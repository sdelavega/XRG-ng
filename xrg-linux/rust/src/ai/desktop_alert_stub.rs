// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Linux stub for the AI budget desktop alert. The alert speaks the
//! freedesktop D-Bus notification protocol directly over the session bus;
//! no notification service is wired up off Linux, so the alert reports
//! "unavailable" instead of pretending the user was notified.

pub const IMPLEMENTATION: &str = "stub";

pub(super) fn send(percent: f64) -> Result<(), String> {
    let _ = percent;
    Err("Desktop notifications require the Linux D-Bus protocol".into())
}
