// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
mod ai;
mod graph_colors;
mod graph_heights;
mod legacy_import;
mod menus;
mod preferences;
mod processes;
mod smoke;
mod targets;
mod weather;
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
    path::{Path, PathBuf},
    rc::Rc,
    time::{Duration, Instant},
};
use xrg_ng_linux::{
    engine::{Panel, SelectionControl, Snapshot, Worker},
    metrics::Inventory,
    settings::{
        self, GraphStyle, Layout, Module, ProcessView, Settings, Store, ThemeChoice, Writer,
    },
    shared::{self, Theme},
};

struct Shell {
    window: gtk::ApplicationWindow,
    paintable: gtk::WidgetPaintable,
    graphs: gtk::Box,
    scroll: gtk::ScrolledWindow,
    areas: Vec<gtk::DrawingArea>,
    draws: Vec<Rc<Cell<u32>>>,
    empty: gtk::Label,
    status: gtk::Label,
    chooser: gtk::DropDown,
    theme_names: gtk::StringList,
    updating: Cell<bool>,
    css: gtk::CssProvider,
    theme: Rc<RefCell<Theme>>,
    settings: Rc<RefCell<Settings>>,
    state: Rc<RefCell<Option<Snapshot>>>,
    selection: crate::ui::SelectionControl,
    processes: RefCell<Option<Rc<processes::Window>>>,
    ai_window: RefCell<Option<Rc<ai::Window>>>,
    ai_control: xrg_ng_linux::ai::Control,
    weather_window: RefCell<Option<Rc<weather::Window>>>,
    weather_control: xrg_ng_linux::weather::Control,
    details: RefCell<BTreeMap<Module, Rc<menus::Details>>>,
    writer: Writer,
    revision: Cell<u64>,
    saved_revision: Cell<u64>,
    dialog: RefCell<Option<Rc<preferences::Dialog>>>,
}
impl Shell {
    fn build(
        application: &gtk::Application,
        settings: Settings,
        store: Store,
        error: Option<String>,
        smoke: bool,
        state: Rc<RefCell<Option<Snapshot>>>,
        controls: (
            SelectionControl,
            xrg_ng_linux::ai::Control,
            xrg_ng_linux::weather::Control,
        ),
    ) -> Rc<Self> {
        let (selection, ai_control, weather_control) = controls;
        let settings = Rc::new(RefCell::new(settings));
        let theme = Rc::new(RefCell::new(
            settings
                .borrow()
                .theme
                .palette()
                .expect("Validated settings"),
        ));
        let content = gtk::Box::new(gtk::Orientation::Vertical, 4);
        content.add_css_class("xrg-shell");
        let css = gtk::CssProvider::new();
        apply_shell_theme(&css, &theme.borrow());
        gtk::style_context_add_provider_for_display(
            &gtk::gdk::Display::default().expect("GTK display"),
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        let toolbar = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        toolbar.set_margin_start(10);
        toolbar.set_margin_end(10);
        toolbar.set_margin_top(8);
        toolbar.set_margin_bottom(4);
        let heading = gtk::Label::new(Some("XRG-ng"));
        heading.set_hexpand(true);
        heading.set_halign(gtk::Align::Start);
        toolbar.append(&heading);
        let names: Vec<_> = shared::themes()
            .iter()
            .map(|t| t.name.clone())
            .chain(std::iter::once("Custom…".into()))
            .collect();
        let chooser =
            gtk::DropDown::from_strings(&names.iter().map(String::as_str).collect::<Vec<_>>());
        let theme_names = chooser
            .model()
            .unwrap()
            .downcast::<gtk::StringList>()
            .unwrap();
        limit_dropdown(&chooser);
        chooser.set_tooltip_text(Some("Theme"));
        chooser.update_property(&[gtk::accessible::Property::Label("Theme")]);
        toolbar.append(&chooser);
        let process_button = gtk::Button::with_label("Processes…");
        toolbar.append(&process_button);
        let ai_button = gtk::Button::with_label("AI…");
        ai_button.set_tooltip_text(Some("AI usage, model inventories and sources"));
        toolbar.append(&ai_button);
        let weather_button = gtk::Button::from_icon_name("weather-clear-symbolic");
        weather_button.set_tooltip_text(Some("Weather · station observations"));
        weather_button.update_property(&[gtk::accessible::Property::Label("Weather")]);
        toolbar.append(&weather_button);
        let prefs = gtk::Button::from_icon_name("preferences-system-symbolic");
        prefs.set_tooltip_text(Some("Preferences · graphs and themes"));
        prefs.update_property(&[gtk::accessible::Property::Label("Preferences")]);
        toolbar.append(&prefs);
        content.append(&toolbar);
        let graphs = gtk::Box::new(gtk::Orientation::Vertical, 4);
        let empty = gtk::Label::new(Some(
            "All graphs are hidden. Open Preferences to show a graph.",
        ));
        empty.set_wrap(true);
        empty.set_margin_top(24);
        empty.set_margin_start(16);
        empty.set_margin_end(16);
        content.append(&empty);
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .vexpand(true)
            .child(&graphs)
            .build();
        content.append(&scroll);
        let mut areas = Vec::new();
        let mut draws = Vec::new();
        for module in Module::ALL {
            let area = gtk::DrawingArea::new();
            area.set_content_width(360);
            area.set_hexpand(true);
            area.add_css_class("xrg-graph");
            area.update_property(&[gtk::accessible::Property::Label(module.title())]);
            let state = state.clone();
            let theme = theme.clone();
            let settings = settings.clone();
            let count = Rc::new(Cell::new(0u32));
            let draw_count = count.clone();
            area.set_draw_func(move |_, context, width, height| {
                draw_count.set(draw_count.get() + 1);
                let state = state.borrow();
                let active = settings.borrow();
                let appearance = active.modules.iter().find(|m| m.id == module).unwrap();
                let palette = appearance.colors.palette(&theme.borrow());
                draw(
                    context,
                    (width, height),
                    &palette,
                    module.title(),
                    state
                        .as_ref()
                        .filter(|s| snapshot_matches(s, &active, module))
                        .and_then(|s| s.panels.get(module.index())),
                    active.temperature_units,
                    (appearance.style, &active.activity_bars),
                );
            });
            graphs.append(&area);
            areas.push(area);
            draws.push(count);
        }
        let status = gtk::Label::new(Some("Sampling on a worker · 1 second interval"));
        status.set_wrap(true);
        status.set_margin_bottom(6);
        status.set_margin_start(10);
        status.set_margin_end(10);
        content.append(&status);
        let window = gtk::ApplicationWindow::builder()
            .application(application)
            .title("XRG-ng")
            .default_width(680)
            .default_height(if smoke { 1400 } else { 850 })
            .child(&content)
            .build();
        let paintable = gtk::WidgetPaintable::new(Some(&content));
        let shell = Rc::new(Self {
            window,
            paintable,
            graphs,
            scroll,
            areas,
            draws,
            empty,
            status,
            chooser,
            theme_names,
            updating: Cell::new(false),
            css,
            theme,
            settings,
            state: state.clone(),
            selection,
            processes: RefCell::new(None),
            ai_window: RefCell::new(None),
            ai_control,
            weather_window: RefCell::new(None),
            weather_control,
            details: RefCell::new(BTreeMap::new()),
            writer: Writer::start(store),
            revision: Cell::new(0),
            saved_revision: Cell::new(0),
            dialog: RefCell::new(None),
        });
        toolbar.append(&menus::install(&shell));
        shell.refresh();
        let weak = Rc::downgrade(&shell);
        shell.chooser.connect_selected_notify(move |chooser| {
            let Some(shell) = weak.upgrade() else {
                return;
            };
            if shell.updating.get() {
                return;
            }
            if chooser.selected() == 6 {
                if matches!(shell.settings.borrow().theme, ThemeChoice::Builtin { .. }) {
                    shell.refresh();
                    shell.preferences();
                }
                return;
            }
            if let Some(theme) = shared::themes().get(chooser.selected() as usize) {
                let choice = ThemeChoice::Builtin {
                    name: theme.name.clone(),
                };
                if shell.settings.borrow().theme == choice {
                    return;
                }
                let mut settings = shell.settings.borrow().clone();
                settings.theme = choice;
                shell.apply(settings);
            }
        });
        let weak = Rc::downgrade(&shell);
        prefs.connect_clicked(move |_| {
            if let Some(shell) = weak.upgrade() {
                shell.preferences();
            }
        });
        let weak = Rc::downgrade(&shell);
        process_button.connect_clicked(move |_| {
            if let Some(shell) = weak.upgrade() {
                shell.processes();
            }
        });
        let weak = Rc::downgrade(&shell);
        ai_button.connect_clicked(move |_| {
            if let Some(shell) = weak.upgrade() {
                shell.ai();
            }
        });
        let weak = Rc::downgrade(&shell);
        weather_button.connect_clicked(move |_| {
            if let Some(shell) = weak.upgrade() {
                shell.weather();
            }
        });
        if let Some(error) = error {
            shell.persistence_error(&error);
        }
        shell.window.present();
        shell
    }
    fn refresh(&self) {
        let settings = self.settings.borrow();
        let horizontal = settings.layout == Layout::Horizontal;
        self.graphs.set_orientation(if horizontal {
            gtk::Orientation::Horizontal
        } else {
            gtk::Orientation::Vertical
        });
        self.graphs.set_valign(gtk::Align::Start);
        self.scroll.set_policy(
            if horizontal {
                gtk::PolicyType::Automatic
            } else {
                gtk::PolicyType::Never
            },
            gtk::PolicyType::Automatic,
        );
        let mut previous = None::<gtk::DrawingArea>;
        for module in &settings.modules {
            let area = &self.areas[module.id.index()];
            area.set_visible(module.visible);
            area.set_content_height(module.effective_height(settings.graph_height) as i32);
            area.set_valign(gtk::Align::Start);
            area.set_vexpand(false);
            self.graphs.reorder_child_after(area, previous.as_ref());
            previous = Some(area.clone());
        }
        self.empty
            .set_visible(!settings.modules.iter().any(|m| m.visible));
        self.updating.set(true);
        let (selected, custom_name) = match &settings.theme {
            ThemeChoice::Builtin { name } => (
                shared::themes()
                    .iter()
                    .position(|t| t.name == *name)
                    .unwrap_or(1),
                "Custom…".to_owned(),
            ),
            ThemeChoice::Custom { theme } => (6, format!("Custom · {}", theme.name)),
        };
        if self.theme_names.string(6).as_deref() != Some(custom_name.as_str()) {
            self.theme_names.splice(6, 1, &[&custom_name]);
        }
        self.chooser.set_selected(selected as u32);
        self.updating.set(false);
        apply_shell_theme(&self.css, &self.theme.borrow());
        for area in &self.areas {
            area.queue_draw();
        }
        self.update_panel_text();
    }
    fn update_panel_text(&self) {
        let state = self.state.borrow();
        let settings = self.settings.borrow();
        for module in Module::ALL {
            let area = &self.areas[module.index()];
            let Some(panel) = state
                .as_ref()
                .filter(|s| snapshot_matches(s, &settings, module))
                .and_then(|s| s.panels.get(module.index()))
            else {
                area.set_tooltip_text(Some("Waiting for selected source…"));
                area.update_property(&[
                    gtk::accessible::Property::Label(module.title()),
                    gtk::accessible::Property::Description("Waiting for selected source…"),
                ]);
                continue;
            };
            let label = panel.display_label(settings.temperature_units);
            let mut detail = panel
                .display_detail(settings.temperature_units)
                .into_owned();
            if settings.activity_bars.visible {
                detail.push_str("\n\n");
                detail.push_str(&panel.activity_description(settings.temperature_units));
            }
            area.set_tooltip_text(Some(&detail));
            area.update_property(&[
                gtk::accessible::Property::Label(&format!("{}: {}", panel.title, label)),
                gtk::accessible::Property::Description(&detail),
            ]);
        }
    }
    fn apply(&self, settings: Settings) {
        let palette = match settings.validate().and_then(|_| settings.theme.palette()) {
            Ok(palette) => palette,
            Err(error) => {
                self.persistence_error(&error);
                return;
            }
        };
        let old = self.settings.borrow().clone();
        if old.metrics != settings.metrics {
            self.selection
                .set(settings.metrics.clone())
                .expect("Validated selection");
        }
        let process_change = old.processes != settings.processes;
        if old.ai != settings.ai {
            self.ai_control
                .set(settings.ai.clone())
                .expect("Validated AI preferences");
        }
        *self.theme.borrow_mut() = palette;
        if old.weather != settings.weather {
            self.weather_control
                .set(settings.weather.clone())
                .expect("Validated weather preferences");
        }
        *self.settings.borrow_mut() = settings.clone();
        if process_change && let Some(window) = self.processes.borrow().as_ref() {
            window.set_view(settings.processes.clone());
        }
        self.refresh();
        self.update_details();
        self.persist(settings);
    }
    fn persist(&self, settings: Settings) {
        let revision = self.revision.get() + 1;
        self.revision.set(revision);
        self.writer.queue(revision, settings);
        self.status.set_text("Saving preferences…");
        self.status.set_tooltip_text(None);
    }
    fn save_process_view(&self, view: ProcessView) {
        if self.settings.borrow().processes == view {
            return;
        }
        self.settings.borrow_mut().processes = view;
        let settings = self.settings.borrow().clone();
        self.persist(settings);
    }
    fn inventory(&self) -> Inventory {
        self.state
            .borrow()
            .as_ref()
            .map(|s| s.inventory.clone())
            .unwrap_or_default()
    }
    fn details(self: &Rc<Self>, module: Module) -> Rc<menus::Details> {
        if let Some(view) = self.details.borrow().get(&module) {
            view.window.present();
            return view.clone();
        }
        let view = menus::Details::new(self, module);
        view.update(self.state.borrow().as_ref(), &self.settings.borrow());
        self.details.borrow_mut().insert(module, view.clone());
        view.window.present();
        view
    }
    fn update_details(&self) {
        for view in self.details.borrow().values() {
            view.update(self.state.borrow().as_ref(), &self.settings.borrow());
        }
    }
    fn ai(self: &Rc<Self>) -> Rc<ai::Window> {
        if let Some(window) = self.ai_window.borrow().as_ref() {
            window.window.present();
            return window.clone();
        }
        let window = ai::Window::new(self);
        window.update(
            self.state.borrow().as_ref().and_then(|s| s.ai.as_ref()),
            &self.settings.borrow().ai,
        );
        *self.ai_window.borrow_mut() = Some(window.clone());
        window.window.present();
        window
    }
    fn weather(self: &Rc<Self>) -> Rc<weather::Window> {
        if let Some(window) = self.weather_window.borrow().as_ref() {
            window.window.present();
            return window.clone();
        }
        let window = weather::Window::new(self);
        window.update(
            self.state
                .borrow()
                .as_ref()
                .and_then(|s| s.weather.as_ref()),
            &self.settings.borrow().weather,
        );
        *self.weather_window.borrow_mut() = Some(window.clone());
        window.window.present();
        window
    }
    fn processes(self: &Rc<Self>) -> Rc<processes::Window> {
        if let Some(window) = self.processes.borrow().as_ref() {
            window.window.present();
            return window.clone();
        }
        let window = processes::Window::new(self);
        if let Some(snapshot) = self.state.borrow().as_ref() {
            window.update(&snapshot.processes);
        }
        *self.processes.borrow_mut() = Some(window.clone());
        window.window.present();
        window
    }
    fn persistence_error(&self, error: &str) {
        self.status
            .set_text("Changes apply for this session; preferences could not be saved.");
        self.status.set_tooltip_text(Some(error));
        eprintln!("Preferences: {error}");
    }
    fn preferences(self: &Rc<Self>) -> Rc<preferences::Dialog> {
        if let Some(dialog) = self.dialog.borrow().as_ref() {
            dialog.window.present();
            return dialog.clone();
        }
        let dialog = preferences::Dialog::new(self);
        *self.dialog.borrow_mut() = Some(dialog.clone());
        dialog.window.present();
        dialog
    }
    fn poll_save(&self) {
        if let Some((revision, result)) = self.writer.latest.lock().unwrap().take() {
            match result {
                Ok(()) => {
                    self.saved_revision.set(revision);
                    if revision == self.revision.get() {
                        self.status
                            .set_text("Preferences saved · 1 second sampling interval");
                        self.status.set_tooltip_text(None);
                    }
                }
                Err(error) if revision == self.revision.get() => self.persistence_error(&error),
                Err(_) => (),
            }
        }
    }
    fn snapshot(&self, path: &Path) -> Result<(), String> {
        save_snapshot(&self.window, &self.paintable, path)
    }
}

pub fn run(smoke_mode: bool) -> bool {
    let application = gtk::Application::builder()
        .application_id("com.sdelavega.xrg-ng")
        .build();
    let success = Rc::new(Cell::new(!smoke_mode));
    let result = success.clone();
    let worker = Rc::new(RefCell::new(None::<Worker>));
    let owner = worker.clone();
    let shell = Rc::new(RefCell::new(None::<Rc<Shell>>));
    let shell_owner = shell.clone();
    application.connect_activate(move |application| {
        if let Some(shell) = shell_owner.borrow().as_ref() {
            shell.window.present();
            return;
        }
        let smoke = smoke_mode.then(smoke::Harness::new).transpose();
        let mut smoke = match smoke {
            Ok(value) => value,
            Err(error) => {
                eprintln!("Smoke setup failed: {error}");
                application.quit();
                return;
            }
        };
        let path = if let Some(harness) = &smoke {
            Some(harness.preferences_path())
        } else {
            settings::preferences_path()
        };
        let (store, settings, error) = Store::open(path);
        let monitor = Worker::start_with_sources(
            !smoke_mode,
            settings.metrics.clone(),
            settings.ai.clone(),
            settings.weather.clone(),
        );
        let selection = monitor.selection_control();
        let ai_control = monitor.ai_control();
        let weather_control = monitor.weather_control();
        let latest = monitor.latest.clone();
        *owner.borrow_mut() = Some(monitor);
        let state = Rc::new(RefCell::new(None::<Snapshot>));
        let view = Shell::build(
            application,
            settings,
            store,
            error,
            smoke_mode,
            state.clone(),
            (selection, ai_control, weather_control),
        );
        *shell_owner.borrow_mut() = Some(view.clone());
        let weak = Rc::downgrade(&view);
        let app = application.downgrade();
        let started = Instant::now();
        let passed = result.clone();
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let (Some(app), Some(shell)) = (app.upgrade(), weak.upgrade()) else {
                return glib::ControlFlow::Break;
            };
            if let Some(snapshot) = latest.lock().unwrap().take() {
                if let Some(window) = shell.processes.borrow().as_ref() {
                    window.update(&snapshot.processes);
                }
                if let (Some(window), Some(update)) =
                    (shell.ai_window.borrow().as_ref(), snapshot.ai.as_ref())
                {
                    window.update(Some(update), &shell.settings.borrow().ai);
                }
                *state.borrow_mut() = Some(snapshot);
                shell.update_panel_text();
                shell.update_details();
                if let (Some(window), Some(update)) = (
                    shell.weather_window.borrow().as_ref(),
                    state.borrow().as_ref().and_then(|s| s.weather.as_ref()),
                ) {
                    window.update(Some(update), &shell.settings.borrow().weather);
                }
                for area in &shell.areas {
                    area.queue_draw();
                }
            }
            shell.poll_save();
            if let Some(harness) = &mut smoke {
                let sequence = state.borrow().as_ref().map_or(0, |s| s.sequence);
                match harness.tick(&shell, sequence) {
                    Ok(true)
                        if state.borrow().as_ref().is_some_and(|s| s.valid)
                            && shell.draws.iter().all(|d| d.get() >= 3) =>
                    {
                        if let Some(path) = std::env::var_os("XRG_SMOKE_IMAGE")
                            && let Err(error) = shell.snapshot(&PathBuf::from(path))
                        {
                            eprintln!("GTK screenshot failed: {error}");
                            app.quit();
                            return glib::ControlFlow::Break;
                        }
                        println!(
                            "GTK_SMOKE_OK samples={sequence} draws={} preferences=roundtrip",
                            shell.draws.iter().map(|d| d.get()).sum::<u32>()
                        );
                        passed.set(true);
                        app.quit();
                        return glib::ControlFlow::Break;
                    }
                    Err(error) => {
                        eprintln!("GTK preferences smoke failed: {error}");
                        app.quit();
                        return glib::ControlFlow::Break;
                    }
                    _ => (),
                }
                if started.elapsed() > Duration::from_secs(20) {
                    eprintln!("GTK smoke timed out at sample {sequence}");
                    app.quit();
                    return glib::ControlFlow::Break;
                }
            }
            glib::ControlFlow::Continue
        });
    });
    let exit = application.run_with_args(&["xrg-ng-linux"]);
    shell.borrow_mut().take();
    worker.borrow_mut().take();
    success.get() && exit == glib::ExitCode::SUCCESS
}
fn snapshot_matches(snapshot: &Snapshot, settings: &Settings, module: Module) -> bool {
    snapshot.selection.matches(&settings.metrics, module)
        && (module != Module::Ai
            || snapshot
                .ai
                .as_ref()
                .is_some_and(|ai| ai.preferences == settings.ai))
}
pub(super) fn limit_dropdown(dropdown: &gtk::DropDown) {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, object| {
        let item = object.downcast_ref::<gtk::ListItem>().unwrap();
        let label = gtk::Label::new(None);
        label.set_max_width_chars(26);
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        item.set_child(Some(&label));
    });
    factory.connect_bind(|_, object| {
        let item = object.downcast_ref::<gtk::ListItem>().unwrap();
        if let (Some(text), Some(label)) = (
            item.item().and_downcast::<gtk::StringObject>(),
            item.child().and_downcast::<gtk::Label>(),
        ) {
            label.set_text(&text.string());
            label.set_tooltip_text(Some(&text.string()));
        }
    });
    dropdown.set_factory(Some(&factory));
}
fn color(context: &gtk::cairo::Context, color: [f64; 4]) {
    context.set_source_rgba(color[0], color[1], color[2], color[3]);
}
fn draw(
    context: &gtk::cairo::Context,
    (width, height): (i32, i32),
    theme: &Theme,
    title: &str,
    panel: Option<&Panel>,
    units: xrg_ng_linux::temperature::Units,
    (style, bars): (GraphStyle, &settings::ActivityBars),
) {
    // Compose translucent Classic colors over an opaque base; repainting never
    // accumulates alpha from previous frames.
    context.set_source_rgb(theme.colors[0][0], theme.colors[0][1], theme.colors[0][2]);
    let _ = context.paint();
    color(context, theme.colors[1]);
    context.rectangle(0., 0., width as f64, height as f64);
    let _ = context.fill();
    color(context, theme.colors[5]);
    context.set_line_width(1.);
    context.rectangle(
        0.5,
        0.5,
        (width as f64 - 1.).max(0.),
        (height as f64 - 1.).max(0.),
    );
    let _ = context.stroke();
    color(context, theme.colors[6]);
    context.select_font_face(
        "monospace",
        gtk::cairo::FontSlant::Normal,
        gtk::cairo::FontWeight::Normal,
    );
    context.set_font_size(13.);
    context.move_to(10., 20.);
    let _ = context.show_text(title);
    context.move_to(10., 39.);
    context.set_font_size(12.);
    let bar_count = panel
        .filter(|_| bars.visible)
        .map_or(0, |p| p.series.len().min(3));
    let bar_width = bar_count as f64 * 10.;
    let _ = context.save();
    context.rectangle(
        8.,
        24.,
        (width as f64
            - 26.
            - if bar_count > 0 {
                bar_width.max(18.)
            } else {
                0.
            })
        .max(0.),
        20.,
    );
    context.clip();
    context.move_to(10., 39.);
    let _ = context.show_text(
        panel
            .map(|p| p.display_label(units))
            .unwrap_or_else(|| "Waiting for sample…".into())
            .as_ref(),
    );
    let _ = context.restore();
    if bar_count > 0 {
        context.set_font_size(9.);
        context.move_to(width as f64 - 9. - bar_width.max(18.), 39.);
        let _ = context.show_text("now");
    }
    let Some(panel) = panel else {
        return;
    };
    let (minimum, maximum) = panel.scale.bounds(&panel.series);
    let bottom = height as f64 - 6.;
    let top = 49.;
    if bottom <= top || width <= 20 {
        return;
    }
    let _ = xrg_ng_linux::graph::draw(
        context,
        &panel.series,
        &theme.colors[2..5],
        xrg_ng_linux::graph::Plot {
            left: 8.,
            top,
            right: width as f64 - 8. - if bar_count > 0 { bar_width + 8. } else { 0. },
            bottom,
            lower: minimum,
            upper: maximum,
        },
        style,
    );
    let _ = xrg_ng_linux::graph::draw_bars(
        context,
        &panel.series,
        xrg_ng_linux::graph::Plot {
            left: width as f64 - 8. - bar_width,
            right: width as f64 - 8.,
            top,
            bottom,
            lower: minimum,
            upper: maximum,
        },
        bars,
        theme.colors[5],
    );
}

fn save_snapshot(
    window: &(impl IsA<gtk::Widget> + IsA<gtk::Native>),
    paintable: &gtk::WidgetPaintable,
    path: &Path,
) -> Result<(), String> {
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(&snapshot, window.width() as f64, window.height() as f64);
    let node = snapshot.to_node().ok_or("No rendered node")?;
    let renderer = window.renderer().ok_or("No renderer")?;
    renderer
        .render_texture(&node, None)
        .save_to_png(path)
        .map_err(|e| e.to_string())
}

fn apply_shell_theme(provider: &gtk::CssProvider, theme: &Theme) {
    let background = theme.colors[0];
    let text = theme.colors[6];
    provider.load_from_data(&format!(
        ".xrg-shell {{ background-color: rgb({:.0}, {:.0}, {:.0}); color: rgb({:.0}, {:.0}, {:.0}); }} .xrg-graph:focus-visible {{ outline: 2px solid currentColor; outline-offset: -2px; }}",
        background[0] * 255., background[1] * 255., background[2] * 255.,
        text[0] * 255., text[1] * 255., text[2] * 255.));
}
