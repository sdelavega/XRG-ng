// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::App;
use eframe::egui::{self, Color32};
use std::collections::BTreeMap;
use xrg_ng_linux::{
    dashboard::bytes,
    process::{
        self,
        control::{Action, Target},
        details::View,
    },
    settings::Module,
};
#[derive(Default)]
pub(super) struct Processes {
    details: BTreeMap<(u32, u64), View>,
    pending: Option<(Target, Action)>,
    message: Option<String>,
}
fn window(
    ctx: &egui::Context,
    key: &str,
    title: &str,
    size: [f32; 2],
    mut body: impl FnMut(&mut egui::Ui),
) -> bool {
    let mut open = true;
    ctx.show_viewport_immediate(
        egui::ViewportId::from_hash_of(key),
        egui::ViewportBuilder::default()
            .with_title(title)
            .with_inner_size(size),
        |ui, _| {
            if ui.ctx().input(|i| i.viewport().close_requested())
                || ui.input_mut(|i| i.consume_key(egui::Modifiers::NONE, egui::Key::Escape))
            {
                open = false;
            }
            egui::CentralPanel::default().show(ui, |ui| {
                egui::ScrollArea::both()
                    .auto_shrink([false, false])
                    .show(ui, |ui| body(ui))
            });
            super::smoke::paint_capture(ui);
        },
    );
    open
}
fn report_text(ui: &mut egui::Ui, text: &str) {
    ui.add(egui::Label::new(text).wrap().selectable(true));
}
pub(super) fn show(app: &mut App, ctx: &egui::Context) {
    if app.show_sensors {
        app.show_sensors = window(
            ctx,
            "sensors",
            "XRG-ng · Sensors and statistics",
            [960., 600.],
            |ui| {
                ui.label("Session statistics cover all readable temperature and fan inputs, independently of graph selection. Averages are sample-weighted. Missing inputs retain statistics and show n/a as current. Replaced inputs start fresh.");
                if let Some(snapshot) = &app.snapshot {
                    let report = &snapshot.sensors;
                    let units = app.settings.temperature_units;
                    ui.label(format!(
                        "{:.1}s since start/reset · snapshot {} · statistics generation {}",
                        report.elapsed_seconds, snapshot.sequence, report.generation
                    ));
                    ui.horizontal(|ui| {
                        if ui.button("Copy sensor report").clicked() {
                            ui.ctx().copy_text(report.text(units));
                        }
                        if ui.button("Reset session statistics").clicked()
                            && let Err(error) = app.worker.sensor_stats_control().reset()
                        {
                            app.error = Some(error);
                        }
                    });
                    ui.small("Reset applies at the next sample. Graph histories, source selection and sampling remain unchanged.");
                    egui::Grid::new("sensor-statistics")
                        .striped(true)
                        .spacing([12., 6.])
                        .show(ui, |ui| {
                            for title in [
                                "Sensor", "Current", "Minimum", "Average", "Maximum", "Samples",
                            ] {
                                ui.strong(title);
                            }
                            ui.end_row();
                            for row in &report.rows {
                                ui.label(&row.name).on_hover_text(format!(
                                    "{:?}\nSource: {}\nIncarnation: {}",
                                    row.kind, row.source_id, row.incarnation
                                ));
                                for value in [
                                    row.current,
                                    Some(row.minimum),
                                    Some(row.average),
                                    Some(row.maximum),
                                ] {
                                    ui.label(row.display(value, units));
                                }
                                ui.label(row.samples.to_string());
                                ui.end_row();
                            }
                        });
                    if report.rows.is_empty() {
                        ui.label("No readable sensor samples accumulated.");
                    }
                    for error in &report.errors {
                        report_text(ui, error);
                    }
                } else {
                    ui.label("Waiting for a sensor sample…");
                }
            },
        );
    }
    let modules: Vec<_> = app.details.iter().copied().collect();
    for module in modules {
        let open = window(
            ctx,
            &format!("details-{module:?}"),
            &format!("XRG-ng · {}", module.title()),
            [640., 550.],
            |ui| {
                if let Some(p) = app.panel(module) {
                    ui.heading(p.display_label(app.settings.temperature_units));
                    report_text(ui, &p.display_detail(app.settings.temperature_units));
                    if app.settings.activity_bars.visible {
                        ui.separator();
                        report_text(
                            ui,
                            &p.activity_description_with_minimum(
                                app.settings.temperature_units,
                                app.settings.minimum_scale(module),
                            ),
                        );
                    }
                    if module == Module::Cpu {
                        for (id, value) in &p.readout.cores {
                            ui.label(format!(
                                "CPU {id}: {}",
                                value
                                    .map(|v| format!("{v:.1}%"))
                                    .unwrap_or_else(|| "unavailable".into())
                            ));
                        }
                    }
                    if module == Module::Network {
                        ui.label(format!(
                            "Presentation floor: {} B/s (0 = automatic). Rates are unchanged.",
                            app.settings.network_min_scale
                        ));
                    }
                } else {
                    ui.label("Waiting for selected source…");
                }
            },
        );
        if !open {
            app.details.remove(&module);
        }
    }
    if app.show_ai {
        app.show_ai = window(ctx, "ai", "XRG-ng · AI usage", [720., 600.], |ui| {
            let mut show_models = app.settings.ai_show_model_breakdown;
            if ui
                .checkbox(&mut show_models, "Show model breakdown")
                .changed()
            {
                let mut s = app.settings.clone();
                s.ai_show_model_breakdown = show_models;
                if let Err(e) = app.apply(s, ctx) {
                    app.error = Some(e);
                }
            }
            if let Some(update) = app
                .snapshot
                .as_ref()
                .and_then(|s| s.ai.as_ref())
                .filter(|a| a.preferences == app.settings.ai)
            {
                report_text(ui, update.detail_for(show_models));
            } else {
                ui.label("Waiting for current AI sources…");
            }
        });
    }
    if app.show_weather {
        app.show_weather = window(ctx, "weather", "XRG-ng · Weather", [600., 520.], |ui| {
            if ui.button("Refresh observation").clicked() {
                app.worker.weather_control().refresh();
            }
            if let Some(update) = app
                .snapshot
                .as_ref()
                .and_then(|s| s.weather.as_ref())
                .filter(|w| w.preferences == app.settings.weather)
            {
                ui.heading(&update.summary);
                report_text(ui, &update.detail);
            } else {
                ui.label("Weather disabled or waiting for the selected station. Configure it in Preferences.");
            }
        });
    }
    if app.show_about {
        app.show_about = window(ctx, "about", "About XRG-ng", [480., 280.], |ui| {
            ui.heading(format!("XRG-ng {}", env!("CARGO_PKG_VERSION")));
            ui.label("Linux · Rust / shared Swift · egui");
            ui.label("Copyright © 2002–2024 Mike Piatek-Jimenez\nCopyright © 2025–2026 Marc Shade\nCopyright © 2026 Stephen de la Vega");
            ui.label("GNU General Public License, version 3 or later.");
            ui.hyperlink_to("Source and feedback", "https://github.com/sdelavega/XRG-ng");
        });
    }
    if app.show_processes {
        let mut processes = std::mem::take(&mut app.processes);
        let before = app.settings.processes.clone();
        app.show_processes = window(ctx, "processes", "XRG-ng · Processes", [960., 640.], |ui| {
            processes.table(ui, app)
        });
        if app.settings.processes != before {
            app.persist();
        }
        if !app.show_processes {
            processes.pending = None;
            processes.details.clear();
        }
        app.processes = processes;
    }
    let mut processes = std::mem::take(&mut app.processes);
    processes.details.retain(|key, view| {
        if let Some(snapshot) = &app.snapshot {
            view.update(&snapshot.processes);
        }
        window(
            ctx,
            &format!("process-{}-{}", key.0, key.1),
            &format!("XRG-ng · Process {}", key.0),
            [640., 600.],
            |ui| report_text(ui, &view.text()),
        )
    });
    app.processes = processes;
}
impl Processes {
    fn table(&mut self, ui: &mut egui::Ui, app: &mut App) {
        let view = &mut app.settings.processes;
        ui.label("CPU % uses one logical core = 100%; multithreaded processes can exceed 100%. Only readable processes are shown.");
        ui.horizontal(|ui| {
            ui.label("Filter");
            ui.add(egui::TextEdit::singleline(&mut view.filter).char_limit(128));
            let mut filtered = view.uid.is_some();
            if ui.checkbox(&mut filtered, "Filter UID").changed() {
                view.uid = filtered.then(|| unsafe { libc::geteuid() });
            }
            if let Some(uid) = &mut view.uid {
                ui.add(egui::DragValue::new(uid).range(0..=u32::MAX));
            }
            ui.label("Rows");
            ui.add(egui::DragValue::new(&mut view.limit).range(10..=200));
        });
        if let Some(message) = &self.message {
            ui.colored_label(Color32::LIGHT_YELLOW, message);
        }
        if let Some((target, action)) = &self.pending {
            let mut confirm = false;
            let mut cancel = false;
            ui.group(|ui| {
                let p = target.process();
                ui.strong(format!("{} · {} (PID {}, start {})", action.name(), p.name, p.pid, p.start_ticks));
                ui.label(action.explanation());
                ui.label("The pidfd pins this process instance. No numeric-PID fallback or privilege elevation is used.");
                ui.horizontal(|ui| {
                    confirm = ui.button(format!("Confirm {}", action.name())).clicked();
                    cancel = ui.button("Cancel").clicked();
                });
            });
            if confirm {
                let (target, action) = self.pending.take().unwrap();
                self.message = Some(match target.send(action) {
                    Ok(()) => format!("{} sent; awaiting a new sample.", action.name()),
                    Err(e) => e,
                });
            }
            if cancel {
                self.pending = None;
            }
        }
        let Some(snapshot) = app.snapshot.as_ref() else {
            ui.label("Waiting for a process sample…");
            return;
        };
        let report = match &snapshot.processes {
            Ok(report) => report,
            Err(e) => {
                ui.colored_label(Color32::LIGHT_RED, e);
                return;
            }
        };
        if report.partial() {
            ui.label(format!(
                "Partial scan: {} / {} attempted, {} unreadable, {} vanished.",
                report.attempted, report.discovered, report.unreadable, report.vanished
            ));
        }
        egui::Grid::new("process-table")
            .striped(true)
            .spacing([12., 6.])
            .show(ui, |ui| {
                for (title, sort) in [
                    ("PID", process::Sort::Pid),
                    ("Process", process::Sort::Name),
                    ("CPU %", process::Sort::Cpu),
                    ("RSS", process::Sort::Memory),
                ] {
                    if ui.selectable_label(view.sort == sort, title).clicked() {
                        view.sort = sort;
                    }
                }
                ui.label("UID");
                ui.label("Threads");
                ui.label("Tools");
                ui.end_row();
                for p in report.ranked(view.sort, view.uid, &view.filter, view.limit as usize) {
                    ui.push_id((p.pid, p.start_ticks), |ui| {
                        ui.label(p.pid.to_string());
                        ui.label(&p.name);
                        ui.label(
                            p.cpu_percent
                                .map(|v| format!("{v:.1}"))
                                .unwrap_or_else(|| "unavailable".into()),
                        );
                        ui.label(bytes(p.rss_bytes as f64));
                        ui.label(p.uid.map(|u| u.to_string()).unwrap_or_else(|| "?".into()));
                        ui.label(p.threads.to_string());
                        ui.menu_button("…", |ui| {
                            if ui.button("Read-only details…").clicked() {
                                if self.details.len() < 8
                                    || self.details.contains_key(&(p.pid, p.start_ticks))
                                {
                                    self.details
                                        .entry((p.pid, p.start_ticks))
                                        .or_insert_with(|| View::new(p.clone()));
                                } else {
                                    self.message = Some(
                                        "Close an inspector before opening another (limit 8)."
                                            .into(),
                                    );
                                }
                                ui.close();
                            }
                            for action in Action::ALL {
                                if ui
                                    .add_enabled(
                                        action.enabled(p),
                                        egui::Button::new(action.name()),
                                    )
                                    .clicked()
                                {
                                    match Target::prepare(p) {
                                        Ok(target) => self.pending = Some((target, action)),
                                        Err(e) => self.message = Some(e),
                                    }
                                    ui.close();
                                }
                            }
                        });
                        ui.end_row();
                    });
                }
            });
    }
}
