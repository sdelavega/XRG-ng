// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Readings, directories, integer, short_label, text};
use std::{
    fs,
    os::unix::fs::MetadataExt,
    path::Path,
    time::{Duration, Instant},
};

#[derive(Clone, Debug, PartialEq)]
pub struct Fan {
    pub id: String,
    pub name: String,
    pub rpm: u64,
    pub alarm: Option<bool>,
    pub notes: Vec<String>,
}
pub fn fans(sys: &Path) -> Result<Readings<Fan>, String> {
    let start = Instant::now();
    let mut report = Readings {
        values: Vec::new(),
        errors: Vec::new(),
    };
    let mut attempted = 0;
    'scan: for directory in directories(&sys.join("class/hwmon"))? {
        if start.elapsed() >= Duration::from_millis(100) {
            report
                .errors
                .push("Fan scan time budget reached; coverage is partial".into());
            break;
        }
        let chip = match text(&directory.join("name")) {
            Ok(name) => short_label(name.as_deref().unwrap_or("hwmon")),
            Err(error) => {
                report.errors.push(error);
                continue;
            }
        };
        let inputs = match directories(&directory) {
            Ok(inputs) => inputs,
            Err(error) => {
                report.errors.push(error);
                continue;
            }
        };
        for input in inputs {
            let file = input.file_name().unwrap_or_default().to_string_lossy();
            let Some(channel) = file
                .strip_prefix("fan")
                .and_then(|s| s.strip_suffix("_input"))
            else {
                continue;
            };
            if channel.is_empty() || !channel.bytes().all(|c| c.is_ascii_digit()) {
                continue;
            }
            if attempted >= 256 || start.elapsed() >= Duration::from_millis(100) {
                report
                    .errors
                    .push("Fan scan limit reached; coverage is partial".into());
                break 'scan;
            }
            attempted += 1;
            let read = || -> Result<Option<Fan>, String> {
                match integer(&directory.join(format!("fan{channel}_enable")))? {
                    Some(0) => return Ok(None),
                    Some(1) | None => (),
                    _ => return Err("Invalid fan enable flag".into()),
                }
                if integer(&directory.join(format!("fan{channel}_fault")))?.is_some_and(|v| v != 0)
                {
                    return Err("Fan sensor reports a fault".into());
                }
                let rpm = integer(&input)?.ok_or("Fan sensor disappeared")?;
                let rpm = u64::try_from(rpm).map_err(|_| "Invalid negative fan RPM")?;
                let label = text(&directory.join(format!("fan{channel}_label")))?
                    .unwrap_or_else(|| format!("fan{channel}"));
                let mut notes = Vec::new();
                let alarm = match integer(&directory.join(format!("fan{channel}_alarm"))) {
                    Ok(Some(0)) => Some(false),
                    Ok(Some(1)) => Some(true),
                    Ok(None) => None,
                    Ok(Some(_)) => {
                        notes.push("Invalid fan alarm flag".into());
                        None
                    }
                    Err(error) => {
                        notes.push(error);
                        None
                    }
                };
                let canonical = fs::canonicalize(&directory).map_err(|e| e.to_string())?;
                let inode = fs::metadata(&input).map_err(|e| e.to_string())?.ino();
                Ok(Some(Fan {
                    id: format!("{}:{channel}:{inode}", canonical.display()),
                    name: format!(
                        "{chip} ({}) · {}",
                        directory.file_name().unwrap_or_default().to_string_lossy(),
                        short_label(&label)
                    ),
                    rpm,
                    alarm,
                    notes,
                }))
            };
            match read() {
                Ok(Some(fan)) => report.values.push(fan),
                Ok(None) => (),
                Err(error) => report.errors.push(format!("{chip}/{file}: {error}")),
            }
        }
    }
    // Duplicate class aliases must not produce a second line for the same sensor.
    report.values.sort_by(|a, b| a.id.cmp(&b.id));
    report.values.dedup_by(|a, b| a.id == b.id);
    Ok(report)
}
