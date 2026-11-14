-- Remembrall - feasibility probe (UE4SS Lua mod)
--
-- Keys are set in config.lua (defaults: F5 place, Ctrl+F5 clear, F6 flip,
-- Ctrl+F6 reload deck). Revelio flips a card; Leviosa moves one.
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

local okCfg, config = pcall(require, "config")
if not okCfg or type(config) ~= "table" or type(config.keys) ~= "table" then
    C.log("config.lua missing or broken (%s); no keys bound", tostring(config))
    config = { keys = {} }
end

local MODIFIERS = { ctrl = ModifierKey.CONTROL, shift = ModifierKey.SHIFT, alt = ModifierKey.ALT }
local ACTIONS = {
    place = Cards.placeAtCrosshair,
    clear = Cards.clear,
    interact = function() Cards.interact() end,
    reload = Cards.loadDeck,
}

for name, fn in pairs(ACTIONS) do
    local k = config.keys[name]
    if type(k) == "table" and k.key then
        local mods = nil
        for _, m in ipairs(k.mods or {}) do
            local mk = MODIFIERS[tostring(m):lower()]
            if mk then
                mods = mods or {}
                mods[#mods + 1] = mk
            else
                C.log("config: unknown modifier '%s' for %s", tostring(m), name)
            end
        end
        bind(k.key, mods, name, fn)
    else
        C.log("config: no key for %s", name)
    end
end
