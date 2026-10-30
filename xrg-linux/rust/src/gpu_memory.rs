// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Driver-reported VRAM pools only. Client allocations never become capacity.
use crate::{
    engine::{Panel, Scale},
    gpu::Gpu,
    hardware::Readings,
    shared::{History, TimedHistory},
};
use std::collections::BTreeMap;

#[derive(Default)]
pub struct View {
    histories: BTreeMap<String, (String, u64, History, TimedHistory)>,
    history_samples: u32,
    minutes: u32,
    interval: Option<f64>,
}
impl View {
    pub fn set_time_window(&mut self, minutes: u32) -> Result<(), String> {
        if minutes > crate::shared::timed_projection_settings()[0] {
            return Err("VRAM window must be 0..60 minutes".into());
        }
        self.minutes = minutes;
        Ok(())
    }
    pub fn set_history_interval(&mut self, seconds: f64) {
        if seconds.is_finite() && seconds >= 0.2 {
            self.interval = Some(seconds);
        }
    }
    fn capacity(&self) -> u32 {
        if self.history_samples == 0 {
            120
        } else {
            self.history_samples
        }
    }
    pub fn set_history_samples(&mut self, count: u32) -> Result<(), String> {
        if count > crate::shared::sampling_settings()[3] {
            return Err("VRAM history capacity is out of range".into());
        }
        let old = self.capacity();
        self.history_samples = count;
        let capacity = self.capacity();
        if old != capacity {
            for (_, _, h, _) in self.histories.values_mut() {
                h.resize(capacity);
            }
        }
        Ok(())
    }
    pub fn clear_graph(&mut self) {
        for (_, _, h, timed) in self.histories.values_mut() {
            h.clear();
            timed.clear();
        }
    }
    pub fn reset(&mut self) {
        self.histories.clear();
    }
    pub fn panel(&mut self, report: &Result<Readings<Gpu>, String>) -> Panel {
        let observed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|v| v.as_secs_f64())
            .unwrap_or(f64::NAN);
        self.panel_at(report, observed)
    }
    pub fn panel_at(&mut self, report: &Result<Readings<Gpu>, String>, observed: f64) -> Panel {
        let mut panel = Panel {
            title: "VRAM",
            label: "VRAM counters unavailable".into(),
            detail: String::new(),
            series: Vec::new(),
            scale: Scale::Percent,
            temperature_text: None,
            weather_plot: None,
            readout: Default::default(),
        };
        let report = match report {
            Ok(report) => report,
            Err(error) => {
                self.reset();
                panel.detail = error.clone();
                return panel;
            }
        };
        let valid = |gpu: &&Gpu| matches!((gpu.memory_used, gpu.memory_total), (Some(used), Some(total)) if total > 0 && used <= total);
        let available: Vec<_> = report.values.iter().filter(valid).collect();
        self.histories
            .retain(|id, _| available.iter().take(3).any(|g| g.id == *id));
        let mut labels = Vec::new();
        let mut details = vec!["Graph: driver-reported VRAM pool used / total; this does not identify physical memory topology. System RAM and readable-client allocations are not used as VRAM totals.".into()];
        for gpu in &report.values {
            let counters = match (gpu.memory_used, gpu.memory_total) {
                (Some(used), Some(total)) if total > 0 && used <= total => format!(
                    "{:.1} / {:.1} MiB VRAM pool",
                    used as f64 / 1_048_576.,
                    total as f64 / 1_048_576.
                ),
                (Some(used), None) => format!(
                    "{:.1} MiB used reported; VRAM total unavailable",
                    used as f64 / 1_048_576.
                ),
                _ => "VRAM counters unavailable".into(),
            };
            details.push(format!(
                "{} · {} · {}\n{counters}",
                gpu.label, gpu.name, gpu.id
            ));
            details.extend(gpu.notes.clone());
        }
        for gpu in available.iter().take(3) {
            let used = gpu.memory_used.unwrap();
            let total = gpu.memory_total.unwrap();
            let capacity = self.capacity();
            let history = self.histories.entry(gpu.id.clone()).or_insert_with(|| {
                (
                    gpu.driver.clone(),
                    total,
                    History::new(capacity),
                    TimedHistory::new_limited(1, 60),
                )
            });
            if history.0 != gpu.driver || history.1 != total {
                *history = (
                    gpu.driver.clone(),
                    total,
                    History::new(capacity),
                    TimedHistory::new_limited(1, 60),
                );
            }
            let percent = 100. * used as f64 / total as f64;
            history.2.append(percent);
            history.3.append(observed, &[percent]);
            panel.series.push(if self.minutes > 0 {
                history
                    .3
                    .values_at(self.minutes, self.interval.unwrap_or(1.))
                    .remove(0)
            } else {
                history.2.values()
            });
            labels.push(format!("{} {percent:.1}%", gpu.label));
        }
        if !labels.is_empty() {
            panel.label = format!(
                "{}{}",
                labels.join(" / "),
                if available.len() > 3 { " (+more)" } else { "" }
            );
        }
        if !report.errors.is_empty() || report.values.iter().any(|gpu| !gpu.notes.is_empty()) {
            panel.label.push_str(" · partial");
        }
        details.extend(report.errors.clone());
        panel.detail = details.join("\n\n");
        panel
    }
}
