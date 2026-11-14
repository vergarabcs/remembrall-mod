---
name: test-in-game
description: API reference for seeing and controlling the running Hogwarts Legacy game from the terminal through tools/game.py and the mod's bridge. Covers screenshots, keys and mouse, camera, teleport, running Lua inside the mod, console commands, reloading the mod and reading its logs. Use it whenever you need to check a Memory Palace mod or companion change in game, take or read a game screenshot, drive the player or menus, or inspect live game state, even if the user only says "test it", "try it" or "does it work".
---

# Controlling the game: tools/game.py + bridge.lua

Two channels, both used through `python tools/game.py <command>` from the repo root:

- **Bridge** (mod side). The tool writes `mod/MemoryPalace/ipc/cmd.json`
  `{id, t, cmd, args}`. `Scripts/bridge.lua` polls it every 100 ms on the game thread,
  deletes it, runs `B.cmds[cmd](args)` and writes `ipc/res.json` `{id, ok, result|err}`.
  It runs one command at a time and drops commands older than 30 s. It works with the
  game in the background.
- **Windows** (outside the game). Window capture, `SendInput` keys and mouse, and focusing
  the game window. Input needs the game in front, so input commands focus it first and
  take focus away from the user's editor.

When a bridge command fails, the tool exits non-zero with `mod error: <message + Lua traceback>`.
If the mod doesn't answer, it reports that the game isn't running, is still loading, or the mod isn't loaded.

## game.py commands

| Command | Channel | Does / returns |
|---|---|---|
| `start` [`--save NAME`] [`--stay`] | Steam + bridge + key | into the world at the courtyard test spot (see below) |
| `quit` | bridge | closes the game and waits for the process to exit |
| `ping` | bridge | `{pong, mod_dir, time}` |
| `state` | bridge | `{world, player{X,Y,Z}, camera{loc,rot}, control_rot, cards[{i,id,side,loc,valid,dist}]}` |
| `lua "<code>"` [`--timeout S`] | bridge | runs Lua inside the mod; prints `print()` output, then the returned value as JSON (see below) |
| `console "<cmd>"` | bridge | UE console command via `KismetSystemLibrary.ExecuteConsoleCommand` → `{sent}` |
| `tp X Y Z` [`--yaw --pitch`] | bridge (+mouse for yaw/pitch) | `K2_TeleportTo` (falls back to `K2_SetActorLocation`) → `{ok, player}` |
| `look --yaw Y --pitch P` / `--card N` / `--at x,y,z` | bridge + mouse | turns the camera in a closed loop (within ~1°) → final `view` result |
| `goto-card N` [`--dist cm`] | bridge + mouse | stands `dist` cm from placed card N and looks at it |
| `shot` [`--crop x,y,w,h`] [`--width 1600`] [`--method auto\|screen\|window`] [`--focus`] [`--out PATH`] | Windows | saves `ipc/shots/shot.png` and prints the path; then **Read** it |
| `key COMBO...` [`--hold ms` (200)] [`--gap ms`] | Windows | e.g. `key F5`, `key ctrl+F5`, `key w --hold 1500`, `key esc enter` |
| `mouse DX DY` [`--steps`] | Windows | relative move (raw input, so it turns the camera) |
| `click [left\|right]` [`--at fx,fy`] [`--hold ms`] | Windows | `--at` moves the cursor to a fraction of the frame first (menus) |
| `focus` | Windows | brings the game to the front |
| `wait ["<lua expr>"]` [`--timeout --interval`] | bridge | polls until the expression is truthy and prints it; with no expression, waits until `phase` is `world` |
| `reload` [`--all` [`--force`]] | bridge | restarts only this mod (`RestartCurrentMod`) and waits for the bridge; `--all` = UE4SS Ctrl+R |
| `log` [`-n N`] [`--all`] | file | tail of UE4SS.log (`[MemoryPalace]` lines unless `--all`) |
| `launch` [`--timeout S`] | Steam + bridge | only starts the game and waits until the bridge answers (title screen); prefer `start` |

Key names: `a`–`z`, `0`–`9`, `f1`–`f24`, `ctrl shift alt space enter esc tab backspace
up down left right insert delete home end pageup pagedown`, and `` ` - = [ ] ; ' , . / \ ``.
Combine them with `+`.

`shot` notes: with the game in front, `screen` grabs that area of the screen, UI included. In
the background, `window` uses PrintWindow, which also works. `--crop` takes fractions of the
full frame and is how you read small text. The game's own `shot`/`HighResShot` commands write
nothing in this build.

## The `lua` command

The code runs in the mod's Lua state on the game thread, so it can do anything the mod can.
It is tried as `return <code>` first, so a bare expression works; otherwise it runs as statements.

In scope: `C` (common.lua), `Cards` (cards.lua), `Spells` (spells.lua), `B` (bridge.lua),
`UEHelpers`, `json`, all UE4SS globals (`FindFirstOf`, `FindAllOf`, `StaticFindObject`,
`RegisterHook`, ...), and `_G`. `print` is captured and returned.

Return values are converted for JSON: tables recursively (depth 6), UObjects to their
`GetFullName()`, vector-like structs to `{X,Y,Z}`, rotators to `{Pitch,Yaw,Roll}`, FString/FName/FText
to strings, and anything else to `tostring`. Several return values come back as a list.
Errors include a traceback.

Useful mod functions:

- **C:** `player()` → pc, pawn · `playerLocation()` · `camera()` → loc, rot ·
  `lineTrace(a,b)` / `sphereTrace(a,b,r)` → hit, {point,normal,actor} · `spawn(classPath, loc, rot)` ·
  `destroy(a)` · `findAsset(path)` · `log(fmt,...)` · `emit(evt)` (events.jsonl) ·
  `readJson/writeJson(name)` (ipc folder) · vector maths `v add sub scale dot len dist norm forward yawToward`
· `valid(o)`
- **Cards:** `placed` (list of `{actor,light,label,card,loc,side}`) · `placeAtCrosshair()` ·
  `interact(opts)` (flip the targeted card; opts `range, dot, source, quiet`) · `clear()` ·
  `loadDeck()` · `spawnPlaceholder(loc, card, yaw)` · `config` · `savePlacements()`
- **B:** `cmds` (the command table) · `plain(v)` (the JSON conversion)

Examples:
```bash
python tools/game.py lua "return C.playerLocation()"
python tools/game.py lua "Cards.placeAtCrosshair(); return #Cards.placed"
python tools/game.py lua "local _,cam=C.camera(); return cam"
```

## Adding a bridge command

Add `function B.cmds.my_cmd(args) ... return <table> end` to `bridge.lua`. Raise an error
with `error("message", 0)` and the tool gets `ok=false`. Then run `game.py reload`, and call
it from Python with `bridge_or_die("my_cmd", {...})` in `game.py` (add a subcommand if it's
worth having). For one-off probes, `lua` is usually enough; promote it to a command once it's reused.

Periodic work in the mod must use `LoopInGameThreadWithDelay` (never `LoopAsync`; it crashed
the game), and `B.cmds.prepare_reload` has to cancel that loop with `CancelDelayedAction`.

## Getting into the world: `start`

```bash
python tools/game.py start     # from any state: closed game, title, menu, or already in world
python tools/game.py quit      # close the game cleanly (waits for the process to exit)
```

`start` is deterministic, so don't drive the menus yourself. It launches through Steam
if needed, presses a key on the title screen until the save menu shows, loads the
**Kiki Kirishima** save (the mod-testing save; `--save NAME` for another), waits until
the player is in the world, then teleports to a fixed courtyard spot and camera angle
(`TEST_SPOT` in game.py). Every run starts from the same view. From a closed game it takes
about 1 minute; when already in the world it's a 3-second reset. `--stay` skips the teleport.

It is built on two bridge commands you can also call through `lua "return B.cmds.phase()"`:
- `phase` returns `title`, `menu`, `loading`, `world` or `other`.
- `load_save {name}` calls the save button's own Blueprint click handler, so it works at
  any resolution.

To find other UI, list the visible widgets:
`lua "local o,s={},{} for _,w in ipairs(FindAllOf('UserWidget') or {}) do local n=w:GetClass():GetFName():ToString() if not s[n] and w:IsVisible() and w:IsInViewport() then s[n]=1 o[#o+1]=n end end return o"`

## Behavior of the game you need to know

- **Reloading.** The mod folder is a junction into this repo, so edits are on disk at once;
  `reload` loads them. A second Ctrl+R (`reload --all`) in one game session crashed the game twice
  (heap corruption in BPModLoaderMod teardown). Use the default `reload`.
- **Camera.** Hogwarts Legacy's camera stack rewrites `SetControlRotation` and pawn rotation every frame.
  Only mouse input turns it, which is why `look` is a closed loop: about 0.14°/px at default sensitivity.
- **Key presses.** UE4SS keybinds (the mod's F5/F6) react to short presses. Game actions
  need a longer one: spells such as Revelio (`r`) need `--hold 300`. Spells are also ignored
  for a moment after a teleport while the character lands.
- **Focus.** `key`, `mouse`, `click`, `look`, `goto-card`, `reload --all` and `shot --focus` take
  focus from the user. Batch input; everything else works in the background.
- **Autosave.** The game autosaves, so teleports and other changes persist into the save.
- **Crashes.** If the window disappears, read `log --all -n 30` and the Windows event log
  (`Get-WinEvent`, provider "Windows Error Reporting") for the exception code before relaunching.
- **Evidence.** Mod actions log `[MemoryPalace]` lines (`log`), mod→companion events go to
  `ipc/events.jsonl`, and a screenshot only counts once you've Read the PNG.
