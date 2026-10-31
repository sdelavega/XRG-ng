// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
mod arm;
mod clients;
mod intel;
mod xe;
use crate::hardware::{self, Readings};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

/// The Linux implementation of the GPU collector (sysfs/DRM discovery, the
/// Intel perf and Xe ioctl native readers, and the NVIDIA query).
pub const IMPLEMENTATION: &str = "linux";

#[derive(Clone, Debug)]
pub struct EngineActivity {
    pub percent: f64,
    pub engines: Vec<(String, f64)>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivitySource {
    Device,
    Engines,
    Clients,
}
impl ActivitySource {
    pub fn suffix(self) -> &'static str {
        match self {
            Self::Device => "",
            Self::Engines => " PMU",
            Self::Clients => " clients",
        }
    }
}
#[derive(Clone, Debug, Default)]
pub struct Gpu {
    pub id: String,
    pub label: String,
    pub name: String,
    pub driver: String,
    pub utilization: Option<f64>,
    pub engine_activity: Option<EngineActivity>,
    pub memory_used: Option<u64>,
    pub memory_total: Option<u64>,
    pub client_activity: Option<f64>,
    pub client_resident_bytes: Option<u64>,
    pub visible_clients: Option<usize>,
    pub temperature: Option<f64>,
    pub power_watts: Option<f64>,
    pub frequency_mhz: Option<f64>,
    pub fan_rpm: Option<u64>,
    pub fan_percent: Option<f64>,
    pub notes: Vec<String>,
}
impl Gpu {
    pub fn activity(&self) -> Option<(ActivitySource, f64)> {
        self.utilization
            .filter(|v| v.is_finite() && (0.0..=100.0).contains(v))
            .map(|v| (ActivitySource::Device, v))
            .or_else(|| {
                self.engine_activity
                    .as_ref()
                    .filter(|v| v.percent.is_finite() && (0.0..=100.0).contains(&v.percent))
                    .map(|v| (ActivitySource::Engines, v.percent))
            })
            .or_else(|| {
                self.client_activity
                    .filter(|v| v.is_finite() && (0.0..=100.0).contains(v))
                    .map(|v| (ActivitySource::Clients, v))
            })
    }
}
struct Device {
    gpu: Gpu,
    path: PathBuf,
    card: Option<PathBuf>,
    suspended: bool,
    vendor: String,
    nodes: BTreeSet<String>,
    metrics_paths: Vec<PathBuf>,
}

pub fn pci_id(value: &str) -> Option<String> {
    let fields: Vec<_> = value.trim().split([':', '.']).collect();
    if fields.len() != 4
        || fields
            .iter()
            .any(|s| s.is_empty() || !s.bytes().all(|c| c.is_ascii_hexdigit()))
    {
        return None;
    }
    let domain = u32::from_str_radix(fields[0], 16).ok()?;
    let bus = u8::from_str_radix(fields[1], 16).ok()?;
    let device = u8::from_str_radix(fields[2], 16).ok()?;
    let function = u8::from_str_radix(fields[3], 16).ok()?;
    if device > 31 || function > 7 {
        return None;
    }
    Some(format!("{domain:04x}:{bus:02x}:{device:02x}.{function}"))
}
fn driver(path: &Path) -> Result<String, String> {
    match fs::read_link(path.join("driver")) {
        Ok(link) => Ok(link
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok("unbound".into()),
        Err(e) => Err(e.to_string()),
    }
}
fn device(path: PathBuf, card: Option<PathBuf>, vendor: &str) -> Result<Device, String> {
    let path = fs::canonicalize(path).map_err(|e| e.to_string())?;
    let basename = path.file_name().unwrap_or_default().to_string_lossy();
    let id = pci_id(&basename).unwrap_or_else(|| path.to_string_lossy().into_owned());
    let driver = driver(&path)?;
    let vendor_name = match vendor {
        "0x1002" => "AMD",
        "0x8086" => "Intel",
        "0x10de" => "NVIDIA",
        _ => arm::family(&driver).map(|f| f.name()).unwrap_or("GPU"),
    };
    let name = hardware::text(&path.join("product_name"))?
        .map(|s| hardware::short_label(&s))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            let compatible = hardware::text(&path.join("of_node/compatible"))
                .ok()
                .flatten()
                .and_then(|s| {
                    s.split('\0')
                        .find(|s| !s.is_empty())
                        .map(hardware::short_label)
                });
            compatible
                .filter(|_| vendor.is_empty())
                .map(|s| format!("{vendor_name} · {s}"))
                .unwrap_or_else(|| format!("{vendor_name} ({driver})"))
        });
    let label = card
        .as_ref()
        .and_then(|p| p.file_name())
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| basename.into_owned());
    let suspended =
        hardware::text(&path.join("power/runtime_status"))?.as_deref() == Some("suspended");
    let nodes = card
        .as_ref()
        .and_then(|p| p.file_name())
        .map(|n| n.to_string_lossy().into_owned())
        .into_iter()
        .collect();
    let metrics_paths = vec![path.clone()];
    Ok(Device {
        nodes,
        metrics_paths,
        gpu: Gpu {
            id,
            label,
            name,
            driver,
            ..Gpu::default()
        },
        path,
        card,
        suspended,
        vendor: vendor.to_owned(),
    })
}
fn insert_device(devices: &mut BTreeMap<String, Device>, incoming: Device) {
    if let Some(existing) = devices.get_mut(&incoming.gpu.id) {
        existing.nodes.extend(incoming.nodes);
        for path in incoming.metrics_paths {
            if !existing.metrics_paths.contains(&path) {
                existing.metrics_paths.push(path);
            }
        }
    } else {
        devices.insert(incoming.gpu.id.clone(), incoming);
    }
}
fn drm_node(name: &str) -> bool {
    name.strip_prefix("card")
        .or_else(|| name.strip_prefix("renderD"))
        .is_some_and(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
}
fn discover(sys: &Path) -> Result<(Vec<Device>, Vec<String>), String> {
    let mut devices = BTreeMap::new();
    let mut errors = Vec::new();
    for card in hardware::directories(&sys.join("class/drm"))? {
        let name = card.file_name().unwrap_or_default().to_string_lossy();
        if !drm_node(&name) {
            continue;
        }
        let path = card.join("device");
        let read = || -> Result<Option<Device>, String> {
            let vendor = hardware::text(&path.join("vendor"))?
                .unwrap_or_default()
                .to_ascii_lowercase();
            if vendor.is_empty() && arm::family(&driver(&path)?).is_none() {
                return Ok(None);
            }
            device(path.clone(), Some(card.clone()), &vendor).map(Some)
        };
        match read() {
            Ok(Some(device)) => {
                insert_device(&mut devices, device);
            }
            Ok(None) => (),
            Err(e) => errors.push(format!("{name}: {e}")),
        }
    }
    // Compute-only NVIDIA installations may have no DRM primary node. The PCI
    // driver's actual binding is the gate; vendor identity alone never runs SMI.
    for path in hardware::directories(&sys.join("bus/pci/devices"))? {
        if driver(&path).ok().as_deref() != Some("nvidia") {
            continue;
        }
        match hardware::text(&path.join("vendor")) {
            Ok(Some(vendor)) if vendor.eq_ignore_ascii_case("0x10de") => {
                match device(path, None, "0x10de") {
                    Ok(device) => {
                        insert_device(&mut devices, device);
                    }
                    Err(e) => errors.push(e),
                }
            }
            Err(e) => errors.push(e),
            _ => (),
        }
    }
    arm::discover(sys, &mut devices, &mut errors);
    Ok((devices.into_values().collect(), errors))
}
fn unsigned(path: &Path, notes: &mut Vec<String>) -> Option<u64> {
    match hardware::integer(path) {
        Ok(Some(value)) if value >= 0 => Some(value as u64),
        Ok(None) => None,
        _ => {
            notes.push(format!(
                "Invalid or unreadable {}",
                path.file_name().unwrap_or_default().to_string_lossy()
            ));
            None
        }
    }
}
fn percent(value: Option<u64>, field: &str, notes: &mut Vec<String>) -> Option<f64> {
    match value {
        Some(v) if v <= 100 => Some(v as f64),
        Some(_) => {
            notes.push(format!("Invalid {field}"));
            None
        }
        None => None,
    }
}
fn validate_memory(gpu: &mut Gpu) {
    if gpu.memory_total == Some(0)
        || matches!((gpu.memory_used, gpu.memory_total), (Some(a), Some(b)) if a > b)
    {
        gpu.notes.push("Invalid VRAM counters".into());
        gpu.memory_used = None;
        gpu.memory_total = None;
    }
}
fn sysfs_metrics(device: &mut Device) {
    let gpu = &mut device.gpu;
    if gpu.driver == "amdgpu" {
        let busy = unsigned(&device.path.join("gpu_busy_percent"), &mut gpu.notes);
        gpu.utilization = percent(busy, "GPU utilization", &mut gpu.notes);
        gpu.memory_used = unsigned(&device.path.join("mem_info_vram_used"), &mut gpu.notes);
        gpu.memory_total = unsigned(&device.path.join("mem_info_vram_total"), &mut gpu.notes);
        validate_memory(gpu);
    }
    if gpu.driver == "i915"
        && let Some(card) = &device.card
    {
        gpu.frequency_mhz = unsigned(&card.join("gt_cur_freq_mhz"), &mut gpu.notes)
            .map(|v| v as f64)
            .or_else(|| {
                unsigned(&card.join("gt/gt0/rps_cur_freq_mhz"), &mut gpu.notes).map(|v| v as f64)
            });
    }
    // i915/xe clocks are not utilization. No fabricated idle percentage or
    // frequency-based busy estimate is emitted for unsupported driver counters.
    match hardware::directories(&device.path.join("hwmon")) {
        Err(e) => gpu.notes.push(e),
        Ok(paths) => {
            for path in paths {
                match hardware::temperature::read(&path, "1") {
                    Ok(Some(value)) => gpu.temperature = Some(value.celsius),
                    Ok(None) => (),
                    Err(error) => gpu.notes.push(error),
                }
                gpu.power_watts = unsigned(&path.join("power1_average"), &mut gpu.notes)
                    .or_else(|| unsigned(&path.join("power1_input"), &mut gpu.notes))
                    .map(|v| v as f64 / 1_000_000.)
                    .or(gpu.power_watts);
                gpu.frequency_mhz = gpu.frequency_mhz.or_else(|| {
                    unsigned(&path.join("freq1_input"), &mut gpu.notes)
                        .map(|v| v as f64 / 1_000_000.)
                });
                gpu.fan_rpm = unsigned(&path.join("fan1_input"), &mut gpu.notes).or(gpu.fan_rpm);
            }
        }
    }
}
fn csv_row(line: &str) -> Result<Vec<String>, String> {
    let mut chars = line.chars().peekable();
    let mut fields = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut closed = false;
    while let Some(c) = chars.next() {
        if quoted {
            if c == '"' {
                if chars.peek() == Some(&'"') {
                    chars.next();
                    field.push('"');
                } else {
                    quoted = false;
                    closed = true;
                }
            } else {
                field.push(c);
            }
        } else if c == ',' {
            fields.push(field.trim().to_owned());
            field.clear();
            closed = false;
        } else if c == '"' && field.trim().is_empty() && !closed {
            field.clear();
            quoted = true;
        } else if c == '"' || (closed && !c.is_whitespace()) {
            return Err("Malformed NVIDIA CSV quoting".into());
        } else {
            field.push(c);
        }
    }
    if quoted {
        return Err("Unterminated NVIDIA CSV field".into());
    }
    fields.push(field.trim().to_owned());
    Ok(fields)
}
fn optional_number(value: &str, name: &str, max: f64, notes: &mut Vec<String>) -> Option<f64> {
    if matches!(value, "N/A" | "[N/A]" | "[Not Supported]" | "Not Supported") {
        return None;
    }
    match value.parse::<f64>() {
        Ok(v) if v.is_finite() && v >= 0. && v <= max => Some(v),
        _ => {
            notes.push(format!("Invalid NVIDIA {name}"));
            None
        }
    }
}
pub fn parse_nvidia(text: &str) -> Readings<Gpu> {
    let mut report = Readings {
        values: Vec::new(),
        errors: Vec::new(),
    };
    let mut seen = BTreeSet::new();
    let mut duplicates = BTreeSet::new();
    for line in text.lines().filter(|s| !s.trim().is_empty()) {
        let read = || -> Result<Gpu, String> {
            let fields = csv_row(line)?;
            if fields.len() != 9 {
                return Err("Expected nine NVIDIA query fields".into());
            }
            let id = pci_id(&fields[0]).ok_or("Invalid NVIDIA PCI address")?;
            let mut gpu = Gpu {
                id,
                name: hardware::short_label(&fields[1]),
                driver: "nvidia".into(),
                ..Gpu::default()
            };
            gpu.utilization = optional_number(&fields[2], "utilization", 100., &mut gpu.notes);
            let mib = |text: &str, notes: &mut Vec<String>| -> Option<u64> {
                if matches!(text, "N/A" | "[N/A]" | "[Not Supported]" | "Not Supported") {
                    return None;
                }
                match text
                    .parse::<u64>()
                    .ok()
                    .and_then(|n| n.checked_mul(1_048_576))
                {
                    Some(value) => Some(value),
                    None => {
                        notes.push("Invalid NVIDIA memory value".into());
                        None
                    }
                }
            };
            gpu.memory_used = mib(&fields[3], &mut gpu.notes);
            gpu.memory_total = mib(&fields[4], &mut gpu.notes);
            validate_memory(&mut gpu);
            gpu.temperature = optional_number(&fields[5], "temperature", 1000., &mut gpu.notes);
            gpu.power_watts = optional_number(&fields[6], "power", f64::MAX, &mut gpu.notes);
            gpu.fan_percent = optional_number(&fields[7], "fan percentage", 100., &mut gpu.notes);
            gpu.frequency_mhz = optional_number(&fields[8], "clock", f64::MAX, &mut gpu.notes);
            Ok(gpu)
        };
        match read() {
            Ok(gpu) if seen.insert(gpu.id.clone()) => report.values.push(gpu),
            Ok(gpu) => {
                duplicates.insert(gpu.id);
                report.errors.push("Duplicate NVIDIA PCI address".into());
            }
            Err(e) => report.errors.push(e),
        }
    }
    report.values.retain(|gpu| !duplicates.contains(&gpu.id));
    report
}

pub fn find_nvidia_smi() -> Option<PathBuf> {
    let paths = std::env::var_os("PATH")?;
    std::env::split_paths(&paths)
        .filter(|path| path.is_absolute())
        .map(|p| p.join("nvidia-smi"))
        .find(|p| p.is_file())
}
pub struct GpuCollector {
    sys: PathBuf,
    program: Option<PathBuf>,
    retry_at: Instant,
    last_error: String,
    #[cfg(unix)]
    command: crate::command::BoundedCommand,
    arm: arm::ArmCollector,
    intel: intel::Collector,
    xe: xe::Collector,
    proc: Option<PathBuf>,
    clients: clients::ClientCollector,
}
impl GpuCollector {
    /// Custom roots do not execute commands unless a program is explicitly supplied.
    pub fn new(sys: impl Into<PathBuf>, nvidia_program: Option<PathBuf>) -> Self {
        let sys = sys.into();
        let intel = intel::Collector::new(&sys);
        let xe = xe::Collector::new(&sys);
        Self {
            sys,
            intel,
            xe,
            program: nvidia_program,
            retry_at: Instant::now(),
            last_error: String::new(),
            #[cfg(unix)]
            command: crate::command::BoundedCommand::default(),
            arm: arm::ArmCollector,
            proc: None,
            clients: clients::ClientCollector::default(),
        }
    }
    pub fn set_xe_pmu(&mut self, enabled: bool) {
        self.xe.set_enabled(enabled);
    }
    pub fn with_proc_root(mut self, proc: impl Into<PathBuf>) -> Self {
        self.proc = Some(proc.into());
        self
    }
    pub fn sample(&mut self) -> Result<Readings<Gpu>, String> {
        self.sample_at(Instant::now())
    }
    pub fn sample_at(&mut self, time: Instant) -> Result<Readings<Gpu>, String> {
        let (mut devices, mut errors) = match discover(&self.sys) {
            Ok(value) => value,
            Err(error) => {
                self.intel.clear();
                self.xe.clear();
                self.clients.clear();
                return Err(error);
            }
        };
        let mut ids = Vec::new();
        for device in &mut devices {
            if device.suspended {
                device
                    .gpu
                    .notes
                    .push("Runtime suspended; telemetry not requested".into());
                continue;
            }
            if device.vendor == "0x10de" && device.gpu.driver == "nvidia" {
                if pci_id(&device.gpu.id).is_some() {
                    ids.push(device.gpu.id.clone());
                } else {
                    device
                        .gpu
                        .notes
                        .push("NVIDIA device has no usable PCI identity".into());
                }
            } else if matches!(
                (device.vendor.as_str(), device.gpu.driver.as_str()),
                ("0x1002", "amdgpu") | ("0x8086", "i915" | "xe")
            ) {
                sysfs_metrics(device);
            } else if arm::family(&device.gpu.driver).is_none() {
                device
                    .gpu
                    .notes
                    .push("Telemetry unsupported for this driver".into());
            }
        }
        self.arm.collect(&self.sys, &mut devices);
        if let Some(proc) = &self.proc {
            self.clients.collect(proc, &mut devices, time);
        }
        self.intel.collect(&self.sys, &mut devices, time);
        self.xe.collect(&self.sys, &mut devices, time);
        if !ids.is_empty() {
            let response = self.nvidia(&ids);
            match response {
                Ok(text) => {
                    let report = parse_nvidia(&text);
                    errors.extend(report.errors);
                    let mut readings: BTreeMap<_, _> = report
                        .values
                        .into_iter()
                        .map(|g| (g.id.clone(), g))
                        .collect();
                    for device in &mut devices {
                        if !ids.contains(&device.gpu.id) {
                            continue;
                        }
                        if let Some(mut gpu) = readings.remove(&device.gpu.id) {
                            gpu.label = device.gpu.label.clone();
                            device.gpu = gpu;
                        } else {
                            device
                                .gpu
                                .notes
                                .push("NVIDIA query returned no matching device".into());
                        }
                    }
                }
                Err(error) => {
                    for device in &mut devices {
                        if ids.contains(&device.gpu.id) {
                            device.gpu.notes.push(error.clone());
                        }
                    }
                }
            }
        }
        Ok(Readings {
            values: devices.into_iter().map(|d| d.gpu).collect(),
            errors,
        })
    }
    fn nvidia(&mut self, ids: &[String]) -> Result<String, String> {
        if Instant::now() < self.retry_at {
            return Err(self.last_error.clone());
        }
        let Some(program) = &self.program else {
            return Err("nvidia-smi not available".into());
        };
        let selector = format!("--id={}", ids.join(","));
        let args = [
            "--query-gpu=pci.bus_id,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,fan.speed,clocks.current.graphics",
            "--format=csv,noheader,nounits",
            &selector,
        ];
        #[cfg(unix)]
        let result = self
            .command
            .output(program, &args, Duration::from_millis(750), 65_536)
            .and_then(|bytes| {
                String::from_utf8(bytes).map_err(|_| "Invalid NVIDIA output encoding".into())
            });
        #[cfg(not(unix))]
        let result: Result<String, String> = Err("NVIDIA query requires Unix".into());
        if let Err(error) = &result {
            self.last_error = error.clone();
            self.retry_at = Instant::now() + Duration::from_secs(30);
        }
        result
    }
}
