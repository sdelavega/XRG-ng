// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Readable processes in the selected proc/PID namespace. No command lines,
//! environments, NSS lookups, privilege escalation, signals or subprocesses.
use crate::{hardware::short_label, system_file};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs, io,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
const ENTRY_LIMIT: usize = 65_536;
const SCAN_BUDGET: Duration = Duration::from_millis(100);
#[derive(Clone, Debug, PartialEq)]
pub struct Process {
    pub pid: u32,
    pub start_ticks: u64,
    pub name: String,
    pub state: char,
    pub cpu_ticks: u64,
    /// 100% is one CPU core. Multi-threaded processes can exceed 100%.
    pub cpu_percent: Option<f64>,
    pub rss_bytes: u64,
    pub virtual_bytes: u64,
    pub memory_percent: Option<f64>,
    pub uid: Option<u32>,
    pub nice: i32,
    pub threads: u64,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Sort {
    Cpu,
    Memory,
    Pid,
    Name,
}
#[derive(Debug)]
pub struct Report {
    pub processes: Vec<Process>,
    pub discovered: usize,
    pub attempted: usize,
    pub vanished: usize,
    pub unreadable: usize,
    pub errors: Vec<String>,
}
impl Report {
    pub fn partial(&self) -> bool {
        self.attempted < self.discovered || self.unreadable > 0 || !self.errors.is_empty()
    }
    /// Filtering happens after acquisition and never changes process rate baselines.
    pub fn ranked(
        &self,
        sort: Sort,
        uid: Option<u32>,
        filter: &str,
        limit: usize,
    ) -> Vec<&Process> {
        let filter = filter.to_lowercase();
        let mut rows: Vec<_> = self
            .processes
            .iter()
            .filter(|p| {
                uid.is_none_or(|u| p.uid == Some(u)) && p.name.to_lowercase().contains(&filter)
            })
            .collect();
        rows.sort_by(|a, b| {
            let order = match sort {
                Sort::Cpu => match (a.cpu_percent, b.cpu_percent) {
                    (Some(a), Some(b)) => b.total_cmp(&a),
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    _ => std::cmp::Ordering::Equal,
                },
                Sort::Memory => b.rss_bytes.cmp(&a.rss_bytes),
                Sort::Pid => a.pid.cmp(&b.pid),
                Sort::Name => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
            };
            order.then_with(|| a.pid.cmp(&b.pid))
        });
        rows.truncate(limit.min(1000));
        rows
    }
}
#[derive(Clone, Debug)]
pub struct Listing {
    pub rows: Vec<Process>,
    pub matched: usize,
    pub readable: usize,
    pub partial: bool,
    pub coverage: String,
}
impl Report {
    pub fn listing(&self, view: &crate::settings::ProcessView) -> Result<Listing, String> {
        view.validate()?;
        let filter = view.filter.to_lowercase();
        let matched = self
            .processes
            .iter()
            .filter(|p| {
                view.uid.is_none_or(|u| p.uid == Some(u)) && p.name.to_lowercase().contains(&filter)
            })
            .count();
        let rows = self
            .ranked(view.sort, view.uid, &view.filter, view.limit as usize)
            .into_iter()
            .cloned()
            .collect();
        Ok(Listing {
            rows,
            matched,
            readable: self.processes.len(),
            partial: self.partial(),
            coverage: format!(
                "{} PID directories · {} attempted · {} vanished · {} unreadable{}",
                self.discovered,
                self.attempted,
                self.vanished,
                self.unreadable,
                if self.partial() {
                    " · partial coverage"
                } else {
                    ""
                }
            ),
        })
    }
}
#[derive(Clone, Copy)]
struct Baseline {
    start: u64,
    ticks: u64,
    time: f64,
}
pub struct Collector {
    root: PathBuf,
    ticks_per_second: u64,
    page_size: u64,
    previous: BTreeMap<u32, Baseline>,
    cursor: u32,
    start: Instant,
    budget: Duration,
}
impl Collector {
    pub fn new(root: PathBuf) -> Self {
        let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        let pages = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        Self::with_parameters(
            root,
            u64::try_from(ticks).unwrap_or(0),
            u64::try_from(pages).unwrap_or(0),
        )
    }
    pub fn with_parameters(root: PathBuf, ticks_per_second: u64, page_size: u64) -> Self {
        Self {
            root,
            ticks_per_second,
            page_size,
            previous: BTreeMap::new(),
            cursor: 0,
            start: Instant::now(),
            budget: SCAN_BUDGET,
        }
    }
    pub fn sample(&mut self) -> Result<Report, String> {
        self.sample_at(self.start.elapsed().as_secs_f64())
    }
    pub fn sample_at(&mut self, time: f64) -> Result<Report, String> {
        if self.ticks_per_second == 0 || self.page_size == 0 || !time.is_finite() || time < 0. {
            self.previous.clear();
            return Err("Process clock/page-size configuration unavailable".into());
        }
        let result = self.collect(time);
        if result.is_err() {
            self.previous.clear();
        }
        result
    }
    fn collect(&mut self, time: f64) -> Result<Report, String> {
        let start = Instant::now();
        let mut pids = Vec::new();
        for (count, entry) in fs::read_dir(&self.root)
            .map_err(|e| format!("Process directory unavailable: {e}"))?
            .enumerate()
        {
            if count >= ENTRY_LIMIT || start.elapsed() >= self.budget {
                return Err("Process discovery budget exceeded".into());
            }
            let entry = entry.map_err(|e| e.to_string())?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                continue;
            };
            if name.is_empty()
                || !name.bytes().all(|b| b.is_ascii_digit())
                || !entry.file_type().map_err(|e| e.to_string())?.is_dir()
            {
                continue;
            }
            if let Ok(pid) = name.parse::<u32>()
                && pid > 0
                && name == pid.to_string()
            {
                pids.push(pid);
            }
        }
        pids.sort_unstable();
        let alive: BTreeSet<_> = pids.iter().copied().collect();
        self.previous.retain(|pid, _| alive.contains(pid));
        let first = pids.partition_point(|pid| *pid <= self.cursor);
        pids.rotate_left(first);
        let memory = system_file::read(&self.root.join("meminfo"), 64 * 1024)
            .ok()
            .and_then(|b| memory_bytes(&b));
        let mut report = Report {
            processes: Vec::new(),
            discovered: pids.len(),
            attempted: 0,
            vanished: 0,
            unreadable: 0,
            errors: Vec::new(),
        };
        if memory.is_none() {
            report.errors.push(
                "System memory total unavailable; per-process memory percentages omitted".into(),
            );
        }
        for pid in pids {
            if start.elapsed() >= self.budget {
                report
                    .errors
                    .push("Process read budget reached; scan window rotates next poll".into());
                break;
            }
            report.attempted += 1;
            self.cursor = pid;
            match read_process(&self.root, pid, self.page_size) {
                Ok(mut process) => {
                    process.memory_percent =
                        memory.map(|total| 100. * process.rss_bytes as f64 / total as f64);
                    let next = Baseline {
                        start: process.start_ticks,
                        ticks: process.cpu_ticks,
                        time,
                    };
                    if let Some(old) = self.previous.get(&pid) {
                        if old.start == next.start && time > old.time {
                            process.cpu_percent = next
                                .ticks
                                .checked_sub(old.ticks)
                                .map(|delta| {
                                    100. * delta as f64
                                        / self.ticks_per_second as f64
                                        / (time - old.time)
                                })
                                .filter(|v| v.is_finite());
                        }
                        // A duplicate/stale timestamp must not consume a newer counter.
                        if time <= old.time {
                            process.cpu_percent = None;
                        }
                    }
                    if self.previous.get(&pid).is_none_or(|old| time > old.time) {
                        self.previous.insert(pid, next);
                    }
                    report.processes.push(process);
                }
                Err(error) => {
                    self.previous.remove(&pid);
                    if matches!(error.raw_os_error(), Some(libc::ESRCH))
                        || error.kind() == io::ErrorKind::NotFound
                    {
                        report.vanished += 1;
                    } else {
                        report.unreadable += 1;
                    }
                }
            }
        }
        Ok(report)
    }
}
fn memory_bytes(bytes: &[u8]) -> Option<u64> {
    let text = std::str::from_utf8(bytes).ok()?;
    let line = text.lines().find(|l| l.starts_with("MemTotal:"))?;
    let mut fields = line.split_whitespace();
    fields.next()?;
    let kb = fields.next()?.parse::<u64>().ok()?;
    if fields.next()? != "kB" || kb == 0 {
        return None;
    }
    kb.checked_mul(1024)
}
pub fn parse_stat(bytes: &[u8], expected_pid: u32, page_size: u64) -> Result<Process, String> {
    let text = String::from_utf8_lossy(bytes);
    let (pid, rest) = text.split_once(" (").ok_or("Missing process name")?;
    if pid.parse::<u32>().ok() != Some(expected_pid) || expected_pid == 0 || page_size == 0 {
        return Err("Invalid PID/page size".into());
    }
    let end = rest.rfind(") ").ok_or("Unterminated process name")?;
    let fields: Vec<_> = rest[end + 2..].split_whitespace().collect();
    if fields.len() < 22 {
        return Err("Incomplete process stat".into());
    }
    let state = fields[0].chars().next().ok_or("Missing process state")?;
    if fields[0].len() != 1 || !"RSDZTtXxKWPI".contains(state) {
        return Err("Invalid process state".into());
    }
    let number = |i: usize| {
        fields[i]
            .parse::<u64>()
            .map_err(|_| "Invalid process counter".to_owned())
    };
    let ticks = number(11)?
        .checked_add(number(12)?)
        .ok_or("Process tick overflow")?;
    let rss: i64 = fields[21].parse().map_err(|_| "Invalid signed RSS")?;
    let rss_bytes = u64::try_from(rss)
        .ok()
        .and_then(|v| v.checked_mul(page_size))
        .ok_or("Invalid RSS size")?;
    Ok(Process {
        pid: expected_pid,
        start_ticks: number(19)?,
        name: short_label(&rest[..end]),
        state,
        cpu_ticks: ticks,
        cpu_percent: None,
        rss_bytes,
        virtual_bytes: number(20)?,
        memory_percent: None,
        uid: None,
        nice: fields[16].parse().map_err(|_| "Invalid nice value")?,
        threads: number(17)?,
    })
}
fn read_process(root: &Path, pid: u32, page_size: u64) -> io::Result<Process> {
    let path = root.join(pid.to_string());
    let stat = path.join("stat");
    let parse = |b: &[u8]| {
        parse_stat(b, pid, page_size).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    };
    let before = parse(&system_file::read(&stat, 8192)?)?;
    let uid = system_file::read(&path.join("status"), 64 * 1024)
        .ok()
        .and_then(|b| {
            let text = std::str::from_utf8(&b).ok()?;
            text.lines()
                .find_map(|l| l.strip_prefix("Uid:"))
                .and_then(|s| s.split_whitespace().next())
                .and_then(|v| v.parse::<u32>().ok())
        });
    let mut after = parse(&system_file::read(&stat, 8192)?)?;
    if before.start_ticks != after.start_ticks {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "PID reused while reading",
        ));
    }
    after.uid = uid;
    Ok(after)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovery_deadline_returns_unavailable_and_clears_rate_baselines() {
        let root = std::env::temp_dir().join(format!("xrg-process-budget-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("meminfo"), "MemTotal: 1 kB").unwrap();
        let mut collector = Collector::with_parameters(root.clone(), 100, 4096);
        collector.previous.insert(
            1,
            Baseline {
                start: 1,
                ticks: 0,
                time: 1.,
            },
        );
        collector.budget = Duration::ZERO;
        assert!(collector.sample_at(2.).unwrap_err().contains("budget"));
        assert!(collector.previous.is_empty());
        fs::remove_dir_all(root).unwrap();
    }
}
