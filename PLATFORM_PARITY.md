# macOS / Linux feature parity

Baseline audit: `50ca1e5`. Target equivalent workflows while retaining AppKit on
macOS and egui/Rust on Linux. Preserve existing settings and XTF files. Do not
invent readings to make different kernel/hardware interfaces look identical.

## First pass: theme exchange and presentation

- Implemented in development: macOS loads portable Linux JSON themes, exports
  JSON or original XTF, and accepts JSON through explicit file-open and graph
  drag-and-drop. The native save chooser has a format selector. Shared Swift and
  Rust fixtures check strict schema acceptance and color precision.
- This has not shipped in macOS 0.1.0. A future Mac release must also include the
  already-implemented Neural Engine graphs and corrected Classic palette.
- Next: configurable module order, per-graph heights/colors and matching chart
  presentation options on Mac. Keep curve fill styles separate from display
  effects: Mac Normal/Scanlines/Pixel Grid/Retro Dots and Linux
  Solid/Pixel/Dot/Hollow currently represent different operations.
- Define common presentation defaults and a versioned portable subset. Provider
  paths, network devices and sensor identities stay platform-local. JSON themes
  continue to contain palettes only.

## Subsequent passes

1. Monitoring tools: Mac process/detail workflows and optional VRAM/Fans modules;
   Linux accumulated sensor statistics, diagnostic export, history resets and
   session transfer totals. Retain the existing integrated Mac fan/VRAM readings.
2. AI accounting: common provider/model deltas, daily/session resets, budgets and
   native notifications. Complete the Mac observer's provider integration first:
   only Gemini currently feeds it, and the threshold has no desktop notification
   consumer. Distinguish source-recorded cost from optional labeled estimates.
3. Weather/battery/Stocks: align history windows, secondary weather curves, unit
   choices and battery graph modes. Port Stocks if retained in the common set.
4. Desktop behavior: Linux collapse/hover expansion and supported window controls;
   preserve explicit compositor limitations. Align history duration and sampling
   controls without equating different OS memory or NPU measurements.

Each pass needs UI, persistence, cancellation, invalid/unavailable-data and fixture
coverage on both platforms. Compare metric meaning and supported interactions,
not just the number of panels. Physical hardware validation remains best effort;
missing hardware is not a prerequisite for finishing these passes.
