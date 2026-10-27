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
use xrg_ng_linux::settings::{Layout, Module, Settings, Store, ThemeChoice, ThemeDocument};
use xrg_ng_linux::temperature::{Text, Units};
const LEGACY_FIXTURE: &str = "# Automated legacy import fixture\n[Modules]\nshow_cpu=false\nshow_network=false\nshow_aitoken=false\n[Colors]\nbackground=rgba(8,16,32,0.9)\ngraph_fg1=rgba(0,128,255,0.75)\ntext=#eeeeee\n[Appearance]\ntheme=Legacy fixture\n[Window]\nx=25\nopacity=0.6\n[Display]\nlayout_orientation=1\nshow_activity_bars=true\n[Temperature]\nunits=1\n[GraphStyles]\ncpu_style=2\n[AIToken]\nclaude_cap=123456\n";
pub(super) struct Harness {
    root: PathBuf,
    stage: u8,
    dialog: Option<Rc<Dialog>>,
    process: Option<Rc<super::processes::Window>>,
    ai: Option<Rc<super::ai::Window>>,
    weather: Option<Rc<super::weather::Window>>,
    menu: Option<gtk::PopoverMenu>,
    menu_paintable: Option<gtk::WidgetPaintable>,
    details: Option<Rc<super::menus::Details>>,
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
        fs::write(root.join("legacy.ini"), LEGACY_FIXTURE).map_err(|e| e.to_string())?;
        fs::write(
            root.join("legacy-invalid.ini"),
            "[Modules]\nshow_network=false\nshow_cpu=maybe\n",
        )
        .map_err(|e| e.to_string())?;
        Ok(Self {
            root,
            stage: 0,
            dialog: None,
            process: None,
            ai: None,
            weather: None,
            menu: None,
            menu_paintable: None,
            details: None,
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
                    loaded.version == 6 && loaded.processes.limit == 20,
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
            19 if shell.saved_revision.get() == shell.revision.get()
                && shell.state.borrow().as_ref().is_some_and(|s| {
                    super::snapshot_matches(s, &shell.settings.borrow(), Module::Cpu)
                }) =>
            {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Weather preferences were lost after graph defaults",
                )?;
                let controllers = shell.areas[Module::Cpu.index()].observe_controllers();
                let key = (0..controllers.n_items())
                    .filter_map(|i| controllers.item(i))
                    .find_map(|c| c.downcast::<gtk::EventControllerKey>().ok())
                    .ok_or("Graph keyboard controller missing")?;
                shell.areas[Module::Cpu.index()].grab_focus();
                let handled = key.emit_by_name::<bool>(
                    "key-pressed",
                    &[
                        &gtk::gdk::Key::F10,
                        &0u32,
                        &gtk::gdk::ModifierType::SHIFT_MASK,
                    ],
                );
                require(handled, "Shift+F10 did not open graph menu")?;
                self.menu = shell.areas[Module::Cpu.index()]
                    .first_child()
                    .and_then(|p| p.downcast::<gtk::PopoverMenu>().ok());
                require(
                    self.menu.as_ref().is_some_and(|p| p.is_visible()),
                    "Keyboard graph menu not visible",
                )?;
                self.menu_paintable = self
                    .menu
                    .as_ref()
                    .map(|p| gtk::WidgetPaintable::new(Some(p)));
                self.stage = 20;
            }
            20 if self.since.elapsed() > Duration::from_millis(200) => {
                let popover = self.menu.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_MENU_IMAGE") {
                    require(
                        popover.width() > 0 && popover.height() > 0,
                        &format!(
                            "Menu has no layout: {}x{} mapped={}",
                            popover.width(),
                            popover.height(),
                            popover.is_mapped()
                        ),
                    )?;
                    let paintable = self.menu_paintable.take().unwrap();
                    super::save_snapshot(&popover, &paintable, &PathBuf::from(path))?;
                }
                popover.popdown();
                menu_action(shell, "graph-details", Some(Module::Cpu));
                let details = shell
                    .details
                    .borrow()
                    .get(&Module::Cpu)
                    .cloned()
                    .ok_or("Menu did not open graph details")?;
                menu_action(shell, "graph-details", Some(Module::Cpu));
                require(
                    shell.details.borrow().len() == 1,
                    "Details action opened duplicate windows",
                )?;
                self.details = Some(details);
                self.stage = 21;
            }
            21 if self.since.elapsed() > Duration::from_millis(200) => {
                let details = self.details.as_ref().unwrap();
                require(
                    details.text().contains("CPU")
                        && !details.text().contains("Waiting for the next"),
                    "Live details did not receive active CPU snapshot",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_DETAILS_IMAGE") {
                    details.snapshot(&PathBuf::from(path))?;
                }
                let original = shell.settings.borrow().clone();
                let mut changed = original.clone();
                changed.metrics.cpu = Some(1_048_575);
                shell.apply(changed);
                require(
                    details.text().contains("Waiting for the next sample"),
                    "Details retained old source data after selection change",
                )?;
                shell.apply(original);
                details.window.close();
                self.details.take();
                require(
                    shell.details.borrow().is_empty(),
                    "Closed details window stayed registered",
                )?;
                // Exercise the actual right-click signal callback and its teardown.
                let controllers = shell.areas[Module::Cpu.index()].observe_controllers();
                let click = (0..controllers.n_items())
                    .filter_map(|i| controllers.item(i))
                    .find_map(|c| c.downcast::<gtk::GestureClick>().ok())
                    .ok_or("Graph mouse controller missing")?;
                require(
                    click.button() == 3,
                    "Graph menu is not bound to right-click",
                )?;
                click.emit_by_name::<()>("pressed", &[&1i32, &24f64, &24f64]);
                let popover = shell.areas[Module::Cpu.index()]
                    .first_child()
                    .and_then(|p| p.downcast::<gtk::PopoverMenu>().ok())
                    .ok_or("Right-click did not open graph menu")?;
                popover.popdown();
                let key = (0..controllers.n_items())
                    .filter_map(|i| controllers.item(i))
                    .find_map(|c| c.downcast::<gtk::EventControllerKey>().ok())
                    .ok_or("Menu key controller missing")?;
                require(
                    key.emit_by_name::<bool>(
                        "key-pressed",
                        &[
                            &gtk::gdk::Key::Menu,
                            &0u32,
                            &gtk::gdk::ModifierType::empty(),
                        ],
                    ),
                    "Menu key was not handled",
                )?;
                let popover = shell.areas[Module::Cpu.index()]
                    .first_child()
                    .and_then(|p| p.downcast::<gtk::PopoverMenu>().ok())
                    .ok_or("Menu key did not open graph menu")?;
                popover.popdown();

                self.stage = 22;
            }
            22 if self.since.elapsed() > Duration::from_millis(200) => {
                require(
                    shell.areas[Module::Cpu.index()].first_child().is_none(),
                    "Closed graph popover stayed parented",
                )?;
                let original = shell.settings.borrow().clone();
                menu_action(shell, "graph-down", Some(Module::Cpu));
                require(
                    shell.settings.borrow().modules[1].id == Module::Cpu
                        && shell.graphs.first_child().as_ref()
                            == Some(shell.areas[Module::Memory.index()].upcast_ref()),
                    "Menu move-down did not reorder the graph widgets",
                )?;
                menu_action(shell, "graph-up", Some(Module::Cpu));
                let revision = shell.revision.get();
                menu_action(shell, "graph-up", Some(Module::Cpu));
                gtk::gio::prelude::ActionGroupExt::activate_action(
                    &shell.window,
                    "graph-hide",
                    Some(&u32::MAX.to_variant()),
                );
                require(
                    shell.revision.get() == revision,
                    "Invalid or boundary menu action modified settings",
                )?;
                let live_details = shell.details(Module::Cpu);
                for module in Module::ALL {
                    menu_action(shell, "graph-hide", Some(module));
                }
                require(
                    shell.empty.is_visible()
                        && shell.settings.borrow().modules.iter().all(|m| !m.visible),
                    "Menu hide actions did not reach all-hidden recovery",
                )?;
                require(
                    live_details.window.is_visible() && live_details.text().contains("CPU"),
                    "Hiding graphs closed their live details",
                )?;
                live_details.window.close();
                menu_action(shell, "show-all", None);
                require(
                    *shell.settings.borrow() == original,
                    "Show-all changed source, weather, theme or graph order preferences",
                )?;
                menu_action(shell, "preferences", None);
                let prefs = shell
                    .dialog
                    .borrow()
                    .clone()
                    .ok_or("Menu preferences action failed")?;
                prefs.cancel.emit_clicked();
                menu_action(shell, "ai", None);
                let ai = shell
                    .ai_window
                    .borrow()
                    .clone()
                    .ok_or("Menu AI action failed")?;
                ai.cancel.emit_clicked();
                menu_action(shell, "processes", None);
                let processes = shell
                    .processes
                    .borrow()
                    .clone()
                    .ok_or("Menu processes action failed")?;
                processes.window.close();
                menu_action(shell, "weather", None);
                let weather = shell
                    .weather_window
                    .borrow()
                    .clone()
                    .ok_or("Menu weather action failed")?;
                weather.close.emit_clicked();
                menu_action(shell, "about", None);
                let about = shell
                    .window
                    .application()
                    .unwrap()
                    .windows()
                    .into_iter()
                    .find_map(|w| w.downcast::<gtk::AboutDialog>().ok())
                    .ok_or("Menu About action failed")?;
                require(
                    about.program_name().as_deref() == Some("XRG-ng")
                        && about.version().as_deref() == Some(env!("CARGO_PKG_VERSION")),
                    "About metadata incorrect",
                )?;
                about.close();
                require(
                    shell.window.lookup_action("quit").is_some(),
                    "Quit action missing",
                )?;
                self.expected = Some(shell.settings.borrow().clone());
                self.stage = 23;
            }
            23 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Context-menu layout changes did not persist",
                )?;
                let dialog = shell.preferences();
                dialog.load_legacy(self.root.join("legacy-invalid.ini"));
                require(
                    dialog.is_busy()
                        && !dialog.apply.is_sensitive()
                        && !dialog.reset.is_sensitive(),
                    "Import I/O did not lock draft controls",
                )?;
                self.dialog = Some(dialog);
                self.stage = 24;
            }
            24 if self.dialog.as_ref().is_some_and(|d| !d.is_busy()) => {
                let dialog = self.dialog.as_ref().unwrap();
                require(
                    dialog.review().is_none()
                        && dialog.message().contains("expected true or false"),
                    "Invalid legacy settings did not report failure",
                )?;
                require(
                    dialog.draft() == *self.expected.as_ref().unwrap()
                        && *shell.settings.borrow() == *self.expected.as_ref().unwrap(),
                    "Failed import changed draft or active settings",
                )?;
                dialog.load_legacy(self.root.join("legacy.ini"));
                self.stage = 25;
            }
            25 if self.since.elapsed() > Duration::from_millis(200)
                && self.dialog.as_ref().is_some_and(|d| !d.is_busy()) =>
            {
                let dialog = self.dialog.as_ref().unwrap();
                let review = dialog
                    .review()
                    .ok_or("Valid import did not open a preview")?;
                require(
                    review.report().contains("[Modules] show_cpu = false")
                        && review.report().contains("[Window] opacity")
                        && review.report().contains("[AIToken] claude_cap"),
                    "Import preview omitted mapped values or unsupported entries",
                )?;
                require(
                    dialog.draft() == *self.expected.as_ref().unwrap(),
                    "Preview changed draft before acceptance",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_IMPORT_IMAGE") {
                    review.snapshot(&PathBuf::from(path))?;
                }
                review.cancel.emit_clicked();
                require(
                    dialog.review().is_none() && dialog.draft() == *self.expected.as_ref().unwrap(),
                    "Cancelling preview changed draft",
                )?;
                dialog.load_legacy(self.root.join("legacy.ini"));
                self.stage = 26;
            }
            26 if self.dialog.as_ref().is_some_and(|d| !d.is_busy()) => {
                let dialog = self.dialog.take().unwrap();
                let review = dialog.review().ok_or("Second import preview missing")?;
                review.accept.emit_clicked();
                require(
                    dialog.draft() != *self.expected.as_ref().unwrap()
                        && *shell.settings.borrow() == *self.expected.as_ref().unwrap(),
                    "Import acceptance changed active settings before Apply",
                )?;
                require(
                    dialog.message().contains("Apply to use and save"),
                    "Import draft did not explain Apply",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == *self.expected.as_ref().unwrap(),
                    "Cancelling imported Preferences saved the draft",
                )?;
                let dialog = shell.preferences();
                dialog.load_legacy(self.root.join("legacy.ini"));
                self.dialog = Some(dialog);
                self.stage = 27;
            }
            27 if self.dialog.as_ref().is_some_and(|d| !d.is_busy()) => {
                let dialog = self.dialog.take().unwrap();
                let review = dialog.review().ok_or("Final import preview missing")?;
                review.accept.emit_clicked();
                let candidate = dialog.draft();
                require(
                    candidate.ai == self.expected.as_ref().unwrap().ai
                        && candidate.weather == self.expected.as_ref().unwrap().weather
                        && candidate.metrics == self.expected.as_ref().unwrap().metrics,
                    "Import changed current service or metric source choices",
                )?;
                dialog.apply.emit_clicked();
                require(
                    *shell.settings.borrow() == candidate,
                    "Imported draft did not apply",
                )?;
                self.expected = Some(candidate);
                self.stage = 28;
            }
            28 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Imported settings did not persist",
                )?;
                require(
                    fs::read_to_string(self.root.join("legacy.ini")).map_err(|e| e.to_string())?
                        == LEGACY_FIXTURE,
                    "Import modified the original legacy file",
                )?;
                let dialog = shell.preferences();
                dialog.load_legacy(self.root.join("legacy.ini"));
                dialog.cancel.emit_clicked();
                self.dialog = Some(dialog);
                self.stage = 29;
            }
            29 if self.since.elapsed() > Duration::from_millis(300) => {
                let dialog = self.dialog.take().unwrap();
                require(
                    dialog.review().is_none() && !dialog.window.is_visible(),
                    "Import read opened a preview after Preferences closed",
                )?;
                require(
                    *shell.settings.borrow() == *self.expected.as_ref().unwrap(),
                    "Late import read changed active settings",
                )?;
                // Display changes are drafts until Apply, including a cancelled
                // attempt to switch back from the imported horizontal layout.
                let before = shell.settings.borrow().clone();
                let dialog = shell.preferences();
                dialog.layout.set_selected(0);
                dialog.temperature_units.set_selected(0);
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == before,
                    "Cancelled display preferences changed active settings",
                )?;
                let dialog = shell.preferences();
                dialog.layout.set_selected(1);
                dialog.temperature_units.set_selected(1);
                dialog.height.set_value(136.);
                for module in Module::ALL {
                    dialog.check(module).set_active(matches!(
                        module,
                        Module::Cpu | Module::Temperature | Module::Gpu | Module::Tpu
                    ));
                }
                for _ in 0..12 {
                    dialog.move_up(Module::Temperature);
                }
                dialog.apply.emit_clicked();
                self.expected = Some(shell.settings.borrow().clone());
                self.stage = 30;
            }
            30 if shell.saved_revision.get() == shell.revision.get()
                && self.since.elapsed() > Duration::from_millis(300) =>
            {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Display preferences did not persist",
                )?;
                require(
                    loaded.layout == Layout::Horizontal
                        && loaded.temperature_units == Units::Fahrenheit,
                    "Display choices did not apply",
                )?;
                require(
                    shell.graphs.orientation() == gtk::Orientation::Horizontal
                        && shell.scroll.hscrollbar_policy() == gtk::PolicyType::Automatic,
                    "Horizontal layout did not enable side scrolling",
                )?;
                let adjustment = shell.scroll.hadjustment();
                require(
                    adjustment.upper() > adjustment.page_size(),
                    "Horizontal graphs are clipped without scroll range",
                )?;
                let area = &shell.areas[Module::Temperature.index()];
                require(
                    area.width() >= 360 && area.height() == 136,
                    "Horizontal graph dimensions were not preserved",
                )?;
                // Fixture replaces only one copied panel; no hardware required.
                let mut state = shell.state.borrow_mut();
                let panel = &mut state.as_mut().unwrap().panels[Module::Temperature.index()];
                let label = Text::reading("", -25., " max · fixture");
                let detail = Text::reading("Sensor named 25.0 °C: ", -25., "");
                panel.label = label.render(Units::Celsius).into_owned();
                panel.detail = detail.render(Units::Celsius).into_owned();
                panel.temperature_text = Some((label, detail));
                panel.series = vec![vec![-40., 0., -25.]];
                drop(state);
                shell.refresh();
                require(
                    area.tooltip_text()
                        .is_some_and(|s| s == "Sensor named 25.0 °C: -13.0 °F"),
                    "Tooltip did not convert only the typed temperature",
                )?;
                let details = shell.details(Module::Temperature);
                require(
                    details.text().contains("-13.0 °F max")
                        && details.text().contains("Sensor named 25.0 °C: -13.0 °F"),
                    "Live details did not use Fahrenheit",
                )?;
                let mut changed = loaded.clone();
                changed.temperature_units = Units::Celsius;
                shell.apply(changed);
                require(
                    details.text().contains("-25.0 °C max") && !details.text().contains("°F"),
                    "Unit switch did not immediately refresh open details",
                )?;
                require(
                    shell.state.borrow().as_ref().unwrap().panels[Module::Temperature.index()]
                        .series[0]
                        == [-40., 0., -25.],
                    "Unit change reset or converted collector history",
                )?;
                shell.apply(loaded);
                details.window.close();
                self.stage = 31;
            }
            31 if self.since.elapsed() > Duration::from_millis(300) => {
                if let Some(path) = std::env::var_os("XRG_SMOKE_LAYOUT_IMAGE") {
                    shell.snapshot(&PathBuf::from(path))?;
                }
                let dialog = shell.preferences();
                require(
                    dialog.layout.selected() == 1 && dialog.temperature_units.selected() == 1,
                    "Reopened display controls lost active choices",
                )?;
                dialog.reset.emit_clicked();
                require(
                    dialog.layout.selected() == 0 && dialog.temperature_units.selected() == 0,
                    "Restore defaults did not reset display draft",
                )?;
                require(
                    shell.settings.borrow().layout == Layout::Horizontal,
                    "Restore defaults applied before Apply",
                )?;
                dialog.apply.emit_clicked();
                self.expected = Some(shell.settings.borrow().clone());
                self.stage = 32;
            }
            32 if shell.saved_revision.get() == shell.revision.get()
                && self.since.elapsed() > Duration::from_millis(300) =>
            {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && loaded == *self.expected.as_ref().unwrap(),
                    "Reset display preferences did not persist",
                )?;
                require(
                    shell.graphs.orientation() == gtk::Orientation::Vertical
                        && shell.scroll.hscrollbar_policy() == gtk::PolicyType::Never
                        && loaded.temperature_units == Units::Celsius,
                    "Switching back to vertical/Celsius failed",
                )?;
                return Ok(true);
            }
            _ => (),
        }
        if self.stage != before {
            self.since = Instant::now();
            eprintln!("GTK_PREFERENCES_STAGE {}", self.stage);
        }
        Ok(false)
    }
}
fn menu_action(shell: &Shell, name: &str, module: Option<Module>) {
    let value = module.map(|m| (m.index() as u32).to_variant());
    gtk::gio::prelude::ActionGroupExt::activate_action(&shell.window, name, value.as_ref());
}
impl Drop for Harness {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
