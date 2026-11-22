-- The creator's camera rig: a shot per category, travels between shots (eased, with a swing and a pull
-- back), Q / E turn, wheel zoom, drag to turn and pan, and a slow idle drift. Runs only while open.

local Camera = {}

local C = Config.camera
local R -- the rig while the creator is open (nil when closed)

local function calm() return Config.reducedMotion == true end

local function smooth(t) return t * t * t * (t * (t * 6 - 15) + 10) end
local function approach(value, target, rate, dt) return value + (target - value) * (1 - math.exp(-rate * dt)) end

local function shotOf(name)
    local shot = Config.shots[name] or Config.shots.body
    return { distance = shot.distance, height = shot.height, look = shot.look, side = shot.side, fov = shot.fov, angle = 0 }
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- The player's frame, read once: the player is frozen while the creator is open, and a new body (a body
-- type change) must not move the shot.
local function frame()
    local o = Open77.character.offsetToWorld(vector3(0, 0, 0))
    local f = Open77.character.offsetToWorld(vector3(0, 1, 0))
    local r = Open77.character.offsetToWorld(vector3(1, 0, 0))
    if not (o and f and r) then return nil end
    return { o = vector3(o), f = vector3(f) - vector3(o), r = vector3(r) - vector3(o) }
end

--- Starts the rig on a shot, with the opening move in from further back.
function Camera.start(shotName)
    local target = shotOf(shotName)
    local start = copy(target)
    if not calm() then
        start.distance = target.distance * C.intro.distance
        start.height = target.height + C.intro.height
        start.angle = C.intro.angle
    end
    R = {
        cur = start, from = copy(start), to = target, t = calm() and 1 or 0, dur = C.intro.seconds,
        swing = 0, lift = 0, side = -1, frame = frame(),
        angle = 0, zoom = 1, zoomTarget = 1, pan = 0, panTarget = 0, turn = 0, turnVelocity = 0,
        touched = GetGameTimer(),
    }
    if calm() then R.cur = copy(target) end
end

--- Travels to another shot (a cut with Config.reducedMotion).
function Camera.travel(shotName)
    if not R then return end
    local to = shotOf(shotName)
    if calm() then
        R.cur, R.from, R.to, R.t = copy(to), copy(to), to, 1
        R.zoomTarget, R.panTarget, R.zoom, R.pan = 1, 0, 1, 0
        if C.resetTurnOnTravel ~= false then R.angle, R.turnVelocity = 0, 0 end
        return
    end
    local covered = math.abs(to.distance - R.cur.distance)
    local amount = math.min(1, covered / 1.4 + math.abs(to.height - R.cur.height) / 0.55)
    local span = C.travelSeconds
    R.from, R.to, R.t = copy(R.cur), to, 0
    R.dur = span.min + (span.max - span.min) * amount
    R.side = -R.side -- one side, then the other
    R.swing = C.swingDegrees * math.max(0.18, amount) * R.side
    R.lift = C.liftRatio * covered
    R.zoomTarget, R.panTarget = 1, 0
    -- The new entry's shot faces the character again (Config.camera.resetTurnOnTravel).
    if C.resetTurnOnTravel ~= false and not R.dragging and R.turn == 0 then R.homing, R.turnVelocity = true, 0 end
end

--- Puts the shot back: the character faces the camera, no zoom, no pan (the recentre key).
function Camera.recentre()
    if not R then return end
    R.zoomTarget, R.panTarget, R.turnVelocity = 1, 0, 0
    if calm() then R.angle, R.zoom, R.pan, R.homing = 0, 1, 0, false else R.homing = true end
    R.touched = GetGameTimer()
end

-- Input ---------------------------------------------------------------------------------

local function touch() if R then R.touched = GetGameTimer() end end

function Camera.turn(direction)
    if not R then return end
    if direction ~= 0 then R.homing = false end
    R.turn = direction
    touch()
end

function Camera.zoom(delta)
    if not R or delta == 0 then return end
    local range = C.zoomRange
    R.zoomTarget = math.max(range[1], math.min(range[2], R.zoomTarget * (1 + C.zoomStep * (delta > 0 and 1 or -1))))
    touch()
end

function Camera.dragStart(x, y)
    if not R then return end
    R.dragging = { x = x, y = y, at = GetGameTimer(), velocity = 0 }
    R.turnVelocity, R.homing = 0, false
    touch()
end

function Camera.dragMove(x, y)
    local d = R and R.dragging
    if not d then return end
    local dx, dy = x - d.x, y - d.y
    if dx == 0 and dy == 0 then return end
    local now = GetGameTimer()
    local turned = -dx * C.dragDegrees
    R.angle = (R.angle + turned) % 360
    R.panTarget = math.max(-C.panLimit, math.min(C.panLimit, R.panTarget + dy * C.panMetres))
    local elapsed = math.max(4, now - d.at) / 1000
    d.velocity = d.velocity + (turned / elapsed - d.velocity) * 0.5
    d.x, d.y, d.at = x, y, now
    touch()
end

-- The turn carries on after a release and eases out (not when the mouse had stopped).
function Camera.dragEnd()
    local d = R and R.dragging
    if not d then return end
    local still = GetGameTimer() - d.at > 120 or calm()
    R.turnVelocity = still and 0 or math.max(-260, math.min(260, d.velocity))
    R.dragging = nil
    touch()
end

-- Frame -----------------------------------------------------------------------------------

--- One step of the rig: the travel, the zoom, the turn, the pan and the idle drift.
function Camera.step(dt, now)
    if not R then return end
    R.swingNow, R.liftNow = 0, 0
    if R.t < 1 then
        R.t = math.min(1, R.t + dt / R.dur)
        local e = smooth(R.t)
        for key, to in pairs(R.to) do R.cur[key] = R.from[key] + (to - R.from[key]) * e end
        local arc = math.sin(math.pi * e)
        R.swingNow, R.liftNow = R.swing * arc, R.lift * arc
    end
    R.zoom = approach(R.zoom, R.zoomTarget, 9, dt)
    R.pan = approach(R.pan, R.panTarget, 10, dt)
    if R.homing then
        -- Back to facing the camera by the shortest way, eased out.
        local signed = ((R.angle + 180) % 360) - 180
        signed = approach(signed, 0, 5, dt)
        if math.abs(signed) < 0.05 then signed, R.homing = 0, false end
        R.angle = signed % 360
    elseif not R.dragging then
        R.turnVelocity = approach(R.turnVelocity, R.turn * C.turnSpeed, R.turn ~= 0 and 8 or 4.5, dt)
        if math.abs(R.turnVelocity) < 0.05 and R.turn == 0 then R.turnVelocity = 0 end
        R.angle = (R.angle + R.turnVelocity * dt) % 360
    end
    local idle = not calm() and R.t >= 1 and R.turn == 0 and not R.dragging and not R.homing and now - R.touched > 1500
    R.drift = approach(R.drift or 0, idle and 1 or 0, 1.2, dt)
    local seconds = now / 1000
    R.driftAngle = C.driftDegrees * R.drift * math.sin(seconds * 0.31)
    R.driftHeight = C.driftHeight * R.drift * math.sin(seconds * 0.43 + 1.3)
end

-- The pose now: on a circle in front of the player, shifted sideways so the character stands between
-- the two panels.
local function pose()
    local fr = R.frame
    local a = math.rad(R.angle + R.cur.angle + (R.swingNow or 0) + (R.driftAngle or 0))
    local d = (R.cur.distance + (R.liftNow or 0)) * R.zoom
    local side = R.cur.side
    local rx, ry = -math.cos(a), math.sin(a)
    local function world(x, y, z) return fr.o + fr.r * x + fr.f * y + vector3(0, 0, z) end
    local position = world(math.sin(a) * d + rx * side, math.cos(a) * d + ry * side, R.cur.height + R.pan + (R.driftHeight or 0))
    local look = world(rx * side, ry * side, R.cur.look + R.pan)
    return position, look, R.cur.fov
end

--- Creates and activates the camera. False while the game refuses it (a new body taking over).
function Camera.place(blendMs)
    if not R then return false end
    R.frame = R.frame or frame()
    if not R.frame then return false end
    local position, look, fov = pose()
    if not R.camera then
        R.camera = Open77.camera.create({ position = position, lookAt = look, fov = fov, thirdPersonBody = true })
        if not R.camera then return false end
    else
        Open77.camera.setTransform(R.camera, { position = position, fov = fov })
        Open77.camera.lookAt(R.camera, look)
    end
    local view = Open77.camera.cameras()
    if not view or view.activeCamera ~= R.camera then
        local ok, why = Open77.camera.activate(R.camera, { blendMs = blendMs or 500 })
        if not ok then
            if tostring(why) == 'camera_not_found' then R.camera = nil end -- created again next try
            return false
        end
    end
    R.stamp = nil
    return true
end

--- Moves the camera to the current pose, only when it changed.
function Camera.push()
    if not R or not R.camera or not R.frame then return end
    local position, look, fov = pose()
    local stamp = ('%.4f %.4f %.4f %.3f %.4f'):format(position.x, position.y, position.z, fov, look.z)
    if stamp == R.stamp then return end
    R.stamp = stamp
    Open77.camera.setTransform(R.camera, { position = position, fov = fov })
    Open77.camera.lookAt(R.camera, look)
end

--- A new body took the old camera with it: drop it (place() makes a new one).
function Camera.drop()
    if not R then return end
    if R.camera then pcall(Open77.camera.destroy, R.camera) end
    R.camera, R.stamp = nil, nil
end

--- False when the game took our shot away (a perspective fallback during a re-dress).
function Camera.active()
    if not R or not R.camera then return false end
    local view = Open77.camera.cameras()
    return view == nil or view.activeCamera == R.camera
end

function Camera.stop()
    if not R then return end
    pcall(Open77.camera.deactivate, { blendMs = C.blendOutMs })
    if R.camera then pcall(Open77.camera.destroy, R.camera) end
    R = nil
end

return Camera
