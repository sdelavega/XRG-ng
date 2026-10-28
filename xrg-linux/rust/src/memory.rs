// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Linux memory categories overlap: never stack them into an invented app/wired total.
use crate::{
    engine::{Panel, Scale},
    shared::{History, Rates},
    system_file,
};
use std::{collections::BTreeMap, path::Path};

const LIMIT: usize = 256 * 1024;
const FIELDS: &[&str] = &[
    "MemTotal:",
    "MemAvailable:",
    "MemFree:",
    "Buffers:",
    "Cached:",
    "Slab:",
    "SReclaimable:",
    "SUnreclaim:",
    "Shmem:",
    "Dirty:",
    "Writeback:",
    "SwapTotal:",
    "SwapFree:",
];
type Fields = BTreeMap<&'static str, Result<u64, String>>;

fn fields(text: &str, names: &[&'static str], kib: bool) -> Result<Fields, String> {
    if text.len() > LIMIT || text.lines().count() > 4096 {
        return Err("Memory counters exceed read limits".into());
    }
    let mut result = Fields::new();
    for line in text.lines() {
        if line.len() > 4096 {
            return Err("Memory counter line exceeds read limits".into());
        }
        let mut parts = line.split_whitespace();
        let Some(name) = parts
            .next()
            .and_then(|name| names.iter().find(|n| **n == name))
        else {
            continue;
        };
        let value = (|| {
            let raw = parts
                .next()
                .ok_or_else(|| format!("Missing {name} value"))?;
            if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
                return Err(format!("Invalid {name} value"));
            }
            let value = raw
                .parse::<u64>()
                .map_err(|_| format!("Invalid {name} value"))?;
            if (kib && parts.next() != Some("kB")) || parts.next().is_some() {
                return Err(format!("Invalid {name} unit or extra fields"));
            }
            value
                .checked_mul(if kib { 1024 } else { 1 })
                .ok_or_else(|| format!("{name} overflow"))
        })();
        match result.entry(name) {
            std::collections::btree_map::Entry::Occupied(mut entry) => {
                let _ = entry.insert(Err(format!("Duplicate {name} counter")));
            }
            std::collections::btree_map::Entry::Vacant(entry) => {
                entry.insert(value);
            }
        }
    }
    Ok(result)
}
fn value(fields: &Fields, name: &str) -> Result<u64, String> {
    fields
        .get(name)
        .cloned()
        .unwrap_or_else(|| Err(format!("Missing {name} counter")))
}

#[derive(Clone, Debug)]
pub struct Swap {
    pub total: u64,
    pub used: u64,
}
#[derive(Clone, Debug)]
pub struct Reading {
    pub total: u64,
    pub available: u64,
    pub cached: Option<u64>,
    pub swap: Option<Swap>,
    pub counters: Vec<(&'static str, Option<u64>)>,
    pub notes: Vec<String>,
}
impl Reading {
    pub fn used_percent(&self) -> f64 {
        100. * (self.total - self.available) as f64 / self.total as f64
    }
}
pub fn parse(text: &str) -> Result<Reading, String> {
    let fields = fields(text, FIELDS, true)?;
    let total = value(&fields, "MemTotal:")?;
    let available = value(&fields, "MemAvailable:")?;
    if total == 0 || available > total {
        return Err("Invalid memory totals".into());
    }
    let mut notes = Vec::new();
    let mut counters = Vec::new();
    for &name in &FIELDS[2..FIELDS.len() - 2] {
        let reading = match fields.get(name) {
            None => None,
            Some(Ok(n)) if *n <= total => Some(*n),
            Some(Ok(_)) => {
                notes.push(format!("{name} exceeds total RAM"));
                None
            }
            Some(Err(error)) => {
                notes.push(error.clone());
                None
            }
        };
        counters.push((name, reading));
    }
    let cached = counters
        .iter()
        .find(|(name, _)| *name == "Cached:")
        .and_then(|(_, n)| *n);
    let swap = match (value(&fields, "SwapTotal:"), value(&fields, "SwapFree:")) {
        (Ok(total), Ok(free)) if free <= total => Some(Swap {
            total,
            used: total - free,
        }),
        (Ok(_), Ok(_)) => {
            notes.push("SwapFree exceeds SwapTotal".into());
            None
        }
        (a, b) => {
            for error in [a.err(), b.err()].into_iter().flatten() {
                notes.push(error);
            }
            None
        }
    };
    Ok(Reading {
        total,
        available,
        cached,
        swap,
        counters,
        notes,
    })
}
#[derive(Clone, Debug)]
pub struct Paging {
    /// pgpgin/out are KiB, despite the counter names. pswpin/out are pages.
    pub io_kib: Result<[u64; 2], String>,
    pub swap_pages: Result<[u64; 2], String>,
}
pub fn paging(text: &str) -> Result<Paging, String> {
    let fields = fields(text, &["pgpgin", "pgpgout", "pswpin", "pswpout"], false)?;
    let pair = |a, b| Ok([value(&fields, a)?, value(&fields, b)?]);
    Ok(Paging {
        io_kib: pair("pgpgin", "pgpgout"),
        swap_pages: pair("pswpin", "pswpout"),
    })
}
fn text(root: &Path, name: &str) -> Result<String, String> {
    String::from_utf8(
        system_file::read(&root.join(name), LIMIT).map_err(|e| format!("{name}: {e}"))?,
    )
    .map_err(|_| format!("Invalid {name} encoding"))
}
pub fn read(root: &Path) -> Result<Reading, String> {
    parse(&text(root, "meminfo")?)
}
pub fn read_paging(root: &Path) -> Result<Paging, String> {
    paging(&text(root, "vmstat")?)
}

#[derive(Default)]
struct Interval {
    previous: Option<(f64, [u64; 2])>,
    rates: Rates,
}
impl Interval {
    fn sample(
        &mut self,
        counters: &Result<[u64; 2], String>,
        now: f64,
    ) -> Result<[f64; 2], String> {
        let counters = match counters {
            Ok(n) if now.is_finite() && now >= 0. => *n,
            Ok(_) => {
                *self = Self::default();
                return Err("invalid sample time".into());
            }
            Err(error) => {
                *self = Self::default();
                return Err(error.clone());
            }
        };
        let previous = self.previous;
        if let Some((before, old)) = previous
            && (now <= before
                || now - before > 300.
                || counters.iter().zip(old).any(|(n, old)| *n < old))
        {
            *self = Self::default();
        }
        let interval = self.previous.map(|(before, _)| now - before);
        self.previous = Some((now, counters));
        let deltas =
            std::array::from_fn::<_, 2, _>(|i| self.rates.sample(i as u32, counters[i], now).0);
        let elapsed = interval.ok_or("waiting for a fresh interval")?;
        let rates = deltas.map(|n| n as f64 / elapsed);
        if rates.iter().any(|v| !v.is_finite()) {
            return Err("invalid interval rate".into());
        }
        Ok(rates)
    }
}
#[derive(Default)]
pub struct View {
    ram: Option<(u64, History)>,
    cache: Option<History>,
    swap: Option<(u64, History)>,
    io: Interval,
    swap_io: Interval,
}
impl View {
    pub fn panel(
        &mut self,
        memory: &Result<Reading, String>,
        paging: &Result<Paging, String>,
        now: f64,
    ) -> Panel {
        let mut panel = Panel {
            title: "Memory",
            label: "Memory unavailable".into(),
            detail: String::new(),
            series: Vec::new(),
            scale: Scale::Percent,
            temperature_text: None,
            readout: Default::default(),
        };
        let reading = match memory {
            Ok(reading) => reading,
            Err(error) => {
                *self = Self::default();
                panel.detail = error.clone();
                return panel;
            }
        };
        if self
            .ram
            .as_ref()
            .is_none_or(|(total, _)| *total != reading.total)
        {
            self.ram = Some((reading.total, History::new(120)));
            self.cache = None;
        }
        let percent = reading.used_percent();
        let history = &mut self.ram.as_mut().unwrap().1;
        history.append(percent);
        panel.series.push(history.values());
        let mut labels = vec![format!("RAM {percent:.1}%")];
        let mut detail = vec![format!(
            "RAM used: {:.1} / {:.1} MiB ({percent:.1}%)\nAvailable: {:.1} MiB",
            (reading.total - reading.available) as f64 / 1_048_576.,
            reading.total as f64 / 1_048_576.,
            reading.available as f64 / 1_048_576.
        )];
        if let Some(cached) = reading.cached {
            let percent = 100. * cached as f64 / reading.total as f64;
            let history = self.cache.get_or_insert_with(|| History::new(120));
            history.append(percent);
            panel.series.push(history.values());
            labels.push(format!("cache {percent:.1}%"));
        } else {
            self.cache = None;
        }
        for (name, value) in &reading.counters {
            detail.push(value.map_or_else(
                || format!("{name} unavailable"),
                |n| format!("{name} {:.1} MiB", n as f64 / 1_048_576.),
            ));
        }
        match &reading.swap {
            Some(swap) if swap.total > 0 => {
                if self
                    .swap
                    .as_ref()
                    .is_none_or(|(total, _)| *total != swap.total)
                {
                    self.swap = Some((swap.total, History::new(120)));
                }
                let percent = 100. * swap.used as f64 / swap.total as f64;
                let history = &mut self.swap.as_mut().unwrap().1;
                history.append(percent);
                panel.series.push(history.values());
                labels.push(format!("swap {percent:.1}%"));
                detail.push(format!(
                    "Swap used: {:.1} / {:.1} MiB ({percent:.1}%)",
                    swap.used as f64 / 1_048_576.,
                    swap.total as f64 / 1_048_576.
                ));
            }
            Some(_) => {
                self.swap = None;
                labels.push("no swap".into());
                detail.push("Swap: none configured (zero capacity); no percentage series".into());
            }
            None => {
                self.swap = None;
                labels.push("swap n/a".into());
                detail.push("Swap: unavailable".into());
            }
        }
        let io = paging
            .as_ref()
            .map_err(Clone::clone)
            .and_then(|p| p.io_kib.clone());
        let swap_io = paging
            .as_ref()
            .map_err(Clone::clone)
            .and_then(|p| p.swap_pages.clone());
        detail.push(match self.io.sample(&io, now) {
            Ok(rates) => format!("Page I/O in / out: {:.1} / {:.1} KiB/s", rates[0], rates[1]),
            Err(error) => format!("Page I/O: {error}"),
        });
        detail.push(match self.swap_io.sample(&swap_io, now) {
            Ok(rates) => format!("Swap in / out: {:.1} / {:.1} pages/s", rates[0], rates[1]),
            Err(error) => format!("Swap I/O: {error}"),
        });
        detail.extend(reading.notes.clone());
        detail.push("Graph series follow the label order: RAM used (MemTotal − MemAvailable), reported Cached / RAM, then used / configured swap when available. Curves are independent percentages, not stacked memory components. Cached can overlap other categories; Buffers and Slab are not macOS wired memory. Page I/O includes file-backed activity; it is not swap-only I/O. Swap event rates use pages, independent of the kernel page size. Values describe the exposed /proc scope, not a cgroup memory limit.".into());
        use crate::dashboard::{Row, bytes};
        panel.readout.top = vec![
            Row::new("Memory", bytes(reading.total as f64)),
            Row::new("Used", bytes((reading.total - reading.available) as f64)),
            Row::new("Available", bytes(reading.available as f64)),
            Row::new(
                "Cached",
                reading
                    .cached
                    .map(|v| bytes(v as f64))
                    .unwrap_or_else(|| "n/a".into()),
            ),
            Row::new(
                "Swap used",
                reading
                    .swap
                    .as_ref()
                    .map(|v| bytes(v.used as f64))
                    .unwrap_or_else(|| "n/a".into()),
            ),
        ];
        panel.label = labels.join(" · ");
        panel.detail = detail.join("\n");
        panel
    }
}
