// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Shell, save_snapshot};
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::{Path, PathBuf},
    rc::{Rc, Weak},
};
use xrg_ng_linux::settings::{Module, Settings, ThemeChoice, ThemeDocument};
use xrg_ng_linux::shared;
struct Row {
    id: Module,
    widget: gtk::Box,
    check: gtk::CheckButton,
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
    form: gtk::Box,
    modules: gtk::Box,
    rows: Vec<Row>,
    pub height: gtk::SpinButton,
    pub name: gtk::Entry,
    pub colors: Vec<gtk::ColorDialogButton>,
    preset: gtk::DropDown,
    preset_names: gtk::StringList,
    message: gtk::Label,
    pub apply: gtk::Button,
    pub cancel: gtk::Button,
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
            "Choose which graphs to show and arrange them with Up and Down. Hidden graphs continue sampling.",
        ));
        description.set_wrap(true);
        description.set_xalign(0.);
        form.append(&description);
        let modules = gtk::Box::new(gtk::Orientation::Vertical, 4);
        let mut rows = Vec::new();
        for id in Module::ALL {
            let widget = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let check = gtk::CheckButton::with_label(id.title());
            check.set_hexpand(true);
            widget.append(&check);
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
            form,
            modules,
            rows,
            height,
            name,
            colors,
            preset,
            preset_names,
            message,
            apply,
            cancel,
            paintable,
        });
        dialog.refresh();
        for row in &dialog.rows {
            let weak = Rc::downgrade(&dialog);
            let id = row.id;
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
                *dialog.draft.borrow_mut() = Settings::default();
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
        dialog.window.connect_close_request(move |_| {
            if let Some(shell) = weak_shell.upgrade() {
                shell.dialog.borrow_mut().take();
            }
            glib::Propagation::Proceed
        });
        dialog
    }
    pub fn select_preset(&self, index: u32) {
        self.preset.set_selected(index);
    }
    pub fn check(&self, id: Module) -> gtk::CheckButton {
        self.rows[id.index()].check.clone()
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
        let mut previous = None::<gtk::Box>;
        for (index, module) in settings.modules.iter().enumerate() {
            let row = &self.rows[module.id.index()];
            row.check.set_active(module.visible);
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
        self.set_message("Working with theme file…");
        true
    }
    fn io_finish(&self) {
        self.busy.set(false);
        self.form.set_sensitive(true);
        self.apply.set_sensitive(true);
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
