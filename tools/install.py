"""Install / uninstall the MemoryPalace mod into a Hogwarts Legacy UE4SS setup.

    python tools/install.py               # link mod into ue4ss/Mods and enable it
    python tools/install.py --status      # show what is installed and enabled
    python tools/install.py --enable-ue4ss / --disable-ue4ss
    python tools/install.py --uninstall   # remove the link and the mods.txt entry

The mod folder is a directory junction pointing back at this project, so edits
here take effect the next time the game starts. No admin rights needed.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD_SRC = ROOT / "mod" / "MemoryPalace"
MOD_NAME = "MemoryPalace"
DEFAULT_GAME = Path(r"D:\SteamLibrary\steamapps\common\Hogwarts Legacy")


def paths(game: Path) -> dict[str, Path]:
    win64 = game / "Phoenix" / "Binaries" / "Win64"
    mods = win64 / "ue4ss" / "Mods"
    return {
        "win64": win64,
        "mods": mods,
        "link": mods / MOD_NAME,
        "mods_txt": mods / "mods.txt",
        "mods_json": mods / "mods.json",
        "proxy": win64 / "dwmapi.dll",
        "proxy_off": win64 / "dwmapi.dll.bak",
    }


def is_junction(p: Path) -> bool:
    return os.path.isjunction(p) if hasattr(os.path, "isjunction") else p.is_symlink()


def set_mods_txt(path: Path, enabled: bool | None) -> None:
    """enabled=None removes the entry."""
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    lines = [l for l in lines if l.split(":")[0].strip() != MOD_NAME]
    if enabled is not None:
        lines.append(f"{MOD_NAME} : {1 if enabled else 0}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def set_mods_json(path: Path, enabled: bool | None) -> None:
    if not path.exists():
        return
    data = json.loads(path.read_text(encoding="utf-8"))
    data = [m for m in data if m.get("mod_name") != MOD_NAME]
    if enabled is not None:
        data.append({"mod_name": MOD_NAME, "mod_enabled": enabled})
    path.write_text(json.dumps(data, indent=4), encoding="utf-8")


def install(p: dict[str, Path]) -> None:
    if not p["mods"].is_dir():
        sys.exit(f"UE4SS Mods folder not found: {p['mods']}")
    (MOD_SRC / "ipc").mkdir(exist_ok=True)
    if p["link"].exists() or is_junction(p["link"]):
        print(f"link already present: {p['link']}")
    else:
        subprocess.run(["cmd", "/c", "mklink", "/J", str(p["link"]), str(MOD_SRC)], check=True)
    set_mods_txt(p["mods_txt"], True)
    set_mods_json(p["mods_json"], True)
    print("installed and enabled in mods.txt / mods.json")
    if not p["proxy"].exists():
        print("NOTE: UE4SS is currently disabled (dwmapi.dll missing). Run with --enable-ue4ss to turn it on.")


def uninstall(p: dict[str, Path]) -> None:
    if is_junction(p["link"]):
        os.rmdir(p["link"])  # removes only the junction, never the project files
        print(f"removed link {p['link']}")
    elif p["link"].exists():
        print(f"{p['link']} is a real folder, not our junction; leaving it alone")
    set_mods_txt(p["mods_txt"], None)
    set_mods_json(p["mods_json"], None)
    print("removed from mods.txt / mods.json")


def toggle_ue4ss(p: dict[str, Path], on: bool) -> None:
    src, dst = (p["proxy_off"], p["proxy"]) if on else (p["proxy"], p["proxy_off"])
    if dst.exists():
        print(f"UE4SS already {'enabled' if on else 'disabled'}")
    elif not src.exists():
        print(f"cannot find {src}")
    else:
        src.rename(dst)
        print(f"UE4SS {'enabled' if on else 'disabled'} ({src.name} -> {dst.name})")


def status(p: dict[str, Path]) -> None:
    print(f"UE4SS proxy dll : {'ENABLED' if p['proxy'].exists() else 'disabled'}")
    print(f"mod link        : {'present' if p['link'].exists() else 'missing'} ({p['link']})")
    if p["mods_txt"].exists():
        print("mods.txt        :")
        for line in p["mods_txt"].read_text(encoding="utf-8").splitlines():
            if line.strip():
                print("   ", line)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", type=Path, default=Path(os.environ.get("HL_GAME_DIR", DEFAULT_GAME)))
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--uninstall", action="store_true")
    g.add_argument("--status", action="store_true")
    g.add_argument("--enable-ue4ss", action="store_true")
    g.add_argument("--disable-ue4ss", action="store_true")
    args = ap.parse_args()
    p = paths(args.game)
    if args.uninstall:
        uninstall(p)
    elif args.status:
        status(p)
    elif args.enable_ue4ss:
        toggle_ue4ss(p, True)
    elif args.disable_ue4ss:
        toggle_ue4ss(p, False)
    else:
        install(p)


if __name__ == "__main__":
    main()
