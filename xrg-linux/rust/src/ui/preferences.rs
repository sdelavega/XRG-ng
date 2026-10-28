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
    scroll: gtk::ScrolledWindow,
    modules: gtk::Box,
    rows: Vec<Row>,
    pub height: gtk::SpinButton,
    pub width: gtk::SpinButton,
    pub sampling: gtk::SpinButton,
    pub opacity: gtk::SpinButton,
    pub window_size: super::window_size::Editor,
    pub network_scale: super::network_scale::Editor,
    pub graph_heights: super::graph_heights::Editor,
    pub activity: gtk::Expander,
    pub activity_visible: gtk::CheckButton,
    activity_series: gtk::CheckButton,
    pub activity_style: gtk::DropDown,
    pub activity_color: gtk::ColorDialogButton,
    pub layout: gtk::DropDown,
    pub temperature_units: gtk::DropDown,
    pub ai_models: gtk::CheckButton,
    pub name: gtk::Entry,
    pub colors: Vec<gtk::ColorDialogButton>,
    pub graph_colors: super::graph_colors::Editor,
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
        let width_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let width_label = gtk::Label::new(Some("Minimum graph width (pixels)"));
        width_label.set_hexpand(true);
        width_label.set_xalign(0.);
        let width = gtk::SpinButton::with_range(100., 1200., 20.);
        width.update_property(&[gtk::accessible::Property::Label(
            "Minimum graph width in pixels",
        )]);
        width_row.append(&width_label);
        width_row.append(&width);
        form.append(&width_row);
        let width_note = gtk::Label::new(Some(
            "Graphs can expand to fill available space. Wider graphs scroll horizontally in either layout; window size is separate.",
        ));
        width_note.set_wrap(true);
        width_note.set_xalign(0.);
        form.append(&width_note);
        let graph_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let label = gtk::Label::new(Some("Default graph height (pixels)"));
        label.set_hexpand(true);
        label.set_xalign(0.);
        graph_row.append(&label);
        let height = gtk::SpinButton::with_range(64., 240., 4.);
        height.update_property(&[gtk::accessible::Property::Label(
            "Default graph height in pixels",
        )]);
        graph_row.append(&height);
        form.append(&graph_row);
        let graph_heights = super::graph_heights::Editor::new();
        form.append(&graph_heights.widget);
        let sampling_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let sampling_label = gtk::Label::new(Some("System sampling interval (milliseconds)"));
        sampling_label.set_hexpand(true);
        sampling_label.set_xalign(0.);
        let sampling = gtk::SpinButton::with_range(250., 10000., 250.);
        sampling.update_property(&[gtk::accessible::Property::Label(
            "System sampling interval in milliseconds",
        )]);
        sampling.set_tooltip_text(Some("Target interval for system metrics. Slow collection can take longer. AI and weather keep their own schedules. Changing this interval preserves rate baselines and history."));
        sampling_row.append(&sampling_label);
        sampling_row.append(&sampling);
        form.append(&sampling_row);
        let opacity_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let opacity_label = gtk::Label::new(Some("Main window opacity (%)"));
        opacity_label.set_hexpand(true);
        opacity_label.set_xalign(0.);
        let opacity = gtk::SpinButton::with_range(10., 100., 5.);
        opacity.set_digits(1);
        opacity.set_width_chars(5);
        opacity.update_property(&[gtk::accessible::Property::Label(
            "Main window opacity percent",
        )]);
        opacity.set_tooltip_text(Some("Applies to the entire dashboard. Preferences and other windows stay opaque. X11 requires a compositing manager; Wayland supports transparency."));
        opacity_row.append(&opacity_label);
        opacity_row.append(&opacity);
        form.append(&opacity_row);
        let window_size = super::window_size::Editor::new(shell);
        form.append(&window_size.widget);
        let network_scale = super::network_scale::Editor::new();
        form.append(&network_scale.widget);
        let activity_content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let activity_description = gtk::Label::new(Some(
            "CPU shows up to 64 logical-core bars. Other graphs show one current-value bar per series, on the graph’s axis. Rate/count bars scale to recent history, not capacity. Temperature bars show a display range, not a thermal limit. Missing readings stay blank; measured zero has an empty track.",
        ));
        activity_description.set_wrap(true);
        activity_description.set_xalign(0.);
        activity_content.append(&activity_description);
        let activity_visible = gtk::CheckButton::with_label("Show current-value activity bars");
        activity_content.append(&activity_visible);
        let activity_series =
            gtk::CheckButton::with_label("Use graph series colors for activity bars");
        activity_content.append(&activity_series);
        let activity_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let activity_style = gtk::DropDown::from_strings(&GraphStyle::ALL.map(GraphStyle::name));
        activity_style.update_property(&[gtk::accessible::Property::Label("Activity bar style")]);
        activity_row.append(&gtk::Label::new(Some("Style")));
        activity_row.append(&activity_style);
        let activity_dialog = gtk::ColorDialog::new();
        activity_dialog.set_with_alpha(true);
        activity_dialog.set_title("Activity bar color");
        let activity_color = gtk::ColorDialogButton::new(Some(activity_dialog));
        activity_color.update_property(&[gtk::accessible::Property::Label("Activity bar color")]);
        activity_row.append(&gtk::Label::new(Some("Color")));
        activity_row.append(&activity_color);
        activity_content.append(&activity_row);
        let activity = gtk::Expander::builder()
            .label("Activity bars")
            .child(&activity_content)
            .build();
        form.append(&activity);
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
        let ai_models =
            gtk::CheckButton::with_label("Show per-model token details in AI monitoring");
        ai_models.set_tooltip_text(Some("Show recorded token attribution. Provider totals, Ollama inventory, source polling and graph history stay the same."));
        form.append(&ai_models);
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
        load.set_tooltip_text(Some(
            "Load XRG-ng JSON or a macOS XTF theme with RGB, grayscale or verified Display P3 colors. Display P3 is converted to the sRGB palette.",
        ));
        let save = gtk::Button::with_label("Save theme…");
        save.set_tooltip_text(Some(
            "Save the current global palette as portable XRG-ng JSON.",
        ));
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
        let graph_colors = super::graph_colors::Editor::new();
        form.append(&graph_colors.widget);
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
            scroll,
            modules,
            rows,
            height,
            width,
            sampling,
            opacity,
            window_size,
            network_scale,
            graph_heights,
            activity,
            activity_visible,
            activity_series,
            activity_style,
            activity_color,
            layout,
            temperature_units,
            ai_models,
            name,
            colors,
            graph_colors,
            preset,
            preset_names,
            message,
            apply,
            cancel,
            reset: reset.clone(),
            paintable,
        });
        dialog.refresh();
        let weak = Rc::downgrade(&dialog);
        dialog.network_scale.connect(Rc::new(move || {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
                && let Ok(value) = dialog.network_scale.value()
            {
                dialog.draft.borrow_mut().network_min_scale = value;
            }
        }));
        let weak = Rc::downgrade(&dialog);
        dialog.window_size.connect(Rc::new(move || {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().window_size = dialog.window_size.value();
                dialog.window_size.update_sensitivity();
            }
        }));
        let weak = Rc::downgrade(&dialog);
        dialog.opacity.connect_value_changed(move |control| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().window_opacity = control.value() / 100.;
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog.sampling.connect_value_changed(move |control| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().sampling_interval_ms = control.value_as_int() as u32;
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog.ai_models.connect_toggled(move |control| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().ai_show_model_breakdown = control.is_active();
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog.activity_series.connect_toggled(move |control| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().activity_bars.use_series_colors = control.is_active();
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog.activity_visible.connect_toggled(move |control| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().activity_bars.visible = control.is_active();
                dialog.activity_style.set_sensitive(control.is_active());
                dialog.activity_color.set_sensitive(control.is_active());
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog
            .activity_style
            .connect_selected_notify(move |control| {
                if let Some(dialog) = weak.upgrade()
                    && !dialog.updating.get()
                    && let Some(style) = GraphStyle::ALL.get(control.selected() as usize)
                {
                    dialog.draft.borrow_mut().activity_bars.style = *style;
                }
            });
        let weak = Rc::downgrade(&dialog);
        dialog.activity_color.connect_rgba_notify(move |control| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().activity_bars.use_series_colors = false;
                dialog.activity_series.set_active(false);
                let rgba = control.rgba();
                dialog.draft.borrow_mut().activity_bars.color = [
                    rgba.red() as f64,
                    rgba.green() as f64,
                    rgba.blue() as f64,
                    rgba.alpha() as f64,
                ];
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog.graph_heights.connect(Rc::new(move |change| {
            if let Some(dialog) = weak.upgrade() {
                dialog.graph_height_changed(change);
            }
        }));
        let weak = Rc::downgrade(&dialog);
        dialog.graph_colors.connect(Rc::new(move |change| {
            if let Some(dialog) = weak.upgrade() {
                dialog.graph_color_changed(change);
            }
        }));
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
        dialog.width.connect_value_changed(move |width| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().graph_width = width.value_as_int() as u32;
            }
        });
        let weak = Rc::downgrade(&dialog);
        dialog.height.connect_value_changed(move |height| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.updating.get()
            {
                dialog.draft.borrow_mut().graph_height = height.value_as_int() as u32;
                dialog.refresh();
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
                match dialog.network_scale.value() {
                    Ok(value) => dialog.draft.borrow_mut().network_min_scale = value,
                    Err(error) => {
                        dialog.set_message(&error);
                        return;
                    }
                }
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
    pub fn reveal_graph_colors(&self) {
        self.graph_colors.widget.set_expanded(true);
        self.graph_colors.module.grab_focus();
        let adjustment = self.scroll.vadjustment();
        adjustment.set_value((adjustment.upper() - adjustment.page_size()).max(0.));
    }
    pub fn reveal_sensor_curves(&self) {
        self.targets.curves.set_expanded(true);
        if let Some(point) = self
            .targets
            .widget
            .compute_point(&self.form, &gtk::graphene::Point::new(0., 0.))
        {
            self.scroll.vadjustment().set_value(point.y() as f64);
        }
        self.targets.temperature_extra[0].widget.grab_focus();
    }
    pub fn reveal_network_scale(&self) {
        self.network_scale.widget.set_expanded(true);
        if let Some(point) = self
            .network_scale
            .widget
            .compute_point(&self.form, &gtk::graphene::Point::new(0., 0.))
        {
            self.scroll.vadjustment().set_value(point.y() as f64);
        }
        self.network_scale.value.grab_focus();
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
        self.network_scale.refresh(settings.network_min_scale);
        self.opacity.set_value(settings.window_opacity * 100.);
        self.window_size.refresh(settings.window_size);
        self.sampling
            .set_value(f64::from(settings.sampling_interval_ms));
        let horizontal = settings.layout == Layout::Horizontal;
        self.layout.set_selected(u32::from(horizontal));
        self.temperature_units
            .set_selected(u32::from(settings.temperature_units == Units::Fahrenheit));
        self.ai_models.set_active(settings.ai_show_model_breakdown);
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
        self.width.set_value(settings.graph_width as f64);
        self.graph_heights.refresh(&settings);
        self.activity_series
            .set_active(settings.activity_bars.use_series_colors);
        self.activity_visible
            .set_active(settings.activity_bars.visible);
        self.activity_style
            .set_selected(settings.activity_bars.style.index() as u32);
        self.activity_style
            .set_sensitive(settings.activity_bars.visible);
        self.activity_color
            .set_sensitive(settings.activity_bars.visible);
        let rgba = settings.activity_bars.color;
        self.activity_color.set_rgba(&gtk::gdk::RGBA::new(
            rgba[0] as f32,
            rgba[1] as f32,
            rgba[2] as f32,
            rgba[3] as f32,
        ));
        self.targets.set(&settings.metrics);
        let palette = Self::preview_palette(&settings);
        self.name.set_text(&palette.name);
        for (button, rgba) in self.colors.iter().zip(palette.colors) {
            button.set_rgba(&gtk::gdk::RGBA::new(
                rgba[0] as f32,
                rgba[1] as f32,
                rgba[2] as f32,
                rgba[3] as f32,
            ));
        }
        self.graph_colors.refresh(&settings, &palette);
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
    fn preview_palette(settings: &Settings) -> shared::Theme {
        match &settings.theme {
            ThemeChoice::Custom { theme } => shared::Theme {
                name: theme.name.clone(),
                colors: theme.colors,
            },
            choice => choice.palette().expect("Known preset"),
        }
    }
    fn graph_height_changed(&self, change: super::graph_heights::Change) {
        if self.updating.get() {
            return;
        }
        let Some(id) = self.graph_heights.selected() else {
            return;
        };
        use super::graph_heights::Change;
        {
            let mut draft = self.draft.borrow_mut();
            let default = draft.graph_height;
            if matches!(change, Change::ResetAll) {
                for module in &mut draft.modules {
                    module.height = None;
                }
            } else {
                let module = draft.modules.iter_mut().find(|m| m.id == id).unwrap();
                match change {
                    Change::Scope => {}
                    Change::Inherit(true) => module.height = None,
                    Change::Inherit(false) => {
                        module.height = Some(module.effective_height(default))
                    }
                    Change::Height(value) if module.height.is_some() => module.height = Some(value),
                    _ => {}
                }
            }
        }
        self.updating.set(true);
        self.graph_heights.refresh(&self.draft.borrow());
        self.updating.set(false);
    }
    fn graph_color_changed(&self, change: super::graph_colors::Change) {
        if self.updating.get() {
            return;
        }
        let Some(id) = self.graph_colors.selected() else {
            return;
        };
        use super::graph_colors::Change;
        let result = (|| {
            let mut draft = self.draft.borrow_mut();
            let base = Self::preview_palette(&draft);
            let module = draft.modules.iter_mut().find(|m| m.id == id).unwrap();
            match change {
                Change::Scope => {}
                Change::Reset => module.colors = Default::default(),
                Change::Color(index, rgba) => module.colors.set(index, Some(rgba))?,
                Change::Inherit(index, true) => module.colors.set(index, None)?,
                Change::Inherit(index, false) => {
                    let palette = module.colors.palette(&base);
                    let rgba = *palette.colors.get(index + 1).ok_or("Unknown graph color")?;
                    module.colors.set(index, Some(rgba))?;
                }
            }
            Ok::<_, String>(())
        })();
        if let Err(error) = result {
            self.set_message(&error);
            return;
        }
        self.updating.set(true);
        let draft = self.draft.borrow();
        let palette = Self::preview_palette(&draft);
        self.graph_colors.refresh(&draft, &palette);
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
        filter.set_name(Some(if save {
            "XRG-ng themes (*.json)"
        } else {
            "XRG themes (*.json, *.xtf)"
        }));
        filter.add_pattern("*.json");
        if !save {
            filter.add_pattern("*.xtf");
            filter.add_pattern("*.XTF");
        }
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
