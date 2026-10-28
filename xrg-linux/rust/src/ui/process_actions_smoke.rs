// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Kernel-backed UI checks target only child processes created here. The ordinary
//! preferences smoke test retains its separate twenty-second deadline.
use super::{Shell, processes::Window};
use gtk::prelude::*;
use std::{
    path::PathBuf,
    process::{Child, Command, Stdio},
    rc::Rc,
    sync::Arc,
    time::{Duration, Instant},
};
use xrg_ng_linux::{
    process::{
        self,
        control::{self, Action},
    },
    settings::ProcessView,
};
struct Disposable(Child);
impl Disposable {
    fn new() -> Result<Self, String> {
        Command::new("/bin/sleep")
            .arg("120")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map(Self)
            .map_err(|e| e.to_string())
    }
    fn stopped(&self) -> bool {
        control::inspect(self.0.id()).is_ok_and(|p| matches!(p.state, 'T' | 't'))
    }
    fn alive(&mut self) -> Result<bool, String> {
        self.0
            .try_wait()
            .map(|s| s.is_none())
            .map_err(|e| e.to_string())
    }
}
impl Drop for Disposable {
    fn drop(&mut self) {
        if matches!(self.0.try_wait(), Ok(None)) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}
pub(super) struct Harness {
    child: Disposable,
    window: Option<Rc<Window>>,
    stage: u8,
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
        Ok(Self {
            child: Disposable::new()?,
            window: None,
            stage: 0,
            since: Instant::now(),
        })
    }
    fn listing(&self, window: &Rc<Window>) -> Result<(), String> {
        let child = control::inspect(self.child.0.id())?;
        let own = control::inspect(std::process::id())?;
        window.update(&Ok(Arc::new(process::Report {
            processes: vec![child, own],
            discovered: 2,
            attempted: 2,
            vanished: 0,
            unreadable: 0,
            errors: Vec::new(),
        })));
        Ok(())
    }
    pub fn tick(&mut self, shell: &Rc<Shell>) -> Result<bool, String> {
        let before = self.stage;
        match self.stage {
            0 => {
                let window = shell.processes();
                window.set_view(ProcessView::default());
                self.listing(&window)?;
                self.window = Some(window);
                self.stage = 1;
            }
            1 if self.window.as_ref().is_some_and(|w| w.settled()) => {
                let window = self.window.as_ref().unwrap();
                require(
                    window.select_pid(self.child.0.id()),
                    "Disposable child is absent from UI",
                )?;
                require(
                    window.actions[0].is_sensitive()
                        && window.actions[2].is_sensitive()
                        && !window.actions[3].is_sensitive(),
                    "Process actions do not reflect running state",
                )?;
                let controllers = window.list.observe_controllers();
                let click = (0..controllers.n_items())
                    .filter_map(|i| controllers.item(i))
                    .find_map(|c| {
                        c.downcast::<gtk::GestureClick>()
                            .ok()
                            .filter(|c| c.button() == 3)
                    })
                    .ok_or("Process right-click controller missing")?;
                let row = window
                    .list
                    .selected_row()
                    .ok_or("Selected process row missing")?;
                click.emit_by_name::<()>(
                    "pressed",
                    &[
                        &1i32,
                        &24f64,
                        &(row.allocation().y() as f64 + row.height() as f64 / 2.),
                    ],
                );
                window.close_context();
                let key = (0..controllers.n_items())
                    .filter_map(|i| controllers.item(i))
                    .find_map(|c| c.downcast::<gtk::EventControllerKey>().ok())
                    .ok_or("Process keyboard controller missing")?;
                let handled = key.emit_by_name::<bool>(
                    "key-pressed",
                    &[
                        &gtk::gdk::Key::F10,
                        &0u32,
                        &gtk::gdk::ModifierType::SHIFT_MASK,
                    ],
                );
                require(handled, "Shift+F10 did not open process context menu")?;
                self.stage = 2;
            }
            2 if self.since.elapsed() > Duration::from_millis(200) => {
                let window = self.window.as_ref().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_PROCESS_MENU_IMAGE") {
                    window.snapshot_context(&PathBuf::from(path))?;
                }
                require(
                    window.select_pid(std::process::id()),
                    "Own process is absent from UI",
                )?;
                require(
                    window.actions.iter().all(|b| !b.is_sensitive()),
                    "Self-control buttons were enabled",
                )?;
                window.activate_context(Action::Pause)?;
                window.close_context();
                self.stage = 3;
            }
            3 if self
                .window
                .as_ref()
                .is_some_and(|w| w.confirmation().is_some()) =>
            {
                let window = self.window.as_ref().unwrap();
                let dialog = window.confirmation().unwrap();
                require(
                    dialog.window.default_widget() == Some(dialog.cancel.clone().upcast()),
                    "Process review does not default to Cancel",
                )?;
                require(
                    dialog.target_pid() == Some(self.child.0.id()),
                    "Context menu retargeted after selection changed",
                )?;
                require(
                    !self.child.stopped(),
                    "Opening a confirmation sent a signal",
                )?;
                self.stage = 4;
            }
            4 if self.since.elapsed() > Duration::from_millis(200) => {
                let window = self.window.as_ref().unwrap();
                let dialog = window.confirmation().unwrap();
                if let Some(path) = std::env::var_os("XRG_SMOKE_PROCESS_CONFIRM_IMAGE") {
                    dialog.snapshot(&PathBuf::from(path))?;
                }
                dialog.cancel.emit_clicked();
                require(
                    !window.busy() && window.confirmation().is_none() && !self.child.stopped(),
                    "Cancel did not discard process action",
                )?;
                require(
                    window.select_pid(self.child.0.id()),
                    "Child disappeared after cancellation",
                )?;
                window.actions[2].emit_clicked();
                self.stage = 5;
            }
            5 if self
                .window
                .as_ref()
                .is_some_and(|w| w.confirmation().is_some()) =>
            {
                let dialog = self.window.as_ref().unwrap().confirmation().unwrap();
                dialog.confirm.emit_clicked();
                dialog.confirm.emit_clicked();
                self.stage = 6;
            }
            6 if self.window.as_ref().is_some_and(|w| !w.busy()) && self.child.stopped() => {
                let window = self.window.as_ref().unwrap();
                self.listing(window)?;
                window.sort.set_selected(3);
                self.stage = 7;
            }
            7 if self.window.as_ref().is_some_and(|w| w.settled()) => {
                let window = self.window.as_ref().unwrap();
                require(
                    window.selected_pid() == Some(self.child.0.id()),
                    "Sorting changed the selected process",
                )?;
                require(
                    window.actions[3].is_sensitive() && !window.actions[2].is_sensitive(),
                    "Stopped state did not enable Resume",
                )?;
                require(
                    window.action_message().contains("SIGSTOP"),
                    "Signal result was lost during refresh",
                )?;
                if let Some(path) = std::env::var_os("XRG_SMOKE_PROCESS_CONTROLS_IMAGE") {
                    window.snapshot(&PathBuf::from(path))?;
                }
                window.actions[3].emit_clicked();
                self.stage = 8;
            }
            8 if self
                .window
                .as_ref()
                .is_some_and(|w| w.confirmation().is_some()) =>
            {
                self.window
                    .as_ref()
                    .unwrap()
                    .confirmation()
                    .unwrap()
                    .confirm
                    .emit_clicked();
                self.stage = 9;
            }
            9 if self.window.as_ref().is_some_and(|w| !w.busy()) && !self.child.stopped() => {
                require(self.child.alive()?, "Resume ended the child")?;
                self.window.as_ref().unwrap().actions[0].emit_clicked();
                self.stage = 10;
            }
            10 if self
                .window
                .as_ref()
                .is_some_and(|w| w.confirmation().is_some()) =>
            {
                self.window.take().unwrap().window.close();
                require(
                    self.child.alive()? && !self.child.stopped(),
                    "Closing parent sent an unconfirmed action",
                )?;
                let window = shell.processes();
                window.set_view(ProcessView::default());
                self.listing(&window)?;
                self.window = Some(window);
                self.stage = 11;
            }
            11 if self.window.as_ref().is_some_and(|w| w.settled()) => {
                let window = self.window.as_ref().unwrap();
                require(
                    window.select_pid(self.child.0.id()),
                    "Reopened table lost child",
                )?;
                window.actions[0].emit_clicked();
                self.stage = 12;
            }
            12 if self
                .window
                .as_ref()
                .is_some_and(|w| w.confirmation().is_some()) =>
            {
                self.window
                    .as_ref()
                    .unwrap()
                    .confirmation()
                    .unwrap()
                    .confirm
                    .emit_clicked();
                self.stage = 13;
            }
            13 if self.window.as_ref().is_some_and(|w| !w.busy()) && !self.child.alive()? => {
                self.child = Disposable::new()?;
                let window = self.window.as_ref().unwrap();
                self.listing(window)?;
                self.stage = 14;
            }
            14 if self.window.as_ref().is_some_and(|w| w.settled()) => {
                let window = self.window.as_ref().unwrap();
                require(window.select_pid(self.child.0.id()), "Second child absent")?;
                window.actions[1].emit_clicked();
                self.stage = 15;
            }
            15 if self
                .window
                .as_ref()
                .is_some_and(|w| w.confirmation().is_some()) =>
            {
                self.window
                    .as_ref()
                    .unwrap()
                    .confirmation()
                    .unwrap()
                    .confirm
                    .emit_clicked();
                self.stage = 16;
            }
            16 if self.window.as_ref().is_some_and(|w| !w.busy()) && !self.child.alive()? => {
                require(
                    self.window
                        .as_ref()
                        .unwrap()
                        .action_message()
                        .contains("SIGKILL"),
                    "Force Kill did not report delivery",
                )?;
                self.window.take().unwrap().window.close();
                self.stage = 17;
            }
            17 => return Ok(true),
            _ => (),
        }
        if before != self.stage {
            self.since = Instant::now();
            eprintln!("GTK_PROCESS_ACTIONS_STAGE {}", self.stage);
        }
        Ok(false)
    }
}
