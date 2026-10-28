// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Policy round trip on live proc + custom sysfs; never opens host DRM/perf.
use super::{Shell, preferences::Dialog};
use gtk::prelude::*;
use std::{
    cell::Cell,
    path::{Path, PathBuf},
    rc::Rc,
    time::{Duration, Instant},
};
use xrg_ng_linux::settings::{Settings, Store};
pub(super) struct Harness {
    stage: u8,
    sequence: u64,
    changed: Instant,
    frames: Rc<Cell<u8>>,
    expected: Option<Settings>,
    dialog: Option<Rc<Dialog>>,
}
fn require(value: bool, message: &str) -> Result<(), String> {
    if value { Ok(()) } else { Err(message.into()) }
}
impl Harness {
    pub fn new() -> Self {
        Self {
            stage: 0,
            sequence: 0,
            changed: Instant::now(),
            frames: Rc::new(Cell::new(0)),
            expected: None,
            dialog: None,
        }
    }
    fn frames(&self, dialog: &Dialog) {
        self.frames.set(0);
        let frames = self.frames.clone();
        dialog.window.add_tick_callback(move |_, _| {
            frames.set(frames.get() + 1);
            if frames.get() >= 3 {
                gtk::glib::ControlFlow::Break
            } else {
                gtk::glib::ControlFlow::Continue
            }
        });
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64, root: &Path) -> Result<bool, String> {
        if matches!(self.stage, 1 | 4) && self.changed.elapsed() > Duration::from_secs(3) {
            return Err("Xe policy update did not wake the ten-second system wait".into());
        }
        let previous = self.stage;
        match self.stage {
            0 if sequence >= 1 => {
                let original = shell.settings.borrow().clone();
                require(
                    !original.metrics.xe_pmu && original.sampling_interval_ms == 10000,
                    "Xe PMU did not start opt-out with the saved cadence",
                )?;
                let d = shell.preferences();
                d.targets.xe_pmu.set_active(true);
                d.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == original,
                    "Cancelled Xe power policy became active",
                )?;
                let d = shell.preferences();
                d.targets.xe_pmu.set_active(true);
                d.reset.emit_clicked();
                require(
                    !d.targets.xe_pmu.is_active() && *shell.settings.borrow() == original,
                    "Xe default policy escaped the draft",
                )?;
                d.cancel.emit_clicked();
                let d = shell.preferences();
                d.targets.xe_pmu.set_active(true);
                d.apply.emit_clicked();
                let mut expected = original;
                expected.metrics.xe_pmu = true;
                require(
                    *shell.settings.borrow() == expected,
                    "Xe policy Apply changed other settings",
                )?;
                self.expected = Some(expected);
                self.sequence = sequence;
                self.changed = Instant::now();
                self.stage = 1;
            }
            1 if sequence > self.sequence
                && shell
                    .state
                    .borrow()
                    .as_ref()
                    .is_some_and(|s| s.selection.xe_pmu)
                && shell.saved_revision.get() == shell.revision.get() =>
            {
                self.persisted(root)?;
                let d = shell.preferences();
                require(
                    d.targets.xe_pmu.is_active(),
                    "Saved Xe policy did not reopen",
                )?;
                d.targets
                    .refresh(&shell.inventory(), &self.expected.as_ref().unwrap().metrics);
                require(
                    d.targets.xe_pmu.is_active() && d.draft().metrics.xe_pmu,
                    "Inventory refresh discarded Xe policy",
                )?;
                self.frames(&d);
                self.dialog = Some(d);
                self.stage = 2;
            }
            2 if self.frames.get() >= 3 => {
                let d = self.dialog.as_ref().unwrap();
                d.reveal_xe_policy();
                self.frames(d);
                self.stage = 3;
            }
            3 if self.frames.get() >= 3 => {
                let d = self.dialog.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_XE_PREFS_IMAGE") {
                    d.snapshot(&PathBuf::from(path))?;
                }
                d.targets.xe_pmu.set_active(false);
                d.apply.emit_clicked();
                self.expected.as_mut().unwrap().metrics.xe_pmu = false;
                require(
                    *shell.settings.borrow() == *self.expected.as_ref().unwrap(),
                    "Disabling Xe policy changed other preferences",
                )?;
                self.sequence = sequence;
                self.changed = Instant::now();
                self.stage = 4;
            }
            4 if sequence > self.sequence
                && shell
                    .state
                    .borrow()
                    .as_ref()
                    .is_some_and(|s| !s.selection.xe_pmu)
                && shell.saved_revision.get() == shell.revision.get() =>
            {
                self.persisted(root)?;
                self.stage = 5;
                return Ok(true);
            }
            5 => {
                // At a ten-second cadence, explicitly exercise cached drawing
                // after Preferences closes. Keep the outer three-draw gate.
                for area in &shell.areas {
                    area.queue_draw();
                }
                return Ok(true);
            }
            _ => (),
        }
        if previous != self.stage {
            println!("GTK_XE_POLICY_STAGE {}", self.stage);
        }
        Ok(false)
    }
    fn persisted(&self, root: &Path) -> Result<(), String> {
        let (_, loaded, error) = Store::open(Some(root.join("settings.conf")));
        require(
            error.is_none() && loaded == *self.expected.as_ref().unwrap(),
            "Xe policy did not persist exactly",
        )
    }
}
