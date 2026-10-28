// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Shell, save_snapshot};
use gtk::prelude::*;
use std::{
    cell::RefCell,
    path::{Path, PathBuf},
    rc::{Rc, Weak},
    sync::Arc,
};
use xrg_ng_linux::ai::{ClaudeSource, Preferences, Update};
const MODES: [ClaudeSource; 4] = [
    ClaudeSource::Auto,
    ClaudeSource::Logs,
    ClaudeSource::Database,
    ClaudeSource::Metrics,
];
pub(super) struct Window {
    pub window: gtk::Window,
    shell: Weak<Shell>,
    usage: gtk::TextView,
    pub enabled: Vec<gtk::CheckButton>,
    pub ollama: gtk::CheckButton,
    pub mode: gtk::DropDown,
    pub paths: Vec<gtk::Entry>,
    pub metrics: gtk::Entry,
    pub endpoint: gtk::Entry,
    pub apply: gtk::Button,
    pub cancel: gtk::Button,
    status: gtk::Label,
    pub tabs: gtk::Notebook,
    paintable: gtk::WidgetPaintable,
    last_report: RefCell<Option<(Arc<xrg_ng_linux::ai::Report>, bool)>>,
}
fn entry_row(form: &gtk::Box, title: &str, placeholder: &str) -> gtk::Entry {
    let row = gtk::Box::new(gtk::Orientation::Vertical, 4);
    let label = gtk::Label::new(Some(title));
    label.set_xalign(0.);
    row.append(&label);
    let entry = gtk::Entry::new();
    entry.set_hexpand(true);
    entry.set_max_length(4096);
    entry.set_placeholder_text(Some(placeholder));
    entry.update_property(&[gtk::accessible::Property::Label(title)]);
    row.append(&entry);
    form.append(&row);
    entry
}
impl Window {
    pub fn new(shell: &Rc<Shell>) -> Rc<Self> {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        content.set_margin_top(12);
        content.set_margin_bottom(12);
        content.set_margin_start(12);
        content.set_margin_end(12);
        let tabs = gtk::Notebook::new();
        tabs.set_vexpand(true);
        let usage = gtk::TextView::builder()
            .editable(false)
            .cursor_visible(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .build();
        usage.update_property(&[gtk::accessible::Property::Label(
            "AI provider usage and Ollama model details",
        )]);
        let scroll = gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&usage)
            .build();
        tabs.append_page(&scroll, Some(&gtk::Label::new(Some("Usage and models"))));
        let form = gtk::Box::new(gtk::Orientation::Vertical, 10);
        let note = gtk::Label::new(Some(
            "Sources are read-only and polled every 5 seconds. Blank paths use the defaults shown. Paths must be absolute. Local URLs accept HTTP loopback IP addresses only; no credentials or query strings. Apply resets token-rate history on the next AI poll.",
        ));
        note.set_wrap(true);
        note.set_xalign(0.);
        form.append(&note);
        let toggles = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let enabled: Vec<_> = ["Claude", "Codex", "Gemini", "Hermes"]
            .iter()
            .map(|name| {
                let check = gtk::CheckButton::with_label(name);
                toggles.append(&check);
                check
            })
            .collect();
        form.append(&toggles);
        let ollama = gtk::CheckButton::with_label("Poll Ollama model inventory");
        form.append(&ollama);
        let mode_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let mode_label = gtk::Label::new(Some("Claude source"));
        mode_label.set_hexpand(true);
        mode_label.set_xalign(0.);
        mode_row.append(&mode_label);
        let mode = gtk::DropDown::from_strings(&[
            "Auto · logs, database, metrics",
            "Logs only",
            "Database only",
            "Metrics only",
        ]);
        mode.update_property(&[gtk::accessible::Property::Label("Claude source priority")]);
        mode_row.append(&mode);
        form.append(&mode_row);
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_default();
        let defaults = Preferences::default().paths(&home);
        let paths = [
            "Claude projects directory",
            "Claude usage database",
            "Codex sessions directory",
            "Gemini temporary sessions directory",
            "Hermes state database",
        ]
        .iter()
        .zip(defaults)
        .map(|(name, path)| entry_row(&form, name, &path.to_string_lossy()))
        .collect();
        let metrics = entry_row(&form, "Claude metrics URL", "http://127.0.0.1:8889/metrics");
        let endpoint = entry_row(
            &form,
            "Ollama base URL (without /api/tags)",
            "http://127.0.0.1:11434",
        );
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&form)
            .build();
        tabs.append_page(&scroll, Some(&gtk::Label::new(Some("Sources"))));
        content.append(&tabs);
        let status = gtk::Label::new(Some(
            "Usage follows locally retained records, not account billing. Token breakdowns use recorded model names; Ollama lists are inventories, not token counters.",
        ));
        status.set_xalign(0.);
        status.set_wrap(true);
        content.append(&status);
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let defaults = gtk::Button::with_label("Default sources");
        actions.append(&defaults);
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        actions.append(&spacer);
        let cancel = gtk::Button::with_label("Close");
        actions.append(&cancel);
        let apply = gtk::Button::with_label("Apply sources");
        apply.add_css_class("suggested-action");
        actions.append(&apply);
        content.append(&actions);
        let window = gtk::Window::builder()
            .application(&shell.window.application().unwrap())
            .title("XRG-ng AI monitoring")
            .transient_for(&shell.window)
            .destroy_with_parent(true)
            .default_width(680)
            .default_height(780)
            .child(&content)
            .build();
        let paintable = gtk::WidgetPaintable::new(Some(&window));
        let result = Rc::new(Self {
            window,
            shell: Rc::downgrade(shell),
            usage,
            enabled,
            ollama,
            mode,
            paths,
            metrics,
            endpoint,
            apply,
            cancel,
            status,
            tabs,
            paintable,
            last_report: RefCell::new(None),
        });
        result.fill(&shell.settings.borrow().ai);
        result.update(
            None,
            &shell.settings.borrow().ai,
            shell.settings.borrow().ai_show_model_breakdown,
        );
        let weak = Rc::downgrade(&result);
        result.apply.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.apply_sources();
            }
        });
        let weak = Rc::downgrade(&result);
        defaults.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.fill(&Preferences::default());
                view.status
                    .set_text("Defaults loaded into this draft. Apply sources to keep them.");
            }
        });
        let weak = Rc::downgrade(&result);
        result.cancel.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.window.close();
            }
        });
        let weak = Rc::downgrade(&result);
        result.window.connect_close_request(move |_| {
            if let Some(view) = weak.upgrade()
                && let Some(shell) = view.shell.upgrade()
            {
                shell.ai_window.borrow_mut().take();
            }
            gtk::glib::Propagation::Proceed
        });
        result
    }
    fn fill(&self, preferences: &Preferences) {
        for (check, value) in self.enabled.iter().zip(preferences.enabled) {
            check.set_active(value);
        }
        self.ollama.set_active(preferences.ollama);
        self.mode.set_selected(
            MODES
                .iter()
                .position(|m| *m == preferences.claude_source)
                .unwrap() as u32,
        );
        for (entry, path) in self.paths.iter().zip([
            &preferences.claude_logs,
            &preferences.claude_database,
            &preferences.codex_logs,
            &preferences.gemini_logs,
            &preferences.hermes_database,
        ]) {
            entry.set_text(path.as_ref().map_or("", |p| p.to_str().unwrap_or("")));
        }
        self.metrics.set_text(&preferences.metrics_url);
        self.endpoint.set_text(&preferences.ollama_url);
    }
    fn draft(&self) -> Result<Preferences, String> {
        let path = |index: usize| {
            let value = self.paths[index].text();
            if value.is_empty() {
                None
            } else {
                Some(PathBuf::from(value.as_str()))
            }
        };
        let preferences = Preferences {
            enabled: std::array::from_fn(|i| self.enabled[i].is_active()),
            ollama: self.ollama.is_active(),
            claude_source: *MODES
                .get(self.mode.selected() as usize)
                .ok_or("Choose a Claude source")?,
            claude_logs: path(0),
            claude_database: path(1),
            codex_logs: path(2),
            gemini_logs: path(3),
            hermes_database: path(4),
            metrics_url: self.metrics.text().to_string(),
            ollama_url: self.endpoint.text().to_string(),
        };
        preferences.validate()?;
        Ok(preferences)
    }
    fn apply_sources(&self) {
        match self.draft() {
            Err(error) => self.status.set_text(&error),
            Ok(preferences) => {
                if let Some(shell) = self.shell.upgrade() {
                    let mut settings = shell.settings.borrow().clone();
                    settings.ai = preferences;
                    shell.apply(settings);
                    self.update(
                        shell.state.borrow().as_ref().and_then(|s| s.ai.as_ref()),
                        &shell.settings.borrow().ai,
                        shell.settings.borrow().ai_show_model_breakdown,
                    );
                    self.status.set_text("Sources applied. Saving status appears in the main window. The AI worker updates on its next poll.");
                }
            }
        }
    }
    pub fn update(&self, update: Option<&Update>, active: &Preferences, show_models: bool) {
        if let Some(update) = update.filter(|u| &u.preferences == active) {
            if self
                .last_report
                .borrow()
                .as_ref()
                .is_some_and(|(old, shown)| {
                    Arc::ptr_eq(old, &update.report) && *shown == show_models
                })
            {
                return;
            }
            *self.last_report.borrow_mut() = Some((update.report.clone(), show_models));
            self.usage.buffer().set_text(update.detail_for(show_models));
        } else if self.last_report.borrow_mut().take().is_some()
            || self.usage.buffer().char_count() == 0
        {
            self.usage
                .buffer()
                .set_text("Waiting for the AI worker to sample the active sources.");
        }
    }
    pub fn status(&self) -> String {
        self.status.text().to_string()
    }
    pub fn usage_text(&self) -> String {
        let buffer = self.usage.buffer();
        buffer
            .text(&buffer.start_iter(), &buffer.end_iter(), false)
            .to_string()
    }
    pub fn snapshot(&self, path: &Path) -> Result<(), String> {
        save_snapshot(&self.window, &self.paintable, path)
    }
}
