// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Start with a ten-second cadence, then retime through real Preferences controls.
use super::{Shell, preferences::Dialog};
use gtk::prelude::*;
use std::{
    path::{Path, PathBuf},
    rc::Rc,
};
use xrg_ng_linux::settings::{Settings, Store};
pub(super) struct Harness {
    stage: u8,
    sequence: u64,
    expected: Option<Settings>,
    dialog: Option<Rc<Dialog>>,
}
fn require(value: bool, error: &str) -> Result<(), String> {
    if value { Ok(()) } else { Err(error.into()) }
}
impl Harness {
    pub fn new() -> Self {
        Self {
            stage: 0,
            sequence: 0,
            expected: None,
            dialog: None,
        }
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64, root: &Path) -> Result<bool, String> {
        let previous = self.stage;
        match self.stage {
            0 if sequence >= 1 => {
                let original = shell.settings.borrow().clone();
                require(
                    original.sampling_interval_ms == 10000,
                    "Saved startup sampling interval was lost",
                )?;
                let dialog = shell.preferences();
                require(
                    dialog.sampling.value_as_int() == 10000,
                    "Startup interval was not displayed",
                )?;
                dialog.sampling.set_value(375.);
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == original,
                    "Cancelled interval changed active settings",
                )?;
                let dialog = shell.preferences();
                dialog.sampling.set_value(375.);
                dialog.reset.emit_clicked();
                require(
                    dialog.sampling.value_as_int() == 1000 && *shell.settings.borrow() == original,
                    "Default sampling did not stay in the draft",
                )?;
                dialog.cancel.emit_clicked();
                let dialog = shell.preferences();
                dialog.sampling.set_value(250.);
                dialog.apply.emit_clicked();
                let mut expected = original;
                expected.sampling_interval_ms = 250;
                require(
                    *shell.settings.borrow() == expected,
                    "Sampling Apply changed sources or other settings",
                )?;
                self.expected = Some(expected);
                self.sequence = sequence;
                self.stage = 1;
            }
            1 if sequence >= self.sequence + 3
                && shell.saved_revision.get() == shell.revision.get() =>
            {
                let (_, loaded, error) = Store::open(Some(root.join("settings.conf")));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Fast sampling did not persist",
                )?;
                let dialog = shell.preferences();
                require(
                    dialog.sampling.value_as_int() == 250,
                    "Reopened interval differs",
                )?;
                dialog.sampling.grab_focus();
                self.dialog = Some(dialog);
                self.stage = 2;
            }
            2 => {
                let dialog = self.dialog.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_SAMPLING_PREFS_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                dialog.sampling.set_value(375.);
                dialog.apply.emit_clicked();
                self.expected.as_mut().unwrap().sampling_interval_ms = 375;
                require(
                    *shell.settings.borrow() == *self.expected.as_ref().unwrap(),
                    "Retime changed non-sampling preferences",
                )?;
                self.sequence = sequence;
                self.stage = 3;
            }
            3 if sequence > self.sequence && shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(root.join("settings.conf")));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Non-step interval did not persist",
                )?;
                self.stage = 4;
                return Ok(true);
            }
            4 => return Ok(true),
            _ => (),
        }
        if previous != self.stage {
            println!("GTK_SAMPLING_STAGE {}", self.stage);
        }
        Ok(false)
    }
}
