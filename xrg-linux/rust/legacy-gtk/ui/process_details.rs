// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::save_snapshot;
use gtk::prelude::*;
use std::{cell::RefCell, path::Path, rc::Rc, sync::Arc};
use xrg_ng_linux::process::{Process, Report, details::View};
pub(super) struct Window {
    pub window: gtk::Window,
    state: RefCell<View>,
    text: gtk::Label,
    pub scroll: gtk::ScrolledWindow,
    status: gtk::Label,
    shown: RefCell<String>,
    paintable: gtk::WidgetPaintable,
    // GTK's transient relationship is weak. Keep the native parent alive until
    // this child's Window field has been released, including delayed Rc drops.
    _parent: gtk::Window,
}
impl Window {
    pub fn new(parent: &gtk::Window, process: Process) -> Rc<Self> {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 10);
        content.set_margin_top(12);
        content.set_margin_bottom(12);
        content.set_margin_start(12);
        content.set_margin_end(12);
        let status = gtk::Label::new(None);
        status.set_xalign(0.);
        status.set_wrap(true);
        content.append(&status);
        let text = gtk::Label::builder()
            .selectable(true)
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .xalign(0.)
            .yalign(0.)
            .hexpand(true)
            .valign(gtk::Align::Start)
            .build();
        let attributes = gtk::pango::AttrList::new();
        attributes.insert(gtk::pango::AttrFontDesc::new(
            &gtk::pango::FontDescription::from_string("Monospace"),
        ));
        text.set_attributes(Some(&attributes));
        let viewport = gtk::Viewport::builder()
            .scroll_to_focus(false)
            .child(&text)
            .build();
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&viewport)
            .build();
        scroll.update_property(&[gtk::accessible::Property::Label(
            "Process identity, live readings and freshness",
        )]);
        content.append(&scroll);
        let close = gtk::Button::with_label("Close");
        close.set_halign(gtk::Align::End);
        content.append(&close);
        let window = gtk::Window::builder()
            .application(&parent.application().unwrap())
            .transient_for(parent)
            .destroy_with_parent(true)
            .title(format!("XRG-ng · {} · PID {}", process.name, process.pid))
            .default_width(640)
            .default_height(780)
            .child(&content)
            .build();
        window.set_default_widget(Some(&close));
        gtk::prelude::RootExt::set_focus(&window, Some(&close));
        let paintable = gtk::WidgetPaintable::new(Some(&window));
        let result = Rc::new(Self {
            window,
            state: RefCell::new(View::new(process)),
            text,
            scroll,
            status,
            _parent: parent.clone(),
            shown: RefCell::new(String::new()),
            paintable,
        });
        let weak = Rc::downgrade(&result);
        close.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.window.close();
            }
        });
        result.refresh();
        result
    }
    pub fn matches(&self, process: &Process) -> bool {
        self.state.borrow().matches(process)
    }
    pub fn update(&self, report: &Result<Arc<Report>, String>) {
        self.state.borrow_mut().update(report);
        self.refresh();
    }
    fn refresh(&self) {
        let state = self.state.borrow();
        let text = state.text();
        self.status.set_text(&state.status().description());
        self.text
            .update_property(&[gtk::accessible::Property::Description(
                &state.status().description(),
            )]);
        if *self.shown.borrow() != text {
            let position = self.scroll.vadjustment().value();
            self.text.set_text(&text);
            self.scroll.vadjustment().set_value(position);
            *self.shown.borrow_mut() = text;
        }
    }
    pub fn text(&self) -> String {
        self.shown.borrow().clone()
    }
    pub fn snapshot(&self, path: &Path) -> Result<(), String> {
        save_snapshot(&self.window, &self.paintable, path)
    }
}
