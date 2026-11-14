-- Remembrall - feasibility probe (UE4SS Lua mod)
--
--   F5          place next flashcard at crosshair
--   Revelio     flip the card you are looking at (or press F6)
--   Leviosa     move a card; it floats where you let go (native game spell)
--   Ctrl+F5     remove everything this mod spawned
--   Ctrl+F6     reload ipc\cards.json
--
-- Results go to UE4SS.log (lines tagged [Remembrall]) and ipc\events.jsonl.

local C = require("common")
local Cards = require("cards")
local Spells = require("spells")

C.log("loaded. Mod dir: %s", C.MOD_DIR)
C.emit({ type = "mod_loaded", mod_dir = C.MOD_DIR })

local function safe(name, fn)
    return function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then
                C.log("%s failed: %s", name, tostring(err))
                C.emit({ type = "error", where = name, err = tostring(err) })
            end
        end)
    end
end

-- Register one binding; a bad key name only loses that binding.
local function bind(keyName, mods, name, fn)
    local ok, err = pcall(function()
        local key = Key[keyName]
        if not key then error("unknown key " .. keyName) end
        if mods then RegisterKeyBind(key, mods, safe(name, fn)) else RegisterKeyBind(key, safe(name, fn)) end
    end)
    if not ok then C.log("keybind %s (%s) not registered: %s", keyName, name, tostring(err)) end
end

pcall(Spells.install)

-- Remote control for tools/game.py (state, Lua eval, console, teleport, camera angles).
local okBridge, errBridge = pcall(function() require("bridge").start() end)
if not okBridge then C.log("bridge not started: %s", tostring(errBridge)) end

local CTRL = { ModifierKey.CONTROL }
bind("F5", nil, "place", Cards.placeAtCrosshair)
bind("F5", CTRL, "clear", Cards.clear)
bind("F6", nil, "interact", function() Cards.interact() end)
bind("F6", CTRL, "reload", Cards.loadDeck)
