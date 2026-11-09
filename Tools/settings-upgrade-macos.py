#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Prove settings survive 0.2.2 -> 0.2.3 -> 0.2.2 on macOS.

The check seeds a *disposable* NSUserDefaults domain (a renamed bundle id,
``com.sdelavega.xrg.upgradecheck.<uuid>``) from a 0.2.2 defaults export.

THE 0.2.3 DOCUMENT IS WRITTEN BY THE LAUNCHED APP ITSELF (Task 13 fix round 2,
finding 1 / ruling R25). The app has ONE narrowly gated startup path: only a
non-production bundle whose process sets
``XRG_UPGRADE_CHECK_SOURCE_DOMAIN=<disposable domain>`` runs the real
document-backed first-launch migration, over that disposable domain, into the
R11 private store ``~/Library/Application Support/XRG-ng-Private/<id>/``.
So the script starts with no document, seeds the domain, launches the supplied
0.2.3 app WITH that env var, quits it, and validates the document THE APP wrote
against the expected oracle. The framework driver and the shared-core probe are
now ONLY supplementary validation (the driver uses the supplied app's OWN
framework -- no this-checkout fallback). A negative control (--withhold-upgrade-env,
or startup migration disabled) writes NO document and fails while the store
symbols remain.

ORDER (fix round 3, finding 2): seed -> NORMALISE 0.2.2 until its settings
snapshot is STABLE (a bounded launch loop, BEFORE 0.2.3) -> CAPTURE THE
REFERENCE DEFAULTS (before 0.2.3 EVER runs) -> launch 0.2.3 (migration, env
var) -> quit -> validate the document the app wrote -> [R26 measurement:
relaunch 0.2.3 with the SAME geometry, byte-compare the document] -> relaunch
0.2.2 (downgrade) -> quit -> COMPARE to the reference. Capturing the reference
BEFORE 0.2.3 is the whole point: any persistent value 0.2.3 changes (and 0.2.2
preserves) is then absent from the reference but present in the final snapshot,
so the compare FAILS. The migration oracle is DERIVED CONSISTENTLY FROM THE
NORMALISED SEED (the exact domain the 0.2.3 app migrated), not from a separate
raw fixture. The 0.2.3 app expands the window geometry, so 0.2.2's first
(cold) launch writes different layout-feedback sizes than warm launches;
normalising until TWO CONSECUTIVE settings snapshots are IDENTICAL keeps ALL
26 mapped XRGModule_* size keys IN the comparison (fix round 2, finding 2)
rather than excluding them. Fix round 4 (finding 2a): that CONVERGENCE is
REQUIRED within MAX_NORMALISE_ATTEMPTS -- exhausting the bounded attempts
without it FAILS the check (never sets downgrade_normalised, never OK). A
probe-only/--skip-launch run NEVER prints SETTINGS_UPGRADE_MACOS_OK and NEVER
claims a relaunch.

SIZE KEYS (fix round 3 finding 2; fix round 4 finding 2): the launched app's
document MUST contain ALL 26 EXPLICIT graphs.<id>.size_width/height keys
(LAYOUT_SIZE_KEYS, not a regex). Fix round 4 requires CORRECTNESS, not just a
valid range: assert_layout_sizes derives the EXPECTED width/height of every
displayed/hidden graph and the seeded CPU height override (140) from the app's
own layout rules (XRGModuleManager.windowChanged horizontal branch, plus
XRGModule.dimension / minHeight) applied to the controlled launch geometry and
the seed, and checks each value within a stated tolerance. All-zero sizes, a
CPU override changed 140->900, or a hidden graph with a nonzero size all FAIL.
The 26 keys are still projected out ONLY of the app-vs-oracle DOCUMENT
comparison (runtime layout feedback); they are validated here and included in
the post-downgrade DOMAIN comparison.

POST-DOWNGRADE EXCLUSIONS are ONLY genuinely volatile AppKit window geometry:
``NSWindow Frame `` (autosaved frames) and ``unminimizedFrame`` (restore rect).
No mapped setting is excluded.

R26 MEASUREMENT is observational ONLY: after the migration launch the app is
launched a second time with the same geometry and its document is byte-compared
before/after. The result (rewritten or not, which keys) is written to the
summary and the report's concerns; the check NEVER gates success on it.

SAFETY (absolute): the real production defaults domain ``com.sdelavega.xrg``,
its ~/Library/Preferences plist, and the real ~/Library/Application
Support/XRG-ng/settings.json are NEVER read, written, exported, deleted or
launched against. Protected --seed/--expected inputs that resolve (realpath,
symlinks followed) to those files are refused before anything is read; a
coordinator-created export copy in scratch is accepted. Every target id is a
generated UUID in a private namespace. Cleanup attempts every step, checks
return codes, verifies the disposable domain/plist/private folder are gone and
reports accumulated failures; the OK line is printed only after cleanup
succeeded (non-zero exit otherwise). Catchable termination signals run all
``finally`` blocks. Storage deletion is GATED on confirmed process-group
termination (finding 3): if terminate_and_reap cannot confirm a group is gone,
cleanup is NOT invoked, the retained disposable paths are printed, and the run
fails with a non-zero exit and NO OK line.

Prints SETTINGS_UPGRADE_MACOS_OK on full success.
"""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True

PRODUCTION_ID = "com.sdelavega.xrg"
UPGRADE_PREFIX = "com.sdelavega.xrg.upgradecheck."
# The app's gated startup path reads exactly this variable (R25); its value is
# the disposable source domain. Withholding it is the negative control.
UPGRADE_ENV_KEY = "XRG_UPGRADE_CHECK_SOURCE_DOMAIN"
OK_LINE = "SETTINGS_UPGRADE_MACOS_OK"
PROBE_ONLY_LINE = "SETTINGS_UPGRADE_MACOS_PROBE_ONLY"
TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parent
FIXTURES = REPO / "Shared/Tests/Fixtures/settings"
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")
# Termination signals that must run Python's ``finally`` blocks (and therefore
# a launch-level process-group reap + verified cleanup) before the process dies.
SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)

# --------------------------------------------------------------------------
# Post-downgrade exclusions (finding 2): ONLY genuinely volatile AppKit window
# geometry. Every mapped setting (including the 26 XRGModule_* graph width/height
# keys, docs/settings-inventory.md §339-364) is COMPARED. These are not settings:
#   - "NSWindow Frame " prefix: EVERY key under this prefix is an AppKit-
#     autosaved window frame, rewritten with live window geometry each launch
#     (dynamic autosave name) -- genuinely volatile AppKit state, not a setting.
#   - "unminimizedFrame": the graph window's AppKit minimize/restore rectangle,
#     rewritten on every launch -- genuinely volatile AppKit state, not a setting.
# No other prefix or key is excluded. Mapped keys that a launch rewrites are
# NORMALISED by running the 0.2.2 baseline once before capturing the reference.
# --------------------------------------------------------------------------
VOLATILE_PREFIXES = ("NSWindow Frame ",)
VOLATILE_KEYS = frozenset({"unminimizedFrame"})

# The EXACT 26 graphs.<id>.size_width/height settings (13 graphs x 2). Fix
# round 3 replaces the old permissive regex (r"^graphs\..*\.size_(width|height)$")
# with this explicit list: docs/settings-inventory.md §339-364 maps exactly these
# legacy XRGModule_* keys. A key NOT in this list is a real setting and is NEVER
# silently projected out. These are the runtime layout-feedback values the
# launched 0.2.3 app writes into settings.json; they are projected out ONLY of
# the app-vs-oracle DOCUMENT comparison, but MUST be present and valid
# (assert_layout_sizes) and are included in the post-downgrade DOMAIN comparison.
GRAPH_IDS = ("cpu", "gpu", "npu", "vram", "memory", "battery",
             "temperature", "network", "disk", "ai", "fans", "weather", "stock")
LAYOUT_SIZE_KEYS = frozenset(
    f"graphs.{gid}.size_{dim}" for gid in GRAPH_IDS for dim in ("width", "height"))

# Seed-derived inputs (fix round 4, finding 2b). Each comes from the SEED
# fixture Shared/Tests/Fixtures/settings/macos-0.2.2-defaults.plist:
#   showGPUGraph=false, showWeatherGraph=false -> exactly gpu + weather hidden,
#     the other 11 displayed; graphPresentationV1 cpu.height=140 (its
#     gpu.height=72 is irrelevant because gpu is hidden);
#   borderWidth=6, graphOrientationVertical=false (HORIZONTAL),
#     graphFont=Menlo-Regular 11, windowWidth=280, windowHeight=684,
#     "NSWindow Frame XRG"={{216,136},{280,684}}, unminimizedFrame=280x684.
# App-source constants: moduleSeparatorWidth=2 and minHeight=30 are the
# XRGModuleManager.swift / XRGModule.swift defaults; titleHeight=
# XRGModule.dimension(textRectHeight)=13 = the Menlo-11 "A" line height the
# app derives from the seeded font (XRGSettings.swift / XRGModuleManager.swift:75).
# See the report's "Fix round 4 / size derivation" for the full derivation.
HIDDEN_GRAPHS = frozenset({"gpu", "weather"})
DISPLAYED_GRAPHS = tuple(gid for gid in GRAPH_IDS if gid not in HIDDEN_GRAPHS)
HEIGHT_OVERRIDES = {"cpu": 140}

# Fix round 4, finding 2b: the 26 EXPECTED sizes are DERIVED from the app's OWN
# layout rules applied to the CONTROLLED launch geometry and the SEED -- they
# are NOT copied from any observed settings.json. The only "observed output" is
# the 26 graphs.*.size_* values the app writes; here every expected value is
# COMPUTED by XRGModuleManager.windowChanged(to:)'s HORIZONTAL else-branch
# (XRGModuleManager.swift:206-209), with XRGModule.dimension/minHeight
# (XRGModule.swift:51,120-122) and the zero rule for hidden modules
# (XRGModuleManager.swift:176-179).
#
# CONTROLLED LAUNCH GEOMETRY (the `size` INPUT to windowChanged): the seeded
# window is 280x684 and collapsed. On launch the app's checkWindowSize()
# (XRGGraphWindow.swift:498-504) expands it to manager.getMinSize()
# (XRGModuleManager.swift:154-166) = titleHeight + (maxMinWidth + separator)
# *count + 2*border, i.e. wide enough for the 11-graph horizontal row. On THIS
# controlled host (Menlo-11 labels, 1920x1205 display) that frame is 1779x684
# pt (AppKit rounds it to whole points); the domain's unminimizedFrame becomes
# {{...,...},{1779,684}} after the launch. 1779 is therefore a CONTROLLED
# launch INPUT, not one of the 26 document values being validated; a frame that
# drifted from it would make the width assertion FAIL loudly, not pass.
#
# Applying windowChanged(to: 1779x684), HORIZONTAL branch:
#   border=6; separator=2; titleHeight=13; minHeight=30; count=11;
#   contentWidth  = 1779 - 2*6 = 1767;  contentHeight = 684 - 2*6 = 672;
#   unit = max(0, 1767 - 13 - 2*11)/11 = 1732/11 = 157.45454545454547;
#   displayed width = unit (the same for all 11 displayed graphs);
#   displayed height = min(672, fixedHeight ?? 672):
#     cpu fixedHeight = max(minHeight=30, 140) = 140 -> 140 (the override);
#     the other 10 displayed graphs have no height override -> 672;
#   hidden (gpu, weather): apply(.zero) clamps to 0, saveSize stores 0
#     -> width=height=0.
# So the width, both height classes, the CPU override and the zeros are all
# DERIVED; a wrong-but-in-range value (0, 900, a nonzero hidden size) is now
# rejected by assert_layout_sizes, which the old [0, 964] range check accepted.
CONTROLLED_GEOMETRY = {
    "windowWidth": 280,
    "windowHeight": 684,
    "windowFrame": "{{216, 136}, {280, 684}}",
    "orientation": "horizontal",
    "source": "Shared/Tests/Fixtures/settings/macos-0.2.2-defaults.plist",
    "observedDisplay": "1920x1205",
    # Controlled launch geometry (the windowChanged `size` argument):
    "expandedWindowWidth": 1779,
    # Seed + XRGModuleManager / XRGModule layout-rule constants:
    "borderWidth": 6,
    "moduleSeparatorWidth": 2,
    "minHeight": 30,
    "textRectHeight": 13,
    "hiddenGraphs": HIDDEN_GRAPHS,
    "displayedGraphs": DISPLAYED_GRAPHS,
    "heightOverrides": HEIGHT_OVERRIDES,
}
# A finite, non-negative graph dimension larger than windowWidth+windowHeight
# is inconsistent with launching inside the controlled geometry: a SECONDARY
# sanity bound (the correctness check below is far tighter).
SIZE_UPPER_BOUND = CONTROLLED_GEOMETRY["windowWidth"] + CONTROLLED_GEOMETRY["windowHeight"]
# Tolerances (points). The layout inputs are integer points except the font-
# derived titleHeight; a +/-1 pt tolerance covers sub-point font-metric/window-
# frame rounding (the 11-way share moves <0.1 pt per graph for a 1 pt frame
# change). It still rejects the corruptions finding 2b names (an all-zero
# displayed size, a 900 CPU height, a nonzero hidden size) by >= 138 pt.
# Hidden values are EXACTLY 0: windowChanged applies NSSize.zero to
# non-displayed modules and XRGModule.dimension/saveSize store 0.0, so a tiny
# 1e-6 tolerance (float representation only) rejects ANY meaningful nonzero
# hidden size -- a +/-0.5 pt tolerance would wrongly accept e.g. 0.4.
SIZE_TOLERANCE = 1.0
HIDDEN_SIZE_TOLERANCE = 1e-6
# Fix round 4, finding 2a: the 0.2.2 normalisation launch loop is BOUNDED (it
# cannot run indefinitely) and MUST demonstrate convergence within this many
# attempts, or the check fails.
MAX_NORMALISE_ATTEMPTS = 3

# The ordered phases of a FULL run (finding 2). The DOWNGRADE REFERENCE is
# captured after normalisation and BEFORE 0.2.3 is ever launched; main() follows
# this order and the unit tests assert the invariant directly.
DOWNGRADE_PHASES = (
    "seed",
    "0.2.2-normalise",
    "capture-reference",
    "0.2.3-upgrade",
    "validate-app-document",
    "0.2.3-relaunch-r26",
    "0.2.2-downgrade",
    "compare-to-reference",
)


class DocumentMismatch(RuntimeError):
    """The 0.2.3 document differs from the pinned oracle (ruling R21).

    Never resolve this by editing the fixture: a legitimate difference since
    Task 12 (Stocks mapped in the shared core) must be reported, not papered
    over. The main() error path prints this message verbatim.
    """


class Interrupted(Exception):
    """A catchable termination signal; raised so every ``finally`` runs."""

    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"SETTINGS_UPGRADE_MACOS: interrupted by signal {signum}")


# --------------------------------------------------------------------------
# Pure, side-effect-free helpers (unit tested).
# --------------------------------------------------------------------------

def make_token():
    return str(uuid.uuid4())


def domain_for(token):
    return UPGRADE_PREFIX + token


def assert_safe_ids(ids):
    """Refuse to run if any target bundle id could reach the production domain."""
    if not ids:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: no target bundle ids")
    for ident in ids:
        if not isinstance(ident, str) or ident == PRODUCTION_ID or not ident.startswith(UPGRADE_PREFIX):
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: refusing unsafe target id {ident!r}")
        suffix = ident[len(UPGRADE_PREFIX):]
        try:
            if str(uuid.UUID(suffix)) != suffix:
                raise ValueError
        except ValueError as error:
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: target id has no generated UUID: {ident!r}") from error


def private_paths(home, domain):
    """Everything a renamed bundle id can create in the user's Library.

    Only ever called for a private, generated UUID domain, so cleanup can never
    touch the production plist or the production settings store.
    """
    assert_safe_ids([domain])
    home = Path(home)
    library = home / "Library"
    paths = []
    for ident in {domain, domain.lower()}:
        paths.extend([
            library / "Preferences" / (ident + ".plist"),
            library / "Caches" / ident,
            library / "Saved Application State" / (ident + ".savedState"),
            library / "HTTPStorages" / ident,
            library / "Application Support" / "XRG-ng-Private" / ident,
        ])
    return paths


def protected_paths(home):
    """The two real production files no input may resolve to."""
    home = Path(home)
    return [
        home / "Library/Preferences/com.sdelavega.xrg.plist",
        home / "Library/Application Support/XRG-ng/settings.json",
    ]


def assert_safe_inputs(seed, expected, home):
    """Refuse protected --seed/--expected inputs BEFORE anything is read.

    ``os.path.realpath`` follows symlinks, so a scratch alias pointing at the
    production plist is refused too. A coordinator-created export copy in
    scratch has a different realpath and is accepted (ruling R9).
    """
    protected = {os.path.realpath(str(path)).lower() for path in protected_paths(home)}
    for label, path in (("--seed", seed), ("--expected", expected)):
        resolved = os.path.realpath(str(path)).lower()
        if resolved in protected:
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: refusing protected {label} input: {path} "
                f"resolves to a production preferences/settings file")


def app_document_path(home, domain):
    """The app's R11 document store for a renamed (non-production) bundle id."""
    assert_safe_ids([domain])
    return (Path(home) / "Library/Application Support/XRG-ng-Private" / domain / "settings.json")


def assert_app_document_backend(symbols):
    """Tie the check to the supplied app binary (finding 1, negative control).

    A supplied app whose main executable does not contain the document store
    must not be able to pass. The negative control keeps these symbols but
    disables startup migration, so it fails later for lack of a document.
    """
    if "XRGSettingsStore" not in symbols or "XRGSettingsMigration" not in symbols:
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: the supplied 0.2.3 app has no XRGSettingsStore "
            "document backend / XRGSettingsMigration; an app that never migrates must fail")


def upgrade_check_env(domain, enabled=True):
    """The env var gating the app's startup migration (R25).

    Withholding it (negative control) leaves a renamed bundle on the legacy
    path: it writes NO document, so the check fails while the app still HAS the
    store symbols (the nm gate still passes).
    """
    assert_safe_ids([domain])
    return {UPGRADE_ENV_KEY: domain} if enabled else {}


def default_seed_path(root=REPO):
    return Path(root) / "Shared/Tests/Fixtures/settings/macos-0.2.2-defaults.plist"


def default_expected_path(root=REPO):
    return Path(root) / "Shared/Tests/Fixtures/settings/macos-0.2.2-expected.json"


def parse_expected(path):
    data = json.loads(Path(path).read_text())
    if not isinstance(data, dict) or not isinstance(data.get("diagnostics"), list) \
            or not isinstance(data.get("document"), str):
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: invalid expected-document file: {path}")
    return data["diagnostics"], data["document"]


def _normalise_diagnostics(diagnostics):
    result = []
    for item in diagnostics or []:
        if isinstance(item, dict):
            result.append((str(item.get("id") or "document"), str(item.get("problem") or "")))
        else:
            result.append((str(item), ""))
    return sorted(result)


def project_layout_sizes(document_text):
    """Canonical document bytes with the EXACT 26 layout size settings removed.

    Only the explicit LAYOUT_SIZE_KEYS are dropped -- no regex. The LAUNCHED
    0.2.3 app recomputes graph geometry on layout and writes those settings into
    settings.json on EVERY launch (XRGModule resize feedback, docs/settings-
    inventory.md §339-364). They are live window geometry, not the seeded 0.2.2
    values, so byte-exact equality with the pure-migration oracle is impossible.
    They are projected out ONLY here so every OTHER (migrated) setting is
    validated byte-for-byte; the 26 keys are additionally REQUIRED present and
    valid by assert_layout_sizes, and are included in the post-downgrade domain
    comparison (finding 2).
    """
    obj = json.loads(document_text)
    if not isinstance(obj, dict) or not isinstance(obj.get("settings"), dict):
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: the app document is not a settings document")
    canonical = dict(obj)
    canonical["settings"] = {k: v for k, v in obj["settings"].items()
                             if k not in LAYOUT_SIZE_KEYS}
    return json.dumps(canonical, sort_keys=True, separators=(",", ":"))


def _valid_layout_size(value, bound):
    """A single graph dimension is valid iff it is a finite JSON number in
    [0, bound] -- consistent with the controlled geometry. Rejects missing
    (handled by caller), null/string/bool, negative, NaN/inf and huge values."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        number = float(value)
    except (ValueError, OverflowError):
        return False
    return math.isfinite(number) and 0 <= number <= bound


def layout_size_derivation(geometry=None):
    """Fix round 4, finding 2b: reproduce XRGModuleManager.windowChanged(to:)'s
    HORIZONTAL else-branch purely from the controlled geometry + seed. Returns
    the intermediate quantities of the derivation (diagnostics / unit tests):
      contentWidth  = expandedWindowWidth - 2*border
      contentHeight = windowHeight - 2*border
      unit          = max(0, contentWidth - titleHeight - separator*count)/count
      cpuHeight     = min(contentHeight, max(minHeight, cpuOverride))
    """
    geometry = geometry or CONTROLLED_GEOMETRY
    border = float(geometry["borderWidth"])
    separator = float(geometry["moduleSeparatorWidth"])
    title_height = float(geometry["textRectHeight"])
    min_height = float(geometry["minHeight"])
    count = len(geometry["displayedGraphs"])
    content_width = float(geometry["expandedWindowWidth"]) - 2 * border
    content_height = float(geometry["windowHeight"]) - 2 * border
    unit = max(0.0, content_width - title_height - separator * count) / count
    cpu_height = min(content_height,
                     max(min_height, float(geometry["heightOverrides"].get("cpu", min_height))))
    return {
        "border": border, "separator": separator, "titleHeight": title_height,
        "minHeight": min_height, "displayedCount": count,
        "contentWidth": content_width, "contentHeight": content_height,
        "unit": unit, "cpuHeight": cpu_height,
    }


def expected_layout_sizes(geometry=None):
    """The EXPECTED value + tolerance for all 26 size keys, DERIVED from the
    controlled geometry + seed via windowChanged (horizontal branch). Pure and
    unit tested. Hidden graphs expect exactly 0 (windowChanged applies .zero to
    non-displayed modules; XRGModule.dimension clamps 0 and saves 0)."""
    geometry = geometry or CONTROLLED_GEOMETRY
    d = layout_size_derivation(geometry)
    hidden = frozenset(geometry["hiddenGraphs"])
    overrides = geometry["heightOverrides"]
    expected = {}
    for gid in GRAPH_IDS:
        if gid in hidden:
            expected[f"graphs.{gid}.size_width"] = (0.0, HIDDEN_SIZE_TOLERANCE)
            expected[f"graphs.{gid}.size_height"] = (0.0, HIDDEN_SIZE_TOLERANCE)
        else:
            expected[f"graphs.{gid}.size_width"] = (d["unit"], SIZE_TOLERANCE)
            height = d["contentHeight"]
            if gid in overrides:
                height = min(d["contentHeight"],
                             max(d["minHeight"], float(overrides[gid])))
            expected[f"graphs.{gid}.size_height"] = (height, SIZE_TOLERANCE)
    return expected


def assert_layout_sizes(document_text, geometry=None):
    """Fix round 4 / finding 2: the app's document MUST contain ALL 26 explicit
    ``graphs.<id>.size_width/height`` settings, each a finite number, AND each
    value MUST MATCH the EXPECTED size DERIVED from the app's own layout rules
    + controlled geometry + seed, within a stated tolerance. A MISSING or
    CORRUPTED entry FAILS, and so does a WRONG-BUT-IN-RANGE entry (all-zero,
    cpu 140->900, or a hidden graph with a nonzero size) -- the old fix-round-3
    range check accepted those. Returns the {key: value} dict of the 26
    validated sizes on success.
    """
    geometry = geometry or CONTROLLED_GEOMETRY
    obj = json.loads(document_text)
    if not isinstance(obj, dict) or not isinstance(obj.get("settings"), dict):
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: the app document is not a settings document")
    settings = obj["settings"]
    derivation = layout_size_derivation(geometry)
    expected = expected_layout_sizes(geometry)
    values = {}
    for key in sorted(LAYOUT_SIZE_KEYS):
        if key not in settings:
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: the app document is MISSING required "
                f"layout size setting {key}")
        value = settings[key]
        if not _valid_layout_size(value, SIZE_UPPER_BOUND):
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: the app document has a CORRUPTED layout "
                f"size setting {key}={value!r}; expected a finite number in "
                f"[0, {SIZE_UPPER_BOUND}] consistent with the controlled "
                f"{geometry['windowWidth']}x{geometry['windowHeight']} window")
        expected_value, tolerance = expected[key]
        if abs(float(value) - expected_value) > tolerance:
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: the app document has a WRONG layout "
                f"size {key}={value!r}; the app's windowChanged layout for the "
                f"controlled {geometry['expandedWindowWidth']}x"
                f"{geometry['windowHeight']} window expects "
                f"{expected_value!r} +/- {tolerance} (unit="
                f"{derivation['unit']!r}, contentHeight="
                f"{derivation['contentHeight']!r}, cpuOverride="
                f"{derivation['cpuHeight']!r}, hidden="
                f"{sorted(geometry['hiddenGraphs'])})")
        values[key] = value
    return values


def compare_documents(expected_diagnostics, expected_document, actual_diagnostics, actual_document):
    """Byte-exact comparison of a PURE migration with the Task 4 oracle.

    Used for the supplementary framework driver / shared-core probe, which
    reproduce the pure migration (no layout). The LAUNCHED APP's document uses
    ``compare_app_document`` (layout-size projection) instead.
    """
    if _normalise_diagnostics(actual_diagnostics) != _normalise_diagnostics(expected_diagnostics):
        raise DocumentMismatch(
            "SETTINGS_UPGRADE_MACOS_MISMATCH: migration diagnostics differ from the "
            "expected fixture; report this instead of editing the fixture")
    if actual_document != expected_document:
        raise DocumentMismatch(
            "SETTINGS_UPGRADE_MACOS_MISMATCH: the 0.2.3 document differs from "
            "macos-0.2.2-expected.json. A catalog/migration change since Task 4 "
            "(e.g. Stocks mapped in the shared core, ruling R21) may be legitimate: "
            "STOP and report it rather than editing the fixture to pass")


def compare_app_document(expected_diagnostics, expected_document, actual_diagnostics, app_document):
    """Compare the document the LAUNCHED APP wrote with the pinned oracle.

    All migrated (non-layout) settings must match byte-for-byte; the 26 runtime
    layout size settings are normalised out (see project_layout_sizes).
    """
    if _normalise_diagnostics(actual_diagnostics) != _normalise_diagnostics(expected_diagnostics):
        raise DocumentMismatch(
            "SETTINGS_UPGRADE_MACOS_MISMATCH: migration diagnostics differ from the "
            "expected fixture; report this instead of editing the fixture")
    if project_layout_sizes(app_document) != project_layout_sizes(expected_document):
        raise DocumentMismatch(
            "SETTINGS_UPGRADE_MACOS_MISMATCH: the 0.2.3 document the app wrote "
            "differs from macos-0.2.2-expected.json. A catalog/migration change "
            "since Task 4 (e.g. Stocks mapped in the shared core, ruling R21) may "
            "be legitimate: STOP and report it rather than editing the fixture to pass")


def load_app_document(document_path, actual_diagnostics, expected_diagnostics, expected_document):
    """Read the document the LAUNCHED APP produced and compare it.

    If the app did not migrate -- no document at its R11 store, as when the env
    var is withheld -- this FAILS. The check never fabricates the document
    itself; this is the negative-control gate (finding 1).
    """
    document_path = Path(document_path)
    if not document_path.is_file():
        raise RuntimeError(
            f"SETTINGS_UPGRADE_MACOS: the launched 0.2.3 app produced no migrated "
            f"settings document at {document_path}; startup migration did not run -- "
            f"an app that does not migrate must fail")
    document = document_path.read_bytes().decode("utf-8")
    # Finding 2 (rr2 / rr3 fix round 4): do NOT silently project the 26 size
    # keys away. The app's document must actually CONTAIN all 26, with CORRECT
    # values derived from the app's layout rules (not just a valid range);
    # a missing, corrupted or wrong entry fails here before the comparison.
    assert_layout_sizes(document)
    compare_app_document(expected_diagnostics, expected_document, actual_diagnostics, document)
    return document


def defaults_snapshot(exported_bytes):
    """Canonical bytes of a defaults domain's SETTINGS keys.

    ONLY the genuinely volatile AppKit window geometry in VOLATILE_KEYS /
    VOLATILE_PREFIXES is projected out (each documented with a reason above).
    Every other key -- all real settings, including the 26 XRGModule_* graph
    width/height keys -- is compared byte-for-byte. Mapped keys a launch
    rewrites are handled by the 0.2.2 baseline normalisation run, NOT exclusion.
    """
    domain = plistlib.loads(exported_bytes)
    stable = {key: value for key, value in domain.items()
              if key not in VOLATILE_KEYS and not key.startswith(VOLATILE_PREFIXES)}
    return plistlib.dumps(stable, fmt=plistlib.FMT_BINARY, sort_keys=True)


def assert_defaults_unchanged(reference_raw, final_raw):
    """Finding 2 downgrade gate: the final 0.2.2 defaults must equal the
    reference captured BEFORE 0.2.3 ever ran. If 0.2.3 changed a persistent
    preference that 0.2.2 preserves, that value is ABSENT from the reference
    but PRESENT in the final snapshot, so this compare FAILS -- which the old
    (post-upgrade) reference capture could not detect. Pure + unit tested.
    """
    if defaults_snapshot(final_raw) != defaults_snapshot(reference_raw):
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: 0.2.2 defaults changed after the "
            "0.2.3 -> 0.2.2 round trip (settings were corrupted or migrated in place)")


class NormalisationDidNotConverge(RuntimeError):
    """Fix round 4, finding 2a: the 0.2.2 baseline never produced TWO
    CONSECUTIVE IDENTICAL settings snapshots within the bounded attempts. An
    exhausted A->B->C baseline must FAIL the check -- never claim a normalised
    downgrade reference, never set downgrade_normalised, never print OK.
    """


def normalise_until_converged(capture, max_attempts=MAX_NORMALISE_ATTEMPTS,
                              snapshot=defaults_snapshot):
    """Drive the 0.2.2 NORMALISE loop until its settings snapshot is STABLE:
    TWO CONSECUTIVE IDENTICAL snapshots (fix round 4, finding 2a). CONVERGENCE
    IS REQUIRED; if the bounded attempts run out without it, raise
    NormalisationDidNotConverge -- the caller NEVER receives a reference and so
    NEVER sets downgrade_normalised (the check fails with no OK line).

    `capture()` (injectable) performs ONE normalise launch + settle + export and
    returns that launch's RAW defaults export bytes; `snapshot` (injectable)
    canonicalises it. Returns the settled raw export bytes (the downgrade
    reference), captured BEFORE 0.2.3 ever runs. Pure w.r.t. injected side
    effects, so convergence AND exhaustion (A->B->C fails) are unit tested.
    """
    previous = None
    for _attempt in range(max_attempts):
        raw = capture()
        current = snapshot(raw)
        if previous is not None and current == previous:
            return raw
        previous = current
    raise NormalisationDidNotConverge(
        "SETTINGS_UPGRADE_MACOS: 0.2.2 baseline normalisation did not converge "
        f"within {max_attempts} attempts (no TWO CONSECUTIVE identical settings "
        "snapshots); refusing to capture a downgrade reference (A->B->C fails)")


def measure_document_rewrite(document_path, before_bytes):
    """R26 MEASUREMENT (observational ONLY). Byte-compare the app's document
    before and after a second 0.2.3 launch with the SAME geometry. NEVER raises
    on a difference: the check does not gate success on this answer; the
    coordinator takes it to the final review. Returns a dict describing whether
    the document was rewritten and, if so, which keys changed.
    """
    path = Path(document_path)
    try:
        after_bytes = path.read_bytes()
        after_present = True
    except OSError:
        after_bytes = None
        after_present = False
    identical = after_present and after_bytes == before_bytes
    changed_keys = []
    if after_present and not identical:
        try:
            before = json.loads(before_bytes.decode("utf-8")).get("settings", {})
            after = json.loads(after_bytes.decode("utf-8")).get("settings", {})
            changed_keys = sorted(key for key in set(before) | set(after)
                                  if before.get(key) != after.get(key))
        except (ValueError, UnicodeDecodeError, AttributeError):
            changed_keys = ["<unparseable document>"]
    return {
        "documentRewritten": not identical,
        "byteIdentical": identical,
        "documentPresentAfterRelaunch": after_present,
        "changedKeys": changed_keys,
        "beforeBytes": len(before_bytes),
        "afterBytes": len(after_bytes) if after_present else None,
    }


def success_marker(launched):
    """A probe-only run must never emit the OK line (finding 2)."""
    return OK_LINE if launched else PROBE_ONLY_LINE


def ok_after_cleanup(cleanup_failures, launched):
    """Emit success only after cleanup succeeded (finding 3 / fix-1 finding 4).

    A failed cleanup or an unreaped process group raises (non-zero exit) and
    NEVER returns the OK line.
    """
    if cleanup_failures:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: cleanup failed; " + "; ".join(cleanup_failures))
    return success_marker(launched)


def summary_fields(domain, seed, expected, document_path, diagnostics,
                   launched, launches, defaults_byte_identical,
                   supplementary_probe_matches, supplementary_driver_matches=False,
                   downgrade_normalised=False, layout_size_settings_normalised=False,
                   oracle_derived_from_normalised_seed=False,
                   reference_captured_before_upgrade=False,
                   layout_size_keys_validated=False, r26=None,
                   derived_oracle_matches_pinned=False, baseline_converged=False):
    """Only a full (launched) run may claim a 0.2.2 relaunch (finding 2)."""
    return {
        "domain": domain, "seed": str(seed), "expected": str(expected),
        "documentSource": "launched 0.2.3 app startup migration (R25 gated path, R11 private store)",
        "documentPath": str(document_path),
        "documentMatchesExpected": True, "diagnostics": diagnostics,
        "layoutSizeSettingsNormalised": layout_size_settings_normalised,
        "layoutSizeKeysValidated": layout_size_keys_validated,
        "migrationOracleDerivedFromNormalisedSeed": oracle_derived_from_normalised_seed,
        "derivedOracleMatchesPinnedProjected": derived_oracle_matches_pinned,
        "referenceCapturedBeforeUpgrade": reference_captured_before_upgrade,
        "defaultsByteIdentical": defaults_byte_identical,
        "downgradeBaselineNormalised": downgrade_normalised,
        "downgradeBaselineConverged": baseline_converged,
        "supplementaryDriverMatches": supplementary_driver_matches,
        "supplementaryProbeMatches": supplementary_probe_matches,
        "r26DocumentRewriteMeasurement": r26,
        "launched": launched,
        "baselineRelaunched": launched,
        "launches": launches,
    }


# --------------------------------------------------------------------------
# Signals and process groups (fix-1 finding 3, fix-round-2 finding 3).
# --------------------------------------------------------------------------

def _signal_handler(signum, frame):
    # Restore the default handler so a repeated signal terminates immediately,
    # then raise so Python unwinds through every ``finally`` block.
    signal.signal(signum, signal.SIG_DFL)
    raise Interrupted(signum)


def install_signal_handlers(signals=SIGNALS):
    """Make catchable termination signals run cleanup instead of killing us."""
    installed = []
    for sig in signals:
        signal.signal(sig, _signal_handler)
        installed.append(sig)
    return installed


def _default_group_alive(pgid):
    """Whether any member of the given process group still exists."""
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # group exists; we simply cannot signal it


def terminate_and_reap(processes, killpg=None, group_alive=None, sleep=None):
    """Terminate (whole process group) and reap every launched app.

    Fix-round-2 finding 3:
      * signal the WHOLE group for EVERY process, even when the leader has
        already exited (a stubborn child can keep the group alive);
      * escalate to SIGKILL for a leader that will not exit;
      * ACCOUNT FOR SURVIVING GROUP MEMBERS: after the leaders are reaped,
        verify each group is CONFIRMED gone before storage is deleted;
      * FAIL LOUDLY (raise, no success) if any group cannot be confirmed gone or
        any signal/wait fails -- never swallow kill errors or a wait timeout.
    All side-effecting operations are injectable for unit tests.
    """
    killpg = killpg or os.killpg
    group_alive = group_alive or _default_group_alive
    sleep = sleep or time.sleep
    failures = []

    def signal_group(pgid, sig):
        try:
            killpg(pgid, sig)
        except ProcessLookupError:
            pass  # group already gone: nothing to signal
        except OSError as error:
            failures.append(f"could not signal process group {pgid} with signal {sig}: {error}")

    # 1. Signal the whole group for EVERY process. poll() is deliberately NOT
    #    consulted: a leader may have exited while children survive.
    for process in processes:
        signal_group(process.pid, signal.SIGTERM)

    # 2. Reap the leaders; escalate to SIGKILL for one that will not exit.
    for process in processes:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            signal_group(process.pid, signal.SIGKILL)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                failures.append(f"leader {process.pid} did not exit after SIGKILL")

    # 3. Account for surviving group members (children that outlived the
    #    leader) BEFORE storage is deleted. Escalate and re-check.
    for process in processes:
        if group_alive(process.pid):
            signal_group(process.pid, signal.SIGKILL)
            for _ in range(5):
                if not group_alive(process.pid):
                    break
                sleep(0.1)
            if group_alive(process.pid):
                failures.append(f"process group {process.pid} could not be confirmed gone")

    if failures:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: " + "; ".join(failures))


# --------------------------------------------------------------------------
# Cleanup (fix-1 finding 4): attempt every step, check return codes, verify gone.
# Returns a list of accumulated failure strings (empty on success).
# --------------------------------------------------------------------------

def cleanup(domain, home, run=None):
    assert_safe_ids([domain])  # safety gate BEFORE any subprocess
    run = run or subprocess.run
    failures = []
    try:
        deleted = run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL, timeout=10)
        if getattr(deleted, "returncode", 0) != 0:
            failures.append(f"defaults delete {domain} returned {getattr(deleted, 'returncode', 0)}")
    except (OSError, subprocess.SubprocessError) as error:
        failures.append(f"defaults delete {domain} raised: {error}")
    for path in private_paths(home, domain):
        try:
            if path.is_symlink() or path.is_file():
                path.unlink(missing_ok=True)
            elif path.is_dir():
                shutil.rmtree(path)
        except OSError as error:
            failures.append(f"could not remove {path}: {error}")
    for path in private_paths(home, domain):
        if path.exists() or path.is_symlink():
            failures.append(f"disposable path still present: {path}")
    # Verify the domain itself is gone (cfprefsd), not just its plist file.
    try:
        check = run(["/usr/bin/defaults", "read", domain], stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=10)
        if getattr(check, "returncode", 1) == 0:
            failures.append(f"disposable defaults domain still registered: {domain}")
    except (OSError, subprocess.SubprocessError) as error:
        failures.append(f"could not verify domain removal: {error}")
    return failures


def report_retained_paths(retained, domain):
    """Finding 3: print the retained disposable paths when reaping FAILS, so a
    human/coordinator can remove them by hand. Storage is deliberately NOT
    deleted in this case (a surviving process could recreate/access it)."""
    print(f"SETTINGS_UPGRADE_MACOS: retained disposable domain {domain}", file=sys.stderr)
    for path in retained:
        print(f"SETTINGS_UPGRADE_MACOS: retained disposable path: {path}", file=sys.stderr)


def reap_and_cleanup(pending, domain, home, unregisters, *, reap, cleanup_fn,
                     unregister, report):
    """Finding 3: GATE ALL storage deletion on CONFIRMED process-group
    termination.

    ``reap(pending)`` (terminate_and_reap) returns ONLY after every launched
    group is confirmed gone, or RAISES. If it raises, storage is NOT deleted:
    the retained disposable paths are printed and a RuntimeError propagates
    (non-zero exit, NO OK line). Unregister + deletion happen ONLY after
    termination is confirmed. Returns cleanup()'s failure list on success.

    Fully injectable so the caller-level guarantee is unit tested.
    """
    try:
        reap(pending)
    except Exception as error:  # ANY failure to confirm termination = do not delete
        retained = [str(path) for path in private_paths(home, domain)]
        report(retained, domain)
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: could not confirm process-group termination "
            f"({error}); disposable storage NOT deleted; retained disposable "
            "paths printed above") from error
    for app in unregisters:
        unregister(app)
    return cleanup_fn(domain, home)


# --------------------------------------------------------------------------
# Supplementary shared-core probe (independent pure migration over the seed).
# --------------------------------------------------------------------------

PROBE_SWIFT = r'''import Foundation
import XRGSharedCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("settings-upgrade-probe: " + message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: PROBE seed.plist document.json diagnostics.json") }
let seedURL = URL(fileURLWithPath: args[1])
let documentURL = URL(fileURLWithPath: args[2])
let diagnosticsURL = URL(fileURLWithPath: args[3])
guard let plistData = try? Data(contentsOf: seedURL),
      let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
      let defaults = object as? [String: Any] else { fail("cannot read seed defaults plist") }
guard let catalog = try? XRGSettingsCatalog.load() else { fail("settings catalog is missing") }
let (document, diagnostics) = XRGSettingsMigration.fromMacDefaults(defaults, catalog: catalog)
do {
    try document.serialized().write(to: documentURL)
    let report: [[String: String]] = diagnostics.map { ["id": $0.id ?? "document", "problem": $0.problem] }
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try bytes.write(to: diagnosticsURL)
} catch { fail("cannot write probe results: \(error)") }
print("PROBE_OK")
'''


def _require_probe_products(products):
    if not (products / "XRGSharedCore.swiftmodule").exists() \
            or not (products / "libXRGSharedCore.dylib").is_file():
        raise RuntimeError(
            f"SETTINGS_UPGRADE_MACOS: --products lacks XRGSharedCore.swiftmodule / "
            f"libXRGSharedCore.dylib: {products}")


def build_probe_products(root, results, provided=None):
    if provided:
        products = Path(provided).resolve()
        _require_probe_products(products)
        return products
    scratch = results / "swift"
    base = ["swift", "build", "--package-path", str(root), "--scratch-path", str(scratch),
            "--product", "XRGSharedCore"]
    subprocess.run(base, check=True, stdout=subprocess.DEVNULL)
    bin_path = subprocess.check_output(base + ["--show-bin-path"], text=True).strip()
    products = Path(bin_path)
    _require_probe_products(products)
    return products


def compile_probe(products, results):
    source = results / "MigrationProbe.swift"
    source.write_text(PROBE_SWIFT)
    executable = results / "MigrationProbe"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-I", str(products),
                    "-L", str(products), "-lXRGSharedCore", str(source), "-o", str(executable)],
                   check=True)
    return executable


def run_probe(executable, products, seed, document_path, diagnostics_path):
    env = os.environ.copy()
    existing = env.get("DYLD_LIBRARY_PATH")
    env["DYLD_LIBRARY_PATH"] = str(products) + (os.pathsep + existing if existing else "")
    subprocess.run([str(executable), str(seed), str(document_path), str(diagnostics_path)],
                   check=True, env=env)


# --------------------------------------------------------------------------
# Supplementary framework driver: the SUPPLIED APP's OWN XRGCore.framework
# reproduces the pure migration over the seed. NO this-checkout fallback.
# --------------------------------------------------------------------------

APP_DRIVER_SWIFT = r'''// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
@testable import XRGCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("app-document-driver: " + message + "\n").utf8))
    exit(1)
}

@main
enum AppDocumentDriver {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count == 3 else { fail("usage: DRIVER seed.plist <output-document.json>") }
        let seedURL = URL(fileURLWithPath: args[1])
        let documentURL = URL(fileURLWithPath: args[2])
        guard let data = try? Data(contentsOf: seedURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let seed = object as? [String: Any] else { fail("cannot read seed defaults plist") }
        guard let catalog = try? XRGSettingsCatalog.load() else { fail("settings catalog is missing") }
        guard let defaults = UserDefaults(suiteName: "com.sdelavega.xrg.upgradecheck.driver") else {
            fail("no defaults suite")
        }
        // The supplied app's OWN document store, over a disposable suite,
        // writing the PURE migration of the seed into a scratch document.
        let store = XRGSettingsStore(fileURL: documentURL, defaults: defaults,
                                     catalog: catalog, legacyDomain: seed)
        if let problem = store.loadProblem { fail("store load problem: \(problem.problem)") }
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            fail("app store wrote no settings.json")
        }
        print("APP_DOCUMENT_OK " + documentURL.path)
    }
}
'''


def _framework_is_testable(framework):
    return framework.is_dir() and any(framework.rglob("*.private.swiftinterface"))


def resolve_driver_framework(app):
    """The supplied 0.2.3 app's OWN XRGCore.framework (built alongside it).

    Finding 1: NO this-checkout framework fallback. If the supplied app's
    framework cannot be used, the check FAILS.
    """
    products = app.resolve().parent
    framework = products / "XRGCore.framework"
    if not _framework_is_testable(framework):
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: the supplied 0.2.3 app has no testable "
            "XRGCore.framework alongside it; refusing any fallback (the supplied "
            "app's framework cannot be used)")
    return products


def compile_app_driver(products, results):
    source = results / "AppDocumentDriver.swift"
    source.write_text(APP_DRIVER_SWIFT)
    executable = results / "AppDocumentDriver"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    "-F", str(products), "-framework", "XRGCore", "-framework", "AppKit",
                    "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", str(products),
                    str(source), "-o", str(executable)], check=True)
    return executable


def run_app_driver(executable, products, seed, document_path):
    env = os.environ.copy()
    existing = env.get("DYLD_FRAMEWORK_PATH")
    env["DYLD_FRAMEWORK_PATH"] = str(products) + (os.pathsep + existing if existing else "")
    result = subprocess.run([str(executable), str(seed), str(document_path)],
                            check=True, capture_output=True, text=True, env=env)
    line = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    if not line.startswith("APP_DOCUMENT_OK "):
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: app document driver did not report OK: {result.stdout!r}")
    return Path(line[len("APP_DOCUMENT_OK "):])


# --------------------------------------------------------------------------
# Renamed-copy launch pattern (mirrors Tools/packaged-smoke-macos.py).
# --------------------------------------------------------------------------

def make_renamed_copy(source, domain, destination):
    source = Path(source).resolve()
    info_path = source / "Contents/Info.plist"
    if not info_path.is_file() or not (source / "Contents/MacOS/XRG-ng").is_file():
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: not a built XRG-ng.app: {source}")
    assert_safe_ids([domain])
    shutil.copytree(source, destination, symlinks=True)
    info = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
    info["CFBundleIdentifier"] = domain
    (destination / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    written = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
    if written.get("CFBundleIdentifier") != domain:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: renamed copy lost its private bundle id")
    return destination


def launch_one(app, domain, results, timeout, processes, extra_env=None, phase="app"):
    """Bounded proof of life; a resident app still running at timeout is a pass.

    The process is left running here and terminated/reaped by launch-level
    finally (``launch_phase`` / ``main``), so an interruption cannot leave it.
    ``extra_env`` carries the gating variable for the 0.2.3 upgrade launch.
    """
    assert_safe_ids([domain])
    binary = app / "Contents/MacOS/XRG-ng"
    log = results / f"launch-{phase}.log"
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    with log.open("wb") as stream:
        process = subprocess.Popen([str(binary)], stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True, cwd=str(app.parent), env=env)
        processes.append(process)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return {"phase": phase, "app": app.parent.name, "log": log.name,
                    "resident": True, "outcome": "resident"}
        if status != 0:
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: {phase} renamed app exited {status}; see {log}")
        return {"phase": phase, "app": app.parent.name, "log": log.name,
                "resident": False, "outcome": "exited-clean"}


def launch_phase(app, domain, results, timeout, processes, reaped, extra_env=None, phase="app"):
    """Launch one renamed app, prove residency, then quit/reap its whole group.

    On success the pid is marked reaped so the top-level finally does not
    re-signal a freed pid; on a reap failure it stays pending and is retried.
    """
    record = launch_one(app, domain, results, timeout, processes, extra_env, phase)
    process = processes[-1]
    terminate_and_reap([process])  # finding 3: may raise (no success)
    reaped.add(process.pid)
    return record


def assert_all_resident(launches):
    if not all(launch["resident"] for launch in launches):
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: a renamed app did not stay resident (no genuine AppKit launch)")


def settle(seconds):
    """Let cfprefsd flush app writes before captures/comparisons."""
    time.sleep(seconds)


def _nm_symbols(app):
    binary = app / "Contents/MacOS/XRG-ng"
    return subprocess.run(["xcrun", "nm", "-arch", platform.machine(), "-j", str(binary)],
                          check=True, capture_output=True, text=True).stdout


def _unregister(app):
    if app.exists():
        try:
            subprocess.run([LSREGISTER, "-u", str(app)], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.SubprocessError):
            pass


def seed_domain(domain, seed):
    subprocess.run(["/usr/bin/defaults", "import", domain, str(seed)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def export_domain(domain):
    return subprocess.run(["/usr/bin/defaults", "export", domain, "-"], check=True,
                          capture_output=True).stdout


# --------------------------------------------------------------------------
# Supplementary validation shared by full and probe-only runs.
# --------------------------------------------------------------------------

def run_supplementary(app, results, seed, products, expected_diagnostics, expected_document):
    """Framework driver + shared-core probe: independent PURE migrations.

    Both must reproduce the oracle byte-exact (R21). The driver uses ONLY the
    supplied app's framework (no fallback). Returns (driver_document,
    probe_diagnostics).
    """
    framework = resolve_driver_framework(app)
    driver = compile_app_driver(framework, results)
    driver_doc_path = results / "driver-document.json"
    written = run_app_driver(driver, framework, seed, driver_doc_path)
    driver_document = written.read_bytes().decode("utf-8")
    if driver_document != expected_document:
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: the supplied app's framework driver does not "
            "reproduce macos-0.2.2-expected.json (STOP and report, do not edit the fixture)")

    probe_products = build_probe_products(REPO, results, products)
    probe = compile_probe(probe_products, results)
    probe_doc_path = results / "probe-document.json"
    probe_diag_path = results / "probe-diagnostics.json"
    run_probe(probe, probe_products, seed, probe_doc_path, probe_diag_path)
    probe_document = probe_doc_path.read_bytes().decode("utf-8")
    probe_diagnostics = json.loads(probe_diag_path.read_text())
    compare_documents(expected_diagnostics, expected_document, probe_diagnostics, probe_document)
    return driver_document, probe_diagnostics


def derive_oracle_from_normalised_seed(results, normalised_seed, products, expected_document):
    """Finding 2: DERIVE THE MIGRATION ORACLE CONSISTENTLY FROM THE NORMALISED
    SEED (stated as the chosen option in the report).

    The 0.2.2 normalisation run settles the 26 layout-size keys BEFORE 0.2.3
    ever runs; the 0.2.3 app then migrates THAT exact domain. So the expected
    0.2.3 document is the pure migration of the NORMALISED seed (the captured
    reference plist), NOT of the raw Task-4 fixture -- this is consistent with
    the launched app BY CONSTRUCTION (both migrate the same normalised domain).

    R21 (a legitimate catalog/migration divergence) is still enforced SEPARATELY
    and byte-exactly over the RAW Task-4 fixture by run_supplementary. Here we
    only RECORD whether the derived oracle's layout-projected form also equals
    the pinned Task-4 oracle projected; a difference (if any) is attributable to
    0.2.2's deterministic normalisation of a mapped non-layout setting, already
    captured in the reference, and must NOT be mistaken for upgrade damage.
    Returns (derived_oracle_text, matches_pinned_projected).
    """
    probe_products = build_probe_products(REPO, results, products)
    probe = compile_probe(probe_products, results)
    doc_path = results / "oracle-normalised-document.json"
    diag_path = results / "oracle-normalised-diagnostics.json"
    run_probe(probe, probe_products, normalised_seed, doc_path, diag_path)
    derived = doc_path.read_bytes().decode("utf-8")
    matches_pinned_projected = (
        project_layout_sizes(derived) == project_layout_sizes(expected_document))
    return derived, matches_pinned_projected


def r26_relaunch(app, domain, results, timeout, processes, reaped, extra_env,
                 document_path, before_bytes):
    """R26 MEASUREMENT (observational ONLY): relaunch 0.2.3 with the SAME env
    var + geometry and byte-compare its document before/after. The check NEVER
    gates on the measurement result (coordinator takes it to final review): a
    non-zero exit on this relaunch is RECORDED, not fatal. Reaping failures
    still propagate (finding 3). Returns (record, measurement).
    """
    try:
        record = launch_one(app, domain, results, timeout, processes, extra_env,
                            "0.2.3-relaunch-r26")
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        # A measurement-only relaunch that exits is recorded, NOT fatal.
        record = {"phase": "0.2.3-relaunch-r26", "resident": False,
                  "outcome": f"exited: {error}"}
    # Confirm the launched group is gone (safety); do not gate on residency.
    pending_new = [process for process in processes if process.pid not in reaped]
    if pending_new:
        terminate_and_reap(pending_new)  # may raise (no success) -- finding 3
        for process in pending_new:
            reaped.add(process.pid)
    measurement = measure_document_rewrite(document_path, before_bytes)
    return record, measurement


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Freshly built 0.2.3 XRG-ng.app")
    parser.add_argument("--baseline", type=Path, required=True, help="0.2.2 XRG-ng.app (tag v0.2.2)")
    parser.add_argument("--seed", type=Path, default=None,
                        help="0.2.2 defaults plist (default: the Task 4 fixture; R9 real-prefs run passes its own)")
    parser.add_argument("--expected", type=Path, default=None,
                        help="expected document JSON (default: the Task 4 fixture)")
    parser.add_argument("--products", type=Path, default=None,
                        help="dir with XRGSharedCore.swiftmodule + libXRGSharedCore.dylib (supplementary probe)")
    parser.add_argument("--results", type=Path, default=None, help="artifacts directory (scratch)")
    parser.add_argument("--launch-timeout", type=float, default=6.0,
                        help="seconds each renamed app is allowed to start (default 6)")
    parser.add_argument("--settle-timeout", type=float, default=1.5,
                        help="seconds to let app preference writes settle (default 1.5)")
    parser.add_argument("--skip-launch", action="store_true",
                        help="supplementary-only validation: NO app launches, NO relaunch claim, NO OK line")
    parser.add_argument("--withhold-upgrade-env", action="store_true",
                        help="NEGATIVE CONTROL: do not pass the startup-migration env var; the check MUST fail")
    args = parser.parse_args(argv)
    if args.settle_timeout < 0 or args.launch_timeout <= 0:
        parser.error("timeouts must be positive")

    install_signal_handlers()

    # SAFETY gate first: nothing touches the machine until the ids are proven safe.
    token = make_token()
    domain = domain_for(token)
    assert_safe_ids([domain])

    home = Path.home().resolve()
    seed = (args.seed or default_seed_path()).resolve()
    expected_path = (args.expected or default_expected_path()).resolve()
    # Fix-1 finding 5: refuse protected inputs BEFORE reading anything.
    assert_safe_inputs(seed, expected_path, home)

    app = args.app.resolve()
    baseline_app = args.baseline.resolve()
    # Finding 1: the supplied app must still HAVE the store symbols (the
    # negative control keeps them but writes no document).
    assert_app_document_backend(_nm_symbols(app))

    if not seed.is_file():
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: missing seed plist: {seed}")
    if not expected_path.is_file():
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: missing expected document: {expected_path}")
    for candidate in (app, baseline_app):
        if not (candidate / "Contents/MacOS/XRG-ng").is_file():
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: not a built XRG-ng.app: {candidate}")
    expected_diagnostics, expected_document = parse_expected(expected_path)

    results = (args.results.resolve() if args.results
               else Path(tempfile.mkdtemp(prefix="xrg-settings-upgrade-")).resolve())
    results.mkdir(parents=True, exist_ok=True)
    print(f"Settings upgrade artifacts: {results}", flush=True)

    for path in private_paths(home, domain):
        if path.exists() or path.is_symlink():
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: disposable namespace already exists: {path}")

    new_copy = results / "0.2.3" / "XRG-ng.app"
    old_copy = results / "0.2.2" / "XRG-ng.app"
    document_path = app_document_path(home, domain)
    cleanup_failures = []
    processes = []
    reaped = set()
    launches = []
    defaults_byte_identical = None
    driver_diagnostics = []
    supplementary_driver_matches = False
    supplementary_probe_matches = False
    downgrade_normalised = False
    layout_size_settings_normalised = False
    layout_size_keys_validated = False
    oracle_derived_from_normalised_seed = False
    oracle_matches_pinned = False
    reference_captured_before_upgrade = False
    r26 = None
    oracle_document = expected_document
    try:
        # Finding 1: "starts with no document".
        if document_path.exists():
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: a document already exists at the app's "
                f"R11 private store {document_path}; the app must start with none")

        # ---- DOWNGRADE_PHASES[0]: seed ----------------------------------------
        seed_domain(domain, seed)
        (results / "seed-defaults.plist").write_bytes(export_domain(domain))

        # R21 PURE-migration oracle over the RAW Task-4 fixture (byte-exact),
        # shared by full and probe-only runs. A tampered --expected fails here.
        _, probe_diagnostics = run_supplementary(
            app, results, seed, args.products, expected_diagnostics, expected_document)
        driver_diagnostics = probe_diagnostics
        supplementary_driver_matches = True
        supplementary_probe_matches = True

        if args.skip_launch:
            # Probe-only: NO launches, NO app document, NO relaunch, NO OK line.
            pass
        else:
            make_renamed_copy(app, domain, new_copy)
            make_renamed_copy(baseline_app, domain, old_copy)
            env_for_upgrade = upgrade_check_env(domain, enabled=not args.withhold_upgrade_env)

            # ---- [1] 0.2.2-normalise (BEFORE 0.2.3 ever runs) ---------------
            # Finding 2: NORMALISE with 0.2.2 so the mapped keys it rewrites on
            # every launch are settled, not excluded (fix round 2, finding 2 --
            # ALL 26 XRGModule_* size keys stay IN the byte comparison). The 26
            # sizes are layout feedback: the FIRST launch from the seeded
            # (minimised 280x684) frame expands the window, so that cold launch
            # writes different sizes than every warm launch (measured: 21.18 ->
            # 157.45). Fix round 4 (finding 2a): CONVERGENCE -- TWO CONSECUTIVE
            # identical settings snapshots -- is REQUIRED within the bounded
            # MAX_NORMALISE_ATTEMPTS. Exhausting them WITHOUT convergence RAISES
            # (never sets downgrade_normalised, never reaches the OK line). The
            # reference is captured from that settled state, all before 0.2.3.
            def capture_normalise():
                launches.append(launch_phase(
                    old_copy, domain, results, args.launch_timeout,
                    processes, reaped, None, "0.2.2-normalise"))
                settle(args.settle_timeout)
                return export_domain(domain)

            reference_raw = normalise_until_converged(
                capture_normalise, MAX_NORMALISE_ATTEMPTS)

            # ---- [2] capture-reference (BEFORE 0.2.3 EVER runs) --------------
            (results / "reference-defaults.plist").write_bytes(reference_raw)
            downgrade_normalised = True  # ONLY on demonstrated convergence
            reference_captured_before_upgrade = True

            # Derive the migration oracle CONSISTENTLY FROM THE NORMALISED SEED
            # (the exact domain the 0.2.3 app is about to migrate) -- the chosen
            # option (vs. an independent baseline-control domain). Its projected
            # form must equal the pure Task-4 oracle (R21). See report.
            oracle_document, oracle_matches_pinned = derive_oracle_from_normalised_seed(
                results, results / "reference-defaults.plist", args.products,
                expected_document)
            oracle_derived_from_normalised_seed = True

            # ---- [3] 0.2.3-upgrade (migration) --------------------------------
            launches.append(launch_phase(new_copy, domain, results, args.launch_timeout,
                                         processes, reaped, env_for_upgrade, "0.2.3-upgrade"))
            settle(args.settle_timeout)

            # ---- [4] validate-app-document (negative-control gate) ------------
            # load_app_document now ALSO requires ALL 26 explicit size keys to be
            # present and valid (assert_layout_sizes); missing/corrupt -> fail.
            document = load_app_document(document_path, driver_diagnostics,
                                         expected_diagnostics, oracle_document)
            (results / "0.2.3-document.json").write_text(document)
            before_bytes = document_path.read_bytes()
            (results / "layout-sizes.json").write_text(json.dumps(
                assert_layout_sizes(document), indent=2, sort_keys=True) + "\n")
            # Record the DERIVED expected sizes and tolerances (fix round 4),
            # so the correctness oracle is auditable from the run artifacts.
            (results / "layout-size-derivation.json").write_text(json.dumps(
                {"derivation": layout_size_derivation(CONTROLLED_GEOMETRY),
                 "expected": {k: {"expected": v, "tolerance": t}
                              for k, (v, t) in expected_layout_sizes().items()},
                 "sizeTolerance": SIZE_TOLERANCE,
                 "hiddenSizeTolerance": HIDDEN_SIZE_TOLERANCE},
                indent=2, sort_keys=True) + "\n")
            layout_size_settings_normalised = True
            layout_size_keys_validated = True

            # ---- [5] 0.2.3-relaunch-r26 (R26 MEASUREMENT, observational) -----
            r26_record, r26 = r26_relaunch(
                new_copy, domain, results, args.launch_timeout, processes, reaped,
                env_for_upgrade, document_path, before_bytes)
            r26["relaunch"] = r26_record
            (results / "r26-measurement.json").write_text(json.dumps(r26, indent=2) + "\n")

            # ---- [6] 0.2.2-downgrade ------------------------------------------
            launches.append(launch_phase(old_copy, domain, results, args.launch_timeout,
                                         processes, reaped, None, "0.2.2-downgrade"))
            settle(args.settle_timeout)
            final_raw = export_domain(domain)
            (results / "downgraded-defaults.plist").write_bytes(final_raw)

            # ---- [7] compare-to-reference -------------------------------------
            # Reference was captured BEFORE 0.2.3: any 0.2.3 damage is now in the
            # final snapshot but NOT the reference, so this compare CATCHES it.
            assert_defaults_unchanged(reference_raw, final_raw)
            defaults_byte_identical = True

            # Only the three GATE launches must be resident; the R26 relaunch is
            # a measurement whose residency never gates success (R26).
            assert_all_resident(launches)

        (results / "summary.json").write_text(json.dumps(summary_fields(
            domain, seed, expected_path, document_path, driver_diagnostics,
            not args.skip_launch, launches, defaults_byte_identical,
            supplementary_probe_matches, supplementary_driver_matches,
            downgrade_normalised, layout_size_settings_normalised,
            oracle_derived_from_normalised_seed, reference_captured_before_upgrade,
            layout_size_keys_validated, r26, oracle_matches_pinned,
            baseline_converged=downgrade_normalised), indent=2) + "\n")
    finally:
        # Finding 3: GATE storage deletion on CONFIRMED process-group termination.
        # reap_and_cleanup reaps every launched group and CONFIRMS they are gone
        # BEFORE calling cleanup. On a reap failure it does NOT delete storage,
        # prints the retained disposable paths and raises (no OK line, non-zero).
        pending = [process for process in processes if process.pid not in reaped]
        cleanup_failures = reap_and_cleanup(
            pending, domain, home, (new_copy, old_copy),
            reap=terminate_and_reap, cleanup_fn=cleanup, unregister=_unregister,
            report=report_retained_paths)
        for failure in cleanup_failures:
            print(f"cleanup failure: {failure}", file=sys.stderr)

    # The OK line is printed ONLY after reaping + cleanup succeeded.
    print(ok_after_cleanup(cleanup_failures, not args.skip_launch), flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Interrupted as error:
        print(f"Settings upgrade failed: {error}", file=sys.stderr)
        sys.exit(128 + error.signum)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError,
            json.JSONDecodeError, plistlib.InvalidFileException) as error:
        print(f"Settings upgrade failed: {error}", file=sys.stderr)
        sys.exit(1)
