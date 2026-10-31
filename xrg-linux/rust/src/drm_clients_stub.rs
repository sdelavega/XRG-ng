// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Linux stub for the DRM fdinfo client scan. DRM client accounting is a
//! Linux kernel interface; there is nothing to read elsewhere, so a scan
//! reports "unavailable" and never fabricates client counters. The types keep
//! the crate-visible API shape of the Linux module so callers compile
//! unchanged; off Linux the scan is the only entry point reached.
#![allow(dead_code)]

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    time::Duration,
};

pub const IMPLEMENTATION: &str = "stub";

#[derive(Debug)]
pub(crate) struct Client {
    pub(crate) driver: String,
    pub(crate) id: u64,
    pub(crate) engines: BTreeMap<String, (Counter, u64)>,
    pub(crate) resident: Option<u64>,
    pub(crate) frequency: Option<u64>,
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum Counter {
    Nanoseconds(u64),
    Cycles { busy: u64, total: u64 },
}

impl Counter {
    pub(crate) fn busy(self) -> u64 {
        match self {
            Self::Nanoseconds(value) | Self::Cycles { busy: value, .. } => value,
        }
    }
    pub(crate) fn same_kind(self, other: Self) -> bool {
        matches!(
            (self, other),
            (Self::Nanoseconds(_), Self::Nanoseconds(_))
                | (Self::Cycles { .. }, Self::Cycles { .. })
        )
    }
    pub(crate) fn percent(self, previous: Self, elapsed: Duration, capacity: u64) -> Option<f64> {
        let busy = self.busy().checked_sub(previous.busy())?;
        let denominator = match (self, previous) {
            (Self::Nanoseconds(_), Self::Nanoseconds(_)) => elapsed.as_secs_f64() * 1_000_000_000.,
            (Self::Cycles { total, .. }, Self::Cycles { total: old, .. }) => {
                total.checked_sub(old)? as f64
            }
            _ => return None,
        };
        (denominator > 0.).then(|| 100. * busy as f64 / denominator / capacity as f64)
    }
}

pub(crate) struct Scan {
    pub(crate) values: BTreeMap<(String, u64), Client>,
    pub(crate) partial: bool,
}

pub(crate) fn scan(
    proc: &Path,
    nodes: &BTreeMap<PathBuf, (String, String)>,
    driver_matches: fn(&str, &str) -> bool,
) -> Result<Scan, String> {
    let _ = (proc, nodes, driver_matches);
    Err("DRM client accounting requires Linux".into())
}
