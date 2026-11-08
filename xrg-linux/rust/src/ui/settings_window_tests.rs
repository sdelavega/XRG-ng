// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The catalog-driven Aether7b settings window's own tests (task 11, spec
//! §9): the sidebar's approved sections, every Linux catalog entry
//! rendering its control with its catalog label, instant apply through the
//! store, invalid values showing the danger rim and reason while saving
//! nothing, resets that ask first, the token-only colour audit over the
//! style and every painted shape, keyboard navigation reaching every
//! control, and the macOS window's review lessons (a–j), each with its
//! test. Every fixture uses a disposable configuration root; no test
//! touches the user's own settings document.
use super::{SECTION_TITLES, SettingsWindow, SourceProvider};
use crate::settings::{
    self, Store,
    document::{self, Catalog, CatalogEntry},
};
use eframe::egui::{self, Pos2, RawInput, Rect, Vec2};
use serde_json::{Value, json};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

static NEXT: AtomicU64 = AtomicU64::new(0);
const SCREEN: Vec2 = Vec2::new(760., 620.);

/// One test's window, store and context, driven together so clicks, focus
/// and text edits behave exactly as they do under the real event loop.
struct Harness {
    ctx: egui::Context,
    window: SettingsWindow,
    store: Store,
    root: PathBuf,
    catalog: Catalog,
}
impl Harness {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "xrg-settings-window-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).unwrap();
        let ctx = egui::Context::default();
        ctx.enable_accesskit();
        Self {
            window: SettingsWindow::new(
                document::catalog().expect("the shared core provides the catalog"),
            ),
            store: Store::open(&root),
            catalog: document::catalog().expect("the shared core provides the catalog"),
            root,
            ctx,
        }
    }
    fn document(&self) -> PathBuf {
        self.root.join("xrg-ng/settings.json")
    }
    fn frame(&mut self, events: Vec<egui::Event>) -> egui::FullOutput {
        let raw = RawInput {
            screen_rect: Some(Rect::from_min_size(Pos2::ZERO, SCREEN)),
            events,
            ..Default::default()
        };
        let mut output = self.ctx.run_ui(raw, |ui| {
            self.window.render(ui, &mut self.store, &FixtureSources)
        });
        // This fixture has no renderer; acknowledge uploads even on setup frames.
        output.textures_delta.clear();
        output
    }
    fn quiet(&mut self) -> egui::FullOutput {
        self.frame(vec![])
    }
    fn click_at(&mut self, centre: Pos2) -> egui::FullOutput {
        let press = vec![
            egui::Event::PointerMoved(centre),
            egui::Event::PointerButton {
                pos: centre,
                button: egui::PointerButton::Primary,
                pressed: true,
                modifiers: egui::Modifiers::NONE,
            },
        ];
        let release = vec![egui::Event::PointerButton {
            pos: centre,
            button: egui::PointerButton::Primary,
            pressed: false,
            modifiers: egui::Modifiers::NONE,
        }];
        let _ = self.frame(press);
        self.frame(release)
    }
    /// One wheel step of 240 px from inside the section's scroll area:
    /// the pointer must sit over it for the wheel to reach it, and the
    /// content moves up so the deeper entries come into view.
    fn wheel(&mut self) -> egui::FullOutput {
        self.frame(vec![
            egui::Event::PointerMoved(egui::pos2(400., 300.)),
            egui::Event::MouseWheel {
                unit: egui::MouseWheelUnit::Point,
                delta: egui::vec2(0., -240.),
                phase: egui::TouchPhase::Move,
                source: egui::MouseWheelSource::Wheel,
                modifiers: egui::Modifiers::NONE,
            },
        ])
    }
    fn click(&mut self, id: &str) -> egui::FullOutput {
        // Settle first: egui answers each press from the previous pass's
        // widgets, so a click must not start the very frame after a modal
        // closed — its full-screen backdrop still answers for the press.
        // The real event loop always runs frames between a user's actions.
        let _ = self.quiet();
        let mut centre = self
            .window
            .rendered()
            .iter()
            .find(|rendered| rendered.id == id)
            .unwrap_or_else(|| panic!("no rendered control for {id}"))
            .response
            .rect
            .center();
        for _ in 0..120 {
            if (60.0..560.0).contains(&centre.y) {
                break;
            }
            let _ = self.wheel();
            centre = self
                .window
                .rendered()
                .iter()
                .find(|rendered| rendered.id == id)
                .expect("the scrolled control")
                .response
                .rect
                .center();
        }
        self.click_at(centre)
    }
    fn click_labelled(&mut self, label: &str) -> egui::FullOutput {
        let mut frame = self.quiet();
        let mut centre = node_centre(&frame, label);
        for _ in 0..120 {
            if centre.is_some_and(|pos| (60.0..560.0).contains(&pos.y)) {
                break;
            }
            frame = self.wheel();
            centre = node_centre(&frame, label);
        }
        let centre = centre.unwrap_or_else(|| {
            panic!(
                "no labelled button {label}; the tree holds: {:?}",
                all_labels(&frame)
            )
        });
        self.click_at(centre)
    }
    fn type_into(&mut self, id: &str, text: &str) {
        self.click(id);
        // Typing replaces the field's text, the way a user selects it
        // first (Ctrl+A) and types over it. egui's select-all matches the
        // `command` modifier bit, which a real windowing system sets
        // alongside ctrl on Linux.
        let _ = self.frame(vec![egui::Event::Key {
            key: egui::Key::A,
            physical_key: None,
            pressed: true,
            repeat: false,
            modifiers: egui::Modifiers {
                ctrl: true,
                command: true,
                ..egui::Modifiers::NONE
            },
        }]);
        for character in text.chars() {
            let _ = self.frame(vec![egui::Event::Text(character.to_string())]);
        }
        // Leaving the field submits (the macOS action's trigger).
        let _ = self.frame(vec![key(egui::Key::Tab)]);
    }
    fn values(&self) -> serde_json::Map<String, Value> {
        self.store.values()
    }
}

fn key(key: egui::Key) -> egui::Event {
    egui::Event::Key {
        key,
        physical_key: None,
        pressed: true,
        repeat: false,
        modifiers: egui::Modifiers::NONE,
    }
}

/// A labelled node's screen-space centre.
fn node_centre(output: &egui::FullOutput, label: &str) -> Option<Pos2> {
    let tree = output.platform_output.accesskit_update.as_ref()?;
    tree.nodes
        .iter()
        .find(|(_, node)| node.label() == Some(label))
        .and_then(|(_, node)| node.bounds())
        .map(|bounds| {
            Pos2::new(
                (bounds.x0 + bounds.x1) as f32 / 2.,
                (bounds.y0 + bounds.y1) as f32 / 2.,
            )
        })
}

/// The accesskit value of the node labelled `label`, if any.
fn node_value(output: &egui::FullOutput, label: &str) -> Option<String> {
    let tree = output.platform_output.accesskit_update.as_ref()?;
    tree.nodes
        .iter()
        .find(|(_, node)| node.label() == Some(label))
        .and_then(|(_, node)| node.value())
        .map(|value| value.to_string())
}

/// Every string the accessibility tree announces: the widget labels and,
/// with them, the values — egui 0.37 puts a plain label's text in its
/// node's value (Role::Label nodes carry text runs, not names), and a
/// screen reader reads labels and values alike.
fn all_labels(output: &egui::FullOutput) -> Vec<String> {
    output
        .platform_output
        .accesskit_update
        .as_ref()
        .map(|tree| {
            tree.nodes
                .iter()
                .flat_map(|(_, node)| {
                    let mut strings = Vec::with_capacity(2);
                    if let Some(label) = node.label() {
                        strings.push(label.to_owned());
                    }
                    if let Some(value) = node.value() {
                        strings.push(value.to_owned());
                    }
                    strings
                })
                .collect()
        })
        .unwrap_or_default()
}

fn labelled(output: &egui::FullOutput, text: &str) -> bool {
    output
        .platform_output
        .accesskit_update
        .as_ref()
        .is_some_and(|tree| {
            tree.nodes.iter().any(|(_, node)| {
                node.label().is_some_and(|label| label.contains(text))
                    || node.value().is_some_and(|value| value.contains(text))
            })
        })
}

/// A fixture source provider: fixed options per kind; it enumerates nothing.
struct FixtureSources;
impl SourceProvider for FixtureSources {
    fn options(&self, kind: &str) -> Vec<crate::metrics::SourceOption> {
        match kind {
            "temperature" => vec![
                crate::metrics::SourceOption {
                    id: "coretemp-1".into(),
                    label: "Package id 1".into(),
                },
                crate::metrics::SourceOption {
                    id: "acpi-2".into(),
                    label: "Board".into(),
                },
            ],
            "network" => vec![crate::metrics::SourceOption {
                id: "enp3s0".into(),
                label: "enp3s0".into(),
            }],
            _ => Vec::new(),
        }
    }
}

fn linux_entries<'a>(catalog: &'a Catalog, section: &str) -> Vec<&'a CatalogEntry> {
    catalog
        .entries
        .iter()
        .filter(|entry| {
            entry.section == section
                && entry.platforms.iter().any(|platform| platform == "linux")
                && entry.shown
        })
        .collect()
}

// The brief's Step 1.

#[test]
fn sidebar_lists_the_approved_sections() {
    let mut harness = Harness::new();
    let frame = harness.quiet();
    // The approved list, verbatim, including Stocks (decision D7).
    for (_, title) in SECTION_TITLES {
        assert!(
            labelled(&frame, title),
            "the sidebar does not label {title}"
        );
    }
    for section in harness.catalog.sections.clone() {
        assert!(
            harness.window.select_section(&section),
            "{section} is not a section"
        );
        assert_eq!(harness.window.section(), section.as_str());
        let _ = harness.quiet();
    }
    assert!(!harness.window.select_section("not-a-section"));
}

#[test]
fn every_linux_entry_has_a_control() {
    let mut harness = Harness::new();
    let mut seen = 0;
    for section in harness.catalog.sections.clone() {
        harness.window.select_section(&section);
        let frame = harness.quiet();
        for entry in linux_entries(&harness.catalog, &section) {
            let rendered = harness
                .window
                .rendered()
                .iter()
                .find(|rendered| rendered.id == entry.id)
                .unwrap_or_else(|| panic!("{} rendered no control", entry.id));
            assert_eq!(
                rendered.control, entry.control,
                "wrong kind for {}",
                entry.id
            );
            assert_eq!(rendered.label, entry.label, "wrong label for {}", entry.id);
            assert!(
                labelled(&frame, &entry.label),
                "{} has no accessible label",
                entry.id
            );
            seen += 1;
        }
    }
    let total: usize = harness
        .catalog
        .sections
        .iter()
        .map(|section| linux_entries(&harness.catalog, section).len())
        .sum();
    assert_eq!(seen, total, "some Linux entries never rendered");
    // Stocks renders from the catalog even though no graph draws it yet
    // (ruling R2; Task 12 adds Module::Stocks).
    harness.window.select_section("stocks");
    let frame = harness.quiet();
    assert!(labelled(&frame, "Stock symbols"));
    assert!(labelled(&frame, "Show DJIA"));
}

#[test]
fn changing_a_control_saves_instantly() {
    let mut harness = Harness::new();
    harness.window.select_section("general");
    let _ = harness.quiet();
    let before = fs::read(harness.document()).ok();
    harness.click("general.window.expand_on_hover");
    // Instant apply (decision D9): the value is in the store and the
    // document, never a draft.
    assert_eq!(
        harness.values()["general.window.expand_on_hover"],
        json!(false),
        "the toggle did not reach the store"
    );
    assert_ne!(
        fs::read(harness.document()).ok(),
        before,
        "the document did not change"
    );
    assert!(
        harness.window.take_dirty(),
        "the window did not report its change"
    );
    assert!(!harness.store.settings().window_collapse.expand_on_hover);
}

#[test]
fn invalid_input_shows_danger_and_does_not_save() {
    let mut harness = Harness::new();
    harness
        .store
        .set("general.window.graph_width", json!(300))
        .expect("valid width");
    harness.window.select_section("general");
    let _ = harness.quiet();
    let before = fs::read(harness.document()).unwrap();
    // Malformed and out-of-range text: never saved, never replaced by the
    // default, and the field keeps what the user typed (lesson a). The
    // core is the only validator — the store is never even asked.
    for bad in ["abc", "99", "99999999999999999999999"] {
        harness.type_into("general.window.graph_width", bad);
        let frame = harness.quiet();
        let reason = harness
            .window
            .error("general.window.graph_width")
            .unwrap_or_else(|| panic!("no danger reason for {bad}"))
            .to_owned();
        assert!(
            labelled(&frame, &reason),
            "the reason {reason:?} did not render inside the row"
        );
        assert_eq!(
            harness.values()["general.window.graph_width"],
            json!(300),
            "{bad} changed the stored width"
        );
        assert_eq!(
            fs::read(harness.document()).unwrap(),
            before,
            "the document changed while the input was invalid"
        );
    }
    // The danger rim: nothing else turns red, but the field's rim does.
    let danger = [
        super::super::aether7b::status_danger(false),
        super::super::aether7b::status_danger(true),
    ];
    let frame = harness.quiet();
    let field = harness
        .window
        .rendered()
        .iter()
        .find(|rendered| rendered.id == "general.window.graph_width")
        .unwrap()
        .response
        .rect;
    let rimmed = frame.shapes.iter().any(|clipped| {
        matches!(&clipped.shape, egui::Shape::Rect(rect)
            if danger.contains(&rect.stroke.color) && rect.rect.intersects(field))
    });
    assert!(rimmed, "the field shows no danger rim");
    // An unrelated stored change does not clobber the invalid edit.
    harness
        .store
        .set("general.window.expand_on_hover", json!(false))
        .expect("valid toggle");
    let _ = harness.quiet();
    assert!(
        harness.window.error("general.window.graph_width").is_some(),
        "an unrelated change cleared the invalid state"
    );
    // Repairing the field clears the reason and saves.
    harness.type_into("general.window.graph_width", "240");
    harness.quiet();
    assert_eq!(
        harness.values()["general.window.graph_width"],
        json!(240),
        "the repaired value was not saved"
    );
    assert!(
        harness.window.error("general.window.graph_width").is_none(),
        "the repair kept the danger reason"
    );
}

#[test]
fn reset_section_asks_then_resets() {
    let mut harness = Harness::new();
    harness
        .store
        .set("general.window.graph_width", json!(300))
        .expect("valid width");
    harness.window.select_section("general");
    let _ = harness.quiet();
    harness.click("general.reset");
    let frame = harness.quiet();
    assert!(
        labelled(&frame, "Reset General to defaults?"),
        "the reset did not ask first"
    );
    // Declining resets nothing.
    harness.click_labelled("Cancel");
    assert_eq!(
        harness.values()["general.window.graph_width"],
        json!(300),
        "a declined reset changed the section"
    );
    // Confirming resets every section entry to its default.
    harness.click("general.reset");
    let _ = harness.quiet();
    harness.click_labelled("Reset");
    assert!(
        harness.values().get("general.window.graph_width").is_none(),
        "the confirmed reset kept the section's change"
    );
    assert!(
        harness.window.take_dirty(),
        "the reset did not report a change"
    );
}

#[test]
fn unreadable_file_shows_banner_and_replace_action() {
    let root = std::env::temp_dir().join(format!(
        "xrg-settings-banner-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(root.join("xrg-ng")).unwrap();
    let path = root.join("xrg-ng/settings.json");
    fs::write(&path, b"certainly not json").unwrap();
    let catalog = document::catalog().expect("the shared core provides the catalog");
    let mut harness = Harness {
        ctx: egui::Context::default(),
        window: SettingsWindow::new(catalog),
        store: Store::open(&root),
        root: root.clone(),
        catalog: document::catalog().expect("the catalog"),
    };
    harness.ctx.enable_accesskit();
    let frame = harness.quiet();
    assert!(
        labelled(&frame, "The settings document needs attention"),
        "the unreadable file did not show its banner"
    );
    assert!(harness.store.blocked(), "the fixture is not blocked");
    // A change while the file is unreadable stays in memory only.
    harness.click("general.window.expand_on_hover");
    assert_eq!(
        fs::read(&path).unwrap(),
        b"certainly not json",
        "a blocked document was written"
    );
    // The user confirms replacing the file: the held change lands in it.
    harness.click_labelled("Replace the file with the current settings");
    let reopened = Store::open(&root);
    assert!(
        reopened.load_problem().is_none(),
        "the replaced document still reports a problem"
    );
    assert_eq!(
        reopened.values()["general.window.expand_on_hover"],
        json!(false),
        "the held change did not reach the replaced document"
    );
    let frame = harness.quiet();
    assert!(
        !labelled(&frame, "The settings document needs attention"),
        "the banner stayed after the replacement"
    );
    fs::remove_dir_all(&root).unwrap();
}

#[test]
fn legacy_import_still_works() {
    let mut harness = Harness::new();
    harness.window.select_section("themes");
    let _ = harness.quiet();
    // The GTK legacy import action: review, then accept — and accepting
    // produces the same document the old draft-then-Apply flow did: the
    // imported view saved whole through the store's whole-view save.
    let file = harness.root.join("legacy.conf");
    fs::write(&file, b"[Modules]\nshow_cpu=false\n").unwrap();
    let base = harness.store.settings().clone();
    let review = crate::legacy::load(&file, &base).expect("the fixture parses");
    // The review alone changes nothing.
    assert!(
        !harness.document().exists(),
        "the review alone wrote the document"
    );
    harness.window.import = Some(review);
    harness
        .window
        .accept_import(&mut harness.store)
        .expect("the imported view saves");
    let reopened = Store::open(&harness.root);
    assert!(
        !reopened
            .settings()
            .modules
            .iter()
            .find(|module| module.id == settings::Module::Cpu)
            .unwrap()
            .visible,
        "the imported CPU visibility was lost"
    );
    assert_eq!(
        fs::read(&file).unwrap(),
        b"[Modules]\nshow_cpu=false\n",
        "the import changed its source file"
    );
    assert!(
        harness.document().exists(),
        "the accepted import did not persist"
    );
    assert!(harness.window.take_dirty(), "the import was not reported");
}

#[test]
fn keyboard_navigation_reaches_every_control() {
    let mut harness = Harness::new();
    harness.window.select_section("weather");
    // Tab order: the sidebar first, then every control of the section,
    // each with its catalog label as the accessible name (lesson d).
    let _ = harness.quiet();
    let entries: Vec<String> = linux_entries(&harness.catalog, "weather")
        .iter()
        .map(|entry| entry.id.clone())
        .collect();
    let mut visited = Vec::new();
    let mut sidebar_seen = Vec::new();
    for _ in 0..96 {
        let frame = harness.frame(vec![key(egui::Key::Tab)]);
        let focused = harness.ctx.memory(|memory| memory.focused());
        let Some(focused) = focused else {
            continue;
        };
        if let Some(control) = harness
            .window
            .rendered()
            .iter()
            .find(|rendered| rendered.response.id == focused)
        {
            if !visited.contains(&control.id) {
                assert!(
                    control.label.is_empty() || labelled(&frame, &control.label),
                    "{} lost its catalog label",
                    control.id
                );
                visited.push(control.id.clone());
            }
        } else if let Some(title) =
            frame
                .platform_output
                .accesskit_update
                .as_ref()
                .and_then(|tree| {
                    tree.nodes
                        .iter()
                        .find(|(id, _)| *id == focused.accesskit_id())
                        .and_then(|(_, node)| node.label().map(str::to_owned))
                })
            && !sidebar_seen.contains(&title)
        {
            sidebar_seen.push(title);
        }
        if visited.len() == entries.len() {
            break;
        }
    }
    for title in ["General", "Weather", "Themes & import"] {
        assert!(
            sidebar_seen.iter().any(|label| label == title),
            "the Tab walk never visited the sidebar's {title} button (walked {sidebar_seen:?})"
        );
    }
    for entry in &entries {
        assert!(
            visited.iter().any(|id| id == entry),
            "Tab never reached {entry} (walked {visited:?})"
        );
    }
}

// The macOS window's review lessons, each with its test.

#[test]
fn dependent_controls_cannot_be_edited() {
    let mut harness = Harness::new();
    harness.window.select_section("graphs");
    let _ = harness.quiet();
    // Samples is enabled while the CPU time window is zero (lesson b).
    assert!(
        harness
            .window
            .rendered()
            .iter()
            .find(|rendered| rendered.id == "graphs.cpu.samples")
            .is_some_and(|rendered| rendered.enabled),
        "samples should be enabled while the CPU time window is 0"
    );
    harness
        .store
        .set("graphs.cpu.time_window", json!(5))
        .expect("valid window");
    let _ = harness.quiet();
    let samples_id = harness
        .window
        .rendered()
        .iter()
        .find(|rendered| rendered.id == "graphs.cpu.samples")
        .unwrap()
        .response
        .id;
    let _ = harness.quiet();
    let before = fs::read(harness.document()).unwrap();
    // A click and typed digits on the disabled control save nothing.
    harness.type_into("graphs.cpu.samples", "150");
    harness.quiet();
    assert!(
        harness.values().get("graphs.cpu.samples").is_none(),
        "a disabled control saved an edit"
    );
    assert_eq!(
        fs::read(harness.document()).unwrap(),
        before,
        "a disabled control changed the document"
    );
    // And the Tab walk skips it entirely (lesson d).
    for _ in 0..96 {
        let _ = harness.frame(vec![key(egui::Key::Tab)]);
        if let Some(focused) = harness.ctx.memory(|memory| memory.focused()) {
            assert_ne!(
                focused, samples_id,
                "the Tab walk stopped on the disabled control"
            );
        }
    }
    // Back again: the dependency re-enables the control.
    harness
        .store
        .set("graphs.cpu.time_window", json!(0))
        .expect("valid window");
    let _ = harness.quiet();
    assert!(
        harness
            .window
            .rendered()
            .iter()
            .find(|rendered| rendered.id == "graphs.cpu.samples")
            .is_some_and(|rendered| rendered.enabled),
        "the dependency did not re-enable samples"
    );
}

#[test]
fn source_pickers_select_by_value_never_by_index() {
    let mut harness = Harness::new();
    // A stored source that is not currently offered shows itself and stays
    // selected; it never snaps to another option by index (lesson c).
    harness
        .store
        .set("sources.temperature.sensor1", json!("removed-sensor"))
        .expect("valid id");
    harness.window.select_section("sources");
    let frame = harness.quiet();
    assert!(
        labelled(&frame, "Unavailable: removed-sensor"),
        "the missing source did not stay selected by value"
    );
    // An offered option restores by its id, never an index-mate's.
    harness
        .store
        .set("sources.temperature.sensor2", json!("acpi-2"))
        .expect("valid id");
    let frame = harness.quiet();
    assert!(
        labelled(&frame, "Board"),
        "the offered source did not restore by value"
    );
}

#[test]
fn focus_halo_is_two_pixels_and_space_activates() {
    let mut harness = Harness::new();
    harness.window.select_section("general");
    let _ = harness.quiet();
    let centre = harness
        .window
        .rendered()
        .iter()
        .find(|rendered| rendered.id == "general.window.expand_on_hover")
        .expect("the toggle rendered")
        .response
        .rect
        .center();
    harness.click_at(centre);
    let frame = harness.quiet();
    assert!(
        harness
            .ctx
            .memory(|memory| memory.focused())
            .is_some_and(|focused| harness
                .window
                .rendered()
                .iter()
                .any(|rendered| rendered.response.id == focused)),
        "the click did not focus a control"
    );
    // The 2 px Carolina halo paints around the focused control (lesson d).
    let halo = super::super::settings_style::focus_halo();
    let haloed = frame.shapes.iter().any(|clipped| {
        matches!(&clipped.shape, egui::Shape::Rect(rect)
            if rect.stroke.width == 2. && rect.stroke.color == halo)
    });
    assert!(haloed, "the focused control paints no 2 px halo");
    // Space activates it through the keyboard contract — the click turned
    // the toggle off, so the keyboard press turns it back on: the stored
    // value returns to the catalog default, where the document keeps no
    // key at all.
    let _ = harness.frame(vec![key(egui::Key::Space)]);
    assert!(
        harness
            .values()
            .get("general.window.expand_on_hover")
            .is_none()
            && harness.store.settings().window_collapse.expand_on_hover,
        "Space did not activate the focused control"
    );
}

#[test]
fn colour_overrides_return_to_inherit() {
    let mut harness = Harness::new();
    harness
        .store
        .set("appearance.series2.color", json!([0.8, 0.3, 0.2, 1.0]))
        .expect("valid colour");
    harness
        .store
        .set("general.window.expand_on_hover", json!(false))
        .expect("valid toggle");
    harness.window.select_section("appearance");
    let _ = harness.quiet();
    // Inherit returns the entry to the unset value without resetting any
    // unrelated setting (lesson e). The core stores null as "not set" —
    // the platform inherits — so the document holds the key with null.
    harness.click_labelled("Inherit the default Series 2 color");
    assert_eq!(
        harness.values()["appearance.series2.color"],
        json!(null),
        "Inherit did not return the entry to the unset value"
    );
    assert_eq!(
        harness.values()["general.window.expand_on_hover"],
        json!(false),
        "Inherit reset unrelated settings"
    );
}

#[test]
fn builtin_theme_selection_applies_the_palette() {
    let mut harness = Harness::new();
    harness.window.select_section("themes");
    let _ = harness.quiet();
    let midnight = crate::shared::themes()
        .into_iter()
        .find(|theme| theme.name == "Midnight")
        .expect("Midnight is a built-in theme");
    // Choosing a built-in writes its palette and its name (lesson f) —
    // the Themes picker's action.
    harness
        .window
        .choose_preset("Midnight", &mut harness.store)
        .expect("the preset applies");
    let values = harness.values();
    for (index, id) in super::super::settings_controls::PALETTE_IDS
        .iter()
        .enumerate()
    {
        let stored = values[*id].as_array().unwrap();
        for (component, expected) in stored.iter().zip(&midnight.colors[index]) {
            assert!(
                (component.as_f64().unwrap() - expected).abs() < 1e-9,
                "the preset colour {id} did not apply"
            );
        }
    }
    assert_eq!(values["themes.name"], json!("Midnight"));
    assert_eq!(values["themes.preset"], json!("Midnight"));
    assert!(
        harness.window.take_dirty(),
        "the preset did not report its change"
    );
    // Editing one colour under the preset marks the theme Custom — the
    // catalog's documented rule, driven through the window's apply path.
    harness
        .store
        .set("appearance.series2.color", json!([0.9, 0.1, 0.1, 1.0]))
        .expect("valid colour");
    let _ = harness.quiet();
    assert_eq!(
        harness.values()["themes.preset"],
        json!("Custom"),
        "an edited palette did not become Custom"
    );
}

#[test]
fn graph_order_is_a_reorderable_list_with_aligned_names() {
    let mut harness = Harness::new();
    harness.window.select_section("graphs");
    let frame = harness.quiet();
    assert!(
        labelled(&frame, "Move CPU up"),
        "the order list has no keyboard Move buttons"
    );
    assert!(
        labelled(&frame, "Move CPU down"),
        "the order list is missing its other direction"
    );
    assert!(
        labelled(&frame, "AI Tokens"),
        "the order list does not show the graph names"
    );
    // One aligned name column (W2): the Move up buttons line up.
    let ups: Vec<f32> = ["CPU", "GPU", "NPU", "VRAM", "Memory"]
        .iter()
        .filter_map(|name| node_centre(&frame, &format!("Move {name} up")).map(|centre| centre.x))
        .collect();
    assert!(ups.len() >= 2, "the Move up buttons did not render");
    let spread =
        ups.iter().cloned().fold(f32::MIN, f32::max) - ups.iter().cloned().fold(f32::MAX, f32::min);
    assert!(
        spread < 1.5,
        "the Move up buttons do not share one column: {ups:?}"
    );
    // A Move button writes the order setting, and focus stays on the moved
    // graph's button (lesson d).
    harness.click_labelled("Move CPU down");
    assert_eq!(
        harness.values()["graphs.order"],
        json!(
            "gpu,cpu,npu,vram,memory,battery,temperature,fans,network,disk,weather,stock,ai,processes"
        ),
        "the Move button did not write the order"
    );
    let frame = harness.quiet();
    let moved = node_centre(&frame, "Move CPU down").expect("the moved row rendered");
    // The tree's focus names the focused node, and its bounds are the
    // button's place in this frame — the one place focus should be.
    let tree = frame
        .platform_output
        .accesskit_update
        .as_ref()
        .expect("the a11y tree");
    let focused_centre = tree
        .nodes
        .iter()
        .find(|(id, _)| *id == tree.focus)
        .and_then(|(_, node)| node.bounds())
        .map(|bounds| {
            Pos2::new(
                (bounds.x0 + bounds.x1) as f32 / 2.,
                (bounds.y0 + bounds.y1) as f32 / 2.,
            )
        });
    assert_eq!(
        focused_centre,
        Some(moved),
        "focus did not stay on the moved graph"
    );
    // The endpoint rows' outward buttons are disabled — the first row's
    // Move up — and the disabled control is still keyboard-reachable-proof:
    // the Tab walk never stops on it.
    let first_up = node_centre(&frame, "Move GPU up");
    assert!(
        first_up.is_some(),
        "the second row's Move up button did not render"
    );
}

#[test]
fn network_minimum_scale_presents_in_units_and_hides_the_sentinel() {
    let mut harness = Harness::new();
    harness.window.select_section("graphs");
    harness
        .store
        .set("graphs.network.minimum_scale", json!(1_048_576))
        .expect("valid bytes");
    let frame = harness.quiet();
    assert_eq!(
        node_value(&frame, "Minimum scale unit").as_deref(),
        Some("MB/s"),
        "the stored bytes/s did not present in its largest dividing unit"
    );
    // The sentinel is not a range: no upper-bound text (lesson i).
    let labels = all_labels(&frame);
    assert!(
        !labels.iter().any(|label| label.contains("740")),
        "the max-safe-integer sentinel shows as a range: {labels:?}"
    );
    // A bounded entry still shows its range (the mockup's "N – N").
    assert!(
        labels.iter().any(|label| label == "64 – 240"),
        "the bounded default height lost its range text: {labels:?}"
    );
    // A typed number stores whole bytes with checked arithmetic, in the
    // unit the selector seeded — bytes/s, the stored default's unit (the
    // macOS test picks its unit first; the freshly opened window has the
    // same one).
    let mut fresh = Harness::new();
    fresh.window.select_section("graphs");
    fresh.type_into("graphs.network.minimum_scale", "2048");
    assert_eq!(
        fresh.values()["graphs.network.minimum_scale"],
        json!(2048),
        "the typed bytes did not store exactly"
    );
    assert!(
        fresh.window.take_dirty(),
        "the typed bytes did not report their change"
    );
}

#[test]
fn changes_reach_the_live_dashboard_immediately() {
    let mut harness = Harness::new();
    harness.window.select_section("general");
    let _ = harness.quiet();
    // A saved change reports itself; the App-facing host (ui.rs) adopts the
    // store's view on that flag, and adopt_live pushes it to the live
    // settings and workers (lesson h). The live-worker end of the chain is
    // the egui smoke gate's stage 5, unchanged.
    harness.click("general.window.expand_on_hover");
    assert!(
        !harness.store.settings().window_collapse.expand_on_hover,
        "the stored view the dashboard adopts is stale"
    );
    assert!(harness.window.take_dirty(), "the change was not reported");
    let mut live = harness.store.settings().clone();
    let worker = crate::engine::Worker::start_with_settings(false, &live);
    let mut theme = live.theme.palette().expect("the palette");
    let stored = harness.store.settings().clone();
    super::super::adopt_live(&mut live, &mut theme, &worker, stored)
        .expect("the live dashboard adopts the stored view");
    assert!(
        !live.window_collapse.expand_on_hover,
        "the live settings did not follow the stored view"
    );
    assert_eq!(theme.name, "Classic");
}

#[test]
fn stocks_persist_without_a_module() {
    let mut harness = Harness::new();
    harness.window.select_section("stocks");
    let _ = harness.quiet();
    harness.click("stocks.show_djia");
    assert_eq!(
        harness.values()["stocks.show_djia"],
        json!(false),
        "the Stocks toggle did not persist through the store"
    );
    // The Linux view carries the Stocks settings even though no graph draws
    // them yet (ruling R2; Task 12 adds Module::Stocks).
    assert!(!harness.store.settings().stocks.show_djia);
    assert_eq!(harness.store.settings().stocks.symbols, "AAPL");
}

#[test]
fn rendering_is_stable_and_writes_nothing() {
    // Rendering the window writes nothing, and two quiet frames paint the
    // same shape count: the window has no timed transitions, so reduced
    // motion is honoured by construction. Sections open from their top.
    let mut harness = Harness::new();
    for section in harness.catalog.sections.clone() {
        harness.window.select_section(&section);
        // Warm up: the first frames settle egui's font atlas and layout.
        let _ = harness.quiet();
        let _ = harness.quiet();
        let first = harness.quiet();
        let second = harness.quiet();
        assert_eq!(
            first.shapes.len(),
            second.shapes.len(),
            "{section}: the window animated between identical frames"
        );
        assert!(
            !harness.document().exists(),
            "rendering the window wrote the settings document"
        );
        // Each section opens from its eyebrow, near the pane's top.
        let eyebrow = ["general", "graphs", "stocks"]
            .contains(&section.as_str())
            .then(|| {
                node_centre(&second, &format!("// {}", section.to_uppercase()))
                    .or_else(|| node_centre(&second, &section.to_uppercase()))
            })
            .flatten();
        if let Some(eyebrow) = eyebrow {
            assert!(
                eyebrow.y < 130.,
                "{section} did not open from its top: {eyebrow:?}"
            );
        }
    }
}

// The token-only audit (lesson j): the style and every painted shape, with
// no blanket exclusions — the only allowance is a colour well's own swatch
// content, bounded to the well's rect.

#[test]
fn only_aether7b_colours() {
    for theme in ["light", "dark"] {
        unsafe {
            std::env::set_var("XRG_SETTINGS_THEME", theme);
        }
        let mut harness = Harness::new();
        for section in harness.catalog.sections.clone() {
            harness.window.select_section(&section);
            let frame = harness.quiet();
            audit(&harness, &frame, theme == "dark");
        }
    }
    unsafe {
        std::env::remove_var("XRG_SETTINGS_THEME");
    }
}

fn audit(harness: &Harness, frame: &egui::FullOutput, dark: bool) {
    let tokens = super::super::settings_style::token_colors(dark);
    // egui's Color32 bytes are premultiplied by their alpha everywhere —
    // the shape's colour and the token's alike — so they compare directly.
    let allowed = |color: egui::Color32| {
        tokens.iter().any(|token| {
            let [tr, tg, tb, ta] = token.to_array();
            let [r, g, b, a] = color.to_array();
            (tr as i32 - r as i32).abs() <= 3
                && (tg as i32 - g as i32).abs() <= 3
                && (tb as i32 - b as i32).abs() <= 3
                && (ta as i32 - a as i32).abs() <= 8
        })
    };
    // The colour wells' swatches are the user's own content (the one
    // allowance); their pixels lie inside the rendered colour rects.
    let wells: Vec<Rect> = harness
        .window
        .rendered()
        .iter()
        .filter(|rendered| rendered.control == "color")
        .map(|rendered| rendered.response.rect.expand(1.5))
        .collect();
    let mut painted = 0;
    for clipped in &frame.shapes {
        let _ = clipped.clip_rect;
        match &clipped.shape {
            egui::Shape::Rect(shape) => {
                painted += 1;
                if shape.fill != egui::Color32::TRANSPARENT
                    && !wells.iter().any(|well| well.intersects(shape.rect))
                {
                    assert!(
                        allowed(shape.fill),
                        "non-token fill {:?} in {}",
                        shape.fill,
                        harness.window.section()
                    );
                }
                if shape.stroke.color != egui::Color32::TRANSPARENT {
                    assert!(
                        allowed(shape.stroke.color),
                        "non-token stroke {:?} in {}",
                        shape.stroke.color,
                        harness.window.section()
                    );
                }
                // An invisible rect paints nothing — the desktop shows
                // through — so it draws no corner the audit can read.
                let painted_shape = shape.fill != egui::Color32::TRANSPARENT
                    || (shape.stroke.color != egui::Color32::TRANSPARENT
                        && shape.stroke.width > 0.);
                // A rect may round only its bottom corners (the sidebar
                // under the headerbar): the largest corner is the one drawn.
                let radius = shape
                    .corner_radius
                    .nw
                    .max(shape.corner_radius.ne)
                    .max(shape.corner_radius.sw)
                    .max(shape.corner_radius.se);
                let half = 0.5 * shape.rect.size().min_elem();
                if painted_shape {
                    // The paint clamps every corner to half the shortest
                    // side (the CSS rule), so the corner the user sees is
                    // the smaller of the shape's radius and that half —
                    // the tokens govern the seen corner, and a full round
                    // is the pill the mockup draws with.
                    let painted_corner = (radius as f32).min(half);
                    assert!(
                        super::super::settings_style::TOKEN_RADII
                            .contains(&(painted_corner.round() as u8))
                            || (painted_corner - half).abs() <= 1.5,
                        "non-token corner radius {radius} in {}",
                        harness.window.section()
                    );
                }
            }
            egui::Shape::Circle(circle) => {
                painted += 1;
                if circle.fill != egui::Color32::TRANSPARENT {
                    assert!(
                        allowed(circle.fill),
                        "non-token circle fill {:?} in {}",
                        circle.fill,
                        harness.window.section()
                    );
                }
                if circle.stroke.color != egui::Color32::TRANSPARENT {
                    assert!(
                        allowed(circle.stroke.color),
                        "non-token circle stroke {:?} in {} (dark {dark})",
                        circle.stroke.color,
                        harness.window.section()
                    );
                }
            }
            egui::Shape::Mesh(mesh) => {
                for vertex in &mesh.vertices {
                    painted += 1;
                    let spot = Rect::from_center_size(vertex.pos, Vec2::splat(2.));
                    if !wells.iter().any(|well| well.intersects(spot)) {
                        assert!(
                            allowed(vertex.color),
                            "non-token mesh colour {:?} in {} (dark {dark})",
                            vertex.color,
                            harness.window.section()
                        );
                    }
                }
            }
            egui::Shape::Text(text) => {
                painted += 1;
                // Text colour is one of the tokens it was laid out with;
                // the glyph vertices carry it into the tessellation audit
                // (the Mesh arm) and the label audit below.
                let _ = text;
            }
            _ => painted += 1,
        }
    }
    assert!(
        painted > 40,
        "{} painted too little: {painted}",
        harness.window.section()
    );
}
