// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Fan, Readings, directories, integer, sensor_identity, short_label, text};
use std::{
    path::Path,
    time::{Duration, Instant},
};

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
                let (source_id, id) = sensor_identity::identity(sys, &directory, &input, &chip)?;
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
                if sensor_identity::identity(sys, &directory, &input, &chip)?.1 != id {
                    return Err("Fan sensor changed during read".into());
                }
                Ok(Some(Fan {
                    id,
                    source_id,
                    name: format!(
                        "{chip} ({}) · {} [fan{channel}]",
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
    let mut counts = std::collections::BTreeMap::new();
    for value in &report.values {
        *counts.entry(value.source_id.clone()).or_insert(0usize) += 1;
    }
    report.values.retain(|value| counts[&value.source_id] == 1);
    if counts.values().any(|n| *n > 1) {
        report
            .errors
            .push("Ambiguous fan source identities omitted".into());
    }
    Ok(report)
}
