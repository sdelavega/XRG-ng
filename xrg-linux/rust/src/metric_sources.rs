// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Bounded, injectable acquisition for selectable CPU/interface/block views.
use crate::{
    collectors::{self, Cpu, LinuxSources},
    hardware, system_file,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};
#[cfg(target_os = "linux")]
use std::{fs, os::unix::fs::MetadataExt};
#[derive(Clone, Debug)]
pub struct CpuRecords {
    pub total: Cpu,
    pub cores: BTreeMap<u32, Cpu>,
}
#[derive(Clone, Debug)]
pub struct Counter {
    pub values: [u64; 2],
    pub identity: String,
}
#[derive(Clone, Debug)]
pub struct Devices {
    pub devices: BTreeMap<String, Counter>,
    pub aggregate: BTreeSet<String>,
    pub identity_incomplete: bool,
}
impl Devices {
    pub fn values(&self, selected: Option<&str>) -> Result<([u64; 2], Vec<String>), String> {
        let names = selected
            .map(|s| BTreeSet::from([s.to_owned()]))
            .unwrap_or_else(|| self.aggregate.clone());
        let mut total = [0u64; 2];
        let mut identities = Vec::new();
        for name in names {
            let counter = self
                .devices
                .get(&name)
                .ok_or_else(|| format!("Selected or aggregate device {name} is unavailable"))?;
            for (sum, value) in total.iter_mut().zip(counter.values) {
                *sum = sum.checked_add(value).ok_or("Device counter overflow")?;
            }
            identities.push(format!("{name}:{}", counter.identity));
        }
        Ok((total, identities))
    }
}
fn text(path: &Path, limit: usize) -> Result<String, String> {
    String::from_utf8(system_file::read(path, limit).map_err(|e| e.to_string())?)
        .map_err(|_| "Invalid metric encoding".into())
}
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && name.len() <= 255
        && !name
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || c == '/' || c == ':')
}
pub fn cpu_records(text: &str) -> Result<CpuRecords, String> {
    let mut total = None;
    let mut cores = BTreeMap::new();
    for line in text.lines() {
        let Some(name) = line.split_whitespace().next() else {
            continue;
        };
        if name == "cpu" {
            if total.is_some() {
                return Err("Duplicate CPU totals".into());
            }
            total = Some(collectors::cpu(line)?);
        } else if let Some(index) = name
            .strip_prefix("cpu")
            .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
        {
            if cores.len() >= 8192 {
                return Err("CPU inventory exceeds 8192 entries".into());
            }
            let index = index.parse::<u32>().map_err(|_| "Invalid CPU index")?;
            if index > 1_048_575 {
                return Err("CPU index is out of range".into());
            }
            let counters = collectors::cpu(&line.replacen(name, "cpu", 1))?;
            if cores.insert(index, counters).is_some() {
                return Err("Duplicate CPU index".into());
            }
        }
    }
    Ok(CpuRecords {
        total: total.ok_or("Missing CPU totals")?,
        cores,
    })
}
pub fn network_records(text: &str) -> Result<BTreeMap<String, [u64; 2]>, String> {
    if text.lines().count() < 2 {
        return Err("Missing network counters".into());
    }
    let mut records = BTreeMap::new();
    for line in text.lines().skip(2) {
        if line.trim().is_empty() {
            continue;
        }
        let (name, counters) = line.split_once(':').ok_or("Invalid network row")?;
        let name = name.trim();
        if !valid_name(name) {
            return Err("Invalid interface name".into());
        }
        let fields: Vec<_> = counters.split_whitespace().collect();
        if fields.len() < 16 {
            return Err("Incomplete interface counters".into());
        }
        let parse = |i: usize| {
            fields[i]
                .parse::<u64>()
                .map_err(|_| "Invalid interface counter")
        };
        if records.len() >= 8192
            || records
                .insert(name.to_owned(), [parse(0)?, parse(8)?])
                .is_some()
        {
            return Err("Duplicate or excessive network inventory".into());
        }
    }
    Ok(records)
}
pub fn disk_records(text: &str) -> Result<BTreeMap<String, ([u64; 2], String)>, String> {
    let mut records = BTreeMap::new();
    for line in text.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.is_empty() {
            continue;
        }
        if fields.len() < 10 || !valid_name(fields[2]) {
            return Err("Incomplete block-device counters".into());
        }
        let parse = |i: usize| {
            fields[i]
                .parse::<u64>()
                .map_err(|_| "Invalid block counter")
        };
        let values = [
            parse(5)?.checked_mul(512).ok_or("Disk byte overflow")?,
            parse(9)?.checked_mul(512).ok_or("Disk byte overflow")?,
        ];
        let identity = format!("{}:{}", parse(0)?, parse(1)?);
        if records.len() >= 8192
            || records
                .insert(fields[2].to_owned(), (values, identity))
                .is_some()
        {
            return Err("Duplicate or excessive disk inventory".into());
        }
    }
    Ok(records)
}
pub fn cpus(source: &LinuxSources) -> Result<CpuRecords, String> {
    cpu_records(&text(&source.proc_root().join("stat"), 4 * 1024 * 1024)?)
}
pub fn network(source: &LinuxSources) -> Result<Devices, String> {
    let records = network_records(&text(&source.proc_root().join("net/dev"), 2 * 1024 * 1024)?)?;
    let aggregate = records
        .keys()
        .filter(|n| n.as_str() != "lo")
        .cloned()
        .collect();
    let mut devices = BTreeMap::new();
    let mut identity_incomplete = false;
    for (name, values) in records {
        let directory = source.sys_root().join("class/net").join(&name);
        let index = hardware::integer(&directory.join("ifindex"))
            .ok()
            .flatten()
            .filter(|n| *n > 0);
        #[cfg(target_os = "linux")]
        let inode = fs::metadata(&directory).ok().map(|m| m.ino());
        #[cfg(not(target_os = "linux"))]
        let inode: Option<u64> = None;
        identity_incomplete |= index.is_none() || inode.is_none();
        devices.insert(
            name,
            Counter {
                values,
                identity: format!("{index:?}:{inode:?}"),
            },
        );
    }
    Ok(Devices {
        devices,
        aggregate,
        identity_incomplete,
    })
}
pub fn disks(source: &LinuxSources) -> Result<Devices, String> {
    let physical = hardware::directories(&source.sys_root().join("block"))?;
    let mut known = BTreeMap::new();
    let mut aggregate = BTreeSet::new();
    for path in physical {
        let name = path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        if !valid_name(&name) {
            return Err("Invalid block name".into());
        }
        if !["loop", "ram", "zram", "dm-", "md"]
            .iter()
            .any(|p| name.starts_with(p))
        {
            aggregate.insert(name.clone());
        }
        known.insert(name, path);
    }
    for path in hardware::directories(&source.sys_root().join("class/block"))? {
        let name = path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        if valid_name(&name) {
            known.insert(name, path);
        }
    }
    let records = disk_records(&text(
        &source.proc_root().join("diskstats"),
        2 * 1024 * 1024,
    )?)?;
    let mut devices = BTreeMap::new();
    let mut identity_incomplete = false;
    for (name, path) in known {
        if let Some((values, number)) = records.get(&name) {
            #[cfg(target_os = "linux")]
            let inode = fs::metadata(path).ok().map(|m| m.ino());
            #[cfg(not(target_os = "linux"))]
            let inode: Option<u64> = {
                // No inode incarnation metadata off Linux; the existing
                // "identity incomplete" flag keeps the counters untrusted.
                let _ = path;
                None
            };
            identity_incomplete |= inode.is_none();
            devices.insert(
                name,
                Counter {
                    values: *values,
                    identity: format!("{number}:{inode:?}"),
                },
            );
        }
    }
    Ok(Devices {
        devices,
        aggregate,
        identity_incomplete,
    })
}
