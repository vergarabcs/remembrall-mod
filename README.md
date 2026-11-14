# Memory Palace (Hogwarts Legacy mod)

Turns a book into flashcards and places them around the castle so related cards
sit together. Built on UE4SS (Lua scripting) plus a Python companion app,
the same architecture Sonorus uses.

## Stage 0: feasibility probe (done)

| # | Question | Result |
|---|---|---|
| 1 | Can we spawn a placeholder object? | **Yes.** `StaticMeshActor` with `/Engine/BasicShapes/Cube` + `PointLight` + floating `TextRenderActor` |
| 2 | Can it show a card and play audio when used? | **Yes.** Floating label and the game's subtitle line both work; the companion speaks the text |
| 3 | Can it find reachable empty spots by itself? | **Dropped.** You place cards yourself with Wingardium Leviosa instead |

## Controls

| Input | Action |
|---|---|
| **F5** | Place the next card from `ipc/cards.json` where the crosshair points |
| **Wingardium Leviosa** | Move a card. Cards are weightless physics objects, so the game's own spell handles them and they float where you let go. Positions go to `ipc/placements.json` |
| **Revelio** | Flip the card nearest your crosshair (within 9 m, 35°): topic, question, answer, closed. Mapping is `S.actions` in `Scripts/spells.lua` |
| **F6** | Same as Revelio, for the card within 4 m you are looking at |
| **Ctrl+F5** | Remove everything the mod spawned |
| **Ctrl+F6** | Reload `ipc/cards.json` |
| **Ctrl+R** | UE4SS hot reload of all Lua mods. Crash-prone: prefer `python tools/game.py reload` |

F7/F11 belong to Sonorus (disabled), F10 to the UE console.

## Setup on a new machine

Windows only (the tools use Win32 for input and screenshots).

1. **Hogwarts Legacy** on Steam. Display mode *Windowed Fullscreen* or *Windowed*. A modest
   resolution (developed at 1440x900, low graphics) keeps screenshots small and the game light.
2. **UE4SS v3.0.1** (developed against `v3.0.1 Beta #0`, from the RE-UE4SS GitHub releases).
   Unzip it into `Hogwarts Legacy\Phoenix\Binaries\Win64\`, so that `dwmapi.dll` and the
   `ue4ss\` folder sit next to `HogwartsLegacy.exe`. The default settings work. Its bundled
   mods (BPModLoaderMod, ConsoleEnablerMod, ...) can stay as they are.
3. **Python 3.10+** with Pillow: `pip install pillow` (only `tools/game.py` needs it).
4. **This repo**, cloned anywhere. If the game isn't in `D:\SteamLibrary\steamapps\common\Hogwarts Legacy`,
   set `HL_GAME_DIR` to the game folder (or pass `--game` to `install.py`); both tools read it.
5. **Link the mod into the game** (a directory junction, so edits here are live; no admin needed):

   ```bash
   python tools/install.py            # junction into ue4ss/Mods + enable in mods.txt
   python tools/install.py --status   # check: UE4SS enabled, link present, MemoryPalace : 1
   ```

6. **Test save.** `game.py start` loads the character **Kiki Kirishima**. It comes over
   through Steam Cloud if that's on. Otherwise copy the save folder from
   `%LOCALAPPDATA%\Hogwarts Legacy\Saved\SaveGames\`, or pass `--save "<your character>"`
   (the courtyard teleport assumes that save is past the intro and can reach Hogwarts).
7. **Check it end to end:** `python tools/game.py start`, then `python tools/game.py shot`.

## Run it

```bash
python tools/game.py start              # or launch the game normally
python companion/companion.py           # optional; speaks cards, prints a summary
python tools/install.py --enable-ue4ss  # only if UE4SS was turned off (dwmapi.dll.bak)
```

Logs: `Phoenix/Binaries/Win64/ue4ss/UE4SS.log` (lines tagged `[MemoryPalace]`) and
`mod/MemoryPalace/ipc/events.jsonl`.

## Remote control and screenshots (`tools/game.py`)

Lets a script (or Claude) see and drive the game to check its own work. The mod's
`bridge.lua` polls `ipc/cmd.json` on the game thread and answers in `ipc/res.json`;
everything else is plain Windows (window capture, `SendInput`).

```bash
python tools/game.py start                  # from anywhere: launch, load test save, courtyard spot
python tools/game.py quit                   # close the game
python tools/game.py shot                   # -> mod/MemoryPalace/ipc/shots/shot.png
python tools/game.py shot --crop 0.3,0.2,0.4,0.5   # zoom (x,y,w,h fractions)
python tools/game.py state                  # world, player, camera, placed cards
python tools/game.py lua "return C.playerLocation()"   # run Lua inside the mod
python tools/game.py key F5                 # keys/combos; --hold MS for longer presses
python tools/game.py click --at 0.5,0.5     # click (fractions of the frame)
python tools/game.py look --yaw 90 --pitch -10    # or --card N / --at x,y,z
python tools/game.py tp X Y Z               # teleport
python tools/game.py goto-card 1            # stand in front of card 1, facing it
python tools/game.py console "stat fps"
python tools/game.py reload                 # restart just this mod after Lua edits
python tools/game.py log -n 30
```

- Screenshots work with the game in the background (PrintWindow); `bridge`, `state`,
  `lua`, `tp` and `console` do too. Keys, mouse, `look` and `goto-card` bring the game
  to the front first.
- `look` is closed-loop mouse movement: the game's camera stack rewrites
  `SetControlRotation` every frame, so the camera can't be set directly.
- The `lua` command runs arbitrary code in the mod. It only reads files from this
  project's `ipc` folder, so anything that can write there can run code in the game.

## Undo

```bash
python tools/install.py --uninstall      # removes the junction + mods.txt entry
python tools/install.py --disable-ue4ss  # turns UE4SS off entirely
```

## Layout

```
mod/MemoryPalace/Scripts/   UE4SS Lua mod (main, common, cards, spells, bridge; lib/json = rxi, MIT)
mod/MemoryPalace/ipc/       files shared between the mod and the companion (gitignored)
companion/                  Python app: audio now; book -> cards -> clusters later
tools/install.py            install / uninstall / toggle UE4SS
tools/game.py               screenshots + remote control (see above)
```

## Rules learned the hard way

- **Never use `LoopAsync`.** It runs Lua on a second OS thread against the same Lua state
  and crashed the game after a few minutes (UE4SS.dll+0x920456). Use
  `LoopInGameThreadWithDelay` for anything periodic.
- Cache the player controller; `UEHelpers.GetPlayerController` scans every controller.
- **Don't press Ctrl+R twice in one session.** The second UE4SS reload of all mods crashed
  the game twice (heap corruption `c0000374` while stopping BPModLoaderMod), even with
  our loops stopped. `game.py reload` uses `RestartCurrentMod` (this mod only), which
  survived repeated reloads and unregisters the spell hook cleanly.
- Engine screenshots (`shot`, `HighResShot`) run but write nothing in this shipping
  build; capture the window instead.
- Game actions (spells) need a key held ~200 ms; UE4SS keybinds react to shorter taps.

## Known limits

- Display uses engine text and the subtitle line. A proper card panel (UMG widget)
  and a nicer object need a Blueprint pak built in UE 4.27.
- Audio plays from the companion through Windows speech, not through the game's Wwise
  audio engine. It ignores the in-game volume and is not positional yet.
- Cards are not yet restored from `placements.json` after a restart.
