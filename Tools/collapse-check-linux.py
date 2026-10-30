#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Check collapse/hover against native X11 and Wayland surfaces in an isolated desktop.

Run under dbus-run-session/xvfb-run; uses the same managed desktop as desktop-check.
No personal settings, AI logs or network services are accessed.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import time

spec = importlib.util.spec_from_file_location("desktop_check", Path(__file__).with_name("desktop-check-linux.py"))
desktop_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(desktop_check)
Desktop = desktop_check.Desktop
run, require, wait_for = desktop_check.run, desktop_check.require, desktop_check.wait_for


def latest(log):
    return desktop_check.log_json(log, "XRG_DESKTOP_WINDOW", last=True)


def state(log, closed, latched, width, height):
    def observed():
        value = latest(log)
        return value if value and value["closed"] == closed and value["latched"] == latched and abs(value["native_width"] - width) <= 1 and abs(value["native_height"] - height) <= 1 else None
    return wait_for(observed, f"Window did not reach closed={closed}, latched={latched}, size={width}x{height}: {latest(log)}")


def bounds(d, identifier, name):
    if d.backend == "x11":
        g = desktop_check.geometry(identifier, d.env)
        return tuple(int(g[k]) for k in ["WIDTH", "HEIGHT", "X", "Y"])
    d.screenshot(identifier, name)
    # Select the largest connected black surface, excluding the small cursor.
    # Morphological opening would erase a thin strip's border around the + button.
    objects = run(["convert", d.output / f"{name}.png", "-fill", "white", "+opaque", "black", "-negate", "-define", "connected-components:verbose=true", "-connected-components", "4", "null:"], d.env)
    candidates = []
    for line in objects.splitlines():
        match = re.fullmatch(r"\s*\d+: (\d+)x(\d+)\+(\d+)\+(\d+) \S+ (\d+) srgb\(255,255,255\)", line)
        if match:
            w, h, x, y, area = map(int, match.groups())
            candidates.append((area, (w, h, x, y)))
    require(candidates, "Cannot locate the native Wayland surface")
    return max(candidates)[1]


def move(d, identifier, rect, title=False, plus=False, side=False):
    w, h, x, y = rect
    if plus:
        px, py = (w / 2, h - 13 * d.native_scale * d.zoom) if side else (w - 14 * d.native_scale * d.zoom, h / 2)
    elif title:
        px, py = (w / 2, h / 2) if side else (w / 3, 13 * d.native_scale * d.zoom)
    else:
        px, py = w / 2, h / 2
    args = ["xdotool", "mousemove"]
    if d.backend == "wayland":
        args += ["--window", identifier]
    run(args + [round(x + px), round(y + py)], d.env)


def outside(d):
    # Keep the pointer inside nested Weston so its X11 backend delivers a real
    # Wayland surface leave, rather than merely leaving the host X11 window.
    if d.backend == "wayland":
        run(["xdotool", "mousemove", "--window", d.weston_window, "20", "20"], d.env)
    else:
        run(["xdotool", "mousemove", "1500", "1100"], d.env)


def exercise(d, binary, fixture, layout, anchor):
    name = f"{layout}-{anchor}"
    case = d.root / name
    case.mkdir()
    env = d.app_env(case)
    prefs = Path(env["XDG_CONFIG_HOME"]) / "xrg-ng/settings.conf"
    prefs.parent.mkdir(parents=True)
    config = json.loads(run([fixture], env))
    config["layout"] = layout
    config["window_collapse"] = {"collapsed": False, "expand_on_hover": True, "anchor": anchor}
    prefs.write_text(json.dumps(config))
    outside(d)
    log = d.output / f"{name}-app.log"
    process = d.start(f"{name}-app", [binary], env)
    ready = wait_for(lambda: desktop_check.log_json(log, "XRG_DESKTOP_READY"), "No native app readiness report")
    require(ready["backend"] == d.backend, f"Wrong window backend: {ready}")
    require(abs(ready["pixels_per_point"] - d.native_scale * d.zoom) < .02, f"Wrong scale: {ready}")
    identifier = d.weston_window if d.backend == "wayland" else wait_for(lambda: desktop_check.window(process.pid, d.env), "No app window")
    d.focus(identifier)
    state(log, False, False, 220, 600)
    before = bounds(d, identifier, f"{name}-expanded")
    d.screenshot(identifier, f"{name}-expanded")
    thin = (220, 28 * d.zoom) if layout == "vertical" else (28 * d.zoom, 600)
    d.key("ctrl+m")
    initial = state(log, True, True, *thin)
    time.sleep(.15)
    collapsed = bounds(d, identifier, f"{name}-collapsed")
    require(abs(collapsed[0] - thin[0] * d.native_scale) <= 2 and abs(collapsed[1] - thin[1] * d.native_scale) <= 2,
            f"Native collapsed bounds differ: {collapsed}, expected {thin}")
    if d.backend == "x11":
        axis = 1 if layout == "vertical" else 0
        edge = before[axis + 2] + (before[axis] if anchor == "end" else 0)
        changed = collapsed[axis + 2] + (collapsed[axis] if anchor == "end" else 0)
        require(abs(edge - changed) <= 2, f"Collapse moved the selected anchor: {before} -> {collapsed}")
    d.screenshot(identifier, f"{name}-collapsed")
    time.sleep(1.2)  # Sampling continues while no graphs are painted.
    move(d, identifier, collapsed)
    opened = state(log, False, True, 220, 600)
    require(opened["snapshots"] > initial["snapshots"], "No collector progress while collapsed")
    d.screenshot(identifier, f"{name}-hover")
    d.key("ctrl+comma")
    wait_for(lambda: latest(log) and latest(log)["preferences"], "Preferences did not open")
    outside(d)
    time.sleep(.7)
    require(not latest(log)["closed"], "Hover expansion closed with Preferences active")
    if d.backend == "x11":
        child = wait_for(lambda: desktop_check.window(process.pid, d.env, "^XRG-ng Preferences$"), "Native preferences missing")
        d.focus(child)
    d.key("Escape")
    wait_for(lambda: not latest(log)["preferences"], "Preferences did not cancel")
    d.focus(identifier)
    state(log, True, True, *thin)
    time.sleep(.15)
    move(d, identifier, bounds(d, identifier, f"{name}-hover-again"))
    state(log, False, True, 220, 600)
    d.key("ctrl+m")  # Explicit expansion pins the temporary hover window.
    state(log, False, False, 220, 600)
    outside(d)
    time.sleep(.6)
    require(not latest(log)["closed"], "Pinned expansion retracted after pointer exit")
    d.key("ctrl+m")
    state(log, True, True, *thin)
    report = d.close(process, log, identifier)
    saved = json.loads(prefs.read_text())
    require(saved["window_size"] == {"width": 220, "height": 600}, f"Transient dimensions were saved: {saved['window_size']}")
    require(saved["window_collapse"] == {"collapsed": True, "expand_on_hover": True, "anchor": anchor}, "Manual latch did not persist")
    outside(d)
    restored_log = d.output / f"{name}-restored-app.log"
    process = d.start(f"{name}-restored-app", [binary], d.app_env_reuse(case))
    state(restored_log, True, True, *thin)
    identifier = d.weston_window if d.backend == "wayland" else wait_for(lambda: desktop_check.window(process.pid, d.env), "No restored app window")
    d.focus(identifier)
    time.sleep(.15)
    move(d, identifier, bounds(d, identifier, f"{name}-restored"), plus=True, side=layout == "horizontal")
    run(["xdotool", "click", "1"], d.env)
    state(restored_log, False, False, 220, 600)
    move(d, identifier, bounds(d, identifier, f"{name}-before-double-click"), title=True)
    time.sleep(.6)  # Separate the preceding + click from this double-click gesture.
    run(["xdotool", "click", "--repeat", "2", "--delay", "100", "1"], d.env)
    state(restored_log, True, True, *thin)
    outside(d)
    d.key("ctrl+m")
    state(restored_log, False, False, 220, 600)
    restored = d.close(process, restored_log, identifier)
    require(json.loads(prefs.read_text())["window_size"] == {"width": 220, "height": 600}, "Expanded restore dimensions changed after relaunch")
    require(report["valid_snapshots"] > 0 and restored["dropped_events"] == 0, "Missing samples or diagnostic overflow")
    require(report["ui_passes"] < 450, f"Unexpected repaint loop: {report['ui_passes']}")
    (d.output / f"{name}.json").write_text(json.dumps({"initial": before, "collapsed": collapsed, "native_report": report, "restored_report": restored}, indent=2) + "\n")
    return name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["binary", "fixture", "output"]:
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--backend", choices=["x11", "wayland"], required=True)
    parser.add_argument("--native-scale", type=float, choices=[1., 1.25], default=1.)
    parser.add_argument("--zoom", type=float, choices=[1., 1.25], default=1.)
    args = parser.parse_args()
    require(args.backend == "x11" or args.native_scale == 1., "Nested Weston uses native scale 1")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="xrg-collapse-") as scratch:
        d = Desktop(Path(scratch), args.output, os.environ, args.backend, args.native_scale, args.zoom)
        try:
            d.boot()
            cases = [exercise(d, args.binary.resolve(), args.fixture.resolve(), layout, anchor)
                     for layout in ["vertical", "horizontal"] for anchor in ["start", "end"]]
            (args.output / "summary.json").write_text(json.dumps({"architecture": os.uname().machine, "backend": args.backend, "native_scale": args.native_scale, "zoom": args.zoom, "cases": cases, "software_rendering": True}, indent=2) + "\n")
            print(f"LINUX_COLLAPSE_OK backend={args.backend} cases={len(cases)} scale={args.native_scale} zoom={args.zoom}")
        finally:
            d.shutdown()


if __name__ == "__main__":
    main()
