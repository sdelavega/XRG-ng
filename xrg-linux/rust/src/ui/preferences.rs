// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Draft-only preferences. Apply validates before changing workers or storage.
use super::{
    App,
    file_picker::{Action, Choice, Decision, PathField, Picker},
};
use eframe::egui::{self, Color32};
use std::{path::PathBuf, sync::mpsc};
use xrg_ng_linux::{
    metrics::{Inventory, SourceOption},
    settings::{self, GraphStyle, Layout, Settings, ThemeChoice, ThemeDocument},
};

enum Loaded {
    Theme(Box<ThemeDocument>),
    Legacy(Box<xrg_ng_linux::legacy::Import>),
    Saved,
}
pub(super) struct Editor {
    pub draft: Settings,
    pub(super) tab: usize,
    theme_path: PathField,
    legacy_path: PathField,
    pub(super) picker: Option<Picker>,
    message: Option<String>,
    import: Option<xrg_ng_linux::legacy::Import>,
    pending: Option<mpsc::Receiver<Result<Loaded, String>>>,
    replace_theme: bool,
}
impl Editor {
    pub fn new(draft: Settings) -> Self {
        Self {
            draft,
            tab: 0,
            theme_path: PathField::default(),
            picker: None,
            legacy_path: PathField::new(
                xrg_ng_linux::legacy::path_from(
                    std::env::var_os("XDG_CONFIG_HOME").as_deref(),
                    std::env::var_os("HOME").as_deref(),
                )
                .unwrap_or_default(),
            ),
            message: None,
            import: None,
            pending: None,
            replace_theme: false,
        }
    }
    pub(super) fn restore_defaults(&mut self) {
        self.draft = Settings {
            ai: self.draft.ai.clone(),
            weather: self.draft.weather.clone(),
            ..Default::default()
        };
        // Ignore any old asynchronous import completion after this new choice.
        self.pending = None;
        self.picker = None;
        self.import = None;
        self.message = None;
    }
    fn content(&mut self, ui: &mut egui::Ui, inventory: &Inventory) {
        let was_busy = self.busy();
        self.poll();
        if was_busy && !self.busy() {
            ui.ctx().request_repaint();
        }
        ui.add_enabled_ui(!self.busy(), |ui| self.form(ui, inventory));
    }
    fn form(&mut self, ui: &mut egui::Ui, inventory: &Inventory) {
        ui.horizontal_wrapped(|ui| {
            for (i, label) in [
                "General",
                "Graphs",
                "Sources",
                "AI",
                "Weather",
                "Themes / import",
            ]
            .into_iter()
            .enumerate()
            {
                ui.selectable_value(&mut self.tab, i, label);
            }
        });
        ui.separator();
        egui::ScrollArea::vertical()
            .id_salt("preferences-body")
            .show(ui, |ui| match self.tab {
                0 => general(ui, &mut self.draft),
                1 => graphs(ui, &mut self.draft),
                2 => sources(ui, &mut self.draft, inventory),
                3 => ai(ui, &mut self.draft),
                4 => weather(ui, &mut self.draft),
                _ => self.themes(ui),
            });
    }
    fn start(
        &mut self,
        ctx: &egui::Context,
        task: impl FnOnce() -> Result<Loaded, String> + Send + 'static,
    ) {
        let (sender, receiver) = mpsc::channel();
        self.pending = Some(receiver);
        self.message = Some("Working…".into());
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let _ = sender.send(task());
            ctx.request_repaint();
        });
    }
    fn poll(&mut self) {
        let result = self.pending.as_ref().map(|receiver| receiver.try_recv());
        match result {
            Some(Ok(result)) => {
                self.pending = None;
                match result {
                    Ok(Loaded::Theme(theme)) => {
                        self.draft.theme = ThemeChoice::Custom { theme };
                        self.message = Some("Theme loaded into draft. Apply to use it.".into());
                    }
                    Ok(Loaded::Legacy(import)) => {
                        self.import = Some(*import);
                        self.message = None;
                    }
                    Ok(Loaded::Saved) => self.message = Some("Theme saved.".into()),
                    Err(e) => self.message = Some(e),
                }
            }
            Some(Err(mpsc::TryRecvError::Disconnected)) => {
                self.pending = None;
                self.message = Some("File operation stopped before returning a result.".into());
            }
            _ => (),
        }
    }
    pub(super) fn choose(&mut self, action: Action, ctx: &egui::Context) {
        if self.pending.is_some() {
            return;
        }
        let path = if action == Action::ImportLegacy {
            self.legacy_path.path()
        } else {
            self.theme_path.path()
        };
        self.choose_at(action, path, ctx);
    }
    pub(super) fn choose_at(&mut self, action: Action, path: PathBuf, ctx: &egui::Context) {
        self.tab = 5;
        self.picker = Some(Picker::new(action, path, ctx));
    }
    pub(super) fn busy(&self) -> bool {
        self.pending.is_some()
    }
    pub(super) fn import_ready(&self) -> bool {
        self.import.is_some()
    }
    pub(super) fn message(&self) -> Option<&str> {
        self.message.as_deref()
    }
    pub(super) fn accept_import(&mut self) {
        if let Some(import) = self.import.take() {
            self.draft = import.settings;
            self.message = Some("Imported into draft. Review before Apply.".into());
        }
    }
    fn load_theme(&mut self, ctx: &egui::Context, path: PathBuf) {
        self.start(ctx, move || {
            ThemeDocument::load(&path).map(|t| Loaded::Theme(Box::new(t)))
        });
    }
    fn save_theme(&mut self, ctx: &egui::Context, path: PathBuf, replace: bool) {
        let document = self.draft.theme.palette().map(|p| ThemeDocument::new(&p));
        self.start(ctx, move || {
            if let Some(preferences) = settings::preferences_path()
                && (path == preferences
                    || path
                        .canonicalize()
                        .ok()
                        .zip(preferences.canonicalize().ok())
                        .is_some_and(|(a, b)| a == b))
            {
                return Err("Export a theme separately from application preferences.".into());
            }
            let document = document?;
            if replace {
                document.save(&path)?;
            } else {
                document.save_new(&path)?;
            }
            Ok(Loaded::Saved)
        });
    }
    fn review_legacy(&mut self, ctx: &egui::Context, path: PathBuf) {
        let base = self.draft.clone();
        self.start(ctx, move || {
            xrg_ng_linux::legacy::load(&path, &base).map(|i| Loaded::Legacy(Box::new(i)))
        });
    }
    fn chosen(&mut self, choice: Choice, ctx: &egui::Context) {
        match choice.action {
            Action::LoadTheme => {
                self.theme_path.set(choice.path.clone());
                self.load_theme(ctx, choice.path);
            }
            Action::SaveTheme => {
                self.theme_path.set(choice.path.clone());
                self.save_theme(ctx, choice.path, choice.replace);
            }
            Action::ImportLegacy => {
                self.legacy_path.set(choice.path.clone());
                self.review_legacy(ctx, choice.path);
            }
        }
    }
    fn show_picker(&mut self, ui: &mut egui::Ui) {
        let Some(decision) = self.picker.as_mut().and_then(|p| p.show(ui)) else {
            return;
        };
        self.picker = None;
        if let Decision::Chosen(choice) = decision {
            self.chosen(choice, ui.ctx());
        }
    }
    fn themes(&mut self, ui: &mut egui::Ui) {
        ui.heading("Theme");
        theme_picker(ui, &mut self.draft.theme);
        if let ThemeChoice::Custom { theme } = &mut self.draft.theme {
            ui.horizontal(|ui| {
                ui.label("Name");
                ui.text_edit_singleline(&mut theme.name);
            });
            for (index, label) in [
                "Window",
                "Graph background",
                "Series 1",
                "Series 2",
                "Series 3",
                "Border",
                "Text",
            ]
            .into_iter()
            .enumerate()
            {
                ui.horizontal(|ui| {
                    rgba(ui, &mut theme.colors[index]);
                    ui.label(label);
                });
            }
        }
        if ui.button("Edit current palette as custom").clicked()
            && let Ok(palette) = self.draft.theme.palette()
        {
            self.draft.theme = ThemeChoice::Custom {
                theme: Box::new(ThemeDocument::new(&palette)),
            };
        }
        ui.separator();
        ui.label("Theme file path (.json or original XRG .xtf)");
        self.theme_path.edit(ui);
        ui.checkbox(
            &mut self.replace_theme,
            "Allow replacing an existing theme file when saving the pasted path",
        );
        ui.horizontal_wrapped(|ui| {
            if ui
                .add_enabled(self.pending.is_none(), egui::Button::new("Browse to load…"))
                .clicked()
            {
                self.choose(Action::LoadTheme, ui.ctx());
            }
            if ui
                .add_enabled(self.pending.is_none(), egui::Button::new("Browse to save…"))
                .clicked()
            {
                self.choose(Action::SaveTheme, ui.ctx());
            }
            if ui
                .add_enabled(self.pending.is_none(), egui::Button::new("Load path"))
                .clicked()
            {
                self.load_theme(ui.ctx(), self.theme_path.path());
            }
            if ui
                .add_enabled(self.pending.is_none(), egui::Button::new("Save path"))
                .clicked()
            {
                self.save_theme(ui.ctx(), self.theme_path.path(), self.replace_theme);
            }
        });
        ui.label("Browse folders or paste a path. Theme files contain only the color palette.");
        ui.separator();
        ui.heading("Import legacy Linux settings");
        self.legacy_path.edit(ui);
        ui.horizontal_wrapped(|ui| {
            if ui
                .add_enabled(
                    self.pending.is_none(),
                    egui::Button::new("Browse legacy settings…"),
                )
                .clicked()
            {
                self.choose(Action::ImportLegacy, ui.ctx());
            }
            if ui
                .add_enabled(
                    self.pending.is_none(),
                    egui::Button::new("Review pasted path…"),
                )
                .clicked()
            {
                self.review_legacy(ui.ctx(), self.legacy_path.path());
            }
        });
        if let Some(import) = &self.import {
            ui.label(import.summary());
            let mut accept = false;
            let mut cancel = false;
            ui.horizontal(|ui| {
                accept = ui.button("Import into draft").clicked();
                cancel = ui.button("Cancel import").clicked();
            });
            if accept {
                self.accept_import();
            }
            if cancel {
                self.import = None;
            }
        }
    }
}
pub(super) fn show(app: &mut App, ctx: &egui::Context) {
    let Some(mut editor) = app.preferences.take() else {
        return;
    };
    let mut open = true;
    let mut apply = false;
    let inventory = app
        .snapshot
        .as_ref()
        .map(|s| s.inventory.clone())
        .unwrap_or_default();
    ctx.show_viewport_immediate(
        egui::ViewportId::from_hash_of("preferences"),
        egui::ViewportBuilder::default()
            .with_title("XRG-ng Preferences")
            .with_inner_size([680., 720.]),
        |ui, _| {
            if ui.ctx().input(|i| i.viewport().close_requested())
                || (editor.picker.is_none()
                    && ui.input_mut(|i| i.consume_key(egui::Modifiers::NONE, egui::Key::Escape)))
            {
                open = false;
            }
            egui::CentralPanel::default().show(ui, |ui| {
                ui.add_enabled_ui(editor.picker.is_none(), |ui| {
                    egui::Panel::bottom("preferences-actions").show(ui, |ui| {
                        if let Some(message) = &editor.message {
                            ui.colored_label(Color32::LIGHT_YELLOW, message);
                        }
                        ui.horizontal(|ui| {
                            if ui.button("Defaults").clicked() {
                                editor.restore_defaults();
                            }
                            if ui.button("Cancel").clicked() {
                                open = false;
                            }
                            if ui
                                .add_enabled(editor.pending.is_none(), egui::Button::new("Apply"))
                                .clicked()
                            {
                                apply = true;
                            }
                            ui.label("Edits take effect only on Apply.");
                        });
                    });
                    editor.content(ui, &inventory);
                });
            });
            editor.show_picker(ui);
            super::smoke::paint_capture(ui);
        },
    );
    if apply {
        editor.draft.weather.station = editor.draft.weather.station.trim().to_ascii_uppercase();
        match app.apply(editor.draft.clone(), ctx) {
            Ok(()) => editor.message = Some("Preferences applied.".into()),
            Err(e) => editor.message = Some(e),
        }
    }
    if open {
        app.preferences = Some(editor);
    }
}
fn general(ui: &mut egui::Ui, s: &mut Settings) {
    ui.heading("Dashboard");
    egui::Grid::new("general")
        .num_columns(2)
        .spacing([14., 10.])
        .show(ui, |ui| {
            ui.label("Layout");
            ui.horizontal(|ui| {
                ui.selectable_value(&mut s.layout, Layout::Vertical, "Vertical");
                ui.selectable_value(&mut s.layout, Layout::Horizontal, "Horizontal");
            });
            ui.end_row();
            let label = ui.label("Graph width");
            ui.add(
                egui::DragValue::new(&mut s.graph_width)
                    .range(100..=1200)
                    .suffix(" px"),
            )
            .labelled_by(label.id);
            ui.end_row();
            let label = ui.label("Default graph height");
            ui.add(
                egui::DragValue::new(&mut s.graph_height)
                    .range(64..=240)
                    .suffix(" px"),
            )
            .labelled_by(label.id);
            ui.end_row();
            let label = ui.label("System sampling target");
            ui.add(
                egui::DragValue::new(&mut s.sampling_interval_ms)
                    .range(xrg_ng_linux::sampling::MIN_MS..=xrg_ng_linux::sampling::MAX_MS)
                    .speed(50.)
                    .suffix(" ms"),
            )
            .labelled_by(label.id);
            ui.end_row();
            ui.label("Temperature");
            ui.horizontal(|ui| {
                ui.selectable_value(
                    &mut s.temperature_units,
                    xrg_ng_linux::temperature::Units::Celsius,
                    "°C",
                );
                ui.selectable_value(
                    &mut s.temperature_units,
                    xrg_ng_linux::temperature::Units::Fahrenheit,
                    "°F",
                );
            });
            ui.end_row();
            let label = ui.label("Window opacity");
            ui.add(egui::Slider::new(&mut s.window_opacity, 0.1..=1.).show_value(true))
                .labelled_by(label.id);
            ui.end_row();
            ui.label("Collapsed window");
            ui.checkbox(
                &mut s.window_collapse.collapsed,
                "Collapse to the hostname strip",
            ).on_hover_text("Ctrl+M or double-click the hostname toggles collapse. The + button expands the strip. Collection continues while collapsed.");
            ui.end_row();
            ui.label("Hover expansion");
            ui.checkbox(
                &mut s.window_collapse.expand_on_hover,
                "Temporarily expand on hover",
            ).on_hover_text("Leave the collapsed strip, then hover to open it temporarily. Explicit expansion keeps it open. Expanded window dimensions are preserved.");
            ui.end_row();
            let label = ui.label("Collapse anchor");
            egui::ComboBox::from_id_salt("collapse-anchor")
                .selected_text(match s.window_collapse.anchor {
                    settings::CollapseAnchor::Start => "Top / left",
                    settings::CollapseAnchor::End => "Bottom / right",
                })
                .show_ui(ui, |ui| {
                    ui.selectable_value(
                        &mut s.window_collapse.anchor,
                        settings::CollapseAnchor::Start,
                        "Top / left",
                    );
                    ui.selectable_value(
                        &mut s.window_collapse.anchor,
                        settings::CollapseAnchor::End,
                        "Bottom / right",
                    );
                })
                .response
                .labelled_by(label.id)
                .on_hover_text("Keep this edge fixed where the desktop exposes window coordinates. Wayland compositors control placement.");
            ui.end_row();
            let label = ui.label("Remember window size");
            let mut remember = s.window_size.is_some();
            if ui
                .checkbox(&mut remember, "")
                .labelled_by(label.id)
                .changed()
            {
                let size = super::window_size(s);
                s.window_size = remember.then_some(settings::WindowSize {
                    width: size.x.round() as u32,
                    height: size.y.round() as u32,
                });
            }
            ui.end_row();
            if let Some(size) = &mut s.window_size {
                let label = ui.label("Window width");
                ui.add(
                    egui::DragValue::new(&mut size.width)
                        .range(100..=8192)
                        .suffix(" px"),
                )
                .labelled_by(label.id);
                ui.end_row();
                let label = ui.label("Window height");
                ui.add(
                    egui::DragValue::new(&mut size.height)
                        .range(100..=8192)
                        .suffix(" px"),
                )
                .labelled_by(label.id);
                ui.end_row();
            }
            let label = ui.label("Network minimum scale");
            ui.add(
                egui::DragValue::new(&mut s.network_min_scale)
                    .range(0..=settings::network_scale::MAX)
                    .suffix(" B/s"),
            )
            .labelled_by(label.id);
            ui.end_row();
        });
    ui.label("A zero network floor uses automatic scaling. Rates and history are unchanged.");
    ui.label("Opacity requires a compositing desktop. Placement and always-on-top remain desktop dependent.");
    ui.separator();
    ui.heading("Current-value bars");
    ui.checkbox(
        &mut s.activity_bars.visible,
        "Show current-value / CPU core bars",
    );
    style_picker(ui, "bar-style", &mut s.activity_bars.style);
    ui.checkbox(
        &mut s.activity_bars.use_series_colors,
        "Use graph series colors",
    );
    ui.horizontal(|ui| {
        rgba(ui, &mut s.activity_bars.color);
        ui.label("Bar color");
    });
}
fn graphs(ui: &mut egui::Ui, s: &mut Settings) {
    ui.label("Graph order, visibility, style, height and colors. Overrides inherit the selected theme when unchecked.");
    let mut movement = None;
    let count = s.modules.len();
    for (i, m) in s.modules.iter_mut().enumerate() {
        ui.push_id(m.id.index(), |ui| {
            ui.horizontal(|ui| {
                ui.checkbox(&mut m.visible, m.id.title());
                if ui.add_enabled(i > 0, egui::Button::new("↑")).clicked() {
                    movement = Some((i, i - 1));
                }
                if ui
                    .add_enabled(i + 1 < count, egui::Button::new("↓"))
                    .clicked()
                {
                    movement = Some((i, i + 1));
                }
            });
            ui.indent("appearance", |ui| {
                if m.id == settings::Module::Battery {
                    ui.horizontal(|ui| {
                        let label = ui.label("Battery history");
                        egui::ComboBox::from_id_salt("battery-mode")
                            .selected_text(match s.metrics.battery_mode {
                                xrg_ng_linux::battery::Mode::Charge => "Charge (%)",
                                xrg_ng_linux::battery::Mode::Power => {
                                    "Charging/discharging power (W)"
                                }
                            })
                            .show_ui(ui, |ui| {
                                ui.selectable_value(
                                    &mut s.metrics.battery_mode,
                                    xrg_ng_linux::battery::Mode::Charge,
                                    "Charge (%)",
                                );
                                ui.selectable_value(
                                    &mut s.metrics.battery_mode,
                                    xrg_ng_linux::battery::Mode::Power,
                                    "Charging/discharging power (W)",
                                );
                            })
                            .response
                            .labelled_by(label.id);
                    });
                }
                style_picker(ui, "style", &mut m.style);
                ui.horizontal(|ui| {
                    let mut custom = m.height.is_some();
                    if ui.checkbox(&mut custom, "Custom height").changed() {
                        m.height = custom.then_some(s.graph_height);
                    }
                    if let Some(height) = &mut m.height {
                        ui.add(egui::DragValue::new(height).range(64..=240).suffix(" px"));
                    }
                });
                ui.collapsing("Colors", |ui| {
                    for (i, label) in ["Background", "Series 1", "Series 2", "Series 3"]
                        .into_iter()
                        .enumerate()
                    {
                        let mut value = m.colors.components()[i];
                        ui.horizontal(|ui| {
                            let mut custom = value.is_some();
                            if ui.checkbox(&mut custom, label).changed() {
                                value = custom.then_some([0.2, 0.6, 1., 1.]);
                            }
                            if let Some(rgba_value) = &mut value {
                                rgba(ui, rgba_value);
                            }
                        });
                        let _ = m.colors.set(i, value);
                    }
                });
            });
            ui.separator();
        });
    }
    if let Some((a, b)) = movement {
        s.modules.swap(a, b);
    }
}
fn source(
    ui: &mut egui::Ui,
    id: &str,
    label: &str,
    value: &mut Option<String>,
    options: &[SourceOption],
    default: &str,
) {
    ui.horizontal(|ui| {
        let label = ui.label(label);
        let selected = value
            .as_ref()
            .map(|id| {
                options
                    .iter()
                    .find(|o| o.id == *id)
                    .map(|o| o.label.clone())
                    .unwrap_or_else(|| format!("Unavailable: {id}"))
            })
            .unwrap_or_else(|| default.into());
        let current = selected.clone();
        let selector = egui::ComboBox::from_id_salt(id)
            .selected_text(selected)
            .width(360.)
            .show_ui(ui, |ui| {
                ui.selectable_value(value, None, default);
                for option in options {
                    ui.selectable_value(value, Some(option.id.clone()), &option.label);
                }
            })
            .response
            .labelled_by(label.id);
        ui.ctx()
            .accesskit_node_builder(selector.id, |node| node.set_value(current));
    });
}
fn sources(ui: &mut egui::Ui, s: &mut Settings, inventory: &Inventory) {
    ui.heading("Metric sources");
    let options = inventory
        .cpus
        .iter()
        .map(|id| SourceOption {
            id: id.to_string(),
            label: format!("CPU {id}"),
        })
        .collect::<Vec<_>>();
    let mut cpu = s.metrics.cpu.map(|v| v.to_string());
    source(ui, "cpu", "CPU", &mut cpu, &options, "All logical CPUs");
    s.metrics.cpu = cpu.and_then(|s| s.parse().ok());
    ui.horizontal(|ui| {
        let label = ui.label("CPU time window (minutes; 0 uses samples)");
        ui.add(
            egui::DragValue::new(&mut s.metrics.cpu_history_minutes)
                .range(0..=xrg_ng_linux::shared::timed_projection_settings()[0]),
        )
        .labelled_by(label.id);
    });
    ui.small("Time windows end at the latest completed normal CPU observation. Bins follow the sampling target; unobserved intervals stay gaps. Current readings and rate baselines are independent. Changing source starts a fresh time history.");
    ui.add_enabled_ui(s.metrics.cpu_history_minutes == 0, |ui| {
        ui.horizontal(|ui| {
            let label = ui.label("Retained CPU samples");
            ui.add(
                egui::DragValue::new(&mut s.metrics.cpu_history_samples)
                    .range(0..=xrg_ng_linux::shared::sampling_settings()[3]),
            )
            .labelled_by(label.id);
        });
    });
    let capacity = if s.metrics.cpu_history_samples == 0 {
        120
    } else {
        s.metrics.cpu_history_samples
    };
    if s.metrics.cpu_history_minutes == 0 {
        ui.small(format!("0 keeps the 120-sample default. Capacity: {capacity} samples, nominal span {:.3} s at the current target. Delays and cadence changes affect the actual span. Resizing preserves newest observations and collector baselines.", f64::from(capacity.saturating_sub(1)) * f64::from(s.sampling_interval_ms) / 1000.));
    }
    for (module, title) in [
        (settings::Module::Memory, "Memory"),
        (settings::Module::Network, "Network"),
        (settings::Module::Disk, "Disk"),
        (settings::Module::Gpu, "GPU"),
        (settings::Module::Tpu, "NPU"),
        (settings::Module::GpuMemory, "VRAM"),
        (settings::Module::Temperature, "Temperature"),
        (settings::Module::Fans, "Fans"),
        (settings::Module::Battery, "Battery"),
    ] {
        let mut minutes = s.metrics.retained_minutes(module);
        if matches!(
            module,
            settings::Module::Memory
                | settings::Module::Network
                | settings::Module::Disk
                | settings::Module::Gpu
        ) {
            ui.horizontal(|ui| {
                let label = ui.label(format!("{title} time window (minutes; 0 uses samples)"));
                ui.add(
                    egui::DragValue::new(&mut minutes)
                        .range(0..=xrg_ng_linux::shared::timed_projection_settings()[0]),
                )
                .labelled_by(label.id);
            });
            if minutes == 0 {
                s.metrics.history_minutes.remove(&module);
            } else {
                s.metrics.history_minutes.insert(module, minutes);
            }
        }
        let mut count = s.metrics.retained_samples(module);
        ui.add_enabled_ui(minutes == 0, |ui| {
            ui.horizontal(|ui| {
                let label = ui.label(format!("Retained {title} samples"));
                ui.add(
                    egui::DragValue::new(&mut count)
                        .range(0..=xrg_ng_linux::shared::sampling_settings()[3]),
                )
                .labelled_by(label.id);
            });
        });
        if count == 0 {
            s.metrics.history_samples.remove(&module);
        } else {
            s.metrics.history_samples.insert(module, count);
        }
    }
    ui.small("GPU windows retain each device’s activity quantity independently. Device, driver and activity-source boundaries keep their existing resets; unavailable activity stays unavailable.");
    ui.small("Memory windows retain independent RAM/cache/swap percentages; RAM and swap capacity changes begin fresh histories for their respective curves. Paging intervals remain independent.");
    ui.small("Network/Disk windows end at the latest completed normal observation; bins follow the sampling target. Unobserved time bins remain gaps. Source/replacement/counter-restart boundaries begin fresh time histories. Transfer totals and rate baselines are independent.");
    ui.small("System histories: 0 keeps 120 samples. Capacity changes preserve newest observations and collector baselines; source/failure resets keep their existing behavior. Sensor statistics stay independent. Battery charge and signed power retain separate axes. Collector cadence and delays affect the actual time span.");
    for (label, value, options) in [
        ("Network", &mut s.metrics.network, &inventory.networks),
        ("Disk", &mut s.metrics.disk, &inventory.disks),
    ] {
        let options = options
            .iter()
            .map(|id| SourceOption {
                id: id.clone(),
                label: id.clone(),
            })
            .collect::<Vec<_>>();
        source(ui, label, label, value, &options, "Aggregate");
    }
    source(
        ui,
        "gpu",
        "GPU / VRAM",
        &mut s.metrics.gpu,
        &inventory.gpus,
        "Automatic GPU",
    );
    ui.separator();
    ui.strong("Intel Xe PMU power policy");
    ui.checkbox(
        &mut s.metrics.xe_pmu,
        "Enable Intel Xe PMU activity for all Xe adapters",
    );
    ui.label("Opt-in engine counters can keep GPUs awake and increase power use. Disabled uses readable client counters. Applying a change wakes the sampler; disabling closes PMU sessions at its next control boundary.");
    ui.separator();
    source(
        ui,
        "temperature",
        "Temperature",
        &mut s.metrics.temperature,
        &inventory.temperatures,
        "Automatic temperature",
    );
    for i in 0..2 {
        source(
            ui,
            &format!("temperature-{i}"),
            &format!("Temperature curve {}", i + 2),
            &mut s.metrics.temperature_extra[i],
            &inventory.temperatures,
            "Hidden",
        );
    }
    source(
        ui,
        "fan",
        "Fan",
        &mut s.metrics.fan,
        &inventory.fans,
        "Automatic fan",
    );
    for i in 0..2 {
        source(
            ui,
            &format!("fan-{i}"),
            &format!("Fan curve {}", i + 2),
            &mut s.metrics.fan_extra[i],
            &inventory.fans,
            "Hidden",
        );
    }
    ui.label("Missing saved sources stay selected and unavailable. Choose a primary sensor before adding distinct extra curves.");
}
fn ai(ui: &mut egui::Ui, s: &mut Settings) {
    ui.heading("AI monitoring");
    ui.horizontal(|ui| {
        let label = ui.label("AI time window (minutes; 0 uses samples)");
        ui.add(
            egui::DragValue::new(&mut s.ai.history_minutes)
                .range(0..=xrg_ng_linux::shared::timed_history_settings()[0]),
        )
        .labelled_by(label.id);
    });
    ui.small("Time windows end at the latest completed observation. Latest value per five-second bin; unobserved time bins stay gaps. Paused collection freezes the window. Changing the window does not collect again or change counters.");
    ui.add_enabled_ui(s.ai.history_minutes == 0, |ui| {
        ui.horizontal(|ui| {
            let label = ui.label("Retained AI samples");
            ui.add(
                egui::DragValue::new(&mut s.ai.history_samples)
                    .range(0..=xrg_ng_linux::shared::sampling_settings()[3]),
            )
            .labelled_by(label.id);
        });
    });
    let capacity = s.ai.history_capacity();
    let span =
        (capacity - 1) as f64 * xrg_ng_linux::shared::ai_sampling_milliseconds() as f64 / 1000.;
    if s.ai.history_minutes == 0 {
        ui.small(format!("0 keeps 120 samples. Capacity: {capacity}; nominal span {span:.0} seconds at 5 s cadence. Delays affect actual time coverage. Resizing preserves newest samples, rate baselines and session/daily counters. Changing retention does not add a collection or delay the next sample."));
    }
    ui.checkbox(
        &mut s.ai.accounting.enabled,
        "Track observed session/daily usage",
    );
    ui.checkbox(
        &mut s.ai.accounting.auto_reset,
        "Reset daily counters at local midnight",
    );
    ui.horizontal(|ui| {
        let label = ui.label("Daily token budget (0 disables)");
        ui.add(egui::DragValue::new(&mut s.ai.accounting.daily_budget).range(0..=u64::MAX))
            .labelled_by(label.id);
    });
    ui.horizontal(|ui| {
        let label = ui.label("Budget alert threshold (%)");
        ui.add(egui::DragValue::new(&mut s.ai.accounting.notify_percent).range(1..=100))
            .labelled_by(label.id);
    });
    ui.checkbox(
        &mut s.ai.accounting.notifications,
        "Send desktop budget alerts",
    );
    ui.checkbox(
        &mut s.ai.accounting.by_model,
        "Aggregate daily usage by model",
    );
    ui.checkbox(
        &mut s.ai.accounting.by_provider,
        "Aggregate daily usage by provider",
    );
    ui.label("Counters exclude initial history; gaps/edits can undercount. Collection continues while the graph is hidden. Desktop alerts require a notification service and follow desktop settings.");
    ui.separator();
    for (i, name) in ["Claude", "Codex", "Gemini", "Hermes"]
        .into_iter()
        .enumerate()
    {
        ui.checkbox(&mut s.ai.enabled[i], name);
    }
    ui.checkbox(&mut s.ai.ollama, "Read local Ollama model inventory");
    ui.checkbox(&mut s.ai_show_model_breakdown, "Show model breakdown");
    egui::ComboBox::from_label("Claude source")
        .selected_text(format!("{:?}", s.ai.claude_source))
        .show_ui(ui, |ui| {
            use xrg_ng_linux::ai::ClaudeSource::*;
            for (value, label) in [
                (Auto, "Automatic"),
                (Logs, "Logs"),
                (Database, "Database"),
                (Metrics, "Local metrics"),
            ] {
                ui.selectable_value(&mut s.ai.claude_source, value, label);
            }
        });
    for (label, value) in [
        ("Claude logs", &mut s.ai.claude_logs),
        ("Claude database", &mut s.ai.claude_database),
        ("Codex logs", &mut s.ai.codex_logs),
        ("Gemini logs", &mut s.ai.gemini_logs),
        ("Hermes database", &mut s.ai.hermes_database),
    ] {
        ui.horizontal(|ui| {
            ui.label(label);
            let mut text = value
                .as_ref()
                .map(|p| p.display().to_string())
                .unwrap_or_default();
            if ui.text_edit_singleline(&mut text).changed() {
                *value = if text.is_empty() {
                    None
                } else {
                    Some(PathBuf::from(text))
                };
            }
        });
    }
    ui.label("Leave paths empty for defaults. Local endpoints must use loopback HTTP.");
    ui.horizontal(|ui| {
        ui.label("Metrics URL");
        ui.text_edit_singleline(&mut s.ai.metrics_url);
    });
    ui.horizontal(|ui| {
        ui.label("Ollama URL");
        ui.text_edit_singleline(&mut s.ai.ollama_url);
    });
}
fn weather(ui: &mut egui::Ui, s: &mut Settings) {
    ui.heading("Weather observations");
    ui.checkbox(
        &mut s.weather.enabled,
        "Enable station weather (network access)",
    );
    ui.horizontal(|ui| {
        ui.label("ICAO station");
        ui.text_edit_singleline(&mut s.weather.station);
    });
    ui.horizontal(|ui| {
        ui.label("Default unit system");
        ui.selectable_value(
            &mut s.weather.units,
            xrg_ng_linux::weather::Units::Metric,
            "Metric",
        );
        ui.selectable_value(&mut s.weather.units, xrg_ng_linux::weather::Units::Us, "US");
    });
    for (id, label, value, metric, us) in [
        (
            "weather-temperature",
            "Temperature",
            &mut s.weather.temperature_units,
            "°C",
            "°F",
        ),
        (
            "weather-distance",
            "Visibility",
            &mut s.weather.distance_units,
            "Kilometers",
            "Miles",
        ),
        (
            "weather-pressure",
            "Pressure",
            &mut s.weather.pressure_units,
            "hPa",
            "inHg",
        ),
    ] {
        ui.horizontal(|ui| {
            let label = ui.label(label);
            egui::ComboBox::from_id_salt(id)
                .selected_text(match value {
                    None => "Default",
                    Some(xrg_ng_linux::weather::Units::Metric) => metric,
                    Some(xrg_ng_linux::weather::Units::Us) => us,
                })
                .show_ui(ui, |ui| {
                    ui.selectable_value(value, None, "Default");
                    ui.selectable_value(value, Some(xrg_ng_linux::weather::Units::Metric), metric);
                    ui.selectable_value(value, Some(xrg_ng_linux::weather::Units::Us), us);
                })
                .response
                .labelled_by(label.id);
        });
    }
    ui.horizontal(|ui| {
        use xrg_ng_linux::weather::WindUnits::*;
        let label = ui.label("Wind / gusts");
        egui::ComboBox::from_id_salt("weather-wind")
            .selected_text(match s.weather.wind_units {
                None => "From visibility units",
                Some(Knots) => "Knots",
                Some(Kmh) => "km/h",
                Some(Mph) => "mph",
            })
            .show_ui(ui, |ui| {
                for (value, label) in [
                    (None, "From visibility units"),
                    (Some(Knots), "Knots"),
                    (Some(Kmh), "km/h"),
                    (Some(Mph), "mph"),
                ] {
                    ui.selectable_value(&mut s.weather.wind_units, value, label);
                }
            })
            .response
            .labelled_by(label.id);
    });
    ui.horizontal(|ui| {
        let label = ui.label("History window");
        egui::ComboBox::from_id_salt("weather-history")
            .selected_text(
                s.weather
                    .history_hours
                    .map_or("Session (legacy)".into(), |h| format!("Last {h} hours")),
            )
            .show_ui(ui, |ui| {
                ui.selectable_value(&mut s.weather.history_hours, None, "Session (legacy)");
                for hours in [6, 12, 24] {
                    ui.selectable_value(
                        &mut s.weather.history_hours,
                        Some(hours),
                        format!("Last {hours} hours"),
                    );
                }
            })
            .response
            .labelled_by(label.id);
    });
    ui.horizontal(|ui| {
        use xrg_ng_linux::weather::Secondary::*;
        let label = ui.label("Secondary curve");
        egui::ComboBox::from_id_salt("weather-secondary")
            .selected_text(format!("{:?}", s.weather.secondary))
            .show_ui(ui, |ui| {
                for (value, name) in [
                    (None, "None"),
                    (Wind, "Wind"),
                    (Humidity, "Humidity"),
                    (Visibility, "Visibility (exact reports)"),
                    (Dewpoint, "Dewpoint"),
                    (Pressure, "Pressure"),
                ] {
                    ui.selectable_value(&mut s.weather.secondary, value, name);
                }
            })
            .response
            .labelled_by(label.id);
    });
    ui.label("Time windows use received observations at their actual timestamps; gaps are not filled. Secondary curves have their own vertical scale.");
    ui.horizontal(|ui| {
        ui.label("Refresh");
        ui.add(
            egui::DragValue::new(&mut s.weather.refresh_minutes)
                .range(5..=60)
                .suffix(" min"),
        );
    });
    ui.label("The Weather graph is independently enabled in Graphs. Missing and stale observations remain explicit.");
}
fn rgba(ui: &mut egui::Ui, value: &mut [f64; 4]) {
    let mut rgba = value.map(|v| v as f32);
    if ui.color_edit_button_rgba_unmultiplied(&mut rgba).changed() {
        *value = rgba.map(f64::from);
    }
}
fn style_picker(ui: &mut egui::Ui, id: &str, style: &mut GraphStyle) {
    egui::ComboBox::from_id_salt(id)
        .selected_text(style.name())
        .show_ui(ui, |ui| {
            for value in GraphStyle::ALL {
                ui.selectable_value(style, value, value.name());
            }
        });
}
fn theme_picker(ui: &mut egui::Ui, choice: &mut ThemeChoice) {
    let label = match choice {
        ThemeChoice::Builtin { name } => name.clone(),
        ThemeChoice::Custom { theme } => format!("Custom · {}", theme.name),
    };
    egui::ComboBox::from_id_salt("theme")
        .selected_text(label)
        .show_ui(ui, |ui| {
            for theme in xrg_ng_linux::shared::themes() {
                ui.selectable_value(
                    choice,
                    ThemeChoice::Builtin {
                        name: theme.name.clone(),
                    },
                    theme.name,
                );
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn restoring_presentation_defaults_keeps_provider_and_weather_sources_private() {
        let mut settings = Settings {
            graph_width: 300,
            window_opacity: 0.4,
            ..Default::default()
        };
        settings.ai.enabled = [false; 4];
        settings.ai.ollama = false;
        settings.ai.metrics_url = "http://127.0.0.1:18889/metrics".into();
        settings.ai.claude_logs = Some(PathBuf::from("/private-provider-logs"));
        settings.weather.enabled = true;
        settings.weather.station = "KJFK".into();
        settings.weather.refresh_minutes = 10;
        let expected_ai = settings.ai.clone();
        let expected_weather = settings.weather.clone();
        let mut editor = Editor::new(settings);
        editor.restore_defaults();
        assert_eq!(editor.draft.ai, expected_ai);
        assert_eq!(editor.draft.weather, expected_weather);
        assert_eq!(editor.draft.graph_width, Settings::default().graph_width);
        assert_eq!(editor.draft.window_opacity, 1.);
        assert!(editor.draft.validate().is_ok());
    }
    #[test]
    fn accessible_source_selector_preserves_the_current_unavailable_selection() {
        let ctx = egui::Context::default();
        ctx.enable_accesskit();
        let mut selected = Some("missing-gpu".into());
        let mut output = ctx.run_ui(egui::RawInput::default(), |ui| {
            source(ui, "gpu-test", "GPU", &mut selected, &[], "Automatic")
        });
        let tree = output.platform_output.accesskit_update.as_ref().unwrap();
        let (_, node) = tree
            .nodes
            .iter()
            .find(|(_, node)| node.role() == egui::accesskit::Role::ComboBox)
            .unwrap();
        assert_eq!(node.value(), Some("Unavailable: missing-gpu"));
        assert!(!node.labelled_by().is_empty());
        assert_eq!(selected.as_deref(), Some("missing-gpu"));
        output.textures_delta.clear();
    }
    #[test]
    fn general_controls_have_associated_accessible_labels() {
        let ctx = egui::Context::default();
        ctx.enable_accesskit();
        let mut settings = Settings {
            window_size: Some(settings::WindowSize {
                width: 300,
                height: 660,
            }),
            ..Default::default()
        };
        let mut output = ctx.run_ui(egui::RawInput::default(), |ui| general(ui, &mut settings));
        let tree = output.platform_output.accesskit_update.as_ref().unwrap();
        for name in [
            "Graph width",
            "Default graph height",
            "System sampling target",
            "Window opacity",
            "Remember window size",
            "Window width",
            "Window height",
            "Network minimum scale",
        ] {
            fn text(tree: &egui::accesskit::TreeUpdate, id: egui::accesskit::NodeId) -> String {
                let Some((_, node)) = tree.nodes.iter().find(|(node_id, _)| *node_id == id) else {
                    return String::new();
                };
                let mut value = node
                    .label()
                    .or_else(|| node.value())
                    .unwrap_or_default()
                    .to_owned();
                for child in node.children() {
                    value.push_str(&text(tree, *child));
                }
                value
            }
            assert!(
                tree.nodes.iter().any(|(_, node)| node
                    .labelled_by()
                    .iter()
                    .any(|id| text(tree, *id).contains(name))),
                "No control labelled by {name}"
            );
        }
        output.textures_delta.clear();
    }
    #[test]
    fn rendering_all_tabs_keeps_the_entire_draft_unchanged() {
        let mut settings = Settings {
            graph_width: 237,
            ..Default::default()
        };
        settings.metrics.cpu = Some(791);
        settings.metrics.gpu = Some("missing-saved-gpu".into());
        settings.network_min_scale = settings::network_scale::MAX;
        settings.modules[0].colors.background = Some([0.123456, 0.654321, 0.314159, 0.765432]);
        let mut editor = Editor::new(settings.clone());
        let ctx = egui::Context::default();
        for tab in 0..6 {
            editor.tab = tab;
            let mut output = ctx.run_ui(
                egui::RawInput {
                    screen_rect: Some(egui::Rect::from_min_size(
                        egui::Pos2::ZERO,
                        egui::vec2(680., 720.),
                    )),
                    ..Default::default()
                },
                |ui| editor.content(ui, &Inventory::default()),
            );
            output.textures_delta.clear();
            assert!(!ctx.tessellate(output.shapes, 1.).is_empty());
            assert_eq!(
                editor.draft, settings,
                "Merely displaying tab {tab} changed settings"
            );
        }
    }
}
