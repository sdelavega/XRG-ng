#!/usr/bin/env python3
"""Falsification test for the minimized-restore trap (issue #1).

Seeds the exact trap state into XRG's defaults (windowIsMinimized=1 plus an
autosaved COLLAPSED frame and no persisted expanded frame), launches the
given XRG.app, lets it settle, quits it cleanly, and reads back the frame
the app autosaved on exit. A build that still has the bug writes the
collapsed frame back; a fixed build expands before quitting and writes a
real size in the collapsed axis: the synthesized 600 with no history, or
the persisted history size with it.

The collapsed axis depends on layout: vertical layouts collapse HEIGHT,
horizontal layouts collapse WIDTH. The test sets the orientation it is
exercising, because a trap seeded for the wrong axis measures nothing
(found the hard way: a height-collapsed seed on a horizontal layout let a
fixed build persist an 809x21 strip as its "expanded" frame).

Only stdlib: `defaults`, `open`, `osascript`. Backs up and restores the
user's XRG defaults around the run so the test never leaves their window
in the trap.

Usage:
  python3 Tools/verify_minimize_restore.py --app /Applications/XRG.app
  python3 Tools/verify_minimize_restore.py --app build/Release/XRG.app --orientation horizontal
  python3 Tools/verify_minimize_restore.py --app build/Release/XRG.app --with-history 984

Exit 0 = restored to the fix's contract, 1 = trapped.
"""

import argparse
import os
import subprocess
import sys
import tempfile
import time

DOMAIN = "com.piatekjimenez.XRG"
FRAME_KEY = "NSWindow Frame xrg_window"
COLLAPSED = 21  # 2 * borderWidth(4) + textRectHeight(13) with default font


def run(*argv, check=False):
    return subprocess.run(list(argv), check=check, capture_output=True, text=True)


def read_default(key):
    p = run("defaults", "read", DOMAIN, key)
    return p.stdout.strip() if p.returncode == 0 else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, help="path to XRG.app to launch")
    ap.add_argument("--with-history", type=int, default=0,
                    help="also persist an expanded frame of this size in the collapsed axis")
    ap.add_argument("--orientation", choices=("vertical", "horizontal"), default="vertical",
                    help="layout under test; the trap collapses HEIGHT for vertical, WIDTH for horizontal")
    ap.add_argument("--settle", type=float, default=4.0)
    args = ap.parse_args()
    vertical = args.orientation == "vertical"

    backup = os.path.join(tempfile.mkdtemp(prefix="xrg-verify-"), "defaults.plist")
    run("defaults", "export", DOMAIN, backup)

    # Screen geometry from the user's current autosave string when present.
    current = read_default(FRAME_KEY) or "0 0 140 700 0 0 1920 1080 "
    parts = current.split()
    screen = " ".join(parts[4:8]) if len(parts) >= 8 else "0 0 1920 1080"
    x, y = (parts[0], parts[1]) if len(parts) >= 2 else ("0", "0")
    w, h = (139, COLLAPSED) if vertical else (COLLAPSED, 238)
    trap_frame = f"{x} {y} {w} {h} {screen} "
    expected = args.with_history if args.with_history else 600

    try:
        run("pkill", "-x", "XRG"); time.sleep(2)
        run("defaults", "write", DOMAIN, "graphOrientationVertical", "-bool", "true" if vertical else "false")
        run("defaults", "write", DOMAIN, "windowIsMinimized", "-bool", "true")
        run("defaults", "write", DOMAIN, FRAME_KEY, trap_frame)
        if args.with_history:
            hw, hh = (139, args.with_history) if vertical else (args.with_history, 238)
            # -string is load-bearing: a bare value starting with "{" is parsed
            # by `defaults` as a dictionary literal, and the app then reads nil.
            run("defaults", "write", DOMAIN, "unminimizedFrame", "-string", f"{{{{{x}, {y}}}, {{{hw}, {hh}}}}}")
        else:
            run("defaults", "delete", DOMAIN, "unminimizedFrame")

        # Exec the bundle's binary directly so LaunchServices cannot substitute
        # another registered copy of the same bundle identifier.
        proc = subprocess.Popen([os.path.join(args.app, "Contents", "MacOS", "XRG")],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(args.settle)
        run("osascript", "-e", 'tell application "XRG" to quit')
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        time.sleep(1)

        after = read_default(FRAME_KEY) or ""
        ap_ = after.split()
        dim = int(ap_[3] if vertical else ap_[2]) if len(ap_) >= 4 else -1
        restored = dim >= expected - 2
        print(f"app={args.app} orientation={args.orientation}\nseeded frame: {trap_frame.strip()}\n"
              f"autosaved after quit: {after.strip()}\n"
              f"{'height' if vertical else 'width'} {dim} (expected >= {expected - 2}) -> "
              f"{'RESTORED' if restored else 'TRAPPED'}")
        return 0 if restored else 1
    finally:
        run("pkill", "-x", "XRG"); time.sleep(1)
        run("defaults", "delete", DOMAIN)
        run("defaults", "import", DOMAIN, backup)
        print(f"defaults restored from {backup}")


if __name__ == "__main__":
    sys.exit(main())
