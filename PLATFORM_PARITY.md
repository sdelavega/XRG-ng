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
- Implemented in development: Mac Graphs preferences provide persistent module
  ordering, visibility, per-graph preferred heights, RGBA colors and
  Solid/Pixel/Dot/Hollow curve fills. Display effects remain independent, with
  per-graph overrides or global inheritance. Apply/Cancel preserve draft changes;
  original rendering and ordering remain the defaults.
- Mac preferred heights compress in small windows to preserve visible modules;
  Linux uses fixed heights in its scrolling layout. Mac mini bars retain bar
  geometry and adopt the module palette; curve fills affect history plots.
- Next: define common presentation defaults and a versioned portable subset. Provider
  paths, network devices and sensor identities stay platform-local. JSON themes
  continue to contain palettes only.

## Subsequent passes

Implemented in development for monitoring tools:

- Mac CPU and Memory graph menus open a searchable process table with saved
  filters/row limits, CPU/memory/name/PID sorting, explicit refresh-failure status
  and frozen, read-only process details. Mac CPU is the recent decaying average
  reported by `ps`; Linux CPU is an interval measurement. Mac filters by exact
  reported user name; Linux supports numeric UID filtering. Linux retains its
  live identity-aware details and process controls; Mac control parity remains open.
- Linux has an all-sensor statistics inspector and a copyable diagnostic report.
  Temperature and fan statistics accumulate for the session independently of graph
  selection, retain missing-input history without stale current readings, and
  restart for replaced input incarnations. Reset clears these statistics at the
  next sample without resetting graph histories. Statistics are not persisted
  between launches.

Remaining monitoring work:

1. Monitoring tools: Mac process controls, richer live details and optional
   VRAM/Fans modules; Linux graph-history resets and session transfer totals.
   Retain the existing integrated Mac fan/VRAM readings.
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
