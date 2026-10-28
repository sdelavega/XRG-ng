// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! hwmon input units and read-only state validation, shared by system/GPU views.
use super::{celsius, integer, text};
use std::path::Path;
#[derive(PartialEq, Eq)]
struct State {
    chip: Option<String>,
    enabled: Option<i64>,
    fault: Option<i64>,
    kind: Option<i64>,
}
impl State {
    fn read(directory: &Path, channel: &str) -> Result<Self, String> {
        let enabled = integer(&directory.join(format!("temp{channel}_enable")))?;
        // Disabled inputs need no ADC, fault, type or chip metadata request.
        if enabled == Some(0) {
            return Ok(Self {
                enabled,
                chip: None,
                fault: None,
                kind: None,
            });
        }
        Ok(Self {
            chip: text(&directory.join("name"))?,
            enabled,
            fault: integer(&directory.join(format!("temp{channel}_fault")))?,
            kind: integer(&directory.join(format!("temp{channel}_type")))?,
        })
    }
}
pub(crate) struct Input {
    pub celsius: f64,
    pub kind: Option<i64>,
    pub chip: Option<String>,
}
pub(crate) fn read(directory: &Path, channel: &str) -> Result<Option<Input>, String> {
    let number = channel
        .parse::<u32>()
        .ok()
        .filter(|v| *v > 0)
        .ok_or("Invalid hwmon temperature channel")?;
    let before = State::read(directory, channel)?;
    match before.enabled {
        Some(0) => return Ok(None),
        Some(1) | None => (),
        _ => return Err("Invalid temperature enable flag".into()),
    }
    if before.fault.is_some_and(|v| v != 0) {
        return Err("Temperature sensor reports a fault".into());
    }
    // Type selects the probe technology, not its units. In particular the
    // upstream ntc-thermistor driver returns calibrated millidegrees for type 4.
    if before.kind.is_some_and(|v| !(1..=6).contains(&v)) {
        return Err("Unsupported temperature sensor type".into());
    }
    // These upstream VIA drivers are exceptions to the usual millidegree ABI.
    // VT1211 temp2 is converted by the driver. Its other channels need board
    // scaling; VT8231's exported readings also require board-specific compute.
    match before.chip.as_deref() {
        Some("vt1211") if number != 2 => return Err(
            "VT1211 external channel requires board-specific calibration; raw input is not Celsius"
                .into(),
        ),
        Some("vt8231") => {
            return Err(
                "VT8231 channel requires board-specific calibration; raw input is not Celsius"
                    .into(),
            );
        }
        _ => (),
    }
    let Some(raw) = integer(&directory.join(format!("temp{channel}_input")))? else {
        return Ok(None);
    };
    let value = celsius(raw)?;
    if State::read(directory, channel)? != before {
        return Err("Temperature sensor configuration changed during read".into());
    }
    Ok(Some(Input {
        celsius: value,
        kind: before.kind,
        chip: before.chip,
    }))
}
