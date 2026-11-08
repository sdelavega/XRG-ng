// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Dedicated native chooser flow through the settings window's production
//! paths, running under the outer unchanged 20-second gate: an original XTF
//! import lands in the store and the live app at once (there is no draft),
//! a JSON export writes the current palette, a cancelled replacement
//! leaves the existing file byte-identical, the GTK legacy import reviews
//! before it applies, and an invalid theme is refused with a message while
//! the settings stay untouched.
use super::{App, file_picker::Action};
use crate::settings::{Module, Settings, ThemeChoice, ThemeDocument};
use eframe::egui;
use std::{
    ffi::OsStr,
    fs,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
const LEGACY: &[u8] = b"[Modules]\nshow_cpu=false\n";
const XTF: &[u8] = include_bytes!("../../tests/fixtures/ModernSRGB.xtf");
pub(super) enum Step {
    Pending,
    Capture(&'static str),
    Done,
}
#[derive(Default)]
pub(super) struct Harness {
    stage: u8,
    /// What the settings and the settings document must still equal:
    /// updated only by the operations that legitimately change them.
    baseline: Option<(Settings, Option<Vec<u8>>)>,
    /// The saved file's bytes before the replacement attempt: cancelling
    /// the replacement must leave the existing file byte-identical, so the
    /// check compares raw bytes, not the theme the store holds by then
    /// (stage 5 legitimately switches the preset before the re-save).
    existing: Option<Vec<u8>>,
    /// The preset stage 5 applies, held while the window's next frame adopts
    /// it into the live view: the baseline is recorded only afterwards, so
    /// the settings and the document are consistent from there on.
    preset: Option<String>,
    /// Whether stage 13 accepted the legacy import already; the baseline is
    /// recorded only once the live dashboard adopted the imported view.
    imported: bool,
    export: Option<ThemeDocument>,
    settled: Option<Instant>,
}
impl Harness {
    pub fn tick(
        &mut self,
        app: &mut App,
        ctx: &egui::Context,
        root: &Path,
    ) -> Result<Step, String> {
        let folder = root.join("Theme files with spaces");
        let saved = folder.join("Saved palette.json");
        let legacy = folder.join("old.conf");
        let stage = self.stage;
        match stage {
            0 => {
                fs::create_dir(&folder).map_err(|e| e.to_string())?;
                fs::write(folder.join("Original.XTF"), XTF).map_err(|e| e.to_string())?;
                fs::write(folder.join("invalid.json"), b"not JSON").map_err(|e| e.to_string())?;
                fs::write(&legacy, LEGACY).map_err(|e| e.to_string())?;
                fs::create_dir(folder.join("Subfolder")).map_err(|e| e.to_string())?;
                self.record(app, root);
                app.preferences();
                self.open_chooser(app)?
                    .choose_at(Action::LoadTheme, folder.clone(), ctx);
                self.stage = 1;
            }
            1 if self.settle(picker_ready(app)) => {
                self.stage = 2;
                return Ok(Step::Capture("XRG_SMOKE_FILE_PICKER_IMAGE"));
            }
            2 => {
                let picker = self.open_chooser(app)?.picker.as_mut().unwrap();
                picker.select_name(OsStr::new("Original.XTF"))?;
                picker.accept();
                self.stage = 3;
            }
            3 if completed(app) => {
                let expected = ThemeChoice::Custom {
                    theme: Box::new(ThemeDocument::parse(XTF)?),
                };
                if app.store.settings().theme != expected {
                    return Err("Chooser XTF load did not reach the settings document".into());
                }
                if app.settings.theme != expected {
                    return Err("The loaded theme did not reach the live dashboard".into());
                }
                self.record(app, root);
                app.settings_window = None;
                self.unchanged(app, root)?;
                app.preferences();
                self.open_chooser(app)?
                    .choose_at(Action::SaveTheme, saved.clone(), ctx);
                self.stage = 4;
            }
            4 if picker_ready(app) => {
                self.open_chooser(app)?.picker.as_mut().unwrap().accept();
                self.stage = 5;
            }
            5 if completed(app) => {
                if self.preset.is_none() {
                    let current = ThemeDocument::new(&app.store.settings().theme.palette()?);
                    if ThemeDocument::load(&saved)? != current {
                        return Err("Chooser did not export the selected palette".into());
                    }
                    self.existing = Some(fs::read(&saved).map_err(|e| e.to_string())?);
                    let alternative = crate::shared::themes()
                        .into_iter()
                        .find(|theme| theme.name != current.name)
                        .ok_or("Missing second theme")?;
                    self.export = Some(ThemeDocument::new(&alternative));
                    let name = alternative.name.clone();
                    app.settings_window
                        .as_mut()
                        .unwrap()
                        .choose_preset(&name, &mut app.store)?;
                    self.preset = Some(name);
                } else if self.preset.as_ref().is_some_and(|name| {
                    app.settings.theme == ThemeChoice::Builtin { name: name.clone() }
                }) {
                    // The preset reached the live dashboard: the baseline now
                    // covers the store, the document and the app alike.
                    self.record(app, root);
                    self.open_chooser(app)?
                        .choose_at(Action::SaveTheme, saved.clone(), ctx);
                    self.stage = 6;
                }
            }
            6 if picker_ready(app) => {
                self.open_chooser(app)?.picker.as_mut().unwrap().accept();
                self.stage = 7;
            }
            7 if self.settle(replacement_ready(app)) => {
                self.stage = 8;
                return Ok(Step::Capture("XRG_SMOKE_FILE_REPLACE_IMAGE"));
            }
            8 => {
                self.open_chooser(app)?.picker = None;
                let existing = self
                    .existing
                    .take()
                    .expect("the chooser gate recorded the existing export");
                if fs::read(&saved).map_err(|e| e.to_string())? != existing {
                    return Err("Cancelling replacement changed the existing file".into());
                }
                self.open_chooser(app)?
                    .choose_at(Action::SaveTheme, saved.clone(), ctx);
                self.stage = 9;
            }
            9 if picker_ready(app) => {
                self.open_chooser(app)?.picker.as_mut().unwrap().accept();
                self.stage = 10;
            }
            10 if replacement_ready(app) => {
                self.open_chooser(app)?
                    .picker
                    .as_mut()
                    .unwrap()
                    .confirm_replace();
                self.stage = 11;
            }
            11 if completed(app) => {
                if Some(ThemeDocument::load(&saved)?) != self.export {
                    return Err("Confirmed replacement did not export the preset palette".into());
                }
                self.unchanged(app, root)?;
                app.settings_window = None;
                app.preferences();
                self.open_chooser(app)?
                    .choose_at(Action::ImportLegacy, legacy.clone(), ctx);
                self.stage = 12;
            }
            12 if picker_ready(app) => {
                self.open_chooser(app)?.picker.as_mut().unwrap().accept();
                self.stage = 13;
            }
            13 if completed(app) => {
                if !self.imported {
                    if !self.open_chooser(app)?.import_ready() {
                        return Err("Legacy chooser skipped its review step".into());
                    }
                    // Review alone changes nothing.
                    self.unchanged(app, root)?;
                    app.settings_window
                        .as_mut()
                        .unwrap()
                        .accept_import(&mut app.store)?;
                    if app
                        .store
                        .settings()
                        .modules
                        .iter()
                        .find(|module| module.id == Module::Cpu)
                        .unwrap()
                        .visible
                    {
                        return Err("Legacy import did not transfer CPU visibility".into());
                    }
                    self.imported = true;
                } else if !app
                    .settings
                    .modules
                    .iter()
                    .find(|module| module.id == Module::Cpu)
                    .unwrap()
                    .visible
                {
                    // The imported view reached the live dashboard; record the
                    // baseline only now that the app holds it too.
                    if fs::read(&legacy).map_err(|e| e.to_string())? != LEGACY {
                        return Err("Import changed its source file".into());
                    }
                    if !root.join("xrg-ng/settings.json").exists() {
                        return Err("Accepted legacy import did not persist".into());
                    }
                    self.record(app, root);
                    app.settings_window = None;
                    self.unchanged(app, root)?;
                    app.preferences();
                    self.open_chooser(app)?.choose_at(
                        Action::LoadTheme,
                        folder.join("invalid.json"),
                        ctx,
                    );
                    self.stage = 14;
                }
            }
            14 if picker_ready(app) => {
                self.open_chooser(app)?.picker.as_mut().unwrap().accept();
                self.stage = 15;
            }
            15 if completed(app) => {
                self.unchanged(app, root)?;
                if self.open_chooser(app)?.message().is_none() {
                    return Err("Invalid theme failed to report its error".into());
                }
                self.stage = 16;
                return Ok(Step::Done);
            }
            16 => return Ok(Step::Done),
            _ => (),
        }
        Ok(Step::Pending)
    }
    fn open_chooser<'a>(
        &self,
        app: &'a mut App,
    ) -> Result<&'a mut super::preferences::SettingsWindow, String> {
        app.settings_window
            .as_mut()
            .ok_or_else(|| "The settings window is closed".into())
    }
    /// Record what the settings and the document equal right now.
    fn record(&mut self, app: &App, root: &Path) {
        self.baseline = Some((
            app.settings.clone(),
            fs::read(root.join("xrg-ng/settings.json")).ok(),
        ));
    }
    /// Nothing but the explicit operations may move the settings or the
    /// document: every check runs against the recorded baseline.
    fn unchanged(&self, app: &App, root: &Path) -> Result<(), String> {
        let (settings, file) = self
            .baseline
            .as_ref()
            .expect("the chooser gate baselines first");
        let document: PathBuf = root.join("xrg-ng/settings.json");
        if &app.settings != settings || fs::read(&document).ok() != *file {
            return Err(
                "A chooser, a review or an invalid theme changed active/saved settings".into(),
            );
        }
        Ok(())
    }
    fn settle(&mut self, ready: bool) -> bool {
        if !ready {
            self.settled = None;
            return false;
        }
        let since = self.settled.get_or_insert_with(Instant::now);
        if since.elapsed() < Duration::from_millis(300) {
            return false;
        }
        self.settled = None;
        true
    }
}
fn completed(app: &App) -> bool {
    app.settings_window
        .as_ref()
        .is_some_and(|window| window.picker.is_none() && !window.busy())
}
fn picker_ready(app: &App) -> bool {
    app.settings_window
        .as_ref()
        .and_then(|window| window.picker.as_ref())
        .is_some_and(|picker| !picker.is_loading())
}
fn replacement_ready(app: &App) -> bool {
    app.settings_window
        .as_ref()
        .and_then(|window| window.picker.as_ref())
        .is_some_and(|picker| picker.needs_replacement())
}
