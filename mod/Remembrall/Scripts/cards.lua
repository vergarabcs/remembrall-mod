-- cards.lua - Unknowns #1 and #2.
--   #1: can we spawn a visible placeholder object at runtime with no custom assets?
--   #2: can that object show a flashcard and trigger audio when you interact with it?
--
-- Placeholder = StaticMeshActor (engine mesh, or a borrowed in-game book mesh)
--             + PointLight (so it is findable)
--             + TextRenderActor (floating text above it, in world space).
-- Interaction = press the interact key while near and looking at a card.
-- Display     = in-world TextRender and the game's own subtitle line.
-- Audio       = event sent to the Python companion, which speaks the text.

local C = require("common")

local M = {}

M.config = {
    interactRange = 400,   -- cm from the player character
    interactDot = 0.5,     -- cos of max angle between camera view and the card (60 deg)
    meshScale = 0.35,
    textWorldSize = 14,
    textLineChars = 38,
    -- Physics makes cards targetable by the game's own spells (Leviosa, Accio, ...).
    -- Gravity is off so a card floats where you let go of it.
    physics = true,
    massKg = 2.0,
    linearDamping = 4.0,
    angularDamping = 4.0,
    labelOffset = 45,
    lightOffset = 60,
}

-- Tried in order. /Engine/BasicShapes ships with most cooked UE4 games.
local MESH_CANDIDATES = {
    "/Engine/BasicShapes/Cube.Cube",
    "/Engine/BasicShapes/Sphere.Sphere",
    "/Engine/BasicShapes/Cylinder.Cylinder",
    "/Engine/EngineMeshes/Cube.Cube",
    "/Engine/EngineMeshes/Sphere.Sphere",
}

M.placed = {}     -- { actor, light, label, card, loc, side }
local deck = nil
local nextCard = 1
local meshCache = nil

---------------------------------------------------------------------------
-- Mesh discovery
---------------------------------------------------------------------------
local function findBookMesh()
    local all = FindAllOf("StaticMesh")
    if not all then return nil end
    local samples = {}
    for _, m in ipairs(all) do
        local ok, name = pcall(function() return m:GetFullName() end)
        if ok and name and name:lower():find("book") then
            if #samples < 10 then samples[#samples + 1] = name end
            if not meshCache then meshCache = { mesh = m, path = name } end
        end
    end
    C.log("Loaded StaticMeshes: %d; book-like sample: %s", #all, table.concat(samples, " | "))
    return meshCache
end

local function getMesh()
    if meshCache and C.valid(meshCache.mesh) then return meshCache end
    meshCache = nil
    for _, path in ipairs(MESH_CANDIDATES) do
        local m = C.findAsset(path)
        C.log("mesh candidate %s -> %s", path, m and "OK" or "missing")
        if m then
            meshCache = { mesh = m, path = path }
            return meshCache
        end
    end
    C.log("No engine mesh available, falling back to an already-loaded book mesh")
    return findBookMesh()
end

---------------------------------------------------------------------------
-- Text helpers
---------------------------------------------------------------------------
local function wrap(s, width)
    local lines, line = {}, ""
    for word in s:gmatch("%S+") do
        if #line + #word + 1 > width and #line > 0 then
            lines[#lines + 1] = line
            line = word
        else
            line = (#line > 0) and (line .. " " .. word) or word
        end
    end
    if #line > 0 then lines[#lines + 1] = line end
    return table.concat(lines, "<br>") -- TextRender line break
end

local function setLabel(entry, s)
    if not C.valid(entry.label) then return false end
    local ok, err = pcall(function()
        entry.label.TextRender:K2_SetText(C.text(wrap(s, M.config.textLineChars)))
    end)
    if not ok then C.log("TextRender SetText failed: %s", tostring(err)) end
    return ok
end

local function showSubtitle(s)
    local subs = FindFirstOf("Subtitles")
    if not C.valid(subs) then
        C.log("Subtitles object not found (it may only exist once the HUD is up)")
        return false
    end
    local ok, err = pcall(function()
        subs:BPRemoveStandaloneSubtitle()
        if s and s ~= "" then subs:BPAddStandaloneSubtitle(s) end
    end)
    if not ok then C.log("Subtitle failed: %s", tostring(err)) end
    return ok
end

---------------------------------------------------------------------------
-- Deck
---------------------------------------------------------------------------
local DEMO = {
    { id = "demo-1", cluster = "demo", front = "What is the method of loci?",
      back = "A memory technique: place images of what you want to remember along a familiar route, then walk it in your mind." },
}

function M.loadDeck()
    local data = C.readJson("cards.json")
    if type(data) == "table" and type(data.cards) == "table" and #data.cards > 0 then
        deck = data.cards
        C.log("Loaded %d cards from ipc\\cards.json", #deck)
    else
        deck = DEMO
        C.log("ipc\\cards.json missing or empty; using the built-in demo card")
    end
    nextCard = 1
end

---------------------------------------------------------------------------
-- Unknown #1: spawn a placeholder
---------------------------------------------------------------------------
function M.spawnPlaceholder(loc, card, facing)
    local report = { type = "probe_spawn", loc = loc, card_id = card and card.id }

    local actor, err = C.spawn("/Script/Engine.StaticMeshActor", loc, { Pitch = 0, Yaw = facing or 0, Roll = 0 })
    report.actor_ok = actor ~= nil
    report.actor_err = err
    if not actor then
        C.log("U1 FAIL: could not spawn StaticMeshActor: %s", tostring(err))
        C.emit(report)
        return nil
    end

    local mesh = getMesh()
    report.mesh = mesh and mesh.path or nil
    if mesh then
        local ok, e = pcall(function()
            local smc = actor.StaticMeshComponent
            smc:SetMobility(2) -- Movable; static components refuse runtime mesh changes
            report.set_mesh = smc:SetStaticMesh(mesh.mesh)
            local s = M.config.meshScale
            actor:SetActorScale3D(C.v(s, s, s))
            actor:SetActorEnableCollision(M.config.physics)
        end)
        if not ok then report.mesh_err = tostring(e) end
    end

    local light = C.spawn("/Script/Engine.PointLight", C.add(loc, C.v(0, 0, M.config.lightOffset)))
    report.light_ok = light ~= nil
    if light then
        pcall(function()
            local lc = light.LightComponent
            lc:SetMobility(2)
            lc:SetIntensity(8000)
            lc:SetLightColor({ R = 1.0, G = 0.8, B = 0.45, A = 1.0 }, true)
            lc:SetAttenuationRadius(350)
        end)
    end

    local label, lerr = C.spawn("/Script/Engine.TextRenderActor", C.add(loc, C.v(0, 0, M.config.labelOffset)),
        { Pitch = 0, Yaw = facing or 0, Roll = 0 })
    report.text_ok = label ~= nil
    report.text_err = lerr
    if label then
        pcall(function()
            local tr = label.TextRender
            tr:SetMobility(2)
            tr:SetHorizontalAlignment(1) -- center
            tr:SetVerticalAlignment(2)   -- bottom: text grows upward
            tr:SetWorldSize(M.config.textWorldSize)
            tr:SetTextRenderColor({ R = 255, G = 225, B = 150, A = 255 })
        end)
    end

    local entry = { actor = actor, light = light, label = label, card = card, loc = loc, side = "closed" }
    M.placed[#M.placed + 1] = entry
    report.label_set = setLabel(entry, card and ("[" .. (card.cluster or "card") .. "]") or "?")
    report.physics = M.setPhysics(entry, true)
    M.startFollow()

    C.log("U1 spawn at %s: actor=%s mesh=%s setMesh=%s light=%s text=%s label=%s physics=%s",
        C.fmt(loc), tostring(report.actor_ok), tostring(report.mesh), tostring(report.set_mesh),
        tostring(report.light_ok), tostring(report.text_ok), tostring(report.label_set), tostring(report.physics))
    C.emit(report)
    return entry
end

---------------------------------------------------------------------------
-- Physics + following: the cube is the "real" object; label and light follow it.
---------------------------------------------------------------------------
function M.setPhysics(e, on)
    if not M.config.physics or not C.valid(e.actor) then return false end
    local ok, err = pcall(function()
        local smc = e.actor.StaticMeshComponent
        if on then
            e.actor:SetActorEnableCollision(true)
            pcall(function() smc:SetCollisionProfileName(FName("PhysicsActor"), true) end)
            smc:SetEnableGravity(false)
            smc:SetLinearDamping(M.config.linearDamping)
            smc:SetAngularDamping(M.config.angularDamping)
            pcall(function() smc:SetMassOverrideInKg(FName("None"), M.config.massKg, true) end)
            smc:SetSimulatePhysics(true)
        else
            smc:SetSimulatePhysics(false)
        end
    end)
    if not ok then C.log("setPhysics(%s) failed: %s", tostring(on), tostring(err)) end
    return ok
end

function M.savePlacements()
    local out = {}
    for _, e in ipairs(M.placed) do
        if C.valid(e.actor) and e.card then
            out[#out + 1] = { id = e.card.id, cluster = e.card.cluster, X = e.loc.X, Y = e.loc.Y, Z = e.loc.Z }
        end
    end
    C.writeJson("placements.json", { placements = out })
end

function M.followTick()
    local now = os.time()
    local settled = false
    local camLoc = C.camera()
    for _, e in ipairs(M.placed) do
        if C.valid(e.actor) then
            local ok, p = pcall(function() return C.tov(e.actor:K2_GetActorLocation()) end)
            if ok and C.dist(p, e.loc) > 2 then
                e.loc, e.movedAt, e.dirty = p, now, true
                local yaw = camLoc and C.yawToward(p, camLoc) or 0
                if C.valid(e.label) then
                    pcall(function()
                        e.label:K2_SetActorLocationAndRotation(C.add(p, C.v(0, 0, M.config.labelOffset)),
                            { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
                    end)
                end
                if C.valid(e.light) then
                    pcall(function()
                        e.light:K2_SetActorLocation(C.add(p, C.v(0, 0, M.config.lightOffset)), false, {}, true)
                    end)
                end
            elseif ok and e.dirty and now - (e.movedAt or now) >= 1 then
                e.dirty = false
                settled = true
                C.emit({ type = "card_moved", card_id = e.card and e.card.id, loc = e.loc })
            end
        end
    end
    if settled then M.savePlacements() end
end

-- Runs ON the game thread. Do not use LoopAsync here: it runs Lua on a second OS
-- thread against the same Lua state, which corrupted memory and crashed the game
-- after a few minutes (2026-11-11, UE4SS.dll+0x920456).
local followHandle = nil
function M.startFollow()
    if followHandle then return end
    followHandle = LoopInGameThreadWithDelay(50, function()
        local ok, err = pcall(M.followTick)
        if not ok then C.log("followTick error: %s", tostring(err)) end
    end)
end

-- Must run before a UE4SS hot reload (see bridge.cmds.prepare_reload).
function M.stopFollow()
    if followHandle then
        pcall(CancelDelayedAction, followHandle)
        followHandle = nil
    end
end

-- F5: place the next card from the deck where the crosshair points.
function M.placeAtCrosshair()
    if not deck then M.loadDeck() end
    local camLoc, camRot = C.camera()
    if not camLoc then return C.log("No player/camera yet") end
    local fwd = C.forward(camRot)
    local hit, info = C.lineTrace(camLoc, C.add(camLoc, C.scale(fwd, 1500)))
    local loc
    if hit and info.point then
        local n = info.normal or C.v(0, 0, 1)
        loc = C.add(info.point, C.scale(n, 35))
    else
        loc = C.add(camLoc, C.scale(fwd, 400))
    end
    local card = deck[((nextCard - 1) % #deck) + 1]
    nextCard = nextCard + 1
    M.spawnPlaceholder(loc, card, C.yawToward(loc, camLoc))
end

---------------------------------------------------------------------------
-- Unknown #2: interact -> display + audio
---------------------------------------------------------------------------
-- Distance is measured from the player character (the third-person camera sits
-- several metres behind it); "looking at" uses the camera's view direction.
local function targetedEntry(range, minDot)
    local camLoc, camRot = C.camera()
    local playerLoc = C.playerLocation()
    if not camLoc or not playerLoc then return nil end
    local fwd = C.forward(camRot)
    local best, bestScore, nearest
    for _, e in ipairs(M.placed) do
        if C.valid(e.actor) then
            local d = C.dist(e.loc, playerLoc)
            local facing = C.dot(C.norm(C.sub(e.loc, camLoc)), fwd)
            if not nearest or d < nearest.d then nearest = { d = d, facing = facing } end
            if d <= range and facing >= minDot then
                local score = facing - d / 10000
                if not bestScore or score > bestScore then best, bestScore = e, score end
            end
        end
    end
    if not best and nearest then
        C.log("Interact miss: nearest card %.0f cm away (limit %d), view angle %.0f deg (limit %.0f)",
            nearest.d, range, math.deg(math.acos(math.max(-1, math.min(1, nearest.facing)))),
            math.deg(math.acos(minDot)))
    end
    return best
end

-- F6 or a mapped spell: closed -> front -> back -> closed.
-- opts: range, dot (targeting overrides), source (for logs), quiet (no log on miss).
function M.interact(opts)
    opts = opts or {}
    local e = targetedEntry(opts.range or M.config.interactRange, opts.dot or M.config.interactDot)
    if not e then
        if not opts.quiet then C.log("Interact: no card in range/in view (%d placed)", #M.placed) end
        return
    end
    local card = e.card or DEMO[1]
    local text
    if e.side == "closed" then
        e.side, text = "front", card.front
    elseif e.side == "front" then
        e.side, text = "back", card.back
    else
        e.side, text = "closed", nil
    end

    local labelOk = setLabel(e, text or ("[" .. (card.cluster or "card") .. "]"))
    local subOk = showSubtitle(text and ((e.side == "front" and "Q: " or "A: ") .. text) or nil)

    -- Turn the label to face the player each time it is read.
    pcall(function()
        local camLoc = C.camera()
        e.label:K2_SetActorRotation({ Pitch = 0, Yaw = C.yawToward(e.loc, camLoc), Roll = 0 }, false)
    end)

    C.log("U2 interact card=%s side=%s via=%s textRender=%s subtitle=%s", tostring(card.id), e.side,
        opts.source or "F6", tostring(labelOk), tostring(subOk))
    C.emit({
        type = "card_open", card_id = card.id, side = e.side, text = text or "", via = opts.source or "F6",
        loc = e.loc, player = C.playerLocation(),
        text_render_ok = labelOk, subtitle_ok = subOk,
    })
end

function M.clear()
    for _, e in ipairs(M.placed) do
        C.destroy(e.actor); C.destroy(e.light); C.destroy(e.label)
    end
    M.placed = {}
    showSubtitle(nil)
    C.log("Cleared all placeholders")
end

return M
