// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::{
    collectors::{Cpu, LinuxSources, cpu_percent},
    shared::{History, Rates},
};
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
}
pub struct Sampler {
    source: LinuxSources,
    previous_cpu: Option<Cpu>,
    rates: Rates,
    histories: [History; 7],
    battery_histories: BTreeMap<String, History>,
    gpu: crate::gpu::GpuCollector,
    gpu_histories: BTreeMap<String, (bool, History)>,
    start: Instant,
    sequence: u64,
}
impl Sampler {
    pub fn new() -> Self {
        Self::with_sources(LinuxSources::live())
    }
    pub fn with_sources(source: LinuxSources) -> Self {
        let gpu = source.gpu_collector();
        Self {
            source,
            gpu,
            gpu_histories: BTreeMap::new(),
            previous_cpu: None,
            rates: Rates::new(),
            histories: array::from_fn(|_| History::new(120)),
            battery_histories: BTreeMap::new(),
            start: Instant::now(),
            sequence: 0,
        }
    }
    pub fn sample(&mut self) -> Snapshot {
        let time = self.start.elapsed().as_secs_f64();
        let cpu = self.source.cpu().and_then(|next| {
            let value = self.previous_cpu.and_then(|prev| cpu_percent(prev, next));
            self.previous_cpu = Some(next);
            value.ok_or_else(|| "Waiting for CPU interval".into())
        });
        let memory = self.source.memory();
        let network = self.source.network().map(|v| {
            [
                self.rates.sample(0, v[0], time).1 as f64,
                self.rates.sample(1, v[1], time).1 as f64,
            ]
        });
        let disk = self.source.disk().map(|v| {
            [
                self.rates.sample(2, v[0], time).1 as f64,
                self.rates.sample(3, v[1], time).1 as f64,
            ]
        });
        let valid = cpu.is_ok() && memory.is_ok() && network.is_ok() && disk.is_ok();
        let mut panels = Vec::new();
        for (index, title, result) in [(0, "CPU", cpu), (1, "Memory", memory)] {
            let label = match result {
                Ok(value) => {
                    self.histories[index].append(value);
                    format!("{value:.1}%")
                }
                Err(error) => error,
            };
            panels.push(Panel {
                title,
                detail: label.clone(),
                label,
                series: vec![self.histories[index].values()],
                scale: Scale::Percent,
            });
        }
        for (index, title, result) in [(2, "Network", network), (4, "Disk", disk)] {
            let label = match result {
                Ok([a, b]) => {
                    self.histories[index].append(a);
                    self.histories[index + 1].append(b);
                    format!("{} / {}", bytes_per_second(a), bytes_per_second(b))
                }
                Err(error) => error,
            };
            panels.push(Panel {
                title,
                detail: label.clone(),
                label,
                series: vec![
                    self.histories[index].values(),
                    self.histories[index + 1].values(),
                ],
                scale: Scale::Automatic,
            });
        }
        panels.push(self.battery_panel());
        panels.push(self.temperature_panel());
        panels.push(self.gpu_panel());
        self.sequence += 1;
        Snapshot {
            sequence: self.sequence,
            panels,
            valid,
        }
    }
    fn gpu_panel(&mut self) -> Panel {
        let mut series = Vec::new();
        let (label, detail) = match self.gpu.sample() {
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
        Panel {
            title: "GPU",
            label,
            detail,
            series,
            scale: Scale::Percent,
        }
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
                if !report.errors.is_empty() {
                    label.push_str(" · partial");
                }
                let mut detail: Vec<_> = report
                    .values
                    .iter()
                    .map(|v| {
                        let power = v.watts.map(|w| format!(" · {w:.1} W")).unwrap_or_default();
                        format!("{}: {:.1}% · {}{power}", v.name, v.percent, v.status)
                    })
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
                    self.histories[6] = History::new(120);
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
                self.histories[6].append(maximum);
                series.push(self.histories[6].values());
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
fn bytes_per_second(value: f64) -> String {
    if value >= 1_048_576. {
        format!("{:.1} MiB/s", value / 1_048_576.)
    } else if value >= 1024. {
        format!("{:.1} KiB/s", value / 1024.)
    } else {
        format!("{value:.0} B/s")
    }
}

pub struct Worker {
    pub latest: Arc<Mutex<Option<Snapshot>>>,
    stop: Option<mpsc::Sender<()>>,
    join: Option<thread::JoinHandle<()>>,
}
impl Worker {
    pub fn start() -> Self {
        let latest = Arc::new(Mutex::new(None));
        let output = latest.clone();
        let (stop, receiver) = mpsc::channel();
        let join = thread::spawn(move || {
            // Swift handles are created and destroyed on this worker only.
            let mut sampler = Sampler::new();
            loop {
                let next_sample = Instant::now() + Duration::from_secs(1);
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
        }
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
