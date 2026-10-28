// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::Shell;
use gtk::prelude::*;
use std::rc::Rc;
use xrg_ng_linux::settings::WindowSize;

pub(super) struct Editor {
    pub widget: gtk::Expander,
    pub remember: gtk::CheckButton,
    pub width: gtk::SpinButton,
    pub height: gtk::SpinButton,
}
impl Editor {
    pub fn new(shell: &Shell) -> Self {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let remember = gtk::CheckButton::with_label("Remember dashboard window size");
        content.append(&remember);
        let (initial_width, initial_height) = shell.window.default_size();
        let mut controls = Vec::new();
        for (label, initial) in [
            ("Window width", initial_width),
            ("Window height", initial_height),
        ] {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let title = gtk::Label::new(Some(label));
            title.set_hexpand(true);
            title.set_xalign(0.);
            let spin = gtk::SpinButton::with_range(100., 8192., 10.);
            spin.set_value(initial.clamp(100, 8192) as f64);
            spin.update_property(&[gtk::accessible::Property::Label(&format!(
                "Dashboard {label} in logical pixels"
            ))]);
            row.append(&title);
            row.append(&spin);
            content.append(&row);
            controls.push(spin);
        }
        let note = gtk::Label::new(Some(
            "Logical pixels, independent of graph sizes. After Apply, resizing the dashboard is remembered when opening Preferences or exiting normally. Maximized/fullscreen sizes are ignored. Uncheck to resume automatic compact sizing. Your desktop may constrain the requested size.",
        ));
        note.set_wrap(true);
        note.set_xalign(0.);
        content.append(&note);
        let widget = gtk::Expander::builder()
            .label("Dashboard window size")
            .child(&content)
            .build();
        Self {
            widget,
            remember,
            width: controls[0].clone(),
            height: controls[1].clone(),
        }
    }
    pub fn value(&self) -> Option<WindowSize> {
        self.remember.is_active().then(|| WindowSize {
            width: self.width.value_as_int() as u32,
            height: self.height.value_as_int() as u32,
        })
    }
    pub fn update_sensitivity(&self) {
        self.width.set_sensitive(self.remember.is_active());
        self.height.set_sensitive(self.remember.is_active());
    }
    pub fn refresh(&self, size: Option<WindowSize>) {
        self.remember.set_active(size.is_some());
        if let Some(size) = size {
            self.width.set_value(size.width as f64);
            self.height.set_value(size.height as f64);
        }
        self.update_sensitivity();
    }
    pub fn connect(&self, changed: Rc<dyn Fn()>) {
        let call = changed.clone();
        self.remember.connect_toggled(move |_| call());
        let call = changed.clone();
        self.width.connect_value_changed(move |_| call());
        self.height.connect_value_changed(move |_| changed());
    }
}
