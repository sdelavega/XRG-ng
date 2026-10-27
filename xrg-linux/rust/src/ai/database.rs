// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::Reading;
use crate::shared::Usage;
use rusqlite::{Connection, OpenFlags};
use std::{
    path::Path,
    time::{Duration, Instant},
};

/// Read-only SQLite snapshot, no lock waiting, bounded VM execution and row count.
/// WAL files are read normally; immutable=1 would silently miss current sessions.
pub fn snapshot(path: &Path, hermes: bool) -> Result<Reading, String> {
    let file = super::logs::open_regular(path)?;
    drop(file);
    let mut conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| e.to_string())?;
    conn.busy_timeout(Duration::ZERO)
        .map_err(|e| e.to_string())?;
    let deadline = Instant::now() + Duration::from_millis(250);
    conn.progress_handler(1000, Some(move || Instant::now() >= deadline))
        .map_err(|e| e.to_string())?;
    let sql = if hermes {
        "SELECT COALESCE(input_tokens,0), COALESCE(output_tokens,0), COALESCE(actual_cost_usd,estimated_cost_usd) FROM sessions WHERE model IS NOT NULL AND model != ''"
    } else {
        "SELECT tokens_used, 0, estimated_cost FROM sessions WHERE tokens_used > 0"
    };
    let mut statement = conn.prepare(sql).map_err(|e| e.to_string())?;
    let mut rows = statement.query([]).map_err(|e| e.to_string())?;
    let mut usage = Usage::default();
    let mut cost = 0.0;
    let mut cost_known = true;
    let mut count = 0;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        count += 1;
        if count > 100_000 || Instant::now() >= deadline {
            return Err("Database query budget exceeded".into());
        }
        let input: i64 = row.get(0).map_err(|e| e.to_string())?;
        let output: i64 = row.get(1).map_err(|e| e.to_string())?;
        let value: Option<f64> = row.get(2).map_err(|e| e.to_string())?;
        if input < 0 || output < 0 || value.is_some_and(|v| !v.is_finite() || v < 0.0) {
            return Err("Invalid database usage/cost".into());
        }
        let total = (input as u64)
            .checked_add(output as u64)
            .ok_or("Token overflow")?;
        usage = usage
            .checked_add(Usage {
                input: input as u64,
                output: output as u64,
                total,
            })
            .ok_or("Token overflow")?;
        if let Some(value) = value {
            cost += value;
        } else {
            cost_known = false;
        }
        if !cost.is_finite() {
            return Err("Cost overflow".into());
        }
    }
    Ok(Reading {
        usage,
        cost: cost_known.then_some(cost),
        source: if hermes {
            "Hermes SQLite (reported/estimated cost)"
        } else {
            "Claude custom SQLite (estimated cost)"
        }
        .into(),
    })
}
