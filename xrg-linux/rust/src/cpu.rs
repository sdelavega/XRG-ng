// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! CPU interval presentation and independently available system load/uptime.
use crate::{
    collectors::{LinuxSources, cpu_usage},
    engine::{Panel, Scale},
    metric_sources::{self, CpuRecords},
    shared::{History, cpu_interval_valid},
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
    // The shared finite-only history ABI stores placeholders for gaps. Keep
    // validity separately so unread intervals and initial padding never plot 0%.
    observed: Vec<bool>,
    scope: Option<Vec<u32>>,
}
impl Default for View {
    fn default() -> Self {
        Self {
            previous: None,
            selected: None,
            histories: std::array::from_fn(|_| History::new(120)),
            observed: vec![false; 120],
            scope: None,
        }
    }
}
impl View {
    pub fn set_history_samples(&mut self, requested: u32) -> Result<(), String> {
        if requested > crate::shared::sampling_settings()[3] {
            return Err("CPU history capacity is out of range".into());
        }
        let capacity = if requested == 0 {
            120
        } else {
            requested as usize
        };
        if capacity != self.observed.len() {
            let count = capacity.min(self.observed.len());
            let mut observed = vec![false; capacity];
            observed[capacity - count..]
                .copy_from_slice(&self.observed[self.observed.len() - count..]);
            for history in &mut self.histories {
                history.resize(capacity as u32);
            }
            self.observed = observed;
        }
        Ok(())
    }
    pub fn clear_graph(&mut self) {
        for history in &mut self.histories {
            history.clear();
        }
        self.observed.fill(false);
    }
    pub fn reset_history(&mut self) {
        self.clear_graph();
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
        let mut readout = crate::dashboard::Readout::default();
        let mut inventory = Vec::new();
        if records.is_err() {
            self.previous = None;
        }
        let result = records.and_then(|next| {
            inventory = next.cores.keys().copied().collect();
            let scope = selected.map_or_else(
                || inventory.clone(),
                |id| {
                    next.cores
                        .contains_key(&id)
                        .then_some(id)
                        .into_iter()
                        .collect()
                },
            );
            // Keep inventory across failed reads, independently of the interval
            // baseline, so recovery cannot combine different graph scopes.
            if self.scope.as_ref().is_some_and(|old| *old != scope) {
                self.reset_history();
            }
            self.scope = Some(scope);
            let previous = self.previous.take();
            if previous.as_ref().is_some_and(|(old, _)| {
                let pair = selected.map_or(Some((old.total, next.total)), |id| {
                    old.cores
                        .get(&id)
                        .zip(next.cores.get(&id))
                        .map(|(a, b)| (*a, *b))
                });
                pair.is_some_and(|(old, next)| {
                    old.fields != next.fields
                        || old.ticks.iter().zip(next.ticks).any(|(a, b)| b < *a)
                })
            }) {
                self.reset_history();
            }
            let previous = previous.filter(|(_, old)| cpu_interval_valid(*old, time));
            let same_members = previous
                .as_ref()
                .is_some_and(|(old, _)| old.cores.keys().eq(next.cores.keys()));
            valid = same_members
                && previous
                    .as_ref()
                    .and_then(|(old, _)| cpu_usage(old.total, next.total))
                    .is_some();
            readout.cores = next
                .cores
                .iter()
                .filter(|(id, _)| selected.is_none_or(|chosen| chosen == **id))
                .take(64)
                .map(|(id, current)| {
                    (
                        *id,
                        previous
                            .as_ref()
                            .and_then(|(old, _)| old.cores.get(id))
                            .and_then(|old| cpu_usage(*old, *current))
                            .map(|usage| usage.busy),
                    )
                })
                .collect();
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
        self.observed.rotate_left(1);
        *self.observed.last_mut().expect("Nonempty CPU history") = result.is_ok();
        let mut detail = Vec::new();
        let label = match result {
            Ok(value) => {
                use crate::dashboard::Row;
                readout.top.push(Row::new(
                    "CPU",
                    if selected.is_some() || inventory.is_empty() {
                        format!("{:.0}%", value.busy)
                    } else {
                        format!("{:.0}%", value.busy * inventory.len() as f64)
                    },
                ));
                readout
                    .top
                    .push(Row::new("Average", format!("{:.1}%", value.busy)));

                for (history, value) in
                    self.histories
                        .iter_mut()
                        .zip([value.busy, value.user, value.system])
                {
                    history.append(value);
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
                for history in &mut self.histories {
                    history.append(0.);
                }
                error
            }
        };
        let series = self
            .histories
            .iter()
            .map(|history| {
                history
                    .values()
                    .into_iter()
                    .zip(self.observed.iter().copied())
                    .map(|(value, observed)| if observed { value } else { f64::NAN })
                    .collect()
            })
            .collect();
        use crate::dashboard::Row;
        if readout.top.is_empty() {
            readout.top.push(Row::new("CPU", "n/a"));
        }
        readout.top.push(Row::new(
            "Load",
            overview
                .load
                .as_ref()
                .map(|load| format!("{:.2}", load.averages[0]))
                .unwrap_or_else(|_| "n/a".into()),
        ));
        readout.top.push(Row::new(
            "Uptime",
            overview
                .uptime
                .as_ref()
                .map(|v| crate::dashboard::uptime(*v))
                .unwrap_or_else(|_| "n/a".into()),
        ));
        detail.push("Graph-face CPU total uses core-percent (average × logical CPU count); Average and history use aggregate capacity, 0–100%. Load shows the one-minute system average. Per-core bars include reported steal time as non-idle and show at most 64 CPUs. Missing intervals remain gaps.".into());
        detail.insert(0, label.clone());
        detail.push(format!("Scope: {}. Graph curves: total non-idle / user including nice / system including reported interrupts; independent percentages, not stacked. Idle includes iowait for the total curve. Guest time already in user/nice is not counted twice. Steal is hypervisor wait, not executed CPU work. Counter regressions (including iowait), counter layout and scope changes clear the affected history. Failed reads, zero-progress counters and invalid or delayed intervals leave gaps while retaining earlier observations. CPU intervals must increase on the worker's monotonic clock and be at most five minutes; it excludes suspend on Linux. Recovery establishes a fresh baseline. Clearing graphs preserves the collector baseline.", selected.map(|id| format!("logical CPU {id}")).unwrap_or_else(|| "all reported logical CPUs (100% is aggregate capacity)".into())));
        detail.push(overview.description());
        detail.push(format!("CPU history capacity: {} samples. Capacity changes preserve newest samples, gaps and collector baselines. Sampling delays and cadence changes affect the actual retained time span.", self.observed.len()));
        (
            Panel {
                title: "CPU",
                label,
                detail: detail.join("\n\n"),
                series,
                scale: Scale::Percent,
                temperature_text: None,
                weather_plot: None,
                readout,
            },
            valid,
            inventory,
        )
    }
}
