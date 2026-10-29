// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Conservative attribution of cumulative deltas to the recorded turn model.
//! The shared Swift decoder remains authoritative for cumulative totals.
use crate::{ai::ModelUsage, ai::models::model_name, shared::Usage};
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Deserialize)]
struct Record {
    #[serde(rename = "type")]
    kind: String,
    payload: Option<Payload>,
}
#[derive(Deserialize)]
struct Payload {
    #[serde(rename = "type")]
    kind: Option<String>,
    model: Option<String>,
    info: Option<Info>,
}
#[derive(Deserialize)]
struct Info {
    last_token_usage: Option<Last>,
    // Codex leaves this absent for synthetic context-window fills. Both true
    // and false mark real request usage; it is not a reasoning-token filter.
    last_usage_includes_reasoning: Option<bool>,
}
#[derive(Deserialize)]
struct Last {
    total_tokens: Option<u64>,
}
pub(super) enum Update {
    Context(Option<String>),
    Count { last: Option<u64>, real: bool },
    Clear,
    Ignore,
}
impl Update {
    pub fn parse(line: &[u8]) -> Self {
        let Ok(record) = serde_json::from_slice::<Record>(line) else {
            return Self::Clear;
        };
        match (record.kind.as_str(), record.payload) {
            ("turn_context", Some(payload)) => Self::Context(model_name(payload.model)),
            ("turn_context" | "compacted" | "session_meta", _) => Self::Clear,
            ("event_msg", Some(payload)) => match payload.kind.as_deref() {
                Some("token_count") => Self::Count {
                    last: payload
                        .info
                        .as_ref()
                        .and_then(|i| i.last_token_usage.as_ref()?.total_tokens),
                    real: payload
                        .info
                        .is_some_and(|i| i.last_usage_includes_reasoning.is_some()),
                },
                Some(
                    "model_reroute" | "context_compacted" | "thread_rolled_back" | "task_started"
                    | "turn_started" | "task_complete" | "turn_complete" | "turn_aborted" | "error",
                )
                | None => Self::Clear,
                _ => Self::Ignore,
            },
            ("event_msg", None) => Self::Clear,
            // Unknown/malformed model metadata can never invalidate a valid
            // cumulative total, but must not leave a stale model active.
            _ => Self::Ignore,
        }
    }
}

#[derive(Clone, Default)]
pub(super) struct Rows(BTreeMap<Option<String>, u64>);
impl Rows {
    fn add(&mut self, mut model: Option<String>, total: u64) -> Result<(), String> {
        if total == 0 {
            return Ok(());
        }
        // Reserve one of the 256 groups for uncertainty. Overflowing metadata
        // falls into that group rather than breaking valid provider counting.
        if model.is_some()
            && !self.0.contains_key(&model)
            && self.0.keys().filter(|m| m.is_some()).count() >= 255
        {
            model = None;
        }
        let value = self.0.entry(model).or_default();
        *value = value
            .checked_add(total)
            .ok_or("Model token total overflow")?;
        Ok(())
    }
    pub fn merge(&mut self, other: &Self) -> Result<(), String> {
        for (model, total) in &other.0 {
            self.add(model.clone(), *total)?;
        }
        Ok(())
    }
    pub fn finish(self) -> Option<Vec<ModelUsage>> {
        if !self.0.keys().any(Option::is_some) {
            return None;
        }
        let mut rows: Vec<_> = self
            .0
            .into_iter()
            .map(|(model, total)| ModelUsage {
                model,
                usage: Usage {
                    total,
                    ..Usage::default()
                },
                cost: None,
            })
            .collect();
        rows.sort_by(|a, b| {
            b.usage
                .total
                .cmp(&a.usage.total)
                .then(a.model.cmp(&b.model))
        });
        Some(rows)
    }
}
#[derive(Clone, Default)]
pub(super) struct Ledger {
    total: u64,
    model: Option<String>,
    pub rows: Rows,
}
impl Ledger {
    pub fn changes_context(&self, update: &Update) -> bool {
        match update {
            Update::Context(model) => self.model != *model,
            Update::Clear | Update::Count { .. } => self.model.is_some(),
            Update::Ignore => false,
        }
    }
    pub fn update(&mut self, update: Update, total: Option<u64>) -> Result<(), String> {
        if let Some(total) = total {
            if total < self.total {
                // A reset/rollback invalidates the old partition. Do not
                // assign the replacement cumulative history to a recent model.
                self.rows = Rows::default();
                self.rows.add(None, total)?;
                self.model = None;
            } else {
                let delta = total - self.total;
                let model = match &update {
                    Update::Count {
                        last: Some(last),
                        real: true,
                    } if *last == delta => self.model.clone(),
                    _ => None,
                };
                self.rows.add(model, delta)?;
            }
            self.total = total;
        }
        match update {
            Update::Context(model) => self.model = model,
            Update::Clear => self.model = None,
            Update::Count { .. } if total.is_none() => self.model = None,
            _ => {}
        }
        Ok(())
    }
}

#[cfg(test)]
pub(super) mod tests;
