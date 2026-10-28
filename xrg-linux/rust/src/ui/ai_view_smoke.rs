// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Copied AI reports, real Preferences controls, cached rendering and persistence.
use super::{Shell, ai};
use gtk::prelude::*;
use std::{path::Path, rc::Rc};
use xrg_ng_linux::{
    ai::{Display, ModelUsage, Models, Reading, Report, Update},
    settings::{Module, Settings, Store},
    shared::Usage,
};
pub(super) struct Harness {
    stage: u8,
    original: Option<Settings>,
    fixture: Option<Update>,
    window: Option<Rc<ai::Window>>,
}
fn require(value: bool, error: &str) -> Result<(), String> {
    if value { Ok(()) } else { Err(error.into()) }
}
impl Harness {
    pub fn new() -> Self {
        Self {
            stage: 0,
            original: None,
            fixture: None,
            window: None,
        }
    }
    fn inject(&self, shell: &Rc<Shell>) {
        if let Some(fixture) = &self.fixture
            && let Some(snapshot) = shell.state.borrow_mut().as_mut()
        {
            snapshot.ai = Some(fixture.clone());
            snapshot.panels[Module::Ai.index()] = fixture.panel.clone();
        }
    }
    fn unchanged_graph(&self, shell: &Rc<Shell>) -> Result<(), String> {
        let fixture = self.fixture.as_ref().unwrap();
        let state = shell.state.borrow();
        let panel = &state.as_ref().ok_or("No fixture snapshot")?.panels[Module::Ai.index()];
        require(
            panel.label == fixture.panel.label && panel.series[0] == fixture.panel.series[0],
            "Model display change altered AI rate history",
        )
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64, root: &Path) -> Result<bool, String> {
        self.inject(shell);
        let previous = self.stage;
        match self.stage {
            0 if sequence >= 2 => {
                let original = shell.settings.borrow().clone();
                let mut report = Report {
                    providers: std::array::from_fn(
                        |_| Err("AI display fixture unavailable".into()),
                    ),
                    ollama: "AI display fixture — not live usage".into(),
                    models: Models {
                        installed: Ok(vec!["fixture-inventory-model".into()]),
                        running: Ok(vec![]),
                    },
                };
                let reading = |total| Reading {
                    usage: Usage {
                        total,
                        ..Usage::default()
                    },
                    cost: Some(0.25),
                    source: "AI display fixture — not live usage".into(),
                    models: Some(vec![ModelUsage {
                        model: Some("fixture-token-model".into()),
                        usage: Usage {
                            total,
                            ..Usage::default()
                        },
                        cost: Some(0.25),
                    }]),
                };
                report.providers[0] = Ok(reading(42));
                let mut display = Display::default();
                display.panel_for(report.clone(), 1., &original.ai);
                report.providers[0] = Ok(reading(52));
                let panel = display.panel_for(report.clone(), 6., &original.ai);
                require(
                    panel.series[0].last() == Some(&2.),
                    "Fixture rate is not measured",
                )?;
                self.fixture = Some(Update::new(original.ai.clone(), panel, report));
                self.inject(shell);
                let window = shell.ai();
                require(
                    window.usage_text().contains("fixture-token-model"),
                    "Model rows missing initially",
                )?;
                let dialog = shell.preferences();
                dialog.ai_models.set_active(false);
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == original
                        && window.usage_text().contains("fixture-token-model"),
                    "Cancelled model preference changed active view",
                )?;
                let dialog = shell.preferences();
                dialog.ai_models.set_active(false);
                dialog.apply.emit_clicked();
                let mut expected = original.clone();
                expected.ai_show_model_breakdown = false;
                require(
                    *shell.settings.borrow() == expected,
                    "Model preference changed other settings",
                )?;
                require(
                    !window.usage_text().contains("fixture-token-model")
                        && !window
                            .usage_text()
                            .contains("per-model token attribution unavailable")
                        && window.usage_text().contains("52 tokens")
                        && window.usage_text().contains("source cost $0.2500")
                        && window.usage_text().contains("fixture-inventory-model"),
                    "Grouped view lost totals, recorded cost or inventory, or retained model rows",
                )?;
                self.original = Some(original);
                self.window = Some(window);
                self.unchanged_graph(shell)?;
                self.stage = 1;
            }
            1 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(root.join("settings.conf")));
                require(
                    error.is_none()
                        && loaded == *shell.settings.borrow()
                        && !loaded.ai_show_model_breakdown,
                    "Grouped model preference did not persist",
                )?;
                let dialog = shell.preferences();
                require(
                    !dialog.ai_models.is_active(),
                    "Reopened preference lost grouped choice",
                )?;
                dialog.reset.emit_clicked();
                require(
                    dialog.ai_models.is_active()
                        && !shell.settings.borrow().ai_show_model_breakdown,
                    "Restore defaults did not stay in the draft",
                )?;
                dialog.cancel.emit_clicked();
                let dialog = shell.preferences();
                dialog.ai_models.set_active(true);
                dialog.apply.emit_clicked();
                require(
                    *shell.settings.borrow() == *self.original.as_ref().unwrap()
                        && self
                            .window
                            .as_ref()
                            .unwrap()
                            .usage_text()
                            .contains("fixture-token-model"),
                    "Cached model rows did not return immediately on Apply",
                )?;
                self.unchanged_graph(shell)?;
                self.stage = 2;
            }
            2 if shell.saved_revision.get() == shell.revision.get() => {
                let (_, loaded, error) = Store::open(Some(root.join("settings.conf")));
                require(
                    error.is_none() && loaded == *self.original.as_ref().unwrap(),
                    "Restored model preference did not persist",
                )?;
                let window = self.window.take().unwrap();
                let fixture = self.fixture.as_ref().unwrap();
                let mut stale = fixture.preferences.clone();
                stale.enabled[0] = false;
                window.update(Some(fixture), &stale, false);
                require(
                    window.usage_text().contains("Waiting for the AI worker")
                        && !window.usage_text().contains("52 tokens"),
                    "Grouped view retained stale source data",
                )?;
                window.cancel.emit_clicked();
                return Ok(true);
            }
            _ => (),
        }
        if previous != self.stage {
            println!("GTK_AI_VIEW_STAGE {}", self.stage);
        }
        Ok(false)
    }
}
