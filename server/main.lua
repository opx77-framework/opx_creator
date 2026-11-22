-- Exports (the creator contract), client requests, the staff command and lifecycle.
--
-- Flow: Open(player) -> the client builds the creator and answers `shown` -> the player edits live on
-- his own body -> `save` (one JSON string) is validated here, applied and persisted by
-- open77_appearance:setBodyFamily(player, family, body, true), the choices go to opx_creator_looks
-- -> host event opx:creator:saved. Any close without a save -> host event opx:creator:closed.
--
-- Clothing (the `clothes` / `headwear` entries) goes through the skin provider (opx_core
-- Config.providers.skin, never required): GetClothing at opening, SetPreview while trying on (a
-- temporary outfit, never stored), SetClothing at Confirm, ClearPreview on every other way out.
--
-- A session belongs to the resource that opened it (its `opener`) and has a public token: the three
-- host events carry both, so a resource can tell its own session from another one's.

local T = Config.timings
local LIMITS = Creator.limits
local RESOURCE = GetCurrentResourceName()

-- Every server -> client message of this resource. The target is a checked player id, the name a
-- constant, and the values are ours: never a value a client sent (an echoed value can push a reply over
-- the 48 KiB that stop the resource), never more than a few (over 32 the server process itself stops).
local function send(player, event, ...)
    if math.type(player) ~= 'integer' or player < 1 or select('#', ...) > 30 then return false, 'invalid_target' end
    return TriggerClientEvent('opx_creator:' .. event, player, ...)
end

-- A host event. A refusal is logged: the opener is waiting for it.
local function raise(name, ...)
    local ok, why = TriggerEvent(name, ...)
    if ok == false then Creator.log('warn', '%s not published: %s', name, tostring(why)) end
end

-- Bytes of a net event: its values as JSON (how they travel), its name and the envelope.
local function weight(event, ...)
    local ok, text = pcall(json.encode, { ... })
    if not ok or type(text) ~= 'string' then return math.huge end
    return #text + #event + 64
end

-- A staff member opened this session for somebody else: he is told how it went.
local function tellStaff(session, code, detail)
    local staff = session.staff
    if not staff or not GetPlayerName(staff) then return end
    send(staff, 'notice', code, session.targetName, detail)
end

-- What a client may say about a creator that did not show (anything else reads 'failed').
local FAILURES = {
    dead = true, in_vehicle = true, body_unavailable = true, focus_unavailable = true,
    catalog_loading = true, nativeui_unavailable = true, no_provider = true, garments_unavailable = true,
}

-- Ends a session without a save and tells the host. `tellClient` closes a creator still on screen.
local function closeSession(player, reason, tellClient, detail)
    local session = Creator.sessions[player]
    if not session then return false end
    Creator.sessions[player] = nil
    clearPreview(player, session)
    if tellClient then send(player, 'close', session.net) end
    Creator.log('info', 'creator of %d closed without a save (%s)', player, reason)
    if not session.shown and (reason == 'failed' or reason == 'no_answer') then
        tellStaff(session, 'failed', reason == 'failed' and (FAILURES[detail] and detail or 'failed') or 'no_answer')
    end
    raise('opx:creator:closed', player, reason, Creator.info(session))
    return true
end

-- Clothing through the skin provider -------------------------------------------------------

-- The skin provider's name (opx_core Config.providers.skin, running), or nil: no clothing entries then.
local function skinProvider()
    if GetResourceState('opx_core') ~= 'running' then return nil end
    local ok, name = pcall(function() return exports.opx_core:GetProvider('skin') end)
    if ok and type(name) == 'string' and name:match('^[%w_%-]+$') then return name end
    return nil
end

-- A sync export of the session's skin provider: its answer, or false, 'no_provider' when it is gone.
local function skinSync(session, name, ...)
    if not session.skin then return false, 'no_provider' end
    local ok, a, b = pcall(Open77.exports.callSync, session.skin, name, ...)
    if not ok then
        Creator.log('warn', 'skin provider %s:%s failed: %s', session.skin, name, tostring(a))
        return false, 'no_provider'
    end
    return a, b
end

-- An export of the skin provider that may wait (GetClothing, SetClothing). Coroutine only.
local function skinAwait(session, name, ...)
    if not session.skin then return nil, 'no_provider' end
    local ok, pending, why = pcall(Open77.exports.call, session.skin, name, ...)
    if not ok or not pending then return nil, ok and why or 'no_provider' end
    return pending:await()
end

-- The 7 slots of a GetClothing answer (missing = empty), or nil when it is not a clothing table.
local function fullGarb(value)
    local garb = Creator.cleanGarb(value)
    if not garb then return nil end
    for _, slot in ipairs(Creator.garmentSlots) do
        if garb[slot] == nil then garb[slot] = false end
    end
    return garb
end

-- Back to the saved clothes when this session tried something on. Safe to call twice.
local function clearPreview(player, session)
    if not session.previewed then return end
    session.previewed = false
    local ok, why = skinSync(session, 'ClearPreview', player)
    if ok ~= true then Creator.log('warn', 'clothing preview of %d not cleared: %s', player, tostring(why)) end
end

-- The session loses its clothing entries (no provider, a uniform, no clothes to read). False when it has
-- no entry left.
local function dropGarments(session)
    session.entries = Creator.withoutGarments(session.entries)
    session.hasGarments, session.garbSlots, session.worn = false, {}, nil
    return session.entries ~= nil
end

-- The session a client message belongs to, or nil (stale number, nothing open).
local function sessionOf(player, net)
    local session = Creator.sessions[player]
    if not session or type(net) ~= 'number' or session.net ~= net then return nil end
    return session
end

-- Sends `open` with the stored choices, far under the 48 KiB of a net event whatever the database holds:
-- both rows when they fit, else the one of the body the player wears, else none; then the whole event is
-- measured, not assumed.
local function sendOpen(player, session, payload, stored)
    if #(stored.male or '') + #(stored.female or '') > LIMITS.openStored then
        local own = session.family and stored[session.family]
        stored = {}
        if own and #own <= LIMITS.openStored then stored[session.family] = own end
        Creator.log('warn', 'stored choices of %s too heavy for one event: only the current body type is sent', session.characterKey)
    end
    if weight('opx_creator:open', session.net, payload, stored) > LIMITS.openEvent then
        stored = {}
        if weight('opx_creator:open', session.net, payload, stored) > LIMITS.openEvent then
            Creator.log('warn', 'open event for %d too heavy, not sent', player)
            return closeSession(player, 'failed', false)
        end
    end
    send(player, 'open', session.net, payload, stored)
end

-- Opens the creator for a player, or adopts the session its own opener already has there. Answers from
-- memory: the stored choices are read and sent from a thread. Returns true, token or false, reason.
---@param invoker string|nil the resource that called the export
---@param staff integer|nil the staff member who asked (staff command)
local function open(player, options, invoker, staff)
    player = Creator.validPlayer(player)
    if not player then return false, 'invalid_player' end
    options = type(options) == 'table' and options or {}
    local mode = options.mode == 'creation' and 'creation' or 'edit'
    local canCancel = options.canCancel
    if type(canCancel) ~= 'boolean' then canCancel = mode == 'edit' end
    local entries, start = Creator.cleanEntries(options.entries), Creator.entryId(options.start)
    if options.entries ~= nil and not entries then return false, 'invalid_options' end
    local tagged, tag = Creator.tag(options.tag)
    if not tagged then return false, 'invalid_options' end
    local opener = Creator.opener(options.opener, invoker)
    -- A scope names a set of entries (Config.scopes); options.entries wins over it.
    local scoped, scope, scopeEntries = Creator.scope(options.scope)
    if not scoped then return false, 'invalid_options' end
    if options.confirmLabel ~= nil and type(options.confirmLabel) ~= 'string' then return false, 'invalid_options' end
    local confirmLabel = options.confirmLabel and Creator.text((options.confirmLabel:gsub('%c', ' ')), 32) or nil
    if options.entries == nil then entries = scopeEntries end

    -- Clothing entries need a running skin provider and a player out of uniform.
    local skin
    if select(2, Creator.reach(entries)) then
        local refusal
        skin = skinProvider()
        if not skin then
            refusal = 'no_provider'
        else
            local ok, uniform = pcall(Open77.exports.callSync, skin, 'GetUniform', player)
            if not ok then refusal = 'no_provider' elseif uniform ~= nil and uniform ~= false then refusal = 'uniform_active' end
        end
        if refusal then
            entries = Creator.withoutGarments(entries)
            if not entries then return false, refusal end
            skin = nil
            Creator.log('info', 'clothing entries left out for %d: %s', player, refusal)
        end
    end
    local hasBody, hasGarments, garbSlots = Creator.reach(entries)

    local info = Creator.identity(player)
    if not info then return false, 'appearance_not_ready' end

    local previous = Creator.sessions[player]
    if previous and previous.opener ~= opener then
        -- Somebody else's session: it is not replaced (Close ends it). One whose character is no longer
        -- played can never save, so it does not lock the player either: it ends here.
        if previous.saving or (previous.characterKey == info.characterKey and previous.userId == info.userId) then
            return false, 'already_open'
        end
        closeSession(player, 'character_changed', true)
        previous = nil
    end
    if previous and previous.saving then return false, 'busy' end

    -- Without Profile on the rail the body type cannot change: the server holds the client to it.
    local lockFamily = entries ~= nil and not Creator.has(entries, 'profile')
    -- The opener's own session is adopted: same public token, the options of this call, a new client number.
    local session = {
        net = Creator.nextNet(), token = previous and previous.token or Creator.newToken(),
        opener = opener, tag = tag, mode = mode, canCancel = canCancel,
        userId = info.userId, characterKey = info.characterKey,
        family = (info.family == 'male' or info.family == 'female') and info.family or nil, lockFamily = lockFamily,
        entries = entries, start = start, scope = scope,
        hasBody = hasBody, hasGarments = hasGarments, garbSlots = garbSlots, skin = skin,
        previewed = false, lastGarb = 0,
        staff = staff ~= player and staff or nil, targetName = staff and Creator.playerName(player) or nil,
        shown = false, saving = false, lastSave = 0, openedAt = math.floor(GetGameTimer()),
    }
    Creator.sessions[player] = session
    -- The opener's previous session tried clothes on: the new one goes on from there, or puts them back.
    if previous and previous.previewed then
        if hasGarments and previous.skin == skin then session.previewed = true else clearPreview(player, previous) end
    end

    local payload = {
        mode = mode, canCancel = canCancel, entries = entries, start = start,
        title = Creator.text(options.title, 64), subtitle = Creator.text(options.subtitle, 160),
        staff = session.staff ~= nil or nil, -- opened by a staff member: a refusal on the client says so
        confirmLabel = confirmLabel, hasBody = hasBody,
    }
    CreateThread(function()
        local stored = hasBody and Creator.loadChoices(session.userId, session.characterKey) or {}
        if Creator.sessions[player] ~= session then return end
        if session.hasGarments then
            -- The character's saved clothes (never a uniform or a preview): the deck starts from them.
            local worn, why = skinAwait(session, 'GetClothing', player)
            if Creator.sessions[player] ~= session then return end
            session.worn = fullGarb(worn)
            if not session.worn then
                Creator.log('warn', 'clothes of %d not read (%s): clothing entries left out', player, tostring(why))
                if not dropGarments(session) then return closeSession(player, 'failed', true, 'no_provider') end
            end
        end
        payload.entries, payload.hasGarments = session.entries, session.hasGarments
        payload.worn = session.worn
        payload.skin = session.hasGarments and session.skin or nil
        sendOpen(player, session, payload, stored)
        -- The client never showed it (no client resource, a catalogue that never loaded...): give up.
        Wait(T.openTimeoutMs)
        if Creator.sessions[player] == session and not session.shown then
            closeSession(player, 'no_answer', true)
        end
    end)
    Creator.log('info', 'creator opened for %d by %s (%s, %s, cancel=%s)', player, opener, session.characterKey, mode,
        tostring(canCancel))
    return true, session.token
end

-- Exports: the creator contract (docs/ARCHITECTURE.md › Replacing a resource) ---------------

exports('Open', function(player, options)
    return open(player, options, GetInvokingResource and GetInvokingResource() or nil)
end)

exports('IsOpen', function(player)
    player = Creator.playerId(player)
    return player ~= nil and Creator.sessions[player] ~= nil
end)

-- Additions (not required from a replacement creator) -----------------------------------------

--- Closes a player's creator without a save (the body before opening is put back) and raises
--- opx:creator:closed (playerId, reason, info). `reason` defaults to 'closed'. False 'not_open' / 'busy'
--- (saving). Any resource may close any session: it is how somebody else's session is ended.
exports('Close', function(player, reason)
    player = Creator.playerId(player)
    local session = player and Creator.sessions[player]
    if not session then return false, 'not_open' end
    if session.saving then return false, 'busy' end
    reason = type(reason) == 'string' and reason:match('^[%w_]+$') and reason:sub(1, 32) or 'closed'
    closeSession(player, reason, true)
    return true
end)

--- A copy of a player's open session, or nil: { token, opener, tag?, mode, canCancel, shown, saving,
--- entries?, characterKey, openedAt }.
exports('GetSession', function(player)
    player = Creator.playerId(player)
    local session = player and Creator.sessions[player]
    if not session then return nil end
    local entries
    if session.entries then
        entries = {}
        for i, id in ipairs(session.entries) do entries[i] = id end
    end
    return {
        token = session.token, opener = session.opener, tag = session.tag,
        mode = session.mode, canCancel = session.canCancel, shown = session.shown, saving = session.saving,
        entries = entries, characterKey = session.characterKey, openedAt = session.openedAt, scope = session.scope,
    }
end)

-- Client requests ----------------------------------------------------------------------
-- A message whose number is not the open session's gets no answer at all.

-- The creator is on screen.
RegisterNetEvent('opx_creator:shown', function(net)
    if type(net) ~= 'number' then return end
    local player = Creator.validPlayer(source)
    local session = player and sessionOf(player, net)
    if not session or session.shown then return end
    session.shown = true
    tellStaff(session, 'opened')
    raise('opx:creator:opened', player, Creator.info(session))
end)

-- The client closed without a save: the player cancelled (only when allowed) or the creator failed.
local CLOSE_REASONS = { cancelled = true, failed = true }

RegisterNetEvent('opx_creator:closed', function(net, reason, detail)
    if type(net) ~= 'number' then return end
    local player = Creator.validPlayer(source)
    local session = player and sessionOf(player, net)
    if not session or session.saving then return end
    if not CLOSE_REASONS[reason] then return end
    if reason == 'cancelled' and not session.canCancel then
        -- Not offered by our client: keep the session (its opener's next Open adopts it).
        return Creator.log('warn', '%d sent a cancel that is not allowed', player)
    end
    if reason == 'failed' then
        Creator.log('warn', 'creator of %d failed on the client: %s', player, Creator.clean(detail, 64))
    end
    closeSession(player, reason, false, type(detail) == 'string' and detail or nil)
end)

-- A clothing change to try on: `garb` = { Head = record|false, ... }. Answered `opx_creator:garbed (number,
-- ok, reason?, dropped?)`; `dropped` = the clothing entries are gone for this session (no clothes record yet).
RegisterNetEvent('opx_creator:garb', function(net, garb)
    if type(net) ~= 'number' then return end
    local player = Creator.validPlayer(source)
    local session = player and sessionOf(player, net)
    if not session then return end
    local function answer(ok, reason, dropped) send(player, 'garbed', session.net, ok, reason, dropped) end
    if not session.hasGarments then return answer(false, 'no_provider') end
    if session.saving then return answer(false, 'busy') end
    local now = GetGameTimer()
    if now - session.lastGarb < T.garbMinMs then return answer(false, 'too_fast') end
    session.lastGarb = now
    local slots = Creator.sessionGarb(session, garb)
    if not slots then
        Creator.log('warn', 'invalid clothing preview from %d', player)
        return answer(false, 'invalid_garb')
    end
    local ok, reason = skinSync(session, 'SetPreview', player, slots)
    if ok == true then
        session.previewed = true
        return answer(true)
    end
    reason = Creator.reason(reason, 'rejected')
    -- No clothing record for this character yet (a creation that opens early): the session goes on without
    -- its clothing entries rather than fail at Confirm. A clothing-only session keeps the refusal.
    if reason == 'presentation_not_ready' and session.hasBody then
        clearPreview(player, session)
        dropGarments(session)
        Creator.log('info', 'clothing entries of %d left out: presentation_not_ready', player)
        return answer(false, reason, true)
    end
    answer(false, reason)
end)

-- A confirmed look. Every save of the open session is answered `opx_creator:saved (number, ok, reason)`,
-- with the session's own number and one of our reason codes. `payload` (the body) is nil when the session
-- has no body entry or the body did not change; `garb` is the clothing of the session (clothing entries).
-- Order: the body (open77_appearance), then the clothes (skin provider SetClothing, changed slots only).
RegisterNetEvent('opx_creator:save', function(net, family, payload, garb)
    if type(net) ~= 'number' then return end
    local player = Creator.validPlayer(source)
    if not player then return end
    local session = sessionOf(player, net)
    if not session then return end
    local function answer(ok, reason) send(player, 'saved', session.net, ok, reason) end

    if session.saving then return answer(false, 'busy') end
    local now = GetGameTimer()
    if now - session.lastSave < T.saveCooldownMs then return answer(false, 'too_fast') end
    session.lastSave = now

    local body, meta
    if session.hasBody and (type(payload) == 'string' or session.mode == 'creation') then
        local _
        body, _, meta = Creator.decodeSave(family, payload)
        if not body then
            Creator.log('warn', 'invalid save from %d: %s', player, tostring(_))
            return answer(false, Creator.reason(_, 'invalid_look'))
        end
        if session.lockFamily and session.family and family ~= session.family then
            Creator.log('warn', '%d tried to change body type in a session without Profile', player)
            return answer(false, 'family_locked')
        end
    else
        family = session.family
    end
    local clothes, changes = nil, {}
    if session.hasGarments then
        clothes = Creator.sessionGarb(session, garb)
        if not clothes then
            Creator.log('warn', 'invalid clothing save from %d', player)
            return answer(false, 'invalid_garb')
        end
        changes = Creator.garbChanges(session, clothes)
    end
    -- An edit that changes nothing ends without a save (no saved event: nothing to pay for).
    if session.mode == 'edit' and not body and #changes == 0 and not session.bodySaved then
        return closeSession(player, 'unchanged', true)
    end
    -- The character must still be the one the creator opened for (no swap in the middle).
    local info = Creator.identity(player)
    if not info or info.characterKey ~= session.characterKey or info.userId ~= session.userId then
        return answer(false, 'character_changed')
    end

    session.saving = true
    CreateThread(function()
        local changed = { body = session.bodySaved == true, clothing = {} }

        -- Ends the session with saved (something was kept) or closed 'dropped' (the player left, nothing kept).
        local function finish()
            if Creator.sessions[player] == session then Creator.sessions[player] = nil end
            clearPreview(player, session)
            if not changed.body and #changed.clothing == 0 and session.dropped then
                return raise('opx:creator:closed', player, 'dropped', Creator.info(session))
            end
            if not session.dropped then answer(true) end
            Creator.log('info', '%d saved %s (body %s, clothes %d) for %s', player, tostring(family),
                tostring(changed.body), #changed.clothing, session.characterKey)
            local event = Creator.info(session)
            event.changed = changed
            raise('opx:creator:saved', player, session.characterKey, family, event)
        end

        if body then
            local done, ok, reason = pcall(function()
                return exports.open77_appearance:setBodyFamily(player, family, body, true)
            end)
            if not done or not ok then
                session.saving = false
                local why = done and Creator.reason(reason, 'rejected') or 'save_error'
                Creator.log('warn', 'look of %d refused by open77_appearance: %s', player, tostring(done and (reason or why) or ok))
                -- The player left while it was applied: the session ends now, with the one event it owes.
                if session.dropped then return finish() end
                return answer(false, why)
            end
            -- The body is the character's now; the choices only help the next edit.
            local stored, failure = Creator.storeChoices(session.userId, session.characterKey, family, meta)
            if not stored then
                Creator.log(failure == 'too_large' and 'info' or 'warn', 'choices of %s not kept (%s): the next edit starts from the body',
                    session.characterKey, tostring(failure))
            end
            changed.body, session.bodySaved = true, true
        end

        if #changes > 0 and not session.dropped then
            local slots = {}
            for _, slot in ipairs(changes) do slots[slot] = clothes[slot] end
            local ok, reason = skinAwait(session, 'SetClothing', player, slots, { reason = 'opx_creator' })
            if ok == true then
                changed.clothing = changes
                session.worn = clothes
            else
                reason = Creator.reason(reason, 'rejected')
                Creator.log('warn', 'clothes of %d not saved: %s', player, reason)
                -- A creation is never stuck on its clothes: the body is kept, the clothes stay as they were.
                if session.mode ~= 'creation' and not session.dropped then
                    session.saving = false
                    if Creator.sessions[player] == session then
                        -- Try them on again: the player can change them or retry.
                        local shown = skinSync(session, 'SetPreview', player, clothes)
                        session.previewed = shown == true or session.previewed
                    end
                    return answer(false, reason)
                end
            end
        end
        finish()
    end)
end)

-- Staff command -------------------------------------------------------------------------
-- `creator [playerId] [scope]` opens an edit session with Cancel (scope: a key of Config.scopes, default
-- 'full'); `creator [playerId] close` ends the session a player has, whoever opened it. The caller is told what happened (a client notice, or the console).

-- With opx_core running, the target must play a finished character: not the selection screen, not a
-- character still in creation (its own flow owns the creator there).
local function playsCharacter(target)
    if type(GetResourceState) ~= 'function' or GetResourceState('opx_core') ~= 'running' then return true end
    local ok, loaded = pcall(function() return exports.opx_core:IsPlayerLoaded(target) end)
    if not ok then return true end
    if loaded ~= true then return false end
    local read, data = pcall(function() return exports.opx_core:GetPlayer(target) end)
    return not (read and type(data) == 'table' and data.isNew == true)
end

if type(Config.command) == 'string' and Config.command ~= '' then
    RegisterCommand(Config.command, function(source, args)
        local caller = Creator.playerId(source) -- nil: the server console
        args = type(args) == 'table' and args or {}
        -- Each word is 'close', a scope name, or (first only) the target's id.
        local closing, scope, first = false, nil, nil
        for i = 1, math.min(#args, 3) do
            local word = tostring(args[i])
            if word == 'close' then
                closing = true
            elseif type(Config.scopes) == 'table' and Config.scopes[word] ~= nil or word == 'full' then
                scope = word
            elseif i == 1 then
                first = word
            end
        end
        local function reply(code, a, b)
            if caller then return send(caller, 'notice', code, a, b) end
            print(('[opx_creator] %s %s %s'):format(code, tostring(a or ''), tostring(b or '')))
        end

        local target = caller
        if first ~= nil then target = Creator.playerId(first) end
        target = target and Creator.validPlayer(target)
        if not target then return reply('refused', 'invalid_player') end
        local name = Creator.playerName(target)

        if closing then
            local session = Creator.sessions[target]
            if not session then return reply('not_open', name) end
            if session.saving then return reply('refused', 'busy') end
            closeSession(target, 'closed', true)
            return reply('closed', name)
        end
        if not playsCharacter(target) then return reply('refused', 'no_character') end
        local ok, reason = open(target, { mode = 'edit', canCancel = true, scope = scope }, nil, caller)
        if ok then
            -- A staff member reads "opened" when the target's creator is on screen (opx_creator:shown).
            if not caller then reply('requested', name) end
            return
        end
        if reason == 'already_open' then
            local session = Creator.sessions[target]
            return reply('already_open', name, session and session.opener or '?')
        end
        reply('refused', tostring(reason))
    end, true)
end

-- Command help shown in opx_chat when it runs (optional: nothing happens without it). Chat is not a
-- provider slot, so opx_chat is named here; its export only describes the command above.
local function publishCommandHelp()
    if type(Config.command) ~= 'string' or Config.command == '' or GetResourceState('opx_chat') ~= 'running' then return end
    pcall(Open77.exports.callSync, 'opx_chat', 'SetCommandHelp', Config.command,
        { en = "Open a player's character creator (edit mode).", fr = "Ouvrir le créateur de personnage d'un joueur (édition)." },
        {
            { name = { en = 'playerId', fr = 'idJoueur' }, help = { en = 'Default: yourself', fr = 'Par défaut : vous' }, optional = true },
            { name = { en = 'scope', fr = 'portée' }, help = { en = 'full, clothing, barber, surgery, tattoo... or close', fr = 'full, clothing, barber, surgery, tattoo... ou close' }, optional = true },
        })
end

AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() or name == 'opx_chat' then publishCommandHelp() end
end)

-- Lifecycle -------------------------------------------------------------------------------

AddEventHandler('onPlayerDisconnected', function(rawId)
    local player = Creator.playerId(rawId)
    local session = player and Creator.sessions[player]
    if not session then return end
    -- A save being applied finishes first and raises saved (or closed 'dropped' if it fails): one event.
    if session.saving then
        session.dropped = true
        return
    end
    closeSession(player, 'dropped', false)
end)

-- This resource stops: every open creator ends (the clients close theirs with the resource). Best effort
-- only: a stopping resource cannot publish on the host bus, so 'stopped' usually never leaves. A flow that
-- waits for the creator must watch its provider itself (opx_character does).
AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    for player, session in pairs(Creator.sessions) do
        Creator.sessions[player] = nil
        TriggerEvent('opx:creator:closed', player, 'stopped', Creator.info(session))
    end
end)
