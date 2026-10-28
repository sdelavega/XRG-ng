// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    collections::BTreeSet,
    fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Cpu {
    pub total: u64,
    pub idle: u64,
    /// First eight /proc/stat fields; guest time is already in user/nice.
    pub ticks: [u64; 8],
    pub fields: usize,
}
fn invalid(message: &str) -> String {
    message.to_string()
}
fn number(text: Option<&str>) -> Result<u64, String> {
    text.ok_or_else(|| invalid("Missing counter"))?
        .parse()
        .map_err(|_| invalid("Invalid counter"))
}
fn sum(mut values: impl Iterator<Item = u64>) -> Result<u64, String> {
    values.try_fold(0u64, |a, b| {
        a.checked_add(b).ok_or_else(|| invalid("Counter overflow"))
    })
}
pub fn cpu(text: &str) -> Result<Cpu, String> {
    let mut fields = text.lines().next().unwrap_or("").split_whitespace();
    if fields.next() != Some("cpu") {
        return Err(invalid("Missing CPU totals"));
    }
    let values = fields
        .take(11)
        .map(|v| number(Some(v)))
        .collect::<Result<Vec<_>, _>>()?;
    if !(4..=10).contains(&values.len()) {
        return Err(invalid("Unknown or incomplete CPU counter layout"));
    }
    let mut ticks = [0; 8];
    let fields = values.len().min(8);
    ticks[..fields].copy_from_slice(&values[..fields]);
    Ok(Cpu {
        total: sum(ticks.into_iter())?,
        idle: sum([ticks[3], ticks[4]].into_iter())?,
        ticks,
        fields,
    })
}
#[derive(Clone, Copy, Debug)]
pub struct CpuUsage {
    pub busy: f64,
    pub user: f64,
    pub system: f64,
    pub nice: f64,
    pub steal: f64,
    pub iowait: f64,
    pub idle: f64,
    pub fields: usize,
}
pub fn cpu_usage(previous: Cpu, next: Cpu) -> Option<CpuUsage> {
    if previous.fields != next.fields {
        return None;
    }
    let deltas = next
        .ticks
        .iter()
        .zip(previous.ticks)
        .map(|(next, old)| next.checked_sub(old))
        .collect::<Option<Vec<_>>>()?;
    let total = sum(deltas.iter().copied()).ok()?;
    if total == 0 {
        return None;
    }
    let percent = |ticks| 100. * ticks as f64 / total as f64;
    Some(CpuUsage {
        busy: percent(total - deltas[3] - deltas[4]),
        user: percent(deltas[0] + deltas[1]),
        system: percent(deltas[2] + deltas[5] + deltas[6]),
        nice: percent(deltas[1]),
        steal: percent(deltas[7]),
        iowait: percent(deltas[4]),
        idle: percent(deltas[3]),
        fields: next.fields,
    })
}
pub fn cpu_percent(previous: Cpu, next: Cpu) -> Option<f64> {
    cpu_usage(previous, next).map(|usage| usage.busy)
}
pub fn memory(text: &str) -> Result<f64, String> {
    crate::memory::parse(text).map(|reading| reading.used_percent())
}
pub fn network(text: &str) -> Result<[u64; 2], String> {
    if text.lines().count() < 2 {
        return Err(invalid("Missing network counters"));
    }
    let mut rx = Vec::new();
    let mut tx = Vec::new();
    for line in text.lines().skip(2) {
        let Some((name, counters)) = line.split_once(':') else {
            continue;
        };
        if name.trim() == "lo" {
            continue;
        }
        let fields: Vec<_> = counters.split_whitespace().collect();
        if fields.len() < 16 {
            return Err(invalid("Incomplete network counters"));
        }
        rx.push(number(fields.first().copied())?);
        tx.push(number(fields.get(8).copied())?);
    }
    Ok([sum(rx.into_iter())?, sum(tx.into_iter())?])
}
pub fn disk(text: &str, devices: &BTreeSet<String>) -> Result<[u64; 2], String> {
    let mut read = Vec::new();
    let mut write = Vec::new();
    let mut found = BTreeSet::new();
    for line in text.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() < 3 || !devices.contains(fields[2]) {
            continue;
        }
        found.insert(fields[2]);
        read.push(number(fields.get(5).copied())?);
        write.push(number(fields.get(9).copied())?);
    }
    if found.len() != devices.len() || devices.is_empty() {
        return Err(invalid("No complete physical disk counters"));
    }
    // Linux diskstats sectors are always 512 bytes, independent of device block size.
    Ok([
        sum(read.into_iter())?
            .checked_mul(512)
            .ok_or_else(|| invalid("Disk counter overflow"))?,
        sum(write.into_iter())?
            .checked_mul(512)
            .ok_or_else(|| invalid("Disk counter overflow"))?,
    ])
}

pub struct LinuxSources {
    proc: PathBuf,
    sys: PathBuf,
    allow_commands: bool,
    tpu_stats: Option<PathBuf>,
}
impl LinuxSources {
    pub fn with_roots(proc: impl Into<PathBuf>, sys: impl Into<PathBuf>) -> Self {
        Self {
            proc: proc.into(),
            sys: sys.into(),
            allow_commands: false,
            tpu_stats: None,
        }
    }
    pub fn with_tpu_stats(mut self, path: impl Into<PathBuf>) -> Self {
        self.tpu_stats = Some(path.into());
        self
    }
    pub fn process_collector(&self) -> crate::process::Collector {
        crate::process::Collector::new(self.proc.clone())
    }
    pub fn tpu_collector(&self) -> crate::tpu::Collector {
        crate::tpu::Collector::new(self.sys.clone(), self.tpu_stats.clone())
    }
    pub fn battery(&self) -> Result<crate::hardware::Readings<crate::hardware::Battery>, String> {
        crate::hardware::batteries(&self.sys)
    }
    pub fn temperatures(
        &self,
    ) -> Result<crate::hardware::Readings<crate::hardware::Temperature>, String> {
        crate::hardware::temperatures(&self.sys)
    }
    pub fn gpu_collector(&self) -> crate::gpu::GpuCollector {
        crate::gpu::GpuCollector::new(
            self.sys.clone(),
            if self.allow_commands {
                crate::gpu::find_nvidia_smi()
            } else {
                None
            },
        )
        .with_proc_root(self.proc.clone())
    }
    pub fn live() -> Self {
        Self {
            proc: "/proc".into(),
            sys: "/sys".into(),
            allow_commands: true,
            tpu_stats: Some("/tmp/xrg-coral-tpu-stats.json".into()),
        }
    }
    pub(crate) fn proc_root(&self) -> &Path {
        &self.proc
    }
    pub(crate) fn sys_root(&self) -> &Path {
        &self.sys
    }
    fn read(root: &Path, file: &str) -> Result<String, String> {
        fs::read_to_string(root.join(file)).map_err(|e| format!("{file}: {e}"))
    }
    pub fn cpu(&self) -> Result<Cpu, String> {
        cpu(&Self::read(&self.proc, "stat")?)
    }
    pub fn memory(&self) -> Result<f64, String> {
        crate::memory::read(&self.proc).map(|reading| reading.used_percent())
    }
    pub fn network(&self) -> Result<[u64; 2], String> {
        network(&Self::read(&self.proc, "net/dev")?)
    }
    pub fn disk(&self) -> Result<[u64; 2], String> {
        let entries = fs::read_dir(self.sys.join("block")).map_err(|e| e.to_string())?;
        let mut devices = BTreeSet::new();
        for entry in entries {
            let entry = entry.map_err(|e| e.to_string())?;
            let name = entry.file_name().to_string_lossy().into_owned();
            // Exclude virtual/stacked devices and partitions, avoiding double counting.
            if ["loop", "ram", "zram", "dm-", "md"]
                .iter()
                .any(|p| name.starts_with(p))
            {
                continue;
            }
            devices.insert(name);
        }
        disk(&Self::read(&self.proc, "diskstats")?, &devices)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cpu_excludes_guest_time_and_includes_iowait() {
        let a = cpu("cpu 100 0 50 800 50 0 0 0 30 0").unwrap();
        let b = cpu("cpu 150 0 50 840 60 0 0 0 80 0").unwrap();
        assert_eq!(a.total, 1000);
        assert_eq!(cpu_percent(a, b), Some(50.));
        assert_eq!(cpu_percent(b, a), None);
        assert_eq!(cpu_percent(a, a), None);
        assert!(cpu("cpu 1 2").is_err());
    }
    #[test]
    fn memory_uses_available_including_reclaimable_cache() {
        assert_eq!(
            memory("MemTotal: 1000 kB\nMemFree: 10 kB\nMemAvailable: 600 kB"),
            Ok(40.)
        );
        assert!(memory("MemTotal: 100 kB").is_err());
        assert!(memory("MemTotal: 0 kB\nMemAvailable: 0 kB").is_err());
        assert!(memory("MemTotal: 10 kB\nMemAvailable: 11 kB").is_err());
    }
    #[test]
    fn network_aggregates_non_loopback() {
        let text = "header\nheader\n lo: 99 0 0 0 0 0 0 0 99 0 0 0 0 0 0 0\n eth0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0\n wlan0: 25 0 0 0 0 0 0 0 75 0 0 0 0 0 0 0";
        assert_eq!(network(text), Ok([125, 275]));
        assert!(network("h\nh\n eth0: 1 2").is_err());
        assert!(network("").is_err());
    }
    #[test]
    fn disk_filters_partitions_and_stacked_devices() {
        let devices = BTreeSet::from(["nvme0n1".to_string()]);
        let text = "259 0 nvme0n1 1 0 10 0 1 0 20 0 0 0 0\n259 1 nvme0n1p1 1 0 9 0 1 0 19 0 0 0 0\n7 0 loop0 1 0 500 0 1 0 500 0";
        assert_eq!(disk(text, &devices), Ok([5120, 10240]));
        assert!(disk("", &devices).is_err());
        assert!(disk("", &BTreeSet::new()).is_err());
        assert!(disk("259 0 nvme0n1 1 0 18446744073709551615 0 1 0 20", &devices).is_err());
    }
}
