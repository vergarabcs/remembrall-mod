"""Remembrall companion (probe version).

Runs next to the game. Watches ipc/events.jsonl written by the Lua mod and:
  * speaks the flashcard text on `card_open` (unknown #2: audio on interaction)
  * prints a running feasibility summary for unknowns #1-#2

Audio uses Windows' built-in speech engine through one long-lived PowerShell
process, so there is nothing to pip install. A neural TTS replaces it later.

    python companion/companion.py            # from the project root
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_IPC = ROOT / "mod" / "Remembrall" / "ipc"

# Reads one line at a time from stdin and speaks it, cancelling anything still playing.
_PS_SPEAKER = r"""
Add-Type -AssemblyName System.Speech
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$s.Rate = 1
while (($line = [Console]::In.ReadLine()) -ne $null) {
    $s.SpeakAsyncCancelAll()
    if ($line.Trim().Length -gt 0) { $s.SpeakAsync($line) | Out-Null }
}
"""


class Speaker:
    def __init__(self) -> None:
        self.proc: subprocess.Popen | None = None
        exe = shutil.which("powershell") or shutil.which("pwsh")
        if not exe:
            print("[audio] PowerShell not found; audio disabled")
            return
        self.proc = subprocess.Popen(
            [exe, "-NoProfile", "-NonInteractive", "-Command", _PS_SPEAKER],
            stdin=subprocess.PIPE,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

    def say(self, text: str) -> bool:
        if not self.proc or self.proc.poll() is not None:
            return False
        line = " ".join(text.split()) + "\n"
        try:
            self.proc.stdin.write(line.encode("utf-8"))
            self.proc.stdin.flush()
            return True
        except OSError as e:
            print(f"[audio] speak failed: {e}")
            return False

    def close(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.stdin.close()
            self.proc.wait(timeout=3)


class Summary:
    """What each probe has proven so far."""

    def __init__(self) -> None:
        self.u1: dict = {}
        self.u2: dict = {}

    def update(self, evt: dict, audio_ok: bool | None) -> None:
        t = evt.get("type")
        if t == "probe_spawn":
            self.u1 = {k: evt.get(k) for k in ("actor_ok", "mesh", "set_mesh", "light_ok", "text_ok", "label_set")}
        elif t == "card_open":
            self.u2 = {
                "text_render": evt.get("text_render_ok"),
                "subtitle": evt.get("subtitle_ok"),
                "audio": audio_ok if audio_ok is not None else self.u2.get("audio"),
            }

    def print(self) -> None:
        print("  U1 placeholder :", self.u1 or "not tried (F5)")
        print("  U2 card+audio  :", self.u2 or "not tried (Revelio or F6 near a card)")


def tail(path: Path):
    """Yield new JSON objects appended to `path`, starting from its current end."""
    pos = path.stat().st_size if path.exists() else 0
    while True:
        if path.exists():
            size = path.stat().st_size
            if size < pos:  # file was truncated or replaced
                pos = 0
            if size > pos:
                with path.open("rb") as f:
                    f.seek(pos)
                    chunk = f.read()
                # Only consume complete lines.
                end = chunk.rfind(b"\n") + 1
                pos += end
                for raw in chunk[:end].splitlines():
                    try:
                        yield json.loads(raw.decode("utf-8"))
                    except (ValueError, UnicodeDecodeError) as e:
                        print(f"[ipc] bad line ({e}): {raw[:120]!r}")
        time.sleep(0.05)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ipc", type=Path, default=DEFAULT_IPC, help="ipc folder shared with the Lua mod")
    ap.add_argument("--no-audio", action="store_true")
    args = ap.parse_args()

    ipc: Path = args.ipc
    ipc.mkdir(parents=True, exist_ok=True)
    cards = ipc / "cards.json"
    if not cards.exists():
        shutil.copy(Path(__file__).with_name("sample_cards.json"), cards)
        print(f"[ipc] wrote sample deck to {cards}")

    speaker = None if args.no_audio else Speaker()
    summary = Summary()
    print(f"[ipc] watching {ipc / 'events.jsonl'}  (Ctrl+C to quit)")
    if speaker and speaker.say("Remembrall companion ready."):
        print("[audio] speech engine started")

    try:
        for evt in tail(ipc / "events.jsonl"):
            t = evt.get("type")
            audio_ok = None
            if t == "card_open":
                text = evt.get("text") or ""
                if speaker and text:
                    audio_ok = speaker.say(text)
                print(f"[card] {evt.get('card_id')} -> {evt.get('side')}: {text[:80]}"
                      f"  (audio={'on' if audio_ok else 'off'})")
            elif t == "error":
                print(f"[mod error] {evt.get('where')}: {evt.get('err')}")
            else:
                print(f"[{t}] " + json.dumps({k: v for k, v in evt.items() if k not in ('type', 'loci', 't')}))
            summary.update(evt, audio_ok)
            if t in ("probe_spawn", "card_open"):
                summary.print()
    except KeyboardInterrupt:
        pass
    finally:
        if speaker:
            speaker.close()
    print("\nFinal summary:")
    summary.print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
