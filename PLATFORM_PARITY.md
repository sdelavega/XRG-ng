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
- Linux graph menus/Live details now clear individual histories, and the
  application menu clears all histories. Collector/rate baselines, sensor
  statistics and AI usage remain intact; AI generation checks discard queued
  pre-reset plots. Weather retains the latest observation and its freshness guard.
- Linux Network/Disk faces now show observed session transfers, with raw kernel
  totals in details. Transfer reset preserves graphs/rate baselines, source changes
  restart the session, and failed-read gaps/saturation are marked as lower bounds.
- Mac now has optional, default-hidden VRAM and Fans graphs with up to three
  sources, per-graph presentation, read-only details and independent history reset.
  GPU/VRAM share one read per graph tick; Fans reuses the temperature collector's
  fan cache. Original GPU/Temperature readings and old presentation profiles remain.
  Allocation-only GPU memory is labeled and plotted in bytes; reported pools use
  percentages when every plotted source has capacity. Linux VRAM currently needs
  a reported used/total pair. Mac optional sources are automatic (extra readings
  in details); Linux also supports explicit fan source selection.
- Mac session/daily AI accounting now consumes observed deltas from Claude,
  Codex, Gemini and Hermes, with explicit unknown input/output splits and available
  log/database model attribution. Initial history is excluded; source changes,
  resets and tracking changes establish new baselines. Daily counters persist;
  independent resets preserve graphs/provider history. A shared portable Swift
  delta helper covers counter corrections and attribution bounds. Mac native budget
  alerts have an explicit permission action and respect OS authorization. Mac cost
  menus now label estimates and source values instead of claiming current pricing.

Remaining monitoring work:

1. Monitoring tools: Mac process controls and richer live details; align optional
   source selection, counter displays and remaining graph modes.
   Retain the existing integrated Mac fan/VRAM readings.
2. AI accounting: expose the shared delta contract to Rust and add Linux persistent
   daily/session counters, resets, budgets and native notifications. Align source
   continuity/model attribution and Mac/Linux observed windows. Mac Codex still
   lacks model/input-output attribution; Ollama inventory is not token accounting.
   Mac log scans retain their last complete snapshot through failed scans, while
   database/endpoint failure breaks accounting continuity. Keep cost estimates
   optional and labeled; neither platform's observed counters are billing records.
3. Weather/battery/Stocks: align history windows, secondary weather curves, unit
   choices and battery graph modes. Port Stocks if retained in the common set.
4. Desktop behavior: Linux collapse/hover expansion and supported window controls;
   preserve explicit compositor limitations. Align history duration and sampling
   controls without equating different OS memory or NPU measurements.

Each pass needs UI, persistence, cancellation, invalid/unavailable-data and fixture
coverage on both platforms. Compare metric meaning and supported interactions,
not just the number of panels. Physical hardware validation remains best effort;
missing hardware is not a prerequisite for finishing these passes.
