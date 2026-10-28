// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Dedicated GTK gate; fixture theme input, real draft and persistence paths.
use super::{Shell, preferences::Dialog};
use gtk::prelude::*;
use std::{fs, path::Path, rc::Rc};
use xrg_ng_linux::settings::{Settings, Store, ThemeChoice, ThemeDocument};
const CLASSIC: &[u8] = include_bytes!("../../../../XRGTests/Fixtures/ClassicTheme.xtf");
const P3: &[u8] = include_bytes!("../../tests/fixtures/DisplayP3.xtf");
const SRGB: &[u8] = include_bytes!("../../tests/fixtures/ModernSRGB.xtf");
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
                fs::write(root.join("ModernSRGB.xtf"), SRGB).map_err(|e| e.to_string())?;
                fs::write(root.join("DisplayP3.xtf"), P3).map_err(|e| e.to_string())?;
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
                let mut expected = dialog.draft();
                expected.theme = ThemeChoice::Custom {
                    theme: Box::new(ThemeDocument::parse(SRGB)?),
                };
                self.expected = Some(expected);
                dialog.load_theme(root.join("ModernSRGB.xtf"));
                self.dialog = Some(dialog);
                self.stage = 2;
            }
            2 => {
                let dialog = self.dialog.as_ref().unwrap();
                require(
                    dialog.draft() == *self.expected.as_ref().unwrap(),
                    "Modern sRGB XTF import differs",
                )?;
                dialog.save_theme(root.join("converted.xrg-theme.json"));
                self.stage = 3;
            }
            3 => {
                let dialog = self.dialog.take().unwrap();
                require(
                    ThemeDocument::load(&root.join("converted.xrg-theme.json"))?
                        == ThemeDocument::parse(SRGB)?,
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
                let mut expected = dialog.draft();
                expected.theme = ThemeChoice::Custom {
                    theme: Box::new(ThemeDocument::parse(P3)?),
                };
                self.expected = Some(expected);
                dialog.load_theme(root.join("DisplayP3.xtf"));
                self.dialog = Some(dialog);
                self.stage = 5;
            }
            5 => {
                let dialog = self.dialog.as_ref().unwrap();
                require(
                    dialog.draft() == *self.expected.as_ref().unwrap(),
                    "Display P3 draft conversion differs",
                )?;
                require(
                    shell.settings.borrow().theme.palette()?.colors
                        == ThemeDocument::parse(SRGB)?.colors,
                    "P3 import changed active theme before Apply",
                )?;
                dialog.save_theme(root.join("p3-converted.xrg-theme.json"));
                self.stage = 6;
            }
            6 => {
                require(
                    ThemeDocument::load(&root.join("p3-converted.xrg-theme.json"))?
                        == ThemeDocument::parse(P3)?,
                    "Display P3 JSON export lost converted colors or alpha",
                )?;
                self.dialog.take().unwrap().apply.emit_clicked();
                self.stage = 7;
            }
            7 if shell.saved_revision.get() == shell.revision.get() => {
                let expected = self.expected.as_ref().unwrap();
                let (_, loaded, error) = Store::open(Some(root.join("settings.conf")));
                require(
                    error.is_none() && loaded == *expected && *shell.settings.borrow() == *expected,
                    "Display P3 palette did not persist or changed other preferences",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_P3_IMAGE") {
                    shell.snapshot(Path::new(&path))?;
                }
                let dialog = shell.preferences();
                dialog.load_theme(root.join("broken.xtf"));
                self.dialog = Some(dialog);
                self.stage = 8;
            }
            8 => {
                let dialog = self.dialog.take().unwrap();
                require(
                    dialog.draft() == *self.expected.as_ref().unwrap(),
                    "Malformed XTF changed the draft",
                )?;
                require(
                    dialog.message().contains("could not be loaded"),
                    "Malformed XTF did not report an error",
                )?;
                for (name, bytes) in [
                    ("Classic.xtf", CLASSIC),
                    ("ModernSRGB.xtf", SRGB),
                    ("DisplayP3.xtf", P3),
                ] {
                    require(
                        fs::read(root.join(name)).map_err(|e| e.to_string())? == bytes,
                        "XTF import changed its source file",
                    )?;
                }
                dialog.cancel.emit_clicked();
                self.stage = 9;
                return Ok(true);
            }
            9 => return Ok(true),
            _ => (),
        }
        if previous != self.stage {
            println!("GTK_XTF_THEME_STAGE {}", self.stage);
        }
        Ok(false)
    }
}
