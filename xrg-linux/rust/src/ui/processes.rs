// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Shell, save_snapshot};
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::Path,
    rc::{Rc, Weak},
    sync::Arc,
};
use xrg_ng_linux::{
    process::{Listing, Report, Sort},
    settings::ProcessView,
};
const SORTS: [Sort; 4] = [Sort::Cpu, Sort::Memory, Sort::Pid, Sort::Name];
struct Row {
    widget: gtk::ListBoxRow,
    labels: Vec<gtk::Label>,
}
pub(super) struct Window {
    pub window: gtk::Window,
    shell: Weak<Shell>,
    pub filter: gtk::Entry,
    pub uid: gtk::Entry,
    pub sort: gtk::DropDown,
    pub limit: gtk::SpinButton,
    status: gtk::Label,
    list: gtk::ListBox,
    rows: RefCell<Vec<Row>>,
    source: RefCell<Option<Arc<Report>>>,
    view: RefCell<ProcessView>,
    updating: Cell<bool>,
    valid: Cell<bool>,
    running: Cell<bool>,
    revision: Cell<u64>,
    completed: Cell<u64>,
    source_revision: Cell<u64>,
    source_completed: Cell<u64>,
    shown: Cell<usize>,
    closed: Cell<bool>,
    paintable: gtk::WidgetPaintable,
}
impl Window {
    pub fn new(shell: &Rc<Shell>) -> Rc<Self> {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        content.set_margin_top(12);
        content.set_margin_bottom(12);
        content.set_margin_start(12);
        content.set_margin_end(12);
        let controls = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let filter = gtk::Entry::new();
        filter.set_placeholder_text(Some("Filter process name"));
        filter.set_max_length(128);
        filter.set_hexpand(true);
        filter.update_property(&[gtk::accessible::Property::Label("Process name filter")]);
        controls.append(&filter);
        let uid = gtk::Entry::new();
        uid.set_placeholder_text(Some("All UIDs"));
        uid.set_max_length(10);
        uid.set_width_chars(10);
        uid.set_max_width_chars(10);
        uid.update_property(&[gtk::accessible::Property::Label(
            "UID filter, empty for all users",
        )]);
        controls.append(&uid);
        let mine = gtk::Button::with_label("My UID");
        controls.append(&mine);
        content.append(&controls);
        let options = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let sort = gtk::DropDown::from_strings(&[
            "CPU · highest first",
            "RSS · highest first",
            "PID · lowest first",
            "Name · A–Z",
        ]);
        sort.update_property(&[gtk::accessible::Property::Label("Process sort order")]);
        options.append(&sort);
        let label = gtk::Label::new(Some("Maximum rows"));
        label.set_hexpand(true);
        label.set_halign(gtk::Align::End);
        options.append(&label);
        let limit = gtk::SpinButton::with_range(10., 200., 10.);
        limit.update_property(&[gtk::accessible::Property::Label("Maximum process rows")]);
        options.append(&limit);
        content.append(&options);
        let header = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        for (title, width) in [
            ("PID", 8),
            ("Name", 24),
            ("UID", 10),
            ("CPU %", 9),
            ("RSS MiB", 11),
            ("Threads", 7),
            ("State", 6),
        ] {
            let label = gtk::Label::new(Some(title));
            label.set_width_chars(width);
            label.set_xalign(0.);
            if title == "Name" {
                label.set_hexpand(true);
            }
            label.add_css_class("heading");
            header.append(&label);
        }
        content.append(&header);
        let list = gtk::ListBox::new();
        list.set_selection_mode(gtk::SelectionMode::None);
        list.add_css_class("boxed-list");
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Automatic)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .vexpand(true)
            .child(&list)
            .build();
        content.append(&scroll);
        let status = gtk::Label::new(Some("Waiting for process data…"));
        status.set_xalign(0.);
        status.set_wrap(true);
        content.append(&status);
        let note = gtk::Label::new(Some(
            "100% CPU is one core. RSS can include shared pages. Counts cover the readable scan, which may be partial.",
        ));
        note.set_xalign(0.);
        note.set_wrap(true);
        content.append(&note);
        let window = gtk::Window::builder()
            .application(&shell.window.application().unwrap())
            .title("XRG-ng Processes")
            .transient_for(&shell.window)
            .destroy_with_parent(true)
            .default_width(940)
            .default_height(560)
            .child(&content)
            .build();
        let paintable = gtk::WidgetPaintable::new(Some(&window));
        let result = Rc::new(Self {
            window,
            shell: Rc::downgrade(shell),
            filter,
            uid,
            sort,
            limit,
            status,
            list,
            rows: RefCell::new(Vec::new()),
            source: RefCell::new(None),
            view: RefCell::new(shell.settings.borrow().processes.clone()),
            updating: Cell::new(false),
            valid: Cell::new(true),
            running: Cell::new(false),
            revision: Cell::new(0),
            completed: Cell::new(0),
            source_revision: Cell::new(0),
            source_completed: Cell::new(0),
            shown: Cell::new(0),
            closed: Cell::new(false),
            paintable,
        });
        result.set_view(shell.settings.borrow().processes.clone());
        let weak = Rc::downgrade(&result);
        result.filter.connect_changed(move |_| {
            if let Some(window) = weak.upgrade() {
                window.controls_changed();
            }
        });
        let weak = Rc::downgrade(&result);
        result.uid.connect_changed(move |_| {
            if let Some(window) = weak.upgrade() {
                window.controls_changed();
            }
        });
        let weak = Rc::downgrade(&result);
        result.sort.connect_selected_notify(move |_| {
            if let Some(window) = weak.upgrade() {
                window.controls_changed();
            }
        });
        let weak = Rc::downgrade(&result);
        result.limit.connect_value_changed(move |_| {
            if let Some(window) = weak.upgrade() {
                window.controls_changed();
            }
        });
        let weak = Rc::downgrade(&result);
        mine.connect_clicked(move |_| {
            if let Some(window) = weak.upgrade() {
                window.uid.set_text(&unsafe { libc::getuid() }.to_string());
            }
        });
        let weak = Rc::downgrade(&result);
        result.window.connect_close_request(move |_| {
            if let Some(window) = weak.upgrade() {
                window.closed.set(true);
                if let Some(shell) = window.shell.upgrade() {
                    shell.processes.borrow_mut().take();
                }
            }
            glib::Propagation::Proceed
        });
        result
    }
    pub fn set_view(self: &Rc<Self>, view: ProcessView) {
        self.updating.set(true);
        self.sort
            .set_selected(SORTS.iter().position(|s| *s == view.sort).unwrap_or(0) as u32);
        self.filter.set_text(&view.filter);
        self.uid
            .set_text(&view.uid.map(|n| n.to_string()).unwrap_or_default());
        self.limit.set_value(view.limit as f64);
        *self.view.borrow_mut() = view;
        self.updating.set(false);
        self.valid.set(true);
        self.request();
    }
    fn controls_changed(self: &Rc<Self>) {
        if self.updating.get() {
            return;
        }
        let uid = self.uid.text();
        let parsed = if uid.is_empty() {
            Ok(None)
        } else {
            uid.parse::<u32>()
                .map(Some)
                .map_err(|_| "Enter a numeric UID, or leave it empty for all users")
        };
        let view = parsed
            .map(|uid| ProcessView {
                sort: *SORTS
                    .get(self.sort.selected() as usize)
                    .unwrap_or(&Sort::Cpu),
                uid,
                filter: self.filter.text().to_string(),
                limit: self.limit.value_as_int() as u32,
            })
            .and_then(|v| {
                v.validate()
                    .map(|_| v)
                    .map_err(|_| "Invalid process filter or row limit")
            });
        match view {
            Err(error) => {
                self.valid.set(false);
                self.revision.set(self.revision.get() + 1);
                self.show_rows(&[]);
                self.status.set_text(error);
            }
            Ok(view) => {
                self.valid.set(true);
                *self.view.borrow_mut() = view.clone();
                if let Some(shell) = self.shell.upgrade() {
                    shell.save_process_view(view);
                }
                self.request();
            }
        }
    }
    pub fn update(self: &Rc<Self>, report: &Result<Arc<Report>, String>) {
        match report {
            Ok(report) => {
                *self.source.borrow_mut() = Some(report.clone());
                self.source_revision.set(self.source_revision.get() + 1);
                if !self.running.get() && self.valid.get() {
                    self.start_query();
                }
            }
            Err(error) => {
                self.source.borrow_mut().take();
                self.revision.set(self.revision.get() + 1);
                self.show_rows(&[]);
                self.status
                    .set_text(&format!("Process data unavailable: {error}"));
            }
        }
    }
    fn request(self: &Rc<Self>) {
        self.revision.set(self.revision.get() + 1);
        if !self.running.get() && self.valid.get() && !self.closed.get() {
            self.start_query();
        }
    }
    fn start_query(self: &Rc<Self>) {
        let Some(source) = self.source.borrow().clone() else {
            return;
        };
        if !self.valid.get() || self.closed.get() {
            return;
        }
        self.running.set(true);
        let view = self.view.borrow().clone();
        let revision = self.revision.get();
        let generation = self.source_revision.get();
        let task = gio::spawn_blocking(move || source.listing(&view));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = task.await;
            let Some(window) = weak.upgrade() else {
                return;
            };
            window.running.set(false);
            if window.closed.get() {
                return;
            }
            if revision == window.revision.get() && window.valid.get() {
                match result {
                    Ok(Ok(listing)) => window.show_listing(listing),
                    Ok(Err(error)) => {
                        window.show_rows(&[]);
                        window.status.set_text(&error);
                    }
                    Err(_) => {
                        window.show_rows(&[]);
                        window
                            .status
                            .set_text("Process query stopped unexpectedly.");
                    }
                }
                window.completed.set(revision);
                window.source_completed.set(generation);
            }
            if (revision != window.revision.get() || generation != window.source_revision.get())
                && window.valid.get()
            {
                window.start_query();
            }
        });
    }
    fn show_listing(&self, listing: Listing) {
        self.show_rows(&listing.rows);
        self.status.set_text(&format!(
            "Showing {} of {} matching / {} readable processes\n{}",
            listing.rows.len(),
            listing.matched,
            listing.readable,
            listing.coverage
        ));
    }
    fn show_rows(&self, processes: &[xrg_ng_linux::process::Process]) {
        let mut rows = self.rows.borrow_mut();
        while rows.len() < processes.len() {
            let widget = gtk::ListBoxRow::new();
            widget.set_activatable(false);
            widget.set_selectable(false);
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
            row.set_margin_top(4);
            row.set_margin_bottom(4);
            let mut labels = Vec::new();
            for (index, width) in [8, 24, 10, 9, 11, 7, 6].into_iter().enumerate() {
                let label = gtk::Label::new(None);
                label.set_width_chars(width);
                label.set_xalign(0.);
                if index == 1 {
                    label.set_hexpand(true);
                    label.set_max_width_chars(30);
                    label.set_ellipsize(gtk::pango::EllipsizeMode::End);
                }
                row.append(&label);
                labels.push(label);
            }
            widget.set_child(Some(&row));
            self.list.append(&widget);
            rows.push(Row { widget, labels });
        }
        for (index, row) in rows.iter().enumerate() {
            let Some(process) = processes.get(index) else {
                row.widget.set_visible(false);
                continue;
            };
            row.widget.set_visible(true);
            let cpu = process
                .cpu_percent
                .map(|v| format!("{v:.1}"))
                .unwrap_or_else(|| "—".into());
            let uid = process
                .uid
                .map(|n| n.to_string())
                .unwrap_or_else(|| "—".into());
            let values = [
                process.pid.to_string(),
                process.name.clone(),
                uid,
                cpu,
                format!("{:.1}", process.rss_bytes as f64 / 1_048_576.),
                process.threads.to_string(),
                process.state.to_string(),
            ];
            for (label, value) in row.labels.iter().zip(&values) {
                label.set_text(value);
            }
            let summary = format!(
                "{} · PID {} · UID {} · CPU {} percent · {:.1} MiB resident · {} threads · state {}",
                process.name,
                process.pid,
                values[2],
                values[3],
                process.rss_bytes as f64 / 1_048_576.,
                process.threads,
                process.state
            );
            row.widget
                .update_property(&[gtk::accessible::Property::Label(&summary)]);
            row.widget.set_tooltip_text(Some(&format!("{summary}\nVirtual memory: {} bytes · nice {} · start ticks {}\nAn unavailable CPU value is waiting for a valid interval.",process.virtual_bytes,process.nice,process.start_ticks)));
        }
        self.shown.set(processes.len());
    }
    pub fn settled(&self) -> bool {
        !self.running.get()
            && self.completed.get() == self.revision.get()
            && self.source_completed.get() == self.source_revision.get()
    }
    pub fn row_count(&self) -> usize {
        self.shown.get()
    }
    pub fn status(&self) -> String {
        self.status.text().to_string()
    }
    pub fn snapshot(&self, path: &Path) -> Result<(), String> {
        save_snapshot(&self.window, &self.paintable, path)
    }
}
