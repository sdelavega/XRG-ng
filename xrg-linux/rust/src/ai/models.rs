// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::shared::Usage;
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq)]
pub struct ModelUsage {
    pub model: Option<String>,
    pub usage: Usage,
    pub cost: Option<f64>,
}
pub(super) fn model_name(name: Option<String>) -> Option<String> {
    name.filter(|s| !s.trim().is_empty() && s.len() <= 1024 && !s.chars().any(char::is_control))
}
#[derive(Clone, Default)]
pub(super) struct Totals(BTreeMap<Option<String>, ModelUsage>);
impl Totals {
    pub fn add(&mut self, row: ModelUsage) -> Result<(), String> {
        if let Some(old) = self.0.get_mut(&row.model) {
            old.usage = old
                .usage
                .checked_add(row.usage)
                .ok_or("Model token total overflow")?;
            old.cost = match (old.cost, row.cost) {
                (Some(a), Some(b)) => Some(a + b),
                _ => None,
            };
            if old.cost.is_some_and(|v| !v.is_finite()) {
                return Err("Model cost overflow".into());
            }
        } else {
            if self.0.len() >= 256 {
                return Err("Provider model limit exceeded (256)".into());
            }
            self.0.insert(row.model.clone(), row);
        }
        Ok(())
    }
    pub fn rows(&self) -> impl Iterator<Item = &ModelUsage> {
        self.0.values()
    }
    pub fn finish(self) -> Vec<ModelUsage> {
        let mut rows: Vec<_> = self.0.into_values().collect();
        rows.sort_by(|a, b| {
            b.usage
                .total
                .cmp(&a.usage.total)
                .then(a.model.cmp(&b.model))
        });
        rows
    }
}
