// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
pub mod ai;
pub mod collectors;
#[cfg(unix)]
pub mod command;
pub mod cpu;
pub mod dashboard;
pub mod engine;
pub mod gpu;
pub mod gpu_memory;
#[cfg(feature = "gtk-ui")]
pub mod graph;
pub mod hardware;
pub mod legacy;
pub mod shared;
pub mod temperature;
pub mod weather;

pub mod process;
mod sensors;
mod system_file;
pub mod tpu;

pub mod settings;

pub mod memory;
pub mod metric_sources;
pub mod metrics;
