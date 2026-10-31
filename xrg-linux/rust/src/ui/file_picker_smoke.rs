// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Dedicated native chooser flow. It runs under the outer unchanged 20s gate.
use super::{App, file_picker::Action};
use crate::settings::{Module, Settings, ThemeChoice, ThemeDocument};
use eframe::egui;
use std::{
    ffi::OsStr,
    fs,
    path::Path,
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
    baseline: Option<Settings>,
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
        let completed = |app: &App| {
            app.preferences
                .as_ref()
                .is_some_and(|e| e.picker.is_none() && !e.busy())
        };
        let stage = self.stage;
        match stage {
            0 => {
                fs::create_dir(&folder).map_err(|e| e.to_string())?;
                fs::write(folder.join("Original.XTF"), XTF).map_err(|e| e.to_string())?;
                fs::write(folder.join("invalid.json"), b"not JSON").map_err(|e| e.to_string())?;
                fs::write(&legacy, LEGACY).map_err(|e| e.to_string())?;
                fs::create_dir(folder.join("Subfolder")).map_err(|e| e.to_string())?;
                self.baseline = Some(app.settings.clone());
                app.preferences();
                app.preferences
                    .as_mut()
                    .unwrap()
                    .choose_at(Action::LoadTheme, folder.clone(), ctx);
                self.stage = 1;
            }
            1 if self.settle(picker_ready(app)) => {
                self.stage = 2;
                return Ok(Step::Capture("XRG_SMOKE_FILE_PICKER_IMAGE"));
            }
            2 => {
                let p = app.preferences.as_mut().unwrap().picker.as_mut().unwrap();
                p.select_name(OsStr::new("Original.XTF"))?;
                p.accept();
                self.stage = 3;
            }
            3 if completed(app) => {
                let expected = ThemeDocument::parse(XTF)?;
                if app.preferences.as_ref().unwrap().draft.theme
                    != (ThemeChoice::Custom {
                        theme: Box::new(expected),
                    })
                {
                    return Err("Chooser XTF load did not reach the preferences draft".into());
                }
                app.preferences = None;
                self.unchanged(app, root)?;
                app.preferences();
                app.preferences
                    .as_mut()
                    .unwrap()
                    .choose_at(Action::SaveTheme, saved.clone(), ctx);
                self.stage = 4;
            }
            4 if picker_ready(app) => {
                app.preferences
                    .as_mut()
                    .unwrap()
                    .picker
                    .as_mut()
                    .unwrap()
                    .accept();
                self.stage = 5;
            }
            5 if completed(app) => {
                let expected = ThemeDocument::new(&app.settings.theme.palette()?);
                if ThemeDocument::load(&saved)? != expected {
                    return Err("Chooser did not export the selected palette".into());
                }
                let alternative = crate::shared::themes()
                    .into_iter()
                    .find(|t| t.name != expected.name)
                    .ok_or("Missing second theme")?;
                self.export = Some(ThemeDocument::new(&alternative));
                let editor = app.preferences.as_mut().unwrap();
                editor.draft.theme = ThemeChoice::Builtin {
                    name: alternative.name,
                };
                editor.choose_at(Action::SaveTheme, saved.clone(), ctx);
                self.stage = 6;
            }
            6 if picker_ready(app) => {
                app.preferences
                    .as_mut()
                    .unwrap()
                    .picker
                    .as_mut()
                    .unwrap()
                    .accept();
                self.stage = 7;
            }
            7 if self.settle(replacement_ready(app)) => {
                self.stage = 8;
                return Ok(Step::Capture("XRG_SMOKE_FILE_REPLACE_IMAGE"));
            }
            8 => {
                app.preferences.as_mut().unwrap().picker = None;
                let expected = ThemeDocument::new(&app.settings.theme.palette()?);
                if ThemeDocument::load(&saved)? != expected {
                    return Err("Cancelling replacement changed the existing file".into());
                }
                app.preferences
                    .as_mut()
                    .unwrap()
                    .choose_at(Action::SaveTheme, saved.clone(), ctx);
                self.stage = 9;
            }
            9 if picker_ready(app) => {
                app.preferences
                    .as_mut()
                    .unwrap()
                    .picker
                    .as_mut()
                    .unwrap()
                    .accept();
                self.stage = 10;
            }
            10 if replacement_ready(app) => {
                app.preferences
                    .as_mut()
                    .unwrap()
                    .picker
                    .as_mut()
                    .unwrap()
                    .confirm_replace();
                self.stage = 11;
            }
            11 if completed(app) => {
                if Some(ThemeDocument::load(&saved)?) != self.export {
                    return Err("Confirmed replacement did not export the draft palette".into());
                }
                app.preferences = None;
                self.unchanged(app, root)?;
                app.preferences();
                app.preferences.as_mut().unwrap().choose_at(
                    Action::ImportLegacy,
                    legacy.clone(),
                    ctx,
                );
                self.stage = 12;
            }
            12 if picker_ready(app) => {
                app.preferences
                    .as_mut()
                    .unwrap()
                    .picker
                    .as_mut()
                    .unwrap()
                    .accept();
                self.stage = 13;
            }
            13 if completed(app) => {
                let editor = app.preferences.as_mut().unwrap();
                if !editor.import_ready() {
                    return Err("Legacy chooser skipped its review step".into());
                }
                if editor.draft != *self.baseline.as_ref().unwrap() {
                    return Err("Review alone changed preferences".into());
                }
                editor.accept_import();
                if editor
                    .draft
                    .modules
                    .iter()
                    .find(|m| m.id == Module::Cpu)
                    .unwrap()
                    .visible
                {
                    return Err("Legacy review did not transfer CPU visibility into draft".into());
                }
                if fs::read(&legacy).map_err(|e| e.to_string())? != LEGACY {
                    return Err("Import changed its source file".into());
                }
                app.preferences = None;
                self.unchanged(app, root)?;
                app.preferences();
                app.preferences.as_mut().unwrap().choose_at(
                    Action::LoadTheme,
                    folder.join("invalid.json"),
                    ctx,
                );
                self.stage = 14;
            }
            14 if picker_ready(app) => {
                app.preferences
                    .as_mut()
                    .unwrap()
                    .picker
                    .as_mut()
                    .unwrap()
                    .accept();
                self.stage = 15;
            }
            15 if completed(app) => {
                let editor = app.preferences.as_ref().unwrap();
                if editor.draft != *self.baseline.as_ref().unwrap() || editor.message().is_none() {
                    return Err(
                        "Invalid theme changed the draft or failed to report its error".into(),
                    );
                }
                self.unchanged(app, root)?;
                self.stage = 16;
                return Ok(Step::Done);
            }
            16 => return Ok(Step::Done),
            _ => (),
        }
        Ok(Step::Pending)
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
    fn unchanged(&self, app: &App, root: &Path) -> Result<(), String> {
        if app.settings != *self.baseline.as_ref().unwrap() || root.join("settings.conf").exists() {
            Err("A chooser or cancelled draft changed active/saved settings".into())
        } else {
            Ok(())
        }
    }
}
fn picker_ready(app: &App) -> bool {
    app.preferences
        .as_ref()
        .and_then(|e| e.picker.as_ref())
        .is_some_and(|p| !p.is_loading())
}
fn replacement_ready(app: &App) -> bool {
    app.preferences
        .as_ref()
        .and_then(|e| e.picker.as_ref())
        .is_some_and(|p| p.needs_replacement())
}
