// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::{
    collectors::LinuxSources,
    engine::{Panel, Scale},
    metric_sources::{self, Devices},
    settings::{MetricSelection, Module},
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
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TransferTotals {
    pub bytes: [u64; 2],
    pub partial: bool,
    pub saturated: bool,
}
impl TransferTotals {
    fn add(&mut self, deltas: [u64; 2]) {
        for (total, delta) in self.bytes.iter_mut().zip(deltas) {
            match total.checked_add(delta) {
                Some(value) => *total = value,
                None => {
                    *total = u64::MAX;
                    self.saturated = true;
                }
            }
        }
    }
}
struct IoHistory {
    rates: Rates,
    histories: [History; 2],
    membership: Option<Vec<String>>,
    totals: TransferTotals,
    last_sample: Option<([u64; 2], f64)>,
    session_started: Option<f64>,
    skip_next_transfer: bool,
    graph_cleared: bool,
}
impl IoHistory {
    fn new() -> Self {
        Self {
            rates: Rates::new(),
            histories: std::array::from_fn(|_| History::new(120)),
            membership: None,
            totals: TransferTotals::default(),
            last_sample: None,
            session_started: None,
            skip_next_transfer: true,
            graph_cleared: false,
        }
    }
    fn clear_graph(&mut self) {
        for h in &mut self.histories {
            h.clear();
        }
        self.graph_cleared = true;
    }
    fn reset_transfers(&mut self) {
        self.totals = TransferTotals::default();
        self.session_started = None;
        self.skip_next_transfer = true;
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
                let counter_restarted = self.last_sample.is_some_and(|(old, at)| {
                    time > at && values.iter().zip(old).any(|(value, old)| *value < old)
                });
                if self.membership.as_ref() != Some(&membership) || counter_restarted {
                    self.reset();
                    self.membership = Some(membership);
                }
                let (delta_a, a) = self.rates.sample(0, values[0], time);
                let (delta_b, b) = self.rates.sample(1, values[1], time);
                let (a, b) = (a as f64, b as f64);
                if self.last_sample.is_none_or(|(_, at)| time > at) {
                    if self.skip_next_transfer {
                        self.skip_next_transfer = false;
                        self.totals.partial = false;
                        self.session_started = Some(time);
                    } else {
                        self.totals.add([delta_a, delta_b]);
                    }
                    self.last_sample = Some((values, time));
                }
                use crate::dashboard::{Row, bytes};
                let (first, second) = if title == "Disk" {
                    ("Read", "Write")
                } else {
                    ("Rx", "Tx")
                };
                readout.bottom = vec![
                    Row::new(first, format!("{}/s", bytes(a))),
                    Row::new(second, format!("{}/s", bytes(b))),
                ];
                detail.push_str(&format!("\nKernel totals (normally since boot): {first} {} bytes / {second} {} bytes. Compact units use powers of 1024; these are not disk capacities.", values[0], values[1]));
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
                // A failed interval cannot be reconstructed. Retain counted
                // transfers, but rebaseline rates and flag incomplete coverage.
                self.rates = Rates::new();
                self.histories = std::array::from_fn(|_| History::new(120));
                if self.graph_cleared {
                    for h in &mut self.histories {
                        h.clear();
                    }
                }
                self.totals.partial = true;
                detail = error.clone();
                error
            }
        };
        if self.membership.is_some() {
            use crate::dashboard::{Row, bytes};
            let (heading, first, second) = if title == "Disk" {
                ("Disk", "Read", "Write")
            } else {
                ("Net", "Rx", "Tx")
            };
            let prefix = if self.totals.partial || self.totals.saturated {
                "≥"
            } else {
                ""
            };
            readout.top = vec![
                Row::new(heading, ""),
                Row::new(
                    format!("{first} session"),
                    format!("{prefix}{}", bytes(self.totals.bytes[0] as f64)),
                ),
                Row::new(
                    format!("{second} session"),
                    format!("{prefix}{}", bytes(self.totals.bytes[1] as f64)),
                ),
            ];
            detail.push_str(&format!("\nSession observed transfers: {first} {} bytes / {second} {} bytes. {:.1}s since baseline. Totals count valid counter deltas since monitoring/start or Reset session transfers. Selection, membership, identity changes and counter restarts begin a new session. Reset graph history preserves totals; resetting transfers preserves rate baselines and graph history. The first sample establishes a baseline. Bridged/VPN/stacked devices may count traffic more than once.", self.totals.bytes[0], self.totals.bytes[1], self.session_started.map_or(0., |at| (time - at).max(0.))));
            if self.totals.partial {
                detail.push_str("\nPartial coverage: a read failed; missed intervals are excluded, and totals are a lower bound. Recovery establishes a fresh interval.");
            }
            if self.totals.saturated {
                detail.push_str(
                    "\nTransfer total saturated at UInt64 maximum; shown as a lower bound.",
                );
            }
        }
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
    pub fn clear_graph(&mut self, module: Module) {
        match module {
            Module::Cpu => self.cpu.clear_graph(),
            Module::Network => self.network.clear_graph(),
            Module::Disk => self.disk.clear_graph(),
            _ => (),
        }
    }
    pub fn reset_transfers(&mut self, module: Module) {
        match module {
            Module::Network => self.network.reset_transfers(),
            Module::Disk => self.disk.reset_transfers(),
            _ => (),
        }
    }
    pub fn transfer_totals(&self) -> [TransferTotals; 2] {
        [self.network.totals, self.disk.totals]
    }

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

#[cfg(test)]
mod transfer_tests {
    #[test]
    fn accumulated_byte_overflow_saturates_and_marks_a_lower_bound() {
        let mut totals = super::TransferTotals::default();
        totals.add([u64::MAX - 1, 2]);
        totals.add([5, 3]);
        assert_eq!(totals.bytes, [u64::MAX, 5]);
        assert!(totals.saturated);
    }
}
