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
use xrg_ng_linux::settings::{
    GraphStyle, Layout, Module, Settings, Store, ThemeChoice, ThemeDocument,
};
use xrg_ng_linux::temperature::{Text, Units};
const LEGACY_FIXTURE: &str = "# Automated legacy import fixture\n[Modules]\nshow_cpu=false\nshow_network=false\nshow_aitoken=false\n[Colors]\nbackground=rgba(8,16,32,0.9)\ngraph_fg1=rgba(0,128,255,0.75)\ntext=#eeeeee\nactivity_bar=rgba(0,255,128,0.5)\n[Appearance]\ntheme=Legacy fixture\n[Window]\nx=25\nopacity=0.6\n[Display]\nlayout_orientation=1\nshow_activity_bars=true\nactivity_bar_style=2\n[Temperature]\nunits=1\n[GraphStyles]\ncpu_style=2\n[AIToken]\nshow_model_breakdown=false\nclaude_cap=123456\n";
pub(super) struct Harness {
    root: PathBuf,
    stage: u8,
    theme_import: Option<super::theme_import_smoke::Harness>,
    ai_view: Option<super::ai_view_smoke::Harness>,
    sampling: Option<super::sampling_smoke::Harness>,
    opacity: Option<super::opacity_smoke::Harness>,
    window_size: Option<super::window_size_smoke::Harness>,
    network_scale: Option<super::network_scale_smoke::Harness>,
    xe_pmu: Option<super::xe_pmu_smoke::Harness>,
    process_details: Option<super::process_details_smoke::Harness>,
    weather_graph: Option<super::weather_graph_smoke::Harness>,
    process_actions: Option<super::process_actions_smoke::Harness>,
    dialog: Option<Rc<Dialog>>,
    process: Option<Rc<super::processes::Window>>,
    ai: Option<Rc<super::ai::Window>>,
    weather: Option<Rc<super::weather::Window>>,
    menu: Option<gtk::PopoverMenu>,
    menu_paintable: Option<gtk::WidgetPaintable>,
    details: Option<Rc<super::menus::Details>>,
    neural_panel: Option<xrg_ng_linux::engine::Panel>,
    memory_panel: Option<xrg_ng_linux::engine::Panel>,
    cpu_panel: Option<xrg_ng_linux::engine::Panel>,
    style_preview: Option<(gtk::Window, gtk::WidgetPaintable)>,
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
        if let Ok(name) = std::env::var("XRG_SMOKE_STYLE") {
            let settings = Settings {
                theme: ThemeChoice::Builtin { name },
                ..Settings::default()
            };
            settings.validate()?;
            fs::write(
                root.join("settings.conf"),
                serde_json::to_vec(&settings).unwrap(),
            )
            .map_err(|e| e.to_string())?;
        }
        if std::env::var("XRG_SMOKE_WEATHER_GRAPH").as_deref() == Ok("1") {
            let mut settings = Settings {
                theme: ThemeChoice::Builtin {
                    name: "Midnight".into(),
                },
                ..Settings::default()
            };
            for m in &mut settings.modules {
                m.visible = matches!(m.id, Module::Cpu | Module::Memory);
            }
            settings.module_mut(Module::Weather).height = Some(128);
            fs::write(
                root.join("settings.conf"),
                serde_json::to_vec(&settings).unwrap(),
            )
            .map_err(|e| e.to_string())?;
        }
        if std::env::var("XRG_SMOKE_XE_PMU").as_deref() == Ok("1") {
            // Preserve real proc/disk counter validation without exposing DRM
            // or PMU sysfs. These are names/directories, never device links.
            let block = root.join("xe-policy-sysfs/block");
            fs::create_dir_all(&block).map_err(|e| e.to_string())?;
            for entry in fs::read_dir("/sys/block")
                .map_err(|e| e.to_string())?
                .take(4097)
            {
                let entry = entry.map_err(|e| e.to_string())?;
                fs::create_dir(block.join(entry.file_name())).map_err(|e| e.to_string())?;
            }
            let settings = Settings {
                sampling_interval_ms: 10000,
                ..Settings::default()
            };
            fs::write(
                root.join("settings.conf"),
                serde_json::to_vec(&settings).unwrap(),
            )
            .map_err(|e| e.to_string())?;
        }
        if std::env::var("XRG_SMOKE_NETWORK_SCALE").as_deref() == Ok("1") {
            fs::write(
                root.join("settings.conf"),
                serde_json::to_vec(&Settings::default()).unwrap(),
            )
            .map_err(|e| e.to_string())?;
        }
        if std::env::var("XRG_SMOKE_WINDOW_SIZE").as_deref() == Ok("1") {
            let settings = Settings {
                window_size: Some(xrg_ng_linux::settings::WindowSize {
                    width: 720,
                    height: 480,
                }),
                ..Settings::default()
            };
            fs::write(
                root.join("settings.conf"),
                serde_json::to_vec(&settings).unwrap(),
            )
            .map_err(|e| e.to_string())?;
        }
        if std::env::var("XRG_SMOKE_OPACITY").as_deref() == Ok("1") {
            let settings = Settings {
                window_opacity: 0.65,
                ..Settings::default()
            };
            fs::write(
                root.join("settings.conf"),
                serde_json::to_vec(&settings).unwrap(),
            )
            .map_err(|e| e.to_string())?;
        }
        if std::env::var("XRG_SMOKE_SAMPLING").as_deref() == Ok("1") {
            let settings = Settings {
                sampling_interval_ms: 10000,
                ..Settings::default()
            };
            fs::write(
                root.join("settings.conf"),
                serde_json::to_vec(&settings).unwrap(),
            )
            .map_err(|e| e.to_string())?;
        }
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
            xe_pmu: (std::env::var("XRG_SMOKE_XE_PMU").as_deref() == Ok("1"))
                .then(super::xe_pmu_smoke::Harness::new),
            network_scale: (std::env::var("XRG_SMOKE_NETWORK_SCALE").as_deref() == Ok("1"))
                .then(super::network_scale_smoke::Harness::new),
            window_size: (std::env::var("XRG_SMOKE_WINDOW_SIZE").as_deref() == Ok("1"))
                .then(super::window_size_smoke::Harness::new),
            opacity: (std::env::var("XRG_SMOKE_OPACITY").as_deref() == Ok("1"))
                .then(super::opacity_smoke::Harness::new),
            sampling: (std::env::var("XRG_SMOKE_SAMPLING").as_deref() == Ok("1"))
                .then(super::sampling_smoke::Harness::new),
            ai_view: (std::env::var("XRG_SMOKE_AI_VIEW").as_deref() == Ok("1"))
                .then(super::ai_view_smoke::Harness::new),
            theme_import: (std::env::var("XRG_SMOKE_XTF_THEME").as_deref() == Ok("1"))
                .then(super::theme_import_smoke::Harness::new),
            process_details: (std::env::var("XRG_SMOKE_PROCESS_DETAILS").as_deref() == Ok("1"))
                .then(super::process_details_smoke::Harness::new),
            weather_graph: (std::env::var("XRG_SMOKE_WEATHER_GRAPH").as_deref() == Ok("1"))
                .then(super::weather_graph_smoke::Harness::new),
            process_actions: if std::env::var("XRG_SMOKE_PROCESS_ACTIONS").as_deref() == Ok("1") {
                Some(super::process_actions_smoke::Harness::new()?)
            } else {
                None
            },
            dialog: None,
            process: None,
            ai: None,
            weather: None,
            menu: None,
            menu_paintable: None,
            details: None,
            neural_panel: None,
            memory_panel: None,
            cpu_panel: None,
            style_preview: None,
            expected: None,
            since: Instant::now(),
        })
    }
    pub fn preferences_path(&self) -> PathBuf {
        self.root.join("settings.conf")
    }
    fn neural_fixture(&self) -> Result<xrg_ng_linux::engine::Panel, String> {
        let create = || -> std::io::Result<xrg_ng_linux::engine::Panel> {
            let sys = self.root.join("neural-fixture");
            for (name, vendor, id, driver) in [
                ("0000:00:0b.0", "0x8086", "0x7d1d", "intel_vpu"),
                ("0000:01:00.0", "0x1022", "0x17f0", "amdxdna"),
            ] {
                let device = sys.join("bus/pci/devices").join(name);
                let bound = sys.join("drivers").join(driver);
                fs::create_dir_all(&device)?;
                fs::create_dir_all(&bound)?;
                fs::write(device.join("vendor"), vendor)?;
                fs::write(device.join("device"), id)?;
                std::os::unix::fs::symlink(bound, device.join("driver"))?;
                if driver == "intel_vpu" {
                    fs::write(device.join("npu_busy_time_us"), "0")?;
                }
            }
            for (name, compatible, driver) in [
                ("ane", "apple,t8103-ane\0", "ane"),
                ("npu", "rockchip,rk3588-rknpu\0", "rknpu"),
                ("cdsp", "qcom,x1e80100-cdsp-pas\0", "qcom_q6v5_pas"),
            ] {
                let device = sys.join("bus/platform/devices").join(name);
                let bound = sys.join("drivers").join(driver);
                fs::create_dir_all(device.join("of_node"))?;
                fs::create_dir_all(&bound)?;
                fs::write(device.join("of_node/compatible"), compatible)?;
                std::os::unix::fs::symlink(bound, device.join("driver"))?;
            }
            fs::create_dir_all(sys.join("kernel/debug/rknpu"))?;
            fs::write(
                sys.join("kernel/debug/rknpu/load"),
                "NPU load: Core0: 0%, Core1: 50%, Core2: 100%,",
            )?;
            let mut sampler = xrg_ng_linux::engine::Sampler::with_sources(
                xrg_ng_linux::collectors::LinuxSources::with_roots(sys.join("proc"), &sys),
            );
            sampler.sample();
            let mut panel = sampler.sample().panels.remove(Module::Tpu.index());
            panel.detail = format!(
                "Automated UI fixture — not live hardware\n\n{}",
                panel.detail
            );
            panel.temperature_text = None;
            Ok(panel)
        };
        create().map_err(|e| e.to_string())
    }
    fn sensor_fixture(
        &self,
    ) -> Result<
        (
            Vec<xrg_ng_linux::engine::Panel>,
            Vec<xrg_ng_linux::engine::Panel>,
        ),
        String,
    > {
        let create = || -> std::io::Result<_> {
            let sys = self.root.join("multi-sensors-fixture");
            let directory = sys.join("class/hwmon/hwmon0");
            fs::create_dir_all(&directory)?;
            fs::write(directory.join("name"), "Fixture board")?;
            for (channel, temp, rpm, label) in [
                (1, "-20000", "1200", "Ambient"),
                (2, "0", "0", "Board"),
                (3, "65000", "2400", "Package"),
            ] {
                fs::write(directory.join(format!("temp{channel}_input")), temp)?;
                fs::write(directory.join(format!("temp{channel}_label")), label)?;
                fs::write(directory.join(format!("fan{channel}_input")), rpm)?;
                fs::write(directory.join(format!("fan{channel}_label")), label)?;
            }
            let temperatures = xrg_ng_linux::hardware::temperature_sources(&sys)
                .map_err(std::io::Error::other)?
                .values;
            let fans = xrg_ng_linux::hardware::fans(&sys)
                .map_err(std::io::Error::other)?
                .values;
            let selection = xrg_ng_linux::settings::MetricSelection {
                temperature: Some(temperatures[0].source_id.clone()),
                temperature_extra: [
                    Some(temperatures[1].source_id.clone()),
                    Some(temperatures[2].source_id.clone()),
                ],
                fan: Some(fans[0].source_id.clone()),
                fan_extra: [
                    Some(fans[1].source_id.clone()),
                    Some(fans[2].source_id.clone()),
                ],
                ..Default::default()
            };
            let mut sampler = xrg_ng_linux::engine::Sampler::with_sources(
                xrg_ng_linux::collectors::LinuxSources::with_roots(sys.join("proc"), &sys),
            );
            sampler
                .set_selection(selection)
                .map_err(std::io::Error::other)?;
            for _ in 0..119 {
                sampler.sample();
            }
            let complete = sampler.sample().panels;
            fs::remove_file(directory.join("temp2_input"))?;
            fs::remove_file(directory.join("fan2_input"))?;
            let partial = sampler.sample().panels;
            Ok((complete, partial))
        };
        let panels = create().map_err(|e| e.to_string())?;
        for index in [Module::Temperature.index(), Module::Fans.index()] {
            require(
                panels.1[index].series.len() == 3
                    && panels.1[index].series[1].iter().all(|v| v.is_nan())
                    && panels.1[index].series[2]
                        .last()
                        .is_some_and(|v| v.is_finite()),
                "Missing fixture sensor shifted another curve",
            )?;
        }
        require(
            panels.0[Module::Fans.index()].series[1].last() == Some(&0.),
            "Stopped fixture fan is unavailable",
        )?;
        Ok(panels)
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
                temperature: inventory.temperatures.first().map(|s| s.id.clone()),
                fan: inventory.fans.first().map(|s| s.id.clone()),
                ..Default::default()
            });
        dialog.check(Module::Cpu).set_active(false);
        for _ in 0..9 {
            dialog.move_up(Module::Tpu);
        }
        dialog.height.set_value(112.);
        dialog.name.set_text("Smoke custom");
        dialog.colors[2].set_rgba(&gtk::gdk::RGBA::new(0.2, 0.8, 0.9, 0.85));
    }
    pub fn summary(&self) -> &'static str {
        if self.xe_pmu.is_some() {
            return "xe-policy=opt-in-cancel-defaults-persist-worker-wake";
        }
        if self.network_scale.is_some() {
            return "network-scale=cached-axis-history-cancel-apply-persist";
        }
        if self.window_size.is_some() {
            return "window-size=startup-cancel-apply-capture-auto";
        }
        if self.opacity.is_some() {
            return "opacity=startup-cancel-defaults-apply-persist";
        }
        if self.sampling.is_some() {
            return "sampling=wake-cancel-apply-persist";
        }
        if self.ai_view.is_some() {
            return "ai-view=grouped-cached-history-preserved";
        }
        if self.theme_import.is_some() {
            return "xtf-theme=classic-srgb-p3-import-cancel-apply-export";
        }
        if self.process_details.is_some() {
            return "process-details=identity-and-freshness";
        }
        if self.weather_graph.is_some() {
            return "weather-graph=fixture-no-network";
        }
        if std::env::var_os("XRG_SMOKE_STYLE").is_some() {
            return "compact-style live Linux readings";
        }
        if self.process_actions.is_some() {
            "process-controls=signals"
        } else {
            "preferences=roundtrip"
        }
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64) -> Result<bool, String> {
        if let Some(harness) = &mut self.xe_pmu {
            let done = harness.tick(shell, sequence, &self.root)?;
            if done {
                require(
                    harness.tick(shell, sequence, &self.root)?,
                    "Xe smoke completion was not stable",
                )?;
            }
            return Ok(done);
        }
        if let Some(harness) = &mut self.network_scale {
            let finished = harness.tick(shell, sequence, &self.root)?;
            if finished {
                require(
                    harness.tick(shell, sequence, &self.root)?,
                    "Network scale completion was not stable",
                )?;
            }
            return Ok(finished);
        }
        if let Some(harness) = &mut self.window_size {
            let finished = harness.tick(shell, sequence, &self.root)?;
            if finished {
                require(
                    harness.tick(shell, sequence, &self.root)?,
                    "Window size completion was not stable",
                )?;
            }
            return Ok(finished);
        }
        if let Some(harness) = &mut self.opacity {
            let finished = harness.tick(shell, sequence, &self.root)?;
            if finished {
                require(
                    harness.tick(shell, sequence, &self.root)?,
                    "Opacity completion was not stable",
                )?;
            }
            return Ok(finished);
        }
        if let Some(harness) = &mut self.sampling {
            let finished = harness.tick(shell, sequence, &self.root)?;
            if finished {
                require(
                    harness.tick(shell, sequence, &self.root)?,
                    "Sampling smoke completion was not stable",
                )?;
            }
            return Ok(finished);
        }
        if let Some(harness) = &mut self.ai_view {
            let finished = harness.tick(shell, sequence, &self.root)?;
            if finished {
                // Reproduce fast completion followed by another driver tick,
                // even when this machine already satisfies the drawing gate.
                require(
                    harness.tick(shell, sequence, &self.root)?,
                    "AI display smoke completion was not stable",
                )?;
            }
            return Ok(finished);
        }
        if let Some(harness) = &mut self.theme_import {
            return harness.tick(shell, sequence, &self.root);
        }
        if let Some(harness) = &mut self.process_details {
            return harness.tick(shell, sequence);
        }
        if let Some(harness) = &mut self.weather_graph {
            return harness.tick(shell, sequence);
        }
        if let Some(harness) = &mut self.process_actions {
            return harness.tick(shell);
        }
        if std::env::var_os("XRG_SMOKE_STYLE").is_some() {
            if sequence < 8 {
                return Ok(false);
            }
            require(
                shell.window.width() <= 180,
                "Compact window is wider than the Mac strip",
            )?;
            require(
                !shell.status.is_visible(),
                "Routine status takes up graph space",
            )?;
            let settings = shell.settings.borrow();
            for module in settings.modules.iter().filter(|m| m.visible) {
                let area = &shell.areas[module.id.index()];
                require(
                    area.width() >= 140 && area.height() == 90,
                    "Compact graph geometry changed",
                )?;
            }
            let last = settings.modules.iter().rev().find(|m| m.visible).unwrap();
            let bounds = shell.areas[last.id.index()]
                .compute_bounds(&shell.window)
                .ok_or("No graph bounds")?;
            require(
                bounds.y() + bounds.height() <= shell.window.height() as f32,
                "Last graph is clipped",
            )?;
            let state = shell.state.borrow();
            let cpu = &state.as_ref().ok_or("No snapshot")?.panels[Module::Cpu.index()];
            require(
                cpu.readout.top.len() == 4 && !cpu.readout.cores.is_empty(),
                "CPU compact readings missing",
            )?;
            require(
                shell.window.lookup_action("preferences").is_some()
                    && shell.chooser.parent().is_some(),
                "Menu lost preferences or theme access",
            )?;
            return Ok(true);
        }
        let before = self.stage;
        if let Some(panel) = &self.neural_panel {
            if let Some(snapshot) = shell.state.borrow_mut().as_mut() {
                snapshot.panels[Module::Tpu.index()] = panel.clone();
            }
            shell.update_panel_text();
            shell.update_details();
            shell.areas[Module::Tpu.index()].queue_draw();
        }
        if let Some(panel) = &self.memory_panel {
            if let Some(snapshot) = shell.state.borrow_mut().as_mut() {
                snapshot.panels[Module::Memory.index()] = panel.clone();
            }
            shell.update_panel_text();
            shell.update_details();
            shell.areas[Module::Memory.index()].queue_draw();
        }
        if let Some(panel) = &self.cpu_panel {
            if let Some(snapshot) = shell.state.borrow_mut().as_mut() {
                snapshot.panels[Module::Cpu.index()] = panel.clone();
            }
            shell.update_panel_text();
            shell.update_details();
            shell.areas[Module::Cpu.index()].queue_draw();
        }
        match self.stage {
            0 if sequence >= 2 => {
                shell.chooser.set_selected(4);
                self.stage = 1;
            }
            1 if sequence >= 3 => {
                shell.chooser.set_selected(2);
                self.stage = 2;
            }
            2 if sequence >= 4
                && shell
                    .settings
                    .borrow()
                    .modules
                    .iter()
                    .filter(|m| m.visible)
                    .all(|m| shell.draws[m.id.index()].get() >= 3) =>
            {
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
                    loaded.version == 21 && loaded.processes.limit == 20,
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
                window.update(Some(&fixture), &active, true);
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
                window.update(Some(&fixture), &stale, true);
                require(
                    !window.usage_text().contains("fixture-model")
                        && !window.usage_text().contains("fixture-claude")
                        && !window.usage_text().contains("Unattributed")
                        && window.usage_text().contains("Waiting for the AI worker"),
                    "Stale AI report survived a source change",
                )?;
                window.update(Some(&fixture), &active, true);
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
                            == Some(shell.areas[original.modules[1].id.index()].upcast_ref()),
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
                let mut shown = original.clone();
                for module in &mut shown.modules {
                    module.visible = true;
                }
                require(
                    *shell.settings.borrow() == shown,
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
                        && review
                            .report()
                            .contains("[AIToken] show_model_breakdown = false")
                        && review.report().contains("[Window] opacity = 0.6")
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
                        && candidate.metrics == self.expected.as_ref().unwrap().metrics
                        && candidate.activity_bars.visible
                        && candidate.window_opacity == 0.6
                        && !candidate.ai_show_model_breakdown
                        && candidate.activity_bars.style == GraphStyle::Dot
                        && candidate.activity_bars.color == [0., 1., 128. / 255., 0.5],
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
                dialog.width.set_value(360.);
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
                    area.tooltip_text().is_some_and(|s| {
                        s.split("\n\n").next() == Some("Sensor named 25.0 °C: -13.0 °F")
                            && s.contains("graph axis: -40.0–248.0 °F")
                    }),
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
                        && shell.scroll.hscrollbar_policy() == gtk::PolicyType::Automatic
                        && loaded.temperature_units == Units::Celsius,
                    "Switching back to vertical/Celsius failed",
                )?;
                self.neural_panel = Some(self.neural_fixture()?);
                self.details = Some(shell.details(Module::Tpu));
                self.details
                    .as_ref()
                    .unwrap()
                    .window
                    .set_default_size(840, 1100);
                self.stage = 33;
            }
            33 if self.since.elapsed() > Duration::from_millis(300) => {
                let details = self.details.take().unwrap();
                let text = details.text();
                for name in [
                    "TPU / NPU",
                    "Intel NPU",
                    "AMD XDNA NPU",
                    "Apple Neural Engine",
                    "Rockchip NPU",
                    "Qualcomm Hexagon / compute DSP",
                ] {
                    require(text.contains(name), &format!("NPU details omitted {name}"))?;
                }
                require(
                    text.contains("Activity: 0.0%")
                        && text.contains("Activity: 50.0%")
                        && text.contains("Activity: unavailable"),
                    "NPU details confused measured zero, load and unavailable activity",
                )?;
                require(
                    shell.state.borrow().as_ref().unwrap().panels[Module::Tpu.index()].scale
                        == xrg_ng_linux::engine::Scale::Percent,
                    "NPU percentage graph uses inference-rate scale",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_NPU_IMAGE") {
                    details.snapshot(&PathBuf::from(path))?;
                }
                details.window.close();
                self.neural_panel.take();
                self.stage = 34;
            }
            34 => {
                let dialog = shell.preferences();
                let selection = dialog.draft().metrics;
                let inventory = xrg_ng_linux::metrics::Inventory {
                    temperatures: (0..3)
                        .map(|i| xrg_ng_linux::metrics::SourceOption {
                            id: if i == 0 {
                                "smoke-temperature-source".into()
                            } else {
                                format!("smoke-temperature-source-{i}")
                            },
                            label: format!("Fixture temperature channel {}", i + 1),
                        })
                        .collect(),
                    fans: (0..3)
                        .map(|i| xrg_ng_linux::metrics::SourceOption {
                            id: if i == 0 {
                                "smoke-fan-source".into()
                            } else {
                                format!("smoke-fan-source-{i}")
                            },
                            label: format!("Fixture fan channel {}", i + 1),
                        })
                        .collect(),
                    ..Default::default()
                };
                dialog.targets.refresh(&inventory, &selection);
                dialog
                    .targets
                    .temperature
                    .select(Some("smoke-temperature-source".into()));
                dialog.targets.fan.select(Some("smoke-fan-source".into()));
                dialog.targets.temperature_extra[0].select(Some("smoke-temperature-source".into()));
                let before = shell.settings.borrow().clone();
                dialog.apply.emit_clicked();
                require(
                    dialog.message().contains("different sensor")
                        && *shell.settings.borrow() == before,
                    "Duplicate sensor selections were accepted",
                )?;
                for i in 0..2 {
                    dialog.targets.temperature_extra[i]
                        .select(Some(format!("smoke-temperature-source-{}", i + 1)));
                    dialog.targets.fan_extra[i].select(Some(format!("smoke-fan-source-{}", i + 1)));
                }
                let cancelled = dialog.draft();
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == before,
                    "Cancelled multi-sensor choices applied",
                )?;
                let dialog = shell.preferences();
                dialog.targets.refresh(&inventory, &dialog.draft().metrics);
                dialog.targets.set(&cancelled.metrics);
                let expected = dialog.draft();
                require(
                    expected.metrics.temperature.as_deref() == Some("smoke-temperature-source")
                        && expected.metrics.fan.as_deref() == Some("smoke-fan-source")
                        && expected.metrics.temperature_extra
                            == [
                                Some("smoke-temperature-source-1".into()),
                                Some("smoke-temperature-source-2".into()),
                            ]
                        && expected.metrics.fan_extra
                            == [
                                Some("smoke-fan-source-1".into()),
                                Some("smoke-fan-source-2".into()),
                            ],
                    "Sensor source controls did not update the draft",
                )?;
                dialog.targets.refresh(
                    &xrg_ng_linux::metrics::Inventory::default(),
                    &expected.metrics,
                );
                require(
                    dialog.targets.value() == expected.metrics,
                    "Sensor source refresh silently switched missing choices",
                )?;
                dialog.apply.emit_clicked();
                require(
                    *shell.settings.borrow() == expected,
                    "Sensor source Apply failed",
                )?;
                self.expected = Some(expected);
                self.stage = 35;
            }
            35 if self.since.elapsed() > Duration::from_millis(300)
                && shell.saved_revision.get() == shell.revision.get()
                && shell.state.borrow().as_ref().is_some_and(|snapshot| {
                    super::snapshot_matches(snapshot, &shell.settings.borrow(), Module::Temperature)
                        && super::snapshot_matches(snapshot, &shell.settings.borrow(), Module::Fans)
                }) =>
            {
                let state = shell.state.borrow();
                let snapshot = state.as_ref().unwrap();
                require(
                    snapshot.panels[Module::Temperature.index()]
                        .series
                        .is_empty()
                        && snapshot.panels[Module::Fans.index()].series.is_empty(),
                    "Missing selected sensor plotted a fallback",
                )?;
                require(
                    snapshot.panels[Module::Temperature.index()]
                        .label
                        .contains("unavailable")
                        && snapshot.panels[Module::Fans.index()]
                            .label
                            .contains("unavailable"),
                    "Missing selected sensor did not show unavailable",
                )?;
                let (_, saved, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && Some(&saved) == self.expected.as_ref(),
                    "Sensor sources did not persist",
                )?;
                let dialog = shell.preferences();
                require(
                    dialog.targets.value() == saved.metrics,
                    "Reopened sensor source controls lost saved choices",
                )?;
                dialog.targets.curves.set_expanded(true);
                let weak = Rc::downgrade(&dialog);
                gtk::glib::timeout_add_local_once(Duration::from_millis(100), move || {
                    if let Some(dialog) = weak.upgrade() {
                        dialog.reveal_sensor_curves();
                    }
                });
                self.dialog = Some(dialog);
                self.stage = 36;
            }
            36 if self.since.elapsed() > Duration::from_millis(300) => {
                let dialog = self.dialog.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_SENSOR_SOURCES_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                dialog.cancel.emit_clicked();
                use xrg_ng_linux::memory::{self, Paging, View};
                let memory = memory::parse(
                    "MemTotal: 8388608 kB\nMemAvailable: 3145728 kB\nMemFree: 1048576 kB\nBuffers: 262144 kB\nCached: 2097152 kB\nSlab: 524288 kB\nSReclaimable: 262144 kB\nSUnreclaim: 262144 kB\nShmem: 131072 kB\nDirty: 128 kB\nWriteback: 0 kB\nSwapTotal: 4194304 kB\nSwapFree: 3145728 kB\n",
                );
                let mut view = View::default();
                let mut panel = None;
                for index in 0..120 {
                    let counters = Ok(Paging {
                        io_kib: Ok([1000 + index * 64, 2000 + index * 32]),
                        swap_pages: Ok([index * 2, index]),
                    });
                    panel = Some(view.panel(&memory, &counters, index as f64 + 1.));
                }
                self.memory_panel = panel;
                self.details = Some(shell.details(Module::Memory));
                self.details
                    .as_ref()
                    .unwrap()
                    .window
                    .set_default_size(840, 900);
                self.stage = 37;
            }
            37 if self.since.elapsed() > Duration::from_millis(300) => {
                let details = self.details.take().unwrap();
                let text = details.text();
                for expected in [
                    "RAM 62.5%",
                    "cache 25.0%",
                    "swap 25.0%",
                    "Page I/O in / out: 64.0 / 32.0 KiB/s",
                    "Swap in / out: 2.0 / 1.0 pages/s",
                    "not stacked",
                ] {
                    require(
                        text.contains(expected),
                        &format!("Memory details omitted {expected}"),
                    )?;
                }
                require(
                    shell.state.borrow().as_ref().unwrap().panels[Module::Memory.index()]
                        .series
                        .len()
                        == 3,
                    "Memory graph lost its independent RAM/cache/swap curves",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_MEMORY_IMAGE") {
                    details.snapshot(&PathBuf::from(path))?;
                }
                details.window.close();
                self.memory_panel.take();
                use xrg_ng_linux::{
                    cpu::{self, Overview, View},
                    metric_sources,
                };
                let overview = Overview {
                    load: cpu::load("2.50 1.25 0.75 3/256 42"),
                    uptime: cpu::uptime("172861.50 999999.00"),
                };
                let mut view = View::default();
                view.panel(
                    metric_sources::cpu_records(
                        "cpu 100 10 30 800 10 2 3 5 900 800\ncpu0 100 10 30 800 10 2 3 5 900 800",
                    ),
                    &overview,
                    None,
                    1.,
                );
                self.cpu_panel = Some(view.panel(metric_sources::cpu_records("cpu 120 15 40 850 15 4 6 10 999 999\ncpu0 120 15 40 850 15 4 6 10 999 999"), &overview, None, 2.).0);
                self.details = Some(shell.details(Module::Cpu));
                self.details
                    .as_ref()
                    .unwrap()
                    .window
                    .set_default_size(840, 900);
                self.stage = 38;
            }
            38 if self.since.elapsed() > Duration::from_millis(300) => {
                let details = self.details.take().unwrap();
                let text = details.text();
                for expected in [
                    "Non-idle: 45.0%",
                    "User including nice: 25.0%",
                    "System including reported IRQ/softirq: 15.0%",
                    "Steal: 5.0%",
                    "2.50 / 1.25 / 0.75",
                    "3 / 256",
                    "Uptime: 2d 00:01:01",
                ] {
                    require(
                        text.contains(expected),
                        &format!("CPU details omitted {expected}"),
                    )?;
                }
                require(
                    shell.state.borrow().as_ref().unwrap().panels[Module::Cpu.index()]
                        .series
                        .iter()
                        .map(|s| *s.last().unwrap())
                        .collect::<Vec<_>>()
                        == [45., 25., 15.],
                    "CPU graph lost its total/user/system curves",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_CPU_IMAGE") {
                    details.snapshot(&PathBuf::from(path))?;
                }
                details.window.close();
                self.cpu_panel.take();
                let before = shell.settings.borrow().clone();
                let dialog = shell.preferences();
                for (module, style) in Module::ALL[..4].iter().zip(GraphStyle::ALL) {
                    dialog.style(*module).set_selected(style.index() as u32);
                    require(
                        dialog
                            .draft()
                            .modules
                            .iter()
                            .find(|m| m.id == *module)
                            .unwrap()
                            .style
                            == style,
                        "Graph style control did not update the draft",
                    )?;
                }
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == before,
                    "Cancelling graph styles changed active settings",
                )?;
                let dialog = shell.preferences();
                for (module, style) in Module::ALL[..4].iter().zip(GraphStyle::ALL) {
                    dialog.style(*module).set_selected(style.index() as u32);
                }
                dialog.apply.emit_clicked();
                self.expected = Some(shell.settings.borrow().clone());
                self.stage = 39;
            }
            39 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, saved, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && Some(&saved) == self.expected.as_ref(),
                    "Per-graph styles did not persist",
                )?;
                let dialog = shell.preferences();
                for (module, style) in Module::ALL[..4].iter().zip(GraphStyle::ALL) {
                    require(
                        dialog.style(*module).selected() == style.index() as u32,
                        "Reopening Preferences lost a graph style",
                    )?;
                }
                dialog.reset.emit_clicked();
                require(
                    dialog
                        .draft()
                        .modules
                        .iter()
                        .all(|m| m.style == GraphStyle::Solid),
                    "Restore defaults did not restore solid styles in the draft",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    Some(&*shell.settings.borrow()) == self.expected.as_ref(),
                    "Cancelling style defaults changed active settings",
                )?;
                let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
                content.set_margin_top(12);
                content.set_margin_bottom(12);
                content.set_margin_start(12);
                content.set_margin_end(12);
                let theme = saved.theme.palette()?;
                for (module, style) in Module::ALL[..4].iter().copied().zip(GraphStyle::ALL) {
                    let area = gtk::DrawingArea::new();
                    area.set_content_height(150);
                    area.set_content_width(600);
                    let theme = theme.clone();
                    let title = format!("{} · {}", module.title(), style.name());
                    let panel = xrg_ng_linux::engine::Panel {
                        title: "Style fixture",
                        label: "Independent curves · fixture data".into(),
                        detail: String::new(),
                        series: vec![
                            vec![60., 80., 65., 90., 70., 80.],
                            vec![30., 45., 25., 60., 30., 55.],
                            vec![10., 15., 5., 30., 10., 20.],
                        ],
                        scale: xrg_ng_linux::engine::Scale::Percent,
                        temperature_text: None,
                        readout: Default::default(),
                    };
                    area.set_draw_func(move |_, context, width, height| {
                        super::draw(
                            context,
                            (width, height),
                            &theme,
                            &title,
                            Some(&panel),
                            Units::Celsius,
                            (style, &Default::default(), 0),
                        )
                    });
                    content.append(&area);
                }
                let window = gtk::Window::builder()
                    .application(&shell.window.application().unwrap())
                    .transient_for(&shell.window)
                    .title("Graph styles · fixture preview")
                    .child(&content)
                    .build();
                let paintable = gtk::WidgetPaintable::new(Some(&window));
                window.present();
                self.style_preview = Some((window, paintable));
                self.stage = 40;
            }
            40 if self.since.elapsed() > Duration::from_millis(300) => {
                let (window, paintable) = self.style_preview.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_STYLES_IMAGE") {
                    super::save_snapshot(&window, &paintable, &PathBuf::from(path))?;
                }
                window.close();
                let before = shell.settings.borrow().clone();
                let dialog = shell.preferences();
                dialog
                    .graph_colors
                    .module
                    .set_selected(Module::Memory.index() as u32);
                dialog.graph_colors.inherit[1].set_active(false);
                dialog.graph_colors.colors[1].set_rgba(&gtk::gdk::RGBA::new(0.85, 0.1, 0.15, 0.6));
                require(
                    !dialog
                        .draft()
                        .modules
                        .iter()
                        .find(|m| m.id == Module::Memory)
                        .unwrap()
                        .colors
                        .is_inherited(),
                    "Graph color edit did not reach draft",
                )?;
                require(
                    *shell.settings.borrow() == before,
                    "Graph color edit applied before Apply",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == before,
                    "Cancelling graph colors changed active settings",
                )?;
                let dialog = shell.preferences();
                dialog
                    .graph_colors
                    .module
                    .set_selected(Module::Memory.index() as u32);
                for (index, rgba) in [(0, [0.02, 0.03, 0.04, 0.9]), (1, [0.85, 0.1, 0.15, 0.6])] {
                    dialog.graph_colors.inherit[index].set_active(false);
                    dialog.graph_colors.colors[index]
                        .set_rgba(&gtk::gdk::RGBA::new(rgba[0], rgba[1], rgba[2], rgba[3]));
                }
                let overrides = dialog
                    .draft()
                    .modules
                    .iter()
                    .find(|m| m.id == Module::Memory)
                    .unwrap()
                    .colors
                    .clone();
                dialog.select_preset(0);
                require(
                    dialog
                        .draft()
                        .modules
                        .iter()
                        .find(|m| m.id == Module::Memory)
                        .unwrap()
                        .colors
                        == overrides,
                    "Theme preset discarded graph overrides",
                )?;
                dialog
                    .graph_colors
                    .module
                    .set_selected(Module::Network.index() as u32);
                require(
                    dialog.graph_colors.inherit.iter().all(|c| c.is_active()),
                    "A graph inherited another graph's overrides",
                )?;
                dialog.apply.emit_clicked();
                self.expected = Some(shell.settings.borrow().clone());
                self.stage = 41;
            }
            41 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, saved, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && Some(&saved) == self.expected.as_ref(),
                    "Graph color overrides did not persist",
                )?;
                let dialog = shell.preferences();
                dialog
                    .graph_colors
                    .module
                    .set_selected(Module::Memory.index() as u32);
                require(
                    !dialog.graph_colors.inherit[0].is_active()
                        && !dialog.graph_colors.inherit[1].is_active()
                        && dialog.graph_colors.inherit[2].is_active()
                        && dialog.graph_colors.inherit[3].is_active(),
                    "Reopening lost per-color inheritance",
                )?;
                let base = saved.theme.palette()?;
                require(
                    dialog.graph_colors.colors[2].rgba()
                        == gtk::gdk::RGBA::new(
                            base.colors[3][0] as f32,
                            base.colors[3][1] as f32,
                            base.colors[3][2] as f32,
                            base.colors[3][3] as f32,
                        ),
                    "Inherited graph color did not follow new theme",
                )?;
                dialog.graph_colors.widget.set_expanded(true);
                self.dialog = Some(dialog);
                self.stage = 42;
            }
            42 if self.since.elapsed() > Duration::from_millis(300) => {
                self.dialog.as_ref().unwrap().reveal_graph_colors();
                self.stage = 43;
            }
            43 if self.since.elapsed() > Duration::from_millis(300) => {
                let dialog = self.dialog.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_GRAPH_COLORS_PREFS_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                dialog.graph_colors.inherit[1].set_active(true);
                require(
                    dialog
                        .draft()
                        .modules
                        .iter()
                        .find(|m| m.id == Module::Memory)
                        .unwrap()
                        .colors
                        .series[0]
                        .is_none(),
                    "Use theme did not clear a single override",
                )?;
                dialog.graph_colors.reset.emit_clicked();
                require(
                    dialog
                        .draft()
                        .modules
                        .iter()
                        .find(|m| m.id == Module::Memory)
                        .unwrap()
                        .colors
                        .is_inherited(),
                    "Graph reset did not clear overrides",
                )?;
                dialog.cancel.emit_clicked();
                let dialog = shell.preferences();
                dialog.reset.emit_clicked();
                require(
                    dialog
                        .draft()
                        .modules
                        .iter()
                        .all(|m| m.colors.is_inherited()),
                    "Restore defaults did not clear graph colors in draft",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    Some(&*shell.settings.borrow()) == self.expected.as_ref(),
                    "Cancelling graph-color resets changed active settings",
                )?;
                let settings = shell.settings.borrow().clone();
                let base = settings.theme.palette()?;
                let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
                content.set_margin_top(12);
                content.set_margin_bottom(12);
                content.set_margin_start(12);
                content.set_margin_end(12);
                for (module, title) in [
                    (Module::Cpu, "CPU · theme colors"),
                    (
                        Module::Memory,
                        "Memory · custom background and primary series",
                    ),
                ] {
                    let appearance = settings.modules.iter().find(|m| m.id == module).unwrap();
                    let palette = appearance.colors.palette(&base);
                    let style = appearance.style;
                    let panel = xrg_ng_linux::engine::Panel {
                        title: "Color fixture",
                        label: "Fixture data · remaining colors inherit the theme".into(),
                        detail: String::new(),
                        series: vec![
                            vec![60., 80., 65., 90., 70., 80.],
                            vec![30., 45., 25., 60., 30., 55.],
                            vec![10., 15., 5., 30., 10., 20.],
                        ],
                        scale: xrg_ng_linux::engine::Scale::Percent,
                        temperature_text: None,
                        readout: Default::default(),
                    };
                    let area = gtk::DrawingArea::new();
                    area.set_content_width(600);
                    area.set_content_height(150);
                    area.set_draw_func(move |_, context, width, height| {
                        super::draw(
                            context,
                            (width, height),
                            &palette,
                            title,
                            Some(&panel),
                            Units::Celsius,
                            (style, &Default::default(), 0),
                        )
                    });
                    content.append(&area);
                }
                let window = gtk::Window::builder()
                    .application(&shell.window.application().unwrap())
                    .transient_for(&shell.window)
                    .title("Per-graph colors · fixture preview")
                    .child(&content)
                    .build();
                let paintable = gtk::WidgetPaintable::new(Some(&window));
                window.present();
                self.style_preview = Some((window, paintable));
                self.stage = 44;
            }
            44 if self.since.elapsed() > Duration::from_millis(300) => {
                let (window, paintable) = self.style_preview.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_GRAPH_COLORS_IMAGE") {
                    super::save_snapshot(&window, &paintable, &PathBuf::from(path))?;
                }
                window.close();
                let before = shell.settings.borrow().clone();
                let dialog = shell.preferences();
                dialog.height.set_value(124.);
                require(
                    dialog.graph_heights.inherit.is_active()
                        && !dialog.graph_heights.height.is_sensitive()
                        && dialog.graph_heights.height.value_as_int() == 124,
                    "Inherited graph height did not follow default control",
                )?;
                dialog
                    .graph_heights
                    .module
                    .set_selected(Module::Memory.index() as u32);
                dialog.graph_heights.inherit.set_active(false);
                dialog.graph_heights.height.set_value(160.);
                require(
                    dialog
                        .draft()
                        .modules
                        .iter()
                        .find(|m| m.id == Module::Memory)
                        .unwrap()
                        .height
                        == Some(160),
                    "Graph height did not reach draft",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == before,
                    "Cancelling graph height changed active settings",
                )?;
                let dialog = shell.preferences();
                dialog.height.set_value(124.);
                dialog.layout.set_selected(0);
                for (id, height) in [(Module::Cpu, 164.), (Module::Memory, 88.)] {
                    dialog.graph_heights.module.set_selected(id.index() as u32);
                    dialog.graph_heights.inherit.set_active(false);
                    dialog.graph_heights.height.set_value(height);
                }
                dialog.apply.emit_clicked();
                self.expected = Some(shell.settings.borrow().clone());
                shell.window.set_default_size(440, 1000);
                shell.scroll.vadjustment().set_value(0.);
                self.stage = 45;
            }
            45 if shell.saved_revision.get() == shell.revision.get()
                && self.since.elapsed() > Duration::from_millis(300) =>
            {
                let (_, saved, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && Some(&saved) == self.expected.as_ref(),
                    "Individual graph heights did not persist",
                )?;
                for (id, height) in [
                    (Module::Cpu, 164),
                    (Module::Memory, 88),
                    (Module::Network, 124),
                ] {
                    require(
                        shell.areas[id.index()].content_height() == height
                            && shell.areas[id.index()].height() == height,
                        "Vertical graph height allocation differs from saved preference",
                    )?;
                }
                if let Some(path) = std::env::var_os("XRG_SMOKE_HEIGHTS_VERTICAL_IMAGE") {
                    shell.snapshot(&PathBuf::from(path))?;
                }
                let dialog = shell.preferences();
                dialog.graph_heights.widget.set_expanded(true);
                for (id, height, inherited) in [
                    (Module::Cpu, 164, false),
                    (Module::Memory, 88, false),
                    (Module::Network, 124, true),
                ] {
                    dialog.graph_heights.module.set_selected(id.index() as u32);
                    require(
                        dialog.graph_heights.height.value_as_int() == height
                            && dialog.graph_heights.inherit.is_active() == inherited,
                        "Reopening Preferences lost graph height/inheritance",
                    )?;
                }
                self.dialog = Some(dialog);
                self.stage = 46;
            }
            46 if self.since.elapsed() > Duration::from_millis(300) => {
                let dialog = self.dialog.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_HEIGHTS_PREFS_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                dialog.height.set_value(112.);
                require(
                    dialog.graph_heights.height.value_as_int() == 112
                        && dialog
                            .draft()
                            .modules
                            .iter()
                            .find(|m| m.id == Module::Cpu)
                            .unwrap()
                            .height
                            == Some(164),
                    "Changing default height overwrote individual size",
                )?;
                dialog.layout.set_selected(1);
                dialog.apply.emit_clicked();
                self.expected = Some(shell.settings.borrow().clone());
                shell.window.set_default_size(1180, 600);
                shell.scroll.hadjustment().set_value(0.);
                self.stage = 47;
            }
            47 if shell.saved_revision.get() == shell.revision.get()
                && self.since.elapsed() > Duration::from_millis(300) =>
            {
                require(
                    shell.graphs.orientation() == gtk::Orientation::Horizontal,
                    "Height fixture did not switch layout",
                )?;
                for (id, height) in [
                    (Module::Cpu, 164),
                    (Module::Memory, 88),
                    (Module::Network, 112),
                ] {
                    require(
                        shell.areas[id.index()].content_height() == height
                            && shell.areas[id.index()].height() == height,
                        "Horizontal graphs stretched individual heights",
                    )?;
                }
                if let Some(path) = std::env::var_os("XRG_SMOKE_HEIGHTS_HORIZONTAL_IMAGE") {
                    shell.snapshot(&PathBuf::from(path))?;
                }
                let dialog = shell.preferences();
                dialog.graph_heights.reset.emit_clicked();
                let mut expected = shell.settings.borrow().clone();
                for module in &mut expected.modules {
                    module.height = None;
                }
                require(
                    dialog.draft() == expected,
                    "Reset graph heights changed unrelated preferences",
                )?;
                dialog.apply.emit_clicked();
                self.expected = Some(expected);
                self.stage = 48;
            }
            48 if shell.saved_revision.get() == shell.revision.get()
                && self.since.elapsed() > Duration::from_millis(300) =>
            {
                let (_, saved, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && Some(&saved) == self.expected.as_ref(),
                    "Reset graph heights did not persist",
                )?;
                require(
                    shell.areas.iter().all(|a| {
                        a.content_height() == 112 && (!a.is_visible() || a.height() == 112)
                    }),
                    "Reset graph heights did not resume default sizing",
                )?;
                let dialog = shell.preferences();
                dialog.graph_heights.inherit.set_active(false);
                dialog.graph_heights.height.set_value(160.);
                dialog.reset.emit_clicked();
                require(
                    dialog.draft().modules.iter().all(|m| m.height.is_none()),
                    "Restore defaults retained a graph height override",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    Some(&*shell.settings.borrow()) == self.expected.as_ref(),
                    "Cancelling size defaults changed active preferences",
                )?;
                let dialog = shell.preferences();
                dialog.activity_visible.set_active(false);
                require(
                    !dialog.activity_style.is_sensitive() && !dialog.activity_color.is_sensitive(),
                    "Hidden bar controls remain enabled",
                )?;
                dialog.activity_visible.set_active(true);
                dialog
                    .activity_style
                    .set_selected(GraphStyle::Pixel.index() as u32);
                dialog
                    .activity_color
                    .set_rgba(&gtk::gdk::RGBA::new(0.5, 0.25, 0.75, 0.5));
                let candidate = dialog.draft();
                require(
                    candidate.activity_bars.visible
                        && candidate.activity_bars.style == GraphStyle::Pixel
                        && candidate.activity_bars.color == [0.5, 0.25, 0.75, 0.5]
                        && !candidate.activity_bars.use_series_colors,
                    "Activity controls missed draft",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    Some(&*shell.settings.borrow()) == self.expected.as_ref(),
                    "Cancelling activity edit applied it",
                )?;
                let dialog = shell.preferences();
                dialog.activity_visible.set_active(true);
                dialog
                    .activity_style
                    .set_selected(GraphStyle::Pixel.index() as u32);
                dialog
                    .activity_color
                    .set_rgba(&gtk::gdk::RGBA::new(0.5, 0.25, 0.75, 0.5));
                dialog.layout.set_selected(0);
                dialog.apply.emit_clicked();
                self.expected = Some(shell.settings.borrow().clone());
                shell.window.set_default_size(440, 1000);
                shell.scroll.vadjustment().set_value(0.);
                self.stage = 49;
            }
            49 if shell.saved_revision.get() == shell.revision.get()
                && self.since.elapsed() > Duration::from_millis(300) =>
            {
                let (_, saved, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && Some(&saved) == self.expected.as_ref(),
                    "Activity bars did not persist",
                )?;
                require(
                    shell.areas[Module::Cpu.index()]
                        .tooltip_text()
                        .is_some_and(|t| t.contains("graph axis")),
                    "Current-value axis missing from tooltip",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_BARS_LIVE_IMAGE") {
                    shell.snapshot(&PathBuf::from(path))?;
                }
                let dialog = shell.preferences();
                require(
                    dialog.activity_visible.is_active()
                        && dialog.activity_style.selected() == 1
                        && dialog.activity_color.rgba()
                            == gtk::gdk::RGBA::new(0.5, 0.25, 0.75, 0.5),
                    "Reopened bar controls lost saved choices",
                )?;
                dialog.activity.set_expanded(true);
                dialog.activity_visible.grab_focus();
                self.dialog = Some(dialog);
                self.stage = 50;
            }
            50 if self.since.elapsed() > Duration::from_millis(300) => {
                let dialog = self.dialog.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_BARS_PREFS_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                dialog.activity_visible.set_active(false);
                dialog.reset.emit_clicked();
                require(
                    dialog.draft().activity_bars == Settings::default().activity_bars,
                    "Restore defaults did not reset bar appearance",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    Some(&*shell.settings.borrow()) == self.expected.as_ref(),
                    "Cancelled bar defaults applied",
                )?;
                let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
                content.set_margin_top(12);
                content.set_margin_bottom(12);
                content.set_margin_start(12);
                content.set_margin_end(12);
                for (index, (title, label, scale, series)) in [
                    (
                        "Solid",
                        "Percent fixtures · 80% / zero / missing",
                        xrg_ng_linux::engine::Scale::Percent,
                        vec![vec![40., 80.], vec![10., 0.], vec![50., f64::NAN]],
                    ),
                    (
                        "Pixel",
                        "Percent fixtures · 80% / zero / missing",
                        xrg_ng_linux::engine::Scale::Percent,
                        vec![vec![40., 80.], vec![10., 0.], vec![50., f64::NAN]],
                    ),
                    (
                        "Dot",
                        "Percent fixtures · 80% / zero / missing",
                        xrg_ng_linux::engine::Scale::Percent,
                        vec![vec![40., 80.], vec![10., 0.], vec![50., f64::NAN]],
                    ),
                    (
                        "Hollow",
                        "Percent fixtures · 80% / zero / missing",
                        xrg_ng_linux::engine::Scale::Percent,
                        vec![vec![40., 80.], vec![10., 0.], vec![50., f64::NAN]],
                    ),
                    (
                        "Signed temperature",
                        "Fixture · −20 °C · same graph range, not a thermal limit",
                        xrg_ng_linux::engine::Scale::Celsius,
                        vec![vec![10., -20.]],
                    ),
                    (
                        "Rate",
                        "Fixture · 500 / 250 B/s · relative to recent graph scale",
                        xrg_ng_linux::engine::Scale::Automatic,
                        vec![vec![1000., 500.], vec![500., 250.]],
                    ),
                    (
                        "Unavailable",
                        "Fixture · missing readings · no bars",
                        xrg_ng_linux::engine::Scale::Percent,
                        vec![],
                    ),
                ]
                .into_iter()
                .enumerate()
                {
                    let panel = xrg_ng_linux::engine::Panel {
                        title: "Activity bar fixture",
                        label: label.into(),
                        detail: String::new(),
                        series,
                        scale,
                        temperature_text: None,
                        readout: Default::default(),
                    };
                    let theme = shell.settings.borrow().theme.palette()?;
                    let bars = xrg_ng_linux::settings::ActivityBars {
                        use_series_colors: false,
                        visible: true,
                        style: GraphStyle::ALL[index.min(3)],
                        color: [0.2, 1., 0.3, 1.],
                    };
                    let area = gtk::DrawingArea::new();
                    area.set_content_width(620);
                    area.set_content_height(112);
                    area.set_draw_func(move |_, context, width, height| {
                        super::draw(
                            context,
                            (width, height),
                            &theme,
                            title,
                            Some(&panel),
                            Units::Celsius,
                            (GraphStyle::Hollow, &bars, 0),
                        );
                    });
                    content.append(&area);
                }
                let window = gtk::Window::builder()
                    .application(&shell.window.application().unwrap())
                    .transient_for(&shell.window)
                    .title("Activity bars · fixture preview")
                    .child(&content)
                    .build();
                let paintable = gtk::WidgetPaintable::new(Some(&window));
                window.present();
                self.style_preview = Some((window, paintable));
                self.stage = 51;
            }
            51 if self.since.elapsed() > Duration::from_millis(300) => {
                let (window, paintable) = self.style_preview.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_BARS_IMAGE") {
                    super::save_snapshot(&window, &paintable, &PathBuf::from(path))?;
                }
                window.close();
                let panels = self.sensor_fixture()?;
                let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
                content.set_margin_top(12);
                content.set_margin_bottom(12);
                content.set_margin_start(12);
                content.set_margin_end(12);
                let intro = gtk::Label::new(Some(
                    "Fixture data · selected curves 1/2/3 · missing curve 2 keeps its slot",
                ));
                content.append(&intro);
                for (panel, title, units) in [
                    (
                        panels.0[Module::Temperature.index()].clone(),
                        "Temperature · complete fixture",
                        Units::Celsius,
                    ),
                    (
                        panels.0[Module::Fans.index()].clone(),
                        "Fans · complete fixture · curve 2 is stopped",
                        Units::Celsius,
                    ),
                    (
                        panels.1[Module::Temperature.index()].clone(),
                        "Temperature · missing curve 2 · Fahrenheit",
                        Units::Fahrenheit,
                    ),
                    (
                        panels.1[Module::Fans.index()].clone(),
                        "Fans · missing curve 2 · no replacement",
                        Units::Celsius,
                    ),
                ] {
                    let theme = shell.settings.borrow().theme.palette()?;
                    let bars = xrg_ng_linux::settings::ActivityBars {
                        use_series_colors: false,
                        visible: true,
                        ..Settings::default().activity_bars
                    };
                    let area = gtk::DrawingArea::new();
                    area.set_content_width(640);
                    area.set_content_height(160);
                    area.set_tooltip_text(Some(&panel.display_detail(units)));
                    area.set_draw_func(move |_, context, width, height| {
                        super::draw(
                            context,
                            (width, height),
                            &theme,
                            title,
                            Some(&panel),
                            units,
                            (GraphStyle::Hollow, &bars, 0),
                        );
                    });
                    content.append(&area);
                }
                let window = gtk::Window::builder()
                    .application(&shell.window.application().unwrap())
                    .transient_for(&shell.window)
                    .title("Multiple sensor curves · fixture preview")
                    .child(&content)
                    .build();
                let paintable = gtk::WidgetPaintable::new(Some(&window));
                window.present();
                self.style_preview = Some((window, paintable));
                self.stage = 52;
            }
            52 if self.since.elapsed() > Duration::from_millis(300) => {
                let (window, paintable) = self.style_preview.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_MULTI_SENSORS_IMAGE") {
                    super::save_snapshot(&window, &paintable, &PathBuf::from(path))?;
                }
                window.close();
                let before = shell.settings.borrow().clone();
                let dialog = shell.preferences();
                dialog.width.set_value(1000.);
                require(
                    dialog.draft().graph_width == 1000,
                    "Width control missed draft",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == before,
                    "Cancelled width applied",
                )?;
                let dialog = shell.preferences();
                dialog.width.set_value(1000.);
                dialog.layout.set_selected(0);
                dialog.apply.emit_clicked();
                let mut expected = before;
                expected.graph_width = 1000;
                expected.layout = Layout::Vertical;
                require(
                    *shell.settings.borrow() == expected,
                    "Width changed unrelated preferences",
                )?;
                self.expected = Some(expected);
                shell.window.set_default_size(680, 700);
                shell.scroll.hadjustment().set_value(0.);
                shell.scroll.vadjustment().set_value(0.);
                self.stage = 53;
            }
            53 if shell.saved_revision.get() == shell.revision.get()
                && self.since.elapsed() > Duration::from_millis(300) =>
            {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && Some(&loaded) == self.expected.as_ref(),
                    "Graph width did not persist",
                )?;
                require(
                    shell.areas.iter().all(|a| {
                        a.content_width() == 1000 && (!a.is_visible() || a.width() >= 1000)
                    }),
                    "Wide vertical graphs lost minimum width",
                )?;
                let range = shell.scroll.hadjustment();
                require(
                    range.upper() > range.page_size(),
                    "Wide vertical graph clipped without a scroll range",
                )?;
                require(
                    shell.window.width() < 1000,
                    "Minimum graph width forced the whole window wider",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_WIDTHS_VERTICAL_IMAGE") {
                    shell.snapshot(&PathBuf::from(path))?;
                }
                let dialog = shell.preferences();
                require(
                    dialog.width.value_as_int() == 1000,
                    "Reopened width control lost saved value",
                )?;
                self.dialog = Some(dialog);
                self.stage = 54;
            }
            54 if self.since.elapsed() > Duration::from_millis(300) => {
                let dialog = self.dialog.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_WIDTHS_PREFS_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                dialog.width.set_value(240.);
                dialog.layout.set_selected(1);
                for module in Module::ALL {
                    dialog.check(module).set_active(matches!(
                        module,
                        Module::Cpu | Module::Memory | Module::Network
                    ));
                }
                dialog.apply.emit_clicked();
                self.expected = Some(shell.settings.borrow().clone());
                shell.window.set_default_size(1000, 600);
                shell.scroll.hadjustment().set_value(0.);
                self.stage = 55;
            }
            55 if shell.saved_revision.get() == shell.revision.get()
                && self.since.elapsed() > Duration::from_millis(300) =>
            {
                let (_, loaded, error) = Store::open(Some(self.preferences_path()));
                require(
                    error.is_none() && Some(&loaded) == self.expected.as_ref(),
                    "Compact horizontal width did not persist",
                )?;
                for module in [Module::Cpu, Module::Memory, Module::Network] {
                    let area = &shell.areas[module.index()];
                    require(
                        area.content_width() == 240 && area.width() >= 240 && area.width() < 1000,
                        "Horizontal minimum width did not apply",
                    )?;
                }
                if let Some(path) = std::env::var_os("XRG_SMOKE_WIDTHS_HORIZONTAL_IMAGE") {
                    shell.snapshot(&PathBuf::from(path))?;
                }
                let before = shell.settings.borrow().clone();
                let dialog = shell.preferences();
                dialog.reset.emit_clicked();
                require(
                    dialog.draft().graph_width == 140,
                    "Restoring defaults retained a custom width",
                )?;
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == before,
                    "Cancelled width defaults applied",
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
