-- opx_creator client: the creator session. The catalogue is the game's (Open77.body.catalog); the preview
-- is the player, re-dressed live (Open77.body.compose + switch); the confirmed look goes to the server,
-- which validates it and makes it the character's through open77_appearance.
-- Clothing entries (Config.categories `garments = true`) try garments on through the server and the skin
-- provider (a temporary outfit): nothing is stored before Confirm. A session without body entries (a
-- wardrobe: options.scope 'clothing') never touches the body.
-- Nothing runs while closed: the frame loop exists only during a session.

local Locale = require('client.modules.locale')
local Catalog = require('client.modules.catalog')
local Camera = require('client.modules.camera')
local View = require('client.modules.view')
local Garments = require('client.modules.garments')
local L = Locale.t
local U = Locale.upper
local T = Config.timings
local SAFETY = Config.safety or {}

local PROFILE = 'profile' -- the first rail entry: body type, starting looks, randomize (not a category)
-- The largest save the server takes (server/state.lua Creator.limits.payload: capped at 40000 bytes).
local MAX_PAYLOAD = math.min(math.max(1024, math.floor(tonumber(Config.maxPayloadBytes) or 40000)), 40000)
local RAIL = Config.rail or {}

local S          -- the open session (nil when closed)
local loading    -- { token, options, stored } while a session is being built
local looping = false

local function categoryById(id)
    for i, category in ipairs(Config.categories) do
        if category.id == id then return category, i end
    end
    return Config.categories[1], 1
end

-- Every rail entry in order: Profile, then the categories.
local function allEntryIds()
    local ids = { PROFILE }
    for _, category in ipairs(Config.categories) do ids[#ids + 1] = category.id end
    return ids
end

-- The rail entries of the session (options.entries narrows them), in rail order.
local function entryIds()
    return S and S.entries or allEntryIds()
end

local function entryIndex(id, ids)
    for i, entry in ipairs(ids or entryIds()) do
        if entry == id then return i end
    end
    return nil
end

local function isGarment(id)
    if id == PROFILE then return false end
    local category = categoryById(id)
    return category.id == id and category.garments == true
end

local function shotOf(id)
    if id == PROFILE then return RAIL.profileShot or 'body' end
    return (categoryById(id)).shot
end

-- id -> true for the entries of the session.
local function allowedSet()
    local set = {}
    for _, id in ipairs(entryIds()) do set[id] = true end
    return set
end

-- Profile rows: 0 body type, 1 starting looks (when the family has some), 2 randomize.
local function profileRows()
    if #Catalog.presets(S.family) > 0 then return { 0, 1, 2 } end
    return { 0, 2 }
end

-- A server or native reason as player text.
local function reasonText(reason)
    local key = 'err_' .. tostring(reason)
    local text = L(key)
    if text == key then text = L('err_generic', tostring(reason)) end
    return text
end

--- A notification through opx_core (its notify provider) when it runs, else the game's own toast.
local function notify(message, kind)
    if type(message) ~= 'string' or message == '' then return end
    local pending = Open77.exports.call('opx_core', 'Notify', message, kind or 'info', 5000)
    if pending then
        CreateThread(function() pending:await() end)
        return
    end
    pcall(Open77.hud.notify, message)
end

--- The status line of the dock. `kind`: nil (info), 'warn' or 'error'.
local function setStatus(text, kind)
    S.status, S.statusError, S.statusWarn = text or '', kind == 'error', kind == 'warn'
end

-- Ask twice ---------------------------------------------------------------------------------

local function disarm()
    if not S or not S.armed then return false end
    S.armed, S.armedUntil = nil, nil
    if not S.busy and not S.saving then setStatus('') end
    return true
end

local function isArmed(kind)
    return S.armed == kind and GetGameTimer() < (S.armedUntil or 0)
end

local function arm(kind, text)
    S.armed, S.armedUntil = kind, GetGameTimer() + (tonumber(SAFETY.windowMs) or 4000)
    setStatus(text, 'warn')
end

-- Model ------------------------------------------------------------------------------------

--- Publishes the session to the document. `withEntries` also re-sends the rail / stepper list (visits).
local function refresh(withEntries)
    if not S then return end
    local ids = entryIds()
    local presets, presetLabel = {}, U(L('ui_custom'))
    for _, p in ipairs(Catalog.presets(S.family)) do
        local label = U(p.label)
        -- the first character, UTF-8 safe (an accented initial is two bytes)
        local initial = label:match('^[%z\1-\127\194-\244][\128-\191]*') or ''
        presets[#presets + 1] = { name = p.name, label = label, initial = initial, img = p.image }
        if p.name == S.preset then presetLabel = U(p.label) end
    end
    local history = isGarment(S.category) and S.garbHistory or S.history[S.family]
    S.peek = ''
    local fields = {
        family = S.family, familyLabel = U(S.family == 'male' and L('ui_male') or L('ui_female')),
        category = S.category, categoryLabel = U(L('cat_' .. S.category)),
        categoryIndex = ('%02d'):format(entryIndex(S.category) or 1), categoryCount = ('%02d'):format(#ids),
        isProfile = S.category == PROFILE, prow = S.prow, peek = '',
        presets = presets, hasPresets = #presets > 0, preset = S.preset or '', presetLabel = presetLabel,
        busy = S.busy, saving = S.saving, status = S.status, statusError = S.statusError, statusWarn = S.statusWarn,
        canCancel = S.canCancel, canUndo = history ~= nil and #history > 0, multiEntry = #ids > 1,
        confirmArmed = S.armed == 'confirm', cancelArmed = S.armed == 'cancel',
        confirmLabel = U(S.saving and L('ui_saving') or (S.armed == 'confirm' and L('ui_confirm_sure') or (S.confirmLabel or L('ui_confirm')))),
        cancelLabel = U(S.armed == 'cancel' and L('ui_cancel_sure') or L('ui_cancel')),
    }
    if withEntries then fields.categories = View.entries(S.visited, allowedSet()) end
    if S.category == PROFILE then
        S.options, S.focus = nil, 0
        fields.optionCount = ('%02d'):format(#profileRows())
        return View.merge(fields)
    end
    local category = categoryById(S.category)
    local rows, used, cells, shown, options
    if category.garments then
        rows, used, cells, shown, options = Garments.rows(S.family, S.garb, category, S.selected[S.category], Config.maxRows)
    else
        rows, used, cells, shown, options = Catalog.rows(S.family, S.choices[S.family], category,
            S.selected[S.category], Config.maxRows)
    end
    S.options, S.focus, S.centred = options, 0, false
    local focus = { i = 0, label = '', value = '', position = '00', count = '00', fill = 0 }
    for i, row in ipairs(rows) do
        row.label = U(row.label)
        row.pos = row.show and ('%02d'):format(row.position) or ''
        row.cnt = row.show and ('%02d'):format(row.count) or ''
        if row.show and row.selected and not fields.strip then
            S.focus, S.centred = i - 1, View.carousel(shown)
            focus = { i = i - 1, label = row.label, value = row.value, position = row.pos, count = row.cnt, fill = row.fill }
            fields.strip = View.strip(cells, shown, row.position)
        end
    end
    fields.strip = fields.strip or View.strip(cells, 0, 1)
    fields.rows, fields.hasRows, fields.focus = rows, used > 0, focus
    fields.optionCount = ('%02d'):format(used)
    View.merge(fields)
end

local function veil(on)
    if not S then return end
    if on then S.veiled = GetGameTimer() elseif not S.veiled then return else S.veiled = nil end
    View.veil(on, on and U(S.family == 'male' and L('ui_male') or L('ui_female')) or '')
end

-- Live preview -----------------------------------------------------------------------------

-- A burst of changes is applied once, after a short pause.
local function schedulePreview()
    S.dirty = GetGameTimer() + T.previewDelayMs
    S.busy = true
    setStatus(L('ui_applying'))
end

local function apply()
    local family = S.family
    local body, reason = Open77.body.compose(family, S.choices[family])
    if not body then
        S.busy = false
        setStatus(reasonText(reason), 'error')
        return refresh()
    end
    local ok, why = Open77.body.switch(family, body)
    if not ok then
        S.busy = false
        setStatus(reasonText(why), 'error')
        return refresh()
    end
    S.waiting = GetGameTimer() + T.redressTimeoutMs
end

-- Undo -------------------------------------------------------------------------------------

--- Remembers the current choices of the family before a change. A burst on one option (holding Left /
--- Right) is one step: `key` names the option, a repeat within 700 ms is not remembered again.
local function remember(key)
    local now = GetGameTimer()
    if key and S.lastKey == key and now - (S.lastKeyAt or 0) < 700 then
        S.lastKeyAt = now
        return
    end
    S.lastKey, S.lastKeyAt = key, now
    local list = S.history[S.family] or {}
    S.history[S.family] = list
    list[#list + 1] = { choices = Catalog.copy(S.choices[S.family]), preset = S.preset }
    local depth = math.max(1, math.floor(tonumber(Config.undoDepth) or 40))
    while #list > depth do table.remove(list, 1) end
end

local function setChoice(option, index)
    remember(option.part .. ':' .. option.name)
    local choices = S.choices[S.family]
    choices[option.part] = choices[option.part] or {}
    choices[option.part][option.name] = index
    S.preset, S.changed = nil, true
    schedulePreview()
    refresh()
end

-- Clothing ---------------------------------------------------------------------------------

-- The equipment slots the clothing entries of a rail list offer (slot -> true).
local function garbSlotsOf(list)
    local slots = {}
    for _, id in ipairs(list) do
        if isGarment(id) then
            for _, slot in ipairs(categoryById(id).slots or {}) do slots[slot] = true end
        end
    end
    return slots
end

-- The rail entries without the clothing ones.
local function withoutGarments(list)
    local out = {}
    for _, id in ipairs(list) do
        if not isGarment(id) then out[#out + 1] = id end
    end
    return out
end

-- Remembers the clothing before a change (a burst on one slot is one step, like remember()).
local function rememberGarb(key)
    local now = GetGameTimer()
    if key and S.lastKey == key and now - (S.lastKeyAt or 0) < 700 then
        S.lastKeyAt = now
        return
    end
    S.lastKey, S.lastKeyAt = key, now
    local list = S.garbHistory
    list[#list + 1] = Garments.copy(S.garb)
    local depth = math.max(1, math.floor(tonumber(Config.undoDepth) or 40))
    while #list > depth do table.remove(list, 1) end
end

-- New clothes are tried on after a short pause, one request at a time (the frame loop sends them).
local function scheduleGarb()
    S.garbDirty = GetGameTimer() + T.previewDelayMs
end

-- A garment in a slot (false = none). Any garment but a full outfit takes the full outfit off: it would
-- hide it.
local function setGarment(slot, record)
    S.garb[slot] = record
    if slot ~= 'Outfit' and record and S.garbSlots.Outfit then S.garb.Outfit = false end
    S.garbChanged = true
    scheduleGarb()
end

-- Choices tables of the body are equal (option name -> index, per part).
local function sameChoices(a, b)
    for _, part in ipairs({ 'head', 'body', 'arms' }) do
        local x, y = a and a[part] or {}, b and b[part] or {}
        for k, v in pairs(x) do if y[k] ~= v then return false end end
        for k, v in pairs(y) do if x[k] ~= v then return false end end
    end
    return true
end

-- The body differs from the one the session opened with (body type or choices).
local function bodyChanged()
    if not S.hasBody or not S.initial then return false end
    return S.family ~= S.initial.family or not sameChoices(S.choices[S.family], S.initial.choices)
end

-- Close --------------------------------------------------------------------------------

--- Ends the session. `keep` leaves the current body (a saved look); otherwise the body captured at
--- opening is put back. open77_appearance takes the body back once the hold is released. `saved` (only
--- on the server's saved answer) is what opx:creator:visible reports.
local function close(keep, saved)
    if not S then return end
    local session = S
    S = nil
    View.hide()
    Camera.stop()
    pcall(Open77.character.setFrozen, false)
    -- A session without body entries never touched the body (no hold, nothing to put back). Clothes tried
    -- on are taken back by the server (skin provider ClearPreview).
    if session.hasBody then
        if not keep and session.original and session.changed then
            pcall(Open77.body.switch, session.original.family, session.original)
        end
        TriggerEvent('open77:appearance:hold', false)
    end
    pcall(Open77.hud.setCinematic, false)
    -- Other client resources may stand down while the creator is on screen (phone, menus...).
    TriggerEvent('opx:creator:visible', false, saved == true)
end

--- Closes on the client side and tells the server why (a client-side failure, a death...).
local function abort(why)
    if not S then return end
    local token = S.token
    close(false)
    TriggerServerEvent('opx_creator:closed', token, 'failed', tostring(why))
end

-- Actions (from the document) ----------------------------------------------------------------

local Actions = {}

function Actions.family(family)
    if not S or S.saving or (family ~= 'male' and family ~= 'female') or family == S.family then return end
    -- Body type is on Profile: a session without Profile (options.entries) keeps it.
    if not entryIndex(PROFILE) then return end
    -- One new body at a time: the previous switch must have taken over first.
    if S.veiled then return end
    -- Both catalogues are read at opening: a UI callback never waits.
    if not Catalog.get(family) then return end
    disarm()
    View.sound('press')
    S.family = family
    S.choices[family] = S.choices[family] or Catalog.emptyChoices()
    S.selected, S.preset, S.changed = {}, nil, true
    S.lastKey = nil
    -- Clothing the other body type cannot wear comes off (the lists were read for both at opening).
    if S.hasGarments and Garments.has(family) then
        local fitted = Garments.fit(family, S.garb)
        if not Garments.same(fitted, S.garb) then
            S.garb, S.garbChanged = fitted, true
            scheduleGarb()
        end
    end
    veil(true)
    schedulePreview()
    refresh()
    View.profileFlick(0)
end

--- Another rail entry (Profile or a category): the deck, the shot and the callouts follow.
function Actions.tab(id)
    id = tostring(id)
    if not S or id == S.category or not entryIndex(id) then return end
    disarm()
    View.sound('press')
    S.category = id
    S.visited[id] = true
    refresh(true)
    View.deckIn()
    local shot = shotOf(id)
    Camera.travel(shot)
    View.scene(id, shot)
end

function Actions.preset(name)
    if not S or S.saving then return end
    for _, preset in ipairs(Catalog.presets(S.family)) do
        if preset.name == name then
            if S.preset == name then return end
            disarm()
            View.sound('press')
            remember()
            S.choices[S.family] = Catalog.normalize(Catalog.copy(preset.choices))
            S.preset, S.changed = name, true
            schedulePreview()
            refresh()
            View.profileFlick(1)
            return
        end
    end
end

--- Profile: every category at random.
function Actions.random()
    if not S or S.saving then return end
    disarm()
    View.sound('press')
    remember()
    S.choices[S.family] = Catalog.random(S.family, Config.categories)
    S.preset, S.changed = nil, true
    schedulePreview()
    refresh()
    View.profileFlick(2)
end

--- R: the category on screen at random, the rest kept (Profile: everything).
function Actions.roll()
    if not S or S.saving then return end
    if S.category == PROFILE then return Actions.random() end
    if isGarment(S.category) then
        -- The category's slots at random, the full outfit excepted (and taken off when anything is worn).
        local slots = {}
        for _, slot in ipairs(categoryById(S.category).slots or {}) do
            if slot ~= 'Outfit' and S.garbSlots[slot] then slots[#slots + 1] = slot end
        end
        if #slots == 0 then return end
        disarm()
        View.sound('press')
        rememberGarb()
        S.garb = Garments.random(S.family, S.garb, slots)
        for _, slot in ipairs(slots) do
            if S.garb[slot] and S.garbSlots.Outfit then S.garb.Outfit = false end
        end
        S.garbChanged = true
        scheduleGarb()
        refresh()
        return View.focusIn()
    end
    disarm()
    View.sound('press')
    remember()
    S.choices[S.family] = Catalog.random(S.family, { (categoryById(S.category)) }, S.choices[S.family])
    S.preset, S.changed = nil, true
    schedulePreview()
    refresh()
    View.focusIn()
end

--- Backspace / Ctrl+Z: the choices before the last change of this body type.
function Actions.undo()
    if not S or S.saving then return end
    if isGarment(S.category) then
        local last = table.remove(S.garbHistory)
        if not last then return end
        disarm()
        View.sound('press')
        S.garb, S.garbChanged, S.lastKey = last, true, nil
        scheduleGarb()
        refresh()
        return View.focusIn()
    end
    local list = S.history[S.family]
    local last = list and table.remove(list)
    if not last then return end
    disarm()
    View.sound('press')
    S.choices[S.family] = last.choices
    S.preset, S.changed, S.lastKey = last.preset, true, nil
    schedulePreview()
    refresh()
    if S.category == PROFILE then View.profileFlick(1) else View.focusIn() end
end

--- Option row `i` (0-based) becomes the big one of the deck.
function Actions.select(i, fromKeyboard)
    i = tonumber(i) or 0
    local option = S and S.options and S.options[i + 1]
    if not option then return end
    local key = option.part .. ':' .. option.name
    if S.selected[S.category] == key then return end
    View.sound(fromKeyboard and 'hover' or 'press')
    S.selected[S.category] = key
    refresh()
    View.focusIn()
    if fromKeyboard then View.reveal(i) end
end

function Actions.step(i, delta)
    i, delta = tonumber(i) or 0, tonumber(delta) or 0
    local option = S and not S.saving and S.options and S.options[i + 1]
    if not option or delta == 0 then return end
    disarm()
    View.sound('press')
    local key = option.part .. ':' .. option.name
    local opened = S.selected[S.category] ~= key
    S.selected[S.category] = key
    if option.garment then
        local slot = option.slot
        local count = Garments.count(S.family, slot)
        local at = Garments.position(S.family, slot, S.garb[slot]) or 1
        rememberGarb(key)
        setGarment(slot, Garments.record(S.family, slot, ((at - 1 + delta) % count) + 1))
        refresh()
        if opened then View.focusIn() else View.flick(i, delta < 0 and -1 or 1, S.centred) end
        return
    end
    local _, position = Catalog.choiceOf(option, S.choices[S.family])
    position = ((position - 1 + delta) % #option.choices) + 1
    setChoice(option, option.choices[position].index)
    if opened then View.focusIn() else View.flick(i, delta < 0 and -1 or 1, S.centred) end
end

function Actions.pick(i, j)
    i, j = tonumber(i) or 0, tonumber(j) or 0
    local option = S and not S.saving and S.options and S.options[i + 1]
    if option and option.garment then
        local slot = option.slot
        local before = Garments.position(S.family, slot, S.garb[slot]) or 0
        if j + 1 == before or j < 0 or j + 1 > Garments.count(S.family, slot) then return end
        disarm()
        View.sound('press')
        rememberGarb()
        setGarment(slot, Garments.record(S.family, slot, j + 1))
        refresh()
        return View.flick(i, j + 1 < before and -1 or 1, S.centred, math.abs(j + 1 - before))
    end
    local choice = option and option.choices[j + 1]
    if not choice then return end
    local _, before = Catalog.choiceOf(option, S.choices[S.family])
    if before == j + 1 then return end
    disarm()
    View.sound('press')
    setChoice(option, choice.index)
    View.flick(i, j + 1 < before and -1 or 1, S.centred, math.abs(j + 1 - before))
end

--- Hover over a carousel cell: its choice's name shows under the option (j < 0 ends it).
function Actions.peek(i, j)
    if not S then return end
    i, j = tonumber(i) or -1, tonumber(j) or -1
    local option = j >= 0 and S.options and S.options[i + 1]
    local label = ''
    if option and option.garment then
        label = Garments.label(S.family, option.slot, Garments.record(S.family, option.slot, j + 1))
    elseif option then
        label = Catalog.choiceLabelAt(option, j + 1)
    end
    if label == (S.peek or '') then return end
    S.peek = label
    if label ~= '' then View.sound('hover') end
    View.set('peek', label)
end

--- A row of the Profile deck takes the keyboard (0 body type, 1 starting looks, 2 randomize).
function Actions.prow(row)
    row = tonumber(row) or 0
    if not S or S.prow == row then return end
    S.prow = row
    refresh()
end

-- Keyboard ---------------------------------------------------------------------------------

--- Up / Down: the previous / next option of the deck (Profile: its rows).
function Actions.move(delta)
    if not S then return end
    if S.category == PROFILE then
        local rows = profileRows()
        local at = 1
        for k, row in ipairs(rows) do if row == S.prow then at = k end end
        View.sound('hover')
        S.prow = rows[((at - 1 + delta) % #rows) + 1]
        return refresh()
    end
    local count = S.options and #S.options or 0
    if count == 0 then return end
    Actions.select((S.focus + delta) % count, true)
end

--- Left / Right: the value of the selected option (Profile: body type, starting look, randomize). `big`
--- (Shift) skips Config.clothing.bigStep garments in a clothing category.
function Actions.nudge(delta, big)
    if not S then return end
    if S.category ~= PROFILE then
        if big and isGarment(S.category) then
            delta = delta * math.max(1, math.floor(tonumber(Config.clothing and Config.clothing.bigStep) or 10))
        end
        return Actions.step(S.focus, delta)
    end
    if S.prow == 0 then
        return Actions.family(S.family == 'male' and 'female' or 'male')
    elseif S.prow == 1 then
        local list = Catalog.presets(S.family)
        if #list == 0 then return end
        local at = 0
        for k, preset in ipairs(list) do if preset.name == S.preset then at = k end end
        if at == 0 then at = delta > 0 and 0 or 1 end
        return Actions.preset(list[((at - 1 + delta) % #list) + 1].name)
    end
    return Actions.random()
end

--- Space: the next value of the selected option (Profile: randomize on its last row).
function Actions.activate()
    if not S then return end
    if S.category == PROFILE and S.prow == 2 then return Actions.random() end
    Actions.nudge(1)
end

--- Tab / Shift+Tab: the next / previous rail entry.
function Actions.cycle(delta)
    if not S then return end
    local ids = entryIds()
    local at = entryIndex(S.category) or 1
    Actions.tab(ids[((at - 1 + delta) % #ids) + 1])
end

--- 1-9: a rail entry by its number.
function Actions.jump(n)
    local id = S and entryIds()[tonumber(n) or 0]
    if id then Actions.tab(id) end
end

-- Sends the look as ONE JSON string { body, choices }: a net event carries at most 1024 values.
function Actions.save()
    if not S or S.saving then return end
    -- Creation: the look is final, so Confirm asks once more (Config.safety.confirmTwice).
    local twice = type(SAFETY.confirmTwice) == 'table' and SAFETY.confirmTwice[S.mode] == true
    if twice and not isArmed('confirm') then
        View.sound('hover')
        arm('confirm', L('ui_confirm_ask'))
        return refresh()
    end
    S.armed, S.armedUntil = nil, nil
    local family = S.family
    -- The body goes only when it changed (always in 'creation'); the server answers an edit that changes
    -- nothing by closing it ('unchanged'). false stands for "nothing" in the event's arguments.
    local encoded = false
    if S.hasBody and (S.mode == 'creation' or bodyChanged()) then
        local body, reason = Open77.body.compose(family, S.choices[family])
        if not body then
            setStatus(reasonText(reason), 'error')
            return refresh()
        end
        local why
        encoded, why = Open77.json.encode({ body = body, choices = S.choices[family] })
        if not encoded or #encoded > MAX_PAYLOAD then
            setStatus(reasonText(why or 'too_large'), 'error')
            return refresh()
        end
    end
    local garb = S.garb and Garments.copy(S.garb) or false
    View.sound('press')
    local sent, refused = TriggerServerEvent('opx_creator:save', S.token, family, encoded, garb)
    if sent == false then
        setStatus(reasonText(refused or 'not_sent'), 'error')
        return refresh()
    end
    S.saving, S.saveDeadline = true, GetGameTimer() + T.saveTimeoutMs
    setStatus(L('ui_saving'))
    refresh()
end

function Actions.cancel()
    if not S or S.saving then return end
    if not S.canCancel then
        -- Creation: no way out but Confirm; say so instead of ignoring Esc.
        arm('notice', L('ui_cannot_cancel')) -- a passing notice: it goes after Config.safety.windowMs
        return refresh()
    end
    -- Changes would be lost: Cancel asks once more (Config.safety.cancelTwice).
    if SAFETY.cancelTwice ~= false and (S.changed or S.garbChanged) and not isArmed('cancel') then
        View.sound('hover')
        arm('cancel', L('ui_cancel_ask'))
        return refresh()
    end
    View.sound('press')
    local token, changed = S.token, S.changed or S.garbChanged
    close(false)
    TriggerServerEvent('opx_creator:closed', token, 'cancelled')
    if changed then notify(L('msg_cancelled'), 'info') end
end

--- The document lost the keyboard and the mouse to another surface and could not take them back: a
--- creator without input cannot be confirmed or left, so it closes (failed) and its opener decides.
function Actions.focusLost(why)
    if not S or S.saving then return end
    abort(why or 'focus_unavailable')
end

View.setHandlers(Actions)

-- Frame loop (only while open) -----------------------------------------------------------------

local function startLoop()
    if looping then return end
    looping = true
    CreateThread(function()
        local last = GetGameTimer()
        while S do
            Wait(0)
            if not S then break end
            local now = GetGameTimer()
            local dt = math.min(0.1, (now - last) / 1000)
            last = now
            if S.dirty and now >= S.dirty then
                S.dirty = nil
                apply()
            end
            -- Clothes to try on: one request at a time (or again when an answer never came).
            if S.garbDirty and now >= S.garbDirty and not S.saving and (not S.garbWait or now > S.garbWait) then
                S.garbDirty = nil
                S.garbSent = Garments.copy(S.garb)
                S.garbWait = now + (tonumber(T.garbAnswerMs) or 4000)
                TriggerServerEvent('opx_creator:garb', S.token, S.garbSent)
            end
            if S.saving and S.saveDeadline and now > S.saveDeadline then
                -- No answer: give the button back rather than leave it on "Saving".
                S.saving, S.saveDeadline = false, nil
                setStatus(L('err_no_answer'), 'error')
                refresh()
            end
            if S.waiting and now > S.waiting then
                S.waiting, S.busy = nil, false
                if not S.armed then setStatus('') end
                refresh()
            end
            -- A question (confirm / cancel again) that was not answered in time goes away.
            if S.armed and now >= (S.armedUntil or 0) then
                disarm()
                refresh()
            end
            -- The veil lifts once the new body is dressed and the shot is back (never before 600 ms).
            if S.veiled and not S.busy and not S.reframe and not S.dirty and now - S.veiled > 600 then veil(false) end
            if S.reframe and now >= S.reframe then
                S.reframe = not Camera.place(300) and now + 250 or nil
            end
            if now >= (S.checkAt or 0) then
                S.checkAt = now + 500
                -- The game can take the shot away during a re-dress: take it back.
                if not S.reframe and not Camera.active() then S.reframe = now end
                -- Killed while editing (staff edit in the open world): the creator gives up.
                local okAlive, alive = pcall(Open77.character.isAlive)
                if okAlive and alive == false and not S.saving then
                    abort('dead')
                    notify(L('msg_closed_dead'), 'warning')
                    break
                end
            end
            Camera.step(dt, now)
            Camera.push()
            View.track(now)
        end
        looping = false
    end)
end

-- Open ------------------------------------------------------------------------------------

local function fail(token, why)
    print(('[opx_creator] the creator could not open: %s'):format(tostring(why)))
    TriggerServerEvent('opx_creator:closed', token, 'failed', tostring(why))
end

local function decodeStored(stored)
    local out = {}
    for _, family in ipairs({ 'male', 'female' }) do
        local text = type(stored) == 'table' and stored[family]
        local choices = type(text) == 'string' and Open77.json.decode(text) or nil
        -- options and indexes the catalogue no longer has are dropped (a game or mod update)
        if type(choices) == 'table' then out[family] = Catalog.clean(family, Catalog.normalize(choices)) end
    end
    return out
end

-- Title and subtitle: the caller's (options.title / subtitle) or the mode's.
local function texts(options)
    local mode = options.mode
    local title = type(options.title) == 'string' and options.title ~= '' and options.title
        or (mode == 'creation' and L('title_creation') or L('title_edit'))
    local subtitle = type(options.subtitle) == 'string' and options.subtitle ~= '' and options.subtitle
        or (mode == 'creation' and L('sub_creation') or L('sub_edit'))
    return U(title), subtitle
end

-- The rail entries the caller allowed (options.entries, checked by the server), in rail order; nil = all.
local function sessionEntries(options)
    if type(options.entries) ~= 'table' then return nil end
    local wanted = {}
    for _, id in ipairs(options.entries) do wanted[tostring(id)] = true end
    local list = {}
    for _, id in ipairs(allEntryIds()) do
        if wanted[id] then list[#list + 1] = id end
    end
    return #list > 0 and list or nil
end

-- Why the creator cannot open on this body now, or nil.
local function blocked()
    local okAlive, alive = pcall(Open77.character.isAlive)
    if okAlive and alive == false then return 'dead' end
    local okSeat, seated = pcall(Open77.character.isInVehicle)
    if okSeat and seated == true then return 'in_vehicle' end
    return nil
end

-- The clothing a session starts from: what the character wears; in 'creation', a character with no clothes
-- at all gets Config.clothing.starter of its body type (only garments the lists have, only offered slots).
local function startingGarb(mode, family, worn, slots)
    local garb = Garments.copy(worn)
    if mode ~= 'creation' then return garb, false end
    for _, slot in ipairs(Garments.SLOTS) do
        if garb[slot] then return garb, false end
    end
    local starter = type(Config.clothing) == 'table' and type(Config.clothing.starter) == 'table'
        and Config.clothing.starter[family]
    if type(starter) ~= 'table' then return garb, false end
    local dressed = false
    for _, slot in ipairs(Garments.SLOTS) do
        local record = starter[slot]
        if slots[slot] and type(record) == 'string' and Garments.position(family, slot, record) then
            garb[slot], dressed = record, true
        end
    end
    return garb, dressed
end

local function open(token, options, stored)
    options = type(options) == 'table' and options or {}
    local hasBody = options.hasBody ~= false
    local hasGarments = options.hasGarments == true and type(options.worn) == 'table' and type(options.skin) == 'string'
    -- The server opened again over a session that touches other things (body, clothes): start it afresh.
    if S and not S.saving and (S.hasBody ~= hasBody or S.serverGarments ~= hasGarments) then
        close(false)
    end
    -- The server opened again over a session on screen (its flow restarted): adopt the new token.
    if S then
        S.token, S.canCancel, S.mode = token, options.canCancel == true, options.mode == 'creation' and 'creation' or 'edit'
        S.armed, S.armedUntil = nil, nil
        S.confirmLabel = type(options.confirmLabel) == 'string' and options.confirmLabel ~= '' and options.confirmLabel or nil
        -- The rail of the new call (the server holds the body type to it when Profile is left out).
        S.entries = sessionEntries(options)
        local list = S.entries or allEntryIds()
        if not S.hasGarments then
            S.entries = withoutGarments(list)
            list = S.entries
        end
        S.garbSlots = garbSlotsOf(list)
        S.garbWait = nil
        if S.hasGarments then scheduleGarb() end -- the new session tries the current clothes on again
        if not entryIndex(PROFILE, list) and S.original and S.family ~= S.original.family and not S.saving then
            -- No body type change any more: back to the body type the session opened with.
            S.family = S.original.family
            S.choices[S.family] = S.choices[S.family] or Catalog.emptyChoices()
            S.selected, S.preset, S.changed, S.lastKey = {}, nil, true, nil
            veil(true)
            schedulePreview()
        end
        local title, subtitle = texts(options)
        View.merge({ title = title, subtitle = subtitle })
        if not entryIndex(S.category, list) then
            -- The entry on screen is not offered any more: the call's start, else its first entry.
            local wantStart = type(options.start) == 'string' and options.start or RAIL.start
            Actions.tab(entryIndex(wantStart, list) and wantStart or list[1])
        end
        refresh(true)
        return TriggerServerEvent('opx_creator:shown', token)
    end
    if loading then
        loading.token, loading.options, loading.stored = token, options, stored
        return
    end
    loading = { token = token, options = options, stored = stored }
    -- The game reports its language after client scripts start: read it now if it was not known then.
    Locale.load()

    -- Each step in its own frame: a resume has a time budget, and a catalogue is ~900 options.
    -- First the body must be settled (no switch in flight), alive and on foot (a respawn or a scripted
    -- move can be under way: wait a little before giving up).
    local state, why = Open77.body.state(), nil
    for _ = 1, 100 do
        state = Open77.body.state()
        why = blocked()
        if state and not state.busy and not why then break end
        if loading.cancelled then break end
        Wait(100)
    end
    if not state or why then
        local req = loading
        loading = nil
        if not req.cancelled then
            fail(req.token, why or 'body_unavailable')
            if why then notify(reasonText(why), 'warning') end
        end
        return
    end
    local family = state.family
    local other = family == 'male' and 'female' or 'male'
    -- The body catalogue only when the session edits the body: a wardrobe never reads it.
    if hasBody then
        local catalog
        catalog, why = Catalog.load(family)
        if not catalog or not loading then
            local req = loading
            loading = nil
            if req then fail(req.token, why) end
            return
        end
        Wait(0)
        Catalog.index(family)
        Wait(0)
        if Catalog.load(other) then
            Wait(0)
            Catalog.index(other)
        end
        Wait(0)
    end

    -- Clothing lists from the skin provider (both body types when Profile can switch it).
    local opts = options
    local entries = sessionEntries(opts)
    local list = entries or allEntryIds()
    local garments = hasGarments
    if garments then
        local ok
        ok, why = Garments.load(opts.skin, family, nil)
        if ok and entryIndex(PROFILE, list) then Garments.load(opts.skin, other, other) end
        if not ok then
            print(('[opx_creator] clothing lists unavailable: %s'):format(tostring(why)))
            garments = false
        end
    end
    if not garments then
        -- No clothing entries on this screen; the server still gets the worn clothes back (nothing changes).
        list = withoutGarments(list)
        entries = list
        if #list == 0 then
            local req = loading
            loading = nil
            if req and not req.cancelled then fail(req.token, why or 'garments_unavailable') end
            return
        end
    end

    local req = loading
    loading = nil
    if not req or req.cancelled then return end
    if req.options ~= opts then
        -- Opened again while the catalogues were read: start over with the latest call (they are cached).
        return CreateThread(function() open(req.token, req.options, req.stored) end)
    end
    local current, choices = nil, {}
    if hasBody then
        current = Open77.body.capture()
        choices = decodeStored(req.stored)
        -- Stored choices the game can no longer compose would fail every preview and save: read the body instead.
        if choices[family] and not Open77.body.compose(family, choices[family]) then choices[family] = nil end
        if not choices[family] then
            choices[family] = Catalog.normalize(current and Open77.body.decompose(current) or nil)
        end
        Wait(0)
    else
        choices[family] = Catalog.emptyChoices()
    end

    local mode = opts.mode == 'creation' and 'creation' or 'edit'
    local garbSlots = garments and garbSlotsOf(list) or {}
    local worn = hasGarments and Garments.copy(opts.worn) or Garments.copy(nil)
    local garb, dressed = worn, false
    if garments then garb, dressed = startingGarb(mode, family, worn, garbSlots) end
    local wantStart = type(opts.start) == 'string' and opts.start or RAIL.start
    local first = entryIndex(wantStart, list) and wantStart or list[1]
    local shot = shotOf(first)
    S = {
        token = req.token, mode = mode, canCancel = opts.canCancel == true,
        entries = entries, family = family, original = current, choices = choices, category = first, selected = {},
        prow = 0, focus = 0, visited = { [first] = true }, history = {},
        busy = false, saving = false, changed = false, status = '', statusError = false, statusWarn = false,
        hasBody = hasBody, initial = hasBody and { family = family, choices = Catalog.copy(choices[family]) } or nil,
        serverGarments = hasGarments, hasGarments = garments, garbSlots = garbSlots,
        worn = worn, garb = garb, garbAccepted = Garments.copy(worn), garbHistory = {}, garbChanged = false,
        confirmLabel = type(opts.confirmLabel) == 'string' and opts.confirmLabel ~= '' and opts.confirmLabel or nil,
    }
    -- A new character in underwear tries the starter clothes on at once.
    if dressed then S.garbDirty = GetGameTimer() end
    Camera.start(shot)
    Open77.character.setFrozen(true)
    if hasBody then
        -- open77_appearance does not put its stored body back while the creator previews on the player.
        TriggerEvent('open77:appearance:hold', true)
    end
    -- A clean view: no vanilla HUD and no game notifications.
    pcall(Open77.hud.setCinematic, true, 0.01)

    local title, subtitle = texts(opts)
    local session = S
    local shown, reason = View.show({
        t = View.texts(), title = title, subtitle = subtitle, categories = View.entries(S.visited, allowedSet()),
        veiled = false,
    }, first, shot)
    -- View.show can wait for the focus: the server may have closed the session meanwhile.
    if S ~= session then return end
    if not shown then
        local token = S.token
        close(false)
        return fail(token, reason)
    end
    TriggerEvent('opx:creator:visible', true, false)
    -- Put the player in a runtime body straight away: later edits only re-dress it.
    if hasBody and not state.switched then
        veil(true)
        apply()
    end
    refresh()
    if not Camera.place(Config.camera.blendInMs) then S.reframe = GetGameTimer() + 250 end
    startLoop()
    TriggerServerEvent('opx_creator:shown', S.token)
end

-- Events ------------------------------------------------------------------------------------

RegisterNetEvent('opx_creator:open', function(token, options, stored)
    if type(token) ~= 'number' then return end
    CreateThread(function() open(token, options, stored) end)
end)

-- The server's answer to a save.
RegisterNetEvent('opx_creator:saved', function(token, ok, reason)
    if not S or S.token ~= token then return end
    S.saveDeadline = nil
    if ok == true then
        local mode = S.mode
        close(true, true)
        -- Creation: opx_character takes over (its own screens); an edit says it worked.
        if mode ~= 'creation' then notify(L('msg_saved'), 'success') end
        return
    end
    S.saving, S.busy = false, false
    setStatus(reasonText(reason), 'error')
    refresh()
end)

-- The server's answer to clothes tried on. Refused: back to the last clothes it took, the reason on the
-- status line. `dropped`: the clothing entries are gone for this session (no clothing record yet).
RegisterNetEvent('opx_creator:garbed', function(token, ok, reason, dropped)
    if not S or S.token ~= token then return end
    S.garbWait = nil
    if ok == true then
        S.garbAccepted = S.garbSent or S.garbAccepted
        return
    end
    if reason == 'too_fast' then
        S.garbDirty = S.garbDirty or GetGameTimer() + T.previewDelayMs
        return
    end
    S.garbDirty = nil
    S.garb = Garments.copy(S.garbAccepted)
    if dropped == true then
        S.hasGarments, S.garb = false, Garments.copy(S.worn)
        S.entries = withoutGarments(S.entries or allEntryIds())
        S.garbSlots = {}
        if not entryIndex(S.category) then Actions.tab(S.entries[1]) end
    end
    setStatus(reasonText(reason), dropped == true and 'warn' or 'error')
    refresh(true)
end)

-- The server ended the session (the client never showed it in time, Close export, resource stop).
RegisterNetEvent('opx_creator:close', function(token)
    if loading and loading.token == token then loading.cancelled = true end
    if S and S.token == token then close(false) end
end)

-- A staff command answer: refused (reason), opened / closed / not_open (player name), failed (player name,
-- reason), already_open (player name, opener).
RegisterNetEvent('opx_creator:notice', function(code, a, b)
    code = tostring(code)
    if code == 'opened' or code == 'closed' then return notify(L('notice_' .. code, tostring(a)), 'success') end
    if code == 'refused' then return notify(L('notice_refused', reasonText(a)), 'error') end
    if code == 'failed' then return notify(L('notice_failed', tostring(a), reasonText(b)), 'error') end
    if code == 'already_open' then return notify(L('notice_already_open', tostring(a), tostring(b)), 'error') end
    notify(L('notice_' .. code, tostring(a)), 'error')
end)

AddEventHandler('open77:body:changed', function(event)
    if not S then return end
    event = tostring(event or '')
    local failed = event:sub(1, 7) == 'failed:'
    if event ~= 'switched' and event ~= 'redressed' and event ~= 'unchanged' and not failed then return end
    S.waiting = nil
    S.busy = false
    if failed then setStatus(reasonText(event:sub(8)), 'error')
    elseif S.saving then setStatus(L('ui_saving'))
    elseif not S.armed then setStatus('') end
    -- A new body (another family, or the first switch) took the camera with the old one.
    if event == 'switched' then
        Camera.drop()
        S.reframe = GetGameTimer()
    end
    refresh()
end)

-- Stopped mid-session: nothing was saved, so the body from before opening is put back (open77_appearance
-- publishes every preview step: the restored body is the one it keeps). A save in flight may already be
-- applied on the server: its body stays, but it is not reported as saved.
AddEventHandler('onClientResourceStop', function(name)
    if name == Open77.resource.name() then close(S ~= nil and S.saving == true) end
end)

exports('IsOpen', function()
    return S ~= nil
end)

Locale.load()

-- A previous instance stopped mid-session may not have released its hold (a stopping VM's events are best
-- effort): no session is open here, so release it once (idempotent in open77_appearance).
TriggerEvent('open77:appearance:hold', false)

-- Measuring tool: lists every slot the local body publishes, with its height above the feet and its
-- forward / side offsets in the character's frame, so Config.scan.points can use real slots.
if (Config.boneCommand or '') ~= '' then
    RegisterCommand(Config.boneCommand, function()
        local o = Open77.character.offsetToWorld(vector3(0, 0, 0))
        local f = Open77.character.offsetToWorld(vector3(0, 1, 0))
        local r = Open77.character.offsetToWorld(vector3(1, 0, 0))
        local slots, why = Open77.character.bones()
        if not (o and f and r) or type(slots) ~= 'table' then
            return print(('[opx_creator] bones unavailable: %s'):format(tostring(why)))
        end
        local fx, fy, rx, ry = f.x - o.x, f.y - o.y, r.x - o.x, r.y - o.y
        local head = Open77.character.bonePosition('head')
        print(('[opx_creator] %d slots on this body (metres: up from the feet / forward / side; dHead = up from Head)'):format(#slots))
        for _, name in ipairs(slots) do
            local p = Open77.character.bonePosition(name)
            if p then
                local dx, dy = p.x - o.x, p.y - o.y
                print(('[opx_creator]   %-24s up %.3f  fwd %.3f  side %.3f  dHead %s'):format(name, p.z - o.z,
                    dx * fx + dy * fy, dx * rx + dy * ry, head and ('%.3f'):format(p.z - head.z) or '-'))
            end
        end
    end, false)
end
