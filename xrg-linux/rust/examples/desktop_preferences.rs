// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Emit isolated desktop-QA settings to stdout; never touches user preferences.
use xrg_ng_linux::settings::{Settings, WindowSize};
fn main() {
    let mut args = std::env::args().skip(1);
    let interval = args
        .next()
        .unwrap_or_else(|| "1000".into())
        .parse::<u32>()
        .expect("interval in milliseconds");
    let opacity = args
        .next()
        .unwrap_or_else(|| "1".into())
        .parse::<f64>()
        .expect("opacity fraction");
    assert!(
        args.next().is_none(),
        "Usage: desktop_preferences [interval-ms [opacity]]"
    );
    let mut settings = Settings {
        sampling_interval_ms: interval,
        window_opacity: opacity,
        window_size: Some(WindowSize {
            width: 220,
            height: 600,
        }),
        ..Default::default()
    };
    settings.ai.enabled = [false; 4];
    settings.ai.ollama = false;
    settings.weather.enabled = false;
    settings.validate().expect("valid QA preferences");
    println!("{}", serde_json::to_string_pretty(&settings).unwrap());
}
