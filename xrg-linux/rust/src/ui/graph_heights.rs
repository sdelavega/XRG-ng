// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use gtk::prelude::*;
use std::rc::Rc;
use xrg_ng_linux::settings::{Module, Settings};
pub(super) enum Change {
    Scope,
    Inherit(bool),
    Height(u32),
    ResetAll,
}
pub(super) struct Editor {
    pub widget: gtk::Expander,
    pub module: gtk::DropDown,
    pub inherit: gtk::CheckButton,
    pub height: gtk::SpinButton,
    pub reset: gtk::Button,
}
impl Editor {
    pub fn new() -> Self {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let description = gtk::Label::new(Some(
            "Choose a graph to size independently, or keep it linked to the default height. Sizes apply in both layouts.",
        ));
        description.set_wrap(true);
        description.set_xalign(0.);
        content.append(&description);
        let module = gtk::DropDown::from_strings(&Module::ALL.map(Module::title));
        super::limit_dropdown(&module);
        module.update_property(&[gtk::accessible::Property::Label("Graph to resize")]);
        content.append(&module);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let inherit = gtk::CheckButton::with_label("Use default height");
        inherit.set_hexpand(true);
        row.append(&inherit);
        let height = gtk::SpinButton::with_range(64., 240., 4.);
        height.update_property(&[gtk::accessible::Property::Label(
            "Individual graph height in pixels",
        )]);
        row.append(&height);
        content.append(&row);
        let reset = gtk::Button::with_label("Use default height for all graphs");
        content.append(&reset);
        let widget = gtk::Expander::builder()
            .label("Individual graph heights")
            .child(&content)
            .build();
        Self {
            widget,
            module,
            inherit,
            height,
            reset,
        }
    }
    pub fn selected(&self) -> Option<Module> {
        Module::ALL.get(self.module.selected() as usize).copied()
    }
    pub fn connect(&self, changed: Rc<dyn Fn(Change)>) {
        let call = changed.clone();
        self.module
            .connect_selected_notify(move |_| call(Change::Scope));
        let call = changed.clone();
        self.inherit
            .connect_toggled(move |check| call(Change::Inherit(check.is_active())));
        let call = changed.clone();
        self.height.connect_value_changed(move |height| {
            call(Change::Height(height.value_as_int() as u32))
        });
        self.reset
            .connect_clicked(move |_| changed(Change::ResetAll));
    }
    /// The parent suppresses callbacks while presenting the selected graph.
    pub fn refresh(&self, settings: &Settings) {
        let Some(id) = self.selected() else {
            return;
        };
        let module = settings.modules.iter().find(|m| m.id == id).unwrap();
        self.inherit.set_active(module.height.is_none());
        self.height.set_sensitive(module.height.is_some());
        self.height
            .set_value(module.effective_height(settings.graph_height) as f64);
        self.reset
            .set_sensitive(settings.modules.iter().any(|m| m.height.is_some()));
    }
}
