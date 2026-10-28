// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! CPU interval presentation and independently available system load/uptime.
use crate::{
    collectors::{LinuxSources, cpu_usage},
    engine::{Panel, Scale},
    metric_sources::{self, CpuRecords},
    shared::History,
    system_file,
};
use std::{path::Path, time::Duration};

#[derive(Clone, Debug, PartialEq)]
pub struct Load {
    pub averages: [f64; 3],
    pub runnable: u64,
    pub tasks: u64,
    pub last_pid: u32,
}
fn words(text: &str, count: usize) -> Result<Vec<&str>, String> {
    let fields: Vec<_> = text.split_whitespace().take(count + 1).collect();
    if text.len() > 4096
        || text.lines().filter(|s| !s.trim().is_empty()).count() != 1
        || fields.len() != count
    {
        return Err("Invalid load/uptime record size or layout".into());
    }
    Ok(fields)
}
fn unsigned(text: &str) -> Result<u64, String> {
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err("Invalid task counter".into());
    }
    text.parse().map_err(|_| "Task counter overflow".into())
}
fn decimal(text: &str) -> Result<f64, String> {
    let mut parts = text.split('.');
    let integer = parts.next().unwrap_or("");
    let fraction = parts.next();
    if integer.is_empty()
        || !integer.bytes().all(|b| b.is_ascii_digit())
        || parts.next().is_some()
        || fraction.is_some_and(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err("Invalid nonnegative decimal".into());
    }
    let value = text.parse::<f64>().map_err(|_| "Invalid decimal")?;
    if !value.is_finite() {
        return Err("Nonfinite decimal".into());
    }
    Ok(value)
}
pub fn load(text: &str) -> Result<Load, String> {
    let fields = words(text, 5)?;
    let (runnable, tasks) = fields[3].split_once('/').ok_or("Invalid task counts")?;
    let runnable = unsigned(runnable)?;
    let tasks = unsigned(tasks)?;
    if tasks == 0 || runnable > tasks {
        return Err("Invalid runnable/total task counts".into());
    }
    let last_pid = u32::try_from(unsigned(fields[4])?).map_err(|_| "Invalid last PID")?;
    if last_pid > i32::MAX as u32 {
        return Err("Invalid last PID".into());
    }
    Ok(Load {
        averages: [
            decimal(fields[0])?,
            decimal(fields[1])?,
            decimal(fields[2])?,
        ],
        runnable,
        tasks,
        last_pid,
    })
}
pub fn uptime(text: &str) -> Result<Duration, String> {
    let fields = words(text, 2)?;
    // Idle is summed over CPUs and can exceed elapsed uptime. Never divide it
    // by uptime to infer busy percent, especially after hotplug or suspend.
    decimal(fields[1])?;
    Duration::try_from_secs_f64(decimal(fields[0])?).map_err(|_| "Uptime is out of range".into())
}
#[derive(Clone, Debug)]
pub struct Overview {
    pub load: Result<Load, String>,
    pub uptime: Result<Duration, String>,
}
fn text(root: &Path, name: &str) -> Result<String, String> {
    String::from_utf8(
        system_file::read(&root.join(name), 4096).map_err(|e| format!("{name}: {e}"))?,
    )
    .map_err(|_| format!("Invalid {name} encoding"))
}
pub fn overview(root: &Path) -> Overview {
    Overview {
        load: text(root, "loadavg").and_then(|s| load(&s)),
        uptime: text(root, "uptime").and_then(|s| uptime(&s)),
    }
}
impl Overview {
    fn description(&self) -> String {
        let load = match &self.load {
            Ok(load) => format!(
                "System-wide load average (1 / 5 / 15 min): {:.2} / {:.2} / {:.2}\nRunnable / total scheduling entities: {} / {}\nLast created PID: {}",
                load.averages[0],
                load.averages[1],
                load.averages[2],
                load.runnable,
                load.tasks,
                load.last_pid
            ),
            Err(error) => format!("Load average: unavailable ({error})"),
        };
        let uptime = match &self.uptime {
            Ok(value) => {
                let seconds = value.as_secs();
                format!(
                    "Uptime: {}d {:02}:{:02}:{:02} (includes suspend)",
                    seconds / 86400,
                    seconds / 3600 % 24,
                    seconds / 60 % 60,
                    seconds % 60
                )
            }
            Err(error) => format!("Uptime: unavailable ({error})"),
        };
        format!(
            "{load}\n{uptime}\nLoad averages count runnable and uninterruptible-I/O tasks, not CPU percent. Task counts include threads; the Processes panel counts readable process leaders. Load/uptime describe the exposed /proc scope and stay system-wide when one logical CPU is selected."
        )
    }
}
pub struct View {
    previous: Option<(CpuRecords, f64)>,
    selected: Option<u32>,
    histories: [History; 3],
}
impl Default for View {
    fn default() -> Self {
        Self {
            previous: None,
            selected: None,
            histories: std::array::from_fn(|_| History::new(120)),
        }
    }
}
impl View {
    pub fn reset_history(&mut self) {
        self.histories = std::array::from_fn(|_| History::new(120));
    }
    pub fn sample(
        &mut self,
        source: &LinuxSources,
        selected: Option<u32>,
        time: f64,
    ) -> (Panel, bool, Vec<u32>) {
        self.panel(
            metric_sources::cpus(source),
            &overview(source.proc_root()),
            selected,
            time,
        )
    }
    pub fn panel(
        &mut self,
        records: Result<CpuRecords, String>,
        overview: &Overview,
        selected: Option<u32>,
        time: f64,
    ) -> (Panel, bool, Vec<u32>) {
        if selected != self.selected {
            self.reset_history();
            self.selected = selected;
        }
        let mut valid = false;
        let mut inventory = Vec::new();
        if records.is_err() {
            self.previous = None;
        }
        let result = records.and_then(|next| {
            inventory = next.cores.keys().copied().collect();
            let previous = self.previous.take().filter(|(_, old)| {
                time.is_finite() && time >= 0. && time > *old && time - old <= 300.
            });
            let same_members = previous
                .as_ref()
                .is_some_and(|(old, _)| old.cores.keys().eq(next.cores.keys()));
            valid = same_members
                && previous
                    .as_ref()
                    .and_then(|(old, _)| cpu_usage(old.total, next.total))
                    .is_some();
            let result = if let Some(id) = selected {
                next.cores
                    .get(&id)
                    .ok_or_else(|| format!("CPU {id} unavailable"))
                    .and_then(|current| {
                        previous
                            .as_ref()
                            .and_then(|(old, _)| old.cores.get(&id))
                            .and_then(|old| cpu_usage(*old, *current))
                            .ok_or_else(|| format!("CPU {id} waiting for interval"))
                    })
            } else {
                previous
                    .as_ref()
                    .filter(|_| same_members)
                    .and_then(|(old, _)| cpu_usage(old.total, next.total))
                    .ok_or_else(|| "Waiting for CPU interval".into())
            };
            if time.is_finite() && time >= 0. {
                self.previous = Some((next, time));
            }
            result
        });
        let mut series = Vec::new();
        let mut detail = Vec::new();
        let label = match result {
            Ok(value) => {
                for (history, value) in
                    self.histories
                        .iter_mut()
                        .zip([value.busy, value.user, value.system])
                {
                    history.append(value);
                    series.push(history.values());
                }
                detail.push(format!("Non-idle: {:.1}%\nUser including nice: {:.1}%\nNice (part of user): {:.1}%\nSystem including reported IRQ/softirq: {:.1}%\nIdle excluding iowait: {:.1}%", value.busy, value.user, value.nice, value.system, value.idle));
                detail.push(if value.fields >= 5 {
                    format!(
                        "I/O wait: {:.1}% (kernel accounting can regress)",
                        value.iowait
                    )
                } else {
                    "I/O wait: unavailable".into()
                });
                detail.push(if value.fields >= 8 {
                    format!(
                        "Steal: {:.1}% (hypervisor wait, included in non-idle)",
                        value.steal
                    )
                } else {
                    "Steal: unavailable".into()
                });
                format!(
                    "{}{:.1}% · usr {:.1}% · sys {:.1}%",
                    selected
                        .map(|id| format!("CPU {id} · "))
                        .unwrap_or_default(),
                    value.busy,
                    value.user,
                    value.system
                )
            }
            Err(error) => {
                self.reset_history();
                error
            }
        };
        detail.insert(0, label.clone());
        detail.push(format!("Scope: {}. Graph curves: total non-idle / user including nice / system including reported interrupts; independent percentages, not stacked. Idle includes iowait for the total curve. Guest time already in user/nice is not counted twice. Steal is hypervisor wait, not executed CPU work. Counter regressions (including iowait), CPU inventory changes for the aggregate, failed reads and invalid or delayed intervals clear the affected history.", selected.map(|id| format!("logical CPU {id}")).unwrap_or_else(|| "all reported logical CPUs (100% is aggregate capacity)".into())));
        detail.push(overview.description());
        (
            Panel {
                title: "CPU",
                label,
                detail: detail.join("\n\n"),
                series,
                scale: Scale::Percent,
                temperature_text: None,
            },
            valid,
            inventory,
        )
    }
}
