// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Shell, preferences::Dialog};
use gtk::prelude::*;
use std::{
    cell::Cell,
    path::{Path, PathBuf},
    rc::Rc,
};
use xrg_ng_linux::settings::{Module, Settings, Store, WindowSize};
pub(super) struct Harness {
    stage: u8,
    frames: Rc<Cell<u8>>,
    expected: Option<Settings>,
    dialog: Option<Rc<Dialog>>,
}
fn require(value: bool, message: &str) -> Result<(), String> {
    if value { Ok(()) } else { Err(message.into()) }
}
impl Harness {
    pub fn new() -> Self {
        Self {
            stage: 0,
            frames: Rc::new(Cell::new(0)),
            expected: None,
            dialog: None,
        }
    }
    pub fn tick(&mut self, shell: &Rc<Shell>, sequence: u64, root: &Path) -> Result<bool, String> {
        let previous = self.stage;
        match self.stage {
            0 if sequence >= 1 => {
                require(
                    shell.window.default_size() == (720, 480),
                    "Saved startup size was not restored",
                )?;
                let original = shell.settings.borrow().clone();
                let dialog = shell.preferences();
                require(
                    dialog.window_size.remember.is_active()
                        && dialog.window_size.width.value_as_int() == 720,
                    "Saved window size not shown in Preferences",
                )?;
                dialog.window_size.width.set_value(600.);
                dialog.window_size.height.set_value(500.);
                dialog.cancel.emit_clicked();
                require(
                    *shell.settings.borrow() == original
                        && shell.window.default_size() == (720, 480),
                    "Cancel changed window size",
                )?;
                let dialog = shell.preferences();
                dialog.reset.emit_clicked();
                require(
                    !dialog.window_size.remember.is_active()
                        && *shell.settings.borrow() == original,
                    "Window defaults escaped the draft",
                )?;
                dialog.cancel.emit_clicked();
                let dialog = shell.preferences();
                dialog.window_size.widget.set_expanded(true);
                dialog.window_size.width.set_value(600.);
                dialog.window_size.height.set_value(500.);
                dialog.window_size.height.grab_focus();
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
                let dialog = self.dialog.take().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_WINDOW_SIZE_PREFS_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                dialog.apply.emit_clicked();
                self.expected.as_mut().unwrap().window_size = Some(WindowSize {
                    width: 600,
                    height: 500,
                });
                require(
                    *shell.settings.borrow() == *self.expected.as_ref().unwrap()
                        && shell.window.default_size() == (600, 500),
                    "Window size Apply changed graph dimensions or other preferences",
                )?;
                self.stage = 2;
            }
            2 if shell.saved_revision.get() == shell.revision.get() => {
                self.persisted(root)?;
                let mut changed = self.expected.as_ref().unwrap().clone();
                changed.graph_width = 180;
                changed.module_mut(Module::Cpu).height = Some(128);
                shell.apply(changed.clone());
                require(
                    shell.window.default_size() == (600, 500),
                    "Graph resizing replaced the explicit window size",
                )?;
                self.expected = Some(changed);
                // Exercise GTK's normal-size state capture without requiring a
                // physical pointer drag or a particular window manager.
                shell.window.set_default_size(640, 520);
                self.stage = 3;
            }
            3 => {
                // Keep this test window alive after exercising the real close
                // handler; production's earlier handler must capture first.
                let keep_open = shell
                    .window
                    .connect_close_request(|_| gtk::glib::Propagation::Stop);
                shell.window.close();
                shell.window.disconnect(keep_open);
                self.expected.as_mut().unwrap().window_size = Some(WindowSize {
                    width: 640,
                    height: 520,
                });
                require(
                    *shell.settings.borrow() == *self.expected.as_ref().unwrap(),
                    "Resized window was not captured",
                )?;
                self.stage = 4;
            }
            4 if shell.saved_revision.get() == shell.revision.get() => {
                self.persisted(root)?;
                let dialog = shell.preferences();
                require(
                    dialog.window_size.width.value_as_int() == 640
                        && dialog.window_size.height.value_as_int() == 520,
                    "Reopening lost the captured size",
                )?;
                dialog.window_size.remember.set_active(false);
                require(
                    !dialog.window_size.width.is_sensitive()
                        && !dialog.window_size.height.is_sensitive(),
                    "Automatic sizing left custom controls enabled",
                )?;
                dialog.apply.emit_clicked();
                self.expected.as_mut().unwrap().window_size = None;
                require(
                    *shell.settings.borrow() == *self.expected.as_ref().unwrap()
                        && shell.window.default_size().0 == 188,
                    "Automatic compact sizing did not resume",
                )?;
                // Auto mode must never start remembering a later desktop resize.
                shell.window.set_default_size(800, 550);
                shell.capture_window_size();
                require(
                    shell.settings.borrow().window_size.is_none(),
                    "Automatic mode captured a window size",
                )?;
                self.stage = 5;
            }
            5 if shell.saved_revision.get() == shell.revision.get() => {
                self.persisted(root)?;
                self.stage = 6;
                return Ok(true);
            }
            6 => return Ok(true),
            _ => (),
        }
        if previous != self.stage {
            println!("GTK_WINDOW_SIZE_STAGE {}", self.stage);
        }
        Ok(false)
    }
    fn persisted(&self, root: &Path) -> Result<(), String> {
        let (_, loaded, error) = Store::open(Some(root.join("settings.conf")));
        require(
            error.is_none() && loaded == *self.expected.as_ref().unwrap(),
            "Window size did not persist",
        )
    }
}
