-- The biometric scan over the stage (ui/creator.rml #scan): corner brackets framing the shot and callouts
-- tied to points of the body.
--
-- NativeUI anchors (`ui:anchor`) only follow points of a <scene3d> view, and Open77.anchors only publish to
-- WebUI pages, so the points are projected here: Open77.camera.project (ungated, the game camera's own
-- projection) for at most 5 points per frame, and each element is moved with an `x` / `y` transform
-- channel (no layout), only when it moved. The world points are read from body slots
-- (Open77.character.bonePosition, `world.transform`) once a second. Nothing runs while the creator is closed:
-- Scan.step is called by the session's frame loop only.

local Locale = require('client.modules.locale')
local L = Locale.t

local Scan = {}

local SC = Config.scan or {}
local MAX = 3           -- callouts in the document (fixed-length list)
local BRACKET = 30      -- dp, the size of a corner bracket
local TAG = 124 + 216   -- dp from a point to the far end of a label (leader + the label's fixed width, ui/creator.rcss .co-tag)

local ui
local on = false         -- the scan tracks the body (Config.scan.enabled)
local measuring = false  -- the screen size is read (also with the scan off: the carousel slide needs it)
local calm = false
local shotName, entry = 'body', nil
local world, ground = {}, nil      -- point name -> vector3; the feet height
local nextPoints, nextMeasure = 0, 0
local dp = { w = 1920, h = 1080, px = 1 }   -- px: physical pixels per dp (x / y motion channels are pixels)
local sent = { frame = nil, co = {} }
local list = {}                    -- the callouts of the entry: { point, side }
local snap = true                  -- the next frame placement jumps (opening) instead of gliding
local drawFlip = false

local function num(v, d) return tonumber(v) or d end

-- The player's frame: origin at the feet, forward and right unit vectors.
local function playerFrame()
    local ok, o = pcall(Open77.character.offsetToWorld, vector3(0, 0, 0))
    local ok2, f = pcall(Open77.character.offsetToWorld, vector3(0, 1, 0))
    local ok3, r = pcall(Open77.character.offsetToWorld, vector3(1, 0, 0))
    if not (ok and ok2 and ok3 and o and f and r) then return nil end
    o = vector3(o.x, o.y, o.z)
    return { o = o, f = vector3(f.x, f.y, f.z) - o, r = vector3(r.x, r.y, r.z) - o }
end

local function readPoints()
    local fr = playerFrame()
    if not fr then return end
    ground = fr.o.z
    local bones = {}
    for name, spec in pairs(SC.points or {}) do
        local base
        if spec.bone then
            if bones[spec.bone] == nil then
                local ok, p = pcall(Open77.character.bonePosition, spec.bone)
                local v = ok and type(p) == 'table' and p.x and vector3(p.x, p.y, p.z) or false
                -- A slot far from the player is not this body's (a body being swapped): use the height.
                if v and #(v - fr.o) > 2.6 then v = false end
                bones[spec.bone] = v
            end
            base = bones[spec.bone] or nil
            if base then base = base + vector3(0, 0, num(spec.up, 0)) end
        end
        if not base then base = fr.o + vector3(0, 0, num(spec.height, 1)) end
        world[name] = base + fr.f * num(spec.forward, 0) + fr.r * num(spec.side, 0)
    end
end

-- Screen size in dp, from two watched rectangles (#dpref is 100 dp wide).
local function measure(now)
    if now < nextMeasure then return end
    nextMeasure = now + 1000
    local ref, root = ui:rect('#dpref'), ui:rect('#root')
    if ref and root and num(ref.width, 0) > 0 and num(root.width, 0) > 0 then
        local scale = ref.width / 100
        dp.w, dp.h, dp.px = root.width / scale, root.height / scale, scale
    end
end

--- A point on screen, in dp: x, y, onScreen. Nil when it cannot be projected or is behind the camera.
local function screen(name)
    local p = world[name]
    if not p then return nil end
    local ok, s = pcall(Open77.camera.project, { x = p.x, y = p.y, z = p.z })
    if not ok or type(s) ~= 'table' or not s.x or not s.y then return nil end
    if s.depth and s.depth <= 0 then return nil end
    if not s.onScreen and (s.x < -2 or s.x > 3 or s.y < -2 or s.y > 3) then return nil end
    return s.x * dp.w, s.y * dp.h, s.onScreen == true
end

-- Layout is computed in dp; the x / y motion channels take physical pixels.
local function moveTo(sel, x, y)
    local to = { x = x * dp.px, y = y * dp.px }
    if snap or calm then
        ui:animate(sel, { to = to, instant = true })
    else
        ui:animate(sel, { to = to, spring = { duration = 0.45, bounce = 0 } })
    end
end

local function placeFrame()
    local f = SC.frames and (SC.frames[shotName] or SC.frames.body)
    if not f then return end
    local tx, ty = screen(f.top)
    local bx, by = screen(f.bottom)
    if not tx or not bx then return end
    local pad = num(f.pad, 16)
    local top, bottom = math.min(ty, by) - pad, math.max(ty, by) + pad
    local w = (bottom - top) * num(f.aspect, 0.45)
    local cx = (tx + bx) / 2
    local b = SC.bounds or {}
    local right = num(b.right, 60) + num(Config.deck and Config.deck.width, 452) + 56
    top = math.max(num(b.top, 70), top)
    bottom = math.min(dp.h - num(b.bottom, 150), bottom)
    local x0 = math.max(num(b.left, 300), cx - w / 2)
    local x1 = math.min(dp.w - right, cx + w / 2)
    if bottom - top < 90 or x1 - x0 < 70 then return end
    local last = sent.frame
    if last and not snap and math.abs(last[1] - x0) < 1.5 and math.abs(last[2] - top) < 1.5
        and math.abs(last[3] - x1) < 1.5 and math.abs(last[4] - bottom) < 1.5 then return end
    sent.frame = { x0, top, x1, bottom }
    moveTo('#brk-tl', x0, top)
    moveTo('#brk-tr', x1 - BRACKET, top)
    moveTo('#brk-bl', x0, bottom - BRACKET)
    moveTo('#brk-br', x1 - BRACKET, bottom - BRACKET)
    if snap then
        snap = false
        ui:class('#scan', 'placed', true)
    end
end

local function placeCallouts()
    local b = SC.bounds or {}
    local minX = num(b.left, 300)
    local maxX = dp.w - num(Config.deck and Config.deck.width, 452) - 66   -- the deck's left edge
    for i, c in ipairs(list) do
        local s = sent.co[i]
        local id = '#co' .. (i - 1)
        local x, y, visible = screen(c.point)
        local show = x ~= nil and visible and x > minX - 40 and x < maxX + 40
        if show ~= s.show then
            ui:class(id, 'gone', not show)
            s.show = show
        end
        if show then
            -- The label goes on its side unless it would leave the stage there.
            local left = c.side == 'left'
            if left and x - TAG < minX then left = false
            elseif not left and x + TAG > maxX then left = true end
            if left ~= s.left then
                ui:class(id, 'left', left)
                s.left = left
            end
            if not s.x or math.abs(s.x - x) > 0.4 or math.abs(s.y - y) > 0.4 then
                ui:animate(id, { to = { x = x * dp.px, y = y * dp.px }, instant = true })
                s.x, s.y = x, y
            end
        end
    end
end

-- The leader lines and brackets draw themselves (the labels show at once).
local function calloutsIn()
    if calm then return end
    drawFlip = not drawFlip
    ui:class('#scan', 'draw-a', drawFlip)
    ui:class('#scan', 'draw-b', not drawFlip)
end

local function decimal(value)
    local text = ('%.2f'):format(value)
    local sep = L('ui_decimal')
    if sep ~= 'ui_decimal' and sep ~= '.' then text = text:gsub('%.', sep) end
    return text
end

-- The callout model of the entry (labels, heights).
local function calloutModel()
    local out = {}
    for i = 1, MAX do
        local c = list[i]
        if c then
            local p = world[c.point]
            out[i] = {
                show = true, side = c.side == 'right' and 'right' or 'left', label = Locale.upper(L('co_' .. c.point)),
                sub = (p and ground) and L('co_height', decimal(p.z - ground)) or '',
            }
        else
            out[i] = { show = false, side = 'left', label = '', sub = '' }
        end
    end
    return out
end

-- Public ---------------------------------------------------------------------------------

function Scan.attach(doc)
    ui = doc
end

--- The model fields the document starts with.
function Scan.blank()
    list = {}
    return calloutModel()
end

--- The rail entry and the camera shot changed: new callouts, the brackets re-frame and draw again.
function Scan.setEntry(id, shot)
    entry, shotName = id, shot or 'body'
    if not ui then return end
    list = {}
    for i, c in ipairs((Config.callouts or {})[id] or {}) do
        if i <= MAX and SC.points and SC.points[c.point] then list[#list + 1] = { point = c.point, side = c.side } end
    end
    if on then readPoints() end
    sent.co = {}
    for i = 1, MAX do sent.co[i] = { show = false } end
    ui:batch(function()
        ui:merge('cc', { callouts = calloutModel() })
        for i = 1, MAX do
            ui:class('#co' .. (i - 1), 'gone', true)
            ui:class('#co' .. (i - 1), 'left', list[i] ~= nil and list[i].side ~= 'right')
            sent.co[i].left = list[i] ~= nil and list[i].side ~= 'right'
        end
        calloutsIn()
    end)
end

--- Physical pixels per dp, as last measured (1 before the first measure).
function Scan.pxPerDp()
    return dp.px
end

--- The creator is on screen: start tracking.
function Scan.start(reduced)
    if not ui then return end
    measuring, nextMeasure = true, 0
    ui:watch('#dpref')
    ui:watch('#root')
    ui:class('#scan', 'placed', false)
    if SC.enabled == false then
        ui:class('#scan', 'off', true)
        return
    end
    on, calm, snap = true, reduced == true, true
    sent.frame = nil
    nextPoints = 0
    readPoints()
end

--- The creator closed: nothing runs any more.
function Scan.stop()
    if not measuring then return end
    on, measuring = false, false
    if not ui then return end
    pcall(function()
        ui:unwatch('#dpref')
        ui:unwatch('#root')
    end)
end

--- One frame (called by the session's frame loop, after the camera moved).
function Scan.step(now)
    if not measuring or not ui then return end
    measure(now)
    if not on then return end
    if now >= nextPoints then
        nextPoints = now + num(SC.refreshMs, 1000)
        readPoints()
    end
    ui:batch(function()
        placeFrame()
        placeCallouts()
    end)
end

return Scan
