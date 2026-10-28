// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Toolkit-neutral graph-face readings. Collection labels/details remain intact;
//! these columns retain typed temperature spans and never infer unavailable data.
use crate::temperature::Text;
#[derive(Clone, Debug)]
pub struct Row {
    pub left: String,
    pub right: Text,
}
impl Row {
    pub fn new(left: impl Into<String>, right: impl Into<Text>) -> Self {
        Self {
            left: left.into(),
            right: right.into(),
        }
    }
}
#[derive(Clone, Debug, Default)]
pub struct Readout {
    pub top: Vec<Row>,
    pub bottom: Vec<Row>,
    /// Logical CPU identity and measured non-idle percent; None stays a gap.
    pub cores: Vec<(u32, Option<f64>)>,
}
pub fn bytes(value: f64) -> String {
    if !value.is_finite() || value < 0. {
        return "n/a".into();
    }
    let mut value = value;
    let units = ["B", "K", "M", "G", "T", "P", "E"];
    let mut index = 0;
    while value >= 1024. && index + 1 < units.len() {
        value /= 1024.;
        index += 1;
    }
    if index == 0 || value >= 100. {
        format!("{value:.0}{}", units[index])
    } else if value >= 10. {
        format!("{value:.1}{}", units[index])
    } else {
        format!("{value:.2}{}", units[index])
    }
}
pub fn uptime(value: std::time::Duration) -> String {
    let s = value.as_secs();
    format!("{}d {}:{:02}", s / 86400, s / 3600 % 24, s / 60 % 60)
}
