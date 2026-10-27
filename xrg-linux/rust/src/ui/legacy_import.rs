// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{preferences::Dialog, save_snapshot};
use gtk::prelude::*;
use std::{path::Path, rc::Rc};
use xrg_ng_linux::legacy::Import;

pub(super) struct Review {
    pub window: gtk::Window,
    pub accept: gtk::Button,
    pub cancel: gtk::Button,
    report: String,
    paintable: gtk::WidgetPaintable,
}
impl Review {
    pub fn new(parent: &Rc<Dialog>, import: Import) -> Rc<Self> {
        let report = import.summary();
        let content = gtk::Box::new(gtk::Orientation::Vertical, 10);
        content.set_margin_top(12);
        content.set_margin_bottom(12);
        content.set_margin_start(12);
        content.set_margin_end(12);
        let description = gtk::Label::new(Some(
            "Review the entries below. Import into draft lets you inspect and edit the result in Preferences before Apply saves it.",
        ));
        description.set_wrap(true);
        description.set_xalign(0.);
        content.append(&description);
        let text = gtk::TextView::builder()
            .editable(false)
            .cursor_visible(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .build();
        text.update_property(&[gtk::accessible::Property::Label(
            "Legacy settings import report",
        )]);
        text.buffer().set_text(&report);
        content.append(
            &gtk::ScrolledWindow::builder()
                .vexpand(true)
                .child(&text)
                .build(),
        );
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        actions.set_halign(gtk::Align::End);
        let cancel = gtk::Button::with_label("Cancel");
        actions.append(&cancel);
        let accept = gtk::Button::with_label("Import into draft");
        accept.add_css_class("suggested-action");
        actions.append(&accept);
        content.append(&actions);
        let window = gtk::Window::builder()
            .application(&parent.window.application().unwrap())
            .transient_for(&parent.window)
            .modal(true)
            .destroy_with_parent(true)
            .title("Import legacy Linux settings")
            .default_width(680)
            .default_height(720)
            .child(&content)
            .build();
        let paintable = gtk::WidgetPaintable::new(Some(&window));
        let view = Rc::new(Self {
            window,
            accept,
            cancel,
            report,
            paintable,
        });
        let weak_parent = Rc::downgrade(parent);
        let weak = Rc::downgrade(&view);
        view.accept.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade()
                && let Some(parent) = weak_parent.upgrade()
            {
                parent.accept_legacy(import.settings.clone());
                view.window.close();
            }
        });
        let weak = Rc::downgrade(&view);
        view.cancel.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.window.close();
            }
        });
        let weak_parent = Rc::downgrade(parent);
        view.window.connect_close_request(move |_| {
            if let Some(parent) = weak_parent.upgrade() {
                parent.import_closed();
            }
            gtk::glib::Propagation::Proceed
        });
        let key = gtk::EventControllerKey::new();
        let weak = Rc::downgrade(&view);
        key.connect_key_pressed(move |_, key, _, _| {
            if key == gtk::gdk::Key::Escape
                && let Some(view) = weak.upgrade()
            {
                view.window.close();
                return gtk::glib::Propagation::Stop;
            }
            gtk::glib::Propagation::Proceed
        });
        view.window.add_controller(key);
        view
    }
    pub fn report(&self) -> &str {
        &self.report
    }
    pub fn snapshot(&self, path: &Path) -> Result<(), String> {
        save_snapshot(&self.window, &self.paintable, path)
    }
}
