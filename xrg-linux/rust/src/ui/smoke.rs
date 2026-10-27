// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Exercised in a real GTK loop using temporary preferences/theme files only.
use super::{Shell, preferences::Dialog};
use gtk::prelude::*;
use std::{
    fs,
    path::PathBuf,
    rc::Rc,
    time::{Instant, SystemTime, UNIX_EPOCH},
};
use xrg_ng_linux::settings::{Module, Settings, Store, ThemeChoice, ThemeDocument};
pub(super) struct Harness {
    root: PathBuf,
    stage: u8,
    dialog: Option<Rc<Dialog>>,
    expected: Option<Settings>,
    since: Instant,
}
fn require(condition: bool, message: &str) -> Result<(), String> {
    if condition {
        Ok(())
    } else {
        Err(message.into())
    }
}
impl Harness {
    pub fn new() -> Result<Self, String> {
        let root = std::env::temp_dir().join(format!(
            "xrg-gtk-preferences-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&root).map_err(|e| e.to_string())?;
        fs::write(root.join("settings.conf"), "theme=Midnight\n").map_err(|e| e.to_string())?;
        fs::write(root.join("invalid.json"), "{broken").map_err(|e| e.to_string())?;
        Ok(Self {
            root,
            stage: 0,
            dialog: None,
            expected: None,
            since: Instant::now(),
        })
    }
    pub fn preferences_path(&self) -> PathBuf {
        self.root.join("settings.conf")
    }
    fn configure(dialog: &Dialog) {
        dialog.check(Module::Cpu).set_active(false);
        for _ in 0..9 {
            dialog.move_up(Module::Tpu);
        }
        dialog.height.set_value(112.);
        dialog.name.set_text("Smoke custom");
        dialog.colors[2].set_rgba(&gtk::gdk::RGBA::new(0.2, 0.8, 0.9, 0.85));
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64) -> Result<bool, String> {
        let before = self.stage;
        match self.stage {
            0 if sequence >= 2 => {
                shell.chooser.set_selected(4);
                self.stage = 1;
            }
            1 if sequence >= 3 => {
                shell.chooser.set_selected(2);
                self.stage = 2;
            }
            2 if sequence >= 4 && shell.draws.iter().all(|d| d.get() >= 3) => {
                let before = shell.settings.borrow().clone();
                let dialog = shell.preferences();
                dialog.select_preset(4);
                require(
                    dialog.draft().theme
                        == ThemeChoice::Builtin {
                            name: "Paper".into(),
                        },
                    "Preferences preset switch failed",
                )?;
                dialog.select_preset(2);
                dialog.select_preset(6);
                require(
                    matches!(dialog.draft().theme, ThemeChoice::Custom { .. }),
                    "Custom choice did not create an editable palette",
                )?;
                dialog.name.set_text("");
                dialog.move_up(Module::Tpu);
                dialog.apply.emit_clicked();
                require(!dialog.message().is_empty(), "Invalid draft had no error")?;
                require(
                    *shell.settings.borrow() == before,
                    "Invalid Apply changed active settings",
                )?;
                Self::configure(&dialog);
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == before,
                    "Cancel changed active settings",
                )?;
                let dialog = shell.preferences();
                Self::configure(&dialog);
                self.expected = Some(dialog.draft());
                dialog.load_theme(self.root.join("invalid.json"));
                self.dialog = Some(dialog);
                self.stage = 3;
            }
            3 => {
                let dialog = self.dialog.as_ref().unwrap();
                if dialog.is_busy() {
                    return Ok(false);
                }
                require(
                    dialog.draft() == *self.expected.as_ref().unwrap(),
                    "Invalid import changed the draft",
                )?;
                require(
                    dialog.message().contains("could not be loaded"),
                    "Invalid import did not report an error",
                )?;
                dialog.save_theme(self.root.join("exported.xrg-theme.json"));
                self.stage = 4;
            }
            4 => {
                let dialog = self.dialog.as_ref().unwrap();
                if dialog.is_busy() {
                    return Ok(false);
                }
                let exported = ThemeDocument::load(&self.root.join("exported.xrg-theme.json"))?;
                require(
                    exported == ThemeDocument::new(&dialog.draft().theme.palette()?),
                    "Theme export changed colors/name",
                )?;
                dialog.name.set_text("Temporary edit");
                dialog.load_theme(self.root.join("exported.xrg-theme.json"));
                self.stage = 5;
            }
            5 => {
                let dialog = self.dialog.as_ref().unwrap();
                if dialog.is_busy() {
                    return Ok(false);
                }
                require(
                    dialog.draft() == *self.expected.as_ref().unwrap(),
                    "Theme load failed to restore the draft",
                )?;
                self.since = Instant::now();
                self.stage = 6;
            }
            6 if self.since.elapsed().as_millis() >= 200 => {
                let dialog = self.dialog.as_ref().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_PREFS_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                dialog.apply.emit_clicked();
                self.dialog.take();
                self.stage = 7;
            }
            7 if shell.saved_revision.get() == shell.revision.get() && shell.revision.get() > 0 => {
                let expected = self.expected.as_ref().unwrap();
                require(
                    *shell.settings.borrow() == *expected,
                    "Apply lost preference edits",
                )?;
                require(
                    !shell.areas[Module::Cpu.index()].is_visible(),
                    "Hidden CPU graph is visible",
                )?;
                require(
                    shell.graphs.first_child()
                        == Some(shell.areas[Module::Tpu.index()].clone().upcast()),
                    "Graph order did not change",
                )?;
                require(
                    shell.areas[Module::Tpu.index()]
                        .tooltip_text()
                        .is_some_and(|t| t.contains("producer")),
                    "Reordered TPU graph acquired another panel's data",
                )?;
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *expected,
                    "Preference reopen did not restore the custom theme/layout",
                )?;
                require(
                    matches!(loaded.theme, ThemeChoice::Custom { .. }),
                    "Custom theme was replaced by a preset",
                )?;
                let actual = Settings::parse(
                    &fs::read(self.preferences_path()).map_err(|e| e.to_string())?,
                )?;
                require(actual == loaded, "Saved settings failed to round trip")?;
                let dialog = shell.preferences();
                for id in Module::ALL {
                    dialog.check(id).set_active(false);
                }
                dialog.apply.emit_clicked();
                require(
                    shell.empty.is_visible(),
                    "All-hidden layout has no recovery message",
                )?;
                let dialog = shell.preferences();
                for module in &expected.modules {
                    dialog.check(module.id).set_active(module.visible);
                }
                dialog.apply.emit_clicked();
                require(
                    !shell.empty.is_visible(),
                    "Restoring graphs did not dismiss the empty state",
                )?;
                self.stage = 8;
            }
            8 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Restored layout did not persist",
                )?;
                self.stage = 9;
            }
            9 => return Ok(true),
            _ => (),
        }
        if self.stage != before {
            eprintln!("GTK_PREFERENCES_STAGE {}", self.stage);
        }
        Ok(false)
    }
}
impl Drop for Harness {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
