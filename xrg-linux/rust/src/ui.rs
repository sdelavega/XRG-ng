// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Native egui shell. Workers publish copied data; painting never collects it.
mod compositor;
mod dashboard;
mod inspectors;
mod preferences;
mod smoke;
use eframe::egui::{self, Color32, ViewportCommand, ViewportId, vec2};
use std::{
    collections::BTreeSet,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use xrg_ng_linux::{
    engine::{Panel, Snapshot, Worker},
    settings::{self, Layout, Module, Settings, Store, Writer},
    shared::Theme,
};

struct App {
    settings: Settings,
    theme: Theme,
    hostname: String,
    snapshot: Option<Snapshot>,
    worker: Worker,
    writer: Writer,
    notifier: Notifier,
    compositor: Arc<std::sync::Mutex<compositor::Compositor>>,
    revision: u64,
    saved_revision: u64,
    error: Option<String>,
    preferences: Option<preferences::Editor>,
    details: BTreeSet<Module>,
    processes: inspectors::Processes,
    show_processes: bool,
    show_ai: bool,
    show_weather: bool,
    show_about: bool,
    smoke: Option<smoke::Harness>,
}
/// Wake egui only for a new worker publication/save result. No continuous render loop.
struct Notifier {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Notifier {
    fn start(ctx: egui::Context, worker: &Worker, writer: &Writer) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let done = stop.clone();
        let latest = worker.latest.clone();
        let saved = writer.latest.clone();
        let thread = std::thread::spawn(move || {
            let mut seen = (0, 0);
            while !done.load(Ordering::Relaxed) {
                let sample = latest.lock().unwrap().as_ref().map(|s| s.sequence);
                let revision = saved.lock().unwrap().as_ref().map(|s| s.0);
                let next = (sample.unwrap_or(seen.0), revision.unwrap_or(seen.1));
                if next != seen {
                    seen = next;
                    ctx.request_repaint();
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        });
        Self {
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for Notifier {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
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
        if resize {
            ctx.send_viewport_cmd_to(
                ViewportId::ROOT,
                ViewportCommand::InnerSize(window_size(&self.settings)),
            );
        }
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
            .filter(|s| snapshot_matches(s, &self.settings, module))
            .and_then(|s| s.panels.get(module.index()))
    }
    fn preferences(&mut self) {
        if self.preferences.is_none() {
            self.preferences = Some(preferences::Editor::new(self.settings.clone()));
        }
    }
    fn capture_size(&mut self, ctx: &egui::Context) {
        if self.settings.window_size.is_none() {
            return;
        }
        let size = ctx.input(|i| {
            let v = i.viewport();
            if v.maximized == Some(true) || v.fullscreen == Some(true) {
                return None;
            }
            v.inner_rect.map(|r| settings::WindowSize {
                width: r.width().round() as u32,
                height: r.height().round() as u32,
            })
        });
        if let Some(size) = size.filter(|s| s.validate().is_ok())
            && self.settings.window_size != Some(size)
        {
            self.settings.window_size = Some(size);
            self.persist();
        }
    }
    fn toolbar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            let reserve = 22.;
            let hostname = &self.hostname;
            let heading = ui.add_sized(
                [(ui.available_width() - reserve).max(20.), 18.],
                egui::Label::new(
                    egui::RichText::new(hostname)
                        .size(11.)
                        .color(dashboard::color(self.theme.colors[6])),
                )
                .truncate()
                .sense(egui::Sense::click_and_drag()),
            );
            if heading.drag_started() {
                ui.ctx().send_viewport_cmd(ViewportCommand::StartDrag);
            }
            ui.menu_button("…", |ui| {
                if ui.button("Preferences…").clicked() {
                    self.capture_size(ui.ctx());
                    self.preferences();
                    ui.close();
                }
                ui.menu_button("Theme", |ui| {
                    for theme in xrg_ng_linux::shared::themes() {
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
        });
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
                if response.double_clicked() {
                    app.details.insert(module);
                }
                let mut popup = egui::Popup::context_menu(&response);
                if response.has_focus()
                    && ui.input(|i| i.modifiers.shift && i.key_pressed(egui::Key::F10))
                {
                    egui::Popup::open_id(ui.ctx(), popup.get_id());
                    popup = popup.at_position(response.rect.left_bottom());
                }
                popup.show(|ui| {
                    if ui.button("Live details…").clicked() {
                        app.details.insert(module);
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
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        if let Some(snapshot) = self.worker.latest.lock().unwrap().take() {
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
        if ctx.input(|i| i.viewport().close_requested()) {
            self.capture_size(&ctx);
        }
        if ctx.input_mut(|i| i.consume_key(egui::Modifiers::CTRL, egui::Key::Comma)) {
            self.capture_size(&ctx);
            self.preferences();
        }

        egui::Frame::new()
            .fill(dashboard::opaque(self.theme.colors[0]))
            .inner_margin(4)
            .show(ui, |ui| {
                ui.spacing_mut().item_spacing = vec2(2., 2.);
                self.toolbar(ui);
                self.strip(ui);
                if let Some(error) = &self.error {
                    ui.colored_label(Color32::LIGHT_RED, error);
                }
            });
        compositor::Compositor::enqueue(&self.compositor, ui, self.settings.window_opacity);
        if let Some(error) = self.compositor.lock().unwrap().error.as_ref() {
            self.error = Some(format!("Window opacity unavailable: {error}"));
        }
        resize_edges(ui);
        preferences::show(self, &ctx);
        inspectors::show(self, &ctx);
        if let Some(mut smoke) = self.smoke.take() {
            smoke.tick(self, &ctx);
            self.smoke = Some(smoke);
        }
    }
    fn clear_color(&self, _: &egui::Visuals) -> [f32; 4] {
        [0.; 4]
    }
    fn on_exit(&mut self, gl: Option<&eframe::glow::Context>) {
        if let Some(gl) = gl {
            self.compositor.lock().unwrap().destroy(gl);
        }
        self.notifier.stop.store(true, Ordering::Relaxed);
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
            let worker = Worker::start_with_settings(!smoke_mode, &settings);
            let writer = Writer::start(store);
            let notifier = Notifier::start(cc.egui_ctx.clone(), &worker, &writer);
            let smoke = harness.map(|mut h| {
                h.success = result;
                h
            });
            Ok(Box::new(App {
                settings,
                theme,
                hostname: hostname(),
                snapshot: None,
                worker,
                writer,
                notifier,
                compositor: Arc::new(std::sync::Mutex::new(compositor::Compositor::default())),
                revision: 0,
                saved_revision: 0,
                error,
                preferences: None,
                details: BTreeSet::new(),
                processes: inspectors::Processes::default(),
                show_processes: false,
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

fn resize_edges(ui: &mut egui::Ui) {
    use egui::{CursorIcon as C, Rect, ResizeDirection as D, pos2};
    let r = ui.max_rect();
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
            .interact(rect, ui.scope_id().with(("resize", i)), egui::Sense::drag())
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
