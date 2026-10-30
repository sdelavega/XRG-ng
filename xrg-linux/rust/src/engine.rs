// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::temperature::Text;
use crate::{
    collectors::LinuxSources,
    settings::{MetricSelection, Module},
    shared::History,
};
use std::{
    array,
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Mutex},
    thread,
    time::Instant,
};

#[derive(Clone, Debug)]
pub struct Panel {
    pub title: &'static str,
    pub label: String,
    pub series: Vec<Vec<f64>>,
    pub scale: Scale,
    pub detail: String,
    pub temperature_text: Option<(crate::temperature::Text, crate::temperature::Text)>,
    pub weather_plot: Option<crate::weather::ObservationPlot>,
    pub readout: crate::dashboard::Readout,
}
impl Panel {
    pub fn plot_bounds(&self, index: usize, minimum: u64) -> (f64, f64) {
        if let Some(plot) = &self.weather_plot {
            if index == 1
                && let Some(axis) = &plot.secondary
            {
                return (axis.lower, axis.upper);
            }
            return self.scale.bounds_with_minimum(
                self.series.first().map_or(&[], std::slice::from_ref),
                minimum,
            );
        }
        self.scale.bounds_with_minimum(&self.series, minimum)
    }
    pub fn activity_description(&self, units: crate::temperature::Units) -> String {
        self.activity_description_with_minimum(units, 0)
    }
    pub fn activity_description_with_minimum(
        &self,
        units: crate::temperature::Units,
        minimum: u64,
    ) -> String {
        let units = self.scale.temperature_units(units);
        let (lower, upper) = self.plot_bounds(0, minimum);
        let axis = match self.scale {
            Scale::Percent => "0–100%".into(),
            Scale::SignedWatts => {
                format!("{lower:.1}–{upper:.1} W; charging positive, discharging negative")
            }
            Scale::Automatic => format!(
                "{lower:.2}–{upper:.2} in graph units; scales to recent history, not device capacity"
            ),
            Scale::Celsius | Scale::Weather(_) => format!(
                "{:.1}–{:.1} °{}; a display range, not a thermal limit",
                units.convert_celsius(lower),
                units.convert_celsius(upper),
                if units == crate::temperature::Units::Celsius {
                    "C"
                } else {
                    "F"
                }
            ),
        };
        let axis = if let Some(plot) = &self.weather_plot {
            format!(
                "{axis}. {}{}",
                plot.range_label,
                plot.secondary.as_ref().map_or(String::new(), |a| format!(
                    "; secondary {} uses its own {:.2}–{:.2} axis",
                    a.label, a.lower, a.upper
                ))
            )
        } else {
            axis
        };
        format!(
            "Current-value (‘now’) bars use the graph axis: {axis}. Left to right follows series order. Missing latest readings have no track; measured zero has an empty track. Signed values extend from zero."
        )
    }
    pub(crate) fn with_temperature_text(
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
        let units = self.scale.temperature_units(units);
        self.temperature_text.as_ref().map_or_else(
            || self.label.as_str().into(),
            |(label, _)| label.render(units),
        )
    }
    pub fn display_detail(&self, units: crate::temperature::Units) -> std::borrow::Cow<'_, str> {
        let units = self.scale.temperature_units(units);
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
    SignedWatts,
    Automatic,
    Celsius,
    /// Weather keeps its own display-unit preference; samples remain Celsius.
    Weather(crate::temperature::Units),
}
impl Scale {
    pub fn temperature_units(
        self,
        fallback: crate::temperature::Units,
    ) -> crate::temperature::Units {
        if let Self::Weather(units) = self {
            units
        } else {
            fallback
        }
    }
    pub fn bounds(self, series: &[Vec<f64>]) -> (f64, f64) {
        self.bounds_with_minimum(series, 0)
    }
    pub fn bounds_with_minimum(self, series: &[Vec<f64>], minimum: u64) -> (f64, f64) {
        match self {
            Self::Percent => (0., 100.),
            Self::SignedWatts => {
                let peak = series
                    .iter()
                    .flatten()
                    .copied()
                    .filter(|v| v.is_finite())
                    .map(f64::abs)
                    .fold(30., f64::max);
                (-peak, peak)
            }
            Self::Automatic => (
                0.,
                (series.iter().flatten().copied().fold(1.0, f64::max) * 1.1).max(minimum as f64),
            ),
            Self::Weather(_) => {
                let mut values = series.iter().flatten().copied().filter(|v| v.is_finite());
                if let Some(first) = values.next() {
                    let (low, high) =
                        values.fold((first, first), |(low, high), v| (low.min(v), high.max(v)));
                    (
                        ((low - 5.) / 5.).floor() * 5.,
                        ((high + 5.) / 5.).ceil() * 5.,
                    )
                } else {
                    (-10., 40.)
                }
            }
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
    pub sensors: Arc<crate::sensor_stats::Report>,
    pub graph_generations: [u64; 13],
    pub transfers: [crate::metrics::TransferTotals; 2],
    pub ai: Option<crate::ai::Update>,
    pub weather: Option<crate::weather::Update>,
}
struct GpuHistory {
    observed: usize,
    source: crate::gpu::ActivitySource,
    driver: String,
    history: History,
}
impl GpuHistory {
    fn new(source: crate::gpu::ActivitySource, driver: &str, capacity: u32) -> Self {
        let history = History::new(capacity);
        Self {
            observed: 0,
            source,
            driver: driver.into(),
            history,
        }
    }
}
pub struct Sampler {
    source: LinuxSources,
    ai: Option<crate::ai::Worker>,
    ai_panel: Panel,
    ai_update: Option<crate::ai::Update>,
    minimum_ai_generation: u64,
    graph_generations: [u64; 13],
    weather: Option<crate::weather::Worker>,
    weather_update: Option<crate::weather::Update>,
    weather_view: crate::weather::Graph,
    process: crate::process::Collector,
    process_histories: [History; 2],
    tpu: crate::tpu::Collector,
    tpu_history: History,
    npu_histories: BTreeMap<String, History>,
    npu_activity_mode: bool,
    metrics: crate::metrics::Sampler,
    memory: crate::memory::View,
    sensors: crate::sensors::View,
    sensor_statistics: crate::sensor_stats::Statistics,
    inventory: crate::metrics::Inventory,
    process_report: Result<Arc<crate::process::Report>, String>,
    battery: crate::battery::View,
    gpu: crate::gpu::GpuCollector,
    gpu_memory: crate::gpu_memory::View,
    gpu_histories: BTreeMap<String, GpuHistory>,
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
            minimum_ai_generation: 0,
            graph_generations: [0; 13],
            weather: None,
            weather_update: None,
            weather_view: Default::default(),
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
            sensors: crate::sensors::View::default(),
            sensor_statistics: Default::default(),
            inventory: crate::metrics::Inventory::default(),
            process_report: Err("Waiting for process sample".into()),
            battery: crate::battery::View::default(),
            start: Instant::now(),
            sequence: 0,
        }
    }
    pub fn clear_graph(&mut self, module: Module) {
        match module {
            Module::Cpu | Module::Network | Module::Disk => self.metrics.clear_graph(module),
            Module::Memory => self.memory.clear_graph(),
            Module::Temperature => self.sensors.clear_temperatures(),
            Module::Fans => self.sensors.clear_fans(),
            Module::GpuMemory => self.gpu_memory.clear_graph(),
            Module::Gpu => {
                for h in self.gpu_histories.values_mut() {
                    h.history.clear();
                    h.observed = 0;
                }
            }
            Module::Battery => self.battery.clear_graph(),
            Module::Processes => {
                for h in &mut self.process_histories {
                    h.clear();
                }
            }
            Module::Tpu => {
                self.tpu_history.clear();
                for h in self.npu_histories.values_mut() {
                    h.clear();
                }
            }
            Module::Weather => self.weather_view.clear_graph(),
            Module::Ai => {
                if let Some(worker) = &self.ai {
                    self.minimum_ai_generation = worker.clear_graph();
                }
                self.ai_panel.series.clear();
                if let Some(update) = &mut self.ai_update {
                    update.panel.series.clear();
                }
            }
        }
        let generation = &mut self.graph_generations[module.index()];
        *generation = generation.wrapping_add(1);
    }
    pub fn reset_transfers(&mut self, module: Module) {
        self.metrics.reset_transfers(module);
    }
    pub fn set_selection(&mut self, selection: MetricSelection) -> Result<(), String> {
        selection.validate()?;
        self.sensors.set_history_samples(
            selection.retained_samples(Module::Temperature),
            selection.retained_samples(Module::Fans),
        )?;
        self.battery
            .set_history_samples(selection.retained_samples(Module::Battery))?;
        let gpu_capacity = selection.history_capacity(Module::Gpu);
        for state in self.gpu_histories.values_mut() {
            state.history.resize(gpu_capacity);
            state.observed = state.observed.min(gpu_capacity as usize);
        }
        let npu_capacity = selection.history_capacity(Module::Tpu);
        self.tpu_history.resize(npu_capacity);
        for history in self.npu_histories.values_mut() {
            history.resize(npu_capacity);
        }
        self.gpu_memory
            .set_history_samples(selection.retained_samples(Module::GpuMemory))?;
        self.memory
            .set_time_window(selection.retained_minutes(Module::Memory))?;
        self.memory
            .set_history_samples(selection.retained_samples(Module::Memory))?;
        if self.metrics.selection().gpu != selection.gpu {
            self.gpu_histories.clear();
            self.gpu_memory.reset();
        }
        if self.metrics.selection().xe_pmu != selection.xe_pmu {
            self.gpu_histories.clear();
        }
        self.gpu.set_xe_pmu(selection.xe_pmu);
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
            && update.graph_generation >= self.minimum_ai_generation
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
        panels.push(self.weather_view.panel(self.weather_update.as_ref()));
        self.sequence += 1;
        Snapshot {
            sequence: self.sequence,
            panels,
            valid,
            selection: self.metrics.selection().clone(),
            inventory: self.inventory.clone(),
            processes: self.process_report.clone(),
            sensors: Arc::new(self.sensor_statistics.report(time)),
            graph_generations: self.graph_generations,
            transfers: self.metrics.transfer_totals(),
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
            weather_plot: None,
            readout: Default::default(),
        }
    }
    fn tpu_panel(&mut self) -> Panel {
        let report = self.tpu.sample();
        self.tpu_panel_from(report)
    }
    fn tpu_panel_from(&mut self, report: crate::tpu::Report) -> Panel {
        let mut details: Vec<Text> = vec!["Read-only TPU/NPU inventory. Detection or a bound driver does not prove usable inference. Graph: device activity or explicitly labeled busiest observed readable-client activity (%), when supported counters are readable; otherwise unscoped producer inference rate (inf/s). These quantities never share a scale. Producer statistics are not assigned to detected adapters.".into()];
        let activity_mode = report.devices.as_ref().is_ok_and(|r| {
            r.values.iter().any(|d| {
                d.busy_time_us.is_some() || d.utilization.is_some() || d.client_activity.is_some()
            })
        });
        if activity_mode != self.npu_activity_mode {
            self.tpu_history = History::new(self.metrics.selection().history_capacity(Module::Tpu));
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
                let active_keys: BTreeSet<_> = readings
                    .values
                    .iter()
                    .filter(|d| d.activity_percent().is_some())
                    .map(|d| d.activity_key())
                    .collect();
                self.npu_histories.retain(|id, _| active_keys.contains(id));
                let capacity = self.metrics.selection().history_capacity(Module::Tpu);
                detection_error = !readings.errors.is_empty();
                for device in readings.values {
                    if let Some(value) = device.activity_percent() {
                        let history = self
                            .npu_histories
                            .entry(device.activity_key())
                            .or_insert_with(|| History::new(capacity));
                        history.append(value);
                        if activity_series.len() < 3 {
                            activity_series.push(history.values());
                            activity_labels.push(format!(
                                "{}{} {value:.1}%",
                                device.label,
                                if device.utilization.is_none() && device.client_activity.is_some()
                                {
                                    " (clients)"
                                } else {
                                    ""
                                }
                            ));
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
                    details.push(device.activity_percent().map_or_else(
                        || "Activity: unavailable (not assumed idle)".into(),
                        |v| {
                            format!(
                                "Activity: {v:.1}%{}",
                                if device.utilization.is_none() && device.client_activity.is_some()
                                {
                                    " (busiest observed readable client)"
                                } else {
                                    ""
                                }
                            )
                            .into()
                        },
                    ));
                    if let Some(activity) = &device.client_activity {
                        details.push(
                            format!(
                                "Observed AMD NPU clients with counters: {}",
                                activity.clients
                            )
                            .into(),
                        );
                    }
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
            weather_plot: None,
            readout: Default::default(),
        }
        .with_temperature_text(label.into(), Text::join(details, "\n\n"))
    }
    fn gpu_panels(&mut self) -> (Panel, Panel) {
        let mut series = Vec::new();
        let mut readout = crate::dashboard::Readout::default();
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
                            weather_plot: None,
                            readout: Default::default(),
                        },
                        vram,
                    );
                }
            }
        }

        let vram = self.gpu_memory.panel(&result);
        let (label, detail): (String, Text) = match result {
            Err(error) => {
                self.gpu_histories.clear();
                ("GPU unavailable".into(), error.into())
            }
            Ok(report) if report.values.is_empty() => {
                self.gpu_histories.clear();
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
                self.gpu_histories.retain(|id, _| {
                    report
                        .values
                        .iter()
                        .any(|v| v.id == *id && v.activity().is_some())
                });
                let mut labels = Vec::new();
                let mut details: Vec<Text> = Vec::new();
                let supported: Vec<_> = report
                    .values
                    .iter()
                    .filter(|g| g.activity().is_some())
                    .collect();
                let partial =
                    !report.errors.is_empty() || report.values.iter().any(|g| !g.notes.is_empty());
                for gpu in supported.iter().take(3) {
                    let (source, value) = gpu.activity().expect("filtered activity");
                    series.push(self.gpu_curve(gpu).expect("filtered activity"));
                    labels.push(format!("{} {value:.0}%{}", gpu.label, source.suffix()));
                }
                readout.top.push(crate::dashboard::Row::new("GPU", ""));
                for gpu in report.values.iter().take(3) {
                    readout.top.push(crate::dashboard::Row::new(
                        &gpu.name,
                        gpu.activity()
                            .map(|(source, value)| format!("{value:.0}%{}", source.suffix()))
                            .unwrap_or_else(|| "n/a".into()),
                    ));
                    if let Some(used) = gpu.memory_used {
                        readout.top.push(crate::dashboard::Row::new(
                            "VRAM used",
                            crate::dashboard::bytes(used as f64),
                        ));
                    }
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
                    if let Some(activity) = &gpu.engine_activity {
                        fields.push(format!("i915 PMU busiest-engine activity: {:.1}% (system-wide engines, not whole-GPU capacity)",activity.percent).into());
                        fields.push(
                            format!(
                                "PMU busy engines: {}",
                                activity
                                    .engines
                                    .iter()
                                    .map(|(name, value)| format!("{name} {value:.1}%"))
                                    .collect::<Vec<_>>()
                                    .join(" / ")
                            )
                            .into(),
                        );
                        fields.push("The maximum busy-engine percentage is plotted; engines are not summed. PMU permissions are unchanged; incomplete or multiplexed intervals stay unavailable.".into());
                    }
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
                weather_plot: None,
                readout,
            }
            .with_temperature_text(label.into(), detail),
            vram,
        )
    }

    fn gpu_curve(&mut self, gpu: &crate::gpu::Gpu) -> Option<Vec<f64>> {
        let Some((source, value)) = gpu.activity() else {
            self.gpu_histories.remove(&gpu.id);
            return None;
        };
        let capacity = self.metrics.selection().history_capacity(Module::Gpu);
        let state = self
            .gpu_histories
            .entry(gpu.id.clone())
            .or_insert_with(|| GpuHistory::new(source, &gpu.driver, capacity));
        if state.source != source || state.driver != gpu.driver {
            *state = GpuHistory::new(source, &gpu.driver, capacity);
        }
        state.history.append(value);
        let mut values = state.history.values();
        state.observed = (state.observed + 1).min(values.len());
        let missing = values.len() - state.observed;
        values[..missing].fill(f64::NAN);
        Some(values)
    }
    fn fan_panel(&mut self) -> Panel {
        let report = crate::hardware::fans(self.source.sys_root());
        self.sensor_statistics
            .fans(&report, self.start.elapsed().as_secs_f64());
        let (panel, inventory) = self.sensors.fans(report, self.metrics.selection());
        self.inventory.fans = inventory;
        panel
    }
    fn battery_panel(&mut self) -> Panel {
        self.battery
            .panel(self.source.battery(), self.metrics.selection().battery_mode)
    }
    fn temperature_panel(&mut self) -> Panel {
        let report = crate::hardware::temperature_sources(self.source.sys_root());
        self.sensor_statistics
            .temperatures(&report, self.start.elapsed().as_secs_f64());
        let (panel, inventory) = self.sensors.temperatures(report, self.metrics.selection());
        self.inventory.temperatures = inventory;
        panel
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
pub struct SelectionControl(
    Arc<Mutex<Option<MetricSelection>>>,
    crate::sampling::Control,
);
impl SelectionControl {
    pub fn set(&self, selection: MetricSelection) -> Result<(), String> {
        selection.validate()?;
        *self.0.lock().unwrap() = Some(selection);
        self.1.request()
    }
}
#[derive(Default)]
struct PlotRequests {
    graphs: BTreeSet<Module>,
    transfers: BTreeSet<Module>,
}
#[derive(Clone)]
pub struct GraphControl(Arc<Mutex<PlotRequests>>, crate::sampling::Control);
impl GraphControl {
    pub fn clear(&self, module: Module) -> Result<(), String> {
        self.0.lock().unwrap().graphs.insert(module);
        self.1.request()
    }
    pub fn clear_all(&self) -> Result<(), String> {
        self.0.lock().unwrap().graphs.extend(Module::ALL);
        self.1.request()
    }
    pub fn reset_transfers(&self, module: Module) -> Result<(), String> {
        if !matches!(module, Module::Network | Module::Disk) {
            return Err("Only Network and Disk have session transfers".into());
        }
        self.0.lock().unwrap().transfers.insert(module);
        self.1.request()
    }
}
#[derive(Clone)]
pub struct SensorStatsControl(Arc<std::sync::atomic::AtomicBool>, crate::sampling::Control);
impl SensorStatsControl {
    pub fn reset(&self) -> Result<(), String> {
        self.0.store(true, std::sync::atomic::Ordering::Release);
        self.1.request()
    }
}
pub struct Worker {
    notification: crate::notification::Notification,
    pub latest: Arc<Mutex<Option<Snapshot>>>,
    sampling: crate::sampling::Control,
    join: Option<thread::JoinHandle<()>>,
    selection: SelectionControl,
    sensor_stats: SensorStatsControl,
    graphs: GraphControl,
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
        Self::start_timed(
            ai_enabled,
            initial,
            ai_preferences,
            weather_preferences,
            crate::sampling::default_interval(),
        )
    }
    pub fn start_with_settings(ai_enabled: bool, settings: &crate::settings::Settings) -> Self {
        settings.validate().expect("Validated settings");
        Self::start_timed(
            ai_enabled,
            settings.metrics.clone(),
            settings.ai.clone(),
            settings.weather.clone(),
            settings.sampling_interval_ms,
        )
    }
    pub fn start_with_system_sources(
        source: LinuxSources,
        settings: &crate::settings::Settings,
    ) -> Self {
        settings.validate().expect("Validated settings");
        Self::spawn(
            settings.metrics.clone(),
            settings.sampling_interval_ms,
            move |_, _| Sampler::with_sources(source),
        )
    }
    fn start_timed(
        ai_enabled: bool,
        initial: MetricSelection,
        ai_preferences: crate::ai::Preferences,
        weather_preferences: crate::weather::Preferences,
        interval_ms: u32,
    ) -> Self {
        ai_preferences.validate().expect("Validated AI preferences");
        weather_preferences
            .validate()
            .expect("Validated weather preferences");
        Self::spawn(initial, interval_ms, move |ai_updates, weather_updates| {
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
        })
    }
    fn spawn(
        initial: MetricSelection,
        interval_ms: u32,
        build: impl FnOnce(crate::ai::Control, crate::weather::Control) -> Sampler + Send + 'static,
    ) -> Self {
        initial.validate().expect("Validated initial selection");
        let mut timer =
            crate::sampling::Timer::new(interval_ms).expect("Validated sampling interval");
        let sampling = timer.control();
        let ai = crate::ai::Control::default();
        let ai_updates = ai.clone();
        let weather = crate::weather::Control::default();
        let weather_updates = weather.clone();
        let selection = SelectionControl(
            Arc::new(Mutex::new(None::<MetricSelection>)),
            sampling.clone(),
        );
        let updates = selection.clone();
        let sensor_stats = SensorStatsControl(
            Arc::new(std::sync::atomic::AtomicBool::new(false)),
            sampling.clone(),
        );
        let reset_stats = sensor_stats.clone();
        let graphs = GraphControl(
            Arc::new(Mutex::new(PlotRequests::default())),
            sampling.clone(),
        );
        let plot_updates = graphs.clone();
        let latest = Arc::new(Mutex::new(None));
        let output = latest.clone();
        let notification = crate::notification::Notification::default();
        let published = notification.clone();
        let join = thread::spawn(move || {
            let mut sampler = build(ai_updates, weather_updates);
            sampler
                .set_selection(initial)
                .expect("Validated initial selection");
            while timer.wait() {
                let started = Instant::now();
                if let Some(selection) = updates.0.lock().unwrap().take() {
                    sampler
                        .set_selection(selection)
                        .expect("Validated selection update");
                }
                if reset_stats
                    .0
                    .swap(false, std::sync::atomic::Ordering::AcqRel)
                {
                    sampler.sensor_statistics.reset();
                }
                let requests = std::mem::take(&mut *plot_updates.0.lock().unwrap());
                for module in requests.graphs {
                    sampler.clear_graph(module);
                }
                for module in requests.transfers {
                    sampler.reset_transfers(module);
                }
                sampler
                    .metrics
                    .set_history_interval(timer.interval_seconds());
                sampler
                    .memory
                    .set_history_interval(timer.interval_seconds());
                // One latest-value slot bounds memory if drawing is slow or hidden.
                *output.lock().unwrap() = Some(sampler.sample());
                published.notify();
                timer.sampled(started);
            }
        });
        Self {
            latest,
            notification,
            sampling,
            join: Some(join),
            selection,
            sensor_stats,
            graphs,
            ai,
            weather,
        }
    }
    /// Wake a consumer after publishing; registration also covers a queued sample.
    pub fn on_publish(&self, callback: impl Fn() + Send + Sync + 'static) {
        self.notification.set(callback);
    }
    pub fn sampling_control(&self) -> crate::sampling::Control {
        self.sampling.clone()
    }
    pub fn selection_control(&self) -> SelectionControl {
        self.selection.clone()
    }
    pub fn graph_control(&self) -> GraphControl {
        self.graphs.clone()
    }
    pub fn sensor_stats_control(&self) -> SensorStatsControl {
        self.sensor_stats.clone()
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
        self.sampling.stop();
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

#[cfg(test)]
mod gpu_activity_tests {
    use super::*;
    use crate::gpu::{EngineActivity, Gpu};
    fn observed(values: Option<Vec<f64>>) -> Option<Vec<f64>> {
        values.map(|v| v.into_iter().filter(|v| v.is_finite()).collect())
    }
    #[test]
    fn retained_gpu_capacity_keeps_observations_and_replacement_boundaries() {
        let mut sampler = Sampler::with_sources(LinuxSources::with_roots(
            "/no-proc-fixture",
            "/no-sys-fixture",
        ));
        let mut selection = MetricSelection::default();
        selection.history_samples.insert(Module::Gpu, 3);
        sampler.set_selection(selection.clone()).unwrap();
        let mut gpu = Gpu {
            id: "adapter".into(),
            driver: "fixture".into(),
            utilization: Some(50.),
            ..Default::default()
        };
        assert_eq!(sampler.gpu_curve(&gpu).unwrap().len(), 3);
        gpu.utilization = Some(25.);
        sampler.gpu_curve(&gpu);
        selection.history_samples.insert(Module::Gpu, 6);
        sampler.set_selection(selection.clone()).unwrap();
        gpu.utilization = Some(10.);
        let values = sampler.gpu_curve(&gpu).unwrap();
        assert_eq!(values.len(), 6);
        assert!(values[..3].iter().all(|v| v.is_nan()));
        assert_eq!(&values[3..], &[50., 25., 10.]);
        gpu.driver = "replacement".into();
        let values = sampler.gpu_curve(&gpu).unwrap();
        assert_eq!(values.len(), 6);
        assert!(values[..5].iter().all(|v| v.is_nan()));
        sampler.clear_graph(Module::Gpu);
        let values = sampler.gpu_curve(&gpu).unwrap();
        assert!(values[..5].iter().all(|v| v.is_nan()));
        gpu.utilization = None;
        assert!(sampler.gpu_curve(&gpu).is_none());
        gpu.utilization = Some(0.);
        assert_eq!(sampler.gpu_curve(&gpu).unwrap().last(), Some(&0.));
        selection.history_samples.remove(&Module::Gpu);
        sampler.set_selection(selection).unwrap();
        assert_eq!(sampler.gpu_curve(&gpu).unwrap().len(), 120);
    }
    #[test]
    fn device_engine_client_and_driver_changes_do_not_mix_history_scopes() {
        let mut sampler = Sampler::with_sources(LinuxSources::with_roots(
            "/no-proc-fixture",
            "/no-sys-fixture",
        ));
        let mut gpu = Gpu {
            id: "adapter".into(),
            driver: "i915".into(),
            engine_activity: Some(EngineActivity {
                percent: 50.,
                engines: vec![("rcs0".into(), 50.)],
            }),
            ..Default::default()
        };
        assert_eq!(observed(sampler.gpu_curve(&gpu)), Some(vec![50.]));
        gpu.engine_activity.as_mut().unwrap().percent = 25.;
        assert_eq!(observed(sampler.gpu_curve(&gpu)), Some(vec![50., 25.]));
        gpu.engine_activity = None;
        gpu.client_activity = Some(75.);
        assert_eq!(observed(sampler.gpu_curve(&gpu)), Some(vec![75.]));
        gpu.utilization = Some(0.);
        assert_eq!(observed(sampler.gpu_curve(&gpu)), Some(vec![0.]));
        gpu.driver = "another-driver".into();
        assert_eq!(observed(sampler.gpu_curve(&gpu)), Some(vec![0.]));
        gpu.utilization = None;
        gpu.client_activity = None;
        assert!(sampler.gpu_curve(&gpu).is_none());
        gpu.utilization = Some(10.);
        assert_eq!(observed(sampler.gpu_curve(&gpu)), Some(vec![10.]));
    }
}

#[cfg(test)]
mod gpu_activity_validation_tests {
    use crate::gpu::{ActivitySource, EngineActivity, Gpu};
    #[test]
    fn malformed_activity_never_reaches_the_finite_only_swift_history() {
        let mut gpu = Gpu {
            utilization: Some(f64::NAN),
            engine_activity: Some(EngineActivity {
                percent: 25.,
                engines: vec![("rcs0".into(), 25.)],
            }),
            client_activity: Some(0.),
            ..Default::default()
        };
        assert_eq!(gpu.activity(), Some((ActivitySource::Engines, 25.)));
        gpu.engine_activity.as_mut().unwrap().percent = 101.;
        assert_eq!(gpu.activity(), Some((ActivitySource::Clients, 0.)));
        gpu.client_activity = Some(f64::INFINITY);
        assert!(gpu.activity().is_none());
    }
}

#[cfg(test)]
mod sampling_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;
    #[test]
    fn sensor_reset_wakes_the_existing_sampler_and_preserves_selection() {
        let worker = Worker::spawn(MetricSelection::default(), 10000, move |_, _| {
            let root = std::env::temp_dir().join("xrg-missing-sensor-reset-roots");
            Sampler::with_sources(LinuxSources::with_roots(
                root.join("proc"),
                root.join("sys"),
            ))
        });
        let slot = worker.latest.clone();
        let (send, receive) = std::sync::mpsc::channel();
        worker.on_publish(move || {
            if let Some(snapshot) = slot.lock().unwrap().take() {
                send.send(snapshot).unwrap();
            }
        });
        let first = receive.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(first.sensors.generation, 0);
        let control = worker.sensor_stats_control();
        control.reset().unwrap();
        let next = receive.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(next.sequence, first.sequence + 1);
        assert_eq!(next.sensors.generation, 1);
        assert_eq!(next.selection, first.selection);
        drop(worker);
        assert!(control.reset().is_err());
    }
    #[test]
    fn publication_notification_reads_slot_and_retiming_without_ui_polling() {
        let worker = Worker::spawn(MetricSelection::default(), 10000, move |_, _| {
            let root = std::env::temp_dir().join("xrg-missing-notification-roots");
            Sampler::with_sources(LinuxSources::with_roots(
                root.join("proc"),
                root.join("sys"),
            ))
        });
        let slot = worker.latest.clone();
        let (send, receive) = std::sync::mpsc::channel();
        worker.on_publish(move || {
            if let Some(snapshot) = slot.lock().unwrap().take() {
                send.send(snapshot.sequence).unwrap();
            }
        });
        assert_eq!(receive.recv_timeout(Duration::from_secs(5)).unwrap(), 1);
        worker.sampling_control().set(250).unwrap();
        assert_eq!(receive.recv_timeout(Duration::from_secs(5)).unwrap(), 2);
        // Stop before dropping the receiver, so teardown publications remain valid.
        drop(worker);
    }
    #[test]
    fn retiming_wakes_the_same_sampler_without_rebuilding_sources_or_resetting_sequence() {
        let builds = Arc::new(AtomicUsize::new(0));
        let observed = builds.clone();
        let worker = Worker::spawn(MetricSelection::default(), 10000, move |_, _| {
            observed.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir()
                .join(format!("xrg-missing-sampling-roots-{}", std::process::id()));
            Sampler::with_sources(LinuxSources::with_roots(
                root.join("proc"),
                root.join("sys"),
            ))
        });
        let wait_for = |sequence| {
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                if let Some(snapshot) = worker.latest.lock().unwrap().as_ref()
                    && snapshot.sequence >= sequence
                {
                    return snapshot.sequence;
                }
                assert!(
                    Instant::now() < deadline,
                    "Sampling did not wake before the original ten-second deadline"
                );
                thread::sleep(Duration::from_millis(5));
            }
        };
        assert_eq!(wait_for(1), 1);
        let control = worker.sampling_control();
        control.set(250).unwrap();
        assert!(wait_for(2) >= 2);
        assert_eq!(builds.load(Ordering::Relaxed), 1);
        assert!(control.set(0).is_err());
        drop(worker);
        assert!(control.set(500).is_err());
    }
}

#[cfg(test)]
mod npu_client_history_tests {
    use super::*;
    use crate::{
        hardware::Readings,
        tpu::{ClientActivity, Device, Family, Report},
    };
    fn report(scope: &str, percent: Option<f64>, device_percent: Option<f64>) -> Report {
        Report {
            devices: Ok(Readings {
                values: vec![Device {
                    id: "fixture-amd-npu".into(),
                    label: "AMD fixture".into(),
                    family: Family::Amd,
                    initialized: true,
                    suspended: false,
                    temperature_c: None,
                    driver: Some("amdxdna".into()),
                    capability_only: false,
                    utilization: device_percent,
                    frequency_mhz: None,
                    memory_bytes: None,
                    busy_time_us: None,
                    notes: Vec::new(),
                    client_activity: Some(ClientActivity {
                        percent,
                        clients: 2,
                        scope: scope.into(),
                    }),
                }],
                errors: Vec::new(),
            }),
            inference: Err("No fixture inference producer".into()),
        }
    }
    #[test]
    fn retained_npu_capacity_survives_source_and_quantity_mode_changes() {
        let mut sampler = Sampler::with_sources(LinuxSources::with_roots(
            "/no-proc-fixture",
            "/no-sys-fixture",
        ));
        let mut selection = MetricSelection::default();
        selection.history_samples.insert(Module::Tpu, 3);
        sampler.set_selection(selection.clone()).unwrap();
        sampler.tpu_panel_from(report("one", Some(50.), None));
        sampler.tpu_panel_from(report("one", Some(40.), None));
        selection.history_samples.insert(Module::Tpu, 6);
        sampler.set_selection(selection.clone()).unwrap();
        let p = sampler.tpu_panel_from(report("one", Some(30.), None));
        assert_eq!(p.series[0].len(), 6);
        assert_eq!(&p.series[0][3..], &[50., 40., 30.]);
        assert!(p.series[0][..2].iter().all(|v| v.is_nan()));
        let p = sampler.tpu_panel_from(report("two", Some(20.), None));
        assert_eq!(p.series[0].len(), 6);
        assert_eq!(p.series[0][5], 20.);
        assert!(!p.series[0].contains(&30.));
        let p = sampler.tpu_panel_from(report("two", None, None));
        assert!(p.series.is_empty());
        assert_eq!(sampler.tpu_history.values().len(), 6);
        let p = sampler.tpu_panel_from(report("two", Some(0.), Some(25.)));
        assert_eq!(p.series[0].len(), 6);
        assert_eq!(p.series[0][5], 25.);
        sampler.clear_graph(Module::Tpu);
        let p = sampler.tpu_panel_from(report("two", Some(0.), Some(25.)));
        assert!(p.series[0][..5].iter().all(|v| v.is_nan()));
        selection.history_samples.remove(&Module::Tpu);
        sampler.set_selection(selection).unwrap();
        assert_eq!(
            sampler
                .tpu_panel_from(report("two", Some(0.), Some(25.)))
                .series[0]
                .len(),
            120
        );
    }
    #[test]
    fn client_scope_warmup_and_device_source_changes_never_join_unrelated_histories() {
        let mut sampler = Sampler::with_sources(LinuxSources::with_roots(
            "/no-proc-fixture",
            "/no-sys-fixture",
        ));
        let warm = sampler.tpu_panel_from(report("one", None, None));
        assert!(warm.series.is_empty());
        assert!(matches!(warm.scale, Scale::Percent));
        let first = sampler.tpu_panel_from(report("one", Some(50.), None));
        assert!(first.label.contains("clients"));
        let same = sampler.tpu_panel_from(report("one", Some(40.), None));
        assert_eq!(&same.series[0][118..], &[50., 40.]);
        let changed = sampler.tpu_panel_from(report("two", Some(20.), None));
        assert_eq!(&changed.series[0][118..], &[0., 20.]);
        assert!(
            sampler
                .tpu_panel_from(report("two", None, None))
                .series
                .is_empty()
        );
        let recovered = sampler.tpu_panel_from(report("two", Some(10.), None));
        assert_eq!(&recovered.series[0][118..], &[0., 10.]);
        let device = sampler.tpu_panel_from(report("two", Some(10.), Some(30.)));
        assert_eq!(&device.series[0][118..], &[0., 30.]);
        assert!(!device.label.contains("clients"));
    }
}

#[cfg(test)]
mod xe_policy_wake_tests {
    use super::*;
    #[test]
    fn policy_changes_wake_the_same_worker_and_publish_the_new_selection() {
        use std::{
            sync::atomic::{AtomicUsize, Ordering},
            time::Duration,
        };
        let builds = Arc::new(AtomicUsize::new(0));
        let count = builds.clone();
        let worker = Worker::spawn(MetricSelection::default(), 10000, move |_, _| {
            count.fetch_add(1, Ordering::Relaxed);
            let root =
                std::env::temp_dir().join(format!("xrg-xe-absent-roots-{}", std::process::id()));
            Sampler::with_sources(LinuxSources::with_roots(
                root.join("proc"),
                root.join("sys"),
            ))
        });
        let wait = |expected: bool, minimum: u64| {
            let end = Instant::now() + Duration::from_secs(3);
            loop {
                if let Some(snapshot) = worker.latest.lock().unwrap().take()
                    && snapshot.sequence >= minimum
                    && snapshot.selection.xe_pmu == expected
                {
                    return;
                }
                assert!(
                    Instant::now() < end,
                    "Policy change slept until the ten-second deadline"
                );
                thread::sleep(Duration::from_millis(5));
            }
        };
        wait(false, 1);
        worker
            .set_selection(MetricSelection {
                xe_pmu: true,
                ..Default::default()
            })
            .unwrap();
        wait(true, 2);
        worker.set_selection(MetricSelection::default()).unwrap();
        wait(false, 3);
        assert_eq!(builds.load(Ordering::Relaxed), 1);
    }
}
