// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::{
    collectors::{Cpu, LinuxSources, cpu_percent},
    shared::{History, Rates},
};
use std::{
    array,
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Debug)]
pub struct Panel {
    pub title: &'static str,
    pub label: String,
    pub series: Vec<Vec<f64>>,
    pub percent: bool,
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
    histories: [History; 6],
    start: Instant,
    sequence: u64,
}
impl Sampler {
    pub fn new() -> Self {
        Self {
            source: LinuxSources::live(),
            previous_cpu: None,
            rates: Rates::new(),
            histories: array::from_fn(|_| History::new(120)),
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
                label,
                series: vec![self.histories[index].values()],
                percent: true,
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
                label,
                series: vec![
                    self.histories[index].values(),
                    self.histories[index + 1].values(),
                ],
                percent: false,
            });
        }
        self.sequence += 1;
        Snapshot {
            sequence: self.sequence,
            panels,
            valid,
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
                *output.lock().unwrap() = Some(sampler.sample());
                // One latest-value slot bounds memory if drawing is slow or hidden.
                match receiver.recv_timeout(Duration::from_secs(1)) {
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
