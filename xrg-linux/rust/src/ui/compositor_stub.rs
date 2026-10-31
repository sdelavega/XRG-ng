// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Linux stub for the dashboard fade compositor. The compositor is a
//! Linux windowing seam; off Linux the fade is unavailable, which surfaces as
//! the module's existing error value so the UI reports "Window opacity
//! unavailable" instead of silently dropping frames or inventing blending.
use eframe::{egui, glow};
use std::sync::{Arc, Mutex};

pub const IMPLEMENTATION: &str = "stub";

#[derive(Default)]
pub(super) struct Compositor {
    pub error: Option<String>,
}
impl Compositor {
    pub fn enqueue(owner: &Arc<Mutex<Self>>, ui: &egui::Ui, opacity: f64) {
        if opacity >= 1. {
            return;
        }
        // No compositor shader runs off Linux; report the unavailable value.
        owner.lock().unwrap().error = Some("Fade compositor requires Linux".into());
        let _ = ui;
    }
    pub fn destroy(&mut self, _gl: &glow::Context) {}
}
