// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Isolated weather presentation fixture. The system worker's weather fetcher is disabled.
use super::{Shell, snapshot_matches};
use gtk::prelude::*;
use std::{
    path::PathBuf,
    rc::Rc,
    time::{Duration, Instant},
};
use xrg_ng_linux::{
    settings::Module,
    shared, temperature,
    weather::{self, Units, Update},
};
pub(super) struct Harness {
    stage: u8,
    since: Instant,
    graph: weather::Graph,
    stale: bool,
    inject: bool,
}
fn require(value: bool, error: &str) -> Result<(), String> {
    if value { Ok(()) } else { Err(error.into()) }
}
impl Harness {
    pub fn new() -> Self {
        let mut graph = weather::Graph::default();
        let first = Update {
            preferences: weather::Preferences {
                enabled: true,
                station: "KSEA".into(),
                ..Default::default()
            },
            observation: shared::metar_latest(
                b"KSEA 271155Z 09010KT 10SM 18/10 Q1013",
                "KSEA",
                1_793_103_000,
            ),
            summary: "Fixture".into(),
            detail: "Fixture · no network".into(),
            stale: false,
            cooldown_seconds: 0,
        };
        graph.panel(Some(&first));
        Self {
            stage: 0,
            since: Instant::now(),
            graph,
            stale: false,
            inject: false,
        }
    }
    fn fixture(&mut self, shell: &Shell) -> Result<(), String> {
        let preferences = shell.settings.borrow().weather.clone();
        let observation = if preferences.enabled {
            shared::metar_latest(
                format!(
                    "{} 271200Z 09010G20KT M1/4SM 20/10 Q1013",
                    preferences.station
                )
                .as_bytes(),
                &preferences.station,
                1_793_103_000,
            )
        } else {
            None
        };
        let update = Update {
            preferences,
            observation,
            summary: "Fixture · no network".into(),
            detail: "Weather graph fixture · no network requests".into(),
            stale: self.stale,
            cooldown_seconds: 0,
        };
        let mut panel = self.graph.panel(Some(&update));
        if let Some(row) = panel.readout.top.first_mut() {
            row.left = "Fixture".into();
        }
        {
            let mut borrowed = shell.state.borrow_mut();
            let state = borrowed.as_mut().ok_or("No worker snapshot")?;
            state.panels[Module::Weather.index()] = panel;
            state.weather = Some(update);
        }
        shell.update_panel_text();
        shell.update_details();
        shell.areas[Module::Weather.index()].queue_draw();
        Ok(())
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64) -> Result<bool, String> {
        if self.inject && sequence >= 2 {
            self.fixture(shell)?;
        }
        let before = self.stage;
        match self.stage {
            0 if sequence >= 2 => {
                let before = shell.settings.borrow().clone();
                let view = shell.weather();
                require(
                    !view.show_graph.is_active(),
                    "Weather graph unexpectedly visible by default",
                )?;
                view.show_graph.set_active(true);
                view.station.set_text(" ksea ");
                view.enabled.set_active(true);
                view.close.emit_clicked();
                require(
                    *shell.settings.borrow() == before,
                    "Cancelled weather graph draft applied",
                )?;
                let view = shell.weather();
                view.show_graph.set_active(true);
                view.station.set_text(" ksea ");
                view.enabled.set_active(true);
                view.apply.emit_clicked();
                require(
                    shell.settings.borrow().module(Module::Weather).visible,
                    "Weather window did not show the graph",
                )?;
                require(
                    shell.settings.borrow().weather.station == "KSEA",
                    "Weather station did not normalize",
                )?;
                view.close.emit_clicked();
                self.inject = true;
                self.stage = 1;
            }
            1 if self.since.elapsed() > Duration::from_millis(350)
                && shell.saved_revision.get() == shell.revision.get() =>
            {
                let area = &shell.areas[Module::Weather.index()];
                require(
                    area.is_visible() && area.height() == 128 && area.width() >= 140,
                    "Weather graph lost its compact allocation",
                )?;
                let state = shell.state.borrow();
                let panel = &state.as_ref().unwrap().panels[Module::Weather.index()];
                require(
                    panel.readout.top.len() == 9 && panel.series[0] == [18., 20.],
                    "Weather readings or deduplicated history missing",
                )?;
                require(
                    panel.readout.top[1].right.render(
                        panel
                            .scale
                            .temperature_units(temperature::Units::Fahrenheit),
                    ) == "20.0 °C",
                    "Metric weather followed system units",
                )?;
                drop(state);
                if let Some(path) = std::env::var_os("XRG_SMOKE_WEATHER_GRAPH_IMAGE") {
                    shell.snapshot(&PathBuf::from(path))?;
                }
                let view = shell.weather();
                require(
                    view.show_graph.is_active(),
                    "Weather visibility did not reopen",
                )?;
                view.units.set_selected(1);
                view.apply.emit_clicked();
                view.close.emit_clicked();
                require(
                    !snapshot_matches(
                        shell.state.borrow().as_ref().unwrap(),
                        &shell.settings.borrow(),
                        Module::Weather,
                    ),
                    "Previous-unit weather snapshot remained current",
                )?;
                self.stage = 2;
            }
            2 if self.since.elapsed() > Duration::from_millis(350) => {
                let state = shell.state.borrow();
                let panel = &state.as_ref().unwrap().panels[Module::Weather.index()];
                require(
                    panel.readout.top[1]
                        .right
                        .render(panel.scale.temperature_units(temperature::Units::Celsius))
                        == "68.0 °F",
                    "US weather display did not stay independent of system units",
                )?;
                require(
                    panel.series[0] == [18., 20.],
                    "Unit change duplicated or converted stored observations",
                )?;
                drop(state);
                let popover = super::menus::popup(shell, Module::Weather, 8., 8.);
                popover.popdown();
                require(
                    shell.window.lookup_action("weather-refresh").is_some(),
                    "Weather graph refresh action missing",
                )?;
                self.stale = true;
                self.stage = 3;
            }
            3 if self.since.elapsed() > Duration::from_millis(350) => {
                let state = shell.state.borrow();
                let panel = &state.as_ref().unwrap().panels[Module::Weather.index()];
                require(
                    panel.readout.top[0]
                        .right
                        .render(temperature::Units::Celsius)
                        == "STALE"
                        && panel.series[0].last().unwrap().is_nan(),
                    "Stale weather looks like a current sample",
                )?;
                drop(state);
                if let Some(path) = std::env::var_os("XRG_SMOKE_WEATHER_STALE_IMAGE") {
                    shell.snapshot(&PathBuf::from(path))?;
                }
                let view = shell.weather();
                view.station.set_text("KJFK");
                view.apply.emit_clicked();
                require(
                    !snapshot_matches(
                        shell.state.borrow().as_ref().unwrap(),
                        &shell.settings.borrow(),
                        Module::Weather,
                    ),
                    "Previous-station observation remained current",
                )?;
                require(
                    shell.areas[Module::Weather.index()]
                        .tooltip_text()
                        .is_some_and(|s| s.contains("Waiting")),
                    "Weather tooltip leaked previous-station readings",
                )?;
                view.enabled.set_active(false);
                view.apply.emit_clicked();
                view.close.emit_clicked();
                self.stage = 4;
            }
            4 if self.since.elapsed() > Duration::from_millis(350) => {
                let state = shell.state.borrow();
                let panel = &state.as_ref().unwrap().panels[Module::Weather.index()];
                require(
                    panel.label == "Weather disabled" && panel.series.is_empty(),
                    "Disabled weather retained plotted readings",
                )?;
                drop(state);
                let view = shell.weather();
                view.show_graph.set_active(false);
                view.apply.emit_clicked();
                view.close.emit_clicked();
                require(
                    !shell.areas[Module::Weather.index()].is_visible(),
                    "Weather graph could not be hidden",
                )?;
                self.stage = 5;
            }
            5 if shell.saved_revision.get() == shell.revision.get() => {
                let view = shell.weather();
                require(
                    !view.show_graph.is_active()
                        && !view.enabled.is_active()
                        && view.units.selected() == 1,
                    "Weather controls lost saved choices",
                )?;
                view.close.emit_clicked();
                require(
                    shell.settings.borrow().weather.units == Units::Us,
                    "Weather units lost",
                )?;
                return Ok(true);
            }
            _ => (),
        }
        if before != self.stage {
            self.since = Instant::now();
            eprintln!("GTK_WEATHER_GRAPH_STAGE {}", self.stage);
        }
        Ok(false)
    }
}
