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
- Linux now uses the same Swift delta ledger through an additive, thread-confined
  ABI. AI preferences enable observed accounting and optional desktop alerts;
  the AI inspector has independent session/daily resets, exact splits/unknowns,
  daily aggregates and persistence/delivery status. Daily state is private and
  locked against competing instances; invalid/changed files are preserved and
  persistence failures suppress alerts. Resets/settings changes arriving during
  collection discard that observation. Budget changes preserve graph histories
  and rate baselines. Native notifications use Rust D-Bus with a one-second
  deadline, independent of the egui redraw cycle and graph visibility.

Implemented in this pass:

- Mac AI modules continue accounting through the existing graph timer while hidden
  or collapsed, with no duplicate visible-module dispatch. Hidden modules with
  tracking disabled cancel outstanding scans/HTTP work and rebaseline on resume;
  detachment and application shutdown also stop collection. Budget delivery remains
  independent of visibility. Both now use a nominal five-second AI cadence,
  independent of system graph refresh: Mac has a separate common-mode timer and
  Linux a separate worker.
- Linux Battery offers its existing charge-percent history and an optional signed
  power history. Charging is positive, discharging negative, with a symmetric
  axis of at least ±30 W. Missing power or ambiguous direction remains a gap;
  genuine zero is preserved. Separate histories are collected together and both
  clear with graph reset. No charging settings are written.
- Linux weather temperature, visibility and pressure can use independent units;
  wind/gusts additionally support knots. Missing overrides inherit the saved unit
  system, preserving old profiles. Unit changes reformat cached observations and
  plots without fetching again or clearing station history.

- Both weather panels now offer 6/12/24-hour windows using actual UTC observation
  spacing and optional wind, humidity, visibility, dewpoint or pressure curves on
  separate axes. Missing fields, bounded visibility and gaps over two hours stay
  gaps; stale cached history remains visible with current bars suppressed. H/L is
  scoped to received temperatures in the selected window. Providers do not promise
  complete coverage. Existing defaults remain Mac received-response / Linux session.
  No new network request is made for presentation changes.

- Mac Codex now supplies recorded input/output components and qualified turn-model
  partitions to observed session/daily accounting. Its AI context menu separates
  cumulative log details from observed counters. Both ports use the same Swift
  component decoder and a common attribution corpus; unknown/synthetic usage stays
  unclassified. Mac checked Codex scans retain the last complete snapshot on I/O
  or size failures; resets still invalidate pre-reset scans. Files are limited to
  64 MiB with 8 MiB records and 255 named models; excess metadata never adds tokens.

- Log accounting and rates now rebaseline on complete-inventory additions/removals,
  renames, device/inode replacements, shorter files and per-file counter rollbacks,
  even when other files hide the rollback in the aggregate. Both use a shared Swift
  file-state predicate and the same fixture corpus. Ordinary nonshrinking updates
  to known files with nondecreasing totals retain continuity. Cached numeric totals,
  graphs and observed counters survive a boundary; imported history cannot cause a
  usage/rate/cost spike. Mac failed or concurrently changing sweeps retain the last
  complete cached data and break accounting continuity; recovery establishes a fresh
  baseline, matching Linux's existing error/recovery rule. Draft sweeps never commit
  an inventory identity. These conservative transitions can undercount real activity.

- Mac AI collection now uses the same nominal five-second interval as the Linux
  worker, through a shared Swift cadence contract. Repaints, high-rate system graph
  timers and a slow graph refresh no longer determine AI polling or add duplicate
  samples. The Mac miner awaits complete background log sweeps and localhost
  responses, then publishes one observation; overlapping requests coalesce. Log
  metadata caching remains active without the old 30-second scan throttle.
  Hidden accounting continues on the separate timer. Reset/apply/resume can wake
  immediately; pause, detach and shutdown cancel in-flight work, and late responses
  cannot cross a reset. Delayed ticks do not create a catch-up sample backlog.
  This is a nominal interval, not a real-time deadline under load.

Remaining monitoring work:

1. Monitoring tools: Mac process controls and richer live details; align optional
   source selection, counter displays and remaining graph modes.
   Retain the existing integrated Mac fan/VRAM readings.
2. AI accounting: align retained history duration and remaining format-specific
   message identity/deduplication and source continuity details. Both now account with hidden graphs and preserve
   recorded Codex input/output components and conservatively qualified turn models.
   Log inventory/replacement boundaries now rebaseline both platforms; periodic
   sampling is nominally five seconds on both. Semantic rewrite detection still differs. Ollama inventory is not token accounting.
   Mac log scans retain cached data for display through failed scans while breaking
   accounting continuity; database/endpoint failure also breaks continuity. Keep cost estimates
   optional and labeled; neither platform's observed counters are billing records.
3. Weather/battery/Stocks: align unit choices still absent on either side, default
   weather-history behavior/provider coverage, battery presentation/cadence and
   multiple-battery behavior. Both have explicit weather time windows/secondary
   curves; Linux now has charge/power modes and independent weather units.
   Port Stocks if retained in the common set.
4. Desktop behavior: Linux collapse/hover expansion and supported window controls;
   preserve explicit compositor limitations. Align history duration and sampling
   controls without equating different OS memory or NPU measurements.

Each pass needs UI, persistence, cancellation, invalid/unavailable-data and fixture
coverage on both platforms. Compare metric meaning and supported interactions,
not just the number of panels. Physical hardware validation remains best effort;
missing hardware is not a prerequisite for finishing these passes.
