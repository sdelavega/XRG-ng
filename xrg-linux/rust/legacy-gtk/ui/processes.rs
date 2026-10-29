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
    process::{
        Listing, Process, Report, Sort,
        control::{self, Action, Target},
    },
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
    pub list: gtk::ListBox,
    column_sizes: Vec<gtk::SizeGroup>,
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
    displayed: RefCell<Vec<Process>>,
    selected: RefCell<Option<Process>>,
    selecting: Cell<bool>,
    action_busy: Cell<bool>,
    pub actions: [gtk::Button; 4],
    pub details_button: gtk::Button,
    details: RefCell<Vec<Rc<super::process_details::Window>>>,
    selection: gtk::Label,
    action_status: gtk::Label,
    context: RefCell<Option<gtk::PopoverMenu>>,
    context_paintable: RefCell<Option<gtk::WidgetPaintable>>,
    pending: RefCell<Option<Rc<super::process_actions::Confirmation>>>,
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
        header.set_margin_start(2);
        header.set_margin_end(2);
        let column_sizes: Vec<_> = (0..7)
            .map(|_| gtk::SizeGroup::new(gtk::SizeGroupMode::Horizontal))
            .collect();
        for (index, (title, width)) in [
            ("PID", 8),
            ("Name", 24),
            ("UID", 10),
            ("CPU %", 9),
            ("RSS MiB", 11),
            ("Threads", 7),
            ("State", 6),
        ]
        .into_iter()
        .enumerate()
        {
            let label = gtk::Label::new(Some(title));
            label.set_width_chars(width);
            label.set_xalign(0.);
            if title == "Name" {
                label.set_hexpand(true);
            }
            label.add_css_class("heading");
            column_sizes[index].add_widget(&label);
            header.append(&label);
        }
        content.append(&header);
        let list = gtk::ListBox::new();
        list.set_selection_mode(gtk::SelectionMode::Single);
        list.add_css_class("boxed-list");
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Automatic)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .vexpand(true)
            .child(&list)
            .build();
        content.append(&scroll);
        let selection = gtk::Label::new(Some("Select a process to manage it."));
        selection.set_xalign(0.);
        selection.set_wrap(true);
        content.append(&selection);
        let action_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let actions = Action::ALL.map(|action| {
            let button = gtk::Button::with_label(action.name());
            button.set_sensitive(false);
            button.set_tooltip_text(Some(action.explanation()));
            action_row.append(&button);
            button
        });
        let details_button = gtk::Button::with_label("Details…");
        details_button.set_sensitive(false);
        action_row.prepend(&details_button);
        content.append(&action_row);
        let action_status = gtk::Label::new(None);
        action_status.set_xalign(0.);
        action_status.set_wrap(true);
        action_status.set_visible(false);
        content.append(&action_status);
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
            .default_height(660)
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
            column_sizes,
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
            displayed: RefCell::new(Vec::new()),
            selected: RefCell::new(None),
            selecting: Cell::new(false),
            action_busy: Cell::new(false),
            actions,
            details_button,
            details: RefCell::new(Vec::new()),
            selection,
            action_status,
            context: RefCell::new(None),
            context_paintable: RefCell::new(None),
            pending: RefCell::new(None),
        });
        let weak = Rc::downgrade(&result);
        result.list.connect_row_selected(move |_, row| {
            if let Some(window) = weak.upgrade()
                && !window.selecting.get()
            {
                *window.selected.borrow_mut() =
                    row.and_then(|r| window.displayed.borrow().get(r.index() as usize).cloned());
                window.update_actions();
            }
        });
        let weak = Rc::downgrade(&result);
        result.details_button.connect_clicked(move |_| {
            if let Some(window) = weak.upgrade() {
                let process = window.selected.borrow().clone();
                if let Some(process) = process {
                    window.open_details(process);
                }
            }
        });
        let weak = Rc::downgrade(&result);
        result.list.connect_row_activated(move |_, row| {
            if let Some(window) = weak.upgrade() {
                let process = window.displayed.borrow().get(row.index() as usize).cloned();
                if let Some(process) = process {
                    window.open_details(process);
                }
            }
        });
        for (button, action) in result.actions.iter().zip(Action::ALL) {
            let weak = Rc::downgrade(&result);
            button.connect_clicked(move |_| {
                if let Some(window) = weak.upgrade()
                    && let Some(process) = window.selected.borrow().clone()
                {
                    window.begin_action(process, action);
                }
            });
        }
        let click = gtk::GestureClick::new();
        click.set_button(3);
        let weak = Rc::downgrade(&result);
        click.connect_pressed(move |_, _, x, y| {
            if let Some(window) = weak.upgrade()
                && let Some(row) = window.list.row_at_y(y as i32)
            {
                window.list.select_row(Some(&row));
                window.popup(x as i32, y as i32);
            }
        });
        result.list.add_controller(click);
        let keys = gtk::EventControllerKey::new();
        let weak = Rc::downgrade(&result);
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            if (key == gtk::gdk::Key::Menu
                || (key == gtk::gdk::Key::F10
                    && modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK)))
                && let Some(window) = weak.upgrade()
                && let Some(row) = window.list.selected_row()
            {
                window.popup(12, row.allocation().y() + row.height() / 2);
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        result.list.add_controller(keys);
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
                window.close_context();
                let details = window.details.borrow().clone();
                for detail in details {
                    detail.window.close();
                }
                let pending = window.pending.borrow().clone();
                if let Some(dialog) = pending {
                    dialog.window.close();
                }
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
        for detail in self.details.borrow().iter() {
            detail.update(report);
        }
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
        self.selecting.set(true);
        let prior = self.selected.borrow().clone();
        self.list.unselect_all();
        *self.displayed.borrow_mut() = processes.to_vec();
        let mut rows = self.rows.borrow_mut();
        while rows.len() < processes.len() {
            let widget = gtk::ListBoxRow::new();
            widget.set_activatable(true);
            widget.set_selectable(true);
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
                self.column_sizes[index].add_widget(&label);
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
        let selected = prior.and_then(|old| processes.iter().position(|p| p.same_instance(&old)));
        *self.selected.borrow_mut() = selected.map(|i| processes[i].clone());
        if let Some(i) = selected {
            self.list.select_row(Some(&rows[i].widget));
        }
        self.selecting.set(false);
        self.update_actions();
    }
    fn update_actions(&self) {
        let selected = self.selected.borrow();
        self.details_button.set_sensitive(selected.is_some());
        for (button, action) in self.actions.iter().zip(Action::ALL) {
            button.set_sensitive(
                !self.action_busy.get() && selected.as_ref().is_some_and(|p| action.enabled(p)),
            );
        }
        self.selection.set_text(
            &selected
                .as_ref()
                .map(|p| {
                    let identity = format!(
                        "{} · PID {} · UID {}",
                        p.name,
                        p.pid,
                        p.uid.map_or("unknown".into(), |u| u.to_string())
                    );
                    match control::eligible(p) {
                        Ok(()) => identity,
                        Err(error) => format!("{identity}\n{error}"),
                    }
                })
                .unwrap_or_else(|| "Select a process to manage it.".into()),
        );
    }
    fn begin_action(self: &Rc<Self>, process: Process, action: Action) {
        if self.closed.get() || self.action_busy.get() || !action.enabled(&process) {
            return;
        }
        self.action_busy.set(true);
        self.update_actions();
        self.action_status.set_text("Checking selected process…");
        self.action_status.set_visible(true);
        let task = gio::spawn_blocking(move || Target::prepare(&process));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = task
                .await
                .unwrap_or_else(|_| Err("Process identity check stopped unexpectedly".into()));
            let Some(window) = weak.upgrade() else {
                return;
            };
            if window.closed.get() {
                return;
            }
            match result {
                Err(error) => {
                    window.action_busy.set(false);
                    window.action_status.set_text(&error);
                    window.update_actions();
                }
                Ok(target) => {
                    let summary = format!(
                        "{} sent to {} (PID {}).",
                        action.name(),
                        target.process().name,
                        target.process().pid
                    );
                    let weak = Rc::downgrade(&window);
                    let dialog = super::process_actions::Confirmation::new(
                        &window.window,
                        target,
                        action,
                        move |result| {
                            if let Some(window) = weak.upgrade() {
                                window.pending.borrow_mut().take();
                                window.action_busy.set(false);
                                if !window.closed.get() {
                                    window.action_status.set_text(&match result {
                                        super::process_actions::Outcome::Cancelled => {
                                            "Process action cancelled; no signal sent.".into()
                                        }
                                        super::process_actions::Outcome::Sent => summary.clone(),
                                        super::process_actions::Outcome::Failed(error) => error,
                                    });
                                    window.update_actions();
                                }
                            }
                        },
                    );
                    *window.pending.borrow_mut() = Some(dialog);
                }
            }
        });
    }
    pub fn popup(self: &Rc<Self>, x: i32, y: i32) {
        let Some(process) = self.selected.borrow().clone() else {
            return;
        };
        let group = gio::SimpleActionGroup::new();
        let entries = gio::Menu::new();
        let details_action = gio::SimpleAction::new("details", None);
        let weak = Rc::downgrade(self);
        let captured = process.clone();
        details_action.connect_activate(move |_, _| {
            if let Some(window) = weak.upgrade() {
                window.open_details(captured.clone());
            }
        });
        group.add_action(&details_action);
        entries.append(Some("Details…"), Some("process.details"));
        for action in Action::ALL {
            let item = gio::SimpleAction::new(action.id(), None);
            item.set_enabled(!self.action_busy.get() && action.enabled(&process));
            let weak = Rc::downgrade(self);
            let process = process.clone();
            item.connect_activate(move |_, _| {
                if let Some(window) = weak.upgrade() {
                    window.begin_action(process.clone(), action);
                }
            });
            group.add_action(&item);
            entries.append(
                Some(action.name()),
                Some(&format!("process.{}", action.id())),
            );
        }
        let menu = gio::Menu::new();
        menu.append_section(
            Some(&format!("{} · PID {}", process.name, process.pid)),
            &entries,
        );
        if let Some(old) = self.context.borrow_mut().take() {
            old.popdown();
            if old.parent().is_some() {
                old.unparent();
            }
        }
        let Some(row) = self.list.selected_row() else {
            return;
        };
        let popover = gtk::PopoverMenu::from_model(Some(&menu));
        popover.set_has_arrow(false);
        popover.set_parent(&row);
        popover.insert_action_group("process", Some(&group));
        popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(
            x,
            y - row.allocation().y(),
            1,
            1,
        )));
        popover.connect_closed(|p| {
            if p.parent().is_some() {
                p.unparent();
            }
        });
        popover.popup();
        popover.present();
        *self.context_paintable.borrow_mut() = Some(gtk::WidgetPaintable::new(Some(&popover)));
        *self.context.borrow_mut() = Some(popover);
    }
    pub fn open_details(
        self: &Rc<Self>,
        process: Process,
    ) -> Option<Rc<super::process_details::Window>> {
        if self.closed.get() {
            return None;
        }
        if let Some(detail) = self
            .details
            .borrow()
            .iter()
            .find(|d| d.matches(&process))
            .cloned()
        {
            detail.window.present();
            return Some(detail);
        }
        if self.details.borrow().len() >= 8 {
            self.action_status
                .set_text("Close a process details window before opening another (maximum eight).");
            self.action_status.set_visible(true);
            return None;
        }
        let detail = super::process_details::Window::new(&self.window, process);
        let report = self
            .source
            .borrow()
            .clone()
            .ok_or_else(|| "Waiting for process data".to_owned());
        detail.update(&report);
        self.details.borrow_mut().push(detail.clone());
        let weak = Rc::downgrade(self);
        let child = Rc::downgrade(&detail);
        detail.window.connect_close_request(move |_| {
            if let Some(window) = weak.upgrade()
                && let Some(child) = child.upgrade()
            {
                window
                    .details
                    .borrow_mut()
                    .retain(|d| !Rc::ptr_eq(d, &child));
            }
            glib::Propagation::Proceed
        });
        detail.window.present();
        Some(detail)
    }
    pub fn detail_windows(&self) -> Vec<Rc<super::process_details::Window>> {
        self.details.borrow().clone()
    }
    pub fn activate_context_details(&self) -> Result<(), String> {
        self.context
            .borrow()
            .as_ref()
            .ok_or("Process menu missing")?
            .activate_action("process.details", None)
            .map_err(|e| e.to_string())
    }
    pub fn activate_context(&self, action: Action) -> Result<(), String> {
        self.context
            .borrow()
            .as_ref()
            .ok_or("Process menu missing")?
            .activate_action(&format!("process.{}", action.id()), None)
            .map_err(|e| e.to_string())
    }
    pub fn close_context(&self) {
        if let Some(popover) = self.context.borrow().as_ref() {
            popover.popdown();
        }
    }
    pub fn snapshot_context(&self, path: &Path) -> Result<(), String> {
        let context = self.context.borrow();
        let context = context.as_ref().ok_or("Process menu missing")?;
        if context.width() == 0 || context.height() == 0 || !context.is_mapped() {
            return Err("Process menu is not mapped or has no layout".into());
        }
        save_snapshot(
            context,
            self.context_paintable
                .borrow()
                .as_ref()
                .ok_or("Menu paintable missing")?,
            path,
        )
    }
    pub fn select_pid(&self, pid: u32) -> bool {
        if let Some(index) = self.displayed.borrow().iter().position(|p| p.pid == pid) {
            self.list
                .select_row(self.list.row_at_index(index as i32).as_ref());
            return true;
        }
        false
    }
    pub fn selected_pid(&self) -> Option<u32> {
        self.selected.borrow().as_ref().map(|p| p.pid)
    }
    pub fn confirmation(&self) -> Option<Rc<super::process_actions::Confirmation>> {
        self.pending.borrow().clone()
    }
    pub fn action_message(&self) -> String {
        self.action_status.text().to_string()
    }
    pub fn busy(&self) -> bool {
        self.action_busy.get()
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
