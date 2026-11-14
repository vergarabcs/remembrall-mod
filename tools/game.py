"""Drive Hogwarts Legacy and the MemoryPalace mod from the command line.

Two channels:
  * The mod's bridge (ipc/cmd.json -> ipc/res.json): state, Lua eval, console
    commands, teleport, camera angles. Works with the game in the background.
  * Windows itself: screenshots of the game window, key presses and mouse input.
    Input needs the game in the foreground; input commands focus it first.

    python tools/game.py ping                      # is the mod answering?
    python tools/game.py state                     # world, player, camera, placed cards
    python tools/game.py shot                      # -> mod/MemoryPalace/ipc/shots/shot.png
    python tools/game.py shot --crop 0.3,0.2,0.4,0.6   # zoom: x,y,w,h as fractions
    python tools/game.py lua "return C.playerLocation()"
    python tools/game.py lua "Cards.placeAtCrosshair()"
    python tools/game.py console "stat fps"
    python tools/game.py tp 1000 2000 300 --yaw 90
    python tools/game.py look --yaw 90 --pitch -10 # or --card N, --at x,y,z
    python tools/game.py goto-card 1 --dist 250
    python tools/game.py key F5                    # also ctrl+F5, r, esc, space ...
    python tools/game.py key w --hold 1500         # walk forward 1.5 s
    python tools/game.py mouse 300 0               # turn the camera (relative pixels)
    python tools/game.py click [left|right] [--hold MS] [--at 0.25,0.2]
    python tools/game.py focus
    python tools/game.py log -n 40                 # [MemoryPalace] lines of UE4SS.log
    python tools/game.py reload                    # restart just this mod (Lua edits)
    python tools/game.py wait                      # until the loading screen is gone
    python tools/game.py launch                    # start via Steam, wait for the mod
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import sys
import time
import uuid
from ctypes import wintypes
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from install import DEFAULT_GAME  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
IPC = ROOT / "mod" / "MemoryPalace" / "ipc"
SHOTS = IPC / "shots"
GAME_DIR = Path(os.environ.get("HL_GAME_DIR", DEFAULT_GAME))
UE4SS_LOG = GAME_DIR / "Phoenix" / "Binaries" / "Win64" / "ue4ss" / "UE4SS.log"
GAME_EXE = "hogwartslegacy.exe"
STEAM_APP_ID = 990080

# --------------------------------------------------------------------------
# Bridge client
# --------------------------------------------------------------------------


def bridge(cmd: str, args: dict | None = None, timeout: float = 10.0) -> dict:
    cmd_path, res_path, tmp = IPC / "cmd.json", IPC / "res.json", IPC / "cmd.json.tmp"
    cid = uuid.uuid4().hex[:10]
    tmp.write_text(json.dumps({"id": cid, "t": time.time(), "cmd": cmd, "args": args or {}}), encoding="utf-8")
    deadline = time.time() + timeout
    while True:
        try:
            os.replace(tmp, cmd_path)
            break
        except PermissionError:  # the mod has the previous file open for a moment
            if time.time() > deadline:
                raise
            time.sleep(0.02)
    while time.time() < deadline:
        try:
            r = json.loads(res_path.read_text(encoding="utf-8"))
            if r.get("id") == cid:
                return r
        except (FileNotFoundError, PermissionError, ValueError):
            pass
        time.sleep(0.03)
    try:
        cmd_path.unlink()  # not consumed; make sure it never fires later
    except FileNotFoundError:
        pass
    raise SystemExit(f"No answer from the mod within {timeout:.0f}s "
                     "(game not running, still loading, or MemoryPalace not loaded?)")


def bridge_or_die(cmd: str, args: dict | None = None, timeout: float = 10.0):
    r = bridge(cmd, args, timeout)
    if not r.get("ok"):
        raise SystemExit(f"mod error: {r.get('err')}")
    return r.get("result")


def show(obj) -> None:
    print(json.dumps(obj, indent=2, ensure_ascii=False))


# --------------------------------------------------------------------------
# Win32
# --------------------------------------------------------------------------
user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)  # physical pixels everywhere
except (AttributeError, OSError):
    user32.SetProcessDPIAware()

H = wintypes.HANDLE
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.POINT)]
user32.GetForegroundWindow.restype = wintypes.HWND
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.BringWindowToTop.argtypes = [wintypes.HWND]
user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
user32.IsIconic.argtypes = [wintypes.HWND]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
user32.GetDC.argtypes = [wintypes.HWND]
user32.GetDC.restype = H
user32.ReleaseDC.argtypes = [wintypes.HWND, H]
user32.PrintWindow.argtypes = [wintypes.HWND, H, wintypes.UINT]
user32.MapVirtualKeyW.argtypes = [wintypes.UINT, wintypes.UINT]
gdi32.CreateCompatibleDC.argtypes = [H]
gdi32.CreateCompatibleDC.restype = H
gdi32.CreateCompatibleBitmap.argtypes = [H, ctypes.c_int, ctypes.c_int]
gdi32.CreateCompatibleBitmap.restype = H
gdi32.SelectObject.argtypes = [H, H]
gdi32.SelectObject.restype = H
gdi32.DeleteObject.argtypes = [H]
gdi32.DeleteDC.argtypes = [H]
gdi32.GetDIBits.argtypes = [H, H, wintypes.UINT, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT]
kernel32.OpenProcess.restype = H
kernel32.QueryFullProcessImageNameW.argtypes = [H, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
kernel32.CloseHandle.argtypes = [H]


def process_name(pid: int) -> str:
    h = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return ""
    try:
        buf, size = ctypes.create_unicode_buffer(1024), wintypes.DWORD(1024)
        if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
            return os.path.basename(buf.value).lower()
        return ""
    finally:
        kernel32.CloseHandle(h)


def client_rect(hwnd) -> tuple[int, int, int, int]:
    r = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(r))
    p = wintypes.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(p))
    return p.x, p.y, p.x + r.right, p.y + r.bottom


def find_window():
    found = []

    def cb(hwnd, _):
        if user32.IsWindowVisible(hwnd):
            cls = ctypes.create_unicode_buffer(64)
            user32.GetClassNameW(hwnd, cls, 64)
            if cls.value == "UnrealWindow":
                pid = wintypes.DWORD()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                if process_name(pid.value) == GAME_EXE:
                    l, t, r, b = client_rect(hwnd)
                    found.append(((r - l) * (b - t), hwnd))
        return True

    user32.EnumWindows(WNDENUMPROC(cb), 0)
    return max(found)[1] if found else None


def window_or_die():
    hwnd = find_window()
    if not hwnd:
        raise SystemExit("Hogwarts Legacy window not found (is the game running?)")
    return hwnd


def focus(hwnd) -> bool:
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    if user32.GetForegroundWindow() == hwnd:
        return True
    fg = user32.GetForegroundWindow()
    fg_thread = user32.GetWindowThreadProcessId(fg, None) if fg else 0
    me = kernel32.GetCurrentThreadId()
    attached = bool(fg_thread) and fg_thread != me and user32.AttachThreadInput(me, fg_thread, True)
    user32.BringWindowToTop(hwnd)
    user32.SetForegroundWindow(hwnd)
    if attached:
        user32.AttachThreadInput(me, fg_thread, False)
    for _ in range(20):
        if user32.GetForegroundWindow() == hwnd:
            time.sleep(0.25)  # let the game notice it has focus again
            return True
        time.sleep(0.05)
    # Last resort: an Alt tap lifts Windows' foreground lock.
    send_key_event(VK["alt"], True)
    send_key_event(VK["alt"], False)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.3)
    return user32.GetForegroundWindow() == hwnd


# --------------------------------------------------------------------------
# Screenshots
# --------------------------------------------------------------------------
class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
                ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
                ("biClrImportant", wintypes.DWORD)]


def grab_printwindow(hwnd):
    from PIL import Image
    l, t, r, b = client_rect(hwnd)
    w, h = r - l, b - t
    hdc = user32.GetDC(hwnd)
    mdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    old = gdi32.SelectObject(mdc, bmp)
    try:
        user32.PrintWindow(hwnd, mdc, 3)  # PW_CLIENTONLY | PW_RENDERFULLCONTENT
        bmi = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
        buf = ctypes.create_string_buffer(w * h * 4)
        gdi32.GetDIBits(mdc, bmp, 0, h, buf, ctypes.byref(bmi), 0)
        return Image.frombuffer("RGB", (w, h), buf, "raw", "BGRX", 0, 1)
    finally:
        gdi32.SelectObject(mdc, old)
        gdi32.DeleteObject(bmp)
        gdi32.DeleteDC(mdc)
        user32.ReleaseDC(hwnd, hdc)


def grab_screen(hwnd):
    from PIL import ImageGrab
    return ImageGrab.grab(bbox=client_rect(hwnd), all_screens=True)


def is_blank(img) -> bool:
    lo, hi = img.convert("L").resize((64, 32)).getextrema()
    return hi - lo < 8


def take_shot(method: str, do_focus: bool):
    """Returns (image, method used).

    No engine-side capture: `shot` / `HighResShot` run but write nothing in this
    shipping build (tested 2026-11-14), while PrintWindow works in the background.
    """
    hwnd = window_or_die()
    if do_focus:
        focus(hwnd)
    foreground = user32.GetForegroundWindow() == hwnd
    if method in ("auto", "screen") and foreground:
        img = grab_screen(hwnd)
        if method == "screen" or not is_blank(img):
            return img, "screen"
    if method == "screen":
        raise SystemExit("Game is not in the foreground; use --focus or --method window")
    img = grab_printwindow(hwnd)
    return img, "window" + (" (blank frame)" if is_blank(img) else "")


def finish_image(img, crop: str | None, width: int):
    if crop:
        x, y, w, h = (float(v) for v in crop.split(","))
        W, H_ = img.size
        img = img.crop((int(x * W), int(y * H_), int((x + w) * W), int((y + h) * H_)))
    if width and img.width > width:
        img = img.resize((width, round(img.height * width / img.width)))
    return img


# --------------------------------------------------------------------------
# Input
# --------------------------------------------------------------------------
ULONG_PTR = ctypes.c_size_t


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("mi", MOUSEINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]

VK = {
    "ctrl": 0xA2, "shift": 0xA0, "alt": 0xA4, "space": 0x20, "enter": 0x0D, "esc": 0x1B, "escape": 0x1B,
    "tab": 0x09, "backspace": 0x08, "up": 0x26, "down": 0x28, "left": 0x25, "right": 0x27,
    "insert": 0x2D, "delete": 0x2E, "home": 0x24, "end": 0x23, "pageup": 0x21, "pagedown": 0x22,
    "`": 0xC0, "tilde": 0xC0, "-": 0xBD, "=": 0xBB, "[": 0xDB, "]": 0xDD, ";": 0xBA, "'": 0xDE,
    ",": 0xBC, ".": 0xBE, "/": 0xBF, "\\": 0xDC,
}
VK.update({f"f{i}": 0x6F + i for i in range(1, 25)})
VK.update({c: ord(c.upper()) for c in "abcdefghijklmnopqrstuvwxyz0123456789"})
EXTENDED = {0x26, 0x28, 0x25, 0x27, 0x2D, 0x2E, 0x24, 0x23, 0x21, 0x22}


def send_key_event(vk: int, down: bool) -> None:
    scan = user32.MapVirtualKeyW(vk, 0)  # MAPVK_VK_TO_VSC
    flags = 0x0008  # KEYEVENTF_SCANCODE: games read scancodes more reliably than VKs
    if vk in EXTENDED:
        flags |= 0x0001
    if not down:
        flags |= 0x0002
    inp = INPUT(1, _INPUTUNION(ki=KEYBDINPUT(0, scan, flags, 0, 0)))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def parse_combo(combo: str) -> list[int]:
    keys = []
    for part in combo.lower().split("+"):
        if part not in VK:
            raise SystemExit(f"unknown key '{part}'. Known: {', '.join(sorted(VK))}")
        keys.append(VK[part])
    return keys


def press(combo: str, hold_ms: int) -> None:
    keys = parse_combo(combo)
    for k in keys:
        send_key_event(k, True)
        time.sleep(0.02)
    time.sleep(hold_ms / 1000)
    for k in reversed(keys):
        send_key_event(k, False)
        time.sleep(0.02)


def send_mouse(flags: int, dx: int = 0, dy: int = 0) -> None:
    inp = INPUT(0, _INPUTUNION(mi=MOUSEINPUT(dx, dy, 0, flags, 0, 0)))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def mouse_move(dx: int, dy: int, steps: int) -> None:
    sx = sy = 0
    for i in range(1, steps + 1):
        tx, ty = round(dx * i / steps), round(dy * i / steps)
        send_mouse(0x0001, tx - sx, ty - sy)  # MOUSEEVENTF_MOVE (relative)
        sx, sy = tx, ty
        time.sleep(0.01)


def wrap180(a: float) -> float:
    return (a + 180.0) % 360.0 - 180.0


def aim(yaw: float | None = None, pitch: float | None = None, target: dict | None = None,
        tolerance: float = 1.0, tries: int = 8) -> dict:
    """Turn the camera with mouse moves until it points at yaw/pitch or at a target.

    The game's camera ignores SetControlRotation, so this is closed-loop: read the
    camera, move the mouse, read again, and learn degrees-per-pixel (and pitch
    inversion) as it goes. A target is {"card": i} or {"x","y","z"}; with a
    third-person camera the right angles shift as it orbits, so they are re-read
    every step.
    """
    k_yaw, k_pitch = 0.1425, -0.1425  # degrees per pixel; mouse down = look down
    v = bridge_or_die("view", target or {})
    for _ in range(tries):
        want_y = v.get("want_yaw", yaw)
        want_p = v.get("want_pitch", pitch)
        dyaw = wrap180(want_y - v["yaw"]) if want_y is not None else 0.0
        dpitch = (want_p - v["pitch"]) if want_p is not None else 0.0
        if abs(dyaw) <= tolerance and abs(dpitch) <= tolerance:
            break
        dx, dy = round(dyaw / k_yaw), round(dpitch / k_pitch)
        mouse_move(dx, dy, max(4, min(30, (abs(dx) + abs(dy)) // 40)))
        time.sleep(0.2)
        before, v = v, bridge_or_die("view", target or {})
        got_y, got_p = wrap180(v["yaw"] - before["yaw"]), v["pitch"] - before["pitch"]
        if abs(dx) >= 15 and abs(got_y) > 0.5 and 0.01 < got_y / dx < 2:
            k_yaw = got_y / dx
        if abs(dy) >= 15 and abs(got_p) > 0.5 and 0.01 < abs(got_p / dy) < 2:
            k_pitch = got_p / dy
    return v


def ensure_focus(args) -> None:
    if getattr(args, "no_focus", False):
        return
    if not focus(window_or_die()):
        raise SystemExit("Could not bring the game to the foreground (click it once, then retry)")


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def cmd_shot(a):
    img, used = take_shot(a.method, a.focus)
    full = img.size
    img = finish_image(img, a.crop, a.width)
    out = Path(a.out) if a.out else SHOTS / "shot.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    print(f"{out}  ({used}, captured {full[0]}x{full[1]}, saved {img.width}x{img.height})")


def cmd_log(a):
    if not UE4SS_LOG.exists():
        raise SystemExit(f"no log at {UE4SS_LOG}")
    lines = UE4SS_LOG.read_text(encoding="utf-8", errors="replace").splitlines()
    if not a.all:
        lines = [l for l in lines if "[MemoryPalace]" in l]
    print("\n".join(lines[-a.n:]))


def cmd_launch(a):
    if find_window():
        print("game already running")
    else:
        os.startfile(f"steam://rungameid/{STEAM_APP_ID}")
        print("launching via Steam ...")
    deadline = time.time() + a.timeout
    while time.time() < deadline and not find_window():
        time.sleep(2)
    if not find_window():
        raise SystemExit("game window did not appear")
    print("window up; waiting for the mod bridge ...")
    while time.time() < deadline:
        try:
            r = bridge("ping", timeout=3)
            if r.get("ok"):
                print("bridge answering:", r.get("result"))
                return
        except SystemExit:
            pass
    raise SystemExit("window is up but the mod bridge never answered")


def cmd_reload(a):
    """Reload the mod's Lua and wait for the bridge to answer again.

    Default: the mod restarts only itself (RestartCurrentMod); no focus needed.
    --all: UE4SS Ctrl+R, which reloads every mod. The second Ctrl+R in a session
    crashed the game twice (inside BPModLoaderMod's teardown), so avoid it.
    """
    if not a.all:
        bridge_or_die("restart", timeout=5)
        time.sleep(1.0)
    else:
        try:
            bridge_or_die("prepare_reload", timeout=5)
        except SystemExit as e:
            if not a.force:
                raise SystemExit(f"mod did not confirm it stopped its loops ({e}); not reloading. "
                                 "Use --force to press Ctrl+R anyway.")
            print(f"(prepare_reload failed: {e}; reloading anyway)")
        time.sleep(0.5)  # let the game thread finish its current tick
        ensure_focus(a)
        press("ctrl+r", 80)
        time.sleep(1.0)
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            if bridge("ping", timeout=2).get("ok"):
                print("reloaded; bridge answering")
                return
        except SystemExit:
            pass
    raise SystemExit("bridge did not come back after the reload; check `game.py log`")


def cmd_wait(a):
    """Poll a Lua expression until it is truthy (default: loaded into the world)."""
    deadline = time.time() + a.timeout
    last = None
    while time.time() < deadline:
        try:
            r = bridge("lua", {"code": a.code}, timeout=5)
            last = (r.get("result") or {}).get("value") if r.get("ok") else r.get("err")
            if r.get("ok") and last not in (None, False, 0, "", [], {}):
                show(last)
                return
        except SystemExit as e:
            last = str(e)
        time.sleep(a.interval)
    raise SystemExit(f"timed out; last value: {last}")


# Player exists and the loading screen widget is hidden.
LOADING_DONE = """(function()
    if not C.playerLocation() then return false end
    for _, w in ipairs(FindAllOf("UI_BP_NewLoadingScreen_C") or {}) do
        if w:IsVisible() then return false end
    end
    return true
end)()"""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping")
    sub.add_parser("state")

    p = sub.add_parser("shot", help="screenshot the game")
    p.add_argument("--method", choices=["auto", "screen", "window"], default="auto",
                   help="screen: grab the screen area (needs foreground); window: PrintWindow "
                        "(works in the background); auto: screen if foreground, else window")
    p.add_argument("--focus", action="store_true", help="bring the game to the front first")
    p.add_argument("--crop", help="x,y,w,h as fractions of the frame, e.g. 0.3,0.2,0.4,0.6")
    p.add_argument("--width", type=int, default=1600, help="downscale to at most this width (0 = full)")
    p.add_argument("--out", help="output path (default ipc/shots/shot.png)")

    p = sub.add_parser("lua", help="run Lua inside the mod")
    p.add_argument("code")
    p.add_argument("--timeout", type=float, default=10)

    p = sub.add_parser("console", help="run a UE console command")
    p.add_argument("command")

    p = sub.add_parser("tp", help="teleport the player")
    for n in ("x", "y", "z"):
        p.add_argument(n, type=float)
    p.add_argument("--yaw", type=float)
    p.add_argument("--pitch", type=float)

    p.add_argument("--no-focus", action="store_true")

    p = sub.add_parser("look", help="turn the camera (mouse, closed loop; needs focus)")
    p.add_argument("--yaw", type=float, help="absolute camera yaw, degrees")
    p.add_argument("--pitch", type=float, help="absolute camera pitch, degrees")
    p.add_argument("--card", type=int, help="look at placed card N")
    p.add_argument("--at", help="look at a world point: x,y,z")
    p.add_argument("--no-focus", action="store_true")

    p = sub.add_parser("goto-card", help="stand in front of placed card N and look at it")
    p.add_argument("i", type=int, nargs="?", default=1)
    p.add_argument("--dist", type=float, default=250)
    p.add_argument("--no-focus", action="store_true")

    p = sub.add_parser("reload", help="restart the MemoryPalace mod (picks up Lua edits)")
    p.add_argument("--all", action="store_true", help="UE4SS Ctrl+R instead (all mods; crash-prone)")
    p.add_argument("--no-focus", action="store_true")
    p.add_argument("--force", action="store_true", help="with --all: press Ctrl+R even if the mod did not answer")

    p = sub.add_parser("wait", help="wait until a Lua expression is truthy (default: loaded in)")
    p.add_argument("code", nargs="?", default=LOADING_DONE)
    p.add_argument("--timeout", type=float, default=120)
    p.add_argument("--interval", type=float, default=2)

    p = sub.add_parser("key", help="press keys/combos in order, e.g. F5 ctrl+F5 r")
    p.add_argument("keys", nargs="+")
    p.add_argument("--hold", type=int, default=200,
                   help="ms each combo is held (game actions like spells ignore an 80 ms tap)")
    p.add_argument("--gap", type=int, default=150, help="ms between combos")
    p.add_argument("--no-focus", action="store_true")

    p = sub.add_parser("mouse", help="relative mouse move (camera turn)")
    p.add_argument("dx", type=int)
    p.add_argument("dy", type=int)
    p.add_argument("--steps", type=int, default=10)
    p.add_argument("--no-focus", action="store_true")

    p = sub.add_parser("click", help="mouse click")
    p.add_argument("button", nargs="?", choices=["left", "right"], default="left")
    p.add_argument("--at", help="move the cursor first: x,y as fractions of the frame (menus)")
    p.add_argument("--hold", type=int, default=80)
    p.add_argument("--no-focus", action="store_true")

    sub.add_parser("focus", help="bring the game window to the front")

    p = sub.add_parser("log", help="tail UE4SS.log")
    p.add_argument("-n", type=int, default=30)
    p.add_argument("--all", action="store_true", help="all lines, not just [MemoryPalace]")

    p = sub.add_parser("launch", help="start the game via Steam and wait for the mod")
    p.add_argument("--timeout", type=float, default=240)

    a = ap.parse_args()
    c = a.cmd
    if c == "ping":
        show(bridge_or_die("ping", timeout=5))
    elif c == "state":
        show(bridge_or_die("state"))
    elif c == "shot":
        cmd_shot(a)
    elif c == "lua":
        r = bridge_or_die("lua", {"code": a.code}, timeout=a.timeout) or {}
        for line in r.get("printed") or []:
            print(line)
        if r.get("value") is not None:
            show(r["value"])
    elif c == "console":
        show(bridge_or_die("console", {"command": a.command}))
    elif c == "tp":
        show(bridge_or_die("tp", {"x": a.x, "y": a.y, "z": a.z}))
        if a.yaw is not None or a.pitch is not None:
            ensure_focus(a)
            show(aim(a.yaw, a.pitch))
    elif c == "look":
        ensure_focus(a)
        target = {"card": a.card} if a.card else None
        if a.at:
            x, y, z = (float(v) for v in a.at.split(","))
            target = {"x": x, "y": y, "z": z}
        show(aim(a.yaw, a.pitch, target))
    elif c == "goto-card":
        show(bridge_or_die("goto_card", {"i": a.i, "dist": a.dist}))
        ensure_focus(a)
        time.sleep(0.5)  # let the camera catch up with the teleport
        show(aim(target={"card": a.i}))
    elif c == "reload":
        cmd_reload(a)
    elif c == "wait":
        cmd_wait(a)
    elif c == "key":
        ensure_focus(a)
        for i, combo in enumerate(a.keys):
            if i:
                time.sleep(a.gap / 1000)
            press(combo, a.hold)
    elif c == "mouse":
        ensure_focus(a)
        mouse_move(a.dx, a.dy, a.steps)
    elif c == "click":
        ensure_focus(a)
        if a.at:
            fx, fy = (float(v) for v in a.at.split(","))
            l, t, r, b = client_rect(window_or_die())
            user32.SetCursorPos(int(l + fx * (r - l)), int(t + fy * (b - t)))
            time.sleep(0.15)
        down, up = (0x0002, 0x0004) if a.button == "left" else (0x0008, 0x0010)
        send_mouse(down)
        time.sleep(a.hold / 1000)
        send_mouse(up)
    elif c == "focus":
        print("focused" if focus(window_or_die()) else "could not focus")
    elif c == "log":
        cmd_log(a)
    elif c == "launch":
        cmd_launch(a)


if __name__ == "__main__":
    main()
