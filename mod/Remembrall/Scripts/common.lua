-- common.lua - shared helpers: logging, IPC, vector math, traces, spawning.
-- Every engine call is wrapped so a failure is logged instead of crashing the probe.

local UEHelpers = require("UEHelpers")
local json = require("lib.json")

local C = {}
C.TAG = "[Remembrall] "

function C.log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(C.TAG .. (ok and msg or tostring(fmt)) .. "\n")
end

---------------------------------------------------------------------------
-- Paths. UE4SS runs with cwd = Phoenix/Binaries/Win64, and script sources
-- look like "@ue4ss\Mods\Remembrall\Scripts\common.lua".
---------------------------------------------------------------------------
local src = debug.getinfo(1, "S").source:gsub("^@", "")
C.SCRIPTS_DIR = src:match("^(.*)[/\\][^/\\]+$") or "."
C.MOD_DIR = C.SCRIPTS_DIR:match("^(.*)[/\\][^/\\]+$") or "."
C.IPC_DIR = C.MOD_DIR .. "\\ipc"

---------------------------------------------------------------------------
-- IPC: Lua -> companion is an append-only JSON-lines file.
---------------------------------------------------------------------------
function C.emit(evt)
    evt.t = os.time()
    local ok, line = pcall(json.encode, evt)
    if not ok then
        C.log("emit: json encode failed: %s", tostring(line))
        return
    end
    local f = io.open(C.IPC_DIR .. "\\events.jsonl", "a")
    if not f then
        C.log("emit: cannot open %s\\events.jsonl (does the ipc folder exist?)", C.IPC_DIR)
        return
    end
    f:write(line .. "\n")
    f:close()
end

function C.readJson(name)
    local f = io.open(C.IPC_DIR .. "\\" .. name, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(json.decode, text)
    if not ok then
        C.log("readJson(%s) failed: %s", name, tostring(data))
        return nil
    end
    return data
end

function C.writeJson(name, data)
    local ok, text = pcall(json.encode, data)
    if not ok then return false end
    local f = io.open(C.IPC_DIR .. "\\" .. name, "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

---------------------------------------------------------------------------
-- Vectors are plain Lua tables {X,Y,Z}; engine structs are copied out.
---------------------------------------------------------------------------
function C.v(x, y, z) return { X = x, Y = y, Z = z } end
function C.tov(u) return { X = u.X, Y = u.Y, Z = u.Z } end
function C.add(a, b) return C.v(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
function C.sub(a, b) return C.v(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
function C.scale(a, s) return C.v(a.X * s, a.Y * s, a.Z * s) end
function C.dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
function C.len(a) return math.sqrt(C.dot(a, a)) end
function C.dist(a, b) return C.len(C.sub(a, b)) end
function C.norm(a)
    local l = C.len(a)
    if l < 1e-6 then return C.v(0, 0, 0) end
    return C.scale(a, 1 / l)
end
function C.fmt(a) return string.format("(%.0f, %.0f, %.0f)", a.X, a.Y, a.Z) end

function C.forward(rot)
    local p, y = math.rad(rot.Pitch), math.rad(rot.Yaw)
    return C.v(math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p))
end

-- Yaw (degrees) that makes an actor's +X axis point from `from` toward `to`.
function C.yawToward(from, to)
    return math.deg(math.atan(to.Y - from.Y, to.X - from.X))
end

---------------------------------------------------------------------------
-- Player / camera
---------------------------------------------------------------------------
function C.valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

-- Cached: UEHelpers.GetPlayerController scans every controller on each call, which is
-- slow at 20 Hz and can trip over half-destroyed objects during level transitions.
local cachedPC = nil
function C.player()
    if not C.valid(cachedPC) then
        cachedPC = nil
        local ok, pc = pcall(UEHelpers.GetPlayerController)
        if ok and C.valid(pc) then cachedPC = pc end
    end
    local pc = cachedPC
    if not pc then return nil end
    local pawn = pc.Pawn
    if not C.valid(pawn) then return nil end
    return pc, pawn
end

function C.playerLocation()
    local _, pawn = C.player()
    if not pawn then return nil end
    return C.tov(pawn:K2_GetActorLocation())
end

function C.camera()
    local pc = C.player()
    if not pc then return nil end
    local cm = pc.PlayerCameraManager
    local rot = cm:GetCameraRotation()
    return C.tov(cm:GetCameraLocation()), { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }
end

---------------------------------------------------------------------------
-- Traces (ETraceTypeQuery 0 = Visibility in most UE projects)
---------------------------------------------------------------------------
local NOCOLOR = { R = 0, G = 0, B = 0, A = 0 }

local function hitInfo(hit)
    local info = {}
    pcall(function() info.point = C.tov(hit.ImpactPoint) end)
    pcall(function() info.normal = C.tov(hit.ImpactNormal) end)
    pcall(function()
        local a = hit.Actor:Get()
        if C.valid(a) then info.actor = a:GetFullName() end
    end)
    return info
end

function C.lineTrace(start, finish)
    local _, pawn = C.player()
    if not pawn then return false end
    local hit = {}
    local ok, wasHit = pcall(function()
        return UEHelpers.GetKismetSystemLibrary():LineTraceSingle(
            pawn, start, finish, 0, false, {}, 0, hit, true, NOCOLOR, NOCOLOR, 0.0)
    end)
    if not ok then
        C.log("lineTrace error: %s", tostring(wasHit))
        return false
    end
    if wasHit then return true, hitInfo(hit) end
    return false
end

function C.sphereTrace(start, finish, radius)
    local _, pawn = C.player()
    if not pawn then return false end
    local hit = {}
    local ok, wasHit = pcall(function()
        return UEHelpers.GetKismetSystemLibrary():SphereTraceSingle(
            pawn, start, finish, radius, 0, false, {}, 0, hit, true, NOCOLOR, NOCOLOR, 0.0)
    end)
    if not ok then
        C.log("sphereTrace error: %s", tostring(wasHit))
        return false
    end
    if wasHit then return true, hitInfo(hit) end
    return false
end

---------------------------------------------------------------------------
-- Spawning
---------------------------------------------------------------------------
function C.spawn(classPath, loc, rot)
    local world = UEHelpers.GetWorld()
    if not C.valid(world) then return nil, "no world" end
    local cls = StaticFindObject(classPath)
    if not C.valid(cls) then return nil, "class not found: " .. classPath end
    rot = rot or { Pitch = 0, Yaw = 0, Roll = 0 }
    local ok, actor = pcall(function() return world:SpawnActor(cls, loc, rot) end)
    if not ok then return nil, "SpawnActor error: " .. tostring(actor) end
    if not C.valid(actor) then return nil, "SpawnActor returned invalid actor" end
    -- Some UE4SS builds ignore table args to SpawnActor; force the transform.
    pcall(function() actor:K2_SetActorLocationAndRotation(loc, rot, false, {}, false) end)
    return actor
end

function C.destroy(actor)
    if C.valid(actor) then pcall(function() actor:K2_DestroyActor() end) end
end

-- Find (or load) an asset by full object path.
function C.findAsset(path)
    local o = StaticFindObject(path)
    if C.valid(o) then return o end
    pcall(function() LoadAsset(path) end)
    o = StaticFindObject(path)
    if C.valid(o) then return o end
    return nil
end

-- Make an FText from a Lua string, trying the UE4SS constructor first.
function C.text(s)
    if type(FText) == "function" then
        local ok, t = pcall(FText, s)
        if ok and t then return t end
    end
    return UEHelpers.GetKismetTextLibrary():Conv_StringToText(s)
end

return C
