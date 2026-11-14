-- config.lua - settings you may want to change.
--
-- Keys: other mods can use the same keys. If one clashes, change it here and
-- restart the game (or run `python tools/game.py reload`).
--   key  = a UE4SS key name: "F1".."F12", "A".."Z", "ONE".."NINE", "NUM_ONE", "INS", "HOME", ...
--   mods = optional list of "ctrl", "shift", "alt"
return {
    keys = {
        place    = { key = "F5" },                    -- place the next card at the crosshair
        clear    = { key = "F5", mods = { "ctrl" } }, -- remove every card this mod spawned
        interact = { key = "F6" },                    -- flip the card you are looking at
        reload   = { key = "F6", mods = { "ctrl" } }, -- reload ipc\cards.json
    },
}
