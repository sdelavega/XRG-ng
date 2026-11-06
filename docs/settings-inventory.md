# XRG-ng settings inventory

Every preference XRG-ng 0.2.2 can read or write, and where each one goes in the
0.2.3 unified settings catalog. This file is the Phase 2 inventory the spec
calls for: each row is either mapped to a catalog entry or deliberately kept
out with a reason.

How to read the tables:

- Columns are `| key | type | default | where it lives today | catalog entry |`.
- Mapped rows end in one or more `backticked` catalog ids.
- Excluded rows end in `excluded: <reason>`, not in backticks; their keys may
  be patterns.
- `Shared/Tests/SettingsCatalogTests.swift` parses these tables: every mapped
  key must appear as some catalog entry's `legacy.macos` or `legacy.linux`
  value, and every catalog legacy pointer must have a row here. Keep the doc
  and the catalog in step when either changes.

Conventions:

- A catalog default of `null` means "not set": the platform inherits. It is
  valid for any control.
- Whole JSON numbers decode as the catalog's `int`, so a whole decimal such
  as an opacity of 1.0 is read back as an integer with the same value; later
  tasks compare numbers by value, not by case.
- Linux pointers are JSON pointers (RFC 6901) into the version-40
  `settings.conf` as the Rust serde model writes it, taking field names from
  the serde attributes (`rename_all = "snake_case"` and friends).
- `/modules/<i>/...` rows use the module's index in `Settings::default_order()`
  in `xrg-linux/rust/src/settings.rs` (cpu 0, gpu 1, tpu 2, memory 3, battery 4,
  temperature 5, network 6, disk 7, ai 8, processes 9, gpu_memory 10, fans 11,
  weather 12). The saved array is the user's display order, so migration must
  locate the module by its `id` wherever it sits.
- Stocks entries are catalogued for both platforms (decision D8); Linux has no
  version-40 stock fields yet, so their `legacy.linux` pointers are null.
- The `temperature` source kind carries the sensor grouping from the macOS 26
  sensor work (Identified, Unidentified, Suspected unused); the grouping is
  the platform's job at runtime, never catalog data.

## macOS transforms

Transforms named by `legacy.macosTransform` convert a raw defaults value into
the catalog value. Task 4 implements them; this task only names them.

| Transform | Converts |
|---|---|
| `cpuMonitorSource` | decodes the XRGMonitorSource JSON blob at XRGCPUView.Source.v1 into the selected logical CPU index as a number, or null for the aggregate. |
| `gpuMonitorSource` | decodes the XRGMonitorSource JSON blob at XRGGPUView.Source.v1 into the selected GPU identity string, or null for automatic. |
| `hardwareSourceSlot` | decodes the XRGHardwareSources JSON blob (vramGraphSourcesV1 or fanGraphSourcesV1) into the source id of the curve slot named by the entry, or null when selection is automatic or the slot is empty. |
| `graphPreferenceHeight` | decodes the XRGGraphPreferences blob at graphPresentationV1 into the height override of the graph named by the entry, or null when it inherits. |
| `graphPreferenceCurve` | decodes the graphPresentationV1 blob into the curve style (solid/pixel/dot/hollow) of the graph named by the entry, or null when it inherits. |
| `graphPreferenceEffect` | decodes the graphPresentationV1 blob into the display effect of the graph named by the entry, or null when it inherits the global effect. |
| `graphPreferenceColor` | decodes the graphPresentationV1 blob into one RGBA color override (background or series 1-3) of the graph named by the entry, or null when it inherits the palette. |
| `nsColorArchive` | decodes the keyed NSColor archive stored at the color key into sRGB RGBA components between 0 and 1. |
| `fontArchive` | decodes the keyed NSFont archive stored at graphFont into a 'Name Size' descriptor string; the system font serialises as 'System <size>'. |
| `orientationFlag` | converts the YES/NO graphOrientationVertical flag into the orientation value vertical or horizontal. |
| `windowLevelIndex` | converts the window level index (0 normal, 1 floating, 2 background) into its value name. |
| `collapseAnchorIndex` | converts the minimize direction index (0 top/left, 1 bottom/right) into the anchor value start or end. |
| `fahrenheitCelsiusIndex` | converts a temperature units index (0 Fahrenheit, 1 Celsius) into its value name. |
| `milesKilometersIndex` | converts a distance units index (0 miles, 1 kilometers) into its value name. |
| `inchesHectopascalsIndex` | converts a pressure units index (0 inches, 1 hectopascals) into its value name. |
| `secondaryIndex` | converts the secondary weather graph index (0 none, 1 wind, 2 humidity, 3 visibility, 4 dewpoint, 5 pressure) into its value name. |
| `stockTimeframeIndex` | converts the stock chart index (0, 1, 2, 3) into its month count 1, 3, 6 or 12. |
| `gpuPlotMode` | converts the saved GPU plot mode raw value (memoryAndActivity, utilization) into the value name. |
| `zeroToNull` | converts the macOS value 0, meaning the session or legacy behaviour, into null. |
| `networkInterfaceAll` | maps the All sentinel, meaning every active interface, to null; other interface names pass through. |
| `temperatureSensorSlot` | passes a saved temperature sensor key through; the legacy placeholders 0/1/2, meaning the first three auto-selected sensors, resolve to the keys the platform auto-configures. |
| `themePreset` | maps the saved theme name to the matching built-in theme, or custom when the name is not a built-in. |

## Linux transforms

| Transform | Converts |
|---|---|
| `themeChoice` | converts the ThemeChoice at /theme into the built-in theme's name, or custom for a custom theme document. |
| `themeName` | converts the ThemeChoice at /theme into its display name, the built-in's name or the custom document's name. |
| `themeColor` | converts the ThemeChoice at /theme into the RGBA palette entry (window, graph background, series 1-3, border, text) named by the entry. |
| `millisecondsToSeconds` | converts the Linux sampling target in milliseconds into seconds. |
| `unitsToTemperature` | converts the weather units value metric/us, or null, into celsius/fahrenheit, or null. |
| `unitsToDistance` | converts the weather units value metric/us, or null, into kilometers/miles, or null. |
| `unitsToPressure` | converts the weather units value metric/us, or null, into hectopascals/inches, or null. |

## macOS defaults keys

| Key | Type | Default | Where it lives today | Catalog entry |
|---|---|---|---|---|
| `windowTitle` | string | empty | General pane, Custom Window Title | `general.window.title` |
| `borderWidth` | int | 4 | General pane, Window Border Width slider (1-16) | `general.window.border_width` |
| `graphOrientationVertical` | bool | YES | General pane, Graph Window Orientation | `general.window.orientation` |
| `windowLevel` | int | 0 | General pane, Window Level | `general.window.level` |
| `stickyWindow` | bool | YES | General pane, Sticky Window | `general.window.sticky_edges` |
| `checkForUpdates` | bool | YES | General pane, Check for updates when starting | `general.updates.check_on_launch` |
| `dropShadow` | bool | NO | General pane, Display a drop shadow | `general.window.drop_shadow` |
| `autoExpandGraph` | bool | YES | General pane, Automatically Expand the Graph Window | `general.window.expand_on_hover` |
| `foregroundWhenExpanding` | bool | NO | General pane, Bring Graph Window to the Foreground when Expanding | `general.window.bring_to_front_on_expand` |
| `showSummary` | bool | YES | General pane, Show Summary Statistics when minimized | `general.window.show_summary` |
| `minimizeUpDown` | int | 0 | General pane, Minimize the Graph Window into | `general.window.collapse_anchor` |
| `isDockIconHidden` | bool | NO | Graph window Hide UI action | `general.window.hide_dock_icon` |
| `antiAliasing` | bool | YES | General pane, Enable Anti-Aliasing | `appearance.antialiasing` |
| `graphRefresh` | double | 1.0 | General pane, Graph Refresh slider (0.2-10 s) | `graphs.refresh` |
| `showCPUGraph` | bool | YES | General pane, graph checkbox | `graphs.cpu.visible` |
| `showGPUGraph` | bool | YES | General pane, graph checkbox | `graphs.gpu.visible` |
| `showNPUGraph` | bool | Apple silicon: YES | General pane, graph checkbox | `graphs.npu.visible` |
| `showVRAMGraph` | bool | NO | General pane, graph checkbox | `graphs.vram.visible` |
| `showMemoryGraph` | bool | YES | General pane, graph checkbox | `graphs.memory.visible` |
| `showBatteryGraph` | bool | YES | General pane, graph checkbox | `graphs.battery.visible` |
| `showTemperatureGraph` | bool | YES | General pane, graph checkbox | `graphs.temperature.visible` |
| `showNetworkGraph` | bool | YES | General pane, graph checkbox | `graphs.network.visible` |
| `showDiskGraph` | bool | YES | General pane, graph checkbox | `graphs.disk.visible` |
| `showWeatherGraph` | bool | YES | General pane, graph checkbox | `graphs.weather.visible` |
| `showStockGraph` | bool | YES | General pane, graph checkbox | `graphs.stock.visible` |
| `showAITokenGraph` | bool | YES | General pane, AI Tokens checkbox | `graphs.ai.visible` |
| `showFansGraph` | bool | NO | General pane, graph checkbox | `graphs.fans.visible` |
| `showCPUBars` | bool | YES | CPU pane, Show CPU Bars | `graphs.cpu.fast_bars` |
| `separateCPUColor` | bool | YES | CPU pane, Separate Coloring for User/System/Nice | `graphs.cpu.separate_colors` |
| `showCPUTemperature` | bool | NO | CPU pane, Show CPU Temperature | `graphs.cpu.show_temperature` |
| `cpuTemperatureUnits` | int | locale: 0 or 1 | CPU pane, temperature units | `graphs.cpu.temperature_units` |
| `showLoadAverage` | bool | YES | CPU pane, Show Load Average | `graphs.cpu.show_load_average` |
| `cpuShowAverageUsage` | bool | YES | CPU pane, Show Average % Usage | `graphs.cpu.show_average` |
| `cpuShowUptime` | bool | YES | CPU pane, Show System Uptime | `graphs.cpu.show_uptime` |
| `showMemoryPagingGraph` | bool | YES | Memory pane, Show Paging Graph | `graphs.memory.show_paging_graph` |
| `memoryShowWired` | bool | YES | Memory pane, Show Wired Memory | `graphs.memory.show_wired` |
| `memoryShowActive` | bool | YES | Memory pane, Show Active Memory | `graphs.memory.show_active` |
| `memoryShowInactive` | bool | YES | Memory pane, Show Inactive Memory | `graphs.memory.show_inactive` |
| `memoryShowFree` | bool | YES | Memory pane, Show Free Memory | `graphs.memory.show_free` |
| `memoryShowCache` | bool | YES | Memory pane, Show Cache Hit Rate | `graphs.memory.show_cache` |
| `memoryShowPage` | bool | YES | Memory pane, Show Page Faults | `graphs.memory.show_page` |
| `tempUnits` | int | locale: 0 or 1 | Temperature pane, temperature units | `graphs.temperature.units` |
| `tempShowUnknownSensors` | bool | NO | Temperature pane, Show Unknown Sensors (nib value binding) | `sources.temperature.show_unknown` |
| `tempFG1Location` | string | 0 | Temperature pane, Sensor Location for Graph 1 | `sources.temperature.sensor1` |
| `tempFG2Location` | string | 1 | Temperature pane, Sensor Location for Graph 2 | `sources.temperature.sensor2` |
| `tempFG3Location` | string | 2 | Temperature pane, Sensor Location for Graph 3 | `sources.temperature.sensor3` |
| `netGraphMode` | int | 0 | Network pane, display mode radio matrix | `graphs.network.display_mode` |
| `netMinGraphScale` | int | 1024 | Network pane, Minimum Graph Vertical Scale | `graphs.network.minimum_scale` |
| `showTotalBandwidthSinceBoot` | bool | YES | Network pane, Show Total Bandwidth used since boot time | `graphs.network.show_total_since_boot` |
| `showTotalBandwidthSinceLoad` | bool | YES | Network pane, Show Total Bandwidth used since launch | `graphs.network.show_total_since_load` |
| `networkInterface` | string | All | Network pane, Network Interface to Monitor | `sources.network.interface` |
| `diskGraphMode` | int | 0 | Disk pane, display mode radio matrix | `graphs.disk.display_mode` |
| `icao` | string | KMOP | Weather pane, Station ICAO Code | `weather.station` |
| `secondaryWeatherGraph` | int | 1 | Weather pane, Secondary Graph | `weather.secondary` |
| `weatherHistoryHours` | int | 0 | Weather pane, History window menu | `weather.history_hours` |
| `temperatureUnits` | int | locale: 0 or 1 | Weather pane, Temperature Units | `weather.units.temperature` |
| `distanceUnits` | int | locale: 0 or 1 | Weather pane, Distance | `weather.units.distance` |
| `pressureUnits` | int | locale: 0 or 1 | Weather pane, Pressure | `weather.units.pressure` |
| `stockSymbols` | string | AAPL | Stock pane, Stock Symbols | `stocks.symbols` |
| `stockGraphTimeFrame` | int | 3 | Stock pane, Graph Time Frame | `stocks.timeframe` |
| `stockShowChange` | bool | YES | Stock pane, Show last day change | `stocks.show_change` |
| `showDJIA` | bool | YES | Stock pane, Show DJIA as a secondary graph | `stocks.show_djia` |
| `backgroundColor` | data | Classic window color archive | Color pane, Background color well | `appearance.window.color` |
| `backgroundTransparency` | double | 0.9 | Color pane, Background transparency slider | `appearance.window.transparency` |
| `graphBGColor` | data | Classic graph background archive | Color pane, Graph Background color well | `appearance.graph_background.color` |
| `graphBGTransparency` | double | 0.9 | Color pane, Graph Background transparency slider | `appearance.graph_background.transparency` |
| `graphFG1Color` | data | Classic series 1 archive | Color pane, Graph Foreground 1 color well | `appearance.series1.color` |
| `graphFG1Transparency` | double | 1.0 | Color pane, Graph Foreground 1 transparency slider | `appearance.series1.transparency` |
| `graphFG2Color` | data | Classic series 2 archive | Color pane, Graph Foreground 2 color well | `appearance.series2.color` |
| `graphFG2Transparency` | double | 1.0 | Color pane, Graph Foreground 2 transparency slider | `appearance.series2.transparency` |
| `graphFG3Color` | data | Classic series 3 archive | Color pane, Graph Foreground 3 color well | `appearance.series3.color` |
| `graphFG3Transparency` | double | 1.0 | Color pane, Graph Foreground 3 transparency slider | `appearance.series3.transparency` |
| `borderColor` | data | Classic border archive | Color pane, Border color well | `appearance.border.color` |
| `borderTransparency` | double | 0.4 | Color pane, Border transparency slider | `appearance.border.transparency` |
| `textColor` | data | Classic text archive | Color pane, Graph Text color well | `appearance.text.color` |
| `textTransparency` | double | 1.0 | Color pane, Graph Text transparency slider | `appearance.text.transparency` |
| `graphFont` | data | System font 10 pt archive | Color pane, Select Font | `appearance.font` |
| `graphStyle` | int | 0 | Color pane, Display Effect | `appearance.display_effect` |
| `portableThemeName` | string | last applied theme name | Color pane, Color Theme picker | `themes.preset` and `themes.name` |
| `aiTokensTrackingEnabled` | bool | false | AI pane, Enable AI Token Tracking | `ai.tracking.enabled` |
| `aiTokensDailyAutoReset` | bool | true | AI pane, Auto-reset daily counters at midnight | `ai.tracking.auto_reset` |
| `aiTokensDailyBudget` | int | 0 | AI pane, Daily token budget | `ai.tracking.daily_budget` |
| `aiTokensBudgetNotifyPercent` | int | 80 | AI pane, Budget notification threshold | `ai.tracking.notify_percent` |
| `aiTokensAggregateByModel` | bool | true | AI pane, Track usage by AI model | `ai.tracking.by_model` |
| `aiTokensAggregateByProvider` | bool | false | AI pane, Track usage by AI provider | `ai.tracking.by_provider` |
| `aiTokensShowRate` | bool | true | AI pane, Show token rate | `ai.display.rate` |
| `aiTokensShowBreakdown` | bool | true | AI pane, Show detailed breakdown | `ai.display.breakdown` |
| `graphPresentationV1` | data | XRGGraphPreferences blob | Window menu, Graph Options editor | `graphs.*.height`, `graphs.*.style`, `graphs.*.effect` and `graphs.*.color.*` via the graphPreference* transforms |
| `XRGCPUView.Source.v1` | data | XRGMonitorSource blob | CPU pane Device to monitor and CPU graph context menu | `sources.cpu.core` |
| `XRGGPUView.Source.v1` | data | XRGMonitorSource blob | GPU graph context menu, GPU sources | `sources.gpu.device` |
| `XRGGPUView.PlotMode.v1` | string | memoryAndActivity | GPU graph context menu, plot mode | `graphs.gpu.plot_mode` |
| `vramGraphSourcesV1` | data | XRGHardwareSources blob | VRAM graph context menu, Choose Sources | `sources.vram.slot1`, `sources.vram.slot2`, `sources.vram.slot3` |
| `fanGraphSourcesV1` | data | XRGHardwareSources blob | Fans graph context menu, Choose Sources | `sources.fans.sensor1`, `sources.fans.sensor2`, `sources.fans.sensor3` |
| `XRGCPUView.HistorySamples.v1` | int | 0 | CPU graph context menu, CPU History | `graphs.cpu.samples` |
| `XRGCPUView.HistoryMinutes.v1` | int | 0 | CPU graph context menu, CPU Time Window | `graphs.cpu.time_window` |
| `XRGGPUView.HistorySamples.v1` | int | 0 | GPU graph context menu, GPU History | `graphs.gpu.samples` |
| `XRGGPUView.HistoryMinutes.v1` | int | 0 | GPU graph context menu, GPU Time Window | `graphs.gpu.time_window` |
| `XRGNPUView.HistorySamples.v1` | int | 0 | Neural engine graph context menu, NPU History | `graphs.npu.samples` |
| `XRGNPUView.HistoryMinutes.v1` | int | 0 | Neural engine graph context menu, NPU Time Window | `graphs.npu.time_window` |
| `XRGHardwareGraphView.VRAM.HistorySamples.v1` | int | 0 | VRAM graph context menu, VRAM History | `graphs.vram.samples` |
| `XRGHardwareGraphView.VRAM.HistoryMinutes.v1` | int | 0 | VRAM graph context menu, VRAM Time Window | `graphs.vram.time_window` |
| `XRGMemoryView.HistorySamples.v1` | int | 0 | Memory graph context menu, Memory History | `graphs.memory.samples` |
| `XRGMemoryView.HistoryMinutes.v1` | int | 0 | Memory graph context menu, Memory Time Window | `graphs.memory.time_window` |
| `XRGBatteryView.HistorySamples.v1` | int | 0 | Battery graph context menu, Battery History | `graphs.battery.samples` |
| `XRGBatteryView.HistoryMinutes.v1` | int | 0 | Battery graph context menu, Battery Time Window | `graphs.battery.time_window` |
| `XRGTemperatureView.HistorySamples.v1` | int | 0 | Temperature graph context menu, Temperature History | `graphs.temperature.samples` |
| `XRGTemperatureView.HistoryMinutes.v1` | int | 0 | Temperature graph context menu, Temperature Time Window | `graphs.temperature.time_window` |
| `XRGNetView.HistorySamples.v1` | int | 0 | Network graph context menu, Network History | `graphs.network.samples` |
| `XRGNetView.HistoryMinutes.v1` | int | 0 | Network graph context menu, Network Time Window | `graphs.network.time_window` |
| `XRGDiskView.HistorySamples.v1` | int | 0 | Disk graph context menu, Disk History | `graphs.disk.samples` |
| `XRGDiskView.HistoryMinutes.v1` | int | 0 | Disk graph context menu, Disk Time Window | `graphs.disk.time_window` |
| `XRGAITokenView.HistorySamples.v1` | int | 0 | AI tokens graph context menu, AI History | `graphs.ai.samples` |
| `XRGAITokenView.HistoryMinutes.v1` | int | 0 | AI tokens graph context menu, AI Time Window | `graphs.ai.time_window` |
| `XRGHardwareGraphView.Fans.HistorySamples.v1` | int | 0 | Fans graph context menu, Fans History | `graphs.fans.samples` |
| `XRGHardwareGraphView.Fans.HistoryMinutes.v1` | int | 0 | Fans graph context menu, Fans Time Window | `graphs.fans.time_window` |
| `windowWidth, windowHeight, windowOriginX, windowOriginY` | mixed | screen-relative | Registered defaults for the window frame | excluded: window geometry, an AppKit window frame (spec Non-goals); it stays platform-local. |
| `unminimizedFrame` | string | NSRect string | Written by the graph window when it collapses | excluded: window geometry/state (spec Non-goals). |
| `windowIsMinimized` | bool | false | Written by the graph window when it collapses | excluded: window collapsed state, not a setting (spec Non-goals). |
| `XRGModule_<name>_width, XRGModule_<name>_height` | double | per module | Saved by XRGModule when a graph is resized | excluded: window layout (spec Non-goals); the Graphs height entries carry explicit per-graph heights. |
| `showSensorWindow` | bool | false | Sensors window open-at-launch state | excluded: window open state, not a setting (spec Non-goals). |
| `tempLocationsAutoconfigured` | bool | unset | One-time latch written by temperature sensor auto-configuration | excluded: internal auto-configuration latch; the sensor entries are the settings. |
| `portableThemeDocument` | data | unset | Written when a theme is applied or imported | excluded: portable theme document, the import/export artifact of the Themes section; the palette lives in the appearance color entries and the name in themes.name. |
| `processInspectorV1` | data | sort/search/user/limit blob | Processes inspector window | excluded: inspector window state (spec Non-goals: inspectors are out of scope). |
| `aiTokensDailyUnclassifiedTokens, aiTokensDailyPromptTokens, aiTokensDailyCompletionTokens` | number | 0 | Daily AI usage counters | excluded: observed usage data recorded by the app, not user settings. |
| `aiTokensDailyModelUnclassifiedTokens, aiTokensDailyModelPromptTokens, aiTokensDailyModelCompletionTokens` | dictionary | empty | Daily AI usage counters by model | excluded: observed usage data recorded by the app, not user settings. |
| `aiTokensDailyProviderUnclassifiedTokens, aiTokensDailyProviderPromptTokens, aiTokensDailyProviderCompletionTokens` | dictionary | empty | Daily AI usage counters by provider | excluded: observed usage data recorded by the app, not user settings. |
| `aiTokensDailyDate, aiTokensLastNotifyDate` | date | unset | Daily counter rollover and last notification dates | excluded: recorded data, not user settings. |
| `fastCPUUsage` | bool | false | Written only by the CollectorProfile profiling tool | excluded: never read by the app; the fast-bars defaults key is showCPUBars. |
| `packagedSmokeMarker` | string | unset | Packaged smoke test marker | excluded: test tooling marker, not an app setting. |
| `SU* (Sparkle keys: SUEnableAutomaticChecks, SUScheduledCheckInterval, ...)` | mixed | Sparkle's | Sparkle update framework | excluded: framework-owned updater state (spec Non-goals); Sparkle keeps managing it. |

## Linux version-40 fields

| Key | Type | Default | Where it lives today | Catalog entry |
|---|---|---|---|---|
| `/theme` | builtin or custom | Classic | Preferences, Theme picker | `themes.preset`, `themes.name` and the `appearance.*.color` entries via the theme* transforms |
| `/graph_height` | u32 | 90 | Preferences, Dashboard, Default graph height | `graphs.default_height` |
| `/graph_width` | u32 | 140 | Preferences, Dashboard, Graph width | `general.window.graph_width` |
| `/sampling_interval_ms` | u32 | 1000 | Preferences, Dashboard, System sampling target | `graphs.refresh` |
| `/window_opacity` | f64 | 1.0 | Preferences, Dashboard, Window opacity | `general.window.opacity` |
| `/window_collapse/expand_on_hover` | bool | false | Preferences, Dashboard, Hover expansion | `general.window.expand_on_hover` |
| `/window_collapse/anchor` | start or end | start | Preferences, Dashboard, Collapse anchor | `general.window.collapse_anchor` |
| `/network_min_scale` | u64 | 0 | Preferences, Dashboard, Network minimum scale | `graphs.network.minimum_scale` |
| `/layout` | vertical or horizontal | vertical | Preferences, Dashboard, Layout | `general.window.orientation` |
| `/temperature_units` | celsius or fahrenheit | celsius | Preferences, Dashboard, Temperature | `graphs.temperature.units` |
| `/activity_bars/visible` | bool | true | Preferences, Current-value bars | `graphs.activity_bars.visible` |
| `/activity_bars/style` | solid, pixel, dot or hollow | solid | Preferences, Current-value bars, style | `graphs.activity_bars.style` |
| `/activity_bars/use_series_colors` | bool | true | Preferences, Current-value bars, Use graph series colors | `graphs.activity_bars.use_series_colors` |
| `/activity_bars/color` | [f64; 4] | [0.2, 1, 0.3, 1] | Preferences, Current-value bars, Bar color | `graphs.activity_bars.color` |
| `/metrics/battery_mode` | charge or power | charge | Preferences, Graphs, Battery history | `graphs.battery.mode` |
| `/metrics/cpu` | u32 or null | null | Preferences, Metric sources, CPU | `sources.cpu.core` |
| `/metrics/cpu_history_samples` | u32 | 0 | Preferences, Metric sources, Retained CPU samples | `graphs.cpu.samples` |
| `/metrics/cpu_history_minutes` | u32 | 0 | Preferences, Metric sources, CPU time window | `graphs.cpu.time_window` |
| `/metrics/history_samples/memory` | u32 | absent | Preferences, Metric sources, Retained Memory samples | `graphs.memory.samples` |
| `/metrics/history_samples/network` | u32 | absent | Preferences, Metric sources, Retained Network samples | `graphs.network.samples` |
| `/metrics/history_samples/disk` | u32 | absent | Preferences, Metric sources, Retained Disk samples | `graphs.disk.samples` |
| `/metrics/history_samples/gpu` | u32 | absent | Preferences, Metric sources, Retained GPU samples | `graphs.gpu.samples` |
| `/metrics/history_samples/tpu` | u32 | absent | Preferences, Metric sources, Retained NPU samples | `graphs.npu.samples` |
| `/metrics/history_samples/gpu_memory` | u32 | absent | Preferences, Metric sources, Retained VRAM samples | `graphs.vram.samples` |
| `/metrics/history_samples/temperature` | u32 | absent | Preferences, Metric sources, Retained Temperature samples | `graphs.temperature.samples` |
| `/metrics/history_samples/fans` | u32 | absent | Preferences, Metric sources, Retained Fans samples | `graphs.fans.samples` |
| `/metrics/history_samples/battery` | u32 | absent | Preferences, Metric sources, Retained Battery samples | `graphs.battery.samples` |
| `/metrics/history_minutes/memory` | u32 | absent | Preferences, Metric sources, Memory time window | `graphs.memory.time_window` |
| `/metrics/history_minutes/network` | u32 | absent | Preferences, Metric sources, Network time window | `graphs.network.time_window` |
| `/metrics/history_minutes/disk` | u32 | absent | Preferences, Metric sources, Disk time window | `graphs.disk.time_window` |
| `/metrics/history_minutes/gpu` | u32 | absent | Preferences, Metric sources, GPU time window | `graphs.gpu.time_window` |
| `/metrics/history_minutes/tpu` | u32 | absent | Preferences, Metric sources, NPU time window | `graphs.npu.time_window` |
| `/metrics/history_minutes/gpu_memory` | u32 | absent | Preferences, Metric sources, VRAM time window | `graphs.vram.time_window` |
| `/metrics/history_minutes/temperature` | u32 | absent | Preferences, Metric sources, Temperature time window | `graphs.temperature.time_window` |
| `/metrics/history_minutes/fans` | u32 | absent | Preferences, Metric sources, Fans time window | `graphs.fans.time_window` |
| `/metrics/history_minutes/battery` | u32 | absent | Preferences, Metric sources, Battery time window | `graphs.battery.time_window` |
| `/metrics/network` | string or null | null | Preferences, Metric sources, Network | `sources.network.interface` |
| `/metrics/disk` | string or null | null | Preferences, Metric sources, Disk | `sources.disk.device` |
| `/metrics/gpu` | string or null | null | Preferences, Metric sources, GPU / VRAM | `sources.gpu.device` and `sources.vram.slot1` |
| `/metrics/xe_pmu` | bool | false | Preferences, Metric sources, Intel Xe PMU power policy | `sources.gpu.xe_pmu` |
| `/metrics/temperature` | string or null | null | Preferences, Metric sources, Temperature | `sources.temperature.sensor1` |
| `/metrics/temperature_extra/0` | string or null | null | Preferences, Metric sources, Temperature curve 2 | `sources.temperature.sensor2` |
| `/metrics/temperature_extra/1` | string or null | null | Preferences, Metric sources, Temperature curve 3 | `sources.temperature.sensor3` |
| `/metrics/fan` | string or null | null | Preferences, Metric sources, Fan | `sources.fans.sensor1` |
| `/metrics/fan_extra/0` | string or null | null | Preferences, Metric sources, Fan curve 2 | `sources.fans.sensor2` |
| `/metrics/fan_extra/1` | string or null | null | Preferences, Metric sources, Fan curve 3 | `sources.fans.sensor3` |
| `/ai/accounting/enabled` | bool | false | Preferences, AI monitoring, Track observed session/daily usage | `ai.tracking.enabled` |
| `/ai/accounting/auto_reset` | bool | true | Preferences, AI monitoring, Reset daily counters at local midnight | `ai.tracking.auto_reset` |
| `/ai/accounting/daily_budget` | u64 | 0 | Preferences, AI monitoring, Daily token budget | `ai.tracking.daily_budget` |
| `/ai/accounting/notify_percent` | u8 | 80 | Preferences, AI monitoring, Budget alert threshold | `ai.tracking.notify_percent` |
| `/ai/accounting/notifications` | bool | false | Preferences, AI monitoring, Send desktop budget alerts | `ai.tracking.notifications` |
| `/ai/accounting/by_model` | bool | true | Preferences, AI monitoring, Aggregate daily usage by model | `ai.tracking.by_model` |
| `/ai/accounting/by_provider` | bool | false | Preferences, AI monitoring, Aggregate daily usage by provider | `ai.tracking.by_provider` |
| `/ai/history_samples` | u32 | 0 | Preferences, AI monitoring, Retained AI samples | `graphs.ai.samples` |
| `/ai/history_minutes` | u32 | 0 | Preferences, AI monitoring, AI time window | `graphs.ai.time_window` |
| `/ai/enabled/0` | bool | true | Preferences, AI monitoring, Claude | `ai.sources.claude` |
| `/ai/enabled/1` | bool | true | Preferences, AI monitoring, Codex | `ai.sources.codex` |
| `/ai/enabled/2` | bool | true | Preferences, AI monitoring, Gemini | `ai.sources.gemini` |
| `/ai/enabled/3` | bool | true | Preferences, AI monitoring, Hermes | `ai.sources.hermes` |
| `/ai/ollama` | bool | true | Preferences, AI monitoring, Read local Ollama model inventory | `ai.sources.ollama` |
| `/ai/claude_source` | auto, logs, database or metrics | auto | Preferences, AI monitoring, Claude source | `ai.claude.source` |
| `/ai/claude_logs` | path or null | null | Preferences, AI monitoring, Claude logs | `ai.claude.logs_path` |
| `/ai/claude_database` | path or null | null | Preferences, AI monitoring, Claude database | `ai.claude.database_path` |
| `/ai/codex_logs` | path or null | null | Preferences, AI monitoring, Codex logs | `ai.codex.logs_path` |
| `/ai/gemini_logs` | path or null | null | Preferences, AI monitoring, Gemini logs | `ai.gemini.logs_path` |
| `/ai/hermes_database` | path or null | null | Preferences, AI monitoring, Hermes database | `ai.hermes.database_path` |
| `/ai/metrics_url` | string | http://127.0.0.1:8889/metrics | Preferences, AI monitoring, Metrics URL | `ai.metrics.url` |
| `/ai/ollama_url` | string | http://127.0.0.1:11434 | Preferences, AI monitoring, Ollama URL | `ai.ollama.url` |
| `/ai_show_model_breakdown` | bool | true | Preferences, AI monitoring, Show model breakdown | `ai.display.breakdown` |
| `/weather/enabled` | bool | false | Preferences, Weather observations, Enable station weather | `weather.enabled` |
| `/weather/station` | string | empty | Preferences, Weather observations, ICAO station | `weather.station` |
| `/weather/refresh_minutes` | u32 | 15 | Preferences, Weather observations, Refresh | `weather.refresh` |
| `/weather/units` | metric or us | metric | Preferences, Weather observations, Default unit system | `weather.units.system` |
| `/weather/temperature_units` | metric, us or null | null | Preferences, Weather observations, Temperature | `weather.units.temperature` |
| `/weather/distance_units` | metric, us or null | null | Preferences, Weather observations, Visibility | `weather.units.distance` |
| `/weather/pressure_units` | metric, us or null | null | Preferences, Weather observations, Pressure | `weather.units.pressure` |
| `/weather/wind_units` | knots, kmh, mph or null | null | Preferences, Weather observations, Wind / gusts | `weather.units.wind` |
| `/weather/history_hours` | u32 or null | null | Preferences, Weather observations, History window | `weather.history_hours` |
| `/weather/secondary` | none, wind, humidity, visibility, dewpoint or pressure | none | Preferences, Weather observations, Secondary curve | `weather.secondary` |
| `/version` | u32 | 40 | settings.conf header | excluded: file format version, migrated structurally, not a setting. |
| `/modules (the array order)` | array | default order | Preferences, Graphs (up and down buttons) | excluded: graph display order is structural; it is migrated as the document's own graph order, not a typed control. |
| `/modules/<i>/id` | module id | varies | Identity of each element of the modules array | excluded: module identity inside the user-reorderable array; see the index convention above. |
| `/window_size (with /width and /height)` | object | null | Preferences, Dashboard, Remember window size | excluded: window geometry, the Linux counterpart of an AppKit window frame (spec Non-goals). |
| `/window_collapse/collapsed` | bool | false | Preferences, Dashboard, Collapsed window | excluded: manual collapsed latch, window state, not a setting (spec Non-goals). |
| `/theme/custom/theme/format` | string | xrg-ng-theme | Custom theme document inside /theme | excluded: part of the portable theme document; see /theme. |
| `/theme/custom/theme/version` | u32 | 1 | Custom theme document inside /theme | excluded: part of the portable theme document; see /theme. |
| `/theme/custom/theme/name` | string | 1-80 chars | Custom theme document inside /theme | excluded: part of the portable theme document; read through the /theme pointer by themes.name. |
| `/theme/custom/theme/colors` | [[f64; 4]; 7] | varies | Custom theme document inside /theme | excluded: part of the portable theme document; read through the /theme pointer by the appearance color entries. |
| `/processes/sort` | cpu, memory, pid or name | cpu | Processes window | excluded: inspector window state (spec Non-goals: inspectors are out of scope). |
| `/processes/uid` | u32 or null | null | Processes window | excluded: inspector window state (spec Non-goals: inspectors are out of scope). |
| `/processes/filter` | string | empty | Processes window | excluded: inspector window state (spec Non-goals: inspectors are out of scope). |
| `/processes/limit` | u32 | 50 | Processes window | excluded: inspector window state (spec Non-goals: inspectors are out of scope). |
| `/modules/0/visible` | varies | see module | Preferences, Graphs (CPU graph) | `graphs.cpu.visible` |
| `/modules/0/style` | varies | see module | Preferences, Graphs (CPU graph) | `graphs.cpu.style` |
| `/modules/0/height` | varies | see module | Preferences, Graphs (CPU graph) | `graphs.cpu.height` |
| `/modules/0/colors/background` | RGBA or null | null | Preferences, Graphs (CPU graph), Colors | `graphs.cpu.color.background` |
| `/modules/0/colors/series/0` | RGBA or null | null | Preferences, Graphs (CPU graph), Colors | `graphs.cpu.color.series1` |
| `/modules/0/colors/series/1` | RGBA or null | null | Preferences, Graphs (CPU graph), Colors | `graphs.cpu.color.series2` |
| `/modules/0/colors/series/2` | RGBA or null | null | Preferences, Graphs (CPU graph), Colors | `graphs.cpu.color.series3` |
| `/modules/1/visible` | varies | see module | Preferences, Graphs (GPU graph) | `graphs.gpu.visible` |
| `/modules/1/style` | varies | see module | Preferences, Graphs (GPU graph) | `graphs.gpu.style` |
| `/modules/1/height` | varies | see module | Preferences, Graphs (GPU graph) | `graphs.gpu.height` |
| `/modules/1/colors/background` | RGBA or null | null | Preferences, Graphs (GPU graph), Colors | `graphs.gpu.color.background` |
| `/modules/1/colors/series/0` | RGBA or null | null | Preferences, Graphs (GPU graph), Colors | `graphs.gpu.color.series1` |
| `/modules/1/colors/series/1` | RGBA or null | null | Preferences, Graphs (GPU graph), Colors | `graphs.gpu.color.series2` |
| `/modules/1/colors/series/2` | RGBA or null | null | Preferences, Graphs (GPU graph), Colors | `graphs.gpu.color.series3` |
| `/modules/2/visible` | varies | see module | Preferences, Graphs (Neural engine graph) | `graphs.npu.visible` |
| `/modules/2/style` | varies | see module | Preferences, Graphs (Neural engine graph) | `graphs.npu.style` |
| `/modules/2/height` | varies | see module | Preferences, Graphs (Neural engine graph) | `graphs.npu.height` |
| `/modules/2/colors/background` | RGBA or null | null | Preferences, Graphs (Neural engine graph), Colors | `graphs.npu.color.background` |
| `/modules/2/colors/series/0` | RGBA or null | null | Preferences, Graphs (Neural engine graph), Colors | `graphs.npu.color.series1` |
| `/modules/2/colors/series/1` | RGBA or null | null | Preferences, Graphs (Neural engine graph), Colors | `graphs.npu.color.series2` |
| `/modules/2/colors/series/2` | RGBA or null | null | Preferences, Graphs (Neural engine graph), Colors | `graphs.npu.color.series3` |
| `/modules/10/visible` | varies | see module | Preferences, Graphs (VRAM graph) | `graphs.vram.visible` |
| `/modules/10/style` | varies | see module | Preferences, Graphs (VRAM graph) | `graphs.vram.style` |
| `/modules/10/height` | varies | see module | Preferences, Graphs (VRAM graph) | `graphs.vram.height` |
| `/modules/10/colors/background` | RGBA or null | null | Preferences, Graphs (VRAM graph), Colors | `graphs.vram.color.background` |
| `/modules/10/colors/series/0` | RGBA or null | null | Preferences, Graphs (VRAM graph), Colors | `graphs.vram.color.series1` |
| `/modules/10/colors/series/1` | RGBA or null | null | Preferences, Graphs (VRAM graph), Colors | `graphs.vram.color.series2` |
| `/modules/10/colors/series/2` | RGBA or null | null | Preferences, Graphs (VRAM graph), Colors | `graphs.vram.color.series3` |
| `/modules/3/visible` | varies | see module | Preferences, Graphs (Memory graph) | `graphs.memory.visible` |
| `/modules/3/style` | varies | see module | Preferences, Graphs (Memory graph) | `graphs.memory.style` |
| `/modules/3/height` | varies | see module | Preferences, Graphs (Memory graph) | `graphs.memory.height` |
| `/modules/3/colors/background` | RGBA or null | null | Preferences, Graphs (Memory graph), Colors | `graphs.memory.color.background` |
| `/modules/3/colors/series/0` | RGBA or null | null | Preferences, Graphs (Memory graph), Colors | `graphs.memory.color.series1` |
| `/modules/3/colors/series/1` | RGBA or null | null | Preferences, Graphs (Memory graph), Colors | `graphs.memory.color.series2` |
| `/modules/3/colors/series/2` | RGBA or null | null | Preferences, Graphs (Memory graph), Colors | `graphs.memory.color.series3` |
| `/modules/4/visible` | varies | see module | Preferences, Graphs (Battery graph) | `graphs.battery.visible` |
| `/modules/4/style` | varies | see module | Preferences, Graphs (Battery graph) | `graphs.battery.style` |
| `/modules/4/height` | varies | see module | Preferences, Graphs (Battery graph) | `graphs.battery.height` |
| `/modules/4/colors/background` | RGBA or null | null | Preferences, Graphs (Battery graph), Colors | `graphs.battery.color.background` |
| `/modules/4/colors/series/0` | RGBA or null | null | Preferences, Graphs (Battery graph), Colors | `graphs.battery.color.series1` |
| `/modules/4/colors/series/1` | RGBA or null | null | Preferences, Graphs (Battery graph), Colors | `graphs.battery.color.series2` |
| `/modules/4/colors/series/2` | RGBA or null | null | Preferences, Graphs (Battery graph), Colors | `graphs.battery.color.series3` |
| `/modules/5/visible` | varies | see module | Preferences, Graphs (Temperature graph) | `graphs.temperature.visible` |
| `/modules/5/style` | varies | see module | Preferences, Graphs (Temperature graph) | `graphs.temperature.style` |
| `/modules/5/height` | varies | see module | Preferences, Graphs (Temperature graph) | `graphs.temperature.height` |
| `/modules/5/colors/background` | RGBA or null | null | Preferences, Graphs (Temperature graph), Colors | `graphs.temperature.color.background` |
| `/modules/5/colors/series/0` | RGBA or null | null | Preferences, Graphs (Temperature graph), Colors | `graphs.temperature.color.series1` |
| `/modules/5/colors/series/1` | RGBA or null | null | Preferences, Graphs (Temperature graph), Colors | `graphs.temperature.color.series2` |
| `/modules/5/colors/series/2` | RGBA or null | null | Preferences, Graphs (Temperature graph), Colors | `graphs.temperature.color.series3` |
| `/modules/6/visible` | varies | see module | Preferences, Graphs (Network graph) | `graphs.network.visible` |
| `/modules/6/style` | varies | see module | Preferences, Graphs (Network graph) | `graphs.network.style` |
| `/modules/6/height` | varies | see module | Preferences, Graphs (Network graph) | `graphs.network.height` |
| `/modules/6/colors/background` | RGBA or null | null | Preferences, Graphs (Network graph), Colors | `graphs.network.color.background` |
| `/modules/6/colors/series/0` | RGBA or null | null | Preferences, Graphs (Network graph), Colors | `graphs.network.color.series1` |
| `/modules/6/colors/series/1` | RGBA or null | null | Preferences, Graphs (Network graph), Colors | `graphs.network.color.series2` |
| `/modules/6/colors/series/2` | RGBA or null | null | Preferences, Graphs (Network graph), Colors | `graphs.network.color.series3` |
| `/modules/7/visible` | varies | see module | Preferences, Graphs (Disk graph) | `graphs.disk.visible` |
| `/modules/7/style` | varies | see module | Preferences, Graphs (Disk graph) | `graphs.disk.style` |
| `/modules/7/height` | varies | see module | Preferences, Graphs (Disk graph) | `graphs.disk.height` |
| `/modules/7/colors/background` | RGBA or null | null | Preferences, Graphs (Disk graph), Colors | `graphs.disk.color.background` |
| `/modules/7/colors/series/0` | RGBA or null | null | Preferences, Graphs (Disk graph), Colors | `graphs.disk.color.series1` |
| `/modules/7/colors/series/1` | RGBA or null | null | Preferences, Graphs (Disk graph), Colors | `graphs.disk.color.series2` |
| `/modules/7/colors/series/2` | RGBA or null | null | Preferences, Graphs (Disk graph), Colors | `graphs.disk.color.series3` |
| `/modules/8/visible` | varies | see module | Preferences, Graphs (AI tokens graph) | `graphs.ai.visible` |
| `/modules/8/style` | varies | see module | Preferences, Graphs (AI tokens graph) | `graphs.ai.style` |
| `/modules/8/height` | varies | see module | Preferences, Graphs (AI tokens graph) | `graphs.ai.height` |
| `/modules/8/colors/background` | RGBA or null | null | Preferences, Graphs (AI tokens graph), Colors | `graphs.ai.color.background` |
| `/modules/8/colors/series/0` | RGBA or null | null | Preferences, Graphs (AI tokens graph), Colors | `graphs.ai.color.series1` |
| `/modules/8/colors/series/1` | RGBA or null | null | Preferences, Graphs (AI tokens graph), Colors | `graphs.ai.color.series2` |
| `/modules/8/colors/series/2` | RGBA or null | null | Preferences, Graphs (AI tokens graph), Colors | `graphs.ai.color.series3` |
| `/modules/11/visible` | varies | see module | Preferences, Graphs (Fans graph) | `graphs.fans.visible` |
| `/modules/11/style` | varies | see module | Preferences, Graphs (Fans graph) | `graphs.fans.style` |
| `/modules/11/height` | varies | see module | Preferences, Graphs (Fans graph) | `graphs.fans.height` |
| `/modules/11/colors/background` | RGBA or null | null | Preferences, Graphs (Fans graph), Colors | `graphs.fans.color.background` |
| `/modules/11/colors/series/0` | RGBA or null | null | Preferences, Graphs (Fans graph), Colors | `graphs.fans.color.series1` |
| `/modules/11/colors/series/1` | RGBA or null | null | Preferences, Graphs (Fans graph), Colors | `graphs.fans.color.series2` |
| `/modules/11/colors/series/2` | RGBA or null | null | Preferences, Graphs (Fans graph), Colors | `graphs.fans.color.series3` |
| `/modules/12/visible` | varies | see module | Preferences, Graphs (Weather graph) | `graphs.weather.visible` |
| `/modules/12/style` | varies | see module | Preferences, Graphs (Weather graph) | `graphs.weather.style` |
| `/modules/12/height` | varies | see module | Preferences, Graphs (Weather graph) | `graphs.weather.height` |
| `/modules/12/colors/background` | RGBA or null | null | Preferences, Graphs (Weather graph), Colors | `graphs.weather.color.background` |
| `/modules/12/colors/series/0` | RGBA or null | null | Preferences, Graphs (Weather graph), Colors | `graphs.weather.color.series1` |
| `/modules/12/colors/series/1` | RGBA or null | null | Preferences, Graphs (Weather graph), Colors | `graphs.weather.color.series2` |
| `/modules/12/colors/series/2` | RGBA or null | null | Preferences, Graphs (Weather graph), Colors | `graphs.weather.color.series3` |
| `/modules/9/visible` | varies | see module | Preferences, Graphs (Processes graph) | `graphs.processes.visible` |
| `/modules/9/style` | varies | see module | Preferences, Graphs (Processes graph) | `graphs.processes.style` |
| `/modules/9/height` | varies | see module | Preferences, Graphs (Processes graph) | `graphs.processes.height` |
| `/modules/9/colors/background` | RGBA or null | null | Preferences, Graphs (Processes graph), Colors | `graphs.processes.color.background` |
| `/modules/9/colors/series/0` | RGBA or null | null | Preferences, Graphs (Processes graph), Colors | `graphs.processes.color.series1` |
| `/modules/9/colors/series/1` | RGBA or null | null | Preferences, Graphs (Processes graph), Colors | `graphs.processes.color.series2` |
| `/modules/9/colors/series/2` | RGBA or null | null | Preferences, Graphs (Processes graph), Colors | `graphs.processes.color.series3` |

*Generated together with `Shared/Settings/settings-catalog.json` so the two
cannot drift; the generator was a throwaway script, the committed artifacts
are the catalog and this file.*
