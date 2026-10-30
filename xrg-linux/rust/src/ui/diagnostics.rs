// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Opt-in desktop-QA counters. No log paths, process names or device data collected.
use eframe::egui;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use serde::Serialize;
use std::time::Instant;
const LIMIT: usize = 8192;
#[derive(Serialize)]
struct Event {
    at_ms: u64,
    width: u32,
    height: u32,
    native_width: u32,
    native_height: u32,
    pixels_per_point: f32,
    zoom_factor: f32,
}
#[derive(Serialize)]
struct Report {
    backend: &'static str,
    renderer: String,
    sampling_interval_ms: u32,
    ui_passes: u64,
    snapshots: u64,
    valid_snapshots: u64,
    max_known_viewports: usize,
    preferences_openings: u32,
    detail_openings: u32,
    events: Vec<Event>,
    dropped_events: u64,
    #[serde(skip)]
    started: Instant,
    #[serde(skip)]
    last_preferences: bool,
    #[serde(skip)]
    last_details: usize,
    #[serde(skip)]
    last_window: Option<(u32, u32, bool, bool, bool)>,
}
#[derive(Default)]
pub(super) struct Diagnostics {
    report: Option<Report>,
}
impl Diagnostics {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        if std::env::var("XRG_DESKTOP_REPORT").as_deref() != Ok("1") {
            return Self::default();
        }
        let renderer = cc
            .gl
            .as_ref()
            .map(|gl| {
                use eframe::glow::HasContext;
                // The creator runs on the current, initialized native GL context.
                unsafe { gl.get_parameter_string(eframe::glow::RENDERER) }
            })
            .unwrap_or_else(|| "unavailable".into());
        Self {
            report: Some(Report {
                backend: "unknown",
                renderer,
                sampling_interval_ms: 0,
                ui_passes: 0,
                snapshots: 0,
                valid_snapshots: 0,
                max_known_viewports: 1,
                preferences_openings: 0,
                detail_openings: 0,
                events: Vec::new(),
                dropped_events: 0,
                started: Instant::now(),
                last_preferences: false,
                last_details: 0,
                last_window: None,
            }),
        }
    }
    pub fn sample(&mut self, valid: bool) {
        if let Some(r) = &mut self.report {
            r.snapshots += 1;
            r.valid_snapshots += u64::from(valid);
        }
    }
    pub fn observe(
        &mut self,
        frame: &eframe::Frame,
        ui: &egui::Ui,
        interval: u32,
        preferences: bool,
        details: usize,
        collapse: (bool, bool),
    ) {
        let Some(r) = &mut self.report else {
            return;
        };
        if r.backend == "unknown" {
            r.backend = frame
                .window_handle()
                .map(|h| match h.as_raw() {
                    RawWindowHandle::Wayland(_) => "wayland",
                    RawWindowHandle::Xlib(_) | RawWindowHandle::Xcb(_) => "x11",
                    _ => "other",
                })
                .unwrap_or("unavailable");
        }
        let size = ui.ctx().viewport_rect();
        let event = Event {
            at_ms: r.started.elapsed().as_millis() as u64,
            width: size.width().round() as u32,
            height: size.height().round() as u32,
            native_width: (size.width() * ui.ctx().zoom_factor()).round() as u32,
            native_height: (size.height() * ui.ctx().zoom_factor()).round() as u32,
            pixels_per_point: ui.ctx().pixels_per_point(),
            zoom_factor: ui.ctx().zoom_factor(),
        };
        let window = (
            event.native_width,
            event.native_height,
            collapse.0,
            collapse.1,
            preferences,
        );
        if r.last_window != Some(window) {
            println!(
                "XRG_DESKTOP_WINDOW {}",
                serde_json::json!({
                    "backend":r.backend,"native_width":event.native_width,"native_height":event.native_height,
                    "pixels_per_point":event.pixels_per_point,"zoom_factor":event.zoom_factor,
                    "closed":collapse.0,"latched":collapse.1,"preferences":preferences,"snapshots":r.snapshots
                })
            );
            r.last_window = Some(window);
        }
        r.ui_passes += 1;
        r.sampling_interval_ms = interval;
        r.max_known_viewports = r
            .max_known_viewports
            .max(ui.input(|i| i.raw.viewports.len()));
        if preferences && !r.last_preferences {
            r.preferences_openings += 1;
        }
        if details > r.last_details {
            r.detail_openings += (details - r.last_details) as u32;
        }
        r.last_preferences = preferences;
        r.last_details = details;
        if r.ui_passes == 2 {
            println!(
                "XRG_DESKTOP_READY {}",
                serde_json::json!({"backend":r.backend,"at_ms":event.at_ms,"width":event.width,"height":event.height,"pixels_per_point":event.pixels_per_point,"zoom_factor":event.zoom_factor})
            );
        }
        if r.events.len() < LIMIT {
            r.events.push(event);
        } else {
            r.dropped_events += 1;
        }
    }
    pub fn finish(&self) {
        if let Some(r) = &self.report {
            println!(
                "XRG_DESKTOP_REPORT {}",
                serde_json::to_string(r).expect("finite diagnostic counters")
            );
        }
    }
}

/// Exercise the normal egui zoom implementation in isolated desktop QA only.
pub(super) fn configure(ctx: &egui::Context) {
    if std::env::var("XRG_DESKTOP_REPORT").as_deref() == Ok("1")
        && let Ok(value) = std::env::var("XRG_DESKTOP_ZOOM")
    {
        let zoom: f32 = value.parse().expect("XRG_DESKTOP_ZOOM must be numeric");
        assert!(
            zoom.is_finite() && (0.5..=2.).contains(&zoom),
            "QA zoom must be 0.5–2"
        );
        ctx.set_zoom_factor(zoom);
    }
}

pub(super) fn focus(response: &egui::Response, name: &str) {
    if response.gained_focus() && std::env::var("XRG_DESKTOP_REPORT").as_deref() == Ok("1") {
        println!("XRG_DESKTOP_FOCUS {}", serde_json::json!({"name":name}));
    }
}
