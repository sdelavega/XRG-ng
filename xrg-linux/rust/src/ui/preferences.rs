// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Shell, save_snapshot};
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::{Path, PathBuf},
    rc::{Rc, Weak},
};
use xrg_ng_linux::settings::{GraphStyle, Layout, Module, Settings, ThemeChoice, ThemeDocument};
use xrg_ng_linux::shared;
use xrg_ng_linux::temperature::Units;
struct Row {
    id: Module,
    widget: gtk::Box,
    check: gtk::CheckButton,
    style: gtk::DropDown,
    up: gtk::Button,
    down: gtk::Button,
}
pub(super) struct Dialog {
    pub window: gtk::Window,
    shell: Weak<Shell>,
    pub targets: Rc<super::targets::Targets>,
    draft: RefCell<Settings>,
    updating: Cell<bool>,
    busy: Cell<bool>,
    closed: Cell<bool>,
    import_review: RefCell<Option<Rc<super::legacy_import::Review>>>,
    form: gtk::Box,
    modules: gtk::Box,
    rows: Vec<Row>,
    pub height: gtk::SpinButton,
    pub layout: gtk::DropDown,
    pub temperature_units: gtk::DropDown,
    pub name: gtk::Entry,
    pub colors: Vec<gtk::ColorDialogButton>,
    preset: gtk::DropDown,
    preset_names: gtk::StringList,
    message: gtk::Label,
    pub apply: gtk::Button,
    pub cancel: gtk::Button,
    pub reset: gtk::Button,
    paintable: gtk::WidgetPaintable,
}
impl Dialog {
    pub fn new(shell: &Rc<Shell>) -> Rc<Self> {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 10);
        content.set_margin_top(16);
        content.set_margin_bottom(16);
        content.set_margin_start(16);
        content.set_margin_end(16);
        let form = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let description = gtk::Label::new(Some(
            "Choose which graphs to show and arrange their order. Hidden graphs continue sampling.",
        ));
        description.set_wrap(true);
        description.set_xalign(0.);
        form.append(&description);
        let import = gtk::Button::with_label("Import legacy Linux settings…");
        import.set_halign(gtk::Align::Start);
        import.set_tooltip_text(Some(
            "Review the C application's settings.conf before importing into this draft",
        ));
        form.append(&import);
        let modules = gtk::Box::new(gtk::Orientation::Vertical, 4);
        let mut rows = Vec::new();
        for id in Module::ALL {
            let widget = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let check = gtk::CheckButton::with_label(id.title());
            check.set_hexpand(true);
            widget.append(&check);
            let style = gtk::DropDown::from_strings(&GraphStyle::ALL.map(GraphStyle::name));
            style.update_property(&[gtk::accessible::Property::Label(&format!(
                "{} graph style",
                id.title()
            ))]);
            style.set_tooltip_text(Some(
                "Solid area, chunky pixels, fine dots, or a hollow outline",
            ));
            widget.append(&style);
            let up = gtk::Button::with_label("Up");
            up.set_tooltip_text(Some(&format!("Move {} up", id.title())));
            up.update_property(&[gtk::accessible::Property::Label(&format!(
                "Move {} up",
                id.title()
            ))]);
            widget.append(&up);
            let down = gtk::Button::with_label("Down");
            down.set_tooltip_text(Some(&format!("Move {} down", id.title())));
            down.update_property(&[gtk::accessible::Property::Label(&format!(
                "Move {} down",
                id.title()
            ))]);
            widget.append(&down);
            modules.append(&widget);
            rows.push(Row {
                id,
                widget,
                check,
                style,
                up,
                down,
            });
        }
        form.append(&modules);
        let graph_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let label = gtk::Label::new(Some("Graph height (pixels)"));
        label.set_hexpand(true);
        label.set_xalign(0.);
        graph_row.append(&label);
        let height = gtk::SpinButton::with_range(64., 240., 4.);
        height.update_property(&[gtk::accessible::Property::Label("Graph height in pixels")]);
        graph_row.append(&height);
        form.append(&graph_row);
        let layout = gtk::DropDown::from_strings(&["Vertical", "Horizontal"]);
        let temperature_units = gtk::DropDown::from_strings(&["Celsius (°C)", "Fahrenheit (°F)"]);
        for (title, control) in [
            ("Graph layout", &layout),
            ("System temperature units", &temperature_units),
        ] {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let label = gtk::Label::new(Some(title));
            label.set_xalign(0.);
            label.set_hexpand(true);
            row.append(&label);
            control.update_property(&[gtk::accessible::Property::Label(title)]);
            row.append(control);
            form.append(&row);
        }
        let targets = Rc::new(super::targets::Targets::new(
            &shell.inventory(),
            &shell.settings.borrow().metrics,
        ));
        form.append(&targets.widget);
        let refresh = gtk::Button::with_label("Refresh source lists");
        form.append(&refresh);

        form.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        let theme_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let label = gtk::Label::new(Some("Theme"));
        label.set_hexpand(true);
        label.set_xalign(0.);
        theme_row.append(&label);
        let names: Vec<_> = shared::themes()
            .iter()
            .map(|t| t.name.clone())
            .chain(std::iter::once("Custom…".into()))
            .collect();
        let preset =
            gtk::DropDown::from_strings(&names.iter().map(String::as_str).collect::<Vec<_>>());
        let preset_names = preset
            .model()
            .unwrap()
            .downcast::<gtk::StringList>()
            .unwrap();
        preset.update_property(&[gtk::accessible::Property::Label("Theme preset")]);
        theme_row.append(&preset);
        form.append(&theme_row);
        let name = gtk::Entry::new();
        name.set_placeholder_text(Some("Custom theme name"));
        name.set_max_length(80);
        name.update_property(&[gtk::accessible::Property::Label("Theme name")]);
        form.append(&name);
        let files = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let load = gtk::Button::with_label("Load theme…");
        let save = gtk::Button::with_label("Save theme…");
        files.append(&load);
        files.append(&save);
        form.append(&files);
        let mut colors = Vec::new();
        for title in [
            "Background",
            "Graph background",
            "Series 1",
            "Series 2",
            "Series 3",
            "Border",
            "Text",
        ] {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let label = gtk::Label::new(Some(title));
            label.set_xalign(0.);
            label.set_hexpand(true);
            row.append(&label);
            let dialog = gtk::ColorDialog::new();
            dialog.set_with_alpha(title != "Background");
            dialog.set_title(title);
            let color = gtk::ColorDialogButton::new(Some(dialog));
            color.update_property(&[gtk::accessible::Property::Label(title)]);
            row.append(&color);
            form.append(&row);
            colors.push(color);
        }
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .vexpand(true)
            .child(&form)
            .build();
        content.append(&scroll);
        let message = gtk::Label::new(None);
        message.set_wrap(true);
        message.set_xalign(0.);
        message.set_visible(false);
        content.append(&message);
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let reset = gtk::Button::with_label("Restore defaults");
        actions.append(&reset);
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        actions.append(&spacer);
        let cancel = gtk::Button::with_label("Cancel");
        actions.append(&cancel);
        let apply = gtk::Button::with_label("Apply");
        apply.add_css_class("suggested-action");
        actions.append(&apply);
        content.append(&actions);
        let window = gtk::Window::builder()
            .application(&shell.window.application().unwrap())
            .title("XRG-ng Preferences")
            .transient_for(&shell.window)
            .modal(true)
            .destroy_with_parent(true)
            .default_width(620)
            .default_height(1000)
            .child(&content)
            .build();
        let paintable = gtk::WidgetPaintable::new(Some(&window));
        let dialog = Rc::new(Self {
            window,
            shell: Rc::downgrade(shell),
            targets,
            draft: RefCell::new(shell.settings.borrow().clone()),
            updating: Cell::new(false),
            busy: Cell::new(false),
            closed: Cell::new(false),
            import_review: RefCell::new(None),
            form,
            modules,
            rows,
            height,
            layout,
            temperature_units,
            name,
            colors,
            preset,
            preset_names,
            message,
            apply,
            cancel,
            reset: reset.clone(),
            paintable,
        });
        dialog.refresh();
        for row in &dialog.rows {
            let weak = Rc::downgrade(&dialog);
            let id = row.id;
            row.style.connect_selected_notify(move |control| {
                if let Some(dialog) = weak.upgrade()
                    && !dialog.updating.get()
                    && let Some(style) = GraphStyle::ALL.get(control.selected() as usize)
                    && let Some(module) = dialog
                        .draft
                        .borrow_mut()
                        .modules
                        .iter_mut()
                        .find(|m| m.id == id)
                {
                    module.style = *style;
                }
            });
            let weak = Rc::downgrade(&dialog);
            row.check.connect_toggled(move |check| {
                if let Some(dialog) = weak.upgrade()
                    && !dialog.updating.get()
                    && let Some(module) = dialog
                        .draft
                        .borrow_mut()
                        .modules
                        .iter_mut()
                        .find(|m| m.id == id)
                {
                    module.visible = check.is_active();
                }
            });
            for (button, offset) in [(&row.up, -1), (&row.down, 1)] {
                let weak = Rc::downgrade(&dialog);
                button.connect_clicked(move |_| {
                    if let Some(dialog) = weak.upgrade() {
                        dialog.draft.borrow_mut().move_module(id, offset);
                        dialog.refresh();
                    }
                });
            }
        }
        let weak = Rc::downgrade(&dialog);
        dialog.height.connect_value_changed(move |height| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().graph_height = height.value_as_int() as u32;
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog.layout.connect_selected_notify(move |control| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().layout = if control.selected() == 1 {
                    Layout::Horizontal
                } else {
                    Layout::Vertical
                };
                dialog.refresh();
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog
            .temperature_units
            .connect_selected_notify(move |control| {
                if let Some(dialog) = weak.upgrade()
                    && !dialog.updating.get()
                {
                    dialog.draft.borrow_mut().temperature_units = if control.selected() == 1 {
                        Units::Fahrenheit
                    } else {
                        Units::Celsius
                    };
                }
            });
        let weak = Rc::downgrade(&dialog);
        dialog.name.connect_changed(move |_| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.customize(None);
            }
        });
        for (index, color) in dialog.colors.iter().enumerate() {
            let weak = Rc::downgrade(&dialog);
            color.connect_rgba_notify(move |_| {
                if let Some(dialog) = weak.upgrade()
                    && !dialog.updating.get()
                {
                    dialog.customize(Some(index));
                }
            });
        }
        let weak = Rc::downgrade(&dialog);
        dialog.preset.connect_selected_notify(move |preset| {
            let Some(dialog) = weak.upgrade() else {
                return;
            };
            if dialog.updating.get() {
                return;
            }
            if preset.selected() == 6 {
                let choice = dialog.draft.borrow().theme.clone();
                if let ThemeChoice::Builtin { .. } = choice {
                    let theme = ThemeDocument::new(&choice.palette().expect("Known preset"));
                    dialog.draft.borrow_mut().theme = ThemeChoice::Custom {
                        theme: Box::new(theme),
                    };
                    let weak = Rc::downgrade(&dialog);
                    glib::idle_add_local_once(move || {
                        if let Some(dialog) = weak.upgrade() {
                            dialog.refresh();
                        }
                    });
                }
                return;
            }
            if let Some(theme) = shared::themes().get(preset.selected() as usize) {
                let choice = ThemeChoice::Builtin {
                    name: theme.name.clone(),
                };
                if dialog.draft.borrow().theme == choice {
                    return;
                }
                dialog.draft.borrow_mut().theme = choice;
                dialog.refresh();
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog.targets.connect_changed(move || {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().metrics = dialog.targets.value();
            }
        });
        let weak = Rc::downgrade(&dialog);
        refresh.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade()
                && let Some(shell) = dialog.shell.upgrade()
            {
                dialog.updating.set(true);
                let selection = dialog.draft.borrow().metrics.clone();
                dialog.targets.refresh(&shell.inventory(), &selection);
                dialog.updating.set(false);
            }
        });
        let weak = Rc::downgrade(&dialog);
        reset.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                let ai = dialog.draft.borrow().ai.clone();
                let weather = dialog.draft.borrow().weather.clone();
                *dialog.draft.borrow_mut() = Settings {
                    ai,
                    weather,
                    ..Settings::default()
                };
                dialog.refresh();
                dialog.set_message("Defaults restored in this draft. Apply to keep them.");
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog.cancel.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.window.close();
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog.apply.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                let settings = dialog.draft.borrow().clone();
                if let Err(error) = settings.validate() {
                    dialog.set_message(&error);
                    return;
                }
                if let Some(shell) = dialog.shell.upgrade() {
                    shell.apply(settings);
                }
                dialog.window.close();
            }
        });
        let weak = Rc::downgrade(&dialog);
        load.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.choose_file(false);
            }
        });
        let weak = Rc::downgrade(&dialog);
        save.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.choose_file(true);
            }
        });
        let weak_shell = Rc::downgrade(shell);
        let weak_dialog = Rc::downgrade(&dialog);
        dialog.window.connect_close_request(move |_| {
            if let Some(dialog) = weak_dialog.upgrade() {
                dialog.closed.set(true);
                let review = dialog.import_review.borrow_mut().take();
                if let Some(review) = review {
                    review.window.close();
                }
            }
            if let Some(shell) = weak_shell.upgrade() {
                shell.dialog.borrow_mut().take();
            }
            glib::Propagation::Proceed
        });
        let weak = Rc::downgrade(&dialog);
        import.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.choose_legacy();
            }
        });
        dialog
    }
    pub fn select_preset(&self, index: u32) {
        self.preset.set_selected(index);
    }
    pub fn check(&self, id: Module) -> gtk::CheckButton {
        self.rows[id.index()].check.clone()
    }
    pub fn style(&self, id: Module) -> gtk::DropDown {
        self.rows[id.index()].style.clone()
    }
    pub fn move_up(&self, id: Module) {
        self.rows[id.index()].up.emit_clicked();
    }
    pub fn is_busy(&self) -> bool {
        self.busy.get()
    }
    pub fn draft(&self) -> Settings {
        self.draft.borrow().clone()
    }
    pub fn message(&self) -> String {
        self.message.text().to_string()
    }
    fn set_message(&self, message: &str) {
        self.message.set_text(message);
        self.message.set_visible(true);
    }
    fn refresh(&self) {
        self.updating.set(true);
        let settings = self.draft.borrow();
        let horizontal = settings.layout == Layout::Horizontal;
        self.layout.set_selected(u32::from(horizontal));
        self.temperature_units
            .set_selected(u32::from(settings.temperature_units == Units::Fahrenheit));
        let mut previous = None::<gtk::Box>;
        for (index, module) in settings.modules.iter().enumerate() {
            let row = &self.rows[module.id.index()];
            for (button, direction) in [
                (&row.up, if horizontal { "Left" } else { "Up" }),
                (&row.down, if horizontal { "Right" } else { "Down" }),
            ] {
                button.set_label(direction);
                let label = format!("Move {} {}", row.id.title(), direction.to_lowercase());
                button.set_tooltip_text(Some(&label));
                button.update_property(&[gtk::accessible::Property::Label(&label)]);
            }
            row.check.set_active(module.visible);
            row.style.set_selected(module.style.index() as u32);
            row.up.set_sensitive(index > 0);
            row.down.set_sensitive(index + 1 < settings.modules.len());
            self.modules
                .reorder_child_after(&row.widget, previous.as_ref());
            previous = Some(row.widget.clone());
        }
        self.height.set_value(settings.graph_height as f64);
        self.targets.set(&settings.metrics);
        let palette = match &settings.theme {
            ThemeChoice::Custom { theme } => shared::Theme {
                name: theme.name.clone(),
                colors: theme.colors,
            },
            _ => settings.theme.palette().expect("Known built-in theme"),
        };
        self.name.set_text(&palette.name);
        for (button, rgba) in self.colors.iter().zip(palette.colors) {
            button.set_rgba(&gtk::gdk::RGBA::new(
                rgba[0] as f32,
                rgba[1] as f32,
                rgba[2] as f32,
                rgba[3] as f32,
            ));
        }
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
        if self.preset_names.string(6).as_deref() != Some(custom_name.as_str()) {
            self.preset_names.splice(6, 1, &[&custom_name]);
        }
        self.preset.set_selected(selected as u32);
        self.updating.set(false);
    }
    fn customize(&self, changed: Option<usize>) {
        let current = self.draft.borrow().theme.clone();
        let mut theme = match current {
            ThemeChoice::Custom { theme } => *theme,
            choice => ThemeDocument::new(&choice.palette().expect("Known preset")),
        };
        if let Some(index) = changed {
            let rgba = self.colors[index].rgba();
            theme.colors[index] = [
                rgba.red() as f64,
                rgba.green() as f64,
                rgba.blue() as f64,
                rgba.alpha() as f64,
            ];
        }
        theme.name = self.name.text().to_string();
        self.draft.borrow_mut().theme = ThemeChoice::Custom {
            theme: Box::new(theme),
        };
        // A name can be temporarily empty while editing. Refreshing all controls
        // here would validate an unfinished draft or move the text caret.
        self.updating.set(true);
        if self.preset_names.string(6).as_deref() != Some("Custom") {
            self.preset_names.splice(6, 1, &["Custom"]);
        }
        self.preset.set_selected(6);
        self.updating.set(false);
    }
    fn choose_file(self: &Rc<Self>, save: bool) {
        let chooser = gtk::FileDialog::builder()
            .title(if save {
                "Save XRG-ng theme"
            } else {
                "Load XRG-ng theme"
            })
            .modal(true)
            .build();
        let filter = gtk::FileFilter::new();
        filter.set_name(Some("XRG-ng themes (*.json)"));
        filter.add_pattern("*.json");
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        chooser.set_filters(Some(&filters));
        if save {
            chooser.set_initial_name(Some("theme.xrg-theme.json"));
        }
        let weak = Rc::downgrade(self);
        let callback = move |result: Result<gio::File, glib::Error>| {
            let Some(dialog) = weak.upgrade() else {
                return;
            };
            match result {
                Ok(file) => {
                    if let Some(path) = file.path() {
                        if save {
                            dialog.save_theme(path);
                        } else {
                            dialog.load_theme(path);
                        }
                    } else {
                        dialog.set_message("Choose a local theme file.");
                    }
                }
                Err(error)
                    if error.matches(gtk::DialogError::Dismissed)
                        || error.matches(gio::IOErrorEnum::Cancelled) => {}
                Err(error) => {
                    dialog.set_message(&format!("Could not choose a theme file: {error}"))
                }
            }
        };
        if save {
            chooser.save(Some(&self.window), None::<&gio::Cancellable>, callback);
        } else {
            chooser.open(Some(&self.window), None::<&gio::Cancellable>, callback);
        }
    }
    fn io_start(&self) -> bool {
        if self.busy.replace(true) {
            return false;
        }
        self.form.set_sensitive(false);
        self.apply.set_sensitive(false);
        self.reset.set_sensitive(false);
        self.set_message("Working with theme file…");
        true
    }
    fn io_finish(&self) {
        self.busy.set(false);
        self.form.set_sensitive(true);
        self.apply.set_sensitive(true);
        self.reset.set_sensitive(true);
    }
    fn choose_legacy(self: &Rc<Self>) {
        let chooser = gtk::FileDialog::builder()
            .title("Import legacy Linux settings")
            .modal(true)
            .build();
        let filter = gtk::FileFilter::new();
        filter.set_name(Some("Linux settings (*.conf, *.ini)"));
        filter.add_pattern("*.conf");
        filter.add_pattern("*.ini");
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        chooser.set_filters(Some(&filters));
        if let Some(path) = xrg_ng_linux::legacy::path_from(
            std::env::var_os("XDG_CONFIG_HOME").as_deref(),
            std::env::var_os("HOME").as_deref(),
        ) {
            chooser.set_initial_file(Some(&gio::File::for_path(path)));
        }
        let weak = Rc::downgrade(self);
        chooser.open(
            Some(&self.window),
            None::<&gio::Cancellable>,
            move |result| {
                let Some(dialog) = weak.upgrade().filter(|d| !d.closed.get()) else {
                    return;
                };
                match result {
                    Ok(file) => {
                        if let Some(path) = file.path() {
                            dialog.load_legacy(path);
                        } else {
                            dialog.set_message("Choose a local legacy settings file.");
                        }
                    }
                    Err(error)
                        if error.matches(gtk::DialogError::Dismissed)
                            || error.matches(gio::IOErrorEnum::Cancelled) => {}
                    Err(error) => {
                        dialog.set_message(&format!("Could not choose legacy settings: {error}"))
                    }
                }
            },
        );
    }
    pub fn load_legacy(self: &Rc<Self>, path: PathBuf) {
        if self.closed.get() || self.import_review.borrow().is_some() || !self.io_start() {
            return;
        }
        self.set_message("Reading legacy settings…");
        let base = self.draft.borrow().clone();
        let task = gio::spawn_blocking(move || xrg_ng_linux::legacy::load(&path, &base));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = task.await;
            let Some(dialog) = weak.upgrade().filter(|d| !d.closed.get()) else {
                return;
            };
            dialog.io_finish();
            match result {
                Ok(Ok(import)) => {
                    let review = super::legacy_import::Review::new(&dialog, import);
                    *dialog.import_review.borrow_mut() = Some(review.clone());
                    dialog.set_message("Review the import before changing this draft.");
                    review.window.present();
                }
                Ok(Err(error)) => {
                    dialog.set_message(&format!("Legacy settings could not be imported: {error}"))
                }
                Err(_) => dialog.set_message("Legacy settings reader stopped unexpectedly."),
            }
        });
    }
    pub fn review(&self) -> Option<Rc<super::legacy_import::Review>> {
        self.import_review.borrow().clone()
    }
    pub(super) fn accept_legacy(&self, settings: Settings) {
        if self.closed.get() {
            return;
        }
        *self.draft.borrow_mut() = settings;
        self.refresh();
        self.set_message("Legacy settings imported into this draft. Apply to use and save them, or Cancel to discard.");
    }
    pub(super) fn import_closed(&self) {
        self.import_review.borrow_mut().take();
    }
    pub fn load_theme(self: &Rc<Self>, path: PathBuf) {
        if !self.io_start() {
            return;
        }
        let task = gio::spawn_blocking(move || ThemeDocument::load(&path));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = task.await;
            let Some(dialog) = weak.upgrade() else {
                return;
            };
            dialog.io_finish();
            match result {
                Ok(Ok(theme)) => {
                    dialog.draft.borrow_mut().theme = ThemeChoice::Custom {
                        theme: Box::new(theme),
                    };
                    dialog.refresh();
                    dialog.set_message("Theme loaded into this draft. Apply to use it.");
                }
                Ok(Err(error)) => {
                    dialog.set_message(&format!("Theme could not be loaded: {error}"))
                }
                Err(_) => dialog.set_message("Theme reader stopped unexpectedly."),
            }
        });
    }
    pub fn save_theme(self: &Rc<Self>, path: PathBuf) {
        let document = match self.draft.borrow().theme.palette() {
            Ok(theme) => ThemeDocument::new(&theme),
            Err(error) => {
                self.set_message(&error);
                return;
            }
        };
        if !self.io_start() {
            return;
        }
        let task = gio::spawn_blocking(move || document.save(&path));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = task.await;
            let Some(dialog) = weak.upgrade() else {
                return;
            };
            dialog.io_finish();
            match result {
                Ok(Ok(())) => dialog.set_message("Theme saved."),
                Ok(Err(error)) => dialog.set_message(&format!("Theme could not be saved: {error}")),
                Err(_) => dialog.set_message("Theme writer stopped unexpectedly."),
            }
        });
    }
    pub fn snapshot(&self, path: &Path) -> Result<(), String> {
        save_snapshot(&self.window, &self.paintable, path)
    }
}
