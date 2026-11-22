-- The creator document (ui/creator.rml): model, motion and input. It only shows and reports
-- intent; client/main.lua decides what an action does. Created on first open, hidden when closed.
--
-- Screen: a category rail on the left (Profile first: body type, starting looks, randomize), the
-- biometric scan around the character in the centre (client/modules/scan.lua), the deck of the active
-- entry on the right (the selected option big with a thumbnail carousel, the others as compact rows),
-- and a dock at the bottom (progress stepper, key hints, Cancel / Confirm).
--
-- Keys: Q / E (A / D) turn; Up / Down an option (Profile: its rows); Left / Right its value (Shift: a big
-- step in a clothing category, Config.clothing.bigStep); Space the next value; R randomize (Profile: everything, a category: that category); Backspace / Ctrl+Z undo; C recentre
-- the shot (Config.camera.recentreKey); Tab / Shift+Tab and 1-9 the rail entry; Enter confirm; Esc cancel.

local Locale = require('client.modules.locale')
local Camera = require('client.modules.camera')
local Scan = require('client.modules.scan')
local L = Locale.t
local U = function(key, ...) return Locale.upper(Locale.t(key, ...)) end

local View = {}

local ui
local handlers = {}  -- see EVENTS
local shown = false  -- tracked here: ui:state() is a snapshot published after a frame
local tiltId = 0
local lastSound = 0

local D = Config.depth
local DECK = Config.deck or {}
local RAIL = Config.rail or {}
local PROFILE = 'profile'

-- Model events of the document, each forwarded to the handler of the same name (client/main.lua Actions).
local EVENTS = { 'family', 'tab', 'preset', 'random', 'select', 'step', 'pick', 'prow', 'save', 'cancel', 'peek', 'roll', 'undo' }

-- Line icons of the rail (24 x 24 path data), by entry id.
local ICONS = {
    profile = 'M4 5 H20 V19 H4 Z M7.4 10 a2 2 0 1 0 4 0 a2 2 0 1 0 -4 0 Z M6.6 16 C7 14 8.2 13.2 9.4 13.2 C10.6 13.2 11.8 14 12.2 16 M14.5 9.5 H17.5 M14.5 12.5 H17.5 M14.5 15.5 H16.5',
    body = 'M9.6 5 a2.4 2.4 0 1 0 4.8 0 a2.4 2.4 0 1 0 -4.8 0 Z M7.5 10 H16.5 L15.6 15.5 H14.4 L13.8 21.5 H10.2 L9.6 15.5 H8.4 Z',
    face = 'M7 9.5 C7 5.4 9.3 3 12 3 C14.7 3 17 5.4 17 9.5 V12 C17 16.4 14.6 20.5 12 20.5 C9.4 20.5 7 16.4 7 12 Z M9.6 10.6 H10.9 M13.1 10.6 H14.4 M10.6 15.6 H13.4',
    eyes = 'M2.5 12 C5.4 7.6 8.6 6 12 6 C15.4 6 18.6 7.6 21.5 12 C18.6 16.4 15.4 18 12 18 C8.6 18 5.4 16.4 2.5 12 Z M9.2 12 a2.8 2.8 0 1 0 5.6 0 a2.8 2.8 0 1 0 -5.6 0 Z',
    hair = 'M5 15 V11 C5 6.2 8 3 12 3 C16 3 19 6.2 19 11 V15 M8.2 20.5 V12.4 C8.2 9.8 9.8 8.4 12 8.4 C14.2 8.4 15.8 9.8 15.8 12.4 V20.5',
    makeup = 'M4 20 L5.2 15.6 L15.8 5 L19 8.2 L8.4 18.8 Z M13.6 7.2 L16.8 10.4',
    marks = 'M6.5 12 a5.5 5.5 0 1 0 11 0 a5.5 5.5 0 1 0 -11 0 Z M12 2.5 V5.5 M12 18.5 V21.5 M2.5 12 H5.5 M18.5 12 H21.5',
    -- a t-shirt
    clothes = 'M9 3.5 L3.5 6.5 L5.5 11 L7.5 10 V20.5 H16.5 V10 L18.5 11 L20.5 6.5 L15 3.5 C14.4 5 13.3 5.8 12 5.8 C10.7 5.8 9.6 5 9 3.5 Z',
    -- a cap
    headwear = 'M4.5 14.5 C4.5 9.2 7.8 6 12 6 C16.2 6 19.5 9.2 19.5 14.5 Z M19.5 14.5 H22 C22 16 20.8 16.8 19.5 16.8 H4.5 M12 6 V4.5',
}

local function calm() return Config.reducedMotion == true end

-- Deck geometry ----------------------------------------------------------------------------

local function stripCount()
    local n = math.floor(tonumber(DECK.strip) or 5)
    n = math.max(3, math.min(7, n))
    if n % 2 == 0 then n = n - 1 end
    return n
end

local function deckWidth() return math.max(380, math.floor(tonumber(DECK.width) or 452)) end

-- The carousel cell size that fits the deck: inner width minus the two arrows, per cell, minus the gap.
local function cellSize()
    return math.max(36, math.floor((deckWidth() - 48 - 64) / stripCount()) - 8)
end

-- Sizes from Config, as a named stylesheet layer over creator.rcss.
local function sizeSheet()
    local cell = cellSize()
    local strip = stripCount() * (cell + 8)
    return table.concat({
        ('#deck { width: %ddp; }'):format(deckWidth()),
        ('#rows { max-height: %ddp; }'):format(math.max(120, math.floor(tonumber(DECK.listHeight) or 340))),
        ('.strip-clip { width: %ddp; height: %ddp; }'):format(strip, cell + 12),
        ('.cell { width: %ddp; height: %ddp; }'):format(cell, cell),
        ('.cell img { width: %ddp; height: %ddp; }'):format(cell - 4, cell - 4),
        ('.cell .sw { width: %ddp; height: %ddp; }'):format(math.floor(cell * 0.62), math.floor(cell * 0.62)),
        -- starting look cards keep the pictures' shape (354 x 396) at a third of the deck's inner width
        ('.chip { height: %ddp; }'):format(math.floor((deckWidth() - 48 - 16) / 3 * 396 / 354 + 0.5)),
    }, '\n')
end

--- The carousel window of the selected option: `stripCount()` cells around the current choice (all of
--- them when there are fewer), from the cells Catalog.rows built. `p` is the 0-based choice position.
function View.strip(cells, count, position)
    local n = stripCount()
    local out = {}
    local function blank() return { show = false, on = false, src = '', swatch = false, plain = false, color = '#00000000', n = '', p = 0 } end
    if count <= 0 then
        for i = 1, n do out[i] = blank() end
        return out
    end
    local first, used
    if count <= n then first, used = 1, count else first, used = position - (n - 1) // 2, n end
    for k = 1, n do
        if k <= used then
            local p = ((first + k - 2) % count) + 1
            local c = cells[p] or {}
            out[k] = {
                show = true, on = p == position, src = c.src or '', swatch = c.swatch == true, plain = c.plain == true,
                color = c.color or '#00000000', n = c.n or ('%02d'):format(p), p = p - 1,
            }
        else
            out[k] = blank()
        end
    end
    return out
end

--- True when the carousel of an option with `count` choices is centred on the choice (it slides).
function View.carousel(count)
    return (tonumber(count) or 0) > stripCount()
end

--- Fixed texts of the document.
function View.texts()
    return {
        bodyType = U('ui_body_type'), male = U('ui_male'), female = U('ui_female'),
        presets = U('ui_presets'), random = U('ui_random'), randomHint = L('ui_random_hint'),
        empty = L('ui_empty'), rebuilding = U('ui_rebuilding'), cancel = U('ui_cancel'),
        hintRotate = U('ui_hint_rotate'), hintZoom = U('ui_hint_zoom'), hintDrag = U('ui_hint_drag'),
        hintOption = U('ui_hint_option'), hintValue = U('ui_hint_value'), hintCategory = U('ui_hint_category'),
        keyWheel = U('ui_key_wheel'), keyDrag = U('ui_key_drag'), keyEnter = U('ui_key_enter'), keyTab = U('ui_key_tab'),
        keyRecentre = Locale.upper(tostring(Config.camera.recentreKey or '')), hintRecentre = U('ui_hint_recentre'),
        hasRecentre = (Config.camera.recentreKey or '') ~= '' and Config.camera.recentreKey ~= false,
        roOptions = U('ro_options'), undo = U('ui_undo'), rollCategory = U('ui_roll_category'),
    }
end

--- The rail entries: Profile, then the categories, always the full list (a data-for keeps its length);
--- `allowed` (id -> true, nil = all) hides the others and numbers the shown ones. `seen` marks the visited
--- ones (the stepper).
function View.entries(seen, allowed)
    seen = seen or {}
    local list = {}
    local ids = { PROFILE }
    for _, category in ipairs(Config.categories) do ids[#ids + 1] = category.id end
    local shownCount = 0
    for i, id in ipairs(ids) do
        local show = allowed == nil or allowed[id] == true
        if show then shownCount = shownCount + 1 end
        list[i] = {
            id = id, label = U('rail_' .. id), n = show and ('%02d'):format(shownCount) or '', seen = seen[id] == true,
            show = show, first = show and shownCount == 1,
            icon = ('<path view-box="0 0 24 24" d="%s"/>'):format(ICONS[id] or ICONS.marks),
        }
    end
    return list
end

function View.sound(kind)
    local name = Config.sounds and Config.sounds[kind]
    if not name then return end
    local now = GetGameTimer()
    if kind == 'hover' and now - lastSound < 70 then return end
    lastSound = now
    pcall(Open77.sfx.play2d, name)
end

-- Motion ---------------------------------------------------------------------------------

-- The rail tilts in from the left and the deck from the right (hinged on their outer edge), then both
-- sway slowly on the render thread: no Lua runs per frame for the panels.
local function tiltIn()
    tiltId = tiltId + 1
    local id = tiltId
    local spring = { duration = 0.6, bounce = 0.18 }
    local function panel(sel, angle, dx, delay)
        ui:animate(sel, {
            from = { rotateY = 0, perspective = D.perspective, x = dx, opacity = 0 },
            to = { rotateY = angle, perspective = D.perspective, x = 0, opacity = 1 },
            spring = spring, delay = delay,
        }, function()
            if D.sway <= 0 or calm() or not shown or tiltId ~= id then return end
            ui:keyframes(sel, { channel = 'rotateY', duration = D.swaySeconds or 7, iterations = -1, alternate = true,
                stops = { { offset = 0, value = angle }, { offset = 1, value = angle - D.sway * (angle > 0 and 1 or -1), easing = 'ease-in-out' } } })
        end)
    end
    panel('#rail', D.tilt, -60, 0)
    panel('#deck', -D.tilt, 60, 0.08)
    ui:animate('#dock', {
        from = { rotateX = 0, perspective = D.perspective, y = 30, opacity = 0 },
        to = { rotateX = D.lean, perspective = D.perspective, y = 0, opacity = 1 },
        spring = { duration = 0.5, bounce = 0.1 }, delay = 0.16,
    })
    ui:animate('#head', { from = { x = -20, opacity = 0 }, to = { x = 0, opacity = 1 }, preset = 'calm', delay = 0.1 })
    ui:animate('#scan', { from = { opacity = 0 }, to = { opacity = 1 }, preset = 'calm', delay = 0.2 })
    ui:animate('.tab', { from = { x = -16, opacity = 0 }, to = { x = 0, opacity = 1 }, preset = 'calm', stagger = 0.04, delay = 0.22 })
    ui:animate('.step', { from = { y = 8, opacity = 0 }, to = { y = 0, opacity = 1 }, preset = 'calm', stagger = 0.035, delay = 0.3 })
end

--- The deck of an entry cascades in.
function View.deckIn(delay)
    if not ui then return end
    delay = delay or 0
    ui:animate('#deck-title', { from = { x = -14, opacity = 0 }, to = { x = 0, opacity = 1 }, preset = 'snappy', delay = delay })
    ui:animate('#focus', { from = { x = 26, opacity = 0 }, to = { x = 0, opacity = 1 }, preset = 'calm', delay = delay + 0.04 })
    ui:animate('.prow', { from = { x = 22, opacity = 0 }, to = { x = 0, opacity = 1 }, preset = 'calm', stagger = 0.05, delay = delay + 0.04 })
    ui:animate('.opt', { from = { x = 22, opacity = 0 }, to = { x = 0, opacity = 1 }, preset = 'calm', stagger = 0.025, delay = delay + 0.1 })
end

--- Another option became the big one.
function View.focusIn()
    if not ui then return end
    ui:animate('#focus', { from = { y = -6, opacity = 0.3 }, to = { y = 0, opacity = 1 }, preset = 'snappy' })
    ui:animate('#strip', { from = { x = 0, opacity = 0 }, to = { x = 0, opacity = 1 }, preset = 'calm' })
end

--- The choice of option row `i` changed by `direction` (-1 / 1): its values flick in from that side
--- and the carousel slides by `cells` cells (1 when true) when it is centred on the choice.
function View.flick(i, direction, slide, cells)
    if not ui then return end
    ui:animate('#row' .. i .. ' .opt-count', { from = { y = 8 * direction, opacity = 0 }, to = { y = 0, opacity = 1 }, preset = 'snappy' })
    ui:animate('#f-value', { from = { x = 14 * direction, opacity = 0 }, to = { x = 0, opacity = 1 }, preset = 'snappy' })
    ui:animate('#f-count', { from = { y = 6 * direction, opacity = 0 }, to = { y = 0, opacity = 1 }, preset = 'snappy' })
    if slide then
        -- x / y motion channels are physical pixels: one cell is (cell + gap) dp
        local span = (cellSize() + 8) * math.max(1, math.min(stripCount(), tonumber(cells) or 1)) * View.pxPerDp()
        ui:animate('#strip', { from = { x = span * direction }, to = { x = 0 }, preset = 'snappy' })
    end
end

--- Keeps option row `i` (0-based) visible in the scrolling list (keyboard moves).
function View.reveal(i)
    if ui then pcall(ui.scrollTo, ui, '#row' .. i, 'nearest', not calm()) end
end

--- Physical pixels per dp (x / y motion channels take pixels), from the scan's measure.
function View.pxPerDp()
    return Scan.pxPerDp()
end

--- A profile row changed its value.
function View.profileFlick(row)
    if not ui then return end
    ui:animate('#prow' .. row .. ' .pval', { from = { scale = 0.94, opacity = 0.4 }, to = { scale = 1, opacity = 1 }, preset = 'snappy' })
end

-- Document ---------------------------------------------------------------------------------

local FOCUS = { keyboard = true, cursor = true }
local FOCUS_TRIES, FOCUS_RETRY_MS = 20, 300 -- a WebUI page holding the input: 6 s, then the creator gives up
local focusId = 0

-- Takes the keyboard and the mouse back while shown, retrying; after FOCUS_TRIES refusals the handler
-- `focusLost` (client/main.lua) closes the session rather than leave it on screen without input.
local function regainFocus()
    focusId = focusId + 1
    local id = focusId
    local function try(left)
        if not ui or not shown or focusId ~= id or ui:hasFocus() == true then return end
        if ui:focus(FOCUS) then return end
        if left <= 1 then
            if handlers.focusLost then handlers.focusLost('focus_unavailable') end
            return
        end
        SetTimeout(FOCUS_RETRY_MS, function() try(left - 1) end)
    end
    SetTimeout(FOCUS_RETRY_MS, function() try(FOCUS_TRIES) end)
end

local function create()
    if ui then return true end
    local entries = View.entries()
    local cc = {
        t = View.texts(), title = '', subtitle = '', calm = calm(), iconsOnly = RAIL.labels == false,
        family = 'male', familyLabel = '', category = '', categoryLabel = '', categoryIndex = '01', categoryCount = '01',
        categories = entries, presets = {}, hasPresets = false, preset = '', presetLabel = '', prow = 0,
        rows = {}, hasRows = false, isProfile = true,
        focus = { i = 0, label = '', value = '', position = '00', count = '00', fill = 0 },
        strip = View.strip({}, 0, 1), callouts = Scan.blank(), peek = '',
        optionCount = '00', canUndo = false, multiEntry = true,
        veiled = false, veilLabel = '', busy = false, saving = false,
        status = '', statusError = false, statusWarn = false, canCancel = false, confirmLabel = '', cancelLabel = '',
        confirmArmed = false, cancelArmed = false,
    }
    local doc, reason = Open77.ui.create({
        document = 'ui/creator.rml',
        layer = 'menu',
        visible = false,
        models = { cc = cc },
        events = { cc = (function()
            local list = { 'hover' }
            for _, name in ipairs(EVENTS) do list[#list + 1] = name end
            return list
        end)() },
    })
    if not doc then
        -- 'nativeui_unavailable_on_this_host' -> the short code the server knows (its FAILURES)
        return false, tostring(reason):find('^nativeui_unavailable') and 'nativeui_unavailable' or reason
    end
    ui = doc
    Scan.attach(ui)
    ui:stylesheet('sizes', sizeSheet())

    ui:onEvent('error', function(name, detail)
        print(('[opx_creator] ui %s: %s'):format(tostring(name), tostring(detail and detail.message)))
    end)
    -- Another surface took the keyboard and the mouse (`suspended` comes back by itself): take them back.
    ui:onEvent('focus', function(kind, detail)
        if kind == 'blur' and shown and type(detail) == 'table' and detail.reason == 'taken' then regainFocus() end
    end)
    for _, name in ipairs(EVENTS) do
        ui:onModel(name, function(...)
            if shown and handlers[name] then handlers[name](...) end
        end)
    end
    ui:onModel('hover', function() View.sound('hover') end)

    -- Keys (shown in the dock and on the deck): see the header of this file.
    local TURN = { q = -1, a = -1, e = 1, d = 1 }
    local RECENTRE = type(Config.camera.recentreKey) == 'string' and Config.camera.recentreKey:lower() or nil
    local function call(name, ...) if handlers[name] then handlers[name](...) end end
    ui:on('keydown', function(e)
        if not shown then return end
        local key = tostring(e.key or '')
        if key == 'escape' then call('cancel')
        elseif key == 'enter' or key == 'numpadenter' then call('save')
        elseif key == 'backspace' or (key == 'z' and e.ctrl_key) then call('undo')
        elseif TURN[key] then Camera.turn(TURN[key])
        elseif key == 'r' then call('roll')
        elseif RECENTRE and key == RECENTRE then Camera.recentre()
        elseif key == 'up' then call('move', -1)
        elseif key == 'down' then call('move', 1)
        elseif key == 'left' then call('nudge', -1, e.shift_key == true)
        elseif key == 'right' then call('nudge', 1, e.shift_key == true)
        elseif key == 'space' then call('activate')
        elseif key == 'tab' then call('cycle', e.shift_key and -1 or 1)
        else
            local n = tonumber(key:match('^numpad(%d)$') or key:match('^(%d)$'))
            if n and n >= 1 then call('jump', n) end
        end
    end)
    ui:on('keyup', function(e)
        if TURN[tostring(e.key or '')] then Camera.turn(0) end
    end)
    -- Over the character only: the wheel zooms (up comes closer), a left drag turns and pans. The drag
    -- follows the mouse anywhere until the button is released (plain mouse events, not drag events).
    ui:on('mousescroll', '#stage', function(e)
        Camera.zoom(tonumber(e.wheel_delta_y or e.wheel_delta or 0) or 0)
    end)
    -- Over the carousel, the wheel steps through the values.
    ui:on('mousescroll', '#carousel', function(e)
        local delta = tonumber(e.wheel_delta_y or e.wheel_delta or 0) or 0
        if shown and delta ~= 0 then call('nudge', delta > 0 and 1 or -1) end
    end)
    ui:on('mousedown', '#stage', function(e)
        if (tonumber(e.button) or 0) ~= 0 then return end
        Camera.dragStart(tonumber(e.mouse_x) or 0, tonumber(e.mouse_y) or 0)
    end)
    ui:on('mousemove', function(e)
        local x, y = tonumber(e.mouse_x), tonumber(e.mouse_y)
        if x and y then Camera.dragMove(x, y) end
    end)
    ui:on('mouseup', function() Camera.dragEnd() end)
    -- Leaving the carousel ends the hover read-out of a thumbnail.
    ui:on('mouseout', '#strip', function() call('peek', -1, -1) end)
    return true
end

---@param callbacks table<string, function>
function View.setHandlers(callbacks)
    handlers = callbacks
end

function View.merge(fields)
    if ui then ui:merge('cc', fields) end
end

function View.set(field, value)
    if ui then ui:set('cc', field, value) end
end

function View.veil(on, label)
    if ui then ui:merge('cc', { veiled = on == true, veilLabel = label or '' }) end
end

--- The active rail entry changed (or the creator opened on it): callouts and brackets follow its shot.
function View.scene(entryId, shot)
    if ui then Scan.setEntry(entryId, shot) end
end

--- One frame of the scan (the session's frame loop, while open only).
function View.track(now)
    if shown then Scan.step(now) end
end

--- Shows the document with the opening motion. Returns true or false, reason.
function View.show(fields, entryId, shot)
    local ok, reason = create()
    if not ok then return false, reason end
    ui:merge('cc', fields)
    if not shown then
        shown = true
        ui:show()
        tiltIn()
        View.deckIn(0.3)
        Scan.start(calm())
        Scan.setEntry(entryId, shot)
    end
    -- A WebUI page that holds the input refuses the focus: wait for it to let go (coroutine), else give up.
    focusId = focusId + 1
    local id = focusId
    local focused, why = ui:focus(FOCUS)
    for _ = 2, FOCUS_TRIES do
        if focused or not shown then break end
        Wait(FOCUS_RETRY_MS)
        if not shown or focusId ~= id then break end
        focused, why = ui:focus(FOCUS)
    end
    if not focused then
        print(('[opx_creator] focus refused: %s'):format(tostring(why)))
        return false, 'focus_unavailable'
    end
    return true
end

--- Hides it after the panels untilt and fade.
function View.hide()
    if not ui or not shown then return end
    shown = false
    tiltId = tiltId + 1
    Scan.stop()
    local doc = ui
    pcall(function()
        doc:blur()
        doc:stop('#rail')
        doc:stop('#deck')
        local tween = { duration = 0.22, easing = 'ease-in' }
        doc:animate('#rail', { to = { rotateY = 0, x = -60, opacity = 0 }, tween = tween })
        doc:animate('#deck', { to = { rotateY = 0, x = 60, opacity = 0 }, tween = tween })
        doc:animate('#dock', { to = { y = 30, opacity = 0 }, tween = tween })
        doc:animate('#head', { to = { opacity = 0 }, tween = tween })
        doc:animate('#scan', { to = { opacity = 0 }, tween = tween })
    end)
    SetTimeout(260, function()
        if shown or ui ~= doc then return end
        pcall(function()
            doc:set('cc', 'veiled', false)
            doc:hide()
        end)
    end)
end

function View.isShown()
    return shown
end

return View
