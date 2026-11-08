// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The one HTTPS GET both opt-in network collectors use: bounded curl.
//!
//! Weather (METAR) and Stocks (Yahoo chart) fetch with the same client,
//! timeouts and response cap, so a source change tunes one path and every
//! collector keeps the same failure behaviour. The per-thread
//! [`BoundedCommand`] keeps the weather collector's guarantee that a
//! killed-but-unreaped query blocks further launches on the same thread
//! instead of accumulating processes.
use crate::command::BoundedCommand;
use std::{cell::RefCell, path::Path, time::Duration};

/// The request deadline both collectors give curl (spec §7: the Stocks
/// fetcher reuses the HTTP client and timeouts already used for weather).
pub const TIMEOUT: Duration = Duration::from_secs(5);

thread_local! {
    static COMMAND: RefCell<BoundedCommand> = RefCell::default();
}

/// One bounded HTTPS GET: HTTPS-only curl with fixed connect and total
/// deadlines and the 2 MiB response cap, answering the body bytes or the
/// failure as text.
pub fn https_get(url: &str, timeout: Duration) -> Result<Vec<u8>, String> {
    let seconds = timeout.as_secs().max(1).to_string();
    // The process bound keeps half a second of grace over curl's own
    // --max-time, exactly as the weather collector always bounded it.
    let bound = timeout + Duration::from_millis(500);
    COMMAND.with_borrow_mut(|command| {
        command.output(
            Path::new("curl"),
            &[
                "-q",
                "--silent",
                "--fail",
                "--globoff",
                "--noproxy",
                "*",
                "--proto",
                "=https",
                "--connect-timeout",
                "3",
                "--max-time",
                &seconds,
                "--max-filesize",
                "2097152",
                "--user-agent",
                concat!("XRG-ng/", env!("CARGO_PKG_VERSION"), " (Linux)"),
                url,
            ],
            bound,
            2_097_152,
        )
    })
}
