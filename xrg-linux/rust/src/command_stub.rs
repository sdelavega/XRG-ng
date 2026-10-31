// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Unix stub for the bounded query runner. The Linux implementation
//! relies on Unix process groups, nonblocking pipes and reaping discipline;
//! none of that exists here, so every query reports "unavailable" instead of
//! running an unbounded child process. Callers treat the error as a missing
//! query result and never substitute zero values.
use std::{path::Path, time::Duration};

#[derive(Default)]
pub struct BoundedCommand;

impl BoundedCommand {
    pub fn output(
        &mut self,
        program: &Path,
        args: &[&str],
        timeout: Duration,
        limit: usize,
    ) -> Result<Vec<u8>, String> {
        let _ = (args, timeout, limit);
        Err(format!(
            "Query subprocesses require Unix process control: {}",
            program.display()
        ))
    }
}
