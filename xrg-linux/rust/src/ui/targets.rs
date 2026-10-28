// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use gtk::prelude::*;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};
use xrg_ng_linux::{metrics::Inventory, settings::MetricSelection};
pub(super) struct Picker<T> {
    pub widget: gtk::DropDown,
    choices: RefCell<Vec<Option<T>>>,
    labels: RefCell<Vec<String>>,
    all: String,
    updating: Cell<bool>,
}
impl<T: Clone + Eq + ToString + 'static> Picker<T> {
    fn new(all: &str, options: Vec<(T, String)>, selected: Option<T>) -> Rc<Self> {
        let picker = Rc::new(Self {
            widget: gtk::DropDown::from_strings(&[]),
            choices: RefCell::new(Vec::new()),
            labels: RefCell::new(Vec::new()),
            all: all.into(),
            updating: Cell::new(false),
        });
        super::limit_dropdown(&picker.widget);
        picker.widget.set_enable_search(true);
        picker.replace(options, selected);
        picker
    }
    pub fn value(&self) -> Option<T> {
        self.choices
            .borrow()
            .get(self.widget.selected() as usize)
            .cloned()
            .flatten()
    }
    fn replace(&self, options: Vec<(T, String)>, selected: Option<T>) {
        self.updating.set(true);
        let mut choices = vec![None];
        let mut labels = vec![self.all.clone()];
        for (value, label) in options {
            if !choices.contains(&Some(value.clone())) {
                choices.push(Some(value));
                labels.push(label);
            }
        }
        if let Some(value) = &selected
            && !choices.contains(&selected)
        {
            choices.push(Some(value.clone()));
            labels.push(format!(
                "{} · unavailable in latest sample",
                value.to_string()
            ));
        }
        let index = choices.iter().position(|c| *c == selected).unwrap_or(0);
        *self.choices.borrow_mut() = choices;
        *self.labels.borrow_mut() = labels;
        self.widget.set_model(Some(&gtk::StringList::new(
            &self
                .labels
                .borrow()
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
        )));
        self.widget.set_selected(index as u32);
        self.updating.set(false);
    }
    pub fn select(&self, value: Option<T>) {
        if !self.choices.borrow().contains(&value) {
            let options = self
                .choices
                .borrow()
                .iter()
                .cloned()
                .zip(self.labels.borrow().iter().cloned())
                .filter_map(|(value, label)| value.map(|v| (v, label)))
                .collect();
            self.replace(options, value);
        } else {
            let index = self
                .choices
                .borrow()
                .iter()
                .position(|v| *v == value)
                .unwrap();
            self.widget.set_selected(index as u32);
        }
    }
    fn changed(self: &Rc<Self>, callback: impl Fn() + 'static) {
        let weak = Rc::downgrade(self);
        self.widget.connect_selected_notify(move |_| {
            if let Some(picker) = weak.upgrade()
                && !picker.updating.get()
            {
                callback();
            }
        });
    }
}
pub(super) struct Targets {
    pub widget: gtk::Box,
    pub cpu: Rc<Picker<u32>>,
    pub network: Rc<Picker<String>>,
    pub disk: Rc<Picker<String>>,
    pub gpu: Rc<Picker<String>>,
    pub temperature: Rc<Picker<String>>,
    pub fan: Rc<Picker<String>>,
    pub curves: gtk::Expander,
    pub temperature_extra: [Rc<Picker<String>>; 2],
    pub fan_extra: [Rc<Picker<String>>; 2],
    updating: Cell<bool>,
}
impl Targets {
    pub fn new(inventory: &Inventory, selection: &MetricSelection) -> Self {
        let widget = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let label = gtk::Label::new(Some("Metric sources"));
        label.set_xalign(0.);
        label.add_css_class("heading");
        widget.append(&label);
        let cpu = Picker::new(
            "Aggregate CPU",
            inventory
                .cpus
                .iter()
                .map(|n| (*n, format!("CPU {n}")))
                .collect(),
            selection.cpu,
        );
        let network = Picker::new(
            "All non-loopback interfaces",
            inventory
                .networks
                .iter()
                .map(|n| (n.clone(), n.clone()))
                .collect(),
            selection.network.clone(),
        );
        let disk = Picker::new(
            "All physical disks",
            inventory
                .disks
                .iter()
                .map(|n| (n.clone(), n.clone()))
                .collect(),
            selection.disk.clone(),
        );
        let gpu = Picker::new(
            "Up to three GPU adapters",
            inventory
                .gpus
                .iter()
                .map(|g| (g.id.clone(), g.label.clone()))
                .collect(),
            selection.gpu.clone(),
        );
        let temperature = Picker::new(
            "Hottest readable sensor",
            inventory
                .temperatures
                .iter()
                .map(|s| (s.id.clone(), s.label.clone()))
                .collect(),
            selection.temperature.clone(),
        );
        let fan = Picker::new(
            "Up to three readable fans",
            inventory
                .fans
                .iter()
                .map(|s| (s.id.clone(), s.label.clone()))
                .collect(),
            selection.fan.clone(),
        );
        for (title, picker) in [
            ("CPU", &cpu.widget),
            ("Network", &network.widget),
            ("Disk", &disk.widget),
            ("GPU and VRAM", &gpu.widget),
            ("Temperature", &temperature.widget),
            ("Fan RPM", &fan.widget),
        ] {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let label = gtk::Label::new(Some(title));
            label.set_xalign(0.);
            label.set_hexpand(true);
            row.append(&label);
            picker.update_property(&[gtk::accessible::Property::Label(&format!("{title} source"))]);
            row.append(picker);
            widget.append(&row);
        }
        let temperature_extra = std::array::from_fn(|i| {
            Picker::new(
                "Not graphed",
                inventory
                    .temperatures
                    .iter()
                    .map(|s| (s.id.clone(), s.label.clone()))
                    .collect(),
                selection.temperature_extra[i].clone(),
            )
        });
        let fan_extra = std::array::from_fn(|i| {
            Picker::new(
                "Not graphed",
                inventory
                    .fans
                    .iter()
                    .map(|s| (s.id.clone(), s.label.clone()))
                    .collect(),
                selection.fan_extra[i].clone(),
            )
        });
        let content = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let explanation = gtk::Label::new(Some(
            "Choose a primary temperature sensor or fan above to pin up to three independent curves. Choose different sensors for curves 2 and 3. Curve numbers follow graph colors and ‘now’ bars. Missing selected sensors leave gaps and never select a replacement. Automatic views remain available above.",
        ));
        explanation.set_wrap(true);
        explanation.set_xalign(0.);
        content.append(&explanation);
        for (kind, pickers) in [("Temperature", &temperature_extra), ("Fan RPM", &fan_extra)] {
            for (index, picker) in pickers.iter().enumerate() {
                let title = format!("{kind} curve {}", index + 2);
                let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
                let label = gtk::Label::new(Some(&title));
                label.set_xalign(0.);
                label.set_hexpand(true);
                row.append(&label);
                picker
                    .widget
                    .update_property(&[gtk::accessible::Property::Label(&title)]);
                row.append(&picker.widget);
                content.append(&row);
            }
        }
        let curves = gtk::Expander::builder()
            .label("Additional temperature and fan curves")
            .child(&content)
            .build();
        widget.append(&curves);
        let targets = Self {
            widget,
            cpu,
            network,
            disk,
            gpu,
            temperature,
            fan,
            curves,
            temperature_extra,
            fan_extra,
            updating: Cell::new(false),
        };
        targets.synchronize();
        targets
    }
    fn synchronize(&self) {
        self.updating.set(true);
        for (primary, extra) in [
            (&self.temperature, &self.temperature_extra),
            (&self.fan, &self.fan_extra),
        ] {
            let active = primary.value().is_some();
            for picker in extra {
                if !active {
                    picker.select(None);
                }
                picker.widget.set_sensitive(active);
            }
        }
        self.updating.set(false);
    }
    pub fn value(&self) -> MetricSelection {
        MetricSelection {
            cpu: self.cpu.value(),
            network: self.network.value(),
            disk: self.disk.value(),
            gpu: self.gpu.value(),
            temperature: self.temperature.value(),
            fan: self.fan.value(),
            temperature_extra: if self.temperature.value().is_some() {
                std::array::from_fn(|i| self.temperature_extra[i].value())
            } else {
                Default::default()
            },
            fan_extra: if self.fan.value().is_some() {
                std::array::from_fn(|i| self.fan_extra[i].value())
            } else {
                Default::default()
            },
        }
    }
    pub fn set(&self, value: &MetricSelection) {
        self.cpu.select(value.cpu);
        self.network.select(value.network.clone());
        self.disk.select(value.disk.clone());
        self.gpu.select(value.gpu.clone());
        self.temperature.select(value.temperature.clone());
        self.fan.select(value.fan.clone());
        for i in 0..2 {
            self.temperature_extra[i].select(value.temperature_extra[i].clone());
            self.fan_extra[i].select(value.fan_extra[i].clone());
        }
        self.synchronize();
    }
    pub fn refresh(&self, inventory: &Inventory, value: &MetricSelection) {
        self.cpu.replace(
            inventory
                .cpus
                .iter()
                .map(|n| (*n, format!("CPU {n}")))
                .collect(),
            value.cpu,
        );
        self.network.replace(
            inventory
                .networks
                .iter()
                .map(|n| (n.clone(), n.clone()))
                .collect(),
            value.network.clone(),
        );
        self.disk.replace(
            inventory
                .disks
                .iter()
                .map(|n| (n.clone(), n.clone()))
                .collect(),
            value.disk.clone(),
        );
        self.gpu.replace(
            inventory
                .gpus
                .iter()
                .map(|g| (g.id.clone(), g.label.clone()))
                .collect(),
            value.gpu.clone(),
        );
        self.temperature.replace(
            inventory
                .temperatures
                .iter()
                .map(|s| (s.id.clone(), s.label.clone()))
                .collect(),
            value.temperature.clone(),
        );
        self.fan.replace(
            inventory
                .fans
                .iter()
                .map(|s| (s.id.clone(), s.label.clone()))
                .collect(),
            value.fan.clone(),
        );
        for i in 0..2 {
            self.temperature_extra[i].replace(
                inventory
                    .temperatures
                    .iter()
                    .map(|s| (s.id.clone(), s.label.clone()))
                    .collect(),
                value.temperature_extra[i].clone(),
            );
            self.fan_extra[i].replace(
                inventory
                    .fans
                    .iter()
                    .map(|s| (s.id.clone(), s.label.clone()))
                    .collect(),
                value.fan_extra[i].clone(),
            );
        }
        self.synchronize();
    }
    pub fn connect_changed(self: &Rc<Self>, callback: impl Fn() + 'static) {
        let callback: Rc<dyn Fn()> = Rc::new(callback);
        // Keep Picker's model-refresh guard as well as the form-level guard.
        let weak = Rc::downgrade(self);
        let callback: Rc<dyn Fn()> = Rc::new(move || {
            if let Some(targets) = weak.upgrade()
                && !targets.updating.get()
            {
                targets.synchronize();
                callback();
            }
        });
        for register in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] {
            let cb = callback.clone();
            match register {
                0 => self.cpu.changed(move || cb()),
                1 => self.network.changed(move || cb()),
                2 => self.disk.changed(move || cb()),
                3 => self.gpu.changed(move || cb()),
                4 => self.temperature.changed(move || cb()),
                5 => self.fan.changed(move || cb()),
                6..=7 => self.temperature_extra[register - 6].changed(move || cb()),
                _ => self.fan_extra[register - 8].changed(move || cb()),
            }
        }
    }
}
