// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Compile-time platform selection for the shared XRG-ng core. Collectors
//! report unavailable values off Linux instead of inventing readings; this
//! constant lets callers and tests confirm which build they are in.

#[derive(Debug, PartialEq, Eq)]
pub enum Platform {
    Linux,
    MacOS,
    Windows,
    Other,
}

pub const PLATFORM: Platform = if cfg!(target_os = "linux") {
    Platform::Linux
} else if cfg!(target_os = "macos") {
    Platform::MacOS
} else if cfg!(target_os = "windows") {
    Platform::Windows
} else {
    Platform::Other
};
