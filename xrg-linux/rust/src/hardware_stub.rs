// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Linux stub for kernel sysfs collection. There is no sysfs off Linux,
//! so every scan returns the module's existing "nothing found" reading (an
//! empty list, never a zero or invented measurement) and attribute helpers
//! report values as absent, exactly as Linux does for a machine without the
//! corresponding sysfs class. The reading types and presentation formatting
//! are shared verbatim with the Linux module (`hardware/format`) so both
//! platforms present identical fields.
#[path = "hardware/format.rs"]
mod format;

use std::path::{Path, PathBuf};

pub const IMPLEMENTATION: &str = "stub";

pub use format::{Battery, BatteryTime, Fan, Readings, Temperature, TimeSource};
// `celsius` is used only by the Linux thermal-zone scan; it stays
// re-exported here so the stub keeps the exact crate-visible API shape.
#[allow(unused_imports)]
pub(crate) use format::{celsius, short_label};

pub fn batteries(_sys: &Path) -> Result<Readings<Battery>, String> {
    Ok(Readings {
        values: Vec::new(),
        errors: Vec::new(),
    })
}
pub fn temperatures(_sys: &Path) -> Result<Readings<Temperature>, String> {
    Ok(Readings {
        values: Vec::new(),
        errors: Vec::new(),
    })
}
pub fn temperature_sources(_sys: &Path) -> Result<Readings<Temperature>, String> {
    Ok(Readings {
        values: Vec::new(),
        errors: Vec::new(),
    })
}
pub fn fans(_sys: &Path) -> Result<Readings<Fan>, String> {
    Ok(Readings {
        values: Vec::new(),
        errors: Vec::new(),
    })
}
pub(crate) fn text(_path: &Path) -> Result<Option<String>, String> {
    // No sysfs exists off Linux; an attribute is absent, not unreadable.
    Ok(None)
}
pub(crate) fn integer(_path: &Path) -> Result<Option<i64>, String> {
    // Attribute values are absent off Linux (see `text`); never invented.
    Ok(None)
}
pub(crate) fn directories(_path: &Path) -> Result<Vec<PathBuf>, String> {
    Ok(Vec::new())
}
