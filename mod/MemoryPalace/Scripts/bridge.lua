-- bridge.lua - lets an outside tool (tools/game.py) drive the mod and inspect the game.
--
-- Protocol (one command at a time):
--   tool writes   ipc\cmd.json  { id, t, cmd, args }   (atomically, via rename)
--   we read it on the game thread, delete it, run B.cmds[cmd](args), and write
--                 ipc\res.json  { id, ok, result | err }
-- Commands older than STALE_S seconds are dropped so a leftover file never fires later.

local UEHelpers = require("UEHelpers")
local json = require("lib.json")
local C = require("common")
local Cards = require("cards")

local B = {}
B.POLL_MS = 100
B.STALE_S = 30

local CMD = C.IPC_DIR .. "\\cmd.json"
local RES = C.IPC_DIR .. "\\res.json"
local TMP = RES .. ".tmp"

---------------------------------------------------------------------------
-- Turn any Lua/UE4SS value into something json.encode accepts.
---------------------------------------------------------------------------
local function plain(v, depth, seen)
    depth, seen = depth or 0, seen or {}
    local t = type(v)
    if t == "nil" or t == "boolean" or t == "string" then return v end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
        return v
    end
    if t == "table" then
        if seen[v] then return "<cycle>" end
        if depth >= 6 then return "<table>" end
        seen[v] = true
        local n, count, out = #v, 0, {}
        for _ in pairs(v) do count = count + 1 end
        if n > 0 and n == count then
            for i = 1, n do out[i] = plain(v[i], depth + 1, seen) end
        else
            for k, x in pairs(v) do out[tostring(k)] = plain(x, depth + 1, seen) end
        end
        seen[v] = nil
        return out
    end
    if t == "userdata" then
        local ok, s = pcall(function() return v:GetFullName() end)
        if ok and type(s) == "string" then return s end
        ok, s = pcall(function() return { X = v.X, Y = v.Y, Z = v.Z } end)
        if ok and type(s.X) == "number" then return s end
        ok, s = pcall(function() return { Pitch = v.Pitch, Yaw = v.Yaw, Roll = v.Roll } end)
        if ok and type(s.Yaw) == "number" then return s end
        ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" then return s end
    end
    return tostring(v)
end
B.plain = plain

local function controller()
    local pc = C.player()
    if pc then return pc end
    local ok, any = pcall(UEHelpers.GetPlayerController)
    if ok and C.valid(any) then return any end
    error("no player controller (still loading?)", 0)
end

local function pawnOrError()
    local _, pawn = C.player()
    if not pawn then error("no player pawn (still loading or in a menu?)", 0) end
    return pawn
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
B.cmds = {}

function B.cmds.ping()
    return { pong = true, mod_dir = C.MOD_DIR, time = os.time() }
end

function B.cmds.state()
    local s = {}
    local world = UEHelpers.GetWorld()
    s.world = C.valid(world) and world:GetFullName() or nil
    s.player = C.playerLocation()
    local camLoc, camRot = C.camera()
    if camLoc then s.camera = { loc = camLoc, rot = camRot } end
    pcall(function()
        local r = controller():GetControlRotation()
        s.control_rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
    end)
    s.cards = {}
    for i, e in ipairs(Cards.placed) do
        s.cards[#s.cards + 1] = {
            i = i, id = e.card and e.card.id, side = e.side, loc = e.loc, valid = C.valid(e.actor),
            dist = s.player and math.floor(C.dist(e.loc, s.player)) or nil,
        }
    end
    return s
end

-- Run Lua in the mod's state. Tries `return <code>` first so expressions just work.
-- Globals available: C (common), Cards, Spells, B (bridge), UEHelpers, json, plus _G.
function B.cmds.lua(args)
    local printed = {}
    local env = setmetatable({
        C = C, Cards = Cards, Spells = package.loaded["spells"], B = B, UEHelpers = UEHelpers, json = json,
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
            printed[#printed + 1] = table.concat(parts, "\t")
        end,
    }, { __index = _G })
    local code = tostring(args.code or "")
    local fn, err = load("return " .. code, "=bridge", "t", env)
    if not fn then fn, err = load(code, "=bridge", "t", env) end
    if not fn then error(err, 0) end
    local res = table.pack(xpcall(fn, debug.traceback))
    if not res[1] then error(res[2], 0) end
    local value
    if res.n == 2 then
        value = plain(res[2])
    elseif res.n > 2 then
        value = {}
        for i = 2, res.n do value[i - 1] = res[i] == nil and "nil" or plain(res[i]) end
    end
    return { value = value, printed = printed }
end

function B.cmds.console(args)
    local cmd = tostring(args.command or "")
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(UEHelpers.GetWorld(), cmd, controller())
    return { sent = cmd }
end

function B.cmds.tp(args)
    local pawn = pawnOrError()
    local loc = C.v(args.x, args.y, args.z)
    local ok = false
    pcall(function() ok = pawn:K2_TeleportTo(loc, pawn:K2_GetActorRotation()) end)
    if not ok then ok = pawn:K2_SetActorLocation(loc, false, {}, true) end
    return { ok = ok, player = C.playerLocation() }
end

-- Hogwarts Legacy's camera stack rewrites control rotation every frame, so the view
-- is turned from outside with mouse input (game.py `look`). This reports where the
-- camera points and, given a target (point or placed card), the angles that face it.
function B.cmds.view(args)
    local camLoc, camRot = C.camera()
    if not camLoc then error("no camera yet", 0) end
    local r = { yaw = camRot.Yaw, pitch = camRot.Pitch, cam = camLoc }
    local target
    if args.card then
        local e = Cards.placed[args.card]
        if not e or not C.valid(e.actor) then error("no placed card #" .. tostring(args.card), 0) end
        target = e.loc
    elseif args.x then
        target = C.v(args.x, args.y, args.z)
    end
    if target then
        local d = C.sub(target, camLoc)
        r.want_yaw = C.yawToward(camLoc, target)
        r.want_pitch = math.deg(math.atan(d.Z, math.sqrt(d.X * d.X + d.Y * d.Y)))
        r.target = target
    end
    return r
end

-- Quiesce before a reload: remove the cards, cancel the follow loop, and stop the
-- bridge loop right after replying.
function B.cmds.prepare_reload()
    Cards.clear()
    Cards.stopFollow()
    B.stopAfterReply = true
    return { stopped = true }
end

-- Reload only this mod (RestartCurrentMod) instead of UE4SS Ctrl+R. A second Ctrl+R
-- in one session crashed the game twice (heap corruption c0000374 while UE4SS was
-- stopping BPModLoaderMod, 2026-11-14), even with all our loops stopped.
function B.cmds.restart()
    if type(RestartCurrentMod) ~= "function" then error("RestartCurrentMod not available", 0) end
    B.cmds.prepare_reload()
    B.restartAfterReply = true
    return { restarting = true }
end

-- Stand `dist` cm from placed card i, on the side the player is already on.
-- game.py then turns the camera onto it with `view`.
function B.cmds.goto_card(args)
    local e = Cards.placed[args.i or 1]
    if not e or not C.valid(e.actor) then error("no placed card #" .. tostring(args.i), 0) end
    local dist = args.dist or 250
    local here = C.playerLocation() or C.add(e.loc, C.v(-dist, 0, 0))
    local dir = C.sub(here, e.loc)
    dir.Z = 0
    dir = C.norm(dir)
    if C.len(dir) < 0.5 then dir = C.v(-1, 0, 0) end
    local spot = C.add(e.loc, C.scale(dir, dist))
    spot.Z = e.loc.Z + (args.dz or 40)
    local r = B.cmds.tp({ x = spot.X, y = spot.Y, z = spot.Z })
    r.card = { i = args.i or 1, id = e.card and e.card.id, loc = e.loc }
    return r
end

---------------------------------------------------------------------------
-- Polling loop (game thread; see the LoopAsync warning in cards.lua)
---------------------------------------------------------------------------
local function readCmd()
    local f = io.open(CMD, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    os.remove(CMD)
    local ok, cmd = pcall(json.decode, text)
    if not ok or type(cmd) ~= "table" then return { cmd = "?", bad = tostring(cmd) } end
    return cmd
end

local function respond(r)
    local ok, text = pcall(json.encode, r)
    if not ok then text = json.encode({ id = r.id, ok = false, err = "encode failed: " .. tostring(text) }) end
    local f = io.open(TMP, "w")
    if not f then return C.log("bridge: cannot write %s", TMP) end
    f:write(text)
    f:close()
    os.remove(RES)
    os.rename(TMP, RES)
end

function B.tick()
    local cmd = readCmd()
    if not cmd then return end
    local r = { id = cmd.id }
    if cmd.bad then
        r.ok, r.err = false, "bad command json: " .. cmd.bad
    elseif type(cmd.t) == "number" and os.time() - cmd.t > B.STALE_S then
        C.log("bridge: dropped stale command %s", tostring(cmd.cmd))
        return
    else
        local handler = B.cmds[cmd.cmd]
        if not handler then
            r.ok, r.err = false, "unknown command " .. tostring(cmd.cmd)
        else
            local ok, res = pcall(handler, type(cmd.args) == "table" and cmd.args or {})
            r.ok = ok
            if ok then r.result = plain(res) else r.err = tostring(res) end
        end
    end
    respond(r)
    if B.stopAfterReply then
        B.stopAfterReply = false
        B.stop()
    end
    if B.restartAfterReply then
        B.restartAfterReply = false
        C.log("bridge: RestartCurrentMod")
        RestartCurrentMod()
    end
end

local handle = nil
function B.stop()
    if handle then
        pcall(CancelDelayedAction, handle)
        handle = nil
    end
    C.log("bridge: stopped (ready for hot reload)")
end

function B.start()
    if handle then return end
    os.remove(CMD) -- never run something left over from a previous session
    handle = LoopInGameThreadWithDelay(B.POLL_MS, function()
        local ok, err = pcall(B.tick)
        if not ok then C.log("bridge tick error: %s", tostring(err)) end
    end)
    C.log("bridge: listening on %s", CMD)
end

return B
