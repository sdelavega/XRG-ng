// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Presentation-only network axis floor in bytes/second. Zero keeps autoscaling.
pub const MAX: u64 = 9_007_199_254_740_991;
const FACTORS: [u64; 3] = [1, 1024, 1_048_576];
pub fn validate(value: u64) -> Result<(), String> {
    if value > MAX {
        Err(format!(
            "Minimum network scale must not exceed {MAX} bytes/s"
        ))
    } else {
        Ok(())
    }
}
pub fn parse(text: &str, unit: u32) -> Result<u64, String> {
    let text = text.trim();
    let invalid =
        || "Minimum network scale must be a nonnegative whole number within range".to_owned();
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err(invalid());
    }
    let factor = FACTORS.get(unit as usize).ok_or_else(invalid)?;
    let result = text
        .parse::<u64>()
        .ok()
        .and_then(|v| v.checked_mul(*factor))
        .ok_or_else(invalid)?;
    validate(result)?;
    Ok(result)
}
pub fn display(value: u64) -> (String, u32) {
    let unit = if value == 0 {
        0
    } else {
        (0..FACTORS.len())
            .rev()
            .find(|i| value.is_multiple_of(FACTORS[*i]))
            .unwrap()
    };
    ((value / FACTORS[unit]).to_string(), unit as u32)
}
