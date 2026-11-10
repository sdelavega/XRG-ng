// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Versioned Linux presentation preferences. Paths are explicit for isolated tests.
pub mod document;
pub mod network_scale;
mod window_collapse;
mod window_size;
mod xtf;
use crate::{
    shared::{self, Theme},
    system_file,
};
use serde::{Deserialize, Serialize};
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    thread,
};
pub use window_collapse::{CollapseAnchor, WindowCollapse};
pub use window_size::WindowSize;
const LIMIT: usize = 128 * 1024;
static NEXT: AtomicU64 = AtomicU64::new(0);
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum Module {
    Cpu,
    Memory,
    Network,
    Disk,
    Battery,
    Temperature,
    Gpu,
    Ai,
    Processes,
    Tpu,
    GpuMemory,
    Fans,
    Weather,
    Stocks,
}
impl Module {
    pub const ALL: [Self; 14] = [
        Self::Cpu,
        Self::Memory,
        Self::Network,
        Self::Disk,
        Self::Battery,
        Self::Temperature,
        Self::Gpu,
        Self::Ai,
        Self::Processes,
        Self::Tpu,
        Self::GpuMemory,
        Self::Fans,
        Self::Weather,
        Self::Stocks,
    ];
    pub fn index(self) -> usize {
        Self::ALL.iter().position(|m| *m == self).unwrap()
    }
    pub fn title(self) -> &'static str {
        match self {
            Self::Cpu => "CPU",
            Self::Memory => "Memory",
            Self::Network => "Network · receive / send",
            Self::Disk => "Disk · read / write",
            Self::Battery => "Battery",
            Self::Temperature => "Temperature",
            Self::Gpu => "GPU · activity",
            Self::Ai => "AI tokens · observed rate",
            Self::Processes => "Processes · readable / running",
            Self::Tpu => "TPU / NPU · neural accelerators",
            Self::GpuMemory => "VRAM · reported pool used",
            Self::Fans => "Fans · RPM",
            Self::Weather => "Weather · station observations",
            Self::Stocks => "Stocks",
        }
    }
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GraphStyle {
    Solid,
    Pixel,
    Dot,
    /// Missing fields in older Rust documents retain their original line view.
    #[default]
    Hollow,
}
impl GraphStyle {
    pub const ALL: [Self; 4] = [Self::Solid, Self::Pixel, Self::Dot, Self::Hollow];
    pub fn name(self) -> &'static str {
        match self {
            Self::Solid => "Solid",
            Self::Pixel => "Pixel",
            Self::Dot => "Dot",
            Self::Hollow => "Hollow",
        }
    }
    pub fn index(self) -> usize {
        Self::ALL.iter().position(|s| *s == self).unwrap()
    }
}
/// Current-value indicators use the graph's axis, never an inferred capacity.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct ActivityBars {
    pub visible: bool,
    pub style: GraphStyle,
    pub color: [f64; 4],
    pub use_series_colors: bool,
}
impl Default for ActivityBars {
    fn default() -> Self {
        Self {
            // Missing fields preserve the appearance of older Rust settings.
            visible: false,
            style: GraphStyle::Solid,
            color: [0.2, 1., 0.3, 1.],
            use_series_colors: false,
        }
    }
}
impl ActivityBars {
    pub fn validate(&self) -> Result<(), String> {
        if self
            .color
            .iter()
            .any(|v| !v.is_finite() || !(0.0..=1.).contains(v))
        {
            return Err(
                "Activity bar RGBA components must be finite numbers between 0 and 1".into(),
            );
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct GraphColors {
    pub background: Option<[f64; 4]>,
    pub series: [Option<[f64; 4]>; 3],
}
impl GraphColors {
    /// Graph background followed by the three series; None inherits the theme.
    pub fn components(&self) -> [Option<[f64; 4]>; 4] {
        [
            self.background,
            self.series[0],
            self.series[1],
            self.series[2],
        ]
    }
    pub fn is_inherited(&self) -> bool {
        self.components().iter().all(Option::is_none)
    }
    pub fn validate(&self) -> Result<(), String> {
        if self
            .components()
            .into_iter()
            .flatten()
            .flatten()
            .any(|v| !v.is_finite() || !(0.0..=1.0).contains(&v))
        {
            return Err("Graph RGBA components must be finite numbers between 0 and 1".into());
        }
        Ok(())
    }
    pub fn set(&mut self, index: usize, color: Option<[f64; 4]>) -> Result<(), String> {
        if color.is_some_and(|c| c.iter().any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))) {
            return Err("Invalid graph color".into());
        }
        match index {
            0 => self.background = color,
            1..=3 => self.series[index - 1] = color,
            _ => return Err("Unknown graph color component".into()),
        }
        Ok(())
    }
    pub fn palette(&self, base: &Theme) -> Theme {
        let mut result = base.clone();
        for (index, color) in self.components().into_iter().enumerate() {
            if let Some(color) = color {
                result.colors[index + 1] = color;
            }
        }
        result
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ModuleSetting {
    pub id: Module,
    pub visible: bool,
    #[serde(default)]
    pub style: GraphStyle,
    #[serde(default, skip_serializing_if = "GraphColors::is_inherited")]
    pub colors: GraphColors,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
}
impl ModuleSetting {
    pub fn effective_height(&self, default: u32) -> u32 {
        self.height.unwrap_or(default)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ThemeDocument {
    pub format: String,
    pub version: u32,
    pub name: String,
    pub colors: [[f64; 4]; 7],
}
impl ThemeDocument {
    pub fn new(theme: &Theme) -> Self {
        Self {
            format: "xrg-ng-theme".into(),
            version: 1,
            name: theme.name.clone(),
            colors: theme.colors,
        }
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.format != "xrg-ng-theme" || self.version != 1 {
            return Err("Unsupported theme format or version".into());
        }
        if self.name.trim() != self.name
            || self.name.is_empty()
            || self.name.chars().count() > 80
            || self.name.chars().any(char::is_control)
        {
            return Err("Theme name must contain 1–80 printable characters".into());
        }
        if self
            .colors
            .iter()
            .flatten()
            .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
        {
            return Err("Theme RGBA components must be finite numbers between 0 and 1".into());
        }
        Ok(())
    }
    pub fn palette(&self) -> Result<Theme, String> {
        self.validate()?;
        Ok(Theme {
            name: self.name.clone(),
            colors: self.colors,
        })
    }
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > LIMIT {
            return Err("Theme file exceeds 128 KiB".into());
        }
        let prefix = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
        if bytes.starts_with(b"bplist")
            || prefix.iter().find(|b| !b.is_ascii_whitespace()) == Some(&b'<')
        {
            return xtf::parse(bytes);
        }
        let value: Self =
            serde_json::from_slice(bytes).map_err(|e| format!("Invalid theme: {e}"))?;
        value.validate()?;
        Ok(value)
    }
    pub fn load(path: &Path) -> Result<Self, String> {
        Self::parse(&system_file::read(path, LIMIT).map_err(|e| e.to_string())?)
    }
    /// Publish a new theme atomically, without replacing a concurrently created file.
    pub fn save_new(&self, path: &Path) -> Result<(), String> {
        self.validate()?;
        atomic_write_new(
            path,
            &serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?,
            false,
        )
    }
    /// Replace an existing theme file atomically — the write the user
    /// confirmed in the file picker. A read-only destination inside a
    /// writable directory is replaced, unlike the settings document.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        self.validate()?;
        atomic_write(
            path,
            &serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?,
            false,
        )
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ThemeChoice {
    Builtin { name: String },
    Custom { theme: Box<ThemeDocument> },
}
impl ThemeChoice {
    pub fn palette(&self) -> Result<Theme, String> {
        match self {
            Self::Custom { theme } => theme.palette(),
            Self::Builtin { name } => shared::themes()
                .into_iter()
                .find(|t| t.name == *name)
                .ok_or_else(|| "Unknown built-in theme".into()),
        }
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct MetricSelection {
    pub battery_mode: crate::battery::Mode,
    /// None selects the aggregate; a number selects one logical CPU.
    pub cpu: Option<u32>,
    /// Zero retains the historical 120-sample default; explicit counts survive resizing.
    #[serde(skip_serializing_if = "zero_cpu_history")]
    pub cpu_history_samples: u32,
    #[serde(skip_serializing_if = "zero_cpu_history")]
    pub cpu_history_minutes: u32,
    /// Graph-local capacities; missing/zero keeps the original 120 samples.
    #[serde(skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub history_samples: std::collections::BTreeMap<Module, u32>,
    #[serde(skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub history_minutes: std::collections::BTreeMap<Module, u32>,
    pub network: Option<String>,
    pub disk: Option<String>,
    /// Collector-provided identity, compared with inventory; never used as a path.
    pub gpu: Option<String>,
    /// Opt-in: Xe engine PMU descriptors can keep the GPU awake.
    pub xe_pmu: bool,
    pub temperature: Option<String>,
    pub fan: Option<String>,
    /// Optional curves 2/3. A primary source is required; holes retain color slots.
    #[serde(skip_serializing_if = "empty_sensor_extras")]
    pub temperature_extra: [Option<String>; 2],
    #[serde(skip_serializing_if = "empty_sensor_extras")]
    pub fan_extra: [Option<String>; 2],
}
fn empty_sensor_extras(value: &[Option<String>; 2]) -> bool {
    value.iter().all(Option::is_none)
}
fn zero_cpu_history(value: &u32) -> bool {
    *value == 0
}
impl MetricSelection {
    pub fn retained_minutes(&self, module: Module) -> u32 {
        self.history_minutes.get(&module).copied().unwrap_or(0)
    }
    pub fn retained_samples(&self, module: Module) -> u32 {
        self.history_samples.get(&module).copied().unwrap_or(0)
    }
    pub fn history_capacity(&self, module: Module) -> u32 {
        match self.retained_samples(module) {
            0 => 120,
            count => count,
        }
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.history_samples.iter().any(|(module, count)| {
            !matches!(
                module,
                Module::Memory
                    | Module::Network
                    | Module::Disk
                    | Module::Gpu
                    | Module::Tpu
                    | Module::GpuMemory
                    | Module::Temperature
                    | Module::Fans
                    | Module::Battery
            ) || *count > shared::sampling_settings()[3]
        }) {
            return Err("History capacity must be 0..20000 for a supported system graph".into());
        }
        if self.history_minutes.iter().any(|(module, count)| {
            !matches!(
                module,
                Module::Memory
                    | Module::Network
                    | Module::Disk
                    | Module::Gpu
                    | Module::Tpu
                    | Module::GpuMemory
                    | Module::Fans
                    | Module::Temperature
                    | Module::Battery
            ) || *count > shared::timed_projection_settings()[0]
        }) {
            return Err("Time windows must be 0..60 minutes for supported system graphs".into());
        }
        if self.cpu_history_minutes > shared::timed_projection_settings()[0] {
            return Err("CPU time window must be 0..60 minutes".into());
        }
        if self.cpu_history_samples > shared::sampling_settings()[3] {
            return Err("CPU history must be automatic or between 1 and 20000 samples".into());
        }
        if self.cpu.is_some_and(|n| n > 1_048_575) {
            return Err("CPU index is out of range".into());
        }
        for name in [&self.network, &self.disk].into_iter().flatten() {
            if name.is_empty()
                || name == "."
                || name == ".."
                || name.len() > 255
                || name
                    .chars()
                    .any(|c| c.is_control() || c.is_whitespace() || c == '/' || c == ':')
            {
                return Err("Invalid network/disk name".into());
            }
        }
        for id in [&self.gpu, &self.temperature, &self.fan]
            .into_iter()
            .flatten()
            .chain(self.temperature_extra.iter().flatten())
            .chain(self.fan_extra.iter().flatten())
        {
            if id.is_empty() || id.len() > 4096 || id.chars().any(char::is_control) {
                return Err("Invalid metric source identity".into());
            }
        }
        for (name, primary, extra) in [
            ("Temperature", &self.temperature, &self.temperature_extra),
            ("Fan", &self.fan, &self.fan_extra),
        ] {
            if primary.is_none() && extra.iter().any(Option::is_some) {
                return Err(format!(
                    "{name}: choose a primary sensor before adding curves"
                ));
            }
            let ids: Vec<_> = std::iter::once(primary).chain(extra).flatten().collect();
            let unique: std::collections::BTreeSet<_> = ids.iter().collect();
            if unique.len() != ids.len() {
                return Err(format!("{name}: each curve must use a different sensor"));
            }
        }
        Ok(())
    }
    pub fn matches(&self, other: &Self, module: Module) -> bool {
        match module {
            Module::Battery => self.battery_mode == other.battery_mode,
            Module::Cpu => self.cpu == other.cpu,
            Module::Network => self.network == other.network,
            Module::Disk => self.disk == other.disk,
            Module::Gpu => self.gpu == other.gpu && self.xe_pmu == other.xe_pmu,
            Module::GpuMemory => self.gpu == other.gpu,
            Module::Temperature => {
                self.temperature == other.temperature
                    && self.temperature_extra == other.temperature_extra
            }
            Module::Fans => self.fan == other.fan && self.fan_extra == other.fan_extra,
            _ => true,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct ProcessView {
    pub sort: crate::process::Sort,
    pub uid: Option<u32>,
    pub filter: String,
    pub limit: u32,
}
impl Default for ProcessView {
    fn default() -> Self {
        Self {
            sort: crate::process::Sort::Cpu,
            uid: None,
            filter: String::new(),
            limit: 50,
        }
    }
}
impl ProcessView {
    pub fn validate(&self) -> Result<(), String> {
        if !(10..=200).contains(&self.limit) {
            return Err("Process row limit must be between 10 and 200".into());
        }
        if self.filter.chars().count() > 128 || self.filter.chars().any(char::is_control) {
            return Err("Process name filter must contain at most 128 printable characters".into());
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Layout {
    #[default]
    Vertical,
    Horizontal,
}
/// The shared Stocks settings, as the Linux view of the unified settings
/// document carries them. The core now maps the Stocks graph itself, so its
/// presentation (visible, style, height, colours) and its position in
/// `graphs.order` travel through the core like every other graph.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct StockSettings {
    /// Comma-separated ticker symbols to graph.
    pub symbols: String,
    /// How much history the chart shows, in months.
    pub timeframe: u32,
    /// Use twice as many lines to show the last day's change.
    pub show_change: bool,
    /// Add the Dow as a secondary curve and closing price.
    pub show_djia: bool,
}
impl Default for StockSettings {
    fn default() -> Self {
        Self {
            symbols: "AAPL".into(),
            timeframe: 12,
            show_change: true,
            show_djia: true,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub version: u32,
    pub theme: ThemeChoice,
    pub modules: Vec<ModuleSetting>,
    pub graph_height: u32,
    #[serde(default = "default_graph_width")]
    pub graph_width: u32,
    #[serde(default = "crate::sampling::default_interval")]
    pub sampling_interval_ms: u32,
    #[serde(default = "default_window_opacity")]
    pub window_opacity: f64,
    #[serde(default)]
    pub window_size: Option<WindowSize>,
    #[serde(default)]
    pub window_collapse: WindowCollapse,
    #[serde(default)]
    pub network_min_scale: u64,
    #[serde(default)]
    pub activity_bars: ActivityBars,
    #[serde(default)]
    pub layout: Layout,
    #[serde(default)]
    pub temperature_units: crate::temperature::Units,
    #[serde(default)]
    pub metrics: MetricSelection,
    #[serde(default)]
    pub processes: ProcessView,
    #[serde(default)]
    pub ai: crate::ai::Preferences,
    #[serde(default = "default_ai_model_breakdown")]
    pub ai_show_model_breakdown: bool,
    #[serde(default)]
    pub weather: crate::weather::Preferences,
    #[serde(default)]
    pub stocks: StockSettings,
}
fn default_graph_width() -> u32 {
    140
}
fn default_window_opacity() -> f64 {
    1.0
}
fn default_ai_model_breakdown() -> bool {
    true
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            version: 40,
            theme: ThemeChoice::Builtin {
                name: "Classic".into(),
            },
            modules: Self::default_order()
                .into_iter()
                .map(|id| ModuleSetting {
                    id,
                    visible: !matches!(
                        id,
                        Module::Processes
                            | Module::GpuMemory
                            | Module::Fans
                            | Module::Weather
                            | Module::Stocks
                    ),
                    style: GraphStyle::Solid,
                    colors: GraphColors::default(),
                    height: None,
                })
                .collect(),
            graph_height: 90,
            graph_width: default_graph_width(),
            sampling_interval_ms: crate::sampling::default_interval(),
            window_opacity: default_window_opacity(),
            window_size: None,
            window_collapse: WindowCollapse::default(),
            network_min_scale: 0,
            activity_bars: ActivityBars {
                visible: true,
                use_series_colors: true,
                ..ActivityBars::default()
            },
            layout: Layout::default(),
            temperature_units: crate::temperature::Units::default(),
            metrics: MetricSelection::default(),
            processes: ProcessView::default(),
            ai: crate::ai::Preferences::default(),
            ai_show_model_breakdown: default_ai_model_breakdown(),
            weather: crate::weather::Preferences::default(),
            stocks: StockSettings::default(),
        }
    }
}
impl Settings {
    pub fn default_order() -> [Module; 14] {
        [
            Module::Cpu,
            Module::Gpu,
            Module::Tpu,
            Module::Memory,
            Module::Battery,
            Module::Temperature,
            Module::Network,
            Module::Disk,
            Module::Ai,
            Module::Processes,
            Module::GpuMemory,
            Module::Fans,
            Module::Weather,
            Module::Stocks,
        ]
    }
    pub fn module(&self, id: Module) -> &ModuleSetting {
        self.modules
            .iter()
            .find(|m| m.id == id)
            .expect("Validated module set")
    }
    pub fn module_mut(&mut self, id: Module) -> &mut ModuleSetting {
        self.modules
            .iter_mut()
            .find(|m| m.id == id)
            .expect("Validated module set")
    }
    /// Join every graph the model knows that the module list lacks, hidden,
    /// exactly as the upgrade chain appends graphs an older file never
    /// stored. A defensive completeness guard for legacy documents; the
    /// core's Linux view already names every graph, including Stocks.
    pub(crate) fn ensure_modules(&mut self) {
        for id in Module::ALL {
            if !self.modules.iter().any(|m| m.id == id) {
                self.modules.push(ModuleSetting {
                    id,
                    visible: false,
                    style: GraphStyle::Solid,
                    colors: GraphColors::default(),
                    height: None,
                });
            }
        }
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.version != 40 {
            return Err("Unsupported settings version; the existing file will be kept".into());
        }
        if !(64..=240).contains(&self.graph_height) {
            return Err("Graph height must be between 64 and 240 pixels".into());
        }
        crate::sampling::interval(self.sampling_interval_ms)?;
        network_scale::validate(self.network_min_scale)?;
        if let Some(size) = self.window_size {
            size.validate()?;
        }
        if !self.window_opacity.is_finite() || !(0.1..=1.0).contains(&self.window_opacity) {
            return Err("Main window opacity must be between 0.1 and 1.0".into());
        }
        if !(100..=1200).contains(&self.graph_width) {
            return Err("Minimum graph width must be between 100 and 1200 pixels".into());
        }
        let ids: std::collections::BTreeSet<_> = self.modules.iter().map(|m| m.id).collect();
        if ids.len() != Module::ALL.len() || self.modules.len() != Module::ALL.len() {
            return Err("Settings must contain each graph exactly once".into());
        }
        self.theme.palette()?;
        self.activity_bars.validate()?;
        for module in &self.modules {
            module.colors.validate()?;
            if module
                .height
                .is_some_and(|height| !(64..=240).contains(&height))
            {
                return Err(format!(
                    "{} graph height must be between 64 and 240 pixels",
                    module.id.title()
                ));
            }
        }
        self.metrics.validate()?;
        self.processes.validate()?;
        self.ai.validate()?;
        self.weather.validate()?;
        Ok(())
    }
    /// Repair a view the workers would refuse (final review, finding 1 /
    /// ruling R29; round 2, issue 2 / ruling R33): reset ONLY the settings
    /// that break a rule, never a whole component, and report every
    /// replacement — the same per-setting fallback a malformed entry gets
    /// at load. Every rule `validate()` carries gets its own field-level
    /// repair here: the bounds of each scalar, the per-module graph rules,
    /// each process, AI and weather field, the per-slot metric choices —
    /// and the cross-setting combinations: a secondary sensor curve
    /// without a primary clears the offending curves only, a duplicate
    /// curve clears the later copy only, and an enabled weather collector
    /// without an addressable station disables the collector only. A
    /// combination no per-field repair catches falls back to the whole
    /// default view, so a loaded document can never fail `validate()`
    /// downstream and the launch never panics.
    pub fn repaired(&self) -> (Settings, Vec<&'static str>) {
        let mut repaired = self.clone();
        let mut replaced: Vec<&'static str> = Vec::new();
        let default = Settings::default();
        if self.theme.palette().is_err() {
            repaired.theme = default.theme.clone();
            replaced.push("the theme");
        }
        if self.activity_bars.validate().is_err() {
            repaired.activity_bars = default.activity_bars.clone();
            replaced.push("the activity bar colours");
        }
        let ids: std::collections::BTreeSet<_> = self.modules.iter().map(|m| m.id).collect();
        if ids.len() != Module::ALL.len() || self.modules.len() != Module::ALL.len() {
            repaired.modules = default.modules.clone();
            replaced.push("the graph set");
        } else {
            for module in &mut repaired.modules {
                if module.colors.validate().is_err() {
                    module.colors = GraphColors::default();
                    replaced.push("a graph's colours");
                }
                if module
                    .height
                    .is_some_and(|height| !(64..=240).contains(&height))
                {
                    module.height = None;
                    replaced.push("a graph's height");
                }
            }
        }
        if !(64..=240).contains(&self.graph_height) {
            repaired.graph_height = default.graph_height;
            replaced.push("the graph height");
        }
        if !(100..=1200).contains(&self.graph_width) {
            repaired.graph_width = default.graph_width;
            replaced.push("the graph width");
        }
        if crate::sampling::interval(self.sampling_interval_ms).is_err() {
            repaired.sampling_interval_ms = default.sampling_interval_ms;
            replaced.push("the sampling interval");
        }
        if network_scale::validate(self.network_min_scale).is_err() {
            repaired.network_min_scale = default.network_min_scale;
            replaced.push("the network scale");
        }
        if !self.window_opacity.is_finite() || !(0.1..=1.0).contains(&self.window_opacity) {
            repaired.window_opacity = default.window_opacity;
            replaced.push("the window opacity");
        }
        if let Some(size) = self.window_size
            && size.validate().is_err()
        {
            repaired.window_size = None;
            replaced.push("the window size");
        }
        // The process view, per field.
        if !(10..=200).contains(&self.processes.limit) {
            repaired.processes.limit = default.processes.limit;
            replaced.push("the process row limit");
        }
        if self.processes.filter.chars().count() > 128
            || self.processes.filter.chars().any(char::is_control)
        {
            repaired.processes.filter = default.processes.filter;
            replaced.push("the process filter");
        }
        // The AI preferences, per field.
        if self.ai.accounting.validate().is_err() {
            repaired.ai.accounting = default.ai.accounting.clone();
            replaced.push("an AI accounting setting");
        }
        if self.ai.history_minutes > crate::shared::timed_history_settings()[0] {
            repaired.ai.history_minutes = default.ai.history_minutes;
            replaced.push("the AI time window");
        }
        if self.ai.history_samples > crate::shared::sampling_settings()[3] {
            repaired.ai.history_samples = default.ai.history_samples;
            replaced.push("the AI history capacity");
        }
        for (field, path) in [
            (&mut repaired.ai.claude_logs, self.ai.claude_logs.as_deref()),
            (
                &mut repaired.ai.claude_database,
                self.ai.claude_database.as_deref(),
            ),
            (&mut repaired.ai.codex_logs, self.ai.codex_logs.as_deref()),
            (&mut repaired.ai.gemini_logs, self.ai.gemini_logs.as_deref()),
            (
                &mut repaired.ai.hermes_database,
                self.ai.hermes_database.as_deref(),
            ),
        ] {
            let invalid = path.is_some_and(|path| {
                let value = path.to_str().unwrap_or("");
                !path.is_absolute() || value.len() > 4096 || value.chars().any(char::is_control)
            });
            if invalid {
                *field = None;
                replaced.push("an AI path");
            }
        }
        if crate::ai::validate_url(&self.ai.metrics_url).is_err() {
            repaired.ai.metrics_url = default.ai.metrics_url;
            replaced.push("the AI metrics endpoint");
        }
        if crate::ai::validate_url(&self.ai.ollama_url).is_err() {
            repaired.ai.ollama_url = default.ai.ollama_url;
            replaced.push("the Ollama endpoint");
        }
        // The weather preferences, per field.
        if self
            .weather
            .history_hours
            .is_some_and(|hours| ![6, 12, 24].contains(&hours))
        {
            repaired.weather.history_hours = None;
            replaced.push("the weather history");
        }
        if !(5..=60).contains(&self.weather.refresh_minutes) {
            repaired.weather.refresh_minutes = default.weather.refresh_minutes;
            replaced.push("the weather refresh interval");
        }
        if self.weather.station.trim().is_empty() {
            // An enabled collector without an addressable station is the
            // cross-setting combination: the collector alone steps back.
            if self.weather.enabled {
                repaired.weather.enabled = false;
                replaced.push("the weather station toggle");
            }
        } else if shared::metar_station(&self.weather.station).is_none() {
            repaired.weather.station = default.weather.station.clone();
            replaced.push("the weather station");
            if self.weather.enabled {
                repaired.weather.enabled = false;
                replaced.push("the weather station toggle");
            }
        }
        // The metric selection, per field.
        if self.metrics.cpu.is_some_and(|index| index > 1_048_575) {
            repaired.metrics.cpu = None;
            replaced.push("the CPU index");
        }
        for (offender, field) in [
            ("the network device", &mut repaired.metrics.network),
            ("the disk device", &mut repaired.metrics.disk),
        ] {
            if field.as_deref().is_some_and(|name| {
                name.is_empty()
                    || name == "."
                    || name == ".."
                    || name.len() > 255
                    || name
                        .chars()
                        .any(|c| c.is_control() || c.is_whitespace() || c == '/' || c == ':')
            }) {
                *field = None;
                replaced.push(offender);
            }
        }
        for (offender, field) in [
            ("the GPU source", &mut repaired.metrics.gpu),
            ("the temperature curve", &mut repaired.metrics.temperature),
            ("the fan curve", &mut repaired.metrics.fan),
        ] {
            if field.as_deref().is_some_and(|id| {
                id.is_empty() || id.len() > 4096 || id.chars().any(char::is_control)
            }) {
                *field = None;
                replaced.push(offender);
            }
        }
        for (offenders, extra) in [
            (
                ["the temperature curve 2", "the temperature curve 3"],
                &mut repaired.metrics.temperature_extra,
            ),
            (
                ["the fan curve 2", "the fan curve 3"],
                &mut repaired.metrics.fan_extra,
            ),
        ] {
            for slot in 0..2 {
                if extra[slot].as_deref().is_some_and(|id| {
                    id.is_empty() || id.len() > 4096 || id.chars().any(char::is_control)
                }) {
                    extra[slot] = None;
                    replaced.push(offenders[slot]);
                }
            }
        }
        let supported = |module: &Module| {
            matches!(
                module,
                Module::Memory
                    | Module::Network
                    | Module::Disk
                    | Module::Gpu
                    | Module::Tpu
                    | Module::GpuMemory
                    | Module::Temperature
                    | Module::Fans
                    | Module::Battery
            )
        };
        repaired.metrics.history_minutes.retain(|module, count| {
            let ok = supported(module) && *count <= shared::timed_projection_settings()[0];
            if !ok {
                replaced.push("a time window");
            }
            ok
        });
        repaired.metrics.history_samples.retain(|module, count| {
            let ok = supported(module) && *count <= shared::sampling_settings()[3];
            if !ok {
                replaced.push("a history capacity");
            }
            ok
        });
        if self.metrics.cpu_history_minutes > shared::timed_projection_settings()[0] {
            repaired.metrics.cpu_history_minutes = default.metrics.cpu_history_minutes;
            replaced.push("the CPU time window");
        }
        if self.metrics.cpu_history_samples > shared::sampling_settings()[3] {
            repaired.metrics.cpu_history_samples = default.metrics.cpu_history_samples;
            replaced.push("the CPU history");
        }
        // The sensor combinations (ruling R33): a secondary curve without
        // a primary clears the offending curves only, and a duplicate
        // clears the later copy only.
        for (offenders, primary, extra) in [
            (
                ["the temperature curve 2", "the temperature curve 3"],
                self.metrics.temperature.as_deref(),
                &mut repaired.metrics.temperature_extra,
            ),
            (
                ["the fan curve 2", "the fan curve 3"],
                self.metrics.fan.as_deref(),
                &mut repaired.metrics.fan_extra,
            ),
        ] {
            let mut seen: Vec<String> = primary.map(str::to_owned).into_iter().collect();
            for slot in 0..2 {
                if let Some(id) = extra[slot].clone() {
                    // A secondary without a primary, or a duplicate of an
                    // earlier curve: the offending slot alone steps back.
                    if primary.is_none() || seen.contains(&id) {
                        extra[slot] = None;
                        replaced.push(offenders[slot]);
                    } else {
                        seen.push(id);
                    }
                }
            }
        }
        if repaired.validate().is_ok() {
            return (repaired, replaced);
        }
        (Settings::default(), vec!["settings that failed validation"])
    }
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > LIMIT {
            return Err("Settings file exceeds 128 KiB".into());
        }
        let text = std::str::from_utf8(bytes).map_err(|_| "Invalid settings encoding")?;
        let mut result: Self = if text.trim_start().starts_with('{') {
            serde_json::from_slice(bytes).map_err(|e| format!("Invalid settings: {e}"))?
        } else {
            // Upgrade only the exact original Rust format; never treat another
            // application's INI or malformed JSON as an empty settings file.
            let lines: Vec<_> = text
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty() && !l.starts_with('#'))
                .collect();
            if lines.len() != 1 {
                return Err("Unrecognized settings format".into());
            }
            let name = lines[0]
                .strip_prefix("theme=")
                .ok_or("Unrecognized settings format")?;
            let mut defaults = Self::default();
            defaults.activity_bars.visible = false;
            defaults.activity_bars.use_series_colors = false;
            for module in &mut defaults.modules {
                // The INI era's line look belongs to the graphs it had;
                // Stocks joins with the model's own Solid default.
                if module.id != Module::Stocks {
                    module.style = GraphStyle::Hollow;
                }
            }
            Self {
                theme: ThemeChoice::Builtin { name: name.into() },
                ..defaults
            }
        };
        if result.version == 1 || result.version == 2 {
            // Older documents must still contain exactly their original graphs.
            // Appending hidden modules preserves order, visibility and recovery
            // behavior, including a deliberately all-hidden layout.
            let expected: std::collections::BTreeSet<_> =
                Module::ALL[..10].iter().copied().collect();
            let actual: std::collections::BTreeSet<_> =
                result.modules.iter().map(|m| m.id).collect();
            if result.modules.len() != 10 || actual != expected {
                return Err("Legacy settings must contain each original graph exactly once".into());
            }
            result
                .modules
                .extend([Module::GpuMemory, Module::Fans].map(|id| ModuleSetting {
                    id,
                    visible: false,
                    style: GraphStyle::Hollow,
                    colors: GraphColors::default(),
                    height: None,
                }));
            result.version = 5;
        }
        if result.version == 3 || result.version == 4 {
            result.version = 5;
        }
        if result.version == 5 {
            result.version = 6;
        }
        if result.version == 6 {
            result.version = 7;
        }
        if result.version == 7 {
            result.version = 8;
        }
        if result.version == 8 {
            result.version = 9;
        }
        if result.version == 9 {
            result.version = 10;
        }
        if result.version == 10 {
            result.version = 11;
        }
        if result.version == 11 {
            result.version = 12;
        }
        if result.version == 12 {
            result.version = 13;
        }
        if result.version == 13 {
            result.version = 14;
        }
        if result.version == 14 {
            let expected: std::collections::BTreeSet<_> =
                Module::ALL[..12].iter().copied().collect();
            let actual: std::collections::BTreeSet<_> =
                result.modules.iter().map(|m| m.id).collect();
            if result.modules.len() != 12 || actual != expected {
                return Err(
                    "Previous settings must contain each of their twelve graphs exactly once"
                        .into(),
                );
            }
            result.modules.push(ModuleSetting {
                id: Module::Weather,
                visible: false,
                style: GraphStyle::Solid,
                colors: GraphColors::default(),
                height: None,
            });
            result.version = 15;
        }
        if result.version == 15 {
            result.version = 16;
        }
        if result.version == 16 {
            result.version = 17;
        }
        if result.version == 17 {
            result.version = 18;
        }
        if result.version == 18 {
            result.version = 19;
        }
        if result.version == 19 {
            result.version = 20;
        }
        if result.version == 20 {
            result.version = 21;
        }
        if result.version == 21 {
            result.version = 22;
        }
        if result.version == 22 {
            result.version = 23;
        }
        if result.version == 23 {
            result.version = 24;
        }
        if result.version == 24 {
            result.version = 25;
        }
        if result.version == 25 {
            result.version = 26;
        }
        if result.version == 26 {
            result.version = 27;
        }
        if result.version == 27 {
            result.version = 28;
        }
        if result.version == 28 {
            result.version = 29;
        }
        if result.version == 29 {
            result.version = 30;
        }
        if result.version == 30 {
            result.version = 31;
        }
        if result.version == 31 {
            result.version = 32;
        }
        if result.version == 32 {
            result.version = 33;
        }
        if result.version == 33 {
            result.version = 34;
        }
        if result.version == 34 {
            result.version = 35;
        }
        if result.version == 35 {
            result.version = 36;
        }
        if result.version == 36 {
            result.version = 37;
        }
        if result.version == 37 {
            result.version = 38;
        }
        if result.version == 38 {
            result.version = 39;
        }
        if result.version == 39 {
            result.version = 40;
        }
        // Older version-40 files may predate the Stocks graph: it joins
        // hidden, the way the chain already appended earlier opt-in graphs.
        result.ensure_modules();
        result.validate()?;
        Ok(result)
    }
    pub fn minimum_scale(&self, module: Module) -> u64 {
        if module == Module::Network {
            self.network_min_scale
        } else {
            0
        }
    }
    pub fn move_module(&mut self, id: Module, offset: isize) {
        if let Some(index) = self.modules.iter().position(|m| m.id == id) {
            let target = index
                .saturating_add_signed(offset)
                .min(self.modules.len() - 1);
            let module = self.modules.remove(index);
            self.modules.insert(target, module);
        }
    }
}
/// The settings document's input bound: the same 1 MiB the settings ABI
/// accepts, so an oversized document is reported instead of truncated.
const DOCUMENT_LIMIT: usize = 1_048_576;

/// The configuration root `$XDG_CONFIG_HOME` (absolute) or `~/.config`.
pub fn config_root_from(
    config_home: Option<&std::ffi::OsStr>,
    home: Option<&std::ffi::OsStr>,
) -> Option<PathBuf> {
    let config = config_home
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .filter(|p| p.is_absolute());
    config
        .or_else(|| {
            home.map(PathBuf::from)
                .filter(|p| p.is_absolute())
                .map(|p| p.join(".config"))
        })
        .filter(|root| root.as_os_str() != "/")
}
pub fn config_root() -> Option<PathBuf> {
    config_root_from(
        std::env::var_os("XDG_CONFIG_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
}
/// The unified settings document: `<config root>/xrg-ng/settings.json`.
pub fn path_from(
    config_home: Option<&std::ffi::OsStr>,
    home: Option<&std::ffi::OsStr>,
) -> Option<PathBuf> {
    config_root_from(config_home, home).map(|root| root.join("xrg-ng/settings.json"))
}
pub fn preferences_path() -> Option<PathBuf> {
    path_from(
        std::env::var_os("XDG_CONFIG_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
}
fn read_optional(path: &Path, limit: usize) -> Result<Option<Vec<u8>>, String> {
    match system_file::read(path, limit) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}
/// The canonical bytes of the document with every setting at its default.
fn default_document() -> Vec<u8> {
    match document::load(br#"{"format": "xrg-ng-settings", "version": 1, "settings": {}}"#) {
        document::Loaded::Ok { document, .. } => document,
        // Unreachable for this constant input: the corpus fixtures hold the
        // exact bytes the pinned core answers the empty document with.
        document::Loaded::Unreadable { .. } => {
            unreachable!("the shared core refuses its own defaults document")
        }
    }
}
/// Every catalog id with its default, from the core, once.
fn catalog_defaults() -> &'static Vec<(String, serde_json::Value)> {
    static DEFAULTS: OnceLock<Vec<(String, serde_json::Value)>> = OnceLock::new();
    DEFAULTS.get_or_init(|| {
        document::catalog()
            .expect("the shared core provides the settings catalog")
            .entries
            .into_iter()
            .map(|entry| (entry.id, entry.default))
            .collect()
    })
}
/// The typed view the app runs on: the core's Linux view, which now maps
/// every graph — including the Stocks graph's presentation (visible, style,
/// height, colours) and its position in `graphs.order` — through the one
/// shared model. Every read of a stored document goes through here; nothing
/// is decoded, defaulted or range-checked on the Rust side.
fn view(document: &[u8]) -> Result<Settings, String> {
    document::linux_view(document)
}

/// The version-40 JSON the core's migration maps. The core now knows the
/// Stocks graph, so the whole view travels unchanged: its presentation and
/// its position in `graphs.order` are carried by the core in both directions.
fn v40_bytes(settings: &Settings) -> Result<Vec<u8>, String> {
    serde_json::to_vec(settings).map_err(|e| e.to_string())
}

/// The shared settings document as the Linux app stores it: the canonical
/// bytes on disk, the Linux view the app reads, and the one load problem
/// that keeps an unhealthy file safe. Nothing is parsed, validated or
/// migrated here — every question goes through the shared core's C ABI —
/// and every write is the bytes the core returned, written atomically with
/// mode 0600. A file that exists but does not load is never overwritten:
/// the app runs on defaults, `load_problem` explains, and only
/// `replace_unreadable` (the user's explicit action) rewrites it. A file the
/// owner cannot write is just as safe: it loads, the app runs on it, and no
/// save ever replaces it.
pub struct Store {
    path: PathBuf,
    document: Vec<u8>,
    settings: Settings,
    expected: Option<Vec<u8>>,
    blocked: bool,
    problem: Option<String>,
    /// Test injection: the next this many commits fail before writing, so a
    /// window test can interrupt the replacement's held-edit sequence.
    #[cfg(test)]
    fail_commits: u32,
}
impl Store {
    /// Open the settings under one configuration root. An existing
    /// `xrg-ng/settings.json` is loaded through the core. A missing one is
    /// migrated once from the legacy `xrg-ng/settings.conf` (which is read
    /// and left byte-identical for downgrades), and a configuration tree
    /// with neither starts from the defaults without writing anything.
    pub fn open(config_root: &Path) -> Self {
        let path = config_root.join("xrg-ng/settings.json");
        let conf = config_root.join("xrg-ng/settings.conf");
        let mut store = Self {
            path,
            document: default_document(),
            settings: Settings::default(),
            expected: None,
            blocked: false,
            problem: None,
            #[cfg(test)]
            fail_commits: 0,
        };
        match read_optional(&store.path, DOCUMENT_LIMIT) {
            // The document exists but cannot be read (permissions, size,
            // special file): it stays untouched and the app runs on defaults.
            Err(problem) => store.unreadable_file(&problem),
            Ok(None) => match read_optional(&conf, LIMIT) {
                Ok(None) => {}
                Ok(Some(bytes)) => store.migrate_legacy(&bytes),
                Err(problem) => {
                    store.problem = Some(format!(
                        "the legacy settings.conf could not be read: {problem}"
                    ));
                }
            },
            Ok(Some(bytes)) => match document::load(&bytes) {
                document::Loaded::Ok {
                    document,
                    diagnostics,
                } => {
                    store.document = document;
                    store.expected = Some(bytes);
                    // A readable file the owner cannot write is a problem the
                    // app reports and runs with, like any other: it is never
                    // replaced, and only the owner restoring the write
                    // permission (not `replace_unreadable`) clears it.
                    if destination_not_writable(&store.path) {
                        store.problem = Some(format!(
                            "the settings document is not writable: {}",
                            store.path.display()
                        ));
                    } else if let Some(diagnostic) = diagnostics.first() {
                        store.problem = Some(format!(
                            "a settings value was replaced: {}",
                            diagnostic.problem
                        ));
                    }
                }
                document::Loaded::Unreadable { diagnostic } => {
                    store.expected = Some(bytes);
                    store.unreadable_file(&diagnostic.problem);
                }
            },
        }
        // Whatever the load produced, the view the app reads is the one the
        // core renders from the document the store holds: fresh, migrated
        // and blocked states alike never fall back to the legacy Rust model.
        match view(&store.document) {
            Ok(view) => {
                // A view the workers would refuse never reaches them (final
                // review, finding 1 / ruling R29): each failing component
                // falls back to its default and the problem is reported
                // exactly like a malformed entry — the app starts, it never
                // panics on a loaded document.
                let (settings, replaced) = view.repaired();
                if replaced.is_empty() {
                    store.settings = view;
                } else {
                    let problem = format!("a settings value was replaced: {}", replaced.join(", "));
                    store.problem = match store.problem.take() {
                        Some(existing) => Some(format!("{existing}; {problem}")),
                        None => Some(problem),
                    };
                    store.settings = settings;
                }
            }
            Err(problem) => {
                store.document = default_document();
                store.settings = Settings::default();
                store.problem = Some(format!(
                    "the settings document could not be rendered: {problem}"
                ));
            }
        }
        store
    }
    /// The Linux view: the typed settings the core renders from the document.
    pub fn settings(&self) -> &Settings {
        &self.settings
    }
    /// The one problem that keeps the settings from being the file's: an
    /// unreadable document, a failed migration, a file the owner cannot
    /// write, or a value the core replaced. None while the file and the view
    /// agree.
    pub fn load_problem(&self) -> Option<&str> {
        self.problem.as_deref()
    }
    /// Whether an existing settings document that does not load is blocking
    /// saves: only the user's explicit `replace_unreadable` clears it.
    pub fn blocked(&self) -> bool {
        self.blocked
    }
    /// Every value the document holds, parsed once: the bytes the core last
    /// returned, with no local validation — every stored value in a
    /// loadable document is core-valid. Absent keys carry their catalog
    /// default.
    pub fn values(&self) -> serde_json::Map<String, serde_json::Value> {
        serde_json::from_slice::<serde_json::Value>(&self.document)
            .ok()
            .and_then(|document| {
                document
                    .get("settings")
                    .and_then(|settings| settings.as_object().cloned())
            })
            .unwrap_or_default()
    }
    /// Store one value, validating it through the core, and write the
    /// resulting document atomically with mode 0600. Refused values leave
    /// the file and the in-memory settings untouched; a blocked file (it
    /// exists but does not load) must be `replace_unreadable`d first.
    pub fn set(&mut self, id: &str, value: serde_json::Value) -> Result<(), document::SetError> {
        if self.blocked {
            return Err(document::SetError::InvalidDocument);
        }
        let document = document::set(&self.document, id, &value)?;
        self.commit(document)
            .map_err(|_| document::SetError::Transport)?;
        Ok(())
    }
    /// Validate one edit through the shared core without writing anything:
    /// the refusal `set` would report for the same value. Held edits —
    /// the in-memory changes a blocked document carries — are applied to
    /// the validation document first, so dependencies among them hold
    /// exactly as they will after the replacement applies them.
    pub fn validate_held(
        &self,
        held: &std::collections::BTreeMap<String, serde_json::Value>,
        id: &str,
        value: &serde_json::Value,
    ) -> Result<(), document::SetError> {
        let mut document = self.document.clone();
        for (held_id, held_value) in held {
            if let Ok(next) = document::set(&document, held_id, held_value) {
                document = next;
            }
        }
        document::set(&document, id, value).map(|_| ())
    }
    /// Restore every entry of one catalog section to its default, in the
    /// document the core returns; unknown keys and other sections are
    /// untouched, and the result is written atomically with mode 0600.
    pub fn reset_section(&mut self, section: &str) -> Result<(), String> {
        if self.blocked {
            return Err("The settings document did not load; replace it before saving".into());
        }
        let document = document::reset_section(&self.document, section)?;
        self.commit(document)
    }
    /// The user's explicit replacement of a document that does not load:
    /// write the current (default) document over it and clear the problem.
    pub fn replace_unreadable(&mut self) -> Result<(), String> {
        if !self.blocked {
            return Ok(());
        }
        let settings = view(&self.document)?;
        atomic_write_settings(&self.path, &self.document)?;
        self.settings = settings;
        self.expected = Some(self.document.clone());
        self.blocked = false;
        self.problem = None;
        Ok(())
    }
    /// Persist a whole settings view: the transitional whole-object save the
    /// preferences editor and `Writer` use. Only the entries whose value
    /// changed since the last loaded or saved view travel through the core's
    /// `set` path, so a save can never reset a document entry it did not
    /// derive: the Stocks settings (whose catalog entries have no
    /// version-40 mapping), other platforms' catalog keys and unknown keys
    /// are left exactly as the document holds them. Any value the core refuses aborts
    /// the save before anything is written.
    pub fn save(&mut self, settings: &Settings) -> Result<(), String> {
        if self.blocked {
            return Err("The settings document did not load; replace it before saving".into());
        }
        let desired = self.view_entries(settings)?;
        let baseline = self.view_entries(&self.settings)?;
        let document = self.changed_document(&desired, &baseline)?;
        self.commit(document)
    }
    /// The settings map the core derives from one Linux view through
    /// `migrate_v40`: every entry with a legacy Linux mapping, at the value
    /// the view carries — now including the Stocks graph's presentation and
    /// `graphs.order`, which the core maps. Entries at their default are
    /// absent from the migrated map, exactly as the core's migration writes
    /// them, so this map is the complete set of document ids a view save may
    /// ever touch.
    fn view_entries(
        &self,
        settings: &Settings,
    ) -> Result<serde_json::Map<String, serde_json::Value>, String> {
        let v40 = v40_bytes(settings)?;
        match document::migrate_v40(&v40)? {
            document::Loaded::Ok {
                document,
                diagnostics,
            } => {
                if let Some(diagnostic) = diagnostics.first() {
                    return Err(format!(
                        "the settings did not convert: {}",
                        diagnostic.problem
                    ));
                }
                let value: serde_json::Value =
                    serde_json::from_slice(&document).map_err(|e| e.to_string())?;
                Ok(value["settings"]
                    .as_object()
                    .cloned()
                    .expect("canonical map"))
            }
            document::Loaded::Unreadable { diagnostic } => Err(format!(
                "the settings did not convert: {}",
                diagnostic.problem
            )),
        }
    }
    /// The order the commit path applies entries through the core (ruling
    /// R33): the station an enabled collector needs comes before the
    /// enable, and a primary sensor curve before its secondaries, so a
    /// multi-entry save never passes through a cross-setting combination
    /// the core's per-edit refusal would reject on the way to a valid
    /// final view.
    fn application_rank(id: &str) -> (u8, &str) {
        match id {
            "weather.enabled" => (1, id),
            "sources.temperature.sensor2" => (1, id),
            "sources.temperature.sensor3" => (2, id),
            "sources.fans.sensor2" => (1, id),
            "sources.fans.sensor3" => (2, id),
            _ => (0, id),
        }
    }
    /// The current document with the desired view's changed entries stored
    /// through the core: every entry whose value differs from the baseline
    /// view is `set`, every entry the desired view reverted to its default
    /// is `set` to that default, which removes it again. Entries neither
    /// map names — the Stocks settings, other platforms' keys, unknown keys
    /// — are left exactly as they are. The entries are applied in the
    /// dependency order `application_rank` prescribes, so no intermediate
    /// document breaks a cross-setting combination. Any value the core
    /// refuses aborts the save before anything is written.
    fn changed_document(
        &self,
        desired: &serde_json::Map<String, serde_json::Value>,
        baseline: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<Vec<u8>, String> {
        let mut document = self.document.clone();
        let mut desired_entries: Vec<(&String, &serde_json::Value)> = desired.iter().collect();
        desired_entries.sort_by_key(|(id, _)| Self::application_rank(id));
        for (id, value) in desired_entries {
            if baseline.get(id) != Some(value) {
                document = document::set(&document, id, value)
                    .map_err(|_| format!("the settings did not convert: {id}"))?;
            }
        }
        let mut removals: Vec<&String> = baseline
            .keys()
            .filter(|id| !desired.contains_key(*id))
            .collect();
        // Reverting to defaults clears the dependent entries first.
        removals.sort_by_key(|id| std::cmp::Reverse(Self::application_rank(id)));
        for id in removals {
            let Some((_, default)) = catalog_defaults().iter().find(|(entry, _)| entry == id)
            else {
                continue;
            };
            document = document::set(&document, id, default)
                .map_err(|_| format!("the settings did not convert: {id}"))?;
        }
        Ok(document)
    }
    /// Fail the next `count` commits without writing. Tests inject a
    /// persistence error into the replacement's held-edit sequence; production
    /// builds have no such hook.
    #[cfg(test)]
    pub fn fail_next_commits(&mut self, count: u32) {
        self.fail_commits = count;
    }
    /// Write one core-produced document: rendered, guarded against external
    /// edits, written atomically with mode 0600, and only then adopted.
    fn commit(&mut self, document: Vec<u8>) -> Result<(), String> {
        #[cfg(test)]
        if self.fail_commits > 0 {
            self.fail_commits -= 1;
            return Err("injected persistence failure".into());
        }
        let settings = view(&document)?;
        if read_optional(&self.path, DOCUMENT_LIMIT)? != self.expected {
            return Err("Settings changed on disk; reopen the app before saving".into());
        }
        atomic_write_settings(&self.path, &document)?;
        self.document = document;
        self.settings = settings;
        self.expected = Some(self.document.clone());
        self.problem = None;
        Ok(())
    }
    /// One-time migration of the legacy `settings.conf`: upgraded by Rust's
    /// existing chain to version 40, converted by the core, written once.
    /// The legacy file itself is never written, and a write failure (a
    /// read-only configuration tree) keeps the migrated state in memory and
    /// reports the problem instead of failing the launch.
    fn migrate_legacy(&mut self, bytes: &[u8]) {
        let settings = match Settings::parse(bytes) {
            Ok(settings) => settings,
            Err(problem) => {
                self.problem = Some(format!(
                    "the legacy settings.conf could not be read: {problem}"
                ));
                return;
            }
        };
        let v40 = match v40_bytes(&settings) {
            Ok(v40) => v40,
            Err(problem) => {
                self.problem = Some(format!(
                    "the legacy settings.conf could not be read: {problem}"
                ));
                return;
            }
        };
        let (document, diagnostics) = match document::migrate_v40(&v40) {
            Ok(document::Loaded::Ok {
                document,
                diagnostics,
            }) => (document, diagnostics),
            Ok(document::Loaded::Unreadable { diagnostic }) => {
                self.problem = Some(format!(
                    "the legacy settings.conf did not convert: {}",
                    diagnostic.problem
                ));
                return;
            }
            Err(problem) => {
                self.problem = Some(format!(
                    "the legacy settings.conf did not convert: {problem}"
                ));
                return;
            }
        };
        if let Some(diagnostic) = diagnostics.first() {
            self.problem = Some(format!(
                "a legacy settings value was replaced: {}",
                diagnostic.problem
            ));
        }
        self.document = document.clone();
        match atomic_write_settings(&self.path, &document) {
            Ok(()) => {
                self.expected = Some(document);
            }
            Err(problem) => {
                // The path names the file the write failed on, so a
                // permission problem can be told from any other tree.
                self.problem = Some(format!(
                    "could not write {}: {problem}",
                    self.path.display()
                ));
            }
        }
    }
    /// An existing settings document that cannot be read or does not load:
    /// protect it for the whole session and run on defaults.
    fn unreadable_file(&mut self, problem: &str) {
        self.blocked = true;
        self.problem = Some(format!(
            "the settings document could not be loaded: {problem}"
        ));
    }
}
/// Whether the atomic writer may replace an existing destination file its
/// owner made read-only. POSIX rename replaces such a file whenever the
/// directory allows it, so every writer states its policy explicitly.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WritePolicy {
    /// The settings document: never replaced without its owner's write
    /// permission, whatever the directory or the caller's privileges allow.
    ProtectReadOnly,
    /// A replacement the user explicitly confirmed (theme export) or a
    /// private state file the app owns (AI accounting): the writer's
    /// previous semantics, so a read-only file in a writable directory is
    /// replaced.
    ReplaceAllowed,
}
/// Replace an existing theme file the user confirmed overwriting.
fn atomic_write(path: &Path, bytes: &[u8], create_parent: bool) -> Result<(), String> {
    atomic_write_bounded(
        path,
        bytes,
        create_parent,
        true,
        LIMIT,
        WritePolicy::ReplaceAllowed,
    )
}
/// Publish a new theme, without replacing a concurrently created file.
fn atomic_write_new(path: &Path, bytes: &[u8], create_parent: bool) -> Result<(), String> {
    atomic_write_bounded(
        path,
        bytes,
        create_parent,
        false,
        LIMIT,
        WritePolicy::ReplaceAllowed,
    )
}
/// Write the AI accounting state, a private file the app itself owns.
pub(crate) fn atomic_write_state(path: &Path, bytes: &[u8]) -> Result<(), String> {
    atomic_write_bounded(
        path,
        bytes,
        true,
        true,
        1_048_576,
        WritePolicy::ReplaceAllowed,
    )
}
/// Write the settings document: the one destination its owner's read-only
/// mode protects from replacement, even inside a writable directory.
fn atomic_write_settings(path: &Path, bytes: &[u8]) -> Result<(), String> {
    atomic_write_bounded(
        path,
        bytes,
        true,
        true,
        DOCUMENT_LIMIT,
        WritePolicy::ProtectReadOnly,
    )
}
fn atomic_write_bounded(
    path: &Path,
    bytes: &[u8],
    create_parent: bool,
    replace: bool,
    limit: usize,
    policy: WritePolicy,
) -> Result<(), String> {
    if bytes.len() > limit {
        return Err(format!("Settings/state file exceeds {} bytes", limit));
    }
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    if create_parent {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    if let Ok(metadata) = fs::symlink_metadata(path)
        && !metadata.is_file()
    {
        return Err("Destination must be a regular file, without symlinks".into());
    }
    // POSIX rename would replace a destination regardless of the file's own
    // mode, whatever the writable directory allows. Only a ProtectReadOnly
    // writer refuses — the settings document; a confirmed theme replacement
    // and the app-owned accounting state keep their previous semantics.
    if policy == WritePolicy::ProtectReadOnly && destination_not_writable(path) {
        return Err(format!(
            "Destination is not writable by its owner: {}",
            path.display()
        ));
    }
    for _ in 0..16 {
        let temporary = parent.join(format!(
            ".xrg-ng-{}-{}.tmp",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        // Restrictive creation permissions (0600) are POSIX; every unix target
        // keeps the explicit private mode instead of umask-dependent defaults.
        #[cfg(unix)]
        let mut file = match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
        {
            Ok(file) => file,
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.to_string()),
        };
        #[cfg(not(unix))]
        let mut file = match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
        {
            Ok(file) => file,
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.to_string()),
        };
        let result = file
            .write_all(bytes)
            .and_then(|_| file.sync_all())
            .and_then(|_| {
                if replace {
                    fs::rename(&temporary, path)
                } else {
                    publish_new(&temporary, path)
                }
            });
        if !replace || result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        return result.map_err(|e| e.to_string());
    }
    Err("Could not create a unique settings temporary file".into())
}
/// Whether an existing file lacks its owner's write permission, so a
/// ProtectReadOnly writer refuses to replace it. The file's own mode
/// decides — not the uid — so a read-only settings document is never
/// rewritten, whatever the directory permissions or the caller's
/// privileges allow.
#[cfg(unix)]
fn destination_not_writable(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o200 == 0)
        .unwrap_or(false)
}
/// Whether an existing file is marked read-only, on the platforms without
/// POSIX mode bits.
#[cfg(not(unix))]
fn destination_not_writable(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().readonly())
        .unwrap_or(false)
}
/// Prefer atomic no-replace rename on Linux (also works on filesystems without
/// hard links). The hard-link fallback likewise cannot replace a racing writer.
fn publish_new(temporary: &Path, path: &Path) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let from = CString::new(temporary.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in export path"))?;
        let to = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in export path"))?;
        // Both C strings remain alive throughout the call; no pointer is retained.
        if unsafe {
            libc::renameat2(
                libc::AT_FDCWD,
                from.as_ptr(),
                libc::AT_FDCWD,
                to.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        } == 0
        {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if !matches!(
            error.raw_os_error(),
            Some(libc::ENOSYS | libc::EINVAL | libc::EOPNOTSUPP)
        ) {
            return Err(error);
        }
    }
    fs::hard_link(temporary, path)
}
/// One worker and one pending value bound save work while users change controls.
/// Results carry a revision so an old completion cannot mask a newer save error.
pub type SaveResult = (u64, Result<(), String>);
pub struct Writer {
    notification: crate::notification::Notification,
    pending: Arc<Mutex<Option<(u64, Settings)>>>,
    wake: Option<mpsc::SyncSender<()>>,
    pub latest: Arc<Mutex<Option<SaveResult>>>,
    join: Option<thread::JoinHandle<()>>,
}
impl Writer {
    pub fn start(mut store: Store) -> Self {
        let pending = Arc::new(Mutex::new(None::<(u64, Settings)>));
        let requests = pending.clone();
        let latest = Arc::new(Mutex::new(None));
        let output = latest.clone();
        let notification = crate::notification::Notification::default();
        let published = notification.clone();
        let (wake, receiver) = mpsc::sync_channel(1);
        let join = thread::spawn(move || {
            let save = |request: Option<(u64, Settings)>, store: &mut Store| {
                if let Some((revision, settings)) = request {
                    *output.lock().unwrap() = Some((revision, store.save(&settings)));
                    published.notify();
                }
            };
            while receiver.recv().is_ok() {
                let request = requests.lock().unwrap().take();
                save(request, &mut store);
            }
            let request = requests.lock().unwrap().take();
            save(request, &mut store);
        });
        Self {
            notification,
            pending,
            wake: Some(wake),
            latest,
            join: Some(join),
        }
    }
    /// Wake a consumer after saving, without polling or holding a value lock.
    pub fn on_publish(&self, callback: impl Fn() + Send + Sync + 'static) {
        self.notification.set(callback);
    }
    pub fn queue(&self, revision: u64, settings: Settings) {
        *self.pending.lock().unwrap() = Some((revision, settings));
        if let Some(wake) = &self.wake {
            let _ = wake.try_send(());
        }
    }
}
impl Drop for Writer {
    fn drop(&mut self) {
        self.wake.take();
        if let Some(join) = self.join.take() {
            join.join().expect("Settings writer panicked");
        }
    }
}
