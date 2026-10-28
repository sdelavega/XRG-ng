// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! GTK actions consume copied snapshots; opening a menu never collects data.
use super::{Shell, save_snapshot, snapshot_matches};
use gtk::{gio, glib, prelude::*};
use std::{cell::RefCell, path::Path, rc::Rc};
use xrg_ng_linux::{
    engine::Snapshot,
    settings::{Module, Settings},
};

fn action(
    shell: &Rc<Shell>,
    name: &str,
    parameter: Option<&glib::VariantTy>,
    callback: impl Fn(&Rc<Shell>, Option<&glib::Variant>) + 'static,
) {
    let action = gio::SimpleAction::new(name, parameter);
    let weak = Rc::downgrade(shell);
    action.connect_activate(move |_, value| {
        if let Some(shell) = weak.upgrade() {
            callback(&shell, value);
        }
    });
    shell.window.add_action(&action);
}
fn module(value: Option<&glib::Variant>) -> Option<Module> {
    value
        .and_then(|v| v.get::<u32>())
        .and_then(|i| Module::ALL.get(i as usize).copied())
}
fn item(menu: &gio::Menu, label: &str, action: &str, module: Module) {
    let entry = gio::MenuItem::new(Some(label), None);
    entry.set_action_and_target_value(Some(action), Some(&(module.index() as u32).to_variant()));
    menu.append_item(&entry);
}
pub(super) fn install(shell: &Rc<Shell>) -> gtk::MenuButton {
    action(shell, "preferences", None, |s, _| {
        s.preferences();
    });
    action(shell, "processes", None, |s, _| {
        s.processes();
    });
    action(shell, "ai", None, |s, _| {
        s.ai();
    });
    action(shell, "weather", None, |s, _| {
        s.weather();
    });
    action(shell, "weather-refresh", None, |s, _| {
        if s.settings.borrow().weather.enabled {
            s.weather_control.refresh();
        }
    });
    action(shell, "show-all", None, |s, _| {
        let mut settings = s.settings.borrow().clone();
        if settings.modules.iter().all(|m| m.visible) {
            return;
        }
        for module in &mut settings.modules {
            module.visible = true;
        }
        s.apply(settings);
    });
    action(
        shell,
        "graph-details",
        Some(glib::VariantTy::UINT32),
        |s, v| {
            if let Some(m) = module(v) {
                s.details(m);
            }
        },
    );
    action(
        shell,
        "graph-hide",
        Some(glib::VariantTy::UINT32),
        |s, v| {
            let Some(module) = module(v) else {
                return;
            };
            let mut settings = s.settings.borrow().clone();
            if let Some(entry) = settings.modules.iter_mut().find(|m| m.id == module)
                && entry.visible
            {
                entry.visible = false;
                s.apply(settings);
            }
        },
    );
    for (name, step) in [("graph-up", -1), ("graph-down", 1)] {
        action(shell, name, Some(glib::VariantTy::UINT32), move |s, v| {
            let Some(module) = module(v) else {
                return;
            };
            let mut settings = s.settings.borrow().clone();
            let Some(index) = settings.modules.iter().position(|m| m.id == module) else {
                return;
            };
            let Some(next) = index
                .checked_add_signed(step)
                .filter(|i| *i < settings.modules.len())
            else {
                return;
            };
            settings.modules.swap(index, next);
            s.apply(settings);
        });
    }
    action(shell, "about", None, |s, _| {
        gtk::AboutDialog::builder().application(&s.window.application().unwrap()).transient_for(&s.window).modal(true).destroy_with_parent(true)
            .program_name("XRG-ng").version(env!("CARGO_PKG_VERSION"))
            .comments("A system resource monitor for Linux, built with Swift, Rust and GTK4.")
            .website("https://github.com/sdelavega/XRG-ng").website_label("XRG-ng on GitHub")
            .license_type(gtk::License::Gpl30)
            .copyright("Copyright © 2002–2024 Mike Piatek-Jimenez / Gaucho Software, LLC\nCopyright © 2025–2026 Marc Shade\nCopyright © 2026 Stephen de la Vega")
            .authors(["Mike Piatek-Jimenez", "Marc Shade", "Stephen de la Vega"])
            .build().present();
    });
    action(shell, "quit", None, |s, _| {
        s.capture_window_size();
        if let Some(app) = s.window.application() {
            app.quit();
        }
    });
    let menu = gio::Menu::new();
    let navigation = gio::Menu::new();
    for (label, name) in [
        ("Preferences…", "preferences"),
        ("Processes…", "processes"),
        ("AI monitoring…", "ai"),
        ("Weather…", "weather"),
    ] {
        navigation.append(Some(label), Some(&format!("win.{name}")));
    }
    menu.append_section(None, &navigation);
    menu.append(Some("Show all graphs"), Some("win.show-all"));
    let app = gio::Menu::new();
    app.append(Some("About XRG-ng"), Some("win.about"));
    app.append(Some("Quit"), Some("win.quit"));
    menu.append_section(None, &app);
    let theme_item = gio::MenuItem::new(None, None);
    theme_item.set_attribute_value("custom", Some(&"theme-selector".to_variant()));
    menu.prepend_item(&theme_item);
    let popover = gtk::PopoverMenu::from_model(Some(&menu));
    popover.add_child(&shell.chooser, "theme-selector");
    let button = gtk::MenuButton::builder()
        .label("⋮")
        .direction(gtk::ArrowType::None)
        .popover(&popover)
        .build();
    button.set_tooltip_text(Some("Application menu"));
    button.update_property(&[gtk::accessible::Property::Label("Application menu")]);
    for module in Module::ALL {
        bind(shell, module);
    }
    button
}
fn bind(shell: &Rc<Shell>, module: Module) {
    let area = &shell.areas[module.index()];
    area.set_focusable(true);
    area.set_tooltip_text(Some("Right-click or press Shift+F10 for graph actions"));
    let click = gtk::GestureClick::new();
    click.set_button(3);
    let weak = Rc::downgrade(shell);
    click.connect_pressed(move |gesture, _, x, y| {
        if let Some(shell) = weak.upgrade() {
            shell.areas[module.index()].grab_focus();
            popup(&shell, module, x, y);
            if gesture.current_event().is_some() {
                gesture.set_state(gtk::EventSequenceState::Claimed);
            }
        }
    });
    area.add_controller(click);
    let key = gtk::EventControllerKey::new();
    let weak = Rc::downgrade(shell);
    key.connect_key_pressed(move |_, key, _, modifiers| {
        if (key == gtk::gdk::Key::Menu
            || (key == gtk::gdk::Key::F10
                && (modifiers
                    & (gtk::gdk::ModifierType::SHIFT_MASK
                        | gtk::gdk::ModifierType::CONTROL_MASK
                        | gtk::gdk::ModifierType::ALT_MASK
                        | gtk::gdk::ModifierType::SUPER_MASK
                        | gtk::gdk::ModifierType::META_MASK))
                    == gtk::gdk::ModifierType::SHIFT_MASK))
            && let Some(shell) = weak.upgrade()
        {
            popup(&shell, module, 12., 12.);
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    area.add_controller(key);
    // DrawingArea has no layout manager to allocate a native popover for us.
    area.connect_resize(|area, _, _| {
        if let Some(popover) = area
            .first_child()
            .and_then(|c| c.downcast::<gtk::PopoverMenu>().ok())
        {
            popover.present();
        }
    });
    area.connect_unrealize(|area| {
        if let Some(popover) = area
            .first_child()
            .and_then(|c| c.downcast::<gtk::PopoverMenu>().ok())
        {
            popover.popdown();
            if popover.parent().is_some() {
                popover.unparent();
            }
        }
    });
}
pub(super) fn popup(shell: &Rc<Shell>, module: Module, x: f64, y: f64) -> gtk::PopoverMenu {
    let area = &shell.areas[module.index()];
    if let Some(old) = area
        .first_child()
        .and_then(|c| c.downcast::<gtk::PopoverMenu>().ok())
    {
        old.popdown();
        if old.parent().is_some() {
            old.unparent();
        }
    }
    let menu = gio::Menu::new();
    let summary = shell
        .state
        .borrow()
        .as_ref()
        .filter(|s| snapshot_matches(s, &shell.settings.borrow(), module))
        .and_then(|s| s.panels.get(module.index()))
        .map(|p| {
            p.display_label(shell.settings.borrow().temperature_units)
                .into_owned()
        })
        .unwrap_or_else(|| "Waiting for active source".into());
    let summary = if summary.chars().count() > 80 {
        format!("{}…", summary.chars().take(80).collect::<String>())
    } else {
        summary
    };
    let commands = gio::Menu::new();
    item(&commands, "Live details…", "win.graph-details", module);
    commands.append(Some("Graph preferences…"), Some("win.preferences"));
    if module == Module::Ai {
        commands.append(Some("AI monitoring…"), Some("win.ai"));
    }
    if module == Module::Weather {
        commands.append(Some("Weather settings…"), Some("win.weather"));
        commands.append(Some("Refresh observations"), Some("win.weather-refresh"));
    }
    if module == Module::Processes {
        commands.append(Some("Process table…"), Some("win.processes"));
    }
    menu.append_section(Some(&format!("{} · {summary}", module.title())), &commands);
    let layout = gio::Menu::new();
    let settings = shell.settings.borrow();
    if let Some(index) = settings.modules.iter().position(|m| m.id == module) {
        if index > 0 {
            item(
                &layout,
                if settings.layout == xrg_ng_linux::settings::Layout::Horizontal {
                    "Move left"
                } else {
                    "Move up"
                },
                "win.graph-up",
                module,
            );
        }
        if index + 1 < settings.modules.len() {
            item(
                &layout,
                if settings.layout == xrg_ng_linux::settings::Layout::Horizontal {
                    "Move right"
                } else {
                    "Move down"
                },
                "win.graph-down",
                module,
            );
        }
    }
    item(&layout, "Hide graph", "win.graph-hide", module);
    menu.append_section(None, &layout);
    let popover = gtk::PopoverMenu::from_model(Some(&menu));
    popover.set_has_arrow(false);
    popover.set_parent(area);
    popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(
        x.max(0.) as i32,
        y.max(0.) as i32,
        1,
        1,
    )));
    popover.connect_closed(|p| {
        if p.parent().is_some() {
            p.unparent();
        }
    });
    popover.popup();
    popover.present();
    popover
}

pub(super) struct Details {
    pub window: gtk::Window,
    text: gtk::TextView,
    shown: RefCell<String>,
    module: Module,
    paintable: gtk::WidgetPaintable,
}
impl Details {
    pub fn new(shell: &Rc<Shell>, module: Module) -> Rc<Self> {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        content.set_margin_top(12);
        content.set_margin_bottom(12);
        content.set_margin_start(12);
        content.set_margin_end(12);
        let text = gtk::TextView::builder()
            .editable(false)
            .cursor_visible(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .build();
        text.update_property(&[gtk::accessible::Property::Label(&format!(
            "{} live details",
            module.title()
        ))]);
        content.append(
            &gtk::ScrolledWindow::builder()
                .vexpand(true)
                .child(&text)
                .build(),
        );
        let close = gtk::Button::with_label("Close");
        close.set_halign(gtk::Align::End);
        content.append(&close);
        let window = gtk::Window::builder()
            .application(&shell.window.application().unwrap())
            .transient_for(&shell.window)
            .destroy_with_parent(true)
            .title(format!("XRG-ng · {} details", module.title()))
            .default_width(640)
            .default_height(500)
            .child(&content)
            .build();
        let paintable = gtk::WidgetPaintable::new(Some(&window));
        let view = Rc::new(Self {
            window,
            text,
            shown: RefCell::new(String::new()),
            module,
            paintable,
        });
        let weak = Rc::downgrade(&view);
        close.connect_clicked(move |_| {
            if let Some(view) = weak.upgrade() {
                view.window.close();
            }
        });
        let weak = Rc::downgrade(shell);
        view.window.connect_close_request(move |_| {
            if let Some(shell) = weak.upgrade() {
                shell.details.borrow_mut().remove(&module);
            }
            glib::Propagation::Proceed
        });
        view
    }
    pub fn update(&self, snapshot: Option<&Snapshot>, settings: &Settings) {
        let text = snapshot
            .filter(|s| snapshot_matches(s, settings, self.module))
            .and_then(|s| s.panels.get(self.module.index()))
            .map(|p| {
                let label = p.display_label(settings.temperature_units);
                let detail = p.display_detail(settings.temperature_units);
                if detail.starts_with(label.as_ref()) {
                    format!("{}\n{}", self.module.title(), detail)
                } else {
                    format!("{}\n{}\n\n{}", self.module.title(), label, detail)
                }
            })
            .unwrap_or_else(|| {
                format!(
                    "{}\nWaiting for the next sample for the active source.",
                    self.module.title()
                )
            });
        if *self.shown.borrow() != text {
            self.text.buffer().set_text(&text);
            *self.shown.borrow_mut() = text;
        }
    }
    pub fn text(&self) -> String {
        self.shown.borrow().clone()
    }
    pub fn snapshot(&self, path: &Path) -> Result<(), String> {
        save_snapshot(&self.window, &self.paintable, path)
    }
}
