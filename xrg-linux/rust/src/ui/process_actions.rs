// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};
use xrg_ng_linux::process::control::{Action, Target};
pub(super) enum Outcome {
    Cancelled,
    Sent,
    Failed(String),
}
pub(super) struct Confirmation {
    pub window: gtk::Window,
    pub confirm: gtk::Button,
    pub cancel: gtk::Button,
    target: RefCell<Option<Target>>,
    action: Action,
    busy: Cell<bool>,
    done: Cell<bool>,
    complete: Box<dyn Fn(Outcome)>,
    paintable: gtk::WidgetPaintable,
}
impl Confirmation {
    pub fn new(
        parent: &gtk::Window,
        target: Target,
        action: Action,
        complete: impl Fn(Outcome) + 'static,
    ) -> Rc<Self> {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 12);
        content.set_margin_top(20);
        content.set_margin_bottom(20);
        content.set_margin_start(20);
        content.set_margin_end(20);
        let process = target.process();
        let heading = gtk::Label::new(Some(action.name()));
        heading.add_css_class("title-3");
        heading.set_xalign(0.);
        content.append(&heading);
        for text in [format!("{}\nPID {} · UID {}",process.name,process.pid,process.uid.unwrap()),action.explanation().into(),"This action applies only to this process. The target identity and kernel permission will be checked again when you confirm.".into()] {
            let label = gtk::Label::new(Some(&text));
            label.set_xalign(0.);
            label.set_wrap(true);
            content.append(&label);
        }
        let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        buttons.set_halign(gtk::Align::End);
        let cancel = gtk::Button::with_label("Cancel");
        let confirm = gtk::Button::with_label(action.name());
        if matches!(action, Action::Terminate | Action::ForceKill) {
            confirm.add_css_class("destructive-action");
        } else {
            confirm.add_css_class("suggested-action");
        }
        buttons.append(&cancel);
        buttons.append(&confirm);
        content.append(&buttons);
        let window = gtk::Window::builder()
            .application(&parent.application().unwrap())
            .transient_for(parent)
            .destroy_with_parent(true)
            .modal(true)
            .title("Confirm process action")
            .default_width(460)
            .child(&content)
            .build();
        window.set_default_widget(Some(&cancel));
        let paintable = gtk::WidgetPaintable::new(Some(&window));
        let result = Rc::new(Self {
            window,
            confirm,
            cancel,
            target: RefCell::new(Some(target)),
            action,
            busy: Cell::new(false),
            done: Cell::new(false),
            complete: Box::new(complete),
            paintable,
        });
        let weak = Rc::downgrade(&result);
        result.cancel.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.window.close();
            }
        });
        let weak = Rc::downgrade(&result);
        result.window.connect_close_request(move |_| {
            if let Some(dialog) = weak.upgrade()
                && !dialog.busy.get()
            {
                dialog.finish(Outcome::Cancelled);
            }
            glib::Propagation::Proceed
        });
        let weak = Rc::downgrade(&result);
        result.confirm.connect_clicked(move |_| {
            if let Some(dialog) = weak.upgrade() {
                dialog.send();
            }
        });
        result.window.present();
        result.cancel.grab_focus();
        result
    }
    fn finish(&self, result: Outcome) {
        if !self.done.replace(true) {
            self.target.borrow_mut().take();
            (self.complete)(result);
        }
    }
    fn send(self: &Rc<Self>) {
        if self.busy.replace(true) || self.done.get() {
            return;
        }
        let Some(target) = self.target.borrow_mut().take() else {
            return;
        };
        self.confirm.set_sensitive(false);
        self.cancel.set_sensitive(false);
        let action = self.action;
        let task = gio::spawn_blocking(move || target.send(action));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            if let Some(dialog) = weak.upgrade() {
                let result = task
                    .await
                    .unwrap_or_else(|_| Err("Process action stopped unexpectedly".into()));
                dialog.finish(match result {
                    Ok(()) => Outcome::Sent,
                    Err(error) => Outcome::Failed(error),
                });
                dialog.window.close();
            }
        });
    }
    pub fn target_pid(&self) -> Option<u32> {
        self.target.borrow().as_ref().map(|t| t.process().pid)
    }
    pub fn snapshot(&self, path: &std::path::Path) -> Result<(), String> {
        super::save_snapshot(&self.window, &self.paintable, path)
    }
}
