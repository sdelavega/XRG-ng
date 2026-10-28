// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use gtk::prelude::*;
use std::rc::Rc;
use xrg_ng_linux::{engine::Panel, settings::network_scale};

pub(super) struct Editor {
    pub widget: gtk::Expander,
    pub value: gtk::Entry,
    pub units: gtk::DropDown,
}
impl Editor {
    pub fn new() -> Self {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let note = gtk::Label::new(Some(
            "Minimum upper bound for the Network graph and its activity bars. The axis still grows with traffic above this floor. Zero keeps automatic scaling. This is a display range, not your connection's capacity. Rates, counters and existing history are unchanged.",
        ));
        note.set_wrap(true);
        note.set_xalign(0.);
        content.append(&note);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let value = gtk::Entry::new();
        value.set_input_purpose(gtk::InputPurpose::Digits);
        value.set_max_length(24);
        value.set_width_chars(12);
        value.set_hexpand(true);
        value.update_property(&[gtk::accessible::Property::Label(
            "Minimum network graph scale",
        )]);
        let units = gtk::DropDown::from_strings(&["B/s", "KiB/s", "MiB/s"]);
        units.update_property(&[gtk::accessible::Property::Label(
            "Minimum network scale units",
        )]);
        row.append(&value);
        row.append(&units);
        content.append(&row);
        let widget = gtk::Expander::builder()
            .label("Network graph scale")
            .child(&content)
            .build();
        Self {
            widget,
            value,
            units,
        }
    }
    pub fn value(&self) -> Result<u64, String> {
        network_scale::parse(self.value.text().as_str(), self.units.selected())
    }
    pub fn refresh(&self, minimum: u64) {
        let (text, unit) = network_scale::display(minimum);
        self.value.set_text(&text);
        self.units.set_selected(unit);
    }
    pub fn connect(&self, changed: Rc<dyn Fn()>) {
        let call = changed.clone();
        self.value.connect_changed(move |_| call());
        self.units.connect_selected_notify(move |_| changed());
    }
}
pub(super) fn description(panel: &Panel, minimum: u64) -> String {
    let (_, upper) = panel.scale.bounds_with_minimum(&panel.series, minimum);
    format!(
        "\nNetwork axis: 0–{upper:.2} bytes/s; minimum upper bound: {minimum} bytes/s. Zero selects automatic scaling. The axis can grow with traffic; this is a display range, not link capacity."
    )
}
