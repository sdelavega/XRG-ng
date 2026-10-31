// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Linux stub for the DRM fdinfo client scan. DRM client accounting is a
//! Linux kernel interface; there is nothing to read elsewhere, so a scan
//! reports "unavailable" and never fabricates client counters. The client
//! types and counter math are shared verbatim with the Linux module
//! (`drm_clients/math`) so accounting can never diverge between platforms;
//! off Linux the scan is the only entry point reached.
#[path = "drm_clients/math.rs"]
mod math;

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

pub const IMPLEMENTATION: &str = "stub";

// `Client` is named only by the Linux parser; it stays re-exported here so
// the stub keeps the exact crate-visible API shape of the Linux module.
#[allow(unused_imports)]
pub(crate) use math::{Client, Counter, Scan};

pub(crate) fn scan(
    proc: &Path,
    nodes: &BTreeMap<PathBuf, (String, String)>,
    driver_matches: fn(&str, &str) -> bool,
) -> Result<Scan, String> {
    let _ = (proc, nodes, driver_matches);
    Err("DRM client accounting requires Linux".into())
}
