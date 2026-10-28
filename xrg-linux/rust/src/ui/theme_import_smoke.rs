// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Dedicated GTK gate; fixture theme input, real draft and persistence paths.
use super::{Shell, preferences::Dialog};
use gtk::prelude::*;
use std::{fs, path::Path, rc::Rc};
use xrg_ng_linux::settings::{Settings, Store, ThemeChoice, ThemeDocument};
const CLASSIC: &[u8] = include_bytes!("../../../../XRGTests/Fixtures/ClassicTheme.xtf");
pub(super) struct Harness {
    stage: u8,
    dialog: Option<Rc<Dialog>>,
    original: Option<Settings>,
    expected: Option<Settings>,
}
fn require(value: bool, message: &str) -> Result<(), String> {
    if value { Ok(()) } else { Err(message.into()) }
}
impl Harness {
    pub fn new() -> Self {
        Self {
            stage: 0,
            dialog: None,
            original: None,
            expected: None,
        }
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64, root: &Path) -> Result<bool, String> {
        if self.dialog.as_ref().is_some_and(|d| d.is_busy()) {
            return Ok(false);
        }
        let previous = self.stage;
        match self.stage {
            0 if sequence >= 2 => {
                fs::write(root.join("Classic.xtf"), CLASSIC).map_err(|e| e.to_string())?;
                fs::write(root.join("broken.xtf"), b"bplist00broken").map_err(|e| e.to_string())?;
                self.original = Some(shell.settings.borrow().clone());
                let dialog = shell.preferences();
                let mut expected = dialog.draft();
                expected.theme = ThemeChoice::Custom {
                    theme: Box::new(ThemeDocument::parse(CLASSIC)?),
                };
                self.expected = Some(expected);
                dialog.load_theme(root.join("Classic.xtf"));
                self.dialog = Some(dialog);
                self.stage = 1;
            }
            1 => {
                let dialog = self.dialog.take().unwrap();
                require(
                    dialog.draft() == *self.expected.as_ref().unwrap(),
                    "XTF import changed non-theme draft settings or lost colors",
                )?;
                require(
                    *shell.settings.borrow() == *self.original.as_ref().unwrap(),
                    "XTF load changed active settings before Apply",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == *self.original.as_ref().unwrap(),
                    "XTF Cancel changed active settings",
                )?;
                let dialog = shell.preferences();
                dialog.load_theme(root.join("Classic.xtf"));
                self.dialog = Some(dialog);
                self.stage = 2;
            }
            2 => {
                let dialog = self.dialog.as_ref().unwrap();
                require(
                    dialog.draft() == *self.expected.as_ref().unwrap(),
                    "XTF reload differs",
                )?;
                dialog.save_theme(root.join("converted.xrg-theme.json"));
                self.stage = 3;
            }
            3 => {
                let dialog = self.dialog.take().unwrap();
                require(
                    ThemeDocument::load(&root.join("converted.xrg-theme.json"))?
                        == ThemeDocument::parse(CLASSIC)?,
                    "XTF JSON export changed colors or alpha",
                )?;
                dialog.apply.emit_clicked();
                self.stage = 4;
            }
            4 if shell.saved_revision.get() == shell.revision.get() && shell.revision.get() > 0 => {
                let expected = self.expected.as_ref().unwrap();
                require(
                    *shell.settings.borrow() == *expected,
                    "XTF Apply changed palette or other preferences",
                )?;
                let (_, loaded, error) = Store::open(Some(root.join("settings.conf")));
                require(
                    error.is_none() && loaded == *expected,
                    "XTF palette did not survive saved-settings reopen",
                )?;
                let dialog = shell.preferences();
                dialog.load_theme(root.join("broken.xtf"));
                self.dialog = Some(dialog);
                self.stage = 5;
            }
            5 => {
                let dialog = self.dialog.take().unwrap();
                require(
                    dialog.draft() == *self.expected.as_ref().unwrap(),
                    "Malformed XTF changed the draft",
                )?;
                require(
                    dialog.message().contains("could not be loaded"),
                    "Malformed XTF did not report an error",
                )?;
                require(
                    fs::read(root.join("Classic.xtf")).map_err(|e| e.to_string())? == CLASSIC,
                    "XTF import changed its source file",
                )?;
                dialog.cancel.emit_clicked();
                return Ok(true);
            }
            _ => (),
        }
        if previous != self.stage {
            println!("GTK_XTF_THEME_STAGE {}", self.stage);
        }
        Ok(false)
    }
}
