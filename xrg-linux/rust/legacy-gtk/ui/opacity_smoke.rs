// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Preference lifecycle against GTK's actual toplevel property, not a mock.
use super::{Shell, preferences::Dialog};
use gtk::prelude::*;
use std::{
    path::{Path, PathBuf},
    rc::Rc,
};
use xrg_ng_linux::settings::{Settings, Store};

pub(super) struct Harness {
    stage: u8,
    expected: Option<Settings>,
    dialog: Option<Rc<Dialog>>,
}
fn require(value: bool, message: &str) -> Result<(), String> {
    if value { Ok(()) } else { Err(message.into()) }
}
fn opacity(shell: &Shell, expected: f64) -> Result<(), String> {
    // GTK quantizes this property to 8 bits; this asserts the requested value,
    // not that an X11 compositing manager or a physical display is present.
    require(
        (shell.window.opacity() - expected).abs() <= 1. / 255. + f64::EPSILON,
        "GTK main window opacity differs from the active preference",
    )
}
impl Harness {
    pub fn new() -> Self {
        Self {
            stage: 0,
            expected: None,
            dialog: None,
        }
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64, root: &Path) -> Result<bool, String> {
        let before = self.stage;
        match self.stage {
            0 if sequence >= 1 => {
                let original = shell.settings.borrow().clone();
                require(
                    original.window_opacity == 0.65,
                    "Saved startup opacity was lost",
                )?;
                opacity(shell, 0.65)?;
                let dialog = shell.preferences();
                require(
                    dialog.opacity.value() == 65. && dialog.window.opacity() == 1.,
                    "Preferences did not show startup opacity or inherited dashboard transparency",
                )?;
                dialog.opacity.set_value(10.);
                opacity(shell, 0.65)?;
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == original,
                    "Cancel changed active settings",
                )?;
                let dialog = shell.preferences();
                dialog.opacity.set_value(10.);
                dialog.reset.emit_clicked();
                require(
                    dialog.opacity.value() == 100. && *shell.settings.borrow() == original,
                    "Defaults escaped the draft",
                )?;
                opacity(shell, 0.65)?;
                dialog.cancel.emit_clicked();
                let dialog = shell.preferences();
                dialog.opacity.set_value(10.);
                dialog.apply.emit_clicked();
                let mut expected = original;
                expected.window_opacity = 0.1;
                require(
                    *shell.settings.borrow() == expected,
                    "Opacity Apply changed other preferences",
                )?;
                opacity(shell, 0.1)?;
                self.expected = Some(expected);
                self.stage = 1;
            }
            1 if shell.saved_revision.get() == shell.revision.get() => {
                self.persisted(root)?;
                let dialog = shell.preferences();
                require(
                    dialog.opacity.value() == 10. && dialog.window.opacity() == 1.,
                    "Reopened opacity differs or Preferences is translucent",
                )?;
                dialog.opacity.set_value(42.5);
                dialog.opacity.grab_focus();
                self.dialog = Some(dialog);
                self.stage = 2;
            }
            2 => {
                let dialog = self.dialog.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_OPACITY_PREFS_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                dialog.apply.emit_clicked();
                self.expected.as_mut().unwrap().window_opacity = 0.425;
                require(
                    *shell.settings.borrow() == *self.expected.as_ref().unwrap(),
                    "Fractional opacity changed other preferences",
                )?;
                opacity(shell, 0.425)?;
                self.stage = 3;
            }
            3 if shell.saved_revision.get() == shell.revision.get() => {
                self.persisted(root)?;
                let dialog = shell.preferences();
                require(
                    dialog.opacity.value() == 42.5,
                    "Fractional opacity did not reopen",
                )?;
                dialog.reset.emit_clicked();
                dialog.apply.emit_clicked();
                self.expected = Some(Settings::default());
                require(
                    *shell.settings.borrow() == Settings::default(),
                    "Defaults did not apply",
                )?;
                opacity(shell, 1.)?;
                self.stage = 4;
            }
            4 if shell.saved_revision.get() == shell.revision.get() => {
                self.persisted(root)?;
                self.stage = 5;
                return Ok(true);
            }
            5 => return Ok(true),
            _ => (),
        }
        if before != self.stage {
            println!("GTK_OPACITY_STAGE {}", self.stage);
        }
        Ok(false)
    }
    fn persisted(&self, root: &Path) -> Result<(), String> {
        let (_, loaded, error) = Store::open(Some(root.join("settings.conf")));
        require(
            error.is_none() && loaded == *self.expected.as_ref().unwrap(),
            "Window opacity did not persist with the other preferences",
        )
    }
}
