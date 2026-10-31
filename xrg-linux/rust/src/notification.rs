// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Publication wakeups, independent of any UI toolkit. Slots remain the source of truth.
/// The Linux implementation of the publication wakeup registry.
pub const IMPLEMENTATION: &str = "linux";
mod common;
pub(crate) use common::Notification;
