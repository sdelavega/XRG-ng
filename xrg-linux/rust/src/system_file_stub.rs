// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Unix stub for the hardened file reader. Hardened Unix file discipline
//! (O_NOFOLLOW/O_NONBLOCK, regular-file and size enforcement) cannot be
//! provided, so every read reports "unsupported" instead of returning
//! possibly unsafe or partial data. Callers map the error to their existing
//! "unavailable" reporting; no value is ever invented.
use std::{io, path::Path};

pub const IMPLEMENTATION: &str = "stub";

pub(crate) fn read(path: &Path, limit: usize) -> io::Result<Vec<u8>> {
    let _ = limit;
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        format!("System files require Unix: {}", path.display()),
    ))
}
