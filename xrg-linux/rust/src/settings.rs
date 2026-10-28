// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Versioned Linux presentation preferences. Paths are explicit for isolated tests.
mod window_size;
mod xtf;
use crate::{
    shared::{self, Theme},
    system_file,
};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    thread,
};
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
}
impl Module {
    pub const ALL: [Self; 13] = [
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
    /// None selects the aggregate; a number selects one logical CPU.
    pub cpu: Option<u32>,
    pub network: Option<String>,
    pub disk: Option<String>,
    /// Collector-provided identity, compared with inventory; never used as a path.
    pub gpu: Option<String>,
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
impl MetricSelection {
    pub fn validate(&self) -> Result<(), String> {
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
            Module::Cpu => self.cpu == other.cpu,
            Module::Network => self.network == other.network,
            Module::Disk => self.disk == other.disk,
            Module::Gpu | Module::GpuMemory => self.gpu == other.gpu,
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
            version: 19,
            theme: ThemeChoice::Builtin {
                name: "Classic".into(),
            },
            modules: Self::default_order()
                .into_iter()
                .map(|id| ModuleSetting {
                    id,
                    visible: !matches!(
                        id,
                        Module::Processes | Module::GpuMemory | Module::Fans | Module::Weather
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
        }
    }
}
impl Settings {
    pub fn default_order() -> [Module; 13] {
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
    pub fn validate(&self) -> Result<(), String> {
        if self.version != 19 {
            return Err("Unsupported settings version; the existing file will be kept".into());
        }
        if !(64..=240).contains(&self.graph_height) {
            return Err("Graph height must be between 64 and 240 pixels".into());
        }
        crate::sampling::interval(self.sampling_interval_ms)?;
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
                module.style = GraphStyle::Hollow;
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
        result.validate()?;
        Ok(result)
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
pub fn path_from(
    config_home: Option<&std::ffi::OsStr>,
    home: Option<&std::ffi::OsStr>,
) -> Option<PathBuf> {
    let config = config_home
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .filter(|p| p.is_absolute());
    let root = config.or_else(|| {
        home.map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .map(|p| p.join(".config"))
    })?;
    Some(root.join("xrg-ng/settings.conf"))
}
pub fn preferences_path() -> Option<PathBuf> {
    path_from(
        std::env::var_os("XDG_CONFIG_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
}
fn read_optional(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match system_file::read(path, LIMIT) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}
pub struct Store {
    path: Option<PathBuf>,
    expected: Option<Vec<u8>>,
    blocked: Option<String>,
}
impl Store {
    /// Invalid/unreadable files remain protected for this session. The UI may
    /// still apply changes in memory and can explain why persistence is unavailable.
    pub fn open(path: Option<PathBuf>) -> (Self, Settings, Option<String>) {
        let loaded = path
            .as_ref()
            .ok_or_else(|| "No configuration directory available".to_owned())
            .and_then(|p| read_optional(p));
        match loaded {
            Ok(expected) => match expected.as_deref().map(Settings::parse).transpose() {
                Ok(settings) => (
                    Self {
                        path,
                        expected,
                        blocked: None,
                    },
                    settings.unwrap_or_default(),
                    None,
                ),
                Err(error) => (
                    Self {
                        path,
                        expected,
                        blocked: Some(error.clone()),
                    },
                    Settings::default(),
                    Some(error),
                ),
            },
            Err(error) => (
                Self {
                    path,
                    expected: None,
                    blocked: Some(error.clone()),
                },
                Settings::default(),
                Some(error),
            ),
        }
    }
    pub fn save(&mut self, settings: &Settings) -> Result<(), String> {
        settings.validate()?;
        if let Some(error) = &self.blocked {
            return Err(error.clone());
        }
        let path = self
            .path
            .as_ref()
            .ok_or("No configuration directory available")?;
        let bytes = serde_json::to_vec_pretty(settings).map_err(|e| e.to_string())?;
        if read_optional(path)? != self.expected {
            return Err("Settings changed on disk; reopen the app before saving".into());
        }
        atomic_write(path, &bytes, true)?;
        self.expected = Some(bytes);
        Ok(())
    }
}
fn atomic_write(path: &Path, bytes: &[u8], create_parent: bool) -> Result<(), String> {
    if bytes.len() > LIMIT {
        return Err("Settings/theme file exceeds 128 KiB".into());
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
    for _ in 0..16 {
        let temporary = parent.join(format!(
            ".xrg-ng-{}-{}.tmp",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
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
        let result = file
            .write_all(bytes)
            .and_then(|_| file.sync_all())
            .and_then(|_| fs::rename(&temporary, path));
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        return result.map_err(|e| e.to_string());
    }
    Err("Could not create a unique settings temporary file".into())
}
/// One worker and one pending value bound save work while users change controls.
/// Results carry a revision so an old completion cannot mask a newer save error.
pub type SaveResult = (u64, Result<(), String>);
pub struct Writer {
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
        let (wake, receiver) = mpsc::sync_channel(1);
        let join = thread::spawn(move || {
            let save = |request: Option<(u64, Settings)>, store: &mut Store| {
                if let Some((revision, settings)) = request {
                    *output.lock().unwrap() = Some((revision, store.save(&settings)));
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
            pending,
            wake: Some(wake),
            latest,
            join: Some(join),
        }
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
