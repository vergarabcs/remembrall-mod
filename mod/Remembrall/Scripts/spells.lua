-- spells.lua - drive cards with in-game spells.
--
-- Wingardium Leviosa needs nothing here: cards are weightless physics objects and the
-- game's own Leviosa moves them. This module maps other spells to card actions by
-- hooking SpellTool:Start and reading the spell's Blueprint class name.
--
-- Spell classes seen so far: BP_RevelioSpell_C, BP_WingardiumSpell_C,
-- BP_StupefySpell_C, BP_AccioSpell_C. Every new one is logged once.

local C = require("common")
local Cards = require("cards")

local S = {}

-- spell class name (lowercased substring) -> card action
S.actions = {
    revelio = "advance", -- closed -> question -> answer -> closed
}

-- Revelio is cast without a target, so be generous: the card nearest the crosshair
-- within this range and angle is the one that flips.
S.config = {
    range = 900,      -- cm from the player
    maxAngle = 35,    -- degrees from the camera's view direction
}

local seen = {}

local function spellClass(ctx)
    local name = "?"
    pcall(function() name = ctx:get():GetClass():GetFName():ToString() end)
    return name
end

local function onSpell(cls)
    local lower = cls:lower()
    for key, action in pairs(S.actions) do
        if lower:find(key, 1, true) then
            if action == "advance" then
                Cards.interact({
                    range = S.config.range,
                    dot = math.cos(math.rad(S.config.maxAngle)),
                    source = cls,
                    quiet = true,
                })
            end
            return
        end
    end
end

function S.install()
    local ok, err = pcall(RegisterHook, "/Script/Phoenix.SpellTool:Start", function(ctx)
        local cls = spellClass(ctx)
        if not seen[cls] then
            seen[cls] = true
            C.log("spell class seen: %s", cls)
        end
        ExecuteInGameThread(function()
            local ok2, e = pcall(onSpell, cls)
            if not ok2 then C.log("spell action error: %s", tostring(e)) end
        end)
    end)
    C.log("spell hook: %s", ok and "registered" or tostring(err))
end

return S
