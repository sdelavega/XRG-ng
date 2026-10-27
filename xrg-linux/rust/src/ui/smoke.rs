// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Exercised in a real GTK loop using temporary preferences/theme files only.
use super::{Shell, preferences::Dialog};
use gtk::prelude::*;
use std::{
    fs,
    path::PathBuf,
    rc::Rc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use xrg_ng_linux::settings::{Module, Settings, Store, ThemeChoice, ThemeDocument};
pub(super) struct Harness {
    root: PathBuf,
    stage: u8,
    dialog: Option<Rc<Dialog>>,
    process: Option<Rc<super::processes::Window>>,
    ai: Option<Rc<super::ai::Window>>,
    weather: Option<Rc<super::weather::Window>>,
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
            process: None,
            ai: None,
            weather: None,
            expected: None,
            since: Instant::now(),
        })
    }
    pub fn preferences_path(&self) -> PathBuf {
        self.root.join("settings.conf")
    }
    fn configure(dialog: &Dialog, shell: &Shell) {
        let inventory = shell.inventory();
        dialog
            .targets
            .set(&xrg_ng_linux::settings::MetricSelection {
                cpu: inventory.cpus.first().copied(),
                network: inventory
                    .networks
                    .iter()
                    .find(|n| n.as_str() != "lo")
                    .cloned(),
                disk: inventory.disks.first().cloned(),
                gpu: inventory.gpus.first().map(|g| g.id.clone()),
            });
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
                Self::configure(&dialog, shell);
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == before,
                    "Cancel changed active settings",
                )?;
                let dialog = shell.preferences();
                Self::configure(&dialog, shell);
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
            9 if shell
                .state
                .borrow()
                .as_ref()
                .is_some_and(|s| s.selection == shell.settings.borrow().metrics) =>
            {
                let state = shell.state.borrow();
                let snapshot = state.as_ref().unwrap();
                if let Some(cpu) = snapshot.selection.cpu {
                    require(
                        snapshot.panels[0].label.contains(&format!("CPU {cpu}")),
                        "CPU selector did not reach the worker",
                    )?;
                }
                let own = snapshot
                    .processes
                    .as_ref()
                    .map_err(Clone::clone)?
                    .processes
                    .iter()
                    .find(|p| p.pid == std::process::id())
                    .ok_or("Own process missing from readable scan")?
                    .clone();
                drop(state);
                let window = shell.processes();
                window.uid.set_text("invalid");
                require(
                    window.row_count() == 0 && window.status().contains("numeric UID"),
                    "Invalid UID filter did not fail closed",
                )?;
                window
                    .uid
                    .set_text(&own.uid.ok_or("Own UID missing")?.to_string());
                window.filter.set_text(&own.name);
                window.sort.set_selected(3);
                window.limit.set_value(20.);
                self.process = Some(window);
                self.stage = 10;
            }
            10 => {
                let window = self.process.as_ref().unwrap();
                if !window.settled() {
                    return Ok(false);
                }
                require(
                    window.row_count() == 1,
                    "Process name/UID filters did not isolate the app",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_PROCESS_IMAGE") {
                    window.snapshot(&PathBuf::from(path))?;
                }
                window.window.close();
                self.process.take();
                self.expected = Some(shell.settings.borrow().clone());
                self.stage = 11;
            }
            11 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Metric/process preferences did not persist",
                )?;
                require(
                    loaded.version == 5 && loaded.processes.limit == 20,
                    "Settings upgrade/process options lost",
                )?;
                self.stage = 12;
            }
            12 => {
                let before = shell.settings.borrow().clone();
                let window = shell.ai();
                window.tabs.set_current_page(Some(1));
                window.paths[0].set_text("relative-path");
                window.apply.emit_clicked();
                require(
                    *shell.settings.borrow() == before && window.status().contains("absolute"),
                    "Invalid AI path changed preferences",
                )?;
                window.paths[0].set_text("");
                window.metrics.set_text("http://example.com/metrics");
                window.apply.emit_clicked();
                require(
                    *shell.settings.borrow() == before && window.status().contains("loopback"),
                    "Remote AI endpoint was accepted",
                )?;
                for check in &window.enabled {
                    check.set_active(false);
                }
                window.ollama.set_active(false);
                window.paths[0].set_text(self.root.join("custom projects").to_str().unwrap());
                window.metrics.set_text("http://127.0.0.1:18889/metrics");
                window.endpoint.set_text("http://[::1]:11434/ollama");
                window.mode.set_selected(1);
                window.apply.emit_clicked();
                require(
                    shell.settings.borrow().ai.enabled == [false; 4]
                        && !shell.settings.borrow().ai.ollama,
                    "AI provider toggles did not apply",
                )?;
                self.expected = Some(shell.settings.borrow().clone());
                self.ai = Some(window);
                self.stage = 13;
            }
            13 if self.since.elapsed() > Duration::from_millis(200) => {
                let window = self.ai.as_ref().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_AI_SOURCES_IMAGE") {
                    window.snapshot(&PathBuf::from(path))?;
                }
                window.tabs.set_current_page(Some(0));
                // Inject only copied fixture snapshots; external workers stay disabled.
                let mut active = shell.settings.borrow().ai.clone();
                active.enabled = [true; 4];
                active.ollama = true;
                use xrg_ng_linux::{
                    ai::{ModelUsage, Models, Reading, Report, Update},
                    shared::Usage,
                };
                let known = Usage {
                    input: 10,
                    output: 2,
                    total: 12,
                };
                let unknown = Usage {
                    input: 30,
                    output: 0,
                    total: 30,
                };
                let report = Report {
                    providers: [
                        Ok(Reading {
                            usage: Usage {
                                input: 40,
                                output: 2,
                                total: 42,
                            },
                            cost: None,
                            source: "Automated UI fixture".into(),
                            models: Some(vec![
                                ModelUsage {
                                    model: None,
                                    usage: unknown,
                                    cost: None,
                                },
                                ModelUsage {
                                    model: Some("fixture-claude".into()),
                                    usage: known,
                                    cost: None,
                                },
                            ]),
                        }),
                        Ok(Reading {
                            usage: known,
                            cost: None,
                            source: "Fixture cumulative session".into(),
                            models: None,
                        }),
                        Err("Fixture provider unavailable".into()),
                        Ok(Reading {
                            usage: known,
                            cost: Some(0.25),
                            source: "Fixture Hermes SQLite".into(),
                            models: Some(vec![ModelUsage {
                                model: Some("fixture-hermes".into()),
                                usage: known,
                                cost: Some(0.25),
                            }]),
                        }),
                    ],
                    ollama: "Automated UI fixture".into(),
                    models: Models {
                        installed: Ok(vec!["fixture-model".into()]),
                        running: Ok(vec![]),
                    },
                };
                let mut panel = xrg_ng_linux::ai::waiting();
                panel.detail = "Automated UI fixture — not live usage\n\nRetained token totals by recorded model.".into();
                let fixture = Update::new(active.clone(), panel, report);
                window.update(Some(&fixture), &active);
                require(
                    window.usage_text().contains("fixture-model")
                        && window.usage_text().contains("fixture-claude")
                        && window.usage_text().contains("Unattributed")
                        && window.usage_text().contains("10 input")
                        && window.usage_text().contains("source cost $0.2500")
                        && window
                            .usage_text()
                            .contains("per-model token attribution unavailable"),
                    "AI model detail did not render",
                )?;
                let mut stale = active.clone();
                stale.ollama = !stale.ollama;
                window.update(Some(&fixture), &stale);
                require(
                    !window.usage_text().contains("fixture-model")
                        && !window.usage_text().contains("fixture-claude")
                        && !window.usage_text().contains("Unattributed")
                        && window.usage_text().contains("Waiting for the AI worker"),
                    "Stale AI report survived a source change",
                )?;
                window.update(Some(&fixture), &active);
                self.stage = 14;
            }
            14 if self.since.elapsed() > Duration::from_millis(200) => {
                let window = self.ai.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_AI_IMAGE") {
                    window.snapshot(&PathBuf::from(path))?;
                }
                window.cancel.emit_clicked();
                self.stage = 15;
            }
            15 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "AI sources did not persist",
                )?;
                let reopened = shell.ai();
                require(
                    !reopened.enabled[0].is_active()
                        && reopened.metrics.text() == loaded.ai.metrics_url,
                    "AI source controls did not reopen",
                )?;
                reopened.paths[0].set_text("unsaved-relative-path");
                reopened.cancel.emit_clicked();
                require(
                    shell.settings.borrow().ai == loaded.ai,
                    "Closing AI controls applied an unsaved draft",
                )?;
                let graphs = shell.preferences();
                graphs.reset.emit_clicked();
                graphs.apply.emit_clicked();
                require(
                    shell.settings.borrow().ai == loaded.ai,
                    "Restoring graph defaults reset AI source preferences",
                )?;
                self.expected = Some(shell.settings.borrow().clone());
                self.stage = 16;
            }
            16 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Graph defaults lost the saved AI settings",
                )?;
                let before = shell.settings.borrow().clone();
                let window = shell.weather();
                window.enabled.set_active(true);
                window.station.set_text("BAD;URL");
                window.apply.emit_clicked();
                require(
                    *shell.settings.borrow() == before
                        && window.status().contains("four-character"),
                    "Invalid weather station changed preferences",
                )?;
                window.station.set_text(" ksea ");
                window.units.set_selected(1);
                window.interval.set_value(5.);
                window.apply.emit_clicked();
                require(
                    shell.settings.borrow().weather.station == "KSEA"
                        && shell.settings.borrow().weather.enabled,
                    "Weather station did not normalize/apply",
                )?;
                window.refresh.emit_clicked();
                require(
                    window.status().contains("cooldown"),
                    "Weather refresh did not explain throttling",
                )?;
                let active = shell.settings.borrow().weather.clone();
                let fixture = xrg_ng_linux::weather::Update {
                    preferences: active.clone(), observation: None, stale: true, cooldown_seconds: 60,
                    summary: "Automated weather UI fixture".into(),
                    detail: "Automated UI fixture — not a live report\n\nKSEA · stale observation\nObserved: 2026-10-27 12:00 UTC\nObservation age: 180 min\n\nTemperature: 32.0 °F\nDewpoint: 28.4 °F\nHumidity: 86 %\nWind: 11.5 mph\nVisibility: <0.25 mi\nPressure: 30.00 inHg\n\nRaw METAR:\nKSEA 271200Z 09010KT M1/4SM 00/M02 A3000".into(),
                };
                window.update(Some(&fixture), &active);
                require(
                    window.text().contains("stale observation"),
                    "Weather observation did not render",
                )?;
                let other = xrg_ng_linux::weather::Preferences {
                    station: "KJFK".into(),
                    ..active.clone()
                };
                window.update(Some(&fixture), &other);
                require(
                    !window.text().contains("KSEA"),
                    "Old station data survived a weather source change",
                )?;
                window.update(Some(&fixture), &active);
                self.expected = Some(shell.settings.borrow().clone());
                self.weather = Some(window);
                self.stage = 17;
            }
            17 if self.since.elapsed() > Duration::from_millis(200) => {
                let window = self.weather.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_WEATHER_IMAGE") {
                    window.snapshot(&PathBuf::from(path))?;
                }
                window.close.emit_clicked();
                self.stage = 18;
            }
            18 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Weather preferences did not persist",
                )?;
                let window = shell.weather();
                require(
                    window.station.text() == "KSEA" && window.units.selected() == 1,
                    "Weather preferences did not reopen",
                )?;
                window.station.set_text("KJFK");
                window.close.emit_clicked();
                require(
                    shell.settings.borrow().weather == loaded.weather,
                    "Closing weather applied an unsaved draft",
                )?;
                let graphs = shell.preferences();
                graphs.reset.emit_clicked();
                graphs.apply.emit_clicked();
                require(
                    shell.settings.borrow().weather == loaded.weather,
                    "Graph defaults reset the weather station",
                )?;
                self.expected = Some(shell.settings.borrow().clone());
                self.stage = 19;
            }
            19 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Weather preferences were lost after graph defaults",
                )?;
                return Ok(true);
            }
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
