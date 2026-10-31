// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
pub mod ai;
pub mod battery;
pub mod collectors;
#[cfg(unix)]
pub mod command;
#[cfg(not(unix))]
#[path = "command_stub.rs"]
pub mod command;
pub mod cpu;
pub mod dashboard;
#[cfg(target_os = "linux")]
pub mod drm_clients;
#[cfg(not(target_os = "linux"))]
#[path = "drm_clients_stub.rs"]
pub mod drm_clients;
pub mod engine;
#[cfg(target_os = "linux")]
pub mod gpu;
#[cfg(not(target_os = "linux"))]
#[path = "gpu_stub.rs"]
pub mod gpu;
pub mod gpu_memory;
#[cfg(feature = "egui-ui")]
pub mod graph;
#[cfg(target_os = "linux")]
pub mod hardware;
#[cfg(not(target_os = "linux"))]
#[path = "hardware_stub.rs"]
pub mod hardware;
pub mod legacy;
pub mod platform;
pub mod shared;
pub mod temperature;
pub mod weather;

pub mod process;
pub mod sampling;
pub mod sensor_stats;
mod sensors;
#[cfg(unix)]
pub mod system_file;
#[cfg(not(unix))]
#[path = "system_file_stub.rs"]
pub mod system_file;
pub mod tpu;

pub mod settings;

pub mod memory;
pub mod metric_sources;
pub mod metrics;
#[cfg(target_os = "linux")]
pub mod notification;
#[cfg(not(target_os = "linux"))]
#[path = "notification_stub.rs"]
pub mod notification;
#[cfg(feature = "egui-ui")]
pub mod ui;
