// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
pub mod ai;
pub mod collectors;
#[cfg(unix)]
pub mod command;
pub mod engine;
pub mod gpu;
pub mod gpu_memory;
pub mod hardware;
pub mod shared;
pub mod weather;

pub mod process;
mod system_file;
pub mod tpu;

pub mod settings;

pub mod metric_sources;
pub mod metrics;
