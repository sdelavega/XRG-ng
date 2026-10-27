// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Shell, save_snapshot};
use gtk::prelude::*;
use std::{
    cell::RefCell,
    path::Path,
    rc::{Rc, Weak},
};
use xrg_ng_linux::{
    shared,
    weather::{Preferences, Units, Update},
};
pub(super) struct Window {
    pub window: gtk::Window,
    shell: Weak<Shell>,
    pub enabled: gtk::CheckButton,
    pub station: gtk::Entry,
    pub units: gtk::DropDown,
    pub interval: gtk::SpinButton,
    pub apply: gtk::Button,
    pub close: gtk::Button,
    pub refresh: gtk::Button,
    status: gtk::Label,
    observation: gtk::TextView,
    shown: RefCell<String>,
    paintable: gtk::WidgetPaintable,
}
impl Window {
    pub fn new(shell: &Rc<Shell>) -> Rc<Self> {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 10);
        content.set_margin_top(12);
        content.set_margin_bottom(12);
        content.set_margin_start(12);
        content.set_margin_end(12);
        let note = gtk::Label::new(Some(
            "Station observations from the NWS Aviation Weather Center. Weather is off until enabled. Choose a four-character ICAO station, such as KSEA. Requests include only the station code; location is not detected automatically.",
        ));
        note.set_wrap(true);
        note.set_xalign(0.);
        content.append(&note);
        let enabled = gtk::CheckButton::with_label("Enable weather requests");
        content.append(&enabled);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        row.append(&gtk::Label::new(Some("ICAO station")));
        let station = gtk::Entry::new();
        station.set_max_length(64);
        station.set_width_chars(8);
        station.set_max_width_chars(12);
        station.set_placeholder_text(Some("KSEA"));
        station.update_property(&[gtk::accessible::Property::Label("ICAO weather station")]);
        row.append(&station);
        let units = gtk::DropDown::from_strings(&["Metric · °C, km/h, hPa", "US · °F, mph, inHg"]);
        units.update_property(&[gtk::accessible::Property::Label("Weather display units")]);
        row.append(&units);
        content.append(&row);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let label = gtk::Label::new(Some("Automatic refresh (minutes)"));
        label.set_hexpand(true);
        label.set_xalign(0.);
        row.append(&label);
        let interval = gtk::SpinButton::with_range(5., 60., 5.);
        interval.update_property(&[gtk::accessible::Property::Label(
            "Weather refresh interval in minutes",
        )]);
        row.append(&interval);
        content.append(&row);
        let observation = gtk::TextView::builder()
            .editable(false)
            .cursor_visible(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .build();
        observation.update_property(&[gtk::accessible::Property::Label(
            "Weather observations, age and raw METAR",
        )]);
        let scroll = gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&observation)
            .build();
        content.append(&scroll);
        let status = gtk::Label::new(Some(
            "Changes stay in this draft until Apply. Automatic and manual requests are limited to one per minute per instance.",
        ));
        status.set_wrap(true);
        status.set_xalign(0.);
        content.append(&status);
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let refresh = gtk::Button::with_label("Refresh now");
        actions.append(&refresh);
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        actions.append(&spacer);
        let close = gtk::Button::with_label("Close");
        actions.append(&close);
        let apply = gtk::Button::with_label("Apply");
        apply.add_css_class("suggested-action");
        actions.append(&apply);
        content.append(&actions);
        let window = gtk::Window::builder()
            .application(&shell.window.application().unwrap())
            .title("XRG-ng Weather")
            .transient_for(&shell.window)
            .destroy_with_parent(true)
            .default_width(660)
            .default_height(760)
            .child(&content)
            .build();
        let paintable = gtk::WidgetPaintable::new(Some(&window));
        let view = Rc::new(Self {
            window,
            shell: Rc::downgrade(shell),
            enabled,
            station,
            units,
            interval,
            apply,
            close,
            refresh,
            status,
            observation,
            shown: RefCell::new(String::new()),
            paintable,
        });
        let preferences = &shell.settings.borrow().weather;
        view.enabled.set_active(preferences.enabled);
        view.station.set_text(&preferences.station);
        view.units
            .set_selected(if preferences.units == Units::Metric {
                0
            } else {
                1
            });
        view.interval.set_value(preferences.refresh_minutes as f64);
        view.update(None, preferences);
        let weak = Rc::downgrade(&view);
        view.apply.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.apply_preferences();
            }
        });
        let weak = Rc::downgrade(&view);
        view.close.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.window.close();
            }
        });
        let weak = Rc::downgrade(&view);
        view.refresh.connect_clicked(move |_| { if let Some(view) = weak.upgrade() && let Some(shell) = view.shell.upgrade() { shell.weather_control.refresh(); view.status.set_text("Refresh requested. A running request or the one-minute cooldown may finish first."); } });
        let weak = Rc::downgrade(&view);
        view.window.connect_close_request(move |_| {
            if let Some(view) = weak.upgrade()
                && let Some(shell) = view.shell.upgrade()
            {
                shell.weather_window.borrow_mut().take();
            }
            gtk::glib::Propagation::Proceed
        });
        view
    }
    fn apply_preferences(&self) {
        let station = self.station.text();
        let station = if station.trim().is_empty() {
            String::new()
        } else {
            shared::metar_station(&station).unwrap_or_else(|| station.to_string())
        };
        let preferences = Preferences {
            enabled: self.enabled.is_active(),
            station,
            units: if self.units.selected() == 0 {
                Units::Metric
            } else {
                Units::Us
            },
            refresh_minutes: self.interval.value_as_int() as u32,
        };
        match preferences.validate() {
            Err(error) => self.status.set_text(&error),
            Ok(()) => {
                if let Some(shell) = self.shell.upgrade() {
                    self.station.set_text(&preferences.station);
                    let mut settings = shell.settings.borrow().clone();
                    settings.weather = preferences;
                    shell.apply(settings);
                    self.update(
                        shell
                            .state
                            .borrow()
                            .as_ref()
                            .and_then(|s| s.weather.as_ref()),
                        &shell.settings.borrow().weather,
                    );
                    self.status.set_text(
                        "Weather preferences applied. Saving status appears in the main window.",
                    );
                }
            }
        }
    }
    pub fn update(&self, update: Option<&Update>, active: &Preferences) {
        self.refresh.set_sensitive(active.enabled);
        let text = if !active.enabled {
            "Weather disabled. No weather requests are made."
        } else {
            update
                .filter(|u| &u.preferences == active)
                .map(|u| u.detail.as_str())
                .unwrap_or("Waiting for the weather worker to apply the active station.")
        };
        if *self.shown.borrow() != text {
            self.observation.buffer().set_text(text);
            *self.shown.borrow_mut() = text.to_owned();
        }
    }
    pub fn status(&self) -> String {
        self.status.text().to_string()
    }
    pub fn text(&self) -> String {
        self.shown.borrow().clone()
    }
    pub fn snapshot(&self, path: &Path) -> Result<(), String> {
        save_snapshot(&self.window, &self.paintable, path)
    }
}
