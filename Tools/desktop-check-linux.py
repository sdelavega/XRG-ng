#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Exercise native X11/Wayland windows and measure isolated, idle application costs.

Run inside dbus-run-session/xvfb-run. Fluxbox manages X11; nested Weston supplies
real Wayland surfaces. The app's native handle report must match the requested
backend. This is software-renderer evidence, not physical GPU/power validation.
"""
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def require(value, message):
    if not value:
        raise RuntimeError(message)


def run(args, env, check=True):
    return subprocess.run(list(map(str, args)), env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          check=check, timeout=10).stdout.strip()


def wait_for(test, message, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = test()
        if value:
            return value
        time.sleep(.025)
    raise RuntimeError(message)


def log_json(path, prefix, last=False):
    if not path.exists():
        return None
    lines = path.read_text(errors="replace").splitlines()
    for line in reversed(lines) if last else lines:
        if line.startswith(prefix + " "):
            return json.loads(line[len(prefix) + 1:])
    return None


def process_stats(pid):
    root = Path(f"/proc/{pid}")
    fields = (root / "stat").read_text().rsplit(") ", 1)[1].split()
    status = dict(line.split(":", 1) for line in (root / "status").read_text().splitlines() if ":" in line)
    threads = {}
    for entry in (root / "task").iterdir():
        try:
            data = dict(line.split(":", 1) for line in (entry / "status").read_text().splitlines() if ":" in line)
            threads[entry.name] = {"name": data["Name"].strip(),
                                   "switches": int(data.get("voluntary_ctxt_switches", "0"))}
        except FileNotFoundError:
            pass
    return {"ticks": int(fields[11]) + int(fields[12]),
            "rss_mib": int(status["VmRSS"].split()[0]) / 1024,
            "threads": threads}


def pss_mib(pid):
    try:
        for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
            if line.startswith("Pss:"):
                return int(line.split()[1]) / 1024
    except (FileNotFoundError, PermissionError):
        pass
    return None


def window(pid, env, title=None):
    args = ["xdotool", "search", "--all", "--onlyvisible"]
    if pid is not None:
        args += ["--pid", str(pid)]
    if title:
        args += ["--name", title]
    found = run(args, env, check=False).splitlines()
    return next((line for line in found if line.isdigit()), None)


def geometry(identifier, env):
    return dict(line.split("=", 1) for line in run(["xdotool", "getwindowgeometry", "--shell", identifier], env).splitlines())


class Desktop:
    def __init__(self, root, output, env, backend, native_scale=1., zoom=1.):
        self.env = dict(env)
        self.root, self.output, self.backend = root, output, backend
        self.native_scale, self.zoom = native_scale, zoom
        self.processes = []
        self.files = []
        self.weston_window = None

    def start(self, name, args, env=None):
        stream = (self.output / f"{name}.log").open("w")
        self.files.append(stream)
        process = subprocess.Popen(list(map(str, args)), env=env or self.env,
                                   stdout=stream, stderr=subprocess.STDOUT)
        self.processes.append(process)
        return process

    def boot(self):
        self.env.update(HOME=str(self.root / "desktop-home"), LIBGL_ALWAYS_SOFTWARE="1",
                        WINIT_X11_SCALE_FACTOR=str(self.native_scale))
        Path(self.env["HOME"]).mkdir()
        keys = self.root / "keys"
        # Let Weston, rather than the host WM, receive its native close shortcut.
        keys.write_text("Mod4 F12 :Nop\n" if self.backend == "wayland" else "Mod1 F4 :Close\n")
        rc = self.root / "fluxbox.rc"
        rc.write_text(f"session.keyFile: {keys}\n")
        wm = self.start("fluxbox", ["fluxbox", "-rc", rc, "-no-toolbar", "-no-slit"])
        wait_for(lambda: "window id" in run(["xprop", "-root", "_NET_SUPPORTING_WM_CHECK"], self.env, False),
                 "Fluxbox did not become the window manager")
        require(wm.poll() is None, "Fluxbox exited during startup")
        picom = self.start("picom", ["picom", "--backend", "xrender", "--config", "/dev/null"])
        time.sleep(.3)
        require(picom.poll() is None, "X11 compositing could not start")
        if self.backend == "wayland":
            runtime = self.root / "runtime"
            runtime.mkdir(mode=0o700)
            self.env["XDG_RUNTIME_DIR"] = str(runtime)
            config = self.root / "weston.ini"
            config.write_text("[core]\nidle-time=0\n[shell]\nbackground-color=0xff234156\npanel-position=none\nlocking=false\nstartup-animation=none\nclose-animation=none\nfocus-animation=none\n")
            weston = self.start("weston", ["weston", "--backend=x11", "--renderer=pixman",
                                           "--width=1280", "--height=1000", "--socket=wayland-xrg",
                                           f"--config={config}", "--idle-time=0"])
            wait_for(lambda: (runtime / "wayland-xrg").exists(), "Weston did not create its Wayland socket")
            self.weston_window = wait_for(lambda: next((v for v in run(["xdotool", "search", "--onlyvisible", "--class", "^Weston Compositor$"], self.env, False).splitlines() if v.isdigit()), None), "Weston's X11 host window did not appear")
            self.env["WAYLAND_DISPLAY"] = "wayland-xrg"

    def app_env(self, case):
        env = dict(self.env, HOME=str(case / "home"), XDG_CONFIG_HOME=str(case / "config"),
                   XDG_CACHE_HOME=str(case / "cache"), XDG_DATA_HOME=str(case / "data"),
                   XRG_DESKTOP_REPORT="1", XRG_DESKTOP_ZOOM=str(self.zoom))
        Path(env["HOME"]).mkdir()
        if self.backend == "wayland":
            env.pop("DISPLAY", None)  # A silent X11 fallback is impossible.
        else:
            env.pop("WAYLAND_DISPLAY", None)
        return env

    def focus(self, identifier):
        run(["xdotool", "windowactivate", "--sync", identifier], self.env)

    def key(self, keys):
        run(["xdotool", "key", "--clearmodifiers", keys], self.env)

    def close(self, process, log, identifier):
        self.focus(identifier)
        self.key("ctrl+q" if self.backend == "wayland" else "alt+F4")
        try:
            code = process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"Clean window close did not exit the app; see {log}")
        require(code == 0, f"Application failed ({code}); see {log}")
        return wait_for(lambda: log_json(log, "XRG_DESKTOP_REPORT"), "Application did not emit desktop diagnostics")

    def profile(self, binary, fixture, name, interval, opacity, seconds, hidden=False,
                interactions=False, seed=True, existing=None):
        case = existing or self.root / name
        if existing is None:
            case.mkdir()
            env = self.app_env(case)
        else:
            env = self.app_env_reuse(case)
        prefs = Path(env["XDG_CONFIG_HOME"]) / "xrg-ng/settings.conf"
        if seed:
            prefs.parent.mkdir(parents=True)
            prefs.write_text(run([fixture, str(interval), str(opacity)], env))
        log = self.output / f"{name}-app.log"
        process = self.start(f"{name}-app", [binary], env)
        ready = wait_for(lambda: log_json(log, "XRG_DESKTOP_READY"), f"No native app readiness report; see {log}")
        require(ready["backend"] == self.backend, f"Wrong native backend: {ready}")
        require(abs(ready["pixels_per_point"] - self.native_scale * self.zoom) < .02,
                f"Requested scale was not active: {ready}")
        anchor = time.monotonic() - ready["at_ms"] / 1000
        identifier = self.weston_window if self.backend == "wayland" else wait_for(lambda: window(process.pid, self.env), "App window missing")
        self.focus(identifier)
        run(["xdotool", "mousemove", "1500", "1100"], self.env)
        if hidden:
            run(["xdotool", "windowminimize", identifier], self.env)
        time.sleep(3)
        begin = time.monotonic()
        start = process_stats(process.pid)
        time.sleep(seconds)
        end = process_stats(process.pid)
        finish = time.monotonic()
        pss = pss_mib(process.pid)
        thread_switches = sum(end["threads"][tid]["switches"] - old["switches"]
                              for tid, old in start["threads"].items() if tid in end["threads"])
        notifier_switches = sum(end["threads"][tid]["switches"] - old["switches"]
                                for tid, old in start["threads"].items()
                                if tid in end["threads"] and old["name"] == "xrg-ui-notify")
        self.focus(identifier)
        if interactions:
            expected_size = self.exercise(identifier, process, ready, log)
        report = self.close(process, log, identifier)
        require(report["valid_snapshots"] > 0, "No valid collector snapshot reached the UI")
        require(report["dropped_events"] == 0, "Desktop diagnostics overflowed")
        lower, upper = (begin - anchor) * 1000 + 100, (finish - anchor) * 1000 - 100
        passes = sum(lower <= event["at_ms"] <= upper for event in report["events"])
        rate = passes / max(seconds - .2, .1)
        require(rate < 8, f"Idle UI is continuously repainting: {rate:.2f} passes/s")
        if interactions:
            require(report["preferences_openings"] >= 1, "Preferences shortcut did not open a native window")
            require(report["detail_openings"] >= 3, "Enter, Space or double-click did not open graph details")
            require(report["max_known_viewports"] >= 2, "No second native viewport was observed")
        metrics = {"name": name, "backend": report["backend"], "renderer": report["renderer"],
                   "sampling_interval_ms": interval, "opacity": opacity, "hidden": hidden,
                   "native_scale": self.native_scale, "ui_zoom": self.zoom,
                   "measurement_seconds": finish - begin,
                   "cpu_one_core_percent": 100 * (end["ticks"] - start["ticks"]) / os.sysconf("SC_CLK_TCK") / (finish - begin),
                   "rss_mib": end["rss_mib"], "pss_mib": pss,
                   "voluntary_thread_switches": thread_switches,
                   "notifier_thread_switches": notifier_switches,
                   "ui_passes_per_second": rate, "native_report": report}
        (self.output / f"{name}.json").write_text(json.dumps(metrics, indent=2) + "\n")
        if interactions:
            current = json.loads(prefs.read_text())
            require(current["window_size"] != {"width": 220, "height": 600}, "Native resize was not saved")
            require(all(abs(current["window_size"][axis] - expected_size[axis]) <= 1 for axis in ["width", "height"]),
                    f"Saved size lost native dimensions under zoom: saved={current['window_size']} expected={expected_size}")
        return metrics, case

    def app_env_reuse(self, case):
        env = dict(self.env, HOME=str(case / "home"), XDG_CONFIG_HOME=str(case / "config"),
                   XDG_CACHE_HOME=str(case / "cache"), XDG_DATA_HOME=str(case / "data"),
                   XRG_DESKTOP_REPORT="1", XRG_DESKTOP_ZOOM=str(self.zoom))
        env.pop("DISPLAY" if self.backend == "wayland" else "WAYLAND_DISPLAY", None)
        return env

    def screenshot(self, identifier, name):
        run(["import", "-window", identifier, self.output / f"{name}.png"], self.env)

    def wayland_bounds(self, image="desktop-before-resize"):
        # Weston 13 places surfaces itself. Locate our one opaque Classic surface
        # in the isolated compositor capture; opening removes the small cursor.
        rect = run(["convert", self.output / f"{image}.png",
                    "-fill", "white", "+opaque", "black", "-negate",
                    "-morphology", "Open", "Rectangle:25x25", "-format", "%@", "info:"], self.env)
        match = re.fullmatch(r"(\d+)x(\d+)\+(\d+)\+(\d+)", rect)
        require(match is not None, f"Cannot locate the Wayland test surface: {rect}")
        width, height, x, y = map(int, match.groups())
        require(width >= 100 and height >= 100, "Wayland capture lacks the test surface")
        return width, height, x, y

    def exercise(self, identifier, process, ready, log):
        self.focus(identifier)
        self.screenshot(identifier, "desktop-before-resize")
        if self.backend == "x11":
            run(["xdotool", "windowsize", "--sync", identifier, "320", "700"], self.env)
        else:
            x, y = self.wayland_bounds()[2:]
            run(["xdotool", "mousemove", "--window", identifier, x + round(ready["width"] * ready["pixels_per_point"]) - 2, y + round(ready["height"] * ready["pixels_per_point"]) - 2], self.env)
            time.sleep(.2)  # Deliver hover/press before moving beyond the hit target.
            run(["xdotool", "mousedown", "1"], self.env)
            time.sleep(.2)
            for _ in range(4):
                run(["xdotool", "mousemove_relative", "20", "15"], self.env)
                time.sleep(.1)
            run(["xdotool", "mouseup", "1"], self.env)
        time.sleep(.3)
        self.screenshot(identifier, "desktop-resized")
        if self.backend == "x11":
            actual = geometry(identifier, self.env)
            physical_width, physical_height = int(actual["WIDTH"]), int(actual["HEIGHT"])
        else:
            physical_width, physical_height = self.wayland_bounds("desktop-resized")[:2]
        expected_size = {"width": round(physical_width / self.native_scale), "height": round(physical_height / self.native_scale)}
        self.key("ctrl+comma")
        time.sleep(.4)
        if self.backend == "x11":
            preferences = wait_for(lambda: window(process.pid, self.env, "^XRG-ng Preferences$"), "Preferences window missing")
            self.focus(preferences)
        self.screenshot(identifier, "desktop-preferences")
        self.key("Escape")
        time.sleep(.3)
        if self.backend == "x11":
            wait_for(lambda: window(process.pid, self.env, "^XRG-ng Preferences$") is None, "Escape did not cancel Preferences")
        self.focus(identifier)
        for _ in range(14):
            self.key("Tab")
            time.sleep(.15)
            if log_json(log, "XRG_DESKTOP_FOCUS", last=True) == {"name": "CPU graph"}:
                break
        else:
            raise RuntimeError("Tab navigation could not focus the CPU graph")
        for activation in ["Return", "space"]:
            self.key(activation)
            time.sleep(.5)
            if self.backend == "x11":
                child = wait_for(lambda: window(process.pid, self.env, "CPU$"), "Keyboard did not open CPU details")
                self.focus(child)
            self.screenshot(identifier, f"keyboard-{activation}")
            self.key("Escape")
            time.sleep(.4)
            self.focus(identifier)
        self.key("shift+F10")
        time.sleep(.2)
        self.screenshot(identifier, "keyboard-graph-menu")
        self.key("Escape")
        time.sleep(.2)
        if self.backend == "x11":
            root = geometry(identifier, self.env)
            x, y = int(root["X"]) + round(65 * ready["pixels_per_point"]), int(root["Y"]) + round(60 * ready["pixels_per_point"])
            run(["xdotool", "mousemove", str(x), str(y), "click", "--repeat", "2", "--delay", "100", "1"], self.env)
        else:
            # Resizing preserves the opposite corner of the undecorated surface.
            x, y = self.wayland_bounds()[2:]
            x += round(65 * ready["pixels_per_point"])
            y += round(60 * ready["pixels_per_point"])
            run(["xdotool", "mousemove", "--window", identifier, str(x), str(y), "click", "--repeat", "2", "--delay", "100", "1"], self.env)
        time.sleep(.4)
        self.screenshot(identifier, "desktop-details")
        self.key("Escape" if self.backend == "wayland" else "alt+F4")
        time.sleep(.3)
        require(process.poll() is None, "Closing a child window unexpectedly closed the application")
        return expected_size

    def shutdown(self):
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
        for stream in self.files:
            stream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backend", choices=["x11", "wayland"], required=True)
    parser.add_argument("--seconds", type=int, default=15)
    parser.add_argument("--profile-only", action="store_true")
    parser.add_argument("--interaction-only", action="store_true")
    parser.add_argument("--native-scale", type=float, choices=[1., 1.25, 1.5, 2.], default=1.)
    parser.add_argument("--zoom", type=float, choices=[1., 1.25, 1.5, 2.], default=1.)
    args = parser.parse_args()
    require(10 <= args.seconds <= 120, "Measurement duration must be 10–120 seconds")
    require(args.backend == "x11" or args.native_scale == 1., "Nested Weston uses native scale 1; test UI zoom separately")
    require(os.environ.get("DISPLAY"), "Run under xvfb-run or an isolated X server")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="xrg-desktop-") as scratch:
        desktop = Desktop(Path(scratch), args.output, os.environ, args.backend, args.native_scale, args.zoom)
        try:
            desktop.boot()
            profiles = []
            cases = [("normal", 1000, 1., False), ("slow", 10000, 1., False), ("translucent", 10000, .7, False)]
            if args.backend == "x11":
                cases.append(("minimized", 1000, 1., True))
            if args.interaction_only:
                cases = cases[:1]
            for name, period, opacity, hidden in cases:
                result, case = desktop.profile(args.binary.resolve(), args.fixture.resolve(), name, period, opacity, args.seconds,
                                               hidden, name == "normal" and not args.profile_only)
                profiles.append(result)
                if name == "normal" and not args.profile_only:
                    restored, _ = desktop.profile(args.binary.resolve(), args.fixture.resolve(), "restored", period, opacity, 10,
                                                   seed=False, existing=case)
                    sizes = {(e["native_width"], e["native_height"]) for e in restored["native_report"]["events"]}
                    saved = json.loads((case / "config/xrg-ng/settings.conf").read_text())["window_size"]
                    require((saved["width"], saved["height"]) in sizes, "Saved window dimensions did not restore")
            (args.output / "summary.json").write_text(json.dumps({"architecture": os.uname().machine,
                "software_rendering": True, "backend": args.backend, "profiles": profiles}, indent=2) + "\n")
            print(f"LINUX_DESKTOP_OK backend={args.backend} profiles={len(profiles)}")
        finally:
            desktop.shutdown()


if __name__ == "__main__":
    main()
