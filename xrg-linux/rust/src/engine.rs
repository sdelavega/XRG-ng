// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::temperature::Text;
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
    pub temperature_text: Option<(crate::temperature::Text, crate::temperature::Text)>,
}
impl Panel {
    fn with_temperature_text(
        mut self,
        label: crate::temperature::Text,
        detail: crate::temperature::Text,
    ) -> Self {
        self.label = label
            .render(crate::temperature::Units::Celsius)
            .into_owned();
        self.detail = detail
            .render(crate::temperature::Units::Celsius)
            .into_owned();
        self.temperature_text = Some((label, detail));
        self
    }
    pub fn display_label(&self, units: crate::temperature::Units) -> std::borrow::Cow<'_, str> {
        self.temperature_text.as_ref().map_or_else(
            || self.label.as_str().into(),
            |(label, _)| label.render(units),
        )
    }
    pub fn display_detail(&self, units: crate::temperature::Units) -> std::borrow::Cow<'_, str> {
        self.temperature_text.as_ref().map_or_else(
            || self.detail.as_str().into(),
            |(_, detail)| detail.render(units),
        )
    }
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
    pub ai: Option<crate::ai::Update>,
    pub weather: Option<crate::weather::Update>,
}
pub struct Sampler {
    source: LinuxSources,
    ai: Option<crate::ai::Worker>,
    ai_panel: Panel,
    ai_update: Option<crate::ai::Update>,
    weather: Option<crate::weather::Worker>,
    weather_update: Option<crate::weather::Update>,
    process: crate::process::Collector,
    process_histories: [History; 2],
    tpu: crate::tpu::Collector,
    tpu_history: History,
    npu_histories: BTreeMap<String, History>,
    npu_activity_mode: bool,
    metrics: crate::metrics::Sampler,
    memory: crate::memory::View,
    temperature_history: History,
    temperature_members: Option<Vec<String>>,
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
        Self::live_with_preferences(ai_enabled, crate::ai::Preferences::default())
    }
    pub fn live_with_preferences(ai_enabled: bool, preferences: crate::ai::Preferences) -> Self {
        Self::live_with_sources(
            ai_enabled,
            preferences,
            crate::weather::Preferences::default(),
        )
    }
    pub fn live_with_sources(
        ai_enabled: bool,
        preferences: crate::ai::Preferences,
        weather: crate::weather::Preferences,
    ) -> Self {
        preferences.validate().expect("Validated AI preferences");
        let mut sampler = Self::with_sources(LinuxSources::live());
        if ai_enabled {
            sampler.ai = crate::ai::Config::live().map(|config| {
                crate::ai::Worker::controlled(config, preferences, crate::ai::Control::default())
            });
            sampler.weather = Some(crate::weather::Worker::start(
                weather,
                crate::weather::Control::default(),
            ));
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
            ai_update: None,
            weather: None,
            weather_update: None,
            gpu,
            process,
            process_histories: array::from_fn(|_| History::new(120)),
            tpu,
            tpu_history: History::new(120),
            npu_histories: BTreeMap::new(),
            npu_activity_mode: false,
            gpu_histories: BTreeMap::new(),
            gpu_memory: crate::gpu_memory::View::default(),
            metrics: crate::metrics::Sampler::default(),
            memory: crate::memory::View::default(),
            temperature_history: History::new(120),
            temperature_members: None,
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
        if self.metrics.selection().temperature != selection.temperature {
            self.temperature_history = History::new(120);
            self.temperature_members = None;
        }
        if self.metrics.selection().fan != selection.fan {
            self.fan_histories.clear();
        }
        self.metrics.set_selection(selection)
    }
    pub fn sample(&mut self) -> Snapshot {
        let time = self.start.elapsed().as_secs_f64();
        let metrics = self.metrics.sample(&self.source, time);
        self.inventory = metrics.inventory;
        let memory = crate::memory::read(self.source.proc_root());
        let valid = metrics.valid && memory.is_ok();
        let paging = crate::memory::read_paging(self.source.proc_root());
        let memory = self.memory.panel(&memory, &paging, time);
        let mut panels = vec![metrics.cpu, memory, metrics.network, metrics.disk];
        panels.push(self.battery_panel());
        panels.push(self.temperature_panel());
        let (gpu, vram) = self.gpu_panels();
        panels.push(gpu);
        if let Some(ai) = &self.ai
            && let Some(update) = ai.latest.lock().unwrap().take()
        {
            self.ai_panel = update.panel.clone();
            self.ai_update = Some(update);
        }
        panels.push(self.ai_panel.clone());
        panels.push(self.process_panel());
        panels.push(self.tpu_panel());
        panels.push(vram);
        panels.push(self.fan_panel());
        if let Some(weather) = &self.weather
            && let Some(update) = weather.latest.lock().unwrap().take()
        {
            self.weather_update = Some(update);
        }
        self.sequence += 1;
        Snapshot {
            sequence: self.sequence,
            panels,
            valid,
            selection: self.metrics.selection().clone(),
            inventory: self.inventory.clone(),
            processes: self.process_report.clone(),
            ai: self.ai_update.clone(),
            weather: self.weather_update.clone(),
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
            temperature_text: None,
        }
    }
    fn tpu_panel(&mut self) -> Panel {
        let report = self.tpu.sample();
        let mut details: Vec<Text> = vec!["Read-only TPU/NPU inventory. Detection or a bound driver does not prove usable inference. Graph: measured NPU activity (%) when a supported counter is readable; otherwise unscoped producer inference rate (inf/s). These quantities never share a scale. Producer statistics are not assigned to detected adapters.".into()];
        let activity_mode = report.devices.as_ref().is_ok_and(|r| {
            r.values
                .iter()
                .any(|d| d.busy_time_us.is_some() || d.utilization.is_some())
        });
        if activity_mode != self.npu_activity_mode {
            self.tpu_history = History::new(120);
            self.npu_histories.clear();
            self.npu_activity_mode = activity_mode;
        }
        let mut activity_labels = Vec::new();
        let mut activity_series = Vec::new();
        let mut capability_records = 0;
        let mut devices = 0;
        let detection_error;
        match report.devices {
            Err(error) => {
                detection_error = true;
                details.push(error.into());
            }
            Ok(readings) => {
                devices = readings
                    .values
                    .iter()
                    .filter(|d| !d.capability_only)
                    .count();
                capability_records = readings.values.len() - devices;
                self.npu_histories.retain(|id, _| {
                    readings
                        .values
                        .iter()
                        .any(|d| &d.id == id && d.utilization.is_some())
                });
                detection_error = !readings.errors.is_empty();
                for device in readings.values {
                    if let Some(value) = device.utilization {
                        let history = self
                            .npu_histories
                            .entry(device.id.clone())
                            .or_insert_with(|| History::new(120));
                        history.append(value);
                        if activity_series.len() < 3 {
                            activity_series.push(history.values());
                            activity_labels.push(format!("{} {value:.1}%", device.label));
                        }
                    }
                    let state = if device.capability_only {
                        "SoC capability only; Linux endpoint unavailable"
                    } else if device.suspended {
                        "suspended; telemetry deferred"
                    } else if device.initialized && device.label.starts_with("Coral USB") {
                        "USB runtime firmware detected; inference capability unverified"
                    } else if device.initialized {
                        "driver bound; inference capability unverified"
                    } else {
                        "firmware/driver unavailable; inference capability unverified"
                    };
                    let prefix = format!("{} · {state}", device.label);
                    let text = match device.temperature_c {
                        Some(v) => {
                            Text::reading(&format!("{prefix} · "), v, &format!("\n{}", device.id))
                        }
                        None => format!("{prefix}\n{}", device.id).into(),
                    };
                    details.push(text);
                    if let Some(driver) = &device.driver {
                        details.push(format!("Driver: {driver}").into());
                    }
                    details.push(device.utilization.map_or_else(
                        || "Activity: unavailable (not assumed idle)".into(),
                        |v| format!("Activity: {v:.1}%").into(),
                    ));
                    if let Some(clock) = device.frequency_mhz {
                        details.push(format!("Reported clock: {clock:.0} MHz").into());
                    }
                    if let Some(bytes) = device.memory_bytes {
                        details
                            .push(format!("Reported NPU memory allocations: {bytes} bytes").into());
                    }
                    details.extend(device.notes.into_iter().map(Text::from));
                }
                details.extend(readings.errors.into_iter().map(Text::from));
            }
        }
        let inventory = format!(
            "{devices} TPU/NPU endpoint(s){}",
            if capability_records > 0 {
                format!(" · {capability_records} SoC capability record(s)")
            } else {
                String::new()
            }
        );
        let mut series = Vec::new();
        let inference_label = match report.inference {
            Err(error) => {
                details.push(error.into());
                if devices > 0 || capability_records > 0 {
                    format!("{inventory} · activity unavailable")
                } else if detection_error {
                    "TPU/NPU discovery/statistics unavailable".into()
                } else {
                    "No TPU/NPU endpoint / no fresh producer statistics".into()
                }
            }
            Ok(inference) => {
                let stats = inference.stats;
                details.push(
                    format!(
                        "Producer total: {} · report age {:.1} s",
                        stats.total_inferences, inference.age_seconds
                    )
                    .into(),
                );
                if let Some(model) = stats.model_name {
                    details.push(format!("Model: {model}").into());
                }
                if let Some(v) = stats.last_latency_ms {
                    details.push(format!("Last reported latency: {v:.2} ms").into());
                }
                if let Some(v) = stats.avg_latency_ms {
                    details.push(format!("Average reported latency: {v:.2} ms").into());
                }
                if let Some(v) = stats.temperature {
                    details.push(Text::reading(
                        "Producer-reported temperature: ",
                        v,
                        " (unscoped)",
                    ));
                }
                if let Some(c) = stats.by_category {
                    details.push(format!("Reported categories: direct {} · hooked {} · logged {} · warming {} (not assumed exclusive)",c.direct.map_or_else(|| "unavailable".into(), |v|v.to_string()), c.hooked.map_or_else(|| "unavailable".into(), |v|v.to_string()), c.logged.map_or_else(|| "unavailable".into(), |v|v.to_string()), c.warming.map_or_else(|| "unavailable".into(), |v|v.to_string())).into());
                }
                let rate = if let Some(rate) = inference.rate {
                    if !activity_mode {
                        self.tpu_history.append(rate);
                        series.push(self.tpu_history.values());
                    }
                    details.push(format!("Unscoped producer rate: {rate:.1} inf/s").into());
                    format!("{rate:.1} inf/s")
                } else {
                    "Waiting for inference interval".into()
                };
                if devices == 0 {
                    format!("{rate} · hardware unverified")
                } else {
                    format!(
                        "{rate} · {inventory}{}",
                        if detection_error { " · partial" } else { "" }
                    )
                }
            }
        };
        let label = if activity_mode {
            series = activity_series;
            if activity_labels.is_empty() {
                "NPU activity · waiting for counter interval".into()
            } else {
                format!(
                    "{}{}",
                    activity_labels.join(" / "),
                    if detection_error { " · partial" } else { "" }
                )
            }
        } else {
            inference_label
        };
        Panel {
            title: "TPU / NPU",
            label: String::new(),
            detail: String::new(),
            series,
            scale: if activity_mode {
                Scale::Percent
            } else {
                Scale::Automatic
            },
            temperature_text: None,
        }
        .with_temperature_text(label.into(), Text::join(details, "\n\n"))
    }
    fn gpu_panels(&mut self) -> (Panel, Panel) {
        let mut series = Vec::new();
        let mut result = self.gpu.sample();
        self.inventory.gpus.clear();
        if let Ok(report) = &mut result {
            self.inventory.gpus = report
                .values
                .iter()
                .map(|gpu| crate::metrics::SourceOption {
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
                            temperature_text: None,
                        },
                        vram,
                    );
                }
            }
        }

        let vram = self.gpu_memory.panel(&result);
        let (label, detail): (String, Text) = match result {
            Err(error) => ("GPU unavailable".into(), error.into()),
            Ok(report) if report.values.is_empty() => {
                if report.errors.is_empty() {
                    self.gpu_histories.clear();
                    (
                        "No GPU detected".into(),
                        "No supported GPU adapter detected".into(),
                    )
                } else {
                    ("GPU unavailable".into(), report.errors.join("\n").into())
                }
            }
            Ok(report) => {
                self.gpu_histories
                    .retain(|id, _| report.values.iter().any(|v| v.id == *id));
                let mut labels = Vec::new();
                let mut details: Vec<Text> = Vec::new();
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
                    let mut fields: Vec<Text> = vec![
                        format!("{} · {} · {}", gpu.label, gpu.name, gpu.id).into(),
                        format!("Driver: {}", gpu.driver).into(),
                        gpu.utilization
                            .map(|v| format!("Utilization: {v:.1}%"))
                            .unwrap_or_else(|| "Device-wide utilization unavailable".into())
                            .into(),
                    ];
                    if let Some(value) = gpu.client_activity {
                        fields.push(
                            format!("Readable-client busiest-engine activity: {value:.1}%").into(),
                        );
                    }
                    if let Some(count) = gpu.visible_clients {
                        fields.push(format!("Readable DRM clients: {count}").into());
                    }
                    if let Some(value) = gpu.client_resident_bytes {
                        fields.push(format!("Readable-client resident allocations: {:.1} MiB (shared buffers may count per client)", value as f64 / 1_048_576.).into());
                    }
                    if let Some(value) = gpu.memory_used {
                        fields.push(
                            format!("VRAM used: {:.1} MiB", value as f64 / 1_048_576.).into(),
                        );
                    }
                    if let Some(value) = gpu.memory_total {
                        fields.push(
                            format!("VRAM total: {:.1} MiB", value as f64 / 1_048_576.).into(),
                        );
                    }
                    if let Some(value) = gpu.temperature {
                        fields.push(Text::reading("Temperature: ", value, ""));
                    }
                    if let Some(value) = gpu.frequency_mhz {
                        fields.push(format!("Reported clock: {value:.0} MHz").into());
                    }
                    if let Some(value) = gpu.power_watts {
                        fields
                            .push(format!("Reported power: {value:.1} W (may include SoC)").into());
                    }
                    if let Some(value) = gpu.fan_rpm {
                        fields.push(format!("Fan: {value} RPM").into());
                    }
                    if let Some(value) = gpu.fan_percent {
                        fields.push(format!("Fan: {value:.0}%").into());
                    }
                    fields.extend(gpu.notes.iter().cloned().map(Text::from));
                    details.push(Text::join(fields, "\n"));
                }
                details.extend(report.errors.into_iter().map(Text::from));
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
                (label, Text::join(details, "\n\n"))
            }
        };
        (
            Panel {
                title: "GPU",
                label: String::new(),
                detail: String::new(),
                series,
                scale: Scale::Percent,
                temperature_text: None,
            }
            .with_temperature_text(label.into(), detail),
            vram,
        )
    }

    fn fan_panel(&mut self) -> Panel {
        let mut panel = Panel {
            title: "Fans", label: "No readable fan sensors".into(), series: Vec::new(),
            detail: "Read-only hwmon fan RPM. Zero can mean a stopped fan; PWM duty is not RPM. Channel labels come from the driver and do not establish CPU/GPU ownership.".into(),
            scale: Scale::Automatic,
            temperature_text: None,
        };
        match crate::hardware::fans(self.source.sys_root()) {
            Err(error) => {
                self.fan_histories.clear();
                panel.label = "Fan readings unavailable".into();
                panel.detail.push_str(&format!("\n{error}"));
            }
            Ok(mut report) => {
                self.inventory.fans = report
                    .values
                    .iter()
                    .map(|fan| crate::metrics::SourceOption {
                        id: fan.source_id.clone(),
                        label: fan.name.clone(),
                    })
                    .collect();
                if let Some(selected) = &self.metrics.selection().fan {
                    report.values.retain(|fan| fan.source_id == *selected);
                    if report.values.is_empty() {
                        self.fan_histories.clear();
                        panel.label = "Selected fan unavailable".into();
                        panel.detail.push_str(&format!("\nSaved fan source {selected} is not readable in the latest sample.\n{}",report.errors.join("\n")));
                        return panel;
                    }
                }
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
            temperature_text: None,
        }
    }
    fn temperature_panel(&mut self) -> Panel {
        let selected = self.metrics.selection().temperature.clone();
        let mut panel = Panel {
            title: "Temperature",
            label: String::new(),
            detail: String::new(),
            series: Vec::new(),
            scale: Scale::Celsius,
            temperature_text: None,
        };
        let mut report = match crate::hardware::temperature_sources(self.source.sys_root()) {
            Ok(report) => report,
            Err(error) => {
                self.temperature_history = History::new(120);
                self.temperature_members = None;
                return panel.with_temperature_text("Temperature unavailable".into(), error.into());
            }
        };
        self.inventory.temperatures = report
            .values
            .iter()
            .map(|sensor| crate::metrics::SourceOption {
                id: sensor.source_id.clone(),
                label: sensor.name.clone(),
            })
            .collect();
        if let Some(selected) = &selected {
            report.values.retain(|sensor| sensor.source_id == *selected);
        } else if report.values.iter().any(|sensor| !sensor.thermal) {
            report.values.retain(|sensor| !sensor.thermal);
        }
        if report.values.is_empty() {
            self.temperature_history = History::new(120);
            self.temperature_members = None;
            let (label, detail) = if let Some(selected) = selected {
                (
                    "Selected temperature sensor unavailable".to_owned(),
                    format!(
                        "Saved temperature source {selected} is not readable in the latest sample.\n{}",
                        report.errors.join("\n")
                    ),
                )
            } else if report.errors.is_empty() {
                (
                    "No temperature sensors".into(),
                    "No readable hwmon or thermal-zone temperature detected".into(),
                )
            } else {
                ("Temperature unavailable".into(), report.errors.join("\n"))
            };
            return panel.with_temperature_text(label.into(), detail.into());
        }
        let mut members: Vec<_> = report
            .values
            .iter()
            .map(|sensor| sensor.id.clone())
            .collect();
        members.sort();
        if self.temperature_members.as_ref() != Some(&members) {
            self.temperature_history = History::new(120);
            self.temperature_members = Some(members);
        }
        let maximum = report
            .values
            .iter()
            .map(|v| v.celsius)
            .fold(f64::NEG_INFINITY, f64::max);
        self.temperature_history.append(maximum);
        panel.series.push(self.temperature_history.values());
        let partial = if report.errors.is_empty() {
            ""
        } else {
            " · partial"
        };
        let label = if selected.is_some() {
            Text::reading(
                "",
                maximum,
                &format!(" · {}{partial}", report.values[0].name),
            )
        } else {
            let count = report.values.len();
            let noun = if count == 1 { "sensor" } else { "sensors" };
            Text::reading("", maximum, &format!(" max · {count} {noun}{partial}"))
        };
        let mut detail: Vec<Text> = report
            .values
            .iter()
            .map(|v| Text::reading(&format!("{}: ", v.name), v.celsius, ""))
            .collect();
        detail.extend(report.errors.into_iter().map(Text::from));
        panel.with_temperature_text(label, Text::join(detail, "\n"))
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
    ai: crate::ai::Control,
    weather: crate::weather::Control,
}
impl Worker {
    pub fn start() -> Self {
        Self::start_with_ai(true)
    }
    pub fn start_with_ai(ai_enabled: bool) -> Self {
        Self::start_configured(ai_enabled, MetricSelection::default())
    }
    pub fn start_configured(ai_enabled: bool, initial: MetricSelection) -> Self {
        Self::start_with_preferences(ai_enabled, initial, crate::ai::Preferences::default())
    }
    pub fn start_with_preferences(
        ai_enabled: bool,
        initial: MetricSelection,
        ai_preferences: crate::ai::Preferences,
    ) -> Self {
        Self::start_with_sources(
            ai_enabled,
            initial,
            ai_preferences,
            crate::weather::Preferences::default(),
        )
    }
    pub fn start_with_sources(
        ai_enabled: bool,
        initial: MetricSelection,
        ai_preferences: crate::ai::Preferences,
        weather_preferences: crate::weather::Preferences,
    ) -> Self {
        ai_preferences.validate().expect("Validated AI preferences");
        let ai = crate::ai::Control::default();
        let ai_updates = ai.clone();
        weather_preferences
            .validate()
            .expect("Validated weather preferences");
        let weather = crate::weather::Control::default();
        let weather_updates = weather.clone();
        let selection = SelectionControl(Arc::new(Mutex::new(None::<MetricSelection>)));
        let updates = selection.clone();
        let latest = Arc::new(Mutex::new(None));
        let output = latest.clone();
        let (stop, receiver) = mpsc::channel();
        let join = thread::spawn(move || {
            // Swift handles are created and destroyed on this worker only.
            let mut sampler = Sampler::live(false);
            if ai_enabled && let Some(config) = crate::ai::Config::live() {
                sampler.ai = Some(crate::ai::Worker::controlled(
                    config,
                    ai_preferences,
                    ai_updates,
                ));
            }
            if ai_enabled {
                sampler.weather = Some(crate::weather::Worker::start(
                    weather_preferences,
                    weather_updates,
                ));
            }
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
            ai,
            weather,
        }
    }
    pub fn selection_control(&self) -> SelectionControl {
        self.selection.clone()
    }
    pub fn ai_control(&self) -> crate::ai::Control {
        self.ai.clone()
    }
    pub fn weather_control(&self) -> crate::weather::Control {
        self.weather.clone()
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
