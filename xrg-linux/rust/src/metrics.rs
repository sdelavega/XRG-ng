// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::{
    collectors::{LinuxSources, cpu_percent},
    engine::{Panel, Scale},
    metric_sources::{self, CpuRecords, Devices},
    settings::MetricSelection,
    shared::{History, Rates},
};
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GpuOption {
    pub id: String,
    pub label: String,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Inventory {
    pub cpus: Vec<u32>,
    pub networks: Vec<String>,
    pub disks: Vec<String>,
    pub gpus: Vec<GpuOption>,
}
struct IoHistory {
    rates: Rates,
    histories: [History; 2],
    membership: Option<Vec<String>>,
}
impl IoHistory {
    fn new() -> Self {
        Self {
            rates: Rates::new(),
            histories: std::array::from_fn(|_| History::new(120)),
            membership: None,
        }
    }
    fn reset(&mut self) {
        *self = Self::new();
    }
    fn panel(
        &mut self,
        title: &'static str,
        source: Result<Devices, String>,
        target: Option<&str>,
        time: f64,
    ) -> (Panel, bool, Vec<String>) {
        let mut valid = false;
        let mut names = Vec::new();
        let mut series = Vec::new();
        let mut detail = String::new();
        let values = source.and_then(|devices| {
            let empty_disk = title == "Disk" && devices.aggregate.is_empty();
            valid = !empty_disk && devices.values(None).is_ok();
            names = devices.devices.keys().cloned().collect();
            if devices.identity_incomplete {
                detail.push_str("Some sysfs identity metadata is unavailable; replacement detection is limited.\n");
            }
            if target.is_none() && empty_disk {
                return Err("No complete physical disk counters".into());
            }
            let (values, identities) = devices.values(target)?;
            let members: Vec<_> = target
                .map(|t| vec![t.to_owned()])
                .unwrap_or_else(|| devices.aggregate.iter().cloned().collect());
            let visible = members.iter().take(16)
                .map(|n| crate::hardware::short_label(n))
                .collect::<Vec<_>>().join(", ");
            let scope = target.unwrap_or(if title == "Disk" {
                "all physical disks"
            } else {
                "all non-loopback interfaces"
            });
            let suffix = if members.len() > 16 { " (+more)" } else { "" };
            let visible = if visible.is_empty() { "none" } else { &visible };
            detail.push_str(&format!("Scope: {scope}\nMembers ({}): {visible}{suffix}", members.len()));
            Ok((values, identities))
        });
        let label = match values {
            Ok((values, membership)) => {
                if self.membership.as_ref() != Some(&membership) {
                    self.reset();
                    self.membership = Some(membership);
                }
                let a = self.rates.sample(0, values[0], time).1 as f64;
                let b = self.rates.sample(1, values[1], time).1 as f64;
                self.histories[0].append(a);
                self.histories[1].append(b);
                series = self.histories.iter().map(History::values).collect();
                format!(
                    "{}{} / {}",
                    target.map(|t| format!("{t} · ")).unwrap_or_default(),
                    super::engine::bytes_per_second(a),
                    super::engine::bytes_per_second(b)
                )
            }
            Err(error) => {
                self.reset();
                detail = error.clone();
                error
            }
        };
        (
            Panel {
                title,
                label,
                series,
                scale: Scale::Automatic,
                detail,
            },
            valid,
            names,
        )
    }
}
pub struct Sampler {
    selection: MetricSelection,
    previous: Option<CpuRecords>,
    cpu: History,
    network: IoHistory,
    disk: IoHistory,
}
pub struct Sample {
    pub cpu: Panel,
    pub network: Panel,
    pub disk: Panel,
    pub inventory: Inventory,
    pub valid: bool,
}
impl Default for Sampler {
    fn default() -> Self {
        Self {
            selection: MetricSelection::default(),
            previous: None,
            cpu: History::new(120),
            network: IoHistory::new(),
            disk: IoHistory::new(),
        }
    }
}
impl Sampler {
    pub fn selection(&self) -> &MetricSelection {
        &self.selection
    }
    pub fn set_selection(&mut self, selection: MetricSelection) -> Result<(), String> {
        selection.validate()?;
        if self.selection.cpu != selection.cpu {
            self.cpu = History::new(120);
        }
        if self.selection.network != selection.network {
            self.network.reset();
        }
        if self.selection.disk != selection.disk {
            self.disk.reset();
        }
        self.selection = selection;
        Ok(())
    }
    pub fn sample(&mut self, source: &LinuxSources, time: f64) -> Sample {
        if !time.is_finite() || time < 0. {
            self.previous = None;
            self.cpu = History::new(120);
            self.network.reset();
            self.disk.reset();
            let panel = |title| Panel {
                title,
                label: "Invalid sample time".into(),
                detail: "Invalid sample time".into(),
                series: Vec::new(),
                scale: Scale::Automatic,
            };
            return Sample {
                cpu: panel("CPU"),
                network: panel("Network"),
                disk: panel("Disk"),
                inventory: Inventory::default(),
                valid: false,
            };
        }
        let mut inventory = Inventory::default();
        let mut valid_cpu = false;
        let mut series = Vec::new();
        let selected = self.selection.cpu;
        let records = metric_sources::cpus(source);
        if records.is_err() {
            self.previous = None;
        }
        let value = records.and_then(|next| {
            inventory.cpus = next.cores.keys().copied().collect();
            valid_cpu = self
                .previous
                .as_ref()
                .and_then(|old| cpu_percent(old.total, next.total))
                .is_some();
            let value = if let Some(id) = selected {
                next.cores
                    .get(&id)
                    .ok_or_else(|| format!("CPU {id} unavailable"))
                    .and_then(|cpu| {
                        self.previous
                            .as_ref()
                            .and_then(|p| p.cores.get(&id))
                            .and_then(|old| cpu_percent(*old, *cpu))
                            .ok_or_else(|| format!("CPU {id} waiting for interval"))
                    })
            } else {
                self.previous
                    .as_ref()
                    .and_then(|p| cpu_percent(p.total, next.total))
                    .ok_or_else(|| "Waiting for CPU interval".into())
            };
            self.previous = Some(next);
            value
        });
        let label = match value {
            Ok(value) => {
                self.cpu.append(value);
                series.push(self.cpu.values());
                format!(
                    "{}{value:.1}%",
                    selected
                        .map(|id| format!("CPU {id} · "))
                        .unwrap_or_default()
                )
            }
            Err(error) => {
                self.cpu = History::new(120);
                error
            }
        };
        let cpu = Panel {
            title: "CPU",
            detail: format!(
                "{label}\n{}",
                if selected.is_some() {
                    "One logical CPU; idle includes iowait; guest time is not counted twice."
                } else {
                    "Aggregate CPU; idle includes iowait; guest time is not counted twice."
                }
            ),
            label,
            series,
            scale: Scale::Percent,
        };
        let (network, valid_network, names) = self.network.panel(
            "Network",
            metric_sources::network(source),
            self.selection.network.as_deref(),
            time,
        );
        inventory.networks = names;
        let (disk, valid_disk, names) = self.disk.panel(
            "Disk",
            metric_sources::disks(source),
            self.selection.disk.as_deref(),
            time,
        );
        inventory.disks = names;
        Sample {
            cpu,
            network,
            disk,
            inventory,
            valid: valid_cpu && valid_network && valid_disk,
        }
    }
}
