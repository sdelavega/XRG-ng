// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Display conversion only. Collector values and history remain Celsius.
use serde::{Deserialize, Serialize};
use std::{borrow::Cow, ops::Range};

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Units {
    #[default]
    Celsius,
    Fahrenheit,
}
impl Units {
    pub fn convert_celsius(self, value: f64) -> f64 {
        match self {
            Self::Celsius => value,
            Self::Fahrenheit => value * 1.8 + 32.,
        }
    }
}

/// Only spans produced from typed readings are converted. Driver names, model
/// names and error text may contain arbitrary numbers or even a degree symbol.
#[derive(Clone, Debug, Default)]
pub struct Text {
    raw: String,
    spans: Vec<(Range<usize>, f64)>,
}
impl From<String> for Text {
    fn from(raw: String) -> Self {
        Self {
            raw,
            spans: Vec::new(),
        }
    }
}
impl From<&str> for Text {
    fn from(raw: &str) -> Self {
        raw.to_owned().into()
    }
}
impl Text {
    pub fn reading(prefix: &str, celsius: f64, suffix: &str) -> Self {
        let value = format!("{celsius:.1} °C");
        Self {
            raw: format!("{prefix}{value}{suffix}"),
            spans: vec![(prefix.len()..prefix.len() + value.len(), celsius)],
        }
    }
    pub fn join(parts: impl IntoIterator<Item = Self>, separator: &str) -> Self {
        let mut result = Self::default();
        for (index, part) in parts.into_iter().enumerate() {
            if index > 0 {
                result.raw.push_str(separator);
            }
            let offset = result.raw.len();
            result.raw.push_str(&part.raw);
            result.spans.extend(
                part.spans
                    .into_iter()
                    .map(|(r, v)| (r.start + offset..r.end + offset, v)),
            );
        }
        result
    }
    pub fn render(&self, units: Units) -> Cow<'_, str> {
        if units == Units::Celsius || self.spans.is_empty() {
            return Cow::Borrowed(&self.raw);
        }
        let mut text = String::new();
        let mut end = 0;
        for (range, value) in &self.spans {
            text.push_str(&self.raw[end..range.start]);
            text.push_str(&format!("{:.1} °F", units.convert_celsius(*value)));
            end = range.end;
        }
        text.push_str(&self.raw[end..]);
        Cow::Owned(text)
    }
}
