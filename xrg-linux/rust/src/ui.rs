// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use gtk::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    fs,
    path::PathBuf,
    rc::Rc,
    time::{Duration, Instant},
};
use xrg_ng_linux::{
    engine::{Panel, Snapshot, Worker},
    shared::{self, Theme},
};

fn preferences_path() -> Option<PathBuf> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(root.join("xrg-ng/settings.conf"))
}
fn saved_theme(themes: &[Theme]) -> usize {
    preferences_path()
        .and_then(|path| fs::read_to_string(path).ok())
        .and_then(|text| {
            text.lines()
                .find_map(|line| line.strip_prefix("theme="))
                .map(str::to_owned)
        })
        .and_then(|name| themes.iter().position(|t| t.name == name))
        .unwrap_or(1)
}
fn save_theme(theme: &Theme) -> Result<(), String> {
    let path = preferences_path().ok_or("No configuration directory")?;
    fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    let result = fs::write(&temporary, format!("theme={}\n", theme.name))
        .and_then(|_| fs::rename(&temporary, &path));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|e| e.to_string())
}

pub fn run(smoke: bool) -> bool {
    let application = gtk::Application::builder()
        .application_id("com.sdelavega.xrg-ng")
        .build();
    let success = Rc::new(Cell::new(!smoke));
    let result = success.clone();
    let worker = Rc::new(RefCell::new(None::<Worker>));
    let owner = worker.clone();
    application.connect_activate(move |application| {
        if let Some(window) = application.active_window() {
            window.present();
            return;
        }
        let monitor = Worker::start_with_ai(!smoke);
        let latest = monitor.latest.clone();
        *owner.borrow_mut() = Some(monitor);
        let themes = shared::themes();
        // Automated smoke mode never reads or writes user preferences.
        let selected = if smoke { 1 } else { saved_theme(&themes) };
        let theme = Rc::new(RefCell::new(themes[selected].clone()));
        let state = Rc::new(RefCell::new(None::<Snapshot>));
        let draw_count = Rc::new(Cell::new(0u32));
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
        let names: Vec<_> = themes.iter().map(|t| t.name.as_str()).collect();
        let chooser = gtk::DropDown::from_strings(&names);
        chooser.set_selected(selected as u32);
        chooser.set_tooltip_text(Some("Built-in theme"));
        toolbar.append(&chooser);
        content.append(&toolbar);
        let graphs = gtk::Box::new(gtk::Orientation::Vertical, 4);
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .vexpand(true)
            .child(&graphs)
            .build();
        content.append(&scroll);
        let mut areas = Vec::new();
        for (index, title) in [
            "CPU",
            "Memory",
            "Network · receive / send",
            "Disk · read / write",
            "Battery",
            "Temperature · hottest readable sensor",
            "GPU · activity",
            "AI tokens · observed rate",
        ]
        .into_iter()
        .enumerate()
        {
            let area = gtk::DrawingArea::new();
            area.set_content_width(360);
            area.set_content_height(100);
            area.set_hexpand(true);
            area.set_vexpand(true);
            area.update_property(&[gtk::accessible::Property::Label(title)]);
            let state = state.clone();
            let theme = theme.clone();
            let draws = draw_count.clone();
            area.set_draw_func(move |_, context, width, height| {
                draws.set(draws.get() + 1);
                let state = state.borrow();
                draw(
                    context,
                    width,
                    height,
                    &theme.borrow(),
                    title,
                    state.as_ref().and_then(|s| s.panels.get(index)),
                );
            });
            graphs.append(&area);
            areas.push(area);
        }
        let status = gtk::Label::new(Some("Sampling on a worker · 1 second interval"));
        status.set_margin_bottom(6);
        content.append(&status);
        let redraw = areas.clone();
        let palette = theme.clone();
        chooser.connect_selected_notify(move |chooser| {
            if let Some(selected) = themes.get(chooser.selected() as usize) {
                *palette.borrow_mut() = selected.clone();
                apply_shell_theme(&css, selected);
                if !smoke && let Err(error) = save_theme(selected) {
                    status.set_text(&format!("Could not save theme: {error}"));
                }
                for area in &redraw {
                    area.queue_draw();
                }
            }
        });
        let window = gtk::ApplicationWindow::builder()
            .application(application)
            .title("XRG-ng")
            .default_width(460)
            .default_height(if smoke { 940 } else { 850 })
            .child(&content)
            .build();
        window.present();
        let paintable = gtk::WidgetPaintable::new(Some(&content));
        let app = application.downgrade();
        let started = Instant::now();
        let passed = result.clone();
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let Some(app) = app.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if let Some(snapshot) = latest.lock().unwrap().take() {
                if smoke {
                    if snapshot.sequence == 2 {
                        chooser.set_selected(4);
                    } // Paper
                    if snapshot.sequence == 3 {
                        chooser.set_selected(2);
                    } // Ocean
                }
                for (area, panel) in areas.iter().zip(&snapshot.panels) {
                    area.set_tooltip_text(Some(&panel.detail));
                    area.update_property(&[
                        gtk::accessible::Property::Label(&format!(
                            "{}: {}",
                            panel.title, panel.label
                        )),
                        gtk::accessible::Property::Description(&panel.detail),
                    ]);
                }
                *state.borrow_mut() = Some(snapshot);
                for area in &areas {
                    area.queue_draw();
                }
            }
            if smoke {
                let ready = state
                    .borrow()
                    .as_ref()
                    .is_some_and(|s| s.sequence >= 4 && s.valid);
                if ready && draw_count.get() >= (areas.len() * 3) as u32 {
                    if let Some(path) = std::env::var_os("XRG_SMOKE_IMAGE")
                        && let Err(error) = save_snapshot(&app, &paintable, PathBuf::from(path))
                    {
                        eprintln!("GTK screenshot failed: {error}");
                        app.quit();
                        return glib::ControlFlow::Break;
                    }
                    println!(
                        "GTK_SMOKE_OK samples={} draws={}",
                        state.borrow().as_ref().unwrap().sequence,
                        draw_count.get()
                    );
                    passed.set(true);
                    app.quit();
                    return glib::ControlFlow::Break;
                }
                if started.elapsed() > Duration::from_secs(12) {
                    eprintln!(
                        "GTK smoke failed: {:?}, draws={}",
                        state.borrow().as_ref().map(|s| (s.sequence, s.valid)),
                        draw_count.get()
                    );
                    app.quit();
                    return glib::ControlFlow::Break;
                }
            }
            glib::ControlFlow::Continue
        });
    });
    let exit = application.run_with_args(&["xrg-ng-linux"]);
    worker.borrow_mut().take();
    success.get() && exit == glib::ExitCode::SUCCESS
}

fn color(context: &gtk::cairo::Context, color: [f64; 4]) {
    context.set_source_rgba(color[0], color[1], color[2], color[3]);
}
fn draw(
    context: &gtk::cairo::Context,
    width: i32,
    height: i32,
    theme: &Theme,
    title: &str,
    panel: Option<&Panel>,
) {
    // Compose translucent Classic colors over an opaque base; repainting never
    // accumulates alpha from previous frames.
    context.set_source_rgb(theme.colors[0][0], theme.colors[0][1], theme.colors[0][2]);
    let _ = context.paint();
    color(context, theme.colors[1]);
    context.rectangle(0., 0., width as f64, height as f64);
    let _ = context.fill();
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
    let _ = context.show_text(
        panel
            .map(|p| p.label.as_str())
            .unwrap_or("Waiting for sample…"),
    );
    let Some(panel) = panel else {
        return;
    };
    let (minimum, maximum) = panel.scale.bounds(&panel.series);
    let bottom = height as f64 - 6.;
    let top = 49.;
    if bottom <= top || width <= 20 {
        return;
    }
    for (index, values) in panel.series.iter().enumerate() {
        color(context, theme.colors[2 + index]);
        context.set_line_width(1.5);
        for (offset, value) in values.iter().enumerate() {
            let x = 8.
                + offset as f64 * (width as f64 - 16.)
                    / (values.len().saturating_sub(1).max(1)) as f64;
            let y =
                bottom - ((value - minimum) / (maximum - minimum)).clamp(0., 1.) * (bottom - top);
            if offset == 0 {
                context.move_to(x, y);
            } else {
                context.line_to(x, y);
            }
        }
        let _ = context.stroke();
    }
}

fn save_snapshot(
    application: &gtk::Application,
    paintable: &gtk::WidgetPaintable,
    path: PathBuf,
) -> Result<(), String> {
    let window = application.active_window().ok_or("No active window")?;
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
        ".xrg-shell {{ background-color: rgb({:.0}, {:.0}, {:.0}); color: rgb({:.0}, {:.0}, {:.0}); }}",
        background[0] * 255., background[1] * 255., background[2] * 255.,
        text[0] * 255., text[1] * 255., text[2] * 255.));
}
