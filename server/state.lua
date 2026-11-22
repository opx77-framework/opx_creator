-- Server state, the choices table and the save payload validation. main.lua builds on it.
--
-- The look itself belongs to open77_appearance (setBodyFamily applies, replicates and stores the body).
-- This resource only keeps the creator CHOICES per (user, character, body family), so that reopening the
-- creator shows exactly what the player picked.

Creator = {}

local RESOURCE = GetCurrentResourceName()

---@type table<integer, CreatorSession>
Creator.sessions = {}
Creator.dbReady = false

-- Sizes, in bytes. A net event over 48 KiB is not refused: it stops the resource. The stored choices of a
-- character (one row per body type) travel back in `opx_creator:open`, so every size is capped where it
-- enters: the save payload, the choices of a save, the row that is stored, the row that is read, the send.
Creator.limits = {
    payload = math.min(math.max(1024, math.floor(tonumber(Config.maxPayloadBytes) or 40000)), 40000),
    choicesRefused = 16 * 1024, -- a save whose clean choices weigh more is refused (invalid_look)
    choicesStored = 12 * 1024,  -- a row is stored, and read back, only up to this (a real one weighs 2 to 10 KiB)
    choicesCount = 1024,        -- options in a choices table (a catalogue has about 900 per body type)
    storedName = 48,            -- longest option name of a stored row (the game's are under 40)
    openStored = 30000,         -- both rows travel with `open` up to this; above, only the worn body's
    openEvent = 40000,          -- the whole `open` event, measured before it is sent
}
local LIMITS = Creator.limits

local lastNet, lastSerial, stamp = 0, 0, nil

--- Text for a log line: control characters out (a client text cannot forge a line), cut to `limit` bytes.
function Creator.clean(value, limit)
    local text = tostring(value):gsub('%c', ' ')
    limit = limit or 160
    if #text > limit then text = text:sub(1, limit) end
    return text
end

function Creator.log(level, message, ...)
    local args = table.pack(...)
    for i = 1, args.n do
        if type(args[i]) == 'string' then args[i] = Creator.clean(args[i]) end
    end
    local ok, text = pcall(string.format, '[%s] ' .. message, RESOURCE, table.unpack(args, 1, args.n))
    if not ok then text = ('[%s] %s'):format(RESOURCE, message) end
    local logger = Open77.log and Open77.log[level]
    if logger then logger(text) else print(text) end
end

--- A player id as the natives want it: an integer of 1 or more. Anything else (the console's 0, nil, a
--- fraction, NaN) is nil: a bad id handed to a native is not always a refusal.
function Creator.playerId(value)
    local number = tonumber(value)
    if not number or number ~= number then return nil end
    local id = math.tointeger(number)
    if not id or id < 1 or id > 0x7FFFFFFF then return nil end
    return id
end

-- A connected player id (it has a name), or nil.
function Creator.validPlayer(value)
    local player = Creator.playerId(value)
    if not player or not GetPlayerName(player) then return nil end
    return player
end

--- The number a client echoes in every message of a session (stale messages are ignored).
function Creator.nextNet()
    lastNet = lastNet + 1
    return lastNet
end

--- The public token of a new session: a string no other session of this server has (start time + serial).
function Creator.newToken()
    if not stamp then
        local ok, seconds = pcall(function() return Open77.time.unix() end)
        seconds = ok and tonumber(seconds) or nil
        if seconds and seconds == seconds and seconds > 0 and seconds < 2 ^ 52 then
            stamp = ('%x'):format(math.floor(seconds))
        else
            stamp = 'c'
        end
    end
    lastSerial = lastSerial + 1
    return ('%s-%d'):format(stamp, lastSerial)
end

-- The character open77_appearance plays for this player: { userId, characterKey, family, ... } or nil.
function Creator.identity(player)
    local ok, info = pcall(function() return exports.open77_appearance:character(player) end)
    if ok and type(info) == 'table' and type(info.userId) == 'string' and type(info.characterKey) == 'string' then
        return info
    end
    return nil
end

-- Database -------------------------------------------------------------------------------

local SCHEMA = [[CREATE TABLE IF NOT EXISTS opx_creator_looks (
    user_id VARCHAR(64) NOT NULL,
    character_key VARCHAR(64) NOT NULL,
    body_family VARCHAR(8) NOT NULL,
    choices_json MEDIUMTEXT NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, character_key, body_family),
    KEY idx_opx_creator_character (character_key)
) DEFAULT CHARSET=utf8mb4]]

CreateThread(function()
    local queued, reason = Open77.database.ready(function()
        Open77.database.update(SCHEMA, {}, function(_, failure)
            if failure then return Creator.log('warn', 'choices table unavailable: %s', tostring(failure)) end
            Creator.dbReady = true
        end)
    end)
    if not queued then Creator.log('warn', 'no database, choices last for the session only: %s', tostring(reason)) end
end)

-- Stored choices of a character as JSON strings by family ({ male = '...', female = '...' }). A row over the
-- stored size (written before the cap existed) is left out: the creator then reads the body itself.
-- Coroutine only.
function Creator.loadChoices(userId, characterKey)
    local stored = {}
    if not Creator.dbReady then return stored end
    local ok, rows = pcall(Open77.database.query.await,
        'SELECT body_family, choices_json FROM opx_creator_looks WHERE user_id = ? AND character_key = ?',
        { userId, characterKey })
    if not ok or type(rows) ~= 'table' then
        Creator.log('warn', 'choices of %s not read: %s', characterKey, tostring(rows))
        return stored
    end
    for _, row in ipairs(rows) do
        local family, text = tostring(row.body_family), row.choices_json
        if (family == 'male' or family == 'female') and type(text) == 'string' then
            if #text <= LIMITS.choicesStored then
                stored[family] = text
            else
                Creator.log('warn', 'choices of %s (%s) ignored: %d bytes', characterKey, family, #text)
            end
        end
    end
    return stored
end

-- Keeps the choices of a saved look (`meta` from Creator.decodeSave). Only a sane row is kept: it is sent
-- back at every Open. When it is not kept, the previous row goes, so the next edit starts from the body
-- that was just saved and not from older choices. Coroutine only. Returns true, or false + reason
-- ('no_database', 'too_large', or the database error).
function Creator.storeChoices(userId, characterKey, family, meta)
    if not Creator.dbReady then return false, 'no_database' end
    if type(meta) ~= 'table' or type(meta.json) ~= 'string' then return false, 'encode_failed' end
    if #meta.json > LIMITS.choicesStored or meta.count > LIMITS.choicesCount or meta.longest > LIMITS.storedName then
        local ok, err = pcall(Open77.database.update.await,
            'DELETE FROM opx_creator_looks WHERE user_id = ? AND character_key = ? AND body_family = ?',
            { userId, characterKey, family })
        if not ok then Creator.log('warn', 'older choices of %s not removed: %s', characterKey, tostring(err)) end
        return false, 'too_large'
    end
    local ok, err = pcall(Open77.database.update.await, [[
        INSERT INTO opx_creator_looks (user_id, character_key, body_family, choices_json)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE choices_json = VALUES(choices_json)]],
        { userId, characterKey, family, meta.json })
    if not ok then return false, tostring(err) end
    return true
end

-- A deleted character: its rows go (citizen ids are unique across accounts).
AddEventHandler('opx:characterDeleted', function(_, citizenId)
    if type(citizenId) ~= 'string' or citizenId == '' or #citizenId > 64 or not Creator.dbReady then return end
    Open77.database.update('DELETE FROM opx_creator_looks WHERE character_key = ?', { citizenId }, function(_, reason)
        if reason then Creator.log('warn', 'choices of %s not purged: %s', citizenId, tostring(reason)) end
    end)
end)

-- Open options ------------------------------------------------------------------------------

-- The rail entry ids: 'profile', then the categories of Config.categories.
local ENTRY_IDS = { profile = true }
for _, category in ipairs(Config.categories) do ENTRY_IDS[category.id] = true end

--- A known rail entry id, or nil.
function Creator.entryId(value)
    return type(value) == 'string' and ENTRY_IDS[value] and value or nil
end

--- options.entries: a list of known rail entry ids (duplicates dropped). nil when absent or invalid.
function Creator.cleanEntries(value)
    if type(value) ~= 'table' then return nil end
    local list, seen = {}, {}
    for i = 1, math.min(#value, 32) do
        local id = Creator.entryId(value[i])
        if not id then return nil end
        if not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    return #list > 0 and list or nil
end

function Creator.has(list, id)
    for _, entry in ipairs(list or {}) do
        if entry == id then return true end
    end
    return false
end

--- A caller's text (title, subtitle): a non-empty string cut to `limit` bytes on a UTF-8 boundary, or nil.
function Creator.text(value, limit)
    if type(value) ~= 'string' or value == '' then return nil end
    if #value <= limit then return value end
    local cut = value:sub(1, limit)
    -- drop a trailing multi-byte sequence the cut left incomplete
    local i = #cut
    while i > 0 and cut:byte(i) >= 128 and cut:byte(i) < 192 do i = i - 1 end
    local lead = i > 0 and cut:byte(i) or 0
    if lead >= 192 then
        local need = lead >= 240 and 4 or (lead >= 224 and 3 or 2)
        if #cut - i + 1 < need then cut = cut:sub(1, i - 1) end
    end
    return cut
end

--- options.tag: the caller's own mark on its session, given back in every event. Returns ok, tag:
--- true, nil when absent; false when it is not a string of 1 to 64 bytes without control characters.
function Creator.tag(value)
    if value == nil or value == '' then return true, nil end
    if type(value) ~= 'string' or #value > 64 or value:find('%c') then return false, nil end
    return true, value
end

--- The resource a session belongs to: options.opener when opx_core relayed the call (its OpenCreator writes
--- the resource that called it; from any other caller it is ignored, so nobody can claim another's
--- session), else the resource that called the export, else this one (the staff command).
local CORE = 'opx_core'
function Creator.opener(value, invoker)
    if invoker == CORE and type(value) == 'string' and #value >= 1 and #value <= 64 and not value:find('[%c%s]') then
        return value
    end
    if type(invoker) == 'string' and invoker ~= '' then return invoker end
    return RESOURCE
end

--- What the opx:creator:* events and GetSession say about a session (a new table each time).
function Creator.info(session)
    return { token = session.token, mode = session.mode, tag = session.tag, opener = session.opener, scope = session.scope }
end

--- A player's name for a staff notice: control characters out, 48 bytes at most.
function Creator.playerName(player)
    local name = GetPlayerName(player)
    if type(name) ~= 'string' or name == '' then return tostring(player) end
    return Creator.text((name:gsub('%c', ' ')), 48) or tostring(player)
end

--- Another resource's refusal as a short code a client may receive, or `fallback`.
function Creator.reason(value, fallback)
    if type(value) == 'string' and #value >= 1 and #value <= 64 and value:match('^[%w_:%.%-]+$') then return value end
    return fallback
end

-- Scopes and clothing ------------------------------------------------------------------------

-- Category id -> its config (garment categories carry `garments = true` and equipment `slots`).
local CATEGORY = {}
for _, category in ipairs(Config.categories) do CATEGORY[category.id] = category end

--- Every rail entry id in rail order: 'profile', then the categories.
function Creator.allEntries()
    local list = { 'profile' }
    for _, category in ipairs(Config.categories) do list[#list + 1] = category.id end
    return list
end

--- True when a rail entry is a clothing category.
function Creator.isGarment(id)
    local category = CATEGORY[id]
    return category ~= nil and category.garments == true
end

--- options.scope: ok, name, entries. `ok` false = unknown scope (or a scope listing an unknown entry);
--- entries nil = every entry. No scope = 'full'.
function Creator.scope(value)
    if value == nil then value = 'full' end
    if type(value) ~= 'string' then return false end
    local list = type(Config.scopes) == 'table' and Config.scopes[value] or nil
    if list == nil then
        if value == 'full' then return true, 'full', nil end
        return false
    end
    if list == false then return true, value, nil end
    local entries = Creator.cleanEntries(list)
    if not entries then return false end
    return true, value, entries
end

--- The rail entries of a session without the clothing ones (nil = every entry), or nil when none is left.
function Creator.withoutGarments(entries)
    local list = {}
    for _, id in ipairs(entries or Creator.allEntries()) do
        if not Creator.isGarment(id) then list[#list + 1] = id end
    end
    return #list > 0 and list or nil
end

--- What the entries of a session touch: hasBody (Profile or a body category), hasGarments, and the set of
--- equipment slots the clothing entries offer.
function Creator.reach(entries)
    local hasBody, slots, any = false, {}, false
    for _, id in ipairs(entries or Creator.allEntries()) do
        if Creator.isGarment(id) then
            for _, slot in ipairs(CATEGORY[id].slots or {}) do
                slots[slot] = true
                any = true
            end
        else
            hasBody = true
        end
    end
    return hasBody, any, slots
end

-- The equipment slots of the skin contract.
Creator.garmentSlots = { 'Head', 'Face', 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit' }
local GARMENT_SLOT = {}
for _, slot in ipairs(Creator.garmentSlots) do GARMENT_SLOT[slot] = true end

local function record(value)
    if value == false then return true end
    return type(value) == 'string' and #value >= 1 and #value <= 160 and not value:find('%c')
end

--- A clothing table from a client or the skin provider: only the 7 slots, each an item record (1 to 160
--- bytes, no control character) or false. Returns a clean copy with the given keys, or nil.
function Creator.cleanGarb(value)
    if type(value) ~= 'table' then return nil end
    local clean, count = {}, 0
    for slot, item in pairs(value) do
        count = count + 1
        if count > #Creator.garmentSlots or not GARMENT_SLOT[slot] or not record(item) then return nil end
        clean[slot] = item
    end
    return clean
end

--- The 7 slots a session previews or saves: the client's value for the slots its entries offer, the worn
--- one for every other slot (a client cannot reach a slot its scope does not show).
function Creator.sessionGarb(session, value)
    local garb = Creator.cleanGarb(value)
    if not garb then return nil end
    local out = {}
    for _, slot in ipairs(Creator.garmentSlots) do
        local worn = session.worn and session.worn[slot] or false
        if session.garbSlots[slot] and garb[slot] ~= nil then out[slot] = garb[slot] else out[slot] = worn end
    end
    return out
end

--- The slots where `garb` differs from what the session's character wears (a list in slot order).
function Creator.garbChanges(session, garb)
    local list = {}
    for _, slot in ipairs(Creator.garmentSlots) do
        if garb[slot] ~= (session.worn and session.worn[slot] or false) then list[#list + 1] = slot end
    end
    return list
end

-- Payload validation -----------------------------------------------------------------------

local PARTS = { head = true, body = true, arms = true }
local MAX_GROUPS = 128
local MAX_DEPTH = 12
local MAX_NODES = 4096

-- Choices = { head = { option = index }, body = {...}, arms = {...} }. Returns a clean copy (plain data:
-- names of [%w_-], whole indexes), the number of options and the longest name; nil when it is not one.
function Creator.cleanChoices(value)
    if type(value) ~= 'table' then return nil end
    local clean, count, longest = { head = {}, body = {}, arms = {} }, 0, 0
    for part, options in pairs(value) do
        if not PARTS[part] or type(options) ~= 'table' then return nil end
        for name, index in pairs(options) do
            count = count + 1
            if count > LIMITS.choicesCount then return nil end
            if type(name) ~= 'string' or #name == 0 or #name > 64 or not name:match('^[%w_%-]+$') then return nil end
            if type(index) ~= 'number' or index ~= index or index % 1 ~= 0 or index < 0 or index > 4096 then return nil end
            clean[part][name] = math.floor(index)
            if #name > longest then longest = #name end
        end
    end
    return clean, count, longest
end

-- Plain data as a JSON text decodes: tables keyed by strings or array indexes, strings, booleans and
-- FINITE numbers, within a depth and a number of values. The body goes on to open77_appearance, which
-- encodes it as it is: a non-finite number ("1e999" decodes to one) or a value JSON does not have there
-- does not answer a refusal, it stops the whole server.
local function plain(value, depth, budget)
    local kind = type(value)
    if kind == 'string' or kind == 'boolean' then return true end
    if kind == 'number' then return value == value and value ~= math.huge and value ~= -math.huge end
    if kind ~= 'table' or depth > MAX_DEPTH then return false end
    for key, item in pairs(value) do
        budget.left = budget.left - 1
        if budget.left < 0 then return false end
        local keyKind = type(key)
        if keyKind == 'number' then
            if math.type(key) ~= 'integer' or key < 1 then return false end
        elseif keyKind ~= 'string' then
            return false
        end
        if not plain(item, depth + 1, budget) then return false end
    end
    return true
end
Creator.plain = function(value) return plain(value, 0, { left = MAX_NODES }) end

-- The body as compose returns it: { family, groups = { { part, name, keys, morphs }, ... } }.
-- Only its outer shape and that it is plain data are checked here; open77_appearance's setBodyFamily
-- validates every group.
function Creator.validBody(body, family)
    if type(body) ~= 'table' or body.family ~= family or type(body.groups) ~= 'table' then return false end
    local n = #body.groups
    if n == 0 or n > MAX_GROUPS then return false end
    for i = 1, n do
        local group = body.groups[i]
        if type(group) ~= 'table' or not PARTS[group.part] or type(group.name) ~= 'string' then return false end
    end
    return Creator.plain(body)
end

-- The save payload: ONE JSON string { body, choices } (a net event carries at most 1024 values).
-- Returns body, choices, meta ({ json, count, longest }: the choices encoded once, for storeChoices)
-- or nil, reason.
function Creator.decodeSave(family, payload)
    if family ~= 'male' and family ~= 'female' then return nil, 'invalid_family' end
    if type(payload) ~= 'string' or #payload == 0 then return nil, 'invalid_look' end
    if #payload > LIMITS.payload then return nil, 'too_large' end
    local ok, data = pcall(json.decode, payload)
    if not ok or type(data) ~= 'table' then return nil, 'invalid_look' end
    if not Creator.validBody(data.body, family) then return nil, 'invalid_look' end
    local choices, count, longest = Creator.cleanChoices(data.choices)
    if not choices then return nil, 'invalid_look' end
    -- `choices` is plain data with whole, bounded numbers: safe to encode
    local encoded = json.encode(choices)
    if type(encoded) ~= 'string' or #encoded > LIMITS.choicesRefused then return nil, 'invalid_look' end
    return data.body, choices, { json = encoded, count = count, longest = longest }
end
