// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::{
    collectors::LinuxSources,
    engine::{Panel, Scale},
    metric_sources::{self, Devices},
    settings::MetricSelection,
    shared::{History, Rates},
};
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SourceOption {
    pub id: String,
    pub label: String,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Inventory {
    pub cpus: Vec<u32>,
    pub networks: Vec<String>,
    pub disks: Vec<String>,
    pub gpus: Vec<SourceOption>,
    pub temperatures: Vec<SourceOption>,
    pub fans: Vec<SourceOption>,
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
        let mut readout = crate::dashboard::Readout::default();
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
                use crate::dashboard::{Row, bytes};
                let (heading, first, second) = if title == "Disk" {
                    ("Disk", "Read", "Write")
                } else {
                    ("Net", "Rx", "Tx")
                };
                readout.top = vec![
                    Row::new(heading, ""),
                    Row::new(format!("{first} total"), bytes(values[0] as f64)),
                    Row::new(format!("{second} total"), bytes(values[1] as f64)),
                ];
                readout.bottom = vec![
                    Row::new(first, format!("{}/s", bytes(a))),
                    Row::new(second, format!("{}/s", bytes(b))),
                ];
                detail.push_str("\nGraph-face totals are kernel lifetime counters for the selected devices (normally since boot); compact byte units use powers of 1024. They are not disk capacity or session transfers.");
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
                temperature_text: None,
                readout,
                detail,
            },
            valid,
            names,
        )
    }
}
pub struct Sampler {
    selection: MetricSelection,
    cpu: crate::cpu::View,
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
            cpu: crate::cpu::View::default(),
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
            self.cpu.reset_history();
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
            self.cpu = crate::cpu::View::default();
            self.network.reset();
            self.disk.reset();
            let panel = |title| Panel {
                title,
                label: "Invalid sample time".into(),
                detail: "Invalid sample time".into(),
                series: Vec::new(),
                scale: Scale::Automatic,
                temperature_text: None,
                readout: Default::default(),
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
        let (cpu, valid_cpu, cpus) = self.cpu.sample(source, self.selection.cpu, time);
        inventory.cpus = cpus;
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
