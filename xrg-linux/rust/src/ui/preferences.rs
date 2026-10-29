// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Draft-only preferences. Apply validates before changing workers or storage.
use super::App;
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
    tab: usize,
    theme_path: String,
    legacy_path: String,
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
            theme_path: String::new(),
            legacy_path: xrg_ng_linux::legacy::path_from(
                std::env::var_os("XDG_CONFIG_HOME").as_deref(),
                std::env::var_os("HOME").as_deref(),
            )
            .map(|p| p.display().to_string())
            .unwrap_or_default(),
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
        self.import = None;
        self.message = None;
    }
    fn content(&mut self, ui: &mut egui::Ui, inventory: &Inventory) {
        self.poll();
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
                self.message = Some("File worker stopped before returning a result.".into());
            }
            _ => (),
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
        ui.text_edit_singleline(&mut self.theme_path);
        ui.checkbox(
            &mut self.replace_theme,
            "Allow replacing an existing theme file",
        );
        ui.horizontal(|ui| {
            if ui.add_enabled(self.pending.is_none(),egui::Button::new("Load into draft")).clicked() {
                let path=PathBuf::from(self.theme_path.trim());
                self.start(ui.ctx(),move||ThemeDocument::load(&path).map(|t|Loaded::Theme(Box::new(t))));
            }
            if ui.add_enabled(self.pending.is_none(),egui::Button::new("Save JSON theme…")).clicked() {
                let path=PathBuf::from(self.theme_path.trim());
                let replace=self.replace_theme;
                let document=self.draft.theme.palette().map(|p|ThemeDocument::new(&p));
                self.start(ui.ctx(),move||{
                    if let Some(preferences)=settings::preferences_path() && (path==preferences || path.canonicalize().ok().zip(preferences.canonicalize().ok()).is_some_and(|(a,b)|a==b)) {
                        return Err("Export a theme separately from application preferences.".into());
                    }
                    if !replace && path.try_exists().map_err(|e|e.to_string())? {return Err("Destination exists. Choose a new path or explicitly allow replacement.".into());}
                    document?.save(&path)?;Ok(Loaded::Saved)
                });
            }
        });
        ui.label("Save exports only the portable JSON palette. Paths can be pasted; no GTK file chooser is used. Reads/writes run on a file worker.");
        ui.separator();
        ui.heading("Import legacy Linux settings");
        ui.text_edit_singleline(&mut self.legacy_path);
        if ui
            .add_enabled(
                self.pending.is_none(),
                egui::Button::new("Review legacy settings…"),
            )
            .clicked()
        {
            let path = PathBuf::from(self.legacy_path.trim());
            let base = self.draft.clone();
            self.start(ui.ctx(), move || {
                xrg_ng_linux::legacy::load(&path, &base).map(|i| Loaded::Legacy(Box::new(i)))
            });
        }
        if let Some(import) = &self.import {
            ui.label(import.summary());
            let mut accept = false;
            let mut cancel = false;
            ui.horizontal(|ui| {
                accept = ui.button("Import into draft").clicked();
                cancel = ui.button("Cancel import").clicked();
            });
            if accept {
                self.draft = self.import.take().unwrap().settings;
                self.message = Some("Imported into draft. Review before Apply.".into());
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
            if ui.ctx().input(|i| i.viewport().close_requested()) {
                open = false;
            }
            egui::CentralPanel::default().show(ui, |ui| {
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
            ui.label("Graph width");
            ui.add(
                egui::DragValue::new(&mut s.graph_width)
                    .range(100..=1200)
                    .suffix(" px"),
            );
            ui.end_row();
            ui.label("Default graph height");
            ui.add(
                egui::DragValue::new(&mut s.graph_height)
                    .range(64..=240)
                    .suffix(" px"),
            );
            ui.end_row();
            ui.label("System sampling target");
            ui.add(
                egui::DragValue::new(&mut s.sampling_interval_ms)
                    .range(250..=10_000)
                    .speed(50.)
                    .suffix(" ms"),
            );
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
            ui.label("Window opacity");
            ui.add(egui::Slider::new(&mut s.window_opacity, 0.1..=1.).show_value(true));
            ui.end_row();
            ui.label("Remember window size");
            let mut remember = s.window_size.is_some();
            if ui.checkbox(&mut remember, "").changed() {
                let size = super::window_size(s);
                s.window_size = remember.then_some(settings::WindowSize {
                    width: size.x.round() as u32,
                    height: size.y.round() as u32,
                });
            }
            ui.end_row();
            if let Some(size) = &mut s.window_size {
                ui.label("Window width");
                ui.add(
                    egui::DragValue::new(&mut size.width)
                        .range(100..=8192)
                        .suffix(" px"),
                );
                ui.end_row();
                ui.label("Window height");
                ui.add(
                    egui::DragValue::new(&mut size.height)
                        .range(100..=8192)
                        .suffix(" px"),
                );
                ui.end_row();
            }
            ui.label("Network minimum scale");
            ui.add(
                egui::DragValue::new(&mut s.network_min_scale)
                    .range(0..=settings::network_scale::MAX)
                    .suffix(" B/s"),
            );
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
        ui.label(label);
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
        egui::ComboBox::from_id_salt(id)
            .selected_text(selected)
            .width(360.)
            .show_ui(ui, |ui| {
                ui.selectable_value(value, None, default);
                for option in options {
                    ui.selectable_value(value, Some(option.id.clone()), &option.label);
                }
            });
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
        ui.label("Units");
        ui.selectable_value(
            &mut s.weather.units,
            xrg_ng_linux::weather::Units::Metric,
            "Metric",
        );
        ui.selectable_value(&mut s.weather.units, xrg_ng_linux::weather::Units::Us, "US");
    });
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
