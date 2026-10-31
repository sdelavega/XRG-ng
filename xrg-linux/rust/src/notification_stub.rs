// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Linux twin of the publication wakeup registry. The registry itself is
//! portable std plumbing shared verbatim with the Linux module
//! (`notification/common`), so wakeups behave identically on every platform
//! and the engine's worker tests keep running; nothing is invented either
//! way. It is marked as the stub so a cfg mistake cannot pass the platform
//! selection test.
#[path = "notification/common.rs"]
mod common;
pub const IMPLEMENTATION: &str = "stub";
pub(crate) use common::Notification;
