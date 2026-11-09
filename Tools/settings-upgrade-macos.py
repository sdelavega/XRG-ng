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

SIZE KEYS (fix round 3 finding 2; fix round 4 finding 2; fix round 5 finding
2b): the launched app's document MUST contain ALL 26 EXPLICIT
graphs.<id>.size_width/height keys (LAYOUT_SIZE_KEYS, not a regex). Fix round 4
requires CORRECTNESS, not just a valid range: assert_layout_sizes derives the
EXPECTED width/height of every displayed/hidden graph and the seeded CPU height
override (140) from the app's own layout rules (XRGModuleManager.windowChanged
horizontal branch, plus XRGModule.dimension / minHeight), and checks each value
within a stated tolerance. All-zero sizes, a CPU override changed 140->900, or
a hidden graph with a nonzero size all FAIL. Fix round 5 makes those EXPECTED
sizes host-INDEPENDENT: the geometry is built by measured_geometry() from
INDEPENDENTLY MEASURED inputs -- the LAUNCHED app's window frame (the app-written
AppKit restore rectangle 'unminimizedFrame', a value the app writes that is NOT
one of the 26 size keys, corroborated by a live CGWindowList measurement) and
the font metric (the seed graphFont's line height, computed portably via the
same AppKit metric XRGSettings.textRectHeight uses). Production NEVER uses the
hardcoded round-4 1779/13 (kept ONLY as a deterministic unit-test reference).
The 26 keys are still projected out ONLY of the app-vs-oracle DOCUMENT
comparison (runtime layout feedback); they are validated here against the
MEASURED geometry and included in the post-downgrade DOMAIN comparison.

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
import ctypes
import ctypes.util
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
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

# --------------------------------------------------------------------------
# Fix round 5, finding 2b: EXPECTED graph sizes must NOT depend on THIS host.
#
# Fix round 4 hardcoded the expanded frame width (1779) and the font-derived
# title height (13) into the production oracle, so correct layouts on a host
# with different display/font metrics could fail the +/-1 pt check. The fix:
# MEASURE the LAUNCHED 0.2.3 app's window frame and the font metric INDEPENDENTLY
# of the 26 graphs.<id>.size_* values under validation, and feed those MEASURED
# inputs into the UNCHANGED XRGModuleManager.windowChanged derivation:
#   * measured frame (W, H): the launched app's AppKit-autosaved window-frame
#     keys (unminimizedFrame / "NSWindow Frame *") -- values THE APP WRITES that
#     are NOT one of the 26 size keys -- corroborated by a live CGWindowList
#     (kCGWindowBounds) measurement of the running process;
#   * measured font metric (textRectHeight = the layout's titleHeight):
#     COMPUTED PORTABLY from the seed's graphFont via the SAME AppKit
#     ("A").size(withAttributes:) call XRGSettings uses (XRGSettings.swift:390),
#     on whatever host runs the check.
# Neither input is inferred from the 26 sizes being validated.
#
# SEED_GEOMETRY holds ONLY portable seed/code constants (no host-specific
# value). measured_geometry(frame_w, frame_h, title_h) builds the complete
# geometry from the three INDEPENDENTLY MEASURED inputs. main() ALWAYS passes
# that measured geometry to load_app_document/assert_layout_sizes; the
# REFERENCE_* constants below are a DETERMINISTIC UNIT-TEST FIXTURE (the round-4
# observed values), used ONLY as the geometry=None default of the pure
# derivation helpers -- NO production code path reads them.
#
# The derivation (UNCHANGED, XRGModuleManager.swift:206-209 HORIZONTAL branch):
#   contentWidth  = frameWidth  - 2*border
#   contentHeight = frameHeight - 2*border
#   unit          = max(0, contentWidth - titleHeight - separator*count)/count
#   displayed width = unit (all 11); displayed height = min(contentHeight,
#       fixedHeight ?? contentHeight); cpu fixedHeight = max(minHeight, 140)=140;
#   hidden (gpu, weather) -> NSSize.zero -> width=height=0.
# Wrong-but-in-range values (all-zero, cpu 140->900, nonzero hidden) fail.
# --------------------------------------------------------------------------
HIDDEN_GRAPHS = frozenset({"gpu", "weather"})
DISPLAYED_GRAPHS = tuple(gid for gid in GRAPH_IDS if gid not in HIDDEN_GRAPHS)
HEIGHT_OVERRIDES = {"cpu": 140}

# PORTABLE seed/code constants ONLY. borderWidth=6 (seed), moduleSeparatorWidth=2
# & minHeight=30 (XRGCore defaults), hidden/displayed graphs & the cpu height
# override (seed). windowWidth/windowHeight are the SEEDED collapsed frame
# (used only for the secondary range-bound floor and documentation).
SEED_GEOMETRY = {
    "windowWidth": 280,
    "windowHeight": 684,
    "windowFrame": "{{216, 136}, {280, 684}}",
    # The fixture's orientation is the deterministic DEFAULT for the
    # geometry=None pure unit tests. The PRODUCTION check ALWAYS overrides it
    # with orientation_from_domain(export(domain)) -- see collect_measured_
    # geometry / measured_geometry -- so both orientations are derived from the
    # seeded/normalised domain, never hardcoded and never from the 26 sizes.
    "orientation": "horizontal",
    "source": "Shared/Tests/Fixtures/settings/macos-0.2.2-defaults.plist",
    "borderWidth": 6,
    "moduleSeparatorWidth": 2,
    "minHeight": 30,
    "hiddenGraphs": HIDDEN_GRAPHS,
    "displayedGraphs": DISPLAYED_GRAPHS,
    "heightOverrides": HEIGHT_OVERRIDES,
}
# Seed-based floor for the secondary range gate (portable).
SIZE_UPPER_BOUND = SEED_GEOMETRY["windowWidth"] + SEED_GEOMETRY["windowHeight"]


def measured_geometry(frame_width, frame_height, text_rect_height, base=None, orientation=None):
    """Build the COMPLETE layout geometry from three INDEPENDENTLY MEASURED
    inputs plus the portable seed constants.

    frame_width/frame_height are the LAUNCHED 0.2.3 app's MEASURED window frame
    (the `size` argument to XRGModuleManager.windowChanged); text_rect_height is
    the MEASURED font metric (XRGSettings.textRectHeight). NO host-specific
    value is hardcoded: expandedWindowWidth, windowHeight and textRectHeight all
    come from these arguments. `orientation` is read from the SEEDED/NORMALISED
    domain (orientation_from_domain); when omitted, the base's orientation (the
    fixture's horizontal) is kept as the deterministic unit-test default. Pure
    and unit tested (alternate-host geometry, inconsistent measured frame, both
    orientations). This is the geometry the PRODUCTION check uses.
    """
    geom = dict(base if base is not None else SEED_GEOMETRY)
    for label, value in (("frameWidth", frame_width),
                         ("frameHeight", frame_height),
                         ("textRectHeight", text_rect_height)):
        try:
            number = float(value)
        except (TypeError, ValueError) as error:
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: measured {label}={value!r} is not a "
                f"number; refusing to derive expected sizes") from error
        if not math.isfinite(number) or number <= 0:
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: measured {label}={value!r} is not a "
                f"finite positive number; refusing to derive expected sizes")
    geom["expandedWindowWidth"] = float(frame_width)
    geom["windowHeight"] = float(frame_height)
    geom["textRectHeight"] = float(text_rect_height)
    if orientation is not None:
        if orientation not in ("vertical", "horizontal"):
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: measured orientation={orientation!r} "
                f"is not vertical/horizontal; refusing to derive expected sizes")
        geom["orientation"] = orientation
    return geom


def size_upper_bound(geometry):
    """Secondary finite/range sanity bound, PORTABLE: a correct graph dimension
    can never exceed the MEASURED window's larger side (contentWidth /
    contentHeight are each smaller than it). Scales with the measured frame so a
    taller/wider host cannot spuriously fail; SIZE_UPPER_BOUND is a seed-based
    floor for the deterministic unit-test reference geometry."""
    return max(SIZE_UPPER_BOUND,
               float(geometry["expandedWindowWidth"]),
               float(geometry["windowHeight"]))


# DETERMINISTIC UNIT-TEST REFERENCE ONLY (the round-4 observed values on THIS
# host). PRODUCTION NEVER uses these: main() builds geometry via
# measured_geometry() from INDEPENDENTLY measured frame + font inputs and passes
# it explicitly. These literals exist SOLELY so the pure derivation helpers
# have a stable geometry=None default for unit tests; finding 2b is fixed
# because the production oracle is 100% MEASURED, not these constants.
REFERENCE_FRAME_WIDTH = 1779.0
REFERENCE_FRAME_HEIGHT = 684.0
REFERENCE_TITLE_HEIGHT = 13.0
CONTROLLED_GEOMETRY = measured_geometry(
    REFERENCE_FRAME_WIDTH, REFERENCE_FRAME_HEIGHT, REFERENCE_TITLE_HEIGHT)

# +/-1 pt for the 22 displayed values: layout inputs are integer points except
# the font titleHeight; the 11-way share moves <0.1 pt per graph for a 1 pt
# frame change, so +/-1 pt covers sub-point font-metric/frame rounding but still
# rejects every named corruption by >= 138 pt. Hidden values are EXACTLY 0
# (windowChanged applies NSSize.zero; saveSize stores 0.0), so a 1e-6 tolerance
# (float representation only) rejects ANY meaningful nonzero hidden size.
SIZE_TOLERANCE = 1.0
HIDDEN_SIZE_TOLERANCE = 1e-6
# Fix round 4, finding 2a: the 0.2.2 normalisation loop is BOUNDED and MUST
# demonstrate convergence within this many attempts, or the check fails.
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
    [0, bound] -- consistent with the geometry. Rejects missing (handled by
    caller), null/string/bool, negative, NaN/inf and huge values."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        number = float(value)
    except (ValueError, OverflowError):
        return False
    return math.isfinite(number) and 0 <= number <= bound


# --------------------------------------------------------------------------
# Fix round 5, finding 2b: INDEPENDENT geometry MEASUREMENT (pure helpers).
# NONE of these reads any of the 26 graphs.<id>.size_* values under validation.
# --------------------------------------------------------------------------
_FRAME_RECT_RE = re.compile(
    r"\{\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\}")


def parse_frame_rect(text):
    """Parse an AppKit NSStringFromRect string '{{x, y}, {w, h}}' -> (w, h).
    The LAST '{a, b}' is the size rectangle (the first is the origin); the
    trailing outer '}' is ignored. Pure and unit tested. Returns None for any
    non-rect value; never consults graph sizes."""
    if not isinstance(text, str):
        return None
    matches = _FRAME_RECT_RE.findall(text)
    if not matches:
        return None
    width, height = matches[-1]
    return (float(width), float(height))


def _legacy_bool(value):
    """Coerce a raw 0.2.2 defaults value the way UserDefaults.bool(forKey:)
    (and 0.2.2's XRGWindowPreferences.apply bool() helper) does: a CFBoolean,
    an integer/float NSNumber (nonzero = true), or a string parsed with NSString
    boolValue semantics. Used ONLY to read graphOrientationVertical from the
    seeded/normalised domain, never from the 26 size keys under validation."""
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        text = value.strip()
        upper = text.upper()
        if upper in ("YES", "TRUE", "Y", "T"):
            return True
        if upper in ("NO", "FALSE", "N", "F", ""):
            return False
        # NSString boolValue: a nonzero numeric string is true.
        try:
            return float(text) != 0.0
        except ValueError:
            return False
    return False


def orientation_from_domain(domain_bytes):
    """Read general.window.orientation's legacy key graphOrientationVertical
    from the SEEDED/NORMALISED domain (NOT one of the 26 size keys), coerced
    with the same bool semantics 0.2.2 read it with. Independent of the sizes
    under validation and of any host-specific geometry. Pure and unit tested.
    """
    domain = plistlib.loads(domain_bytes)
    return "vertical" if _legacy_bool(domain.get("graphOrientationVertical", False)) else "horizontal"


def window_frame_from_domain(exported_bytes):
    """Measure the LAUNCHED app's window frame from values THE APP WRITES that
    are NOT one of the 26 size keys: the AppKit-autosaved 'NSWindow Frame *'
    keys and the graph window's 'unminimizedFrame' restore rectangle. These are
    genuinely volatile AppKit WINDOW geometry (see VOLATILE_KEYS/PREFIXES),
    written by AppKit / XRGBackgroundView from the live NSWindow.frame -- the
    EXACT `size` argument passed to XRGModuleManager.windowChanged.
    Returns (width, height, key) or None. Pure and unit tested: a domain holding
    ONLY size keys (no frame key) yields None, proving the measurement cannot be
    inferred from the values under validation.
    """
    domain = plistlib.loads(exported_bytes)
    frames = []
    for key, value in domain.items():
        if key == "unminimizedFrame" or key.startswith("NSWindow Frame "):
            rect = parse_frame_rect(value)
            if rect and rect[0] > 0 and rect[1] > 0:
                frames.append((rect[0], rect[1], key))
    if not frames:
        return None
    # The graph window's OWN restore rectangle is the EXPANDED frame the layout
    # receives for BOTH orientations. In a VERTICAL layout that frame is TALL
    # and NARROW, so the old width-only "widest frame wins" rule wrongly picks
    # the shorter/wider collapsed frame; prefer the dedicated restore rectangle
    # when present. Neither source is one of the 26 validated size keys.
    restore = [f for f in frames if f[2] == "unminimizedFrame"]
    if restore:
        return max(restore, key=lambda f: f[0] * f[1])
    vertical = _legacy_bool(domain.get("graphOrientationVertical", False))
    if vertical:
        # Expanded vertical windows are TALL: prefer the tallest frame.
        return max(frames, key=lambda f: (f[1], f[0]))
    # Widest (expanded) horizontal frame wins; on a width tie prefer the graph
    # window's dedicated restore rectangle.
    return max(frames, key=lambda f: (f[0], f[2] == "unminimizedFrame"))


def font_descriptor_from_seed(seed):
    """Read the seed's archived NSFont (graphFont) -> (fontName, pointSize).
    PORTABLE: the font is a SEED setting (Menlo-Regular 11), NOT one of the 26
    size keys; its line-height metric is measured on the host by
    measure_title_height. Pure and unit tested."""
    domain = plistlib.loads(Path(seed).read_bytes())
    blob = domain.get("graphFont")
    if not isinstance(blob, (bytes, bytearray)):
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: seed has no archived graphFont")
    objects = plistlib.loads(bytes(blob))["$objects"]
    nsfont = next((o for o in objects if isinstance(o, dict) and "NSSize" in o), None)
    if nsfont is None:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: cannot parse seed graphFont size")
    size = float(nsfont["NSSize"])
    uid = nsfont.get("NSName")
    name = objects[uid.data] if isinstance(uid, plistlib.UID) else str(uid)
    if not isinstance(name, str) or not name or not math.isfinite(size) or size <= 0:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: seed graphFont is invalid")
    return name, size


FRAME_CROSSCHECK_TOLERANCE = 2.0


def frames_consistent(domain_frame, live_frame):
    """True when an independently measured live CGWindowList frame corroborates
    the app-written domain frame (same shape). Tolerates a single 0.5x/1x/2x
    backing-scale difference (Retina points vs pixels). Returns None when no
    live measurement is available. Pure and unit tested."""
    if not live_frame:
        return None
    dw, dh = float(domain_frame[0]), float(domain_frame[1])
    lw, lh = float(live_frame[0]), float(live_frame[1])
    if min(dw, dh, lw, lh) <= 0:
        return False
    for scale in (0.5, 1.0, 2.0):
        if (abs(lw - dw * scale) <= FRAME_CROSSCHECK_TOLERANCE + 0.01 * dw * scale
                and abs(lh - dh * scale) <= FRAME_CROSSCHECK_TOLERANCE + 0.01 * dh * scale):
            return True
    return False


def layout_size_derivation(geometry=None):
    """Reproduce XRGModuleManager.windowChanged(to:) for the geometry's
    orientation: the HORIZONTAL else-branch (lines 206-209) or the VERTICAL
    branch (lines 185-205). The frame width/height and titleHeight come from
    independent measurement (measured_geometry), NOT this host; the orientation
    is read from the seeded/normalised domain. Returns the derivation's
    intermediate quantities (diagnostics / unit tests).

    HORIZONTAL:
      contentWidth  = expandedWindowWidth - 2*border
      contentHeight = windowHeight - 2*border
      unit          = max(0, contentWidth - titleHeight - separator*count)/count
      cpuHeight     = min(contentHeight, max(minHeight, cpuOverride))
    VERTICAL (XRGCore/XRGModuleManager.swift:185-205): every displayed graph
      spans the FULL contentWidth; heights come from a vertical stack that
      reserves each graph's minimum (minHeight == XRGGraphLabels.lineHeight ==
      textRectHeight, the same measured font metric as titleHeight), gives the
      cpu its fixed 140, and shares the remaining `available` height among the
      automatic graphs. Hidden graphs get NSSize.zero -> 0.
    """
    geometry = geometry or CONTROLLED_GEOMETRY
    border = float(geometry["borderWidth"])
    separator = float(geometry["moduleSeparatorWidth"])
    title_height = float(geometry["textRectHeight"])
    min_height = float(geometry["minHeight"])
    displayed = list(geometry["displayedGraphs"])
    count = len(displayed)
    content_width = float(geometry["expandedWindowWidth"]) - 2 * border
    content_height = float(geometry["windowHeight"]) - 2 * border
    overrides = geometry["heightOverrides"]
    orientation = geometry.get("orientation", "horizontal")
    result = {
        "border": border, "separator": separator, "titleHeight": title_height,
        "minHeight": min_height, "displayedCount": count,
        "contentWidth": content_width, "contentHeight": content_height,
        "orientation": orientation,
    }
    if orientation == "vertical":
        available = max(0.0, content_height - title_height - separator * count)
        fixed = {gid: max(min_height, float(h)) for gid, h in overrides.items()
                 if gid in displayed}
        automatic = [gid for gid in displayed if gid not in fixed]
        if len(automatic) == count:
            heights = {gid: available / count for gid in displayed}
        else:
            line = title_height  # XRGGraphLabels.lineHeight == textRectHeight
            minima = {gid: line for gid in displayed}
            base = sum(minima.values())
            extra = max(0.0, available - base)
            requested = sum(max(0.0, (fixed.get(gid, minima[gid]) - minima[gid]))
                            for gid in displayed)
            factor = min(1.0, extra / requested) if requested > 0 else 0.0
            automatic_extra = (max(0.0, extra - requested) / len(automatic)
                               if automatic else 0.0)
            heights = {}
            for gid in displayed:
                minimum = minima[gid]
                if gid in fixed:
                    value = minimum + max(0.0, fixed[gid] - minimum) * factor
                else:
                    value = minimum + automatic_extra
                heights[gid] = (minimum * available / base
                                if base > available and base > 0 else value)
        result.update({
            "unit": content_width,  # vertical: full width, not the shared unit
            "cpuHeight": heights.get("cpu", min_height),
            "verticalWidth": content_width,
            "verticalHeights": heights,
            "available": available,
        })
    else:
        unit = max(0.0, content_width - title_height - separator * count) / count
        cpu_height = min(content_height,
                         max(min_height, float(overrides.get("cpu", min_height))))
        result.update({"unit": unit, "cpuHeight": cpu_height})
    return result


def expected_layout_sizes(geometry=None):
    """The EXPECTED value + tolerance for all 26 size keys, DERIVED from the
    measured geometry + seed via windowChanged for the geometry's orientation
    (horizontal else-branch or vertical branch). Pure and unit tested for BOTH
    orientations. Hidden graphs expect exactly 0 (windowChanged applies .zero
    to non-displayed modules; XRGModule.dimension clamps 0 and saves 0)."""
    geometry = geometry or CONTROLLED_GEOMETRY
    d = layout_size_derivation(geometry)
    hidden = frozenset(geometry["hiddenGraphs"])
    overrides = geometry["heightOverrides"]
    vertical = d["orientation"] == "vertical"
    expected = {}
    for gid in GRAPH_IDS:
        if gid in hidden:
            expected[f"graphs.{gid}.size_width"] = (0.0, HIDDEN_SIZE_TOLERANCE)
            expected[f"graphs.{gid}.size_height"] = (0.0, HIDDEN_SIZE_TOLERANCE)
        elif vertical:
            expected[f"graphs.{gid}.size_width"] = (d["verticalWidth"], SIZE_TOLERANCE)
            expected[f"graphs.{gid}.size_height"] = (d["verticalHeights"][gid], SIZE_TOLERANCE)
        else:
            expected[f"graphs.{gid}.size_width"] = (d["unit"], SIZE_TOLERANCE)
            height = d["contentHeight"]
            if gid in overrides:
                height = min(d["contentHeight"],
                             max(d["minHeight"], float(overrides[gid])))
            expected[f"graphs.{gid}.size_height"] = (height, SIZE_TOLERANCE)
    return expected


def assert_layout_sizes(document_text, geometry=None):
    """Fix round 4/5 / finding 2: the app's document MUST contain ALL 26 explicit
    ``graphs.<id>.size_width/height`` settings, each a finite number, AND each
    value MUST MATCH the EXPECTED size DERIVED from the app's own layout rules
    + INDEPENDENTLY MEASURED geometry + seed, within a stated tolerance. The
    measured frame is the launched app's window; a document whose sizes are
    inconsistent with that measured frame FAILS. A MISSING or CORRUPTED entry
    FAILS, and so does a WRONG-BUT-IN-RANGE entry (all-zero, cpu 140->900, or
    a hidden graph with a nonzero size) -- the old fix-round-3 range check
    accepted those. Returns the {key: value} dict of the 26 validated sizes.
    """
    geometry = geometry or CONTROLLED_GEOMETRY
    obj = json.loads(document_text)
    if not isinstance(obj, dict) or not isinstance(obj.get("settings"), dict):
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: the app document is not a settings document")
    settings = obj["settings"]
    derivation = layout_size_derivation(geometry)
    expected = expected_layout_sizes(geometry)
    bound = size_upper_bound(geometry)  # PORTABLE: scales with the measured frame
    values = {}
    for key in sorted(LAYOUT_SIZE_KEYS):
        if key not in settings:
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: the app document is MISSING required "
                f"layout size setting {key}")
        value = settings[key]
        if not _valid_layout_size(value, bound):
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: the app document has a CORRUPTED layout "
                f"size setting {key}={value!r}; expected a finite number in "
                f"[0, {bound}] consistent with the MEASURED "
                f"{geometry['expandedWindowWidth']}x"
                f"{geometry['windowHeight']} window")
        expected_value, tolerance = expected[key]
        if abs(float(value) - expected_value) > tolerance:
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: the app document has a WRONG layout "
                f"size {key}={value!r}; the app's windowChanged layout for the "
                f"MEASURED {geometry['expandedWindowWidth']}x"
                f"{geometry['windowHeight']} window (titleHeight="
                f"{geometry['textRectHeight']}) expects "
                f"{expected_value!r} +/- {tolerance} (unit="
                f"{derivation['unit']!r}, contentHeight="
                f"{derivation['contentHeight']!r}, cpuOverride="
                f"{derivation['cpuHeight']!r}, hidden="
                f"{sorted(geometry['hiddenGraphs'])}) -- sizes inconsistent "
                f"with the measured window frame")
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


def load_app_document(document_path, actual_diagnostics, expected_diagnostics,
                      expected_document, geometry=None):
    """Read the document the LAUNCHED APP produced and compare it.

    If the app did not migrate -- no document at its R11 store, as when the env
    var is withheld -- this FAILS. The check never fabricates the document
    itself; this is the negative-control gate (finding 1).

    ``geometry`` is the INDEPENDENTLY MEASURED geometry (fix round 5, finding
    2b): production always supplies it so the 26 size values are validated
    against the launched app's MEASURED frame/font, not a host-specific oracle.
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
    # values derived from the app's layout rules applied to the MEASURED
    # geometry (not just a valid range); a missing, corrupted or wrong entry
    # fails here before the comparison.
    assert_layout_sizes(document, geometry=geometry)
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
                   derived_oracle_matches_pinned=False, baseline_converged=False,
                   measured_geometry=None):
    """Only a full (launched) run may claim a 0.2.2 relaunch (finding 2)."""
    return {
        "domain": domain, "seed": str(seed), "expected": str(expected),
        "documentSource": "launched 0.2.3 app startup migration (R25 gated path, R11 private store)",
        "documentPath": str(document_path),
        "documentMatchesExpected": True, "diagnostics": diagnostics,
        "layoutSizeSettingsNormalised": layout_size_settings_normalised,
        "layoutSizeKeysValidated": layout_size_keys_validated,
        "expectedSizesFromMeasuredGeometry": measured_geometry is not None,
        "measuredGeometry": measured_geometry,
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


def launch_phase(app, domain, results, timeout, processes, reaped, extra_env=None,
                 phase="app", observe=None):
    """Launch one renamed app, prove residency, then quit/reap its whole group.

    On success the pid is marked reaped so the top-level finally does not
    re-signal a freed pid; on a reap failure it stays pending and is retried.

    ``observe(pid)`` is an OPTIONAL, observational measurement run while the
    app is still RESIDENT (before reaping): fix round 5 uses it to read the
    launched process's live window frame via CGWindowList. It NEVER breaks the
    launch (best-effort), so a missing Screen Recording permission cannot fail
    an otherwise valid run.
    """
    record = launch_one(app, domain, results, timeout, processes, extra_env, phase)
    process = processes[-1]
    if observe is not None:
        try:
            record["liveWindowFrame"] = observe(process.pid)
        except Exception as error:  # observational only
            record["liveWindowFrame"] = None
            record["liveWindowFrameError"] = f"{type(error).__name__}: {error}"
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
# Fix round 5, finding 2b: INDEPENDENT geometry MEASUREMENT (integration).
# The window frame is measured from the LAUNCHED process via CGWindowList and
# from app-written window-frame keys; the font metric is computed portably from
# the seed font. None is inferred from the 26 size keys under validation.
# --------------------------------------------------------------------------

def live_window_frame(pid):
    """INDEPENDENT live OS measurement of the launched process's window frame
    via CGWindowList (Quartz): match kCGWindowOwnerPID == pid and take the
    largest kCGWindowBounds. This is 'read the window's frame from the launched
    process via the CGWindowList APIs' -- entirely outside the app's settings
    data and the 26 size keys. Screen Recording permission is NOT needed for
    bounds/PID. Returns (width, height) or None (best-effort, never raises).
    """
    try:
        cg_path = ctypes.util.find_library("CoreGraphics")
        cf_path = ctypes.util.find_library("CoreFoundation")
        if not cg_path or not cf_path:
            return None
        cg = ctypes.CDLL(cg_path)
        cf = ctypes.CDLL(cf_path)
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
        cf.CFArrayGetCount.restype = ctypes.c_long
        cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
        cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
        cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        cf.CFDictionaryGetValue.restype = ctypes.c_void_p
        cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        cf.CFNumberGetValue.restype = ctypes.c_ubyte
        cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
        cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p

        def cfstr(text):
            return cf.CFStringCreateWithCString(None, text.encode("ascii"), 0x0600)

        def number(dictionary, key):
            value_ref = cf.CFDictionaryGetValue(dictionary, key)
            if not value_ref:
                return None
            out = ctypes.c_double()
            if cf.CFNumberGetValue(value_ref, 13, ctypes.byref(out)):  # kCFNumberDoubleType
                return out.value
            return None

        k_pid = cfstr("kCGWindowOwnerPID")
        k_bounds = cfstr("kCGWindowBounds")
        k_width = cfstr("Width")
        k_height = cfstr("Height")
        best = None
        # kCGWindowListOptionOnScreenOnly|ExcludeDesktopElements AND option All
        # (so a collapsed/minimised window is still considered); keep the
        # largest window owned by the launched pid across BOTH lists. NOTE: the
        # seed starts the main graph window MINIMIZED (windowIsMinimized=True),
        # so CGWindowList sees the collapsed strip + sensor window but NOT the
        # expanded graph window. The layout `size` input is therefore measured
        # from the app-written restore rectangle (unminimizedFrame) instead --
        # see collect_measured_geometry; this live measurement is an independent
        # corroboration that the app genuinely launched an AppKit window.
        for option in (1 | 16, 0):
            array = cg.CGWindowListCopyWindowInfo(option, 0)
            if not array:
                continue
            count = cf.CFArrayGetCount(array)
            for index in range(count):
                window = cf.CFArrayGetValueAtIndex(array, index)
                owner = number(window, k_pid)
                if owner is None or int(owner) != int(pid):
                    continue
                bounds = cf.CFDictionaryGetValue(window, k_bounds)
                if not bounds:
                    continue
                width = number(bounds, k_width)
                height = number(bounds, k_height)
                if width is None or height is None or width <= 0 or height <= 0:
                    continue
                if best is None or width * height > best[0] * best[1]:
                    best = (width, height)
        return best
    except (OSError, ValueError, TypeError, OverflowError, ctypes.ArgumentError):
        return None


# The portable font-metric helper: it computes XRGSettings.textRectHeight EXACTLY
# (XRGSettings.swift:390/492), from the seed's graphFont, on the host running
# the check. Its output is a MEASURED layout INPUT, not one of the 26 sizes.
TITLE_HEIGHT_SWIFT = r'''// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import Foundation
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("title-height-helper: " + message + "\n").utf8))
    exit(1)
}
let arguments = CommandLine.arguments
guard arguments.count == 3, let size = Double(arguments[2]) else {
    fail("usage: TITLEHELPER <font-name> <point-size>")
}
let name = arguments[1]
let font: NSFont = name == "System"
    ? NSFont.systemFont(ofSize: CGFloat(size))
    : (NSFont(name: name, size: CGFloat(size)) ?? NSFont.systemFont(ofSize: CGFloat(size)))
let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .right
let attributes: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
// The SAME line-height metric XRGSettings.textRectHeight (and therefore
// XRGModuleManager.titleHeight) uses.
let height = ("A" as NSString).size(withAttributes: attributes).height
guard height.isFinite, height > 0 else { fail("font produced a non-positive line height") }
print("TITLE_HEIGHT " + String(format: "%.6f", height))
'''


def measure_title_height(font_name, font_size, results):
    """COMPUTE the font metric PORTABLY: the line height of 'A' in the seed's
    graphFont via the SAME AppKit NSString.size(withAttributes:) call the app
    uses for textRectHeight. Measured on the host running the check (NOT a
    hardcoded constant, NOT inferred from the 26 sizes)."""
    source = results / "TitleHeightHelper.swift"
    source.write_text(TITLE_HEIGHT_SWIFT)
    executable = results / "TitleHeightHelper"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(source), "-o", str(executable)],
                   check=True, stdout=subprocess.DEVNULL)
    result = subprocess.run([str(executable), font_name, str(font_size)],
                            check=True, capture_output=True, text=True)
    for line in result.stdout.splitlines():
        if line.startswith("TITLE_HEIGHT "):
            value = float(line.split(maxsplit=1)[1])
            if math.isfinite(value) and value > 0:
                return value
    raise RuntimeError("SETTINGS_UPGRADE_MACOS: could not measure the font title height")


def collect_measured_geometry(domain, seed, results, live_frame=None,
                              export=export_domain, measure_font=measure_title_height):
    """Build the geometry whose EXPECTED sizes the PRODUCTION check validates,
    from INDEPENDENTLY MEASURED inputs (fix round 5, finding 2b). NONE of these
    is one of the 26 graphs.<id>.size_* values under validation:
      * frame (W, H): the launched 0.2.3 app's AppKit window-frame keys it
        writes into its disposable domain (window_frame_from_domain -- a value
        the app writes that is NOT a size key), corroborated by a LIVE
        CGWindowList measurement of the running process (live_frame);
      * title height: the seed graphFont's line height, COMPUTED PORTABLY via
        AppKit (measure_font) -- the font metric the layout uses.
    Returns (geometry, provenance). FAILS LOUDLY if the frame cannot be
    measured (never silently falls back to host-specific hardcoded geometry).
    """
    exported = export(domain)
    frame = window_frame_from_domain(exported)
    if frame is None:
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: cannot MEASURE the launched 0.2.3 app's "
            "window frame from its app-written AppKit window-frame keys "
            "(unminimizedFrame / 'NSWindow Frame *'); refusing to derive "
            "expected sizes from host-specific hardcoded geometry")
    frame_w, frame_h, frame_key = frame
    font_name, font_size = font_descriptor_from_seed(seed)
    title_height = measure_font(font_name, font_size, results)
    # R9-2: the orientation MUST come from the seeded/normalised domain, not a
    # hardcoded "horizontal". XRGModuleManager defaults to vertical. Read it
    # from the same domain export as the frame (never from the 26 size keys).
    orientation = orientation_from_domain(exported)
    geometry = measured_geometry(frame_w, frame_h, title_height, orientation=orientation)
    provenance = {
        "orientation": orientation,
        "orientationSource": ("graphOrientationVertical in the seeded/normalised "
                              "domain, coerced with UserDefaults.bool(forKey:) "
                              "semantics -- independent of the 26 validated size keys"),
        "measurement": "independent of the 26 graphs.*.size_* keys under validation",
        "frameWidth": frame_w,
        "frameHeight": frame_h,
        "frameSource": ("app-written AppKit window-frame key "
                        f"'{frame_key}' in the launched app's disposable defaults "
                        "domain (NOT a size key)"),
        "titleHeight": title_height,
        "titleHeightSource": ("AppKit (\"A\").size(withAttributes:) line height of "
                              f"the seed graphFont '{font_name} {font_size:g}' -- the "
                              "SAME metric as XRGSettings.textRectHeight, computed "
                              "portably on this host"),
        "fontName": font_name,
        "fontSize": font_size,
        "liveWindowFrame": list(live_frame) if live_frame else None,
        "liveFrameSource": ("CGWindowList kCGWindowBounds of the launched process "
                            "(independent live OS measurement)"),
        "liveFrameCorroboratesLaunch": live_frame is not None,
        "liveFrameConsistent": frames_consistent((frame_w, frame_h), live_frame),
        "liveFrameNote": (
            "The seed starts the main graph window MINIMIZED "
            "(windowIsMinimized=True), so CGWindowList reports the live on-screen "
            "collapsed strip / sensor windows, NOT the expanded graph window; "
            "liveFrameConsistent is therefore EXPECTED to be False and is purely "
            "informational (it never gates success). The layout `size` input is "
            "measured from the AppKit restore rectangle 'unminimizedFrame' -- the "
            "EXACT NSWindow.frame.size passed to windowChanged(to:) -- a value the "
            "app writes that is NOT one of the 26 size keys. Both sources are "
            "independent of the 26 validated sizes."),
        "sizeTolerance": SIZE_TOLERANCE,
        "hiddenSizeTolerance": HIDDEN_SIZE_TOLERANCE,
        "sizeUpperBound": size_upper_bound(geometry),
    }
    return geometry, provenance


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
    measured_geometry_provenance = None  # fix round 5, finding 2b
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
            # Fix round 5, finding 2b: while the 0.2.3 app is RESIDENT, take an
            # INDEPENDENT live CGWindowList measurement of its window frame.
            upgrade_record = launch_phase(
                new_copy, domain, results, args.launch_timeout,
                processes, reaped, env_for_upgrade, "0.2.3-upgrade",
                observe=live_window_frame)
            launches.append(upgrade_record)
            settle(args.settle_timeout)

            # ---- [4] validate-app-document (negative-control gate) ------------
            # Fix round 5, finding 2b: MEASURE the launched app's window frame
            # (app-written frame keys + live CGWindowList cross-check) and the
            # font metric (seed graphFont line height, computed portably), then
            # DERIVE the expected sizes from those INDEPENDENTLY MEASURED inputs
            # -- NEVER from hardcoded 1779/13, NEVER from the 26 size keys.
            measured, measured_geometry_provenance = collect_measured_geometry(
                domain, seed, results,
                live_frame=upgrade_record.get("liveWindowFrame"))
            (results / "measured-geometry.json").write_text(json.dumps(
                measured_geometry_provenance, indent=2, sort_keys=True) + "\n")
            # load_app_document now ALSO requires ALL 26 explicit size keys to be
            # present and CORRECT w.r.t. the MEASURED geometry; a missing,
            # corrupted or frame-inconsistent entry fails here.
            document = load_app_document(document_path, driver_diagnostics,
                                         expected_diagnostics, oracle_document,
                                         geometry=measured)
            (results / "0.2.3-document.json").write_text(document)
            before_bytes = document_path.read_bytes()
            (results / "layout-sizes.json").write_text(json.dumps(
                assert_layout_sizes(document, geometry=measured),
                indent=2, sort_keys=True) + "\n")
            # Record the MEASURED geometry + DERIVED expected sizes and
            # tolerances, so the correctness oracle is fully auditable.
            (results / "layout-size-derivation.json").write_text(json.dumps(
                {"measuredGeometry": measured_geometry_provenance,
                 "derivation": layout_size_derivation(measured),
                 "expected": {k: {"expected": v, "tolerance": t}
                              for k, (v, t) in expected_layout_sizes(measured).items()},
                 "sizeUpperBound": size_upper_bound(measured),
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
            baseline_converged=downgrade_normalised,
            measured_geometry=measured_geometry_provenance), indent=2) + "\n")
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
