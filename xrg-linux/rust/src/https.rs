// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The bounded HTTPS GET both opt-in network collectors use.
//!
//! Weather (METAR) keeps its original `--fail` behaviour: an HTTP error is a
//! transport failure, with the METAR User-Agent. Stocks (Yahoo chart) needs
//! the HTTP status and body even on an error, because Yahoo answers an
//! unknown symbol with a 404 whose body is a `chart.error` envelope — with
//! `--fail` that body is lost and the ticker is misread as a network error.
//! Both paths share curl's deadlines, response cap and per-thread
//! [`BoundedCommand`], so a source change tunes one client, not two. The
//! per-thread guard keeps the weather collector's guarantee that a
//! killed-but-unreaped query blocks further launches on the same thread.
use crate::command::BoundedCommand;
use std::{cell::RefCell, path::Path, time::Duration};

/// The request deadline both collectors give curl (spec §7: the Stocks
/// fetcher reuses the HTTP client and timeouts already used for weather).
pub const TIMEOUT: Duration = Duration::from_secs(5);

thread_local! {
    static COMMAND: RefCell<BoundedCommand> = RefCell::default();
}

/// Weather (METAR): one bounded HTTPS GET with `--fail`, answering the body
/// bytes or the failure as text. An HTTP error is a transport failure, exactly
/// as the weather collector always treated it; the User-Agent is unchanged.
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
                concat!(
                    "XRG-ng/",
                    env!("CARGO_PKG_VERSION"),
                    " (Linux METAR monitor)"
                ),
                url,
            ],
            bound,
            2_097_152,
        )
    })
}

/// The HTTP status and body of one reply, before a collector classifies it.
/// The status is kept next to the body so a 404 can be told apart from a
/// transport failure without discarding its payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpReply {
    pub status: u16,
    pub body: Vec<u8>,
}

/// The `Fetch` answer for one Stocks reply. A 2xx, or Yahoo's 404, keeps its
/// body so the shared classifier can read the `chart.error` not-found
/// envelope out of it (instead of `--fail` turning the 404 into a transport
/// error). Other HTTP errors and curl-level failures remain transport errors,
/// for which the collector retains the last good values. This is a pure
/// boundary so the transport decision is testable without the network.
pub fn stock_body(reply: Result<HttpReply, String>) -> Result<Vec<u8>, String> {
    match reply {
        Ok(HttpReply { status, body }) if (200..=299).contains(&status) || status == 404 => {
            Ok(body)
        }
        Ok(HttpReply { status, .. }) => Err(format!("HTTP {status} fetching the stock chart")),
        Err(problem) => Err(problem),
    }
}

/// Split the `%{http_code}` trailer curl appends into a reply's status and
/// body. HTTP codes are exactly three digits, so the last three bytes are the
/// status; a missing or invalid trailer is a transport failure.
fn split_stock_reply(mut raw: Vec<u8>) -> Result<HttpReply, String> {
    if raw.len() < 3 {
        return Err("the HTTP reply has no status".into());
    }
    let trailer = raw.split_off(raw.len() - 3);
    let status = std::str::from_utf8(&trailer)
        .ok()
        .and_then(|text| text.parse::<u16>().ok())
        .filter(|status| *status >= 100)
        .ok_or_else(|| "the HTTP status is not a three-digit code".to_string())?;
    Ok(HttpReply { status, body: raw })
}

/// Stocks (Yahoo chart): one bounded HTTPS GET that keeps the HTTP status and
/// body. curl runs without `--fail` and appends `%{http_code}`, so a 404's
/// not-found envelope survives; `stock_body` then hands the classifier the
/// body (or a transport error). Weather keeps `https_get` unchanged.
pub fn stock_https_get(url: &str, timeout: Duration) -> Result<Vec<u8>, String> {
    let seconds = timeout.as_secs().max(1).to_string();
    let bound = timeout + Duration::from_millis(500);
    let raw = COMMAND.with_borrow_mut(|command| {
        command.output(
            Path::new("curl"),
            &[
                "-q",
                "--silent",
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
                "--write-out",
                "%{http_code}",
                "--user-agent",
                concat!("XRG-ng/", env!("CARGO_PKG_VERSION"), " (Linux Stocks)"),
                url,
            ],
            bound,
            2_097_152 + 16,
        )
    })?;
    stock_body(split_stock_reply(raw))
}
