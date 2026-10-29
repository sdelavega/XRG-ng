// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use gtk::prelude::*;
use std::rc::Rc;
use xrg_ng_linux::{
    settings::{Module, Settings},
    shared::Theme,
};
pub(super) enum Change {
    Scope,
    Inherit(usize, bool),
    Color(usize, [f64; 4]),
    Reset,
}
pub(super) struct Editor {
    pub widget: gtk::Expander,
    pub module: gtk::DropDown,
    pub inherit: Vec<gtk::CheckButton>,
    pub colors: Vec<gtk::ColorDialogButton>,
    pub reset: gtk::Button,
}
impl Editor {
    pub fn new() -> Self {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let description = gtk::Label::new(Some(
            "Override only the colors you choose. Use theme follows the active preset or custom palette.",
        ));
        description.set_wrap(true);
        description.set_xalign(0.);
        content.append(&description);
        let module = gtk::DropDown::from_strings(&Module::ALL.map(Module::title));
        super::limit_dropdown(&module);
        module.update_property(&[gtk::accessible::Property::Label("Graph to customize")]);
        content.append(&module);
        let mut inherit = Vec::new();
        let mut colors = Vec::new();
        for title in ["Graph background", "Series 1", "Series 2", "Series 3"] {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let label = gtk::Label::new(Some(title));
            label.set_xalign(0.);
            label.set_hexpand(true);
            row.append(&label);
            let check = gtk::CheckButton::with_label("Use theme");
            check.update_property(&[gtk::accessible::Property::Label(&format!(
                "Use theme for graph {title}"
            ))]);
            row.append(&check);
            let dialog = gtk::ColorDialog::new();
            dialog.set_with_alpha(true);
            dialog.set_title(title);
            let color = gtk::ColorDialogButton::new(Some(dialog));
            color.update_property(&[gtk::accessible::Property::Label(&format!(
                "Graph {title} color"
            ))]);
            row.append(&color);
            content.append(&row);
            inherit.push(check);
            colors.push(color);
        }
        let reset = gtk::Button::with_label("Use theme for this graph");
        content.append(&reset);
        let widget = gtk::Expander::builder()
            .label("Per-graph colors")
            .child(&content)
            .build();
        Self {
            widget,
            module,
            inherit,
            colors,
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
        for (index, check) in self.inherit.iter().enumerate() {
            let call = changed.clone();
            check.connect_toggled(move |check| call(Change::Inherit(index, check.is_active())));
        }
        for (index, color) in self.colors.iter().enumerate() {
            let call = changed.clone();
            color.connect_rgba_notify(move |button| {
                let c = button.rgba();
                call(Change::Color(
                    index,
                    [
                        c.red() as f64,
                        c.green() as f64,
                        c.blue() as f64,
                        c.alpha() as f64,
                    ],
                ));
            });
        }
        self.reset.connect_clicked(move |_| changed(Change::Reset));
    }
    /// The parent suppresses callbacks while refreshing these controls.
    pub fn refresh(&self, settings: &Settings, base: &Theme) {
        let Some(id) = self.selected() else {
            return;
        };
        let appearance = settings.modules.iter().find(|m| m.id == id).unwrap();
        let palette = appearance.colors.palette(base);
        for (index, rgba) in palette.colors[1..5].iter().enumerate() {
            let inherited = appearance.colors.components()[index].is_none();
            self.inherit[index].set_active(inherited);
            self.colors[index].set_sensitive(!inherited);
            self.colors[index].set_rgba(&gtk::gdk::RGBA::new(
                rgba[0] as f32,
                rgba[1] as f32,
                rgba[2] as f32,
                rgba[3] as f32,
            ));
        }
        self.reset.set_sensitive(!appearance.colors.is_inherited());
    }
}
