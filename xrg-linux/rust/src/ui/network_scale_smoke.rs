// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Shell, menus::Details, preferences::Dialog};
use gtk::prelude::*;
use std::{
    cell::Cell,
    path::{Path, PathBuf},
    rc::Rc,
};
use xrg_ng_linux::{
    engine::{Panel, Scale},
    settings::{Module, Settings, Store},
    temperature::Units,
};
pub(super) struct Harness {
    stage: u8,
    frames: Rc<Cell<u8>>,
    draws: u32,
    fixture: Option<Panel>,
    expected: Option<Settings>,
    dialog: Option<Rc<Dialog>>,
    details: Option<Rc<Details>>,
}
fn require(value: bool, message: &str) -> Result<(), String> {
    if value { Ok(()) } else { Err(message.into()) }
}
impl Harness {
    pub fn new() -> Self {
        Self {
            stage: 0,
            frames: Rc::new(Cell::new(0)),
            draws: 0,
            fixture: None,
            expected: None,
            dialog: None,
            details: None,
        }
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64, root: &Path) -> Result<bool, String> {
        if let Some(panel) = &self.fixture {
            if let Some(snapshot) = shell.state.borrow_mut().as_mut() {
                snapshot.panels[Module::Network.index()] = panel.clone();
            }
            shell.update_panel_text();
            shell.update_details();
            shell.areas[Module::Network.index()].queue_draw();
        }
        let previous = self.stage;
        match self.stage {
            0 if sequence >= 1 => {
                let original = shell.settings.borrow().clone();
                require(
                    original.network_min_scale == 0 && original.activity_bars.visible,
                    "Network scale smoke requires automatic scaling and visible activity bars",
                )?;
                self.fixture = Some(Panel {
                    title: "Network",
                    label: "Fixture network · 128 / 64 B/s".into(),
                    series: vec![vec![0., 100., 200., 128.], vec![0., 90., 50., 64.]],
                    scale: Scale::Automatic,
                    temperature_text: None,
                    detail: "Copied fixture: receive/send bytes per second. Not live traffic."
                        .into(),
                    readout: Default::default(),
                });
                self.details = Some(shell.details(Module::Network));
                let dialog = shell.preferences();
                dialog.network_scale.units.set_selected(2);
                dialog.network_scale.value.set_text("3");
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == original,
                    "Cancel applied a network scale",
                )?;
                let dialog = shell.preferences();
                dialog.network_scale.value.set_text("invalid");
                dialog.apply.emit_clicked();
                require(
                    dialog.window.is_visible()
                        && dialog.message().contains("whole number")
                        && *shell.settings.borrow() == original,
                    "Invalid scale was applied or did not report its error",
                )?;
                dialog.reset.emit_clicked();
                require(
                    dialog.network_scale.value() == Ok(0) && *shell.settings.borrow() == original,
                    "Network defaults escaped the draft",
                )?;
                dialog.cancel.emit_clicked();
                let dialog = shell.preferences();
                dialog.network_scale.units.set_selected(1);
                dialog.network_scale.value.set_text("4");
                dialog.reveal_network_scale();
                let frames = self.frames.clone();
                dialog.window.add_tick_callback(move |_, _| {
                    frames.set(frames.get() + 1);
                    if frames.get() >= 3 {
                        gtk::glib::ControlFlow::Break
                    } else {
                        gtk::glib::ControlFlow::Continue
                    }
                });
                self.dialog = Some(dialog);
                self.expected = Some(original);
                self.stage = 1;
            }
            1 if self.frames.get() >= 3 => {
                let dialog = self.dialog.as_ref().unwrap();
                dialog.reveal_network_scale();
                self.frames.set(0);
                let frames = self.frames.clone();
                dialog.window.add_tick_callback(move |_, _| {
                    frames.set(frames.get() + 1);
                    if frames.get() >= 3 {
                        gtk::glib::ControlFlow::Break
                    } else {
                        gtk::glib::ControlFlow::Continue
                    }
                });
                self.stage = 2;
            }
            2 if self.frames.get() >= 3 => {
                let dialog = self.dialog.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_NETWORK_SCALE_PREFS_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                let before_sequence = shell.state.borrow().as_ref().unwrap().sequence;
                dialog.apply.emit_clicked();
                self.expected.as_mut().unwrap().network_min_scale = 4096;
                self.unchanged(shell)?;
                require(
                    shell.state.borrow().as_ref().unwrap().sequence == before_sequence,
                    "Scale Apply waited for/replaced the copied sample",
                )?;
                let area = &shell.areas[Module::Network.index()];
                require(
                    area.tooltip_text().is_some_and(|s| {
                        s.contains("0.00–4096.00") && s.contains("minimum upper bound: 4096")
                    }) && self
                        .details
                        .as_ref()
                        .unwrap()
                        .text()
                        .contains("minimum upper bound: 4096"),
                    "Cached graph axis, activity bars and details did not update immediately",
                )?;
                self.draws = shell.draws[Module::Network.index()].get();
                self.stage = 3;
            }
            3 if shell.saved_revision.get() == shell.revision.get()
                && shell.draws[Module::Network.index()].get() > self.draws =>
            {
                self.persisted(root)?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_NETWORK_SCALE_IMAGE") {
                    shell.snapshot(&PathBuf::from(path))?;
                }
                let dialog = shell.preferences();
                require(
                    dialog.network_scale.value.text() == "4"
                        && dialog.network_scale.units.selected() == 1,
                    "Saved minimum did not reopen as exact KiB/s",
                )?;
                dialog.reset.emit_clicked();
                require(
                    dialog.network_scale.value() == Ok(0)
                        && shell.settings.borrow().network_min_scale == 4096,
                    "Reset changed the active scale before Apply",
                )?;
                dialog.cancel.emit_clicked();
                let dialog = shell.preferences();
                dialog.network_scale.value.set_text("0");
                dialog.apply.emit_clicked();
                self.expected.as_mut().unwrap().network_min_scale = 0;
                self.unchanged(shell)?;
                require(
                    self.fixture
                        .as_ref()
                        .unwrap()
                        .scale
                        .bounds_with_minimum(
                            &self.fixture.as_ref().unwrap().series,
                            shell.settings.borrow().network_min_scale,
                        )
                        .1
                        < 221.,
                    "Automatic scale did not resume",
                )?;
                self.stage = 4;
            }
            4 if shell.saved_revision.get() == shell.revision.get() => {
                self.persisted(root)?;
                self.details.take().unwrap().window.close();
                self.stage = 5;
                return Ok(true);
            }
            5 => return Ok(true),
            _ => (),
        }
        if previous != self.stage {
            println!("GTK_NETWORK_SCALE_STAGE {}", self.stage);
        }
        Ok(false)
    }
    fn unchanged(&self, shell: &Shell) -> Result<(), String> {
        let state = shell.state.borrow();
        let panel = &state.as_ref().unwrap().panels[Module::Network.index()];
        let fixture = self.fixture.as_ref().unwrap();
        require(
            *shell.settings.borrow() == *self.expected.as_ref().unwrap()
                && panel.series == fixture.series
                && panel.label == fixture.label
                && panel.scale == fixture.scale,
            "Scale Apply changed sources, rate history, readings or other preferences",
        )?;
        require(
            panel
                .activity_description_with_minimum(
                    Units::Celsius,
                    shell.settings.borrow().network_min_scale,
                )
                .contains("not device capacity"),
            "Network activity bars misrepresented a display scale as capacity",
        )
    }
    fn persisted(&self, root: &Path) -> Result<(), String> {
        let (_, loaded, error) = Store::open(Some(root.join("settings.conf")));
        require(
            error.is_none() && loaded == *self.expected.as_ref().unwrap(),
            "Network scale did not persist",
        )
    }
}
