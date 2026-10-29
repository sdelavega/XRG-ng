// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Details are read-only. Test reports are explicitly labeled where synthesized.
use super::{Shell, process_details, processes};
use gtk::prelude::*;
use std::{
    path::PathBuf,
    rc::Rc,
    sync::Arc,
    time::{Duration, Instant},
};
use xrg_ng_linux::{
    process::{Process, Report},
    settings::ProcessView,
};
pub(super) struct Harness {
    stage: u8,
    injected_stage: Option<u8>,
    since: Instant,
    window: Option<Rc<processes::Window>>,
    detail: Option<Rc<process_details::Window>>,
    target: Option<Process>,
    other: Option<Process>,
}
fn require(value: bool, error: &str) -> Result<(), String> {
    if value { Ok(()) } else { Err(error.into()) }
}
fn report(processes: Vec<Process>, partial: bool) -> Result<Arc<Report>, String> {
    Ok(Arc::new(Report {
        discovered: processes.len() + usize::from(partial),
        attempted: processes.len(),
        processes,
        vanished: 0,
        unreadable: usize::from(partial),
        errors: Vec::new(),
    }))
}
impl Harness {
    pub fn new() -> Self {
        Self {
            stage: 0,
            injected_stage: None,
            since: Instant::now(),
            window: None,
            detail: None,
            target: None,
            other: None,
        }
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64) -> Result<bool, String> {
        let before = self.stage;
        // Pin this mode to controlled copied reports once the initial live frame
        // has been captured; ordinary sampler scans remain independent.
        if let Some(window) = &self.window
            && let Some(target) = &self.target
            && (!matches!(self.stage, 1 | 3) || self.injected_stage != Some(self.stage))
        {
            let mut target = target.clone();
            target.name = "Details fixture (this app)".into();
            let mut rows = vec![target];
            if let Some(other) = &self.other {
                rows.push(other.clone());
            }
            let next = match self.stage {
                0..=3 => report(rows, false),
                4 => report(Vec::new(), true),
                5 => Err("Fixture: proc scan unavailable".into()),
                6 => {
                    rows[0].start_ticks += 1;
                    report(rows, false)
                }
                _ => report(rows, false),
            };
            window.update(&next);
            self.injected_stage = Some(self.stage);
        }
        match self.stage {
            0 if sequence >= 2 => {
                let state = shell.state.borrow();
                let processes = state
                    .as_ref()
                    .ok_or("No snapshot")?
                    .processes
                    .as_ref()
                    .map_err(Clone::clone)?;
                let target = processes
                    .processes
                    .iter()
                    .find(|p| p.pid == std::process::id())
                    .ok_or("Own process missing")?
                    .clone();
                let mut other = target.clone();
                other.pid = if target.pid == 1 { 2 } else { 1 };
                other.name = "Other row fixture".into();
                other.start_ticks += 1;
                drop(state);
                let window = shell.processes();
                window.set_view(ProcessView::default());
                self.target = Some(target);
                self.other = Some(other);
                self.window = Some(window);
                self.stage = 1;
            }
            1 if self.window.as_ref().unwrap().settled() => {
                let window = self.window.as_ref().unwrap();
                let target = self.target.as_ref().unwrap();
                require(
                    window.select_pid(target.pid),
                    "Details target not selectable",
                )?;
                require(
                    window.details_button.is_sensitive()
                        && window.actions.iter().all(|b| !b.is_sensitive()),
                    "Self inspection was blocked by signal eligibility",
                )?;
                window.details_button.emit_clicked();
                let detail = window
                    .detail_windows()
                    .into_iter()
                    .next()
                    .ok_or("Details button did not open a window")?;
                require(
                    detail.text().contains("Parent PID:")
                        && detail.text().contains("Lifetime CPU time:")
                        && detail.text().contains("Kernel priority:"),
                    "Process inspector missed stat readings",
                )?;
                self.detail = Some(detail);
                self.stage = 2;
            }
            2 if self.since.elapsed() > Duration::from_millis(250) => {
                let window = self.window.as_ref().unwrap();
                let target = self.target.as_ref().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_PROCESS_DETAILS_IMAGE") {
                    self.detail
                        .as_ref()
                        .unwrap()
                        .snapshot(&PathBuf::from(path))?;
                }
                require(window.select_pid(target.pid), "Details target lost")?;
                window.popup(8, 8);
                window.select_pid(self.other.as_ref().unwrap().pid);
                window.activate_context_details()?;
                window.close_context();
                require(
                    window.detail_windows().len() == 1,
                    "Frozen details menu retargeted after selection changed",
                )?;
                // Activation uses the row that was activated, not any later selection.
                window.select_pid(target.pid);
                let row = window.list.selected_row().unwrap();
                window.list.emit_by_name::<()>("row-activated", &[&row]);
                require(
                    window.detail_windows().len() == 1,
                    "Row activation duplicated the inspector",
                )?;
                // Constrain the inspector and scroll before the next updates;
                // freshness must remain visible and updates must not jump to top.
                self.detail
                    .as_ref()
                    .unwrap()
                    .window
                    .set_default_size(640, 400);
                window.filter.set_text("no row can match this fixture");
                self.stage = 3;
            }
            3 if self.window.as_ref().unwrap().settled() => {
                let window = self.window.as_ref().unwrap();
                require(
                    window.row_count() == 0
                        && self
                            .detail
                            .as_ref()
                            .unwrap()
                            .text()
                            .contains("Live · latest readable"),
                    "Filtering retargeted or stopped the inspector",
                )?;
                let detail = self.detail.as_ref().unwrap();
                let adjustment = detail.scroll.vadjustment();
                require(
                    adjustment.upper() > adjustment.page_size() + 40.,
                    "Inspector fixture has no scroll range",
                )?;
                adjustment.set_value(40.);
                self.stage = 4;
            }
            4 if self.since.elapsed() > Duration::from_millis(250) => {
                require(
                    self.detail.as_ref().unwrap().scroll.vadjustment().value() > 10.,
                    "Live inspector refresh reset the scroll position",
                )?;
                require(
                    self.detail
                        .as_ref()
                        .unwrap()
                        .text()
                        .contains("Not found in a partial scan"),
                    "Missing partial data looked current",
                )?;
                self.stage = 5;
            }
            5 if self.since.elapsed() > Duration::from_millis(250) => {
                require(
                    self.detail
                        .as_ref()
                        .unwrap()
                        .text()
                        .contains("Process data unavailable"),
                    "Failed process scan looked current",
                )?;
                self.stage = 6;
            }
            6 if self.since.elapsed() > Duration::from_millis(250) => {
                let detail = self.detail.as_ref().unwrap();
                require(
                    detail.text().contains("Process identity changed"),
                    "PID reuse was not stopped",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_PROCESS_DETAILS_STALE_IMAGE") {
                    detail.snapshot(&PathBuf::from(path))?;
                }
                self.stage = 7;
            }
            7 if self.since.elapsed() > Duration::from_millis(250) => {
                let detail = self.detail.as_ref().unwrap();
                require(
                    detail.text().contains("Process identity changed"),
                    "Delayed old report reactivated a replaced PID",
                )?;
                self.window.as_ref().unwrap().window.close();
                require(
                    !detail.window.is_visible(),
                    "Process inspector survived parent close",
                )?;
                return Ok(true);
            }
            _ => (),
        }
        if self.stage != before {
            self.since = Instant::now();
            eprintln!("GTK_PROCESS_DETAILS_STAGE {}", self.stage);
        }
        Ok(false)
    }
}
