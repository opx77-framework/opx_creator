-- Clothing lists of the creator's garment categories (Config.categories with `garments = true`).
-- The catalogue is the skin provider's (its client export GetGarments, read in pages): this resource needs
-- no equipment native. A list position is 1-based with 1 = "None" (the slot empty), then the garments in
-- the provider's order. Rows, cells and labels of a garment deck are built here; client/main.lua decides.

local Locale = require('client.modules.locale')
local L = Locale.t

local Garments = {}

local PAGE = 60          -- GetGarments answers at most 60 items per call (an export result stays small)
local MAX_ITEMS = 4000   -- items kept per slot at most

Garments.SLOTS = { 'Head', 'Face', 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit' }

local lists = {}         -- [family] = { [slot] = { items = { { record, label } }, at = { [record] = position } } }

-- A text of the provider for a row: a non-empty string without control characters, 64 bytes at most.
local function text(value)
    if type(value) ~= 'string' or value == '' then return nil end
    value = value:gsub('%c', ' ')
    if #value > 64 then value = value:sub(1, 64) end
    return value
end

-- "Items.Jacket_01_basic_02" -> "Jacket 01 Basic 02": the record when the provider has no label.
local function pretty(record)
    local name = tostring(record):gsub('^Items%.', ''):gsub('_', ' ')
    return (name:gsub('(%a)([%w]*)', function(a, b) return a:upper() .. b end))
end

-- One slot, page after page. Coroutine only. Returns the list, or nil, reason when the first page fails.
local function loadSlot(provider, slot, family)
    local list = { items = {}, at = {} }
    local offset = 0
    while offset < MAX_ITEMS do
        local ok, pending, why = pcall(Open77.exports.call, provider, 'GetGarments', slot, offset, PAGE, family)
        if not ok or not pending then return nil, ok and why or 'no_provider' end
        local page, reason = pending:await()
        if type(page) ~= 'table' or type(page.items) ~= 'table' then
            if offset == 0 then return nil, reason or 'garments_unavailable' end
            break
        end
        local count = 0
        for _, item in ipairs(page.items) do
            count = count + 1
            local record = type(item) == 'table' and item.record
            if type(record) == 'string' and #record <= 160 and not record:find('%c') and not list.at[record] then
                list.items[#list.items + 1] = { record = record, label = text(item.label) or pretty(record) }
                list.at[record] = #list.items + 1
            end
        end
        offset = offset + count
        if count == 0 or offset >= (tonumber(page.total) or 0) then break end
        Wait(0)
    end
    return list
end

--- Reads the 7 lists of a family from the skin provider (`family` nil = the provider's default, the local
--- body). Coroutine only. Returns true, or false, reason. Read again at every call (a server can add
--- clothing between two sessions).
function Garments.load(provider, key, family)
    if type(provider) ~= 'string' or provider == '' then return false, 'no_provider' end
    local out = {}
    for _, slot in ipairs(Garments.SLOTS) do
        local list, why = loadSlot(provider, slot, family)
        if not list then return false, why end
        out[slot] = list
        Wait(0)
    end
    lists[key] = out
    return true
end

function Garments.has(key)
    return lists[key] ~= nil
end

--- Choices in a slot: garments + 1 (None).
function Garments.count(key, slot)
    local list = lists[key] and lists[key][slot]
    return (list and #list.items or 0) + 1
end

--- The position of a record (false = 1, None), or nil when the list does not have it (hidden, restricted).
function Garments.position(key, slot, record)
    if record == false or record == nil then return 1 end
    local list = lists[key] and lists[key][slot]
    return list and list.at[record] or nil
end

--- The record at a position (1 = false).
function Garments.record(key, slot, position)
    if position <= 1 then return false end
    local list = lists[key] and lists[key][slot]
    local item = list and list.items[position - 1]
    return item and item.record or false
end

--- The text of a record: its label, `None` for false, the record itself when the list does not have it.
function Garments.label(key, slot, record)
    if record == false or record == nil then return L('none') end
    local position = Garments.position(key, slot, record)
    local list = lists[key] and lists[key][slot]
    local item = position and list and list.items[position - 1]
    return item and item.label or pretty(record)
end

--- The option behind a garment row: shaped like a catalogue option (`part` .. ':' .. `name` is its key).
function Garments.option(slot)
    return { part = 'garb', name = slot, garment = true, slot = slot }
end

--- The model of a garment category: rows (fixed length maxRows), the carousel cells of the selected row
--- (only the window around its position: never a cell per garment), the count of that row, and the
--- options. Same shape as Catalog.rows. `slots` = the category's slots offered by the session.
function Garments.rows(key, garb, category, selectedKey, maxRows)
    local options = {}
    for _, slot in ipairs(category.slots or {}) do
        if #options < maxRows then options[#options + 1] = Garments.option(slot) end
    end
    local present = false
    for _, option in ipairs(options) do
        if 'garb:' .. option.slot == selectedKey then present = true end
    end
    local rows, cells, shown = {}, {}, 0
    for i, option in ipairs(options) do
        local slot = option.slot
        local record = garb[slot]
        if record == nil then record = false end
        local count = Garments.count(key, slot)
        local position = Garments.position(key, slot, record) or 0
        local selected = selectedKey == 'garb:' .. slot or (not present and i == 1)
        if selected then
            shown = count
            local function cell(p)
                cells[p] = { show = true, on = p == position, src = '', swatch = false, plain = true,
                    color = '#00000000', n = ('%02d'):format(p) }
            end
            if count <= 7 then
                for p = 1, count do cell(p) end
            else
                for d = -3, 3 do cell(((math.max(position, 1) - 1 + d) % count) + 1) end
            end
        end
        rows[i] = {
            show = true, key = 'garb:' .. slot, label = L('garb_' .. slot), value = Garments.label(key, slot, record),
            position = position, count = count,
            fill = (count > 1 and position > 0) and math.floor((position - 1) / (count - 1) * 100 + 0.5) or 0,
            selected = selected,
        }
    end
    local used = #rows
    for i = used + 1, maxRows do
        rows[i] = { show = false, key = '', label = '', value = '', position = 0, count = 0, fill = 0, selected = false }
    end
    return rows, used, cells, shown, options
end

--- A random garment for each slot (empty included), on top of `garb` (copied).
function Garments.random(key, garb, slots)
    local out = Garments.copy(garb)
    for _, slot in ipairs(slots) do
        out[slot] = Garments.record(key, slot, math.random(Garments.count(key, slot)))
    end
    return out
end

function Garments.copy(garb)
    local out = {}
    for _, slot in ipairs(Garments.SLOTS) do
        local value = garb and garb[slot]
        if value == nil then value = false end
        out[slot] = value
    end
    return out
end

function Garments.same(a, b)
    for _, slot in ipairs(Garments.SLOTS) do
        if (a[slot] or false) ~= (b[slot] or false) then return false end
    end
    return true
end

--- `garb` for another family's lists: a record the list does not have becomes None.
function Garments.fit(key, garb)
    local out = Garments.copy(garb)
    for _, slot in ipairs(Garments.SLOTS) do
        if out[slot] and not Garments.position(key, slot, out[slot]) then out[slot] = false end
    end
    return out
end

return Garments
