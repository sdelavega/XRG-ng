// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
#[cfg(feature = "gtk-ui")]
mod ui;
use std::{process::ExitCode, time::Duration};
use xrg_ng_linux::{engine::Sampler, shared};

fn main() -> ExitCode {
    shared::check_abi();
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--version"] {
        println!("XRG-ng {}", env!("CARGO_PKG_VERSION"));
        return ExitCode::SUCCESS;
    }
    if args.first().is_some_and(|arg| arg == "--headless") {
        let count = match args.as_slice() {
            [_] => 3,
            [_, flag, value] if flag == "--samples" => match value.parse::<u32>() {
                Ok(n @ 2..=3600) => n,
                _ => return usage(),
            },
            _ => return usage(),
        };
        let (_, settings, error) =
            xrg_ng_linux::settings::Store::open(xrg_ng_linux::settings::preferences_path());
        if let Some(error) = error {
            eprintln!("Preferences unavailable; using default AI sources: {error}");
        }
        let mut sampler = Sampler::live_with_sources(true, settings.ai, settings.weather);
        let mut valid = false;
        for index in 0..count {
            let snapshot = sampler.sample();
            valid = snapshot.valid;
            println!("sample={} valid={}", snapshot.sequence, snapshot.valid);
            for panel in snapshot.panels {
                println!(
                    "{}: {}",
                    panel.title,
                    panel.display_label(settings.temperature_units)
                );
            }
            if index + 1 < count {
                std::thread::sleep(Duration::from_secs(1));
            }
        }
        return if valid {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }
    #[cfg(feature = "gtk-ui")]
    if args.is_empty() || args == ["--smoke-test"] {
        return if ui::run(!args.is_empty()) {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }
    usage()
}
fn usage() -> ExitCode {
    eprintln!(
        "Usage: xrg-ng-linux [--version | --headless [--samples 2..3600] | --smoke-test]\nBuild with --features gtk-ui for the GTK 4 application."
    );
    ExitCode::from(2)
}
