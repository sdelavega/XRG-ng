# XRG-ng coordinator handoff

Updated 2026-10-30. Implementation baseline: `f98badc` on `main`, pushed to
`sdelavega/XRG-ng`. Working tree was clean before this handoff was added.

## Direction and settled decisions

- macOS: native AppKit, predominantly Swift, targeting macOS 26+. Preserve
  original nib/settings compatibility. Linux: Rust + egui/eframe, reusing portable
  Swift through the versioned C ABI. The old Linux C/GTK implementation is retired;
  do not resume that port or reintroduce GTK/GSK/Cairo/GLib dependencies.
- Aim for equivalent workflows and honest metric meanings, not identical readings
  across different kernels. Preserve missing-data gaps, source identity, reset
  boundaries, cancellation, existing settings, and original XTF load/save support.
- Classic is the palette imported from the original XRG theme, not the former pink
  palette. Built-in themes coexist with external theme loading/saving.
- GPL-3.0-or-later. APSL-derived sensor implementations/catalog were replaced.
  Retain GPL-compatible dependencies and required notices; the user explicitly
  chose this over replacing every non-GPL dependency. Historical releases retain
  their historical notices/arrangements. See THIRD_PARTY_NOTICES.md.
- Hardware support is best effort; lack of every physical vendor device is not a
  blocker. Feedback is explicitly encouraged. TPU includes onboard NPUs.

## Where we stopped

Recent commits:

- `f98badc`: recognize uppercase Rockchip vendor `RKNPU` driver as well as `rknpu`,
  allowing the existing uniquely-owned debugfs utilization reader to work. Tests
  preserve three-core averaging, real zero, suspended masking and ambiguous
  multi-device rejection. No automatic privilege elevation.
- `95054b0`: documented physical Raspberry Pi 5 and RK3588 Linux validation.
- `0fdf7a3`: preserve observed Network/Disk transfer deltas across native wake while
  rebasing rates. Previous work moved GPU snapshot collection off the main actor,
  coalesced requests and rejected stale publication across reset/sleep/wake.

Physical RK3588 NPU result: a private MobileNet/RKNN experiment completed 3,950
inferences in eight seconds; root-readable debugfs showed core 0 up to 91%, other
cores zero, then suspension. A patched debug headless XRG run then completed 18
samples alongside 3,971 inferences, showing 0% to 30.7% averaged utilization and
unavailable after suspension. Both exited 0. Unprivileged XRG completed three
samples with activity unavailable: this image restricts debugfs to root. Devfreq
reported 100 while suspended and is deliberately NOT treated as NPU activity.
Temporary vendor SDK/model were test inputs only and are not shipped dependencies.

The latest full ARM64 Linux debug gate passed: 591 Rust tests, 38 shared Swift
tests, C ABI smoke, fmt/clippy, live collection, UI dependency/retirement guards,
Classic/Midnight, sensor/clipboard, file-picker and X11/Wayland collapse/scale checks.
macOS was unchanged in that pass. Its preceding full gate passed 615 tests on ARM64
and 615 under Rosetta, universal builds and packaged launch checks. Rosetta does
not establish physical Intel coverage; synthetic wake tests do not establish
actual sleep/wake behavior.

Pi validation: Debian 13.4, CPU/memory/I/O, thermal/fan, X11 smoke and native
Wayland app exit 0 with V3D rendering. The temporary headless labwc compositor
segfaulted at shutdown (139), reproduced; do not call the entire session a pass.
RK3588: Arch-derived Beryllium OS, X11 smoke, eight thermal inputs, NPU, separate
Mali-G610/Panfrost EGL probe. Native Wayland app session was not tested there.
Rendering success does not establish complete GPU utilization/VRAM telemetry.

## Recommended next steps

1. Resume the sampling/lifecycle parity work interrupted by hardware validation.
   Read SAMPLING_PARITY.md, especially “Next work,” then PLATFORM_PARITY.md's
   remaining monitoring work. Prioritize remaining wake/long-gap behavior and
   interval-edit phase policy, preserving observed transfers/accounting totals.
   Linux's elapsed clock excludes suspend; do not apply blanket counter resets.
2. Audit optional-source hidden/visible eligibility (NPU, GPU/VRAM, temperature,
   fans, weather/Stocks) and measure collection/publication costs before further
   worker changes. Core hidden collection is already aligned. Any global Pause
   control needs explicit semantics for collection vs display vs accounting;
   it is not implemented merely by collapsing or hiding the window.
3. For useful unprivileged Rockchip NPU activity, investigate a narrowly scoped,
   read-only access mechanism or documented administrator configuration. This is
   a proposed follow-up, not an approved design: do not run the GUI as root by
   default or broadly relax debugfs permissions. Keep unsupported activity absent.
4. Then address remaining source selection/graph modes, AI source continuity,
   weather/battery units/cadence/multiple batteries, Stocks if retained, and desktop
   differences listed in PLATFORM_PARITY.md. Make focused passes with fixtures,
   persistence/cancellation coverage and appropriate platform gates.
5. Release work is separate. A dedicated XRG-ng signing key was the user's chosen
   direction; verify current signing/configuration state before publication. Linux
   packaging/release tooling includes x86-64/ARM64 distribution work. Do not infer
   a new release has been published from successful preview tests.

## Operations and evidence

- Commands: `bash Tools/ci-linux.sh debug` in a suitable Linux environment;
  `bash Tools/ci-macos.sh Debug` for native changes. CI workflows document desktop
  dependencies. Do not weaken assertions or smoke gates to accommodate missing tools.
- Ignored local evidence: `dist/arm-host-validation`,
  `dist/rknpu-activity-validation`, and `dist/io-wake-validation`. The latest NPU
  directory retains logs, source/binary hashes, private SDK provenance and UI
  evidence archive. These are local artifacts, not portable public dependencies.
- Full implementation chronology: MODERNIZATION.md (older “remaining” lists are
  historical). Current parity documents above are the better planning entry points.
- Owned remote test scratch and disposable build container were removed; about
  13.6 GiB was freed in the last pass. No validation process is intentionally left
  running. Preserve shared images, installed apps, settings and unrelated caches.
- Private SSH host details and credentials are intentionally excluded here. Obtain
  them from the user/private conversation. The RK3588 box permits deeper testing;
  the Pi must be treated gently, with read-only/isolated tests and no disruptive
  system changes. Reboot authorization applies only to the RK3588 test box when
  SSH gets flaky, not to the Pi. Attempt bounded sudo reboot before requesting a
  manual cycle, but independently verify connectivity: delayed log output alone
  is not a stall. One premature reboot request occurred; the box returned and
  subsequent tests completed normally. Never claim the workload caused a crash.
- Periodic /private/var cleanup is authorized only for confirmed inactive,
  user-owned XRG scratch at least 24 hours old; defer during active validation.
  Never broadly purge /private/var or follow links outside confirmed scratch.
- XRG is currently NOT tracked by Gortex. Native tools are appropriate unless that
  state changes; do not start/retrack a daemon merely to enable graph tools.
