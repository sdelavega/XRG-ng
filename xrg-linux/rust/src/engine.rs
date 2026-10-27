// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::{collectors::LinuxSources, settings::MetricSelection, shared::History};
use std::{
    array,
    collections::BTreeMap,
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Debug)]
pub struct Panel {
    pub title: &'static str,
    pub label: String,
    pub series: Vec<Vec<f64>>,
    pub scale: Scale,
    pub detail: String,
}
/// Temperature uses a signed range; missing data is represented by no series.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Scale {
    Percent,
    Automatic,
    Celsius,
}
impl Scale {
    pub fn bounds(self, series: &[Vec<f64>]) -> (f64, f64) {
        match self {
            Self::Percent => (0., 100.),
            Self::Automatic => (
                0.,
                series.iter().flatten().copied().fold(1.0, f64::max) * 1.1,
            ),
            Self::Celsius => {
                let min = series.iter().flatten().copied().fold(0.0, f64::min);
                let max = series.iter().flatten().copied().fold(120.0, f64::max);
                ((min / 10.).floor() * 10., (max / 10.).ceil() * 10.)
            }
        }
    }
}
#[derive(Clone, Debug)]
pub struct Snapshot {
    pub sequence: u64,
    pub panels: Vec<Panel>,
    pub valid: bool,
    pub selection: MetricSelection,
    pub inventory: crate::metrics::Inventory,
    pub processes: Result<Arc<crate::process::Report>, String>,
}
pub struct Sampler {
    source: LinuxSources,
    ai: Option<crate::ai::Worker>,
    ai_panel: Panel,
    process: crate::process::Collector,
    process_histories: [History; 2],
    tpu: crate::tpu::Collector,
    tpu_history: History,
    metrics: crate::metrics::Sampler,
    memory_history: History,
    temperature_history: History,
    inventory: crate::metrics::Inventory,
    process_report: Result<Arc<crate::process::Report>, String>,
    battery_histories: BTreeMap<String, History>,
    fan_histories: BTreeMap<String, History>,
    gpu: crate::gpu::GpuCollector,
    gpu_memory: crate::gpu_memory::View,
    gpu_histories: BTreeMap<String, (bool, History)>,
    start: Instant,
    sequence: u64,
}
impl Sampler {
    pub fn new() -> Self {
        Self::live(true)
    }
    pub fn live(ai_enabled: bool) -> Self {
        let mut sampler = Self::with_sources(LinuxSources::live());
        if ai_enabled {
            sampler.ai = crate::ai::Config::live().map(crate::ai::Worker::start);
        }
        sampler
    }
    pub fn with_sources(source: LinuxSources) -> Self {
        let gpu = source.gpu_collector();
        let process = source.process_collector();
        let tpu = source.tpu_collector();
        Self {
            source,
            ai: None,
            ai_panel: crate::ai::waiting(),
            gpu,
            process,
            process_histories: array::from_fn(|_| History::new(120)),
            tpu,
            tpu_history: History::new(120),
            gpu_histories: BTreeMap::new(),
            gpu_memory: crate::gpu_memory::View::default(),
            metrics: crate::metrics::Sampler::default(),
            memory_history: History::new(120),
            temperature_history: History::new(120),
            inventory: crate::metrics::Inventory::default(),
            process_report: Err("Waiting for process sample".into()),
            battery_histories: BTreeMap::new(),
            fan_histories: BTreeMap::new(),
            start: Instant::now(),
            sequence: 0,
        }
    }
    pub fn set_selection(&mut self, selection: MetricSelection) -> Result<(), String> {
        selection.validate()?;
        if self.metrics.selection().gpu != selection.gpu {
            self.gpu_histories.clear();
            self.gpu_memory.reset();
        }
        self.metrics.set_selection(selection)
    }
    pub fn sample(&mut self) -> Snapshot {
        let time = self.start.elapsed().as_secs_f64();
        let metrics = self.metrics.sample(&self.source, time);
        self.inventory = metrics.inventory;
        let memory = self.source.memory();
        let valid = metrics.valid && memory.is_ok();
        let mut series = Vec::new();
        let label = match memory {
            Ok(value) => {
                self.memory_history.append(value);
                series.push(self.memory_history.values());
                format!("{value:.1}%")
            }
            Err(error) => error,
        };
        let memory = Panel {
            title: "Memory",
            detail: label.clone(),
            label,
            series,
            scale: Scale::Percent,
        };
        let mut panels = vec![metrics.cpu, memory, metrics.network, metrics.disk];
        panels.push(self.battery_panel());
        panels.push(self.temperature_panel());
        let (gpu, vram) = self.gpu_panels();
        panels.push(gpu);
        if let Some(ai) = &self.ai
            && let Some(panel) = ai.latest.lock().unwrap().take()
        {
            self.ai_panel = panel;
        }
        panels.push(self.ai_panel.clone());
        panels.push(self.process_panel());
        panels.push(self.tpu_panel());
        panels.push(vram);
        panels.push(self.fan_panel());
        self.sequence += 1;
        Snapshot {
            sequence: self.sequence,
            panels,
            valid,
            selection: self.metrics.selection().clone(),
            inventory: self.inventory.clone(),
            processes: self.process_report.clone(),
        }
    }
    fn process_panel(&mut self) -> Panel {
        let mut series = Vec::new();
        self.process_report = self.process.sample().map(Arc::new);
        let (label, detail) = match &self.process_report {
            Err(error) => ("Processes unavailable".into(), error.clone()),
            Ok(report) => {
                let count = report.processes.len();
                let running = report.processes.iter().filter(|p| p.state == 'R').count();
                let mut details = vec![format!("{} PID directories discovered; {} attempted; {count} readable; {running} running; {} vanished; {} unreadable. Counts/rankings cover this scan's readable processes in the current PID namespace. Graph: readable / running counts.",report.discovered,report.attempted,report.vanished,report.unreadable), "CPU: 100% is one core; multi-threaded processes may exceed 100%. First/new/reused PID samples wait for an interval. RSS is approximate and may include shared pages; it is never summed into system memory usage. Names come from stat; arguments and environments are not read.".into()];
                for (title, sort) in [
                    ("Top CPU", crate::process::Sort::Cpu),
                    ("Top RSS", crate::process::Sort::Memory),
                ] {
                    details.push(title.into());
                    for process in report.ranked(sort, None, "", 10) {
                        let cpu = process
                            .cpu_percent
                            .map(|v| format!("{v:.1}% CPU"))
                            .unwrap_or_else(|| "CPU waiting for interval".into());
                        let memory = process
                            .memory_percent
                            .map(|v| format!(" · {v:.1}% memory"))
                            .unwrap_or_default();
                        let uid = process
                            .uid
                            .map(|u| u.to_string())
                            .unwrap_or_else(|| "unknown".into());
                        details.push(format!("{} · PID {} · UID {uid} · {cpu} · {:.1} MiB RSS{memory} · {} threads · state {} · nice {}",process.name,process.pid,process.rss_bytes as f64 / 1_048_576.,process.threads,process.state,process.nice));
                    }
                }
                let label = if count == 0 {
                    "No readable processes".into()
                } else {
                    self.process_histories[0].append(count as f64);
                    self.process_histories[1].append(running as f64);
                    series = self.process_histories.iter().map(History::values).collect();
                    format!(
                        "{count} readable · {running} running{}",
                        if report.partial() { " · partial" } else { "" }
                    )
                };
                details.extend(report.errors.clone());
                (label, details.join("\n"))
            }
        };
        Panel {
            title: "Processes",
            label,
            detail,
            series,
            scale: Scale::Automatic,
        }
    }
    fn tpu_panel(&mut self) -> Panel {
        let report = self.tpu.sample();
        let mut details = vec!["Coral discovery is read-only and does not prove the device can run inference. Graph: observed producer-counter change per second, not TPU utilization. Producer statistics are unscoped and are not assigned to individual adapters.".into()];
        let mut devices = 0;
        let detection_error;
        match report.devices {
            Err(error) => {
                detection_error = true;
                details.push(error);
            }
            Ok(readings) => {
                devices = readings.values.len();
                detection_error = !readings.errors.is_empty();
                for device in readings.values {
                    let state = if device.suspended {
                        "suspended; telemetry deferred"
                    } else if device.initialized {
                        "runtime USB ID / bound apex driver detected; inference capability unverified"
                    } else {
                        "USB firmware or PCIe driver not initialized"
                    };
                    let temp = device
                        .temperature_c
                        .map(|v| format!(" · {v:.1} °C"))
                        .unwrap_or_default();
                    details.push(format!("{} · {state}{temp}\n{}", device.label, device.id));
                }
                details.extend(readings.errors);
            }
        }
        let mut series = Vec::new();
        let label = match report.inference {
            Err(error) => {
                details.push(error);
                if devices > 0 {
                    format!("{devices} Coral detected · statistics unavailable")
                } else if detection_error {
                    "TPU discovery/statistics unavailable".into()
                } else {
                    "No Coral / no fresh producer statistics".into()
                }
            }
            Ok(inference) => {
                let stats = inference.stats;
                details.push(format!(
                    "Producer total: {} · report age {:.1} s",
                    stats.total_inferences, inference.age_seconds
                ));
                if let Some(model) = stats.model_name {
                    details.push(format!("Model: {model}"));
                }
                if let Some(v) = stats.last_latency_ms {
                    details.push(format!("Last reported latency: {v:.2} ms"));
                }
                if let Some(v) = stats.avg_latency_ms {
                    details.push(format!("Average reported latency: {v:.2} ms"));
                }
                if let Some(v) = stats.temperature {
                    details.push(format!(
                        "Producer-reported temperature: {v:.1} °C (unscoped)"
                    ));
                }
                if let Some(c) = stats.by_category {
                    details.push(format!("Reported categories: direct {} · hooked {} · logged {} · warming {} (not assumed exclusive)",c.direct.map_or_else(|| "unavailable".into(), |v|v.to_string()), c.hooked.map_or_else(|| "unavailable".into(), |v|v.to_string()), c.logged.map_or_else(|| "unavailable".into(), |v|v.to_string()), c.warming.map_or_else(|| "unavailable".into(), |v|v.to_string())));
                }
                let rate = if let Some(rate) = inference.rate {
                    self.tpu_history.append(rate);
                    series.push(self.tpu_history.values());
                    format!("{rate:.1} inf/s")
                } else {
                    "Waiting for inference interval".into()
                };
                if devices == 0 {
                    format!("{rate} · hardware unverified")
                } else {
                    format!(
                        "{rate} · {devices} Coral{}",
                        if detection_error { " · partial" } else { "" }
                    )
                }
            }
        };
        Panel {
            title: "TPU",
            label,
            detail: details.join("\n\n"),
            series,
            scale: Scale::Automatic,
        }
    }
    fn gpu_panels(&mut self) -> (Panel, Panel) {
        let mut series = Vec::new();
        let mut result = self.gpu.sample();
        self.inventory.gpus.clear();
        if let Ok(report) = &mut result {
            self.inventory.gpus = report
                .values
                .iter()
                .map(|gpu| crate::metrics::GpuOption {
                    id: gpu.id.clone(),
                    label: format!(
                        "{} · {}",
                        gpu.label,
                        crate::hardware::short_label(&gpu.name)
                    ),
                })
                .collect();
            if let Some(selected) = &self.metrics.selection().gpu {
                report.values.retain(|gpu| gpu.id == *selected);
                if report.values.is_empty() {
                    self.gpu_histories.clear();
                    let unavailable = "Selected GPU unavailable".to_owned();
                    let vram = self.gpu_memory.panel(&Err(unavailable));
                    return (
                        Panel {
                            title: "GPU",
                            label: "Selected GPU unavailable".into(),
                            detail: format!(
                                "GPU identity {selected} was not present in the latest sample.\n{}",
                                report.errors.join("\n")
                            ),
                            series,
                            scale: Scale::Percent,
                        },
                        vram,
                    );
                }
            }
        }

        let vram = self.gpu_memory.panel(&result);
        let (label, detail) = match result {
            Err(error) => ("GPU unavailable".into(), error),
            Ok(report) if report.values.is_empty() => {
                if report.errors.is_empty() {
                    self.gpu_histories.clear();
                    (
                        "No GPU detected".into(),
                        "No supported GPU adapter detected".into(),
                    )
                } else {
                    ("GPU unavailable".into(), report.errors.join("\n"))
                }
            }
            Ok(report) => {
                self.gpu_histories
                    .retain(|id, _| report.values.iter().any(|v| v.id == *id));
                let mut labels = Vec::new();
                let mut details = Vec::new();
                let supported: Vec<_> = report
                    .values
                    .iter()
                    .filter(|g| g.utilization.or(g.client_activity).is_some())
                    .collect();
                let partial =
                    !report.errors.is_empty() || report.values.iter().any(|g| !g.notes.is_empty());
                for gpu in supported.iter().take(3) {
                    let value = gpu
                        .utilization
                        .or(gpu.client_activity)
                        .expect("filtered activity");
                    let device_counter = gpu.utilization.is_some();
                    let history = self
                        .gpu_histories
                        .entry(gpu.id.clone())
                        .or_insert_with(|| (device_counter, History::new(120)));
                    if history.0 != device_counter {
                        *history = (device_counter, History::new(120));
                    }
                    history.1.append(value);
                    series.push(history.1.values());
                    labels.push(format!(
                        "{} {value:.0}%{}",
                        gpu.label,
                        if device_counter { "" } else { " clients" }
                    ));
                }
                for gpu in &report.values {
                    let mut fields = vec![
                        format!("{} · {} · {}", gpu.label, gpu.name, gpu.id),
                        format!("Driver: {}", gpu.driver),
                        gpu.utilization
                            .map(|v| format!("Utilization: {v:.1}%"))
                            .unwrap_or_else(|| "Device-wide utilization unavailable".into()),
                    ];
                    if let Some(value) = gpu.client_activity {
                        fields.push(format!(
                            "Readable-client busiest-engine activity: {value:.1}%"
                        ));
                    }
                    if let Some(count) = gpu.visible_clients {
                        fields.push(format!("Readable DRM clients: {count}"));
                    }
                    if let Some(value) = gpu.client_resident_bytes {
                        fields.push(format!("Readable-client resident allocations: {:.1} MiB (shared buffers may count per client)", value as f64 / 1_048_576.));
                    }
                    if let Some(value) = gpu.memory_used {
                        fields.push(format!("VRAM used: {:.1} MiB", value as f64 / 1_048_576.));
                    }
                    if let Some(value) = gpu.memory_total {
                        fields.push(format!("VRAM total: {:.1} MiB", value as f64 / 1_048_576.));
                    }
                    if let Some(value) = gpu.temperature {
                        fields.push(format!("Temperature: {value:.1} °C"));
                    }
                    if let Some(value) = gpu.frequency_mhz {
                        fields.push(format!("Reported clock: {value:.0} MHz"));
                    }
                    if let Some(value) = gpu.power_watts {
                        fields.push(format!("Reported power: {value:.1} W (may include SoC)"));
                    }
                    if let Some(value) = gpu.fan_rpm {
                        fields.push(format!("Fan: {value} RPM"));
                    }
                    if let Some(value) = gpu.fan_percent {
                        fields.push(format!("Fan: {value:.0}%"));
                    }
                    fields.extend(gpu.notes.clone());
                    details.push(fields.join("\n"));
                }
                details.extend(report.errors);
                let label = if labels.is_empty() {
                    "GPU utilization unavailable".into()
                } else {
                    format!(
                        "{}{}{}",
                        labels.join(" / "),
                        if supported.len() > 3 { " (+more)" } else { "" },
                        if partial { " · partial" } else { "" }
                    )
                };
                (label, details.join("\n\n"))
            }
        };
        (
            Panel {
                title: "GPU",
                label,
                detail,
                series,
                scale: Scale::Percent,
            },
            vram,
        )
    }

    fn fan_panel(&mut self) -> Panel {
        let mut panel = Panel {
            title: "Fans", label: "No readable fan sensors".into(), series: Vec::new(),
            detail: "Read-only hwmon fan RPM. Zero can mean a stopped fan; PWM duty is not RPM. Channel labels come from the driver and do not establish CPU/GPU ownership.".into(),
            scale: Scale::Automatic,
        };
        match crate::hardware::fans(self.source.sys_root()) {
            Err(error) => {
                self.fan_histories.clear();
                panel.label = "Fan readings unavailable".into();
                panel.detail.push_str(&format!("\n{error}"));
            }
            Ok(report) => {
                let visible: Vec<_> = report.values.iter().take(3).collect();
                self.fan_histories
                    .retain(|id, _| visible.iter().any(|fan| fan.id == *id));
                let mut labels = Vec::new();
                for fan in visible {
                    let history = self
                        .fan_histories
                        .entry(fan.id.clone())
                        .or_insert_with(|| History::new(120));
                    history.append(fan.rpm as f64);
                    panel.series.push(history.values());
                    labels.push(format!(
                        "{} {} RPM{}",
                        fan.name,
                        fan.rpm,
                        if fan.alarm == Some(true) {
                            " · alarm"
                        } else {
                            ""
                        }
                    ));
                }
                if !labels.is_empty() {
                    panel.label = labels.join(" / ");
                } else if !report.errors.is_empty() {
                    panel.label = "Fan readings unavailable".into();
                }
                if report.values.len() > 3 {
                    panel.label.push_str(" (+more)");
                }
                if !report.errors.is_empty() || report.values.iter().any(|f| !f.notes.is_empty()) {
                    panel.label.push_str(" · partial");
                }
                for fan in report.values.iter().take(64) {
                    panel.detail.push_str(&format!(
                        "\n{}: {} RPM{}",
                        fan.name,
                        fan.rpm,
                        match fan.alarm {
                            Some(true) => " · driver alarm active",
                            Some(false) => " · driver alarm clear",
                            None => "",
                        }
                    ));
                    for note in &fan.notes {
                        panel.detail.push_str(&format!("\n{note}"));
                    }
                }
                if report.values.len() > 64 {
                    panel.detail.push_str("\nAdditional fan details omitted");
                }
                for error in report.errors {
                    panel.detail.push_str(&format!("\n{error}"));
                }
            }
        }
        panel
    }
    fn battery_panel(&mut self) -> Panel {
        let mut series = Vec::new();
        let (label, detail) = match self.source.battery() {
            Err(error) => ("Battery unavailable".into(), error),
            Ok(report) if report.values.is_empty() => {
                if report.errors.is_empty() {
                    self.battery_histories.clear();
                    (
                        "No system battery".into(),
                        "No present system battery detected".into(),
                    )
                } else {
                    ("Battery unavailable".into(), report.errors.join("\n"))
                }
            }
            Ok(report) => {
                let visible: Vec<_> = report.values.iter().take(3).collect();
                self.battery_histories
                    .retain(|name, _| visible.iter().any(|v| v.name == *name));
                let mut labels = Vec::new();
                for reading in visible {
                    let history = self
                        .battery_histories
                        .entry(reading.name.clone())
                        .or_insert_with(|| History::new(120));
                    history.append(reading.percent);
                    series.push(history.values());
                    labels.push(format!("{} {:.0}%", reading.name, reading.percent));
                }
                let mut label = labels.join(" / ");
                if report.values.len() > 3 {
                    label.push_str(&format!(" (+{})", report.values.len() - 3));
                }
                if !report.errors.is_empty() || report.values.iter().any(|v| !v.notes.is_empty()) {
                    label.push_str(" · partial");
                }
                let mut detail: Vec<_> = report
                    .values
                    .iter()
                    .map(crate::hardware::Battery::description)
                    .collect();
                detail.extend(report.errors);
                (label, detail.join("\n"))
            }
        };
        Panel {
            title: "Battery",
            label,
            detail,
            series,
            scale: Scale::Percent,
        }
    }
    fn temperature_panel(&mut self) -> Panel {
        let mut series = Vec::new();
        let (label, detail) = match self.source.temperatures() {
            Err(error) => ("Temperature unavailable".into(), error),
            Ok(report) if report.values.is_empty() => {
                if report.errors.is_empty() {
                    self.temperature_history = History::new(120);
                    (
                        "No temperature sensors".into(),
                        "No readable hwmon or thermal-zone temperature detected".into(),
                    )
                } else {
                    ("Temperature unavailable".into(), report.errors.join("\n"))
                }
            }
            Ok(report) => {
                let maximum = report
                    .values
                    .iter()
                    .map(|v| v.celsius)
                    .fold(f64::NEG_INFINITY, f64::max);
                self.temperature_history.append(maximum);
                series.push(self.temperature_history.values());
                let partial = if report.errors.is_empty() {
                    ""
                } else {
                    " · partial"
                };
                let count = report.values.len();
                let noun = if count == 1 { "sensor" } else { "sensors" };
                let label = format!("{maximum:.1} °C max · {count} {noun}{partial}");
                let mut detail: Vec<_> = report
                    .values
                    .iter()
                    .map(|v| format!("{}: {:.1} °C", v.name, v.celsius))
                    .collect();
                detail.extend(report.errors);
                (label, detail.join("\n"))
            }
        };
        Panel {
            title: "Temperature",
            label,
            detail,
            series,
            scale: Scale::Celsius,
        }
    }
}
pub(crate) fn bytes_per_second(value: f64) -> String {
    if value >= 1_048_576. {
        format!("{:.1} MiB/s", value / 1_048_576.)
    } else if value >= 1024. {
        format!("{:.1} KiB/s", value / 1024.)
    } else {
        format!("{value:.0} B/s")
    }
}

#[derive(Clone)]
pub struct SelectionControl(Arc<Mutex<Option<MetricSelection>>>);
impl SelectionControl {
    pub fn set(&self, selection: MetricSelection) -> Result<(), String> {
        selection.validate()?;
        *self.0.lock().unwrap() = Some(selection);
        Ok(())
    }
}
pub struct Worker {
    pub latest: Arc<Mutex<Option<Snapshot>>>,
    stop: Option<mpsc::Sender<()>>,
    join: Option<thread::JoinHandle<()>>,
    selection: SelectionControl,
}
impl Worker {
    pub fn start() -> Self {
        Self::start_with_ai(true)
    }
    pub fn start_with_ai(ai_enabled: bool) -> Self {
        Self::start_configured(ai_enabled, MetricSelection::default())
    }
    pub fn start_configured(ai_enabled: bool, initial: MetricSelection) -> Self {
        let selection = SelectionControl(Arc::new(Mutex::new(None::<MetricSelection>)));
        let updates = selection.clone();
        let latest = Arc::new(Mutex::new(None));
        let output = latest.clone();
        let (stop, receiver) = mpsc::channel();
        let join = thread::spawn(move || {
            // Swift handles are created and destroyed on this worker only.
            let mut sampler = Sampler::live(ai_enabled);
            sampler
                .set_selection(initial)
                .expect("Validated initial selection");
            loop {
                let next_sample = Instant::now() + Duration::from_secs(1);
                if let Some(selection) = updates.0.lock().unwrap().take() {
                    sampler
                        .set_selection(selection)
                        .expect("Validated selection update");
                }
                *output.lock().unwrap() = Some(sampler.sample());
                // One latest-value slot bounds memory if drawing is slow or hidden.
                match receiver.recv_timeout(next_sample.saturating_duration_since(Instant::now())) {
                    Err(mpsc::RecvTimeoutError::Timeout) => (),
                    _ => break,
                }
            }
        });
        Self {
            latest,
            stop: Some(stop),
            join: Some(join),
            selection,
        }
    }
    pub fn selection_control(&self) -> SelectionControl {
        self.selection.clone()
    }
    pub fn set_selection(&self, selection: MetricSelection) -> Result<(), String> {
        self.selection.set(selection)
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(join) = self.join.take() {
            join.join().expect("collector worker panicked");
        }
    }
}

impl Default for Sampler {
    fn default() -> Self {
        Self::new()
    }
}
