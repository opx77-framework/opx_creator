-- Player-facing text from locales/<lang>.json, English as the fallback.

local Locale = {}

local strings, fallback = {}, {}
local settled = false -- the language is known (forced, or reported by the game): no need to read it again

local function read(lang)
    local text = Open77.resource.readFile(('locales/%s.json'):format(lang))
    if not text then return nil end
    local data = Open77.json.decode(text)
    return type(data) == 'table' and data or nil
end

-- The language and whether it is final: the game reports its language only once the world is ready
-- (`locale_not_reported` before), later than client scripts start, so English is provisional until then.
local function language()
    if Config.locale ~= 'auto' then return Config.locale, true end
    local ok, info = pcall(Open77.session.locale)
    local code = ok and type(info) == 'table' and info.code or nil
    if type(code) == 'string' then return code:sub(1, 2):lower(), true end
    return 'en', false
end

--- Reads the locale files; called at start and at every opening, it only reads again while the game's
--- language was not reported yet.
function Locale.load()
    if settled then return end
    local lang
    lang, settled = language()
    fallback = read('en') or {}
    strings = read(lang) or fallback
end

---@param key string
---@return string
function Locale.t(key, ...)
    local text = strings[key] or fallback[key] or key
    if select('#', ...) == 0 then return text end
    local ok, formatted = pcall(string.format, text, ...)
    return ok and formatted or text
end

--- Upper case for display. RmlUi's `text-transform: uppercase` only maps ASCII ("Santé" -> "SANTé"), so
--- caps labels are upper-cased here: ASCII, Latin-1 accented letters (à-þ), ÿ and œ.
---@param text string
---@return string
function Locale.upper(text)
    if type(text) ~= 'string' then return text end
    text = text:gsub('\xC3([\xA0-\xBE])', function(c)
        if c == '\xB7' then return nil end -- the division sign
        return '\xC3' .. string.char(c:byte() - 0x20)
    end)
    text = text:gsub('\xC3\xBF', '\xC5\xB8'):gsub('\xC5\x93', '\xC5\x92')
    return (text:upper())
end

return Locale
