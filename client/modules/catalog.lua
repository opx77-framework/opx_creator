-- The game's creator catalogue (Open77.body.catalog): options by uiSlot, choices, labels, thumbnails.
-- Labels come from the catalogue (game language); the locale only fills what the game leaves blank.

local Locale = require('client.modules.locale')
local Thumbs = require('client.modules.thumbs')
local L = Locale.t

local Catalog = {}

local catalogs, indexes = {}, {}
Catalog.cellsMax = 0 -- the most choices of any shown option (the cell list keeps this length)

--- The catalogue of a family, waiting while the game reads it. Coroutine only.
function Catalog.load(family)
    if catalogs[family] then return catalogs[family] end
    for _ = 1, 200 do
        local catalog, reason = Open77.body.catalog(family)
        if catalog then
            catalogs[family] = catalog
            return catalog
        end
        if reason ~= 'catalog_loading' then return nil, reason end
        Wait(100)
    end
    return nil, 'catalog_loading'
end

function Catalog.get(family)
    return catalogs[family]
end

--- slot -> { option, ... } of the options the game's creator shows (not hidden, applied, not a follower).
function Catalog.index(family)
    if indexes[family] then return indexes[family] end
    local catalog = catalogs[family]
    if not catalog then return nil end
    local index = { bySlot = {} }
    for _, option in ipairs(catalog.options or {}) do
        local follower = option.link ~= nil and not option.linkController
        local count = #(option.choices or {})
        if not option.hidden and option.applied and not follower and count > 0 then
            local slot = option.uiSlot or option.name
            index.bySlot[slot] = index.bySlot[slot] or {}
            table.insert(index.bySlot[slot], option)
            if count > Catalog.cellsMax then Catalog.cellsMax = count end
        end
    end
    indexes[family] = index
    return index
end

function Catalog.copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = Catalog.copy(v) end
    return out
end

function Catalog.emptyChoices()
    return { head = {}, body = {}, arms = {} }
end

--- A choices table with the three parts present.
function Catalog.normalize(choices)
    choices = type(choices) == 'table' and choices or {}
    choices.head = type(choices.head) == 'table' and choices.head or {}
    choices.body = type(choices.body) == 'table' and choices.body or {}
    choices.arms = type(choices.arms) == 'table' and choices.arms or {}
    return choices
end

--- Stored choices against the catalogue of today: an option or a choice index the game (or a mod update)
--- no longer has is dropped, so the option falls back to its default. Every option counts, not only the
--- shown ones (followers and hidden options are part of a body too). Unchanged without a catalogue.
function Catalog.clean(family, choices)
    local catalog = catalogs[family]
    if not catalog or type(choices) ~= 'table' then return choices end
    local known = {}
    for _, option in ipairs(catalog.options or {}) do
        if option.part and option.name then
            local indexes = {}
            for _, choice in ipairs(option.choices or {}) do
                if choice.index ~= nil then indexes[choice.index] = true end
            end
            if next(indexes) == nil then indexes = true end -- no listed choices: any index is the game's
            known[option.part] = known[option.part] or {}
            known[option.part][option.name] = indexes
        end
    end
    for part, options in pairs(choices) do
        if type(options) == 'table' then
            for name, index in pairs(options) do
                local indexes = known[part] and known[part][name]
                if not indexes or (indexes ~= true and not indexes[index]) then options[name] = nil end
            end
        end
    end
    return choices
end

--- The current choice of an option and its 1-based position in option.choices.
function Catalog.choiceOf(option, choices)
    local part = choices[option.part]
    local index = part and part[option.name]
    if index == nil then index = option.default end
    for position, choice in ipairs(option.choices) do
        if choice.index == index then return choice, position end
    end
    return option.choices[1], 1
end

-- Labels ------------------------------------------------------------------------------

local function usable(text)
    return type(text) == 'string' and text ~= '' and not text:find('^LocKey') and text or nil
end

local function localized(key)
    local text = L(key)
    return text ~= key and text or nil
end

-- Config.optionLabels: 'game' (catalogue first), 'locale' (slot_* of the locale first), 'auto'.
local function localeFirst()
    local mode = Config.optionLabels or 'auto'
    if mode == 'auto' then return Config.locale ~= 'auto' end
    return mode == 'locale'
end

function Catalog.optionLabel(option)
    local fromLocale = localized('slot_' .. tostring(option.uiSlot or option.name))
    if localeFirst() then return fromLocale or usable(option.label) or option.name end
    return usable(option.label) or fromLocale or option.name
end

local SKIP = { ca = true, bl = true, pwa = true, pma = true, wa = true, ma = true, base = true, fpp = true, tpp = true }
local GENERIC = { basehead = true, head = true, default = true, body = true, base = true }

-- "h0_000_pwa__basehead__01_ca_pale_00_warm_ivory" -> "Warm Ivory" (the words after the last number).
local function internalName(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local tail = name:match('.*__(.+)$') or name
    local tokens, last = {}, 0
    for token in tail:gmatch('[^_]+') do
        tokens[#tokens + 1] = token
        if token:match('^%d+$') then last = #tokens end
    end
    local words = {}
    for i = last + 1, #tokens do
        if not SKIP[tokens[i]:lower()] then words[#words + 1] = tokens[i] end
    end
    if #words == 0 then return nil end
    local generic = true
    for i, word in ipairs(words) do
        if not GENERIC[word:lower()] then generic = false end
        words[i] = word:sub(1, 1):upper() .. word:sub(2):lower()
    end
    if generic then return L('default') end
    return table.concat(words, ' ')
end

function Catalog.choiceLabel(option, choice, position)
    local label = usable(choice.label)
    if label then return label end
    if option.kind == 'morph' then return L('shape', position) end
    if option.kind == 'switcher' then
        local list = choice.options or {}
        local none = #list > 0
        for _, name in ipairs(list) do
            if not (name:match('_none$') or name:match('_00$')) then none = false end
        end
        return none and L('none') or L('style', position)
    end
    if choice.name == 'None' then return L('none') end
    return internalName(choice.name) or L('option', position)
end

function Catalog.presetLabel(name)
    return localized('preset_' .. tostring(name):lower()) or (tostring(name):gsub('^%l', string.upper))
end

-- Thumbnails cut from the game's atlas (client/modules/thumbs.lua), else a colour swatch, else a number.
function Catalog.thumbOf(family, option, position)
    local seq = Thumbs.options[family] and Thumbs.options[family][option.name]
    local part = seq and Thumbs.seq[seq] and Thumbs.seq[seq][position]
    return part and ('/ui/thumbs/' .. part .. '.png') or ''
end

-- Rows of a category -------------------------------------------------------------------

local function blankRow()
    return { show = false, key = '', label = '', value = '', position = 0, count = 0, fill = 0, selected = false }
end

local function blankCell()
    return { show = false, on = false, src = '', swatch = false, plain = false, color = '#00000000', n = '' }
end

--- The model of a category: rows (fixed length maxRows), cells of the selected row (fixed length),
--- and the option behind each row. Lists keep their length, unused entries hidden (`show`): RmlUi warns
--- for every entry of a data-for that shrinks.
function Catalog.rows(family, choices, category, selectedKey, maxRows)
    local index = Catalog.index(family)
    local active = Open77.body.active(family, choices) or {}
    local options = {}
    for _, slot in ipairs(category.slots) do
        for _, option in ipairs(index and index.bySlot[slot] or {}) do
            if active[option.part] and active[option.part][option.name] and #options < maxRows then
                options[#options + 1] = option
            end
        end
    end

    -- The selected row; the first one when none is, or when a switcher removed it.
    local present = false
    for _, option in ipairs(options) do
        if option.part .. ':' .. option.name == selectedKey then present = true end
    end
    local rows, cells = {}, {}
    for i, option in ipairs(options) do
        local key = option.part .. ':' .. option.name
        local selected = selectedKey == key or (not present and i == 1)
        local choice, position = Catalog.choiceOf(option, choices)
        local count = #option.choices
        if selected then
            for p, c in ipairs(option.choices) do
                local src = Catalog.thumbOf(family, option, p)
                local color = c.color
                local swatch = src == '' and type(color) == 'table' and (tonumber(color.a) or 0) > 0
                cells[p] = {
                    show = true, on = p == position, src = src, swatch = swatch, plain = src == '' and not swatch,
                    color = swatch and ('#%02x%02x%02x'):format(color.r or 0, color.g or 0, color.b or 0) or '#00000000',
                    n = ('%02d'):format(p),
                }
            end
        end
        rows[i] = {
            show = true, key = key, label = Catalog.optionLabel(option),
            value = Catalog.choiceLabel(option, choice, position),
            position = position, count = count,
            fill = count > 1 and math.floor((position - 1) / (count - 1) * 100 + 0.5) or 100,
            selected = selected,
        }
    end
    local used, shown = #rows, #cells
    for i = used + 1, maxRows do rows[i] = blankRow() end
    for p = shown + 1, math.max(Catalog.cellsMax, shown) do cells[p] = blankCell() end
    return rows, used, cells, shown, options
end

local function sparseSlots()
    local set = {}
    for _, slot in ipairs(Config.random and Config.random.sparse or {}) do set[slot] = true end
    return set
end

--- Random choices over every shown option of the categories, on top of `base` (a choices table, copied;
--- nil = start empty). A Config.random.sparse slot keeps its default choice most of the time.
function Catalog.random(family, categories, base)
    local choices = Catalog.normalize(Catalog.copy(base) or Catalog.emptyChoices())
    local index = Catalog.index(family)
    if not index then return choices end
    local sparse = sparseSlots()
    local chance = tonumber(Config.random and Config.random.sparseChance) or 0
    for _, category in ipairs(categories) do
        for _, slot in ipairs(category.slots) do
            for _, option in ipairs(index.bySlot[slot] or {}) do
                local pick = option.choices[math.random(#option.choices)].index
                if sparse[slot] and option.default ~= nil and math.random() < chance then pick = option.default end
                choices[option.part][option.name] = pick
            end
        end
    end
    return choices
end

--- The picture of a starting look (Config.looks), or ''.
function Catalog.lookImage(name)
    local file = Config.looks and Config.looks[tostring(name):lower()]
    return type(file) == 'string' and ('/ui/looks/' .. file .. '.png') or ''
end

--- Starting looks of a family: { name, label, image, choices }.
function Catalog.presets(family)
    local list = {}
    local catalog = catalogs[family]
    for _, preset in ipairs(catalog and catalog.presets or {}) do
        list[#list + 1] = {
            name = preset.name, label = Catalog.presetLabel(preset.name), image = Catalog.lookImage(preset.name),
            choices = preset.choices,
        }
    end
    return list
end

--- The label of choice `position` (1-based) of an option, for the carousel's hover read-out.
function Catalog.choiceLabelAt(option, position)
    local choice = option and option.choices[position]
    return choice and Catalog.choiceLabel(option, choice, position) or ''
end

return Catalog
