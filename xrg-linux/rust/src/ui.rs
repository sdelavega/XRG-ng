// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Native egui shell. Workers publish copied data; painting never collects it.
mod collapse;
#[cfg(target_os = "linux")]
#[path = "ui/compositor.rs"]
pub mod compositor;
#[cfg(not(target_os = "linux"))]
#[path = "ui/compositor_stub.rs"]
pub mod compositor;
mod dashboard;
mod diagnostics;
mod file_picker;
mod file_picker_smoke;
mod inspectors;
mod preferences;
mod smoke;
use crate::{
    engine::{Panel, Snapshot, Worker},
    settings::{self, Layout, Module, Settings, Store, Writer},
    shared::Theme,
};
use eframe::egui::{self, Color32, ViewportCommand, ViewportId, vec2};
use std::{
    collections::BTreeSet,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

struct App {
    settings: Settings,
    collapse: collapse::State,
    theme: Theme,
    hostname: String,
    snapshot: Option<Snapshot>,
    worker: Worker,
    writer: Writer,
    diagnostics: diagnostics::Diagnostics,
    compositor: Arc<std::sync::Mutex<compositor::Compositor>>,
    revision: u64,
    saved_revision: u64,
    error: Option<String>,
    preferences: Option<preferences::Editor>,
    details: BTreeSet<Module>,
    processes: inspectors::Processes,
    show_processes: bool,
    show_sensors: bool,
    show_ai: bool,
    show_weather: bool,
    show_about: bool,
    smoke: Option<smoke::Harness>,
}
impl App {
    fn apply(&mut self, settings: Settings, ctx: &egui::Context) -> Result<(), String> {
        settings.validate()?;
        let theme = settings.theme.palette()?;
        if self.settings.metrics != settings.metrics {
            self.worker
                .selection_control()
                .set(settings.metrics.clone())?;
        }
        if self.settings.sampling_interval_ms != settings.sampling_interval_ms {
            self.worker
                .sampling_control()
                .set(settings.sampling_interval_ms)?;
        }
        if self.settings.ai != settings.ai {
            self.worker.ai_control().set(settings.ai.clone())?;
        }
        if self.settings.weather != settings.weather {
            self.worker
                .weather_control()
                .set(settings.weather.clone())?;
        }
        let resize = self.settings.layout != settings.layout
            || self.settings.graph_width != settings.graph_width
            || self.settings.graph_height != settings.graph_height
            || self.settings.window_size != settings.window_size
            || self
                .settings
                .modules
                .iter()
                .zip(&settings.modules)
                .any(|(a, b)| a.id != b.id || a.visible != b.visible || a.height != b.height);
        self.settings = settings;
        self.theme = theme;
        self.sync_collapse(ctx, resize);
        self.persist();
        ctx.request_repaint();
        Ok(())
    }
    fn persist(&mut self) {
        self.revision += 1;
        self.writer.queue(self.revision, self.settings.clone());
        self.error = None;
    }
    fn panel(&self, module: Module) -> Option<&Panel> {
        self.snapshot
            .as_ref()
            .filter(|s| {
                snapshot_matches(s, &self.settings, module)
                    && (module != Module::Ai
                        || s.ai.as_ref().is_none_or(|a| {
                            a.control_revision == self.worker.ai_control().revision()
                        }))
            })
            .and_then(|s| s.panels.get(module.index()))
    }
    fn preferences(&mut self) {
        if self.preferences.is_none() {
            self.preferences = Some(preferences::Editor::new(self.settings.clone()));
        }
    }
    fn capture_size(&mut self, ctx: &egui::Context) {
        if self.settings.window_size.is_none() || !self.collapse.can_capture() {
            return;
        }
        let zoom = ctx.zoom_factor();
        let size = ctx.input(|i| current_window_size(i, zoom));
        if let Some(size) = size.filter(|s| s.validate().is_ok())
            && self.settings.window_size != Some(size)
        {
            self.settings.window_size = Some(size);
            self.persist();
        }
    }
    fn sync_collapse(&mut self, ctx: &egui::Context, resize: bool) {
        let zoom = ctx.zoom_factor();
        let popup_open = egui::Popup::is_any_open(ctx);
        let input = ctx.input(|i| collapse::Input {
            native: i.viewport_rect().size() * zoom,
            outer: i
                .viewport()
                .outer_rect
                .map(|r| r.min)
                .or_else(|| i.viewport().inner_rect.map(|r| r.min)),
            zoom,
            time: i.time,
            inside: i
                .pointer
                .hover_pos()
                .is_some_and(|p| i.viewport_rect().contains(p)),
            blocked: i.pointer.any_down()
                || popup_open
                || self.preferences.is_some()
                || !self.details.is_empty()
                || self.show_processes
                || self.show_sensors
                || self.show_ai
                || self.show_weather
                || self.show_about,
            maximized: i.viewport().maximized == Some(true)
                || i.viewport().fullscreen == Some(true),
        });
        if let Some(geometry) = self.collapse.update(
            self.settings.window_collapse,
            self.settings.layout,
            input,
            viewport_window_size(&self.settings, zoom) * zoom,
            resize,
        ) {
            ctx.send_viewport_cmd(ViewportCommand::MinInnerSize(geometry.minimum));
            if let Some(size) = geometry.size {
                ctx.send_viewport_cmd(ViewportCommand::InnerSize(size));
            }
            ctx.send_viewport_cmd(ViewportCommand::Resizable(geometry.resizable));
            if let Some(position) = geometry.position {
                ctx.send_viewport_cmd(ViewportCommand::OuterPosition(position));
            }
            ctx.request_repaint();
        }
        if let Some(delay) = self.collapse.repaint_after(input.time) {
            ctx.request_repaint_after(delay);
        }
    }
    fn toggle_collapse(&mut self, ctx: &egui::Context) {
        if !self.settings.window_collapse.collapsed {
            if ctx.input(|i| {
                i.viewport().maximized == Some(true) || i.viewport().fullscreen == Some(true)
            }) {
                return;
            }
            self.capture_size(ctx);
        }
        let mut settings = self.settings.clone();
        settings.window_collapse.collapsed = !settings.window_collapse.collapsed;
        if let Err(error) = self.apply(settings, ctx) {
            self.error = Some(error);
        }
    }
    fn toolbar(&mut self, ui: &mut egui::Ui) {
        let side = self.collapse.closed() && self.settings.layout == Layout::Horizontal;
        let draw = |ui: &mut egui::Ui| {
            let reserve = 22.;
            let hostname = &self.hostname;
            let sense = egui::Sense::click_and_drag().difference(egui::Sense::FOCUSABLE);
            let heading = if side {
                let (rect, response) = ui.allocate_exact_size(
                    vec2(20., (ui.available_height() - reserve).max(20.)),
                    sense,
                );
                let color = dashboard::color(self.theme.colors[6]);
                let galley = ui.painter().layout_no_wrap(
                    hostname.clone(),
                    egui::FontId::proportional(11.),
                    color,
                );
                let pos = egui::pos2(
                    rect.center().x - galley.size().y / 2.,
                    rect.center().y + galley.size().x / 2.,
                );
                ui.painter().with_clip_rect(rect).add(
                    egui::epaint::TextShape::new(pos, galley, color)
                        .with_angle(-std::f32::consts::FRAC_PI_2),
                );
                response
            } else {
                ui.add_sized(
                    [(ui.available_width() - reserve).max(20.), 18.],
                    egui::Label::new(
                        egui::RichText::new(hostname)
                            .size(11.)
                            .color(dashboard::color(self.theme.colors[6])),
                    )
                    .truncate()
                    .sense(sense),
                )
            };
            heading.widget_info(|| egui::WidgetInfo::labeled(egui::Role::Label, true, hostname));
            let toggle = heading.double_clicked();
            if heading.drag_started() {
                ui.ctx().send_viewport_cmd(ViewportCommand::StartDrag);
            }
            if toggle {
                self.toggle_collapse(ui.ctx());
            }
            if self.collapse.closed() {
                let expand=ui.button("+").on_hover_text("Expand graphs (Ctrl+M). Ctrl+, opens Preferences. Double-click the title to expand.");
                expand.widget_info(|| {
                    egui::WidgetInfo::labeled(egui::Role::Button, true, "Expand graphs")
                });
                if expand.clicked() {
                    self.toggle_collapse(ui.ctx());
                }
                return;
            }
            let menu = ui.menu_button("…", |ui| {
                let label = if self.settings.window_collapse.collapsed {
                    "Keep graphs expanded (Ctrl+M)"
                } else {
                    "Collapse graphs (Ctrl+M)"
                };
                let allowed = self.settings.window_collapse.collapsed
                    || ui.input(|i| {
                        i.viewport().maximized != Some(true)
                            && i.viewport().fullscreen != Some(true)
                    });
                if ui.add_enabled(allowed, egui::Button::new(label)).clicked() {
                    self.toggle_collapse(ui.ctx());
                    ui.close();
                }
                if ui.button("Preferences…").clicked() {
                    self.capture_size(ui.ctx());
                    self.preferences();
                    ui.close();
                }
                ui.menu_button("Theme", |ui| {
                    for theme in crate::shared::themes() {
                        if ui.button(&theme.name).clicked() {
                            let mut settings = self.settings.clone();
                            settings.theme = settings::ThemeChoice::Builtin { name: theme.name };
                            if let Err(e) = self.apply(settings, ui.ctx()) {
                                self.error = Some(e);
                            }
                            ui.close();
                        }
                    }
                });
                ui.menu_button("Zoom", egui::gui_zoom::zoom_menu_buttons);
                if ui.button("Clear all graph histories").clicked() {
                    if let Err(e) = self.worker.graph_control().clear_all() {
                        self.error = Some(e);
                    }
                    ui.close();
                }
                if ui.button("Show all graphs").clicked() {
                    let mut settings = self.settings.clone();
                    settings.modules.iter_mut().for_each(|m| m.visible = true);
                    if let Err(e) = self.apply(settings, ui.ctx()) {
                        self.error = Some(e);
                    }
                    ui.close();
                }
                if ui.button("Processes…").clicked() {
                    self.show_processes = true;
                    ui.close();
                }
                if ui.button("Sensors and statistics…").clicked() {
                    self.show_sensors = true;
                    ui.close();
                }
                if ui.button("AI usage…").clicked() {
                    self.show_ai = true;
                    ui.close();
                }
                if ui.button("Weather…").clicked() {
                    self.show_weather = true;
                    ui.close();
                }
                if ui.button("About XRG-ng…").clicked() {
                    self.show_about = true;
                    ui.close();
                }
                ui.separator();
                if ui.button("Quit").clicked() {
                    self.capture_size(ui.ctx());
                    ui.ctx().send_viewport_cmd(ViewportCommand::Close);
                }
            });
            diagnostics::focus(&menu.response, "Application menu");
            menu.response.widget_info(|| {
                egui::WidgetInfo::labeled(egui::Role::Button, true, "Application menu")
            });
        };
        if side {
            ui.vertical_centered(draw);
        } else {
            ui.horizontal(draw);
        }
    }
    fn strip(&mut self, ui: &mut egui::Ui) {
        let settings = self.settings.clone();
        let draw = |ui: &mut egui::Ui, app: &mut Self| {
            for appearance in settings.modules.iter().filter(|m| m.visible) {
                let module = appearance.id;
                let palette = appearance.colors.palette(&app.theme);
                let panel = app.panel(module);
                let response = dashboard::show(
                    ui,
                    vec2(
                        settings.graph_width as f32,
                        appearance.effective_height(settings.graph_height) as f32,
                    ),
                    &palette,
                    module,
                    panel,
                    &settings,
                    appearance.style,
                );
                let detail = panel
                    .map(|p| {
                        format!(
                            "{}\n\n{}",
                            p.display_label(settings.temperature_units),
                            p.display_detail(settings.temperature_units)
                        )
                    })
                    .unwrap_or_else(|| "Waiting for selected source…".into());
                let response = response.on_hover_text(detail);
                if dashboard::details_requested(&response) {
                    app.details.insert(module);
                }
                let popup = dashboard::context_menu(&response, module);
                popup.show(|ui| {
                    if ui.button("Live details…").clicked() {
                        app.details.insert(module);
                        ui.close();
                    }
                    if matches!(module, Module::Temperature | Module::Fans)
                        && ui.button("Sensors and statistics…").clicked()
                    {
                        app.show_sensors = true;
                        ui.close();
                    }
                    if ui.button("Clear graph history").clicked() {
                        if let Err(e) = app.worker.graph_control().clear(module) {
                            app.error = Some(e);
                        }
                        ui.close();
                    }
                    if matches!(module, Module::Network | Module::Disk)
                        && ui.button("Reset session transfers").clicked()
                    {
                        if let Err(e) = app.worker.graph_control().reset_transfers(module) {
                            app.error = Some(e);
                        }
                        ui.close();
                    }
                    ui.menu_button("Graph style", |ui| {
                        for style in settings::GraphStyle::ALL {
                            if ui
                                .selectable_label(style == appearance.style, style.name())
                                .clicked()
                            {
                                let mut next = app.settings.clone();
                                next.modules
                                    .iter_mut()
                                    .find(|m| m.id == module)
                                    .unwrap()
                                    .style = style;
                                if let Err(e) = app.apply(next, ui.ctx()) {
                                    app.error = Some(e);
                                }
                                ui.close();
                            }
                        }
                    });
                    for (label, offset) in [("Move earlier", -1isize), ("Move later", 1)] {
                        let i = app
                            .settings
                            .modules
                            .iter()
                            .position(|m| m.id == module)
                            .unwrap();
                        let next_index = i
                            .checked_add_signed(offset)
                            .filter(|i| *i < app.settings.modules.len());
                        if ui
                            .add_enabled(next_index.is_some(), egui::Button::new(label))
                            .clicked()
                        {
                            let mut next = app.settings.clone();
                            next.modules.swap(i, next_index.unwrap());
                            if let Err(e) = app.apply(next, ui.ctx()) {
                                app.error = Some(e);
                            }
                            ui.close();
                        }
                    }
                    if ui.button("Hide graph").clicked() {
                        let mut next = app.settings.clone();
                        next.modules
                            .iter_mut()
                            .find(|m| m.id == module)
                            .unwrap()
                            .visible = false;
                        if let Err(e) = app.apply(next, ui.ctx()) {
                            app.error = Some(e);
                        }
                        ui.close();
                    }
                    if ui.button("Preferences…").clicked() {
                        app.preferences();
                        ui.close();
                    }
                });
                if let Some(smoke) = &mut app.smoke {
                    smoke.draws[module.index()] += 1;
                }
            }
            if !settings.modules.iter().any(|m| m.visible) {
                ui.label("All graphs are hidden. Open Preferences to show a graph.");
            }
        };
        egui::ScrollArea::both()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                if settings.layout == Layout::Horizontal {
                    ui.horizontal_top(|ui| draw(ui, self));
                } else {
                    draw(ui, self);
                }
            });
    }
}
impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        if let Some(snapshot) = self.worker.latest.lock().unwrap().take() {
            self.diagnostics.sample(snapshot.valid);
            self.snapshot = Some(snapshot);
        }
        let saved = self.writer.latest.lock().unwrap().take();
        if let Some((revision, result)) = saved {
            match result {
                Ok(()) => self.saved_revision = revision,
                Err(e) if revision == self.revision => {
                    self.error = Some(format!(
                        "Changes apply for this session; preferences could not be saved: {e}"
                    ))
                }
                Err(_) => (),
            }
        }
        if ctx.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, egui::Key::Q)) {
            self.capture_size(&ctx);
            ctx.send_viewport_cmd(ViewportCommand::Close);
        }
        if ctx.input(|i| i.viewport().close_requested()) {
            self.capture_size(&ctx);
        }
        if ctx.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, egui::Key::Comma)) {
            self.capture_size(&ctx);
            self.preferences();
        }

        if ctx.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, egui::Key::M)) {
            self.toggle_collapse(&ctx);
        }
        self.sync_collapse(&ctx, false);
        egui::Frame::new()
            .fill(dashboard::opaque(self.theme.colors[0]))
            .inner_margin(4)
            .show(ui, |ui| {
                ui.spacing_mut().item_spacing = vec2(2., 2.);
                self.toolbar(ui);
                if !self.collapse.closed() {
                    self.strip(ui);
                }
                if !self.collapse.closed()
                    && let Some(error) = &self.error
                {
                    ui.colored_label(Color32::LIGHT_RED, error);
                }
            });
        compositor::Compositor::enqueue(&self.compositor, ui, self.settings.window_opacity);
        if let Some(error) = self.compositor.lock().unwrap().error.as_ref() {
            self.error = Some(format!("Window opacity unavailable: {error}"));
        }
        if !self.settings.window_collapse.collapsed {
            resize_edges(ui);
        }
        preferences::show(self, &ctx);
        inspectors::show(self, &ctx);
        self.diagnostics.observe(
            frame,
            ui,
            self.settings.sampling_interval_ms,
            self.preferences.is_some(),
            self.details.len(),
            (
                self.collapse.closed(),
                self.settings.window_collapse.collapsed,
            ),
        );
        if let Some(mut smoke) = self.smoke.take() {
            smoke.tick(self, &ctx);
            self.smoke = Some(smoke);
        }
    }
    fn clear_color(&self, _: &egui::Visuals) -> [f32; 4] {
        [0.; 4]
    }
    fn on_exit(&mut self, gl: Option<&eframe::glow::Context>) {
        self.diagnostics.finish();
        if let Some(gl) = gl {
            self.compositor.lock().unwrap().destroy(gl);
        }
    }
}
fn snapshot_matches(snapshot: &Snapshot, settings: &Settings, module: Module) -> bool {
    snapshot.selection.matches(&settings.metrics, module)
        && (module != Module::Ai
            || snapshot
                .ai
                .as_ref()
                .is_some_and(|a| a.preferences == settings.ai))
        && (module != Module::Weather
            || snapshot
                .weather
                .as_ref()
                .is_some_and(|w| w.preferences == settings.weather))
}

fn current_window_size(i: &egui::InputState, zoom: f32) -> Option<settings::WindowSize> {
    let v = i.viewport();
    if v.maximized == Some(true) || v.fullscreen == Some(true) {
        return None;
    }
    // Wayland does not expose global window coordinates, so inner_rect
    // may be absent even though the local viewport dimensions are known.
    let r = v.inner_rect.unwrap_or_else(|| i.viewport_rect());
    Some(settings::WindowSize {
        width: (r.width() * zoom).round() as u32,
        height: (r.height() * zoom).round() as u32,
    })
}
// Saved dimensions use native logical units. Egui viewport commands use UI
// points, which are smaller when the user zooms with Ctrl+plus/minus.
fn viewport_window_size(settings: &Settings, zoom: f32) -> egui::Vec2 {
    let size = window_size(settings);
    if settings.window_size.is_some() {
        size / zoom
    } else {
        size
    }
}
fn window_size(settings: &Settings) -> egui::Vec2 {
    if let Some(s) = settings.window_size {
        return vec2(s.width as f32, s.height as f32);
    }
    let heights: Vec<_> = settings
        .modules
        .iter()
        .filter(|m| m.visible)
        .map(|m| m.effective_height(settings.graph_height) as f32)
        .collect();
    let gaps = heights.len().saturating_sub(1) as f32 * 2.;
    if settings.layout == Layout::Horizontal {
        vec2(
            (settings.graph_width as f32 * heights.len() as f32 + gaps + 8.).clamp(148., 1200.),
            heights.into_iter().fold(90., f32::max) + 30.,
        )
    } else {
        vec2(
            (settings.graph_width as f32 + 8.).max(148.),
            (heights.iter().sum::<f32>() + gaps + 30.).clamp(120., 1000.),
        )
    }
}
pub fn run(smoke_mode: bool) -> bool {
    let success = Arc::new(AtomicBool::new(!smoke_mode));
    let harness = match smoke_mode.then(smoke::Harness::new).transpose() {
        Ok(h) => h,
        Err(e) => {
            eprintln!("Smoke setup: {e}");
            return false;
        }
    };
    let path = harness
        .as_ref()
        .map(|h| h.path())
        .or_else(settings::preferences_path);
    let (store, mut settings, error) = Store::open(path);
    if smoke_mode {
        settings.ai.enabled = [false; 4];
        settings.ai.ollama = false;
        settings.weather.enabled = false;
    }
    if let Some(name) = std::env::var_os("XRG_SMOKE_STYLE").filter(|_| smoke_mode) {
        settings.theme = settings::ThemeChoice::Builtin {
            name: name.to_string_lossy().into_owned(),
        };
    }
    let theme = match settings.theme.palette() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Theme: {e}");
            return false;
        }
    };
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("XRG-ng")
            .with_app_id("com.sdelavega.xrg-ng")
            .with_decorations(false)
            .with_transparent(true)
            .with_inner_size(window_size(&settings))
            .with_min_inner_size([100., 100.])
            .with_icon(egui::IconData::default()),
        renderer: eframe::Renderer::Glow,
        persist_window: false,
        ..Default::default()
    };
    let result = success.clone();
    let run = eframe::run_native(
        "XRG-ng",
        options,
        Box::new(move |cc| {
            cc.egui_ctx.set_visuals(egui::Visuals::dark());
            diagnostics::configure(&cc.egui_ctx);
            let worker = Worker::start_with_settings(!smoke_mode, &settings);
            let writer = Writer::start(store);
            let ctx = cc.egui_ctx.clone();
            worker.on_publish(move || ctx.request_repaint_of(ViewportId::ROOT));
            let ctx = cc.egui_ctx.clone();
            writer.on_publish(move || ctx.request_repaint_of(ViewportId::ROOT));
            let smoke = harness.map(|mut h| {
                h.success = result;
                h
            });
            Ok(Box::new(App {
                settings,
                collapse: collapse::State::default(),
                theme,
                hostname: hostname(),
                snapshot: None,
                worker,
                writer,
                diagnostics: diagnostics::Diagnostics::new(cc),
                compositor: Arc::new(std::sync::Mutex::new(compositor::Compositor::default())),
                revision: 0,
                saved_revision: 0,
                error,
                preferences: None,
                details: BTreeSet::new(),
                processes: inspectors::Processes::default(),
                show_processes: false,
                show_sensors: false,
                show_ai: false,
                show_weather: false,
                show_about: false,
                smoke,
            }))
        }),
    );
    if let Err(e) = run {
        eprintln!("XRG-ng desktop: {e}");
        return false;
    }
    success.load(Ordering::Relaxed)
}

fn hostname() -> String {
    // POSIX gethostname; every unix target reads the real host name.
    #[cfg(unix)]
    {
        let mut bytes = [0u8; 256];
        // POSIX gethostname writes at most the supplied buffer, with no allocation.
        if unsafe { libc::gethostname(bytes.as_mut_ptr().cast(), bytes.len()) } == 0 {
            let length = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
            return String::from_utf8_lossy(&bytes[..length])
                .chars()
                .filter(|c| !c.is_control())
                .collect();
        }
        "XRG-ng".into()
    }
    #[cfg(not(unix))]
    {
        // No POSIX gethostname off Unix; use the same fallback the Unix
        // shell already uses when gethostname fails.
        "XRG-ng".into()
    }
}

fn resize_edges(ui: &mut egui::Ui) {
    use egui::{CursorIcon as C, Rect, ResizeDirection as D, pos2};
    // Content can exceed the viewport minimum width. Resize hit targets must
    // remain on the visible native edges, including an undecorated Wayland window.
    let r = ui.ctx().viewport_rect();
    let (l, t, b, x) = (r.left(), r.top(), r.bottom(), r.right());
    for (i, (rect, direction, cursor)) in [
        (
            Rect::from_min_max(pos2(l, t), pos2(l + 8., t + 8.)),
            D::NorthWest,
            C::ResizeNwSe,
        ),
        (
            Rect::from_min_max(pos2(x - 8., t), pos2(x, t + 8.)),
            D::NorthEast,
            C::ResizeNeSw,
        ),
        (
            Rect::from_min_max(pos2(l, b - 8.), pos2(l + 8., b)),
            D::SouthWest,
            C::ResizeNeSw,
        ),
        (
            Rect::from_min_max(pos2(x - 8., b - 8.), pos2(x, b)),
            D::SouthEast,
            C::ResizeNwSe,
        ),
        (
            Rect::from_min_max(pos2(l + 8., t), pos2(x - 8., t + 3.)),
            D::North,
            C::ResizeVertical,
        ),
        (
            Rect::from_min_max(pos2(l + 8., b - 3.), pos2(x - 8., b)),
            D::South,
            C::ResizeVertical,
        ),
        (
            Rect::from_min_max(pos2(l, t + 8.), pos2(l + 3., b - 8.)),
            D::West,
            C::ResizeHorizontal,
        ),
        (
            Rect::from_min_max(pos2(x - 3., t + 8.), pos2(x, b - 8.)),
            D::East,
            C::ResizeHorizontal,
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let response = ui
            .interact(
                rect,
                ui.scope_id().with(("resize", i)),
                egui::Sense::drag().difference(egui::Sense::FOCUSABLE),
            )
            .on_hover_cursor(cursor);
        if response.drag_started() {
            ui.ctx()
                .send_viewport_cmd(ViewportCommand::BeginResize(direction));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn old_source_and_missing_optional_reports_cannot_reappear() {
        let mut settings = Settings::default();
        let snapshot = Snapshot {
            sequence: 1,
            panels: Vec::new(),
            valid: true,
            selection: Default::default(),
            inventory: Default::default(),
            processes: Err("fixture".into()),
            sensors: Default::default(),
            graph_generations: [0; 13],
            transfers: Default::default(),
            ai: None,
            weather: None,
        };
        assert!(!snapshot_matches(&snapshot, &settings, Module::Ai));
        assert!(!snapshot_matches(&snapshot, &settings, Module::Weather));
        settings.metrics.cpu = Some(7);
        assert!(!snapshot_matches(&snapshot, &settings, Module::Cpu));
        assert!(snapshot_matches(&snapshot, &settings, Module::Memory));
        settings.metrics.xe_pmu = true;
        assert!(!snapshot_matches(&snapshot, &settings, Module::Gpu));
        assert!(snapshot_matches(&snapshot, &settings, Module::GpuMemory));
    }
    #[test]
    fn wayland_size_is_retained_without_global_coordinates_and_maximized_size_is_ignored() {
        for maximized in [false, true] {
            let ctx = egui::Context::default();
            let mut raw = egui::RawInput {
                screen_rect: Some(egui::Rect::from_min_size(
                    egui::Pos2::ZERO,
                    vec2(300., 660.),
                )),
                ..Default::default()
            };
            let viewport = raw.viewports.get_mut(&ViewportId::ROOT).unwrap();
            viewport.inner_rect = None; // Normal Wayland input: size but no global position.
            viewport.maximized = Some(maximized);
            let mut observed = None;
            let mut output = ctx.run_ui(raw, |ui| {
                observed = ui.input(|i| current_window_size(i, 1.))
            });
            output.textures_delta.clear();
            assert_eq!(
                observed,
                (!maximized).then_some(settings::WindowSize {
                    width: 300,
                    height: 660
                })
            );
        }
    }
    #[test]
    fn zoomed_windows_keep_native_logical_dimensions_across_saves_and_apply() {
        for native_scale in [1., 1.25, 1.5, 2.] {
            for zoom in [1., 1.25, 1.5, 2.] {
                let ctx = egui::Context::default();
                ctx.options_mut(|o| o.zoom_factor = zoom);
                let mut raw = egui::RawInput {
                    screen_rect: Some(egui::Rect::from_min_size(
                        egui::Pos2::ZERO,
                        vec2(300., 660.) / zoom,
                    )),
                    ..Default::default()
                };
                raw.viewports
                    .get_mut(&ViewportId::ROOT)
                    .unwrap()
                    .native_pixels_per_point = Some(native_scale);
                let mut size = None;
                let mut output =
                    ctx.run_ui(raw, |ui| size = ui.input(|i| current_window_size(i, zoom)));
                output.textures_delta.clear();
                assert_eq!(
                    size,
                    Some(settings::WindowSize {
                        width: 300,
                        height: 660
                    })
                );
                let settings = Settings {
                    window_size: size,
                    ..Default::default()
                };
                assert_eq!(
                    viewport_window_size(&settings, zoom) * zoom,
                    vec2(300., 660.)
                );
            }
        }
    }
    #[test]
    fn about_window_links_to_sponsors() {
        use super::inspectors::{SPONSORS_URL, about_content};
        assert_eq!(SPONSORS_URL, "https://github.com/sponsors/sdelavega");
        let ctx = egui::Context::default();
        ctx.enable_accesskit();
        let screen = egui::Rect::from_min_size(egui::Pos2::ZERO, vec2(480., 360.));
        let raw = egui::RawInput {
            screen_rect: Some(screen),
            ..Default::default()
        };
        // Frame 1: render the About content and locate the rendered link,
        // so the click below lands inside its own rect.
        let mut output = ctx.run_ui(raw.clone(), about_content);
        let tree = output.platform_output.accesskit_update.as_ref().unwrap();
        let sponsors_rect = tree
            .nodes
            .iter()
            .find_map(|(_, node)| {
                if node.role() == egui::accesskit::Role::Link
                    && node.label() == Some("Support XRG-ng…")
                {
                    node.bounds()
                } else {
                    None
                }
            })
            .expect("the About window must link to GitHub Sponsors");
        output.textures_delta.clear();
        let center = egui::pos2(
            ((sponsors_rect.x0 + sponsors_rect.x1) / 2.) as f32,
            ((sponsors_rect.y0 + sponsors_rect.y1) / 2.) as f32,
        );
        // Frame 2: press the rendered support link.
        let press = egui::RawInput {
            events: vec![
                egui::Event::PointerMoved(center),
                egui::Event::PointerButton {
                    pos: center,
                    button: egui::PointerButton::Primary,
                    pressed: true,
                    modifiers: egui::Modifiers::NONE,
                },
            ],
            ..raw.clone()
        };
        ctx.run_ui(press, about_content).textures_delta.clear();
        // Frame 3: release inside the link and inspect the emitted command.
        let release = egui::RawInput {
            events: vec![egui::Event::PointerButton {
                pos: center,
                button: egui::PointerButton::Primary,
                pressed: false,
                modifiers: egui::Modifiers::NONE,
            }],
            ..raw
        };
        let mut output = ctx.run_ui(release, about_content);
        let opened = output.platform_output.commands.iter().any(|command| {
            matches!(
                command,
                egui::OutputCommand::OpenUrl(egui::OpenUrl { url, .. })
                    if url == SPONSORS_URL
            )
        });
        assert!(
            opened,
            "clicking the support link must open {SPONSORS_URL}, got {:?}",
            output.platform_output.commands
        );
        output.textures_delta.clear();
    }
    #[test]
    fn automatic_and_saved_sizes_follow_the_same_graph_order() {
        let mut settings = Settings::default();
        settings.modules.iter_mut().for_each(|m| m.visible = false);
        settings.modules[0].visible = true;
        settings.modules[0].height = Some(120);
        assert_eq!(window_size(&settings), vec2(148., 150.));
        settings.layout = Layout::Horizontal;
        assert_eq!(window_size(&settings), vec2(148., 150.));
        settings.window_size = Some(settings::WindowSize {
            width: 640,
            height: 480,
        });
        assert_eq!(window_size(&settings), vec2(640., 480.));
    }
}
