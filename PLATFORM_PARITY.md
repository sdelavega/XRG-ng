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
  and instance-bound live process details. Mac table CPU is the recent decaying
  average reported by `ps`; Mac live details and Linux use interval measurements.
  Mac filters by exact reported user name; Linux supports numeric UID filtering.
  Both now offer confirmation-based Terminate, Force Kill, Pause and Resume.
  Mac uses SDK task-name/audit-token APIs and kernel token-based signal delivery,
  with no numeric-PID fallback or privilege helper. Native identities bracket the
  ps scan; unverified rows retain frozen, read-only details. Exit/identity changes
  stop detail updates and actions; read failures retain explicitly stale details.
  Process protections and permissions can still prevent access or delivery.
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
  Mac Network/Disk now share those accounting/reset rules: directional byte totals
  and raw kernel counters appear in Transfer Details…, with separate Reset Session
  Transfers actions. Existing compact combined totals remain, with ≥ for incomplete
  or saturated coverage. Graph reset preserves rates/baselines and totals; a transfer
  reset excludes the next interval spanning the action. Failed reads append gaps
  and show unavailable rates; recovery retains counted totals and rebaselines.
  Membership/identity changes and any counter rollback start a fresh session and
  plot. Network name/index reuse between observations remains undetectable; disk
  replacement uses registry IDs. Fast samples do not add to normal session totals.
- Mac now has optional, default-hidden VRAM and Fans graphs with up to three
  sources, per-graph presentation, read-only details and independent history reset.
  GPU/VRAM share one read per graph tick; Fans reuses the temperature collector's
  fan cache. Original GPU/Temperature readings and old presentation profiles remain.
  Allocation-only GPU memory is labeled and plotted in bytes; reported pools use
  percentages when every plotted source has capacity. Linux VRAM currently needs
  a reported used/total pair. Mac optional panels now retain automatic selection
  by default and offer persistent custom curve slots through Choose Sources….
  Apply/Cancel are separate drafts; None preserves an empty color slot. Missing
  pinned sources show gaps and never select another device. Unaffected histories
  survive source changes; metadata and unit changes reset the affected histories.
  VRAM choices prefer IOService locations, falling back to session registry IDs;
  driver/topology changes may require reselection. Fan choices use sensor keys.
  Source IDs remain platform-local. Linux also supports explicit fan/GPU selection;
  Mac integrated GPU/Temperature readings remain separate from these optional plots.
- Mac CPU/GPU now have persistent graph-menu source selection with aggregate/all
  defaults. CPU pins use zero-based logical slots; GPU pins prefer IOService
  locations, falling back to registry IDs. Missing pins stay unavailable. Cached
  per-source histories survive switches; source/mode changes never read hardware.
  GPU has a utilization-only option alongside the existing memory/activity view;
  unsupported percentages do not fall back to memory or wait-time measurements.
  Read-only scrollable details explain scope, source identity and units. GPU reset
  clears only selected GPU histories and preserves readouts/optional VRAM settings;
  failed GPU reads append gaps and mark current values unavailable. Replacement
  GPU instances/metadata start new histories.
- Mac CPU Average now uses the latest interval across selected logical CPUs,
  independently of graph size/history. Total remains core-percent and Average is
  normalized to 0–100%. CPU graph reset preserves live readings, choices, both
  sampling baselines, fast smoothing and availability, without reading hardware.
  Cleared/resized histories use missing samples; aggregation/stacking preserve gaps.
  The shared Mac default renderer now segments those gaps instead of bridging them
  or extending a stale endpoint to now; complete histories retain legacy geometry.
  Warm-up, zero-progress and failed intervals show unavailable instead of fake idle;
  recovery first establishes a fresh baseline. Normal/fast streams recover separately.
  An aggregate requires valid intervals on all selected cores; pinned valid cores
  remain usable independently. Changed CPU counts clear history and both baselines
  to avoid logical-slot mixing. Both now share a CPU interval boundary: finite,
  nonnegative, strictly increasing monotonic timestamps at most five minutes apart.
  Missing reads, invalid/delayed intervals and zero-progress counters leave gaps
  while retaining earlier observations; Linux initial padding is also missing.
  Graph clearing preserves interval baselines. Linux counter rollback/layout or
  graph scope changes still clear the affected history; inventory survives failed
  reads so recovery cannot mix scopes. Mac uses a continuous clock that includes
  sleep; the Linux worker's elapsed clock excludes suspend. Remaining differences:
  OS tick/CPU accounting, suspend detection, and topology/wrap policies.
  Mac stacks system/user/nice while Linux plots
  independent non-idle/user/system curves. Linux may still have a valid kernel
  aggregate when an individual logical-CPU interval is unavailable.
- CPU retention now has explicit capacities on both platforms. Mac's CPU History
  graph menu offers presets; Linux Preferences / Sources accepts 1–20,000 retained
  samples. Valid custom Mac counts remain selectable. Automatic preserves legacy
  defaults (Mac graph width, Linux 120 samples). Resizing retains newest values and
  gaps without resetting collector baselines; explicit capacity survives window
  resizing. Nominal spans describe point spacing at the current target, not a
  measured time axis. Shared Swift owns bounds and history resizing, exposed to
  Rust by additive ABI v1 functions. Linux settings migrate read-only to version 28
  and write the new version only on save. Preferences remain platform-local.
  Both normal sampling controls cover 200 ms–10 s, with millisecond precision;
  valid legacy Mac values outside that range survive opening/saving. Mac restarts
  its graph timer on edits; Linux retimes from the worker's last sample start.
  AI/fast sampling stays independent.
- Memory, Network and Disk now share CPU's explicit-capacity workflow: Mac graph
  history menus / Linux Preferences Sources, 1–20,000 samples, preserving original
  automatic defaults. Capacity changes retain newest observations and normal/fast
  rate/paging baselines and session transfers without polling hardware. Growing
  explicit Mac capacities adds missing padding; paging stacks use CPU's gap-safe sums.
  Source/failure reset policies remain unchanged and keep the chosen capacity.
  Mac Memory retains paging activity; Linux retains RAM/cache/swap percentages.
  Current RAM/swap bars and accounting remain separate from history settings.
  The Linux per-module map migrates old files without a write; unsupported module
  keys and invalid capacities reject the entire settings edit. AI and Weather have
  separate cadence/windows; timestamp-based retention remains open. Mac Memory's
  existing Reset Graph still resets its paging baseline; Linux preserves it.
- GPU, NPU and VRAM now also have independent capacity controls. All cached
  device histories retain newest samples when resized; future/replacement histories
  use the configured capacity. GPU activity source/driver changes and NPU quantity
  or client-scope changes keep their existing reset boundaries. VRAM pool/metadata
  replacements remain separate histories. Capacity changes do not poll hardware,
  reset NPU energy/rate baselines, enable profiling or change source selection.
  Native VRAM settings leave Fans untouched. GPU/TPU-category/VRAM map entries
  migrate without writing until explicit save. Mac NPU
  power/activity/traffic and Linux activity/producer rates retain different meanings;
  missing counters remain unavailable. This does not establish physical GPU/NPU
  validation on unowned platforms.
- Temperature, Fans and Battery now have independent sample capacities through the
  same Mac history menus / Linux Sources controls. Resizing preserves newest readings,
  sensor choices, polling baselines and session statistics. The standalone Mac Fans
  graph has its own capacity; integrated fan curves share Temperature’s capacity.
  Newly added positions are missing, cold temperatures stay valid, and zero RPM remains a stopped fan. Native
  temperature label rendering reads the fan cache without refreshing hardware.
  Linux charge and signed-power histories remain separate; Mac keeps its split
  charge/discharge watt curves. Source, failure and aggregate membership boundaries
  keep their existing policies. Linux schema 29 upgrades older profiles without writing
  until explicit save. AI/Weather duration and timestamp-based retention remain open.
- AI rate history now has independent sample capacities on both platforms: Mac
  **AI History** and Linux **Preferences → AI → Retained AI samples**. Explicit
  counts keep newest values and gaps while preserving current rates, rate/cost
  baselines and session/daily accounting. Mac stacked sums propagate missing
  padding. Linux excludes retention from source identity, preserving the collector
  and accounting ledger through capacity edits. Source/failure policies remain.
  Both describe nominal spans at the shared five-second cadence. Original automatic
  defaults remain (Mac width minus indicator strip, Linux 120); collection delays
  mean equal capacities are not guaranteed equal wall-clock windows. Linux AI
  history-only edits now resize the cached result without collecting, appending a
  duplicate observation or changing counters/alerts. They preserve the existing
  deadline and an in-flight scan; source/accounting edits and counter resets still
  request collection. Schema 30 upgrades old files without writing until explicit
  save. Timestamp-based retention and remaining scheduling work are still open.
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

- Linux now has a persistent manual collapse latch, hostname double-click/Ctrl+M
  controls, a compact hostname strip in either layout and optional transient hover
  expansion. Explicit expansion pins the window open; Preferences, inspectors,
  menus and pointer gestures keep hover expansion open. Sampling continues while
  collapsed. Expanded dimensions remain separate from transient strip/hover sizes
  and UI zoom. Top/left and bottom/right anchors use desktop-supplied coordinates;
  Wayland placement remains compositor-controlled. Maximized/fullscreen windows
  stay expanded. Existing profiles default to expanded with hover disabled.

Remaining monitoring work:

1. Monitoring tools: align optional source selection, counter displays and remaining
   graph modes. Process controls and live details are now present on both platforms;
   account for their different permissions, CPU meanings and user filters.
   Retain the existing integrated Mac fan/VRAM readings.
2. AI accounting: define timestamp-based history retention and align remaining format-specific
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
4. Desktop behavior: align other supported window controls and preserve explicit
   compositor limitations. Linux now supports collapse/hover expansion. Define
   timestamp-based retention windows where appropriate;
   align remaining scheduling behavior without equating different OS memory or NPU measurements.

Each pass needs UI, persistence, cancellation, invalid/unavailable-data and fixture
coverage on both platforms. Compare metric meaning and supported interactions,
not just the number of panels. Physical hardware validation remains best effort;
missing hardware is not a prerequisite for finishing these passes.
