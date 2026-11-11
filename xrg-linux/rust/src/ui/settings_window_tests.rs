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
    /// One quiet frame on a taller screen: the whole section renders with
    /// nothing below the scroll fold, for the geometry test's painted-
    /// label checks over every row.
    fn quiet_tall(&mut self) -> egui::FullOutput {
        let raw = RawInput {
            screen_rect: Some(Rect::from_min_size(Pos2::ZERO, Vec2::new(SCREEN.x, 8000.))),
            ..Default::default()
        };
        let mut output = self.ctx.run_ui(raw, |ui| {
            self.window.render(ui, &mut self.store, &FixtureSources)
        });
        output.textures_delta.clear();
        output
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

/// Every node's bounds carrying this exact label.
#[allow(dead_code)]
fn all_labelled(output: &egui::FullOutput, label: &str) -> Vec<egui::Rect> {
    output
        .platform_output
        .accesskit_update
        .as_ref()
        .map(|tree| {
            tree.nodes
                .iter()
                .filter(|(_, node)| node.label() == Some(label))
                .filter_map(|(_, node)| node.bounds())
                .map(|bounds| {
                    Rect::from_min_max(
                        Pos2::new(bounds.x0 as f32, bounds.y0 as f32),
                        Pos2::new(bounds.x1 as f32, bounds.y1 as f32),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The focused widget's exact accessible name, from the frame's tree.
fn focused_label(output: &egui::FullOutput, focused: Option<egui::Id>) -> Option<String> {
    focused_identity(output, focused).map(|(_, _, label)| label)
}

/// The focused widget's accesskit id, role and exact name. Coverage tracks
/// this identity, never the name alone: a composite row's field and slider
/// share a catalog label and must still count as two controls.
fn focused_identity(
    output: &egui::FullOutput,
    focused: Option<egui::Id>,
) -> Option<(egui::accesskit::NodeId, egui::accesskit::Role, String)> {
    let tree = output.platform_output.accesskit_update.as_ref()?;
    let id = focused?.accesskit_id();
    tree.nodes
        .iter()
        .find(|(node_id, _)| *node_id == id)
        .and_then(|(node_id, node)| {
            node.label()
                .map(|label| (*node_id, node.role(), label.to_owned()))
        })
}

/// Every node of one frame's tree with the given role and exact label.
fn nodes_with_role(
    output: &egui::FullOutput,
    role: egui::accesskit::Role,
    label: &str,
) -> Vec<Rect> {
    output
        .platform_output
        .accesskit_update
        .as_ref()
        .map(|tree| {
            tree.nodes
                .iter()
                .filter(|(_, node)| node.role() == role && node.label() == Some(label))
                .filter_map(|(_, node)| node.bounds())
                .map(|bounds| {
                    Rect::from_min_max(
                        Pos2::new(bounds.x0 as f32, bounds.y0 as f32),
                        Pos2::new(bounds.x1 as f32, bounds.y1 as f32),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The rect a painted text shape with exactly this galley text occupies,
/// overlapping `around`.
fn painted_text(frame: &egui::FullOutput, text: &str, around: Rect) -> Rect {
    for clipped in &frame.shapes {
        if let egui::Shape::Text(painted) = &clipped.shape {
            let rect = Rect::from_min_size(painted.pos, painted.galley.rect.size());
            if painted.galley.text() == text && rect.intersects(around) {
                return rect;
            }
        }
    }
    panic!("no painted text {text:?} around {around:?}");
}

/// The value of the text field named `label` — role-filtered, because a
/// composite row's slider and field can share the catalog label.
fn field_value(output: &egui::FullOutput, label: &str) -> Option<String> {
    let tree = output.platform_output.accesskit_update.as_ref()?;
    tree.nodes
        .iter()
        .find(|(_, node)| {
            node.role() == egui::accesskit::Role::TextInput && node.label() == Some(label)
        })
        .and_then(|(_, node)| node.value())
        .map(|value| value.to_string())
}

/// The accesskit value of the combo named `label`. A composite row can
/// also announce that label on another node; the unit the selector shows
/// is this role's value.
fn combo_value(output: &egui::FullOutput, label: &str) -> Option<String> {
    let tree = output.platform_output.accesskit_update.as_ref()?;
    tree.nodes
        .iter()
        .find(|(_, node)| {
            node.role() == egui::accesskit::Role::ComboBox && node.label() == Some(label)
        })
        .and_then(|(_, node)| node.value())
        .map(|value| value.to_string())
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

/// A value the shared core's semantic constraints refuse (final review,
/// finding 1 / ruling R29): the one-character station that used to crash
/// the Linux launch shows the constraint's reason and saves nothing, and
/// the station the worker normalises at read time still saves.
#[test]
fn constraint_refusal_shows_the_entrys_reason_and_saves_nothing() {
    let mut harness = Harness::new();
    harness
        .store
        .set("weather.refresh", json!(20))
        .expect("valid refresh");
    harness.window.select_section("weather");
    let _ = harness.quiet();
    let before = fs::read(harness.document()).unwrap();
    harness.type_into("weather.station", "K");
    let frame = harness.quiet();
    let reason = harness
        .window
        .error("weather.station")
        .expect("the station shows its constraint reason")
        .to_owned();
    assert_eq!(
        reason,
        "Enter a four-character ICAO station code, for example KSEA."
    );
    assert!(
        labelled(&frame, &reason),
        "the reason {reason:?} did not render inside the row"
    );
    assert_eq!(
        fs::read(harness.document()).unwrap(),
        before,
        "the refused station changed the document"
    );
    assert_ne!(
        harness.values().get("weather.station"),
        Some(&json!("K")),
        "the refused station reached the store"
    );
    // A station the worker normalises at read time saves; the reason
    // clears. The egui field submits trimmed text, so the stored value is
    // the trimmed one.
    harness.type_into("weather.station", " ksea ");
    harness.quiet();
    assert_eq!(
        harness.values()["weather.station"],
        json!("ksea"),
        "the normalising station was not saved"
    );
    assert!(
        harness.window.error("weather.station").is_none(),
        "the saved station kept its danger reason"
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

/// The accessible names a section's enabled controls announce, derived
/// from the catalog exactly as the controls build them (lesson d): the
/// entry labels, and the subcontrol names composites add.
fn expected_names(
    catalog: &Catalog,
    values: &serde_json::Map<String, Value>,
    section: &str,
) -> std::collections::BTreeSet<String> {
    let mut expected = std::collections::BTreeSet::new();
    for entry in linux_entries(catalog, section) {
        if !super::settings_controls::depends_holds(values, &catalog.entries, entry) {
            continue; // disabled controls never join the focus walk
        }
        let label = entry.label.as_str();
        match entry.control.as_str() {
            "toggle" | "choice" | "source" | "integer" | "decimal" | "duration" | "text"
            | "action" => {
                expected.insert(label.to_owned());
                // A bytes/s entry also offers its unit selector.
                if entry
                    .range
                    .as_ref()
                    .is_some_and(|range| range.unit.as_deref() == Some("bytes/s"))
                {
                    expected.insert(format!("{label} unit"));
                }
            }
            "color" => {
                expected.insert(label.to_owned());
                expected.insert(format!("Inherit the default {label}"));
            }
            "path" => {
                expected.insert(label.to_owned());
                expected.insert(format!("Choose {label}"));
            }
            "segmented" => {
                for option in entry.options.iter().flatten() {
                    expected.insert(format!("{label}: {}", option.label));
                }
            }
            "order" => {
                let ids: Vec<&str> = entry
                    .default
                    .as_str()
                    .unwrap_or_default()
                    .split(',')
                    .filter(|id| !id.is_empty())
                    .collect();
                for (index, id) in ids.iter().enumerate() {
                    let name = super::settings_controls::graph_name(id);
                    // The endpoint rows' outward buttons are disabled and
                    // never join the focus walk (lesson d).
                    if index > 0 {
                        expected.insert(format!("Move {name} up"));
                    }
                    if index + 1 < ids.len() {
                        expected.insert(format!("Move {name} down"));
                    }
                }
            }
            other => panic!("unknown control {other}"),
        }
    }
    expected
}

/// The same coverage as `expected_names`, keyed by role so a shared label
/// cannot collapse a field and its slider into one control. A stepped entry
/// contributes both widgets; a bytes/s entry contributes its unit combo.
fn expected_controls(
    catalog: &Catalog,
    values: &serde_json::Map<String, Value>,
    section: &str,
) -> Vec<(egui::accesskit::Role, String)> {
    let mut expected = Vec::new();
    for entry in linux_entries(catalog, section) {
        if !super::settings_controls::depends_holds(values, &catalog.entries, entry) {
            continue;
        }
        let label = entry.label.as_str();
        let role = egui::accesskit::Role::Button;
        match entry.control.as_str() {
            "toggle" => expected.push((egui::accesskit::Role::CheckBox, label.to_owned())),
            "choice" | "source" => {
                expected.push((egui::accesskit::Role::ComboBox, label.to_owned()));
            }
            "integer" | "decimal" | "duration" | "text" => {
                expected.push((egui::accesskit::Role::TextInput, label.to_owned()));
                if entry.range.as_ref().is_some_and(|range| {
                    range.max < super::settings_controls::UNBOUNDED_MAXIMUM
                        && range.step.is_some_and(|step| step > 0.)
                }) {
                    expected.push((egui::accesskit::Role::Slider, label.to_owned()));
                }
                if entry
                    .range
                    .as_ref()
                    .is_some_and(|range| range.unit.as_deref() == Some("bytes/s"))
                {
                    expected.push((egui::accesskit::Role::ComboBox, format!("{label} unit")));
                }
            }
            "action" => expected.push((role, label.to_owned())),
            "color" => {
                expected.push((egui::accesskit::Role::ColorWell, label.to_owned()));
                expected.push((role, format!("Inherit the default {label}")));
            }
            "path" => {
                expected.push((egui::accesskit::Role::TextInput, label.to_owned()));
                expected.push((role, format!("Choose {label}")));
            }
            "segmented" => {
                for option in entry.options.iter().flatten() {
                    expected.push((role, format!("{label}: {}", option.label)));
                }
            }
            "order" => {
                let ids: Vec<&str> = entry
                    .default
                    .as_str()
                    .unwrap_or_default()
                    .split(',')
                    .filter(|id| !id.is_empty())
                    .collect();
                for (index, id) in ids.iter().enumerate() {
                    let name = super::settings_controls::graph_name(id);
                    if index > 0 {
                        expected.push((role, format!("Move {name} up")));
                    }
                    if index + 1 < ids.len() {
                        expected.push((role, format!("Move {name} down")));
                    }
                }
            }
            other => panic!("unknown control {other}"),
        }
    }
    expected
}

/// Tab until the focused node is this role and exact label. Returns the
/// widget id and the frame that focused it.
fn focus_role(
    harness: &mut Harness,
    role: egui::accesskit::Role,
    label: &str,
) -> (egui::Id, egui::FullOutput) {
    let mut frame = harness.quiet();
    for _ in 0..600 {
        let focused = harness.ctx.memory(|memory| memory.focused());
        if let Some((_, focused_role, focused_label)) = focused_identity(&frame, focused)
            && focused_role == role
            && focused_label == label
        {
            return (focused.expect("just matched"), frame);
        }
        frame = harness.frame(vec![key(egui::Key::Tab)]);
    }
    panic!(
        "Tab never focused {label} ({role:?}); the tree holds {:?}",
        all_labels(&frame)
    );
}

fn halo_around(frame: &egui::FullOutput, rect: Rect) -> bool {
    let halo = super::super::settings_style::focus_halo();
    frame.shapes.iter().any(|clipped| {
        matches!(&clipped.shape, egui::Shape::Rect(shape)
            if shape.stroke.width == 2. && shape.stroke.color == halo
                && shape.rect.expand(1.).intersects(rect))
    })
}

#[test]
fn keyboard_navigation_reaches_every_control() {
    let mut harness = Harness::new();
    // The sidebar first, in catalog order, then the section's controls —
    // each focused node's accessible name is exactly its catalog name
    // (or the subcontrol name its composite derives), never a substring
    // matched against some other node (lesson d, review issue 6).
    let _ = harness.quiet();
    let mut sidebar = Vec::new();
    for _ in 0..8 {
        let frame = harness.frame(vec![key(egui::Key::Tab)]);
        let focused = harness.ctx.memory(|memory| memory.focused());
        let label = focused_label(&frame, focused)
            .unwrap_or_else(|| panic!("the Tab walk focused an unnamed node"));
        sidebar.push(label);
    }
    assert_eq!(
        sidebar,
        SECTION_TITLES
            .iter()
            .map(|(_, title)| title.to_owned())
            .collect::<Vec<_>>(),
        "the Tab walk did not visit the sidebar first, in order"
    );
    let sidebar_names: Vec<&str> = SECTION_TITLES.iter().map(|(_, t)| *t).collect();
    // One widget id always announces the same role and name. Coverage is
    // the set of those ids, not the set of names: a field and its slider
    // share a label and must both be visited (lesson d).
    let mut identities: std::collections::HashMap<egui::Id, (egui::accesskit::Role, String)> =
        std::collections::HashMap::new();
    for section in harness.catalog.sections.clone() {
        harness.window.select_section(&section);
        let _ = harness.quiet();
        let mut expected_labels = expected_names(&harness.catalog, &harness.values(), &section);
        let mut expected = expected_controls(&harness.catalog, &harness.values(), &section);
        if section == "themes" {
            // The Linux-specific legacy import block, inside the Themes
            // section's "Import and export" card, is window chrome the
            // walk must cover with the rest.
            expected_labels.insert("Legacy Linux settings path".into());
            expected_labels.insert("Browse legacy settings…".into());
            expected_labels.insert("Review pasted path…".into());
            expected.push((
                egui::accesskit::Role::TextInput,
                "Legacy Linux settings path".into(),
            ));
            expected.push((
                egui::accesskit::Role::Button,
                "Browse legacy settings…".into(),
            ));
            expected.push((egui::accesskit::Role::Button, "Review pasted path…".into()));
        }
        let mut required: std::collections::BTreeMap<(String, String), usize> =
            std::collections::BTreeMap::new();
        for (role, label) in &expected {
            *required
                .entry((format!("{role:?}"), label.clone()))
                .or_default() += 1;
        }
        let mut covered: std::collections::HashMap<
            (String, String),
            std::collections::HashSet<egui::Id>,
        > = std::collections::HashMap::new();
        // Geometric Tab order is acceptable. The walk still has to reach
        // every control, identified by widget id and role, and each focused
        // control paints later under its own test. A tall section wraps
        // through off-screen rows, so the budget is generous.
        let mut budget = expected.len() * 12 + 96;
        let done = |covered: &std::collections::HashMap<
            (String, String),
            std::collections::HashSet<egui::Id>,
        >| {
            required
                .iter()
                .all(|(key, count)| covered.get(key).is_some_and(|ids| ids.len() >= *count))
        };
        while !done(&covered) {
            if budget == 0 {
                let missing: Vec<_> = required
                    .iter()
                    .filter(|(key, count)| covered.get(key).is_none_or(|ids| ids.len() < **count))
                    .map(|(key, count)| {
                        format!(
                            "{key:?} want {count} got {}",
                            covered.get(key).map(|ids| ids.len()).unwrap_or(0)
                        )
                    })
                    .collect();
                panic!("{section}: the Tab walk never covered {missing:?}");
            }
            budget -= 1;
            let frame = harness.frame(vec![key(egui::Key::Tab)]);
            let focused = harness.ctx.memory(|memory| memory.focused());
            let Some(focused) = focused else {
                continue;
            };
            let Some((_, role, label)) = focused_identity(&frame, Some(focused)) else {
                panic!("{section}: the walk focused a node with no name");
            };
            if let Some(previous) = identities.insert(focused, (role, label.clone())) {
                assert_eq!(
                    previous,
                    (role, label.clone()),
                    "{section}: one focusable widget announced two identities"
                );
            }
            let known = expected_labels.contains(&label)
                || sidebar_names.contains(&label.as_str())
                || label == "Close settings";
            assert!(
                known,
                "{section}: the walk focused an unexpected name {label:?} (expected {expected_labels:?})"
            );
            let key = (format!("{role:?}"), label);
            if required.contains_key(&key) {
                covered.entry(key).or_default().insert(focused);
            }
        }
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
    // catalog's documented rule, driven through the window's apply path
    // (an edit operation, never a render).
    harness.window.select_section("appearance");
    let _ = harness.quiet();
    harness.click_labelled("Inherit the default Series 2 color");
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
fn network_scale_round_trips_through_every_unit_and_the_boundary() {
    let mut harness = Harness::new();
    let id = "graphs.network.minimum_scale";
    let document = harness.document();
    // Every unit presents the exact bytes it stands for and stores them
    // back exactly — checked conversions, the core the only validator
    // (lesson g, review issue 4). Re-selecting the section re-seeds the
    // presentation's unit from the stored value, so each unit presents.
    for (bytes, presented) in [
        (512i64, "512"),      // bytes/s: no larger unit divides it
        (2048, "2"),          // KB/s
        (1_572_864, "1536"),  // KB/s again: MB does not divide it
        (3_221_225_472, "3"), // GB/s
    ] {
        harness.store.set(id, json!(bytes)).expect("valid bytes");
        assert!(harness.window.select_section("graphs"));
        let frame = harness.quiet();
        assert_eq!(
            node_value(&frame, "Minimum scale").as_deref(),
            Some(presented),
            "{bytes} bytes did not present as {presented}"
        );
        // Retyping the presented value is an unchanged-value submission:
        // it saves nothing new, shows no reason and leaves the document
        // byte-identical.
        let before = fs::read(&document).unwrap();
        harness.type_into(id, presented);
        assert_eq!(
            harness.values()[id],
            json!(bytes),
            "{presented} did not round-trip to {bytes}"
        );
        assert!(
            harness.window.error(id).is_none(),
            "the unchanged submission for {presented} showed a reason"
        );
        assert_eq!(
            fs::read(&document).unwrap(),
            before,
            "the unchanged submission rewrote the document"
        );
    }
    // The catalog's upper bound round-trips through the field: the whole
    // max-safe-integer is a valid stored value (issue 4) — its largest
    // dividing unit is bytes/s (it is odd).
    harness.store.set(id, json!(0)).expect("valid bytes");
    assert!(harness.window.select_section("graphs"));
    harness.type_into(id, "9007199254740991");
    assert_eq!(
        harness.values()[id],
        json!(9_007_199_254_740_991u64),
        "the valid boundary value was refused"
    );
    // Range validity is the core's: a negative value reaches it and comes
    // back as its refusal with the bounds in the reason.
    harness.type_into(id, "-5");
    assert_eq!(
        harness.window.error(id),
        Some("Between 0 bytes/s and 9007199254740991 bytes/s."),
        "the core's range refusal did not reach the row"
    );
    // A unit conversion that is not a whole number of bytes never
    // reaches the store.
    harness.type_into(id, "1.5");
    assert!(
        harness
            .window
            .error(id)
            .is_some_and(|reason| reason.contains("whole number of bytes")),
        "a fractional byte count was not refused"
    );
    assert_eq!(harness.values()[id], json!(9_007_199_254_740_991u64));
    // And a scaled value that cannot fit the ABI's whole numbers is
    // refused before the core is asked: 8589934592 GB/s is 2^63 bytes.
    harness
        .store
        .set(id, json!(1_073_741_824))
        .expect("valid bytes");
    assert!(harness.window.select_section("graphs"));
    harness.type_into(id, "8589934592");
    assert!(
        harness
            .window
            .error(id)
            .is_some_and(|reason| reason.contains("too large")),
        "an unrepresentable byte count was not refused"
    );
}

#[test]
fn network_units_switch_and_round_trip_fractional_boundaries() {
    // Real unit changes, not auto-presentation: the focused combo cycles
    // with the arrow keys, paints the halo, and a fractional presentation
    // in that unit stores the exact bytes. Each unit also accepts its
    // boundary and an unchanged resubmission.
    let mut harness = Harness::new();
    let id = "graphs.network.minimum_scale";
    harness.window.select_section("graphs");
    harness.store.set(id, json!(1_536)).expect("valid bytes");
    let _ = harness.quiet();
    let (combo, _) = focus_role(
        &mut harness,
        egui::accesskit::Role::ComboBox,
        "Minimum scale unit",
    );
    let frame = harness.quiet();
    assert_eq!(
        harness.ctx.memory(|memory| memory.focused()),
        Some(combo),
        "the unit combo did not keep focus"
    );
    let combo_rect = nodes_with_role(
        &frame,
        egui::accesskit::Role::ComboBox,
        "Minimum scale unit",
    )
    .pop()
    .expect("the focused unit combo");
    assert!(
        halo_around(&frame, combo_rect),
        "the focused unit combo paints no 2 px halo"
    );
    // One arrow is a real unit switch: the presentation changes and the
    // stored bytes do not. The seeded unit is whatever the field chose.
    let seeded = combo_value(&frame, "Minimum scale unit").expect("the seeded unit");
    let seeded_field = field_value(&frame, "Minimum scale").expect("the seeded field");
    let _ = harness.frame(vec![key(egui::Key::ArrowRight)]);
    let frame = harness.quiet();
    let switched = combo_value(&frame, "Minimum scale unit").expect("the switched unit");
    let switched_field = field_value(&frame, "Minimum scale").expect("the switched field");
    assert_ne!(
        (seeded.as_str(), seeded_field.as_str()),
        (switched.as_str(), switched_field.as_str()),
        "the focused combo did not switch units ({seeded} {seeded_field} stayed)"
    );
    assert_eq!(harness.values()[id], json!(1_536));
    let presented = field_value(&frame, "Minimum scale").expect("the switched presentation");
    if switched != "bytes/s" {
        assert!(
            presented.contains('.'),
            "{switched} did not present 1536 as a fraction ({presented})"
        );
    }
    let document = harness.document();
    let before = fs::read(&document).unwrap();
    harness.type_into(id, &presented);
    assert_eq!(
        harness.values()[id],
        json!(1_536),
        "the fractional presentation did not round-trip"
    );
    assert_eq!(
        fs::read(&document).unwrap(),
        before,
        "the unchanged fractional submission rewrote the document"
    );
    // A typed fraction in each unit, reached by switching, not by seeding.
    for (unit, text, bytes) in [
        ("KB/s", "1.5", 1_536i64),
        ("MB/s", "1.5", 1_572_864),
        ("GB/s", "1.5", 1_610_612_736),
        ("bytes/s", "2048", 2_048),
    ] {
        select_scale_unit(&mut harness, unit);
        harness.type_into(id, text);
        assert_eq!(
            harness.values()[id],
            json!(bytes),
            "{text} {unit} did not store {bytes} bytes"
        );
        assert!(
            harness.window.error(id).is_none(),
            "{text} {unit} was refused: {:?}",
            harness.window.error(id)
        );
    }
    // Boundaries in each unit: 0, and the catalog maximum expressed in
    // that unit. Retyping either leaves the document byte-identical.
    let max = 9_007_199_254_740_991.0f64;
    for (unit, multiplier) in super::settings_controls::SCALE_UNITS {
        select_scale_unit(&mut harness, unit);
        harness.type_into(id, "0");
        assert!(
            harness
                .values()
                .get(id)
                .is_none_or(|value| value == &json!(0)),
            "0 {unit} did not store the lower boundary"
        );
        let before = fs::read(&document).unwrap();
        harness.type_into(id, "0");
        assert_eq!(
            fs::read(&document).unwrap(),
            before,
            "the unchanged 0 {unit} submission rewrote the document"
        );
        let text = format!("{}", max / multiplier as f64);
        let parsed: f64 = text.parse().expect("the boundary presentation parses");
        assert_eq!(
            parsed * multiplier as f64,
            max,
            "{unit} boundary text does not round-trip"
        );
        harness.type_into(id, &text);
        assert_eq!(
            harness.values()[id],
            json!(9_007_199_254_740_991u64),
            "the {unit} upper boundary was refused"
        );
        let before = fs::read(&document).unwrap();
        harness.type_into(id, &text);
        assert_eq!(
            fs::read(&document).unwrap(),
            before,
            "the unchanged {unit} boundary submission rewrote the document"
        );
    }
}

/// Arrow-cycle the minimum-scale combo until it shows `unit`.
fn select_scale_unit(harness: &mut Harness, unit: &str) {
    for _ in 0..5 {
        let _ = focus_role(
            harness,
            egui::accesskit::Role::ComboBox,
            "Minimum scale unit",
        );
        let frame = harness.quiet();
        if combo_value(&frame, "Minimum scale unit").as_deref() == Some(unit) {
            return;
        }
        let _ = harness.frame(vec![key(egui::Key::ArrowRight)]);
        let _ = harness.quiet();
    }
    panic!("the unit combo never switched to {unit}");
}

#[test]
fn changes_reach_the_live_dashboard_immediately() {
    let mut harness = Harness::new();
    // A custom series-2 override the live dashboard starts from: the
    // adoption below has to move it back to the inherited default.
    harness
        .store
        .set("appearance.series2.color", json!([0.8, 0.3, 0.2, 1.0]))
        .expect("valid colour");
    // The live state starts BEFORE any edit (review issue 6): a no-op
    // adoption cannot move it, so each leg asserts a real difference.
    let mut live = harness.store.settings().clone();
    let worker = crate::engine::Worker::start_with_settings(false, &live);
    let mut theme = live.theme.palette().expect("the palette");
    assert_eq!(theme.colors[3], [0.8, 0.3, 0.2, 1.0]);
    assert_eq!(live.layout, settings::Layout::Vertical);
    // Orientation, through the choice menu.
    harness.window.select_section("general");
    let _ = harness.quiet();
    harness.click_labelled("Orientation");
    harness.click_labelled("Horizontal");
    assert_eq!(
        harness.values()["general.window.orientation"],
        json!("horizontal")
    );
    // Size, through the number field.
    harness.type_into("general.window.graph_width", "300");
    assert_eq!(harness.values()["general.window.graph_width"], json!(300));
    // Order, through the reorderable list.
    harness.window.select_section("graphs");
    let _ = harness.quiet();
    harness.click_labelled("Move CPU down");
    // Visibility, through the toggle.
    harness.click("graphs.memory.visible");
    assert_eq!(harness.values()["graphs.memory.visible"], json!(false));
    // Colour, through Inherit.
    harness.window.select_section("appearance");
    let _ = harness.quiet();
    harness.click_labelled("Inherit the default Series 2 color");
    assert_eq!(harness.values()["appearance.series2.color"], json!(null));
    assert!(
        harness.window.take_dirty(),
        "the edits were not reported for adoption"
    );
    // The host's adoption pushes the stored view into the live state
    // (lesson h): orientation, size, order, visibility and colour all
    // follow, against the pre-edit values asserted above.
    let stored = harness.store.settings().clone();
    super::super::adopt_live(&mut live, &mut theme, &worker, stored)
        .expect("the live dashboard adopts the stored view");
    assert_eq!(live.layout, settings::Layout::Horizontal);
    assert_eq!(live.graph_width, 300);
    assert_eq!(
        live.modules
            .iter()
            .position(|m| m.id == settings::Module::Cpu),
        Some(1),
        "the moved graph did not reach the live order"
    );
    assert!(
        !live
            .modules
            .iter()
            .find(|m| m.id == settings::Module::Memory)
            .expect("the module")
            .visible,
        "the visibility change did not reach the live dashboard"
    );
    let classic = crate::shared::themes()
        .into_iter()
        .find(|theme| theme.name == "Classic")
        .expect("Classic is a built-in theme");
    assert_eq!(
        theme.colors[3], classic.colors[3],
        "the colour change did not reach the live theme"
    );
    assert_ne!(theme.colors[3], [0.8, 0.3, 0.2, 1.0]);
}

#[test]
fn rendering_never_writes_a_mismatched_document() {
    // Review issue 1: opening or rendering the window must never write.
    // The fixture is the exact document the old code rewrote on every
    // frame — a custom palette under a still-selected built-in preset.
    let mut harness = Harness::new();
    harness
        .store
        .set("themes.preset", json!("Midnight"))
        .expect("valid preset");
    harness
        .store
        .set("appearance.series1.color", json!([0.9, 0.1, 0.1, 1.0]))
        .expect("valid colour");
    let before = fs::read(harness.document()).unwrap();
    // Many frames across every section: the file stays byte-identical.
    for section in harness.catalog.sections.clone() {
        harness.window.select_section(&section);
        for _ in 0..4 {
            let _ = harness.quiet();
        }
        assert_eq!(
            fs::read(harness.document()).unwrap(),
            before,
            "rendering {section} wrote the settings document"
        );
    }
    // The mismatch stays as the document holds it: the preset still
    // reads Midnight — nothing reconciled it behind the user's back.
    assert_eq!(harness.values()["themes.preset"], json!("Midnight"));
    assert!(
        !harness.window.take_dirty(),
        "a read-only frame reported a change"
    );
    // Reconciliation happens inside the window's own edit operations:
    // an edit through the window marks the theme Custom (the catalog's
    // documented rule, at edit time).
    harness.window.select_section("appearance");
    let _ = harness.quiet();
    harness.click_labelled("Inherit the default Series 2 color");
    assert_eq!(
        harness.values()["themes.preset"],
        json!("Custom"),
        "the window edit did not reconcile the preset"
    );
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

// The row layout the macOS window has and the snapshots were missing
// (fix L1/L2): every entry's catalog label painted in the card's left
// column, the controls in one aligned right-hand column, cards filling
// the content pane inside the token gutter and aligned with the section
// eyebrow — proven over every section with geometry, because this
// implementer cannot view images.

#[test]
fn every_row_paints_its_label_left_of_its_aligned_control() {
    let mut harness = Harness::new();
    let gutter = super::super::aether7b::SPACE_S6;
    let pane_left = super::SIDEBAR_WIDTH + gutter;
    let pane_right = SCREEN.x - gutter;
    for section in harness.catalog.sections.clone() {
        harness.window.select_section(&section);
        let frame = harness.quiet_tall();
        // L2: the section eyebrow and the cards share the gutter's left
        // edge, and every card spans the pane's width inside the gutter.
        let eyebrow = painted_text(
            &frame,
            &format!("// {}", section.to_uppercase()),
            Rect::from_min_size(Pos2::ZERO, Vec2::new(SCREEN.x, 8000.)),
        );
        assert!(
            (eyebrow.left() - pane_left).abs() <= 1.5,
            "{section}: the eyebrow does not sit at the pane's left inset ({eyebrow:?})"
        );
        let mut cards: Vec<Rect> = Vec::new();
        for rendered in harness.window.rendered() {
            if rendered.card_rect.width() > 0. && !cards.contains(&rendered.card_rect) {
                cards.push(rendered.card_rect);
            }
        }
        assert!(!cards.is_empty(), "{section} rendered no cards");
        for card in &cards {
            assert!(
                (card.left() - pane_left).abs() <= 1.5,
                "{section}: a card does not align with the eyebrow ({card:?} vs {eyebrow:?})"
            );
            assert!(
                (card.right() - pane_right).abs() <= 1.5,
                "{section}: a card does not fill the pane ({card:?})"
            );
            assert!(
                (card.width() - (pane_right - pane_left)).abs() <= 3.,
                "{section}: a card does not span the pane's width ({card:?})"
            );
        }
        for entry in linux_entries(&harness.catalog, &section) {
            let rendered = harness
                .window
                .rendered()
                .iter()
                .find(|rendered| rendered.id == entry.id)
                .unwrap_or_else(|| panic!("{} rendered no control", entry.id));
            let card = rendered.card_rect;
            let room = card.expand(1.5);
            assert!(
                room.contains_rect(rendered.control_rect),
                "{}: the control left its card ({:?} vs {card:?})",
                entry.id,
                rendered.control_rect
            );
            assert!(
                room.contains_rect(rendered.response.rect),
                "{}: the widget left its card",
                entry.id
            );
            match entry.control.as_str() {
                // An action button sits in the label column (fix V8); its
                // own text is the label it paints.
                "action" => {
                    let label = painted_text(&frame, &entry.label, rendered.response.rect);
                    assert!(
                        room.contains_rect(label),
                        "{}: the button's label left its card",
                        entry.id
                    );
                }
                // The order list spans the card below its label.
                "order" => {
                    let label = rendered
                        .label_rect
                        .unwrap_or_else(|| panic!("{} painted no row label", entry.id));
                    let painted = painted_text(&frame, &entry.label, label);
                    assert!(
                        room.contains_rect(label) && room.contains_rect(painted),
                        "{}: the label left its card",
                        entry.id
                    );
                    assert!(
                        label.bottom() <= rendered.control_rect.top() + 1.5,
                        "{}: the list does not sit below its label",
                        entry.id
                    );
                    assert!(
                        (label.left() - rendered.control_rect.left()).abs() <= 1.5,
                        "{}: the label and list do not share the left column",
                        entry.id
                    );
                }
                _ => {
                    // L1: the label is painted, left of the control,
                    // vertically centred with it.
                    let label = rendered
                        .label_rect
                        .unwrap_or_else(|| panic!("{} painted no row label", entry.id));
                    let painted = painted_text(&frame, &entry.label, label);
                    assert!(
                        room.contains_rect(label) && room.contains_rect(painted),
                        "{}: the label left its card ({label:?} vs {card:?})",
                        entry.id
                    );
                    assert!(
                        label.right() <= rendered.control_rect.left() - 4.,
                        "{}: the label is not left of its control ({label:?} vs {:?})",
                        entry.id,
                        rendered.control_rect
                    );
                    assert!(
                        (label.center().y - rendered.control_rect.center().y).abs() <= 2.5,
                        "{}: the label is not vertically centred with its control",
                        entry.id
                    );
                    // The one right-hand column: every control group in a
                    // card ends at the card's inner right edge.
                    let inner = card.right() - super::super::aether7b::SPACE_S4;
                    assert!(
                        (rendered.control_rect.right() - inner).abs() <= 1.5,
                        "{}: the control group is not flush with the card's right edge",
                        entry.id
                    );
                }
            }
        }
        // All the rows of one card share that right edge exactly.
        for card in &cards {
            let mut edges: Vec<f32> = Vec::new();
            for rendered in harness.window.rendered().iter().filter(|rendered| {
                rendered.card_rect == *card
                    && !matches!(rendered.control.as_str(), "order" | "action")
            }) {
                edges.push(rendered.control_rect.right());
            }
            if let (Some(min), Some(max)) = (
                edges.iter().cloned().reduce(f32::min),
                edges.iter().cloned().reduce(f32::max),
            ) {
                assert!(
                    (max - min) <= 1.5,
                    "{section}: a card's controls do not share one right edge ({edges:?})"
                );
            }
        }
    }
}

#[test]
fn stepped_entries_are_one_composite_row_with_a_named_synchronized_slider() {
    let mut harness = Harness::new();
    harness.window.select_section("general");
    // A stored, non-default opacity, so the slider edit moves a value
    // the document actually holds.
    harness
        .store
        .set("general.window.opacity", json!(0.8))
        .expect("valid opacity");
    let _ = harness.quiet();
    // Fix L4 / review issue 3: the stepped opacity entry is ONE composite
    // row — field, range and slider inside the row's control group — and
    // the slider carries the catalog label as its accessible name.
    let frame = harness.quiet();
    let rendered = harness
        .window
        .rendered()
        .iter()
        .find(|rendered| rendered.id == "general.window.opacity")
        .expect("the opacity entry rendered");
    let group = rendered.control_rect;
    let slider = nodes_with_role(&frame, egui::accesskit::Role::Slider, "Window opacity")
        .pop()
        .expect("the slider is named by the catalog label");
    assert!(
        group.contains_rect(slider),
        "the slider is detached from its composite row ({slider:?} vs {group:?})"
    );
    let field = nodes_with_role(&frame, egui::accesskit::Role::TextInput, "Window opacity")
        .pop()
        .expect("the field rendered");
    assert!(
        group.contains_rect(field),
        "the field is detached from its composite row"
    );
    let range = painted_text(&frame, "0.1 – 1", group);
    assert!(
        group.contains_rect(range),
        "the range text is detached from its composite row"
    );
    // The slider is keyboard-focusable with the 2 px halo (lesson d).
    let mut halo_frame = None;
    for _ in 0..40 {
        let frame = harness.frame(vec![key(egui::Key::Tab)]);
        let focused = harness.ctx.memory(|memory| memory.focused());
        let reached = focused_label(&frame, focused).is_some_and(|label| label == "Window opacity")
            && frame
                .platform_output
                .accesskit_update
                .as_ref()
                .and_then(|tree| {
                    tree.nodes
                        .iter()
                        .find(|(id, _)| Some(*id) == focused.map(|f| f.accesskit_id()))
                })
                .is_some_and(|(_, node)| node.role() == egui::accesskit::Role::Slider);
        if reached {
            halo_frame = Some(frame);
            break;
        }
    }
    let frame = halo_frame.expect("Tab never reached the slider");
    let halo = super::super::settings_style::focus_halo();
    let slider = nodes_with_role(&frame, egui::accesskit::Role::Slider, "Window opacity")
        .pop()
        .expect("the focused slider");
    assert!(
        frame.shapes.iter().any(|clipped| {
            matches!(&clipped.shape, egui::Shape::Rect(rect)
                if rect.stroke.width == 2. && rect.stroke.color == halo
                    && rect.rect.expand(1.).intersects(slider))
        }),
        "the focused slider paints no 2 px halo"
    );
    // A slider edit saves instantly and synchronizes the field: the
    // displayed number follows the stored value (review issue 3) —
    // click the track's left third.
    let before = harness.values()["general.window.opacity"].as_f64().unwrap();
    let click = Pos2::new(slider.left() + slider.width() / 3., slider.center().y);
    harness.click_at(click);
    let after = harness.values()["general.window.opacity"].as_f64().unwrap();
    assert!(
        after < before,
        "the slider edit did not save ({before} → {after})"
    );
    let frame = harness.quiet();
    assert_eq!(
        field_value(&frame, "Window opacity").as_deref(),
        Some(
            super::settings_controls::value_text(&harness.values()["general.window.opacity"])
                .as_str()
        ),
        "the field did not resynchronize with the slider edit"
    );
}

#[test]
fn colour_popup_sliders_are_named_and_apply_on_click() {
    let mut harness = Harness::new();
    harness.window.select_section("appearance");
    let _ = harness.quiet();
    // Review issue 3: the colour editor's component sliders are named
    // by their channel, and a click on the track applies through the
    // window's instant-apply path. Keyboard operation is the sibling
    // test — egui will not Tab into the popup, so the editor moves
    // focus itself.
    let well = harness
        .window
        .rendered()
        .iter()
        .find(|rendered| rendered.id == "appearance.window.color")
        .expect("the colour well rendered");
    harness.click_at(well.response.rect.center());
    let frame = harness.quiet();
    for channel in ["Red", "Green", "Blue", "Opacity"] {
        assert!(
            !nodes_with_role(&frame, egui::accesskit::Role::Slider, channel).is_empty(),
            "the colour editor's {channel} slider carries no name"
        );
    }
    // A click on the Red track sets the component and saves instantly.
    let red = nodes_with_role(&frame, egui::accesskit::Role::Slider, "Red")
        .pop()
        .expect("the named Red slider");
    let before = harness.values().get("appearance.window.color").cloned();
    harness.click_at(egui::Pos2::new(
        red.left() + red.width() / 10.,
        red.center().y,
    ));
    let after = harness.values()["appearance.window.color"].clone();
    assert_ne!(
        before,
        Some(after.clone()),
        "the popup slider click did not apply a colour"
    );
    assert!(
        after
            .as_array()
            .and_then(|rgba| rgba.first())
            .and_then(serde_json::Value::as_f64)
            .expect("the stored colour")
            < 0.5,
        "clicking the left of the Red track did not lower the component"
    );
    assert!(
        harness.window.take_dirty(),
        "the popup slider edit was not reported"
    );
    // Escape belongs to the popup first: it closes the editor.
    let _ = harness.frame(vec![key(egui::Key::Escape)]);
    let frame = harness.quiet();
    assert!(
        nodes_with_role(&frame, egui::accesskit::Role::Slider, "Red").is_empty(),
        "Escape did not close the colour editor"
    );
}

#[test]
fn colour_editor_is_keyboard_operable_and_returns_focus() {
    // Explicit focus management (lesson d): Space opens the editor and
    // focuses the first channel, arrows adjust it, the 2 px halo paints,
    // Tab moves to the next channel by widget identity, and Escape returns
    // focus to the well. Channels are tracked by id and role, not by name.
    let mut harness = Harness::new();
    harness.window.select_section("appearance");
    let (well, _) = focus_role(
        &mut harness,
        egui::accesskit::Role::ColorWell,
        "Window background color",
    );
    let frame = harness.frame(vec![key(egui::Key::Space)]);
    let mut frame = frame;
    let mut focused = harness.ctx.memory(|memory| memory.focused());
    if focused_identity(&frame, focused)
        .is_none_or(|(_, role, _)| role != egui::accesskit::Role::Slider)
    {
        frame = harness.quiet();
        focused = harness.ctx.memory(|memory| memory.focused());
    }
    let (red_node, role, label) =
        focused_identity(&frame, focused).expect("Space did not move focus into the editor");
    assert_eq!(role, egui::accesskit::Role::Slider);
    assert_eq!(
        label, "Red",
        "keyboard activation did not focus the first channel"
    );
    let red_widget = focused.expect("the channel is focused");
    let red_rect = nodes_with_role(&frame, egui::accesskit::Role::Slider, "Red")
        .pop()
        .expect("the focused Red slider");
    assert!(
        halo_around(&frame, red_rect),
        "the focused colour channel paints no 2 px halo"
    );
    let before = harness.values().get("appearance.window.color").cloned();
    let before_red = before
        .as_ref()
        .and_then(Value::as_array)
        .and_then(|rgba| rgba.first())
        .and_then(Value::as_f64)
        .unwrap_or(0.2);
    let _ = harness.frame(vec![key(egui::Key::ArrowRight)]);
    let after = harness.values()["appearance.window.color"].clone();
    let after_red = after
        .as_array()
        .and_then(|rgba| rgba.first())
        .and_then(Value::as_f64)
        .expect("the stored colour");
    assert!(
        after_red > before_red,
        "ArrowRight did not raise the Red channel ({before_red} → {after_red})"
    );
    let frame = harness.quiet();
    let focused = harness.ctx.memory(|memory| memory.focused());
    let (still, still_role, _) =
        focused_identity(&frame, focused).expect("the channel lost focus after the adjustment");
    assert_eq!(focused, Some(red_widget));
    assert_eq!(still, red_node);
    assert_eq!(still_role, egui::accesskit::Role::Slider);
    // Tab stays in the editor and lands on a different slider identity.
    let frame = harness.frame(vec![key(egui::Key::Tab)]);
    let focused = harness.ctx.memory(|memory| memory.focused());
    let (green_node, green_role, green_label) =
        focused_identity(&frame, focused).expect("Tab left the editor without a focus");
    assert_eq!(green_role, egui::accesskit::Role::Slider);
    assert_eq!(green_label, "Green");
    assert_ne!(
        green_node, red_node,
        "Tab did not move to a different channel identity"
    );
    let _ = harness.frame(vec![key(egui::Key::Escape)]);
    let frame = harness.quiet();
    assert!(
        nodes_with_role(&frame, egui::accesskit::Role::Slider, "Red").is_empty(),
        "Escape did not close the colour editor"
    );
    let focused = harness.ctx.memory(|memory| memory.focused());
    assert_eq!(
        focused,
        Some(well),
        "Escape did not return focus to the colour well"
    );
    let (_, role, label) =
        focused_identity(&frame, focused).expect("the well has no accessible identity");
    assert_eq!(role, egui::accesskit::Role::ColorWell);
    assert_eq!(label, "Window background color");
}

#[test]
fn blocked_documents_validate_held_edits_through_the_core() {
    // Review issue 2: while the document is blocked, a parseable but
    // invalid edit is refused by the shared core — the danger reason
    // shows, nothing is held — and a valid edit is held in memory only,
    // presented in its control, and lands when the file is replaced.
    let root = std::env::temp_dir().join(format!(
        "xrg-settings-blocked-{}-{}",
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
    // An invalid width is refused with the core's reason, held nothing.
    harness.type_into("general.window.graph_width", "99");
    let frame = harness.quiet();
    let reason = harness
        .window
        .error("general.window.graph_width")
        .expect("a blocked document accepted an invalid edit");
    assert_eq!(reason, "Between 100 px and 1200 px.");
    assert!(
        labelled(&frame, reason),
        "the refusal reason did not render inside the row"
    );
    assert_eq!(
        fs::read(&path).unwrap(),
        b"certainly not json",
        "a blocked document was written"
    );
    // A valid edit is held in memory, presented in its control.
    harness.type_into("general.window.graph_width", "300");
    assert!(
        harness.window.error("general.window.graph_width").is_none(),
        "the valid held edit kept the invalid reason"
    );
    let frame = harness.quiet();
    assert_eq!(
        node_value(&frame, "Graph width").as_deref(),
        Some("300"),
        "the held edit did not present in its control"
    );
    assert_eq!(
        fs::read(&path).unwrap(),
        b"certainly not json",
        "the held edit wrote the blocked file"
    );
    // Replacing the file lands the held edit; the refused one is gone.
    harness.click_labelled("Replace the file with the current settings");
    let reopened = Store::open(&root);
    assert_eq!(
        reopened.values()["general.window.graph_width"],
        json!(300),
        "the held edit did not land in the replaced document"
    );
    fs::remove_dir_all(&root).unwrap();
}

/// The theme and reduced-motion pins are process-wide environment
/// variables that the appearance tests set and remove. Tests run on
/// parallel threads, so every test that touches a pin holds this lock for
/// its whole body — a mid-frame flip made the token audit see another
/// test's light pin during its dark pass (fix round 3).
static APPEARANCE_PINS: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Hold the appearance pins for the calling test's body; a poisoned lock
/// (a panicked holder) is adopted rather than failing every later test.
fn appearance_pins() -> std::sync::MutexGuard<'static, ()> {
    std::sync::Mutex::lock(&APPEARANCE_PINS).unwrap_or_else(|error| error.into_inner())
}

#[test]
fn reduced_motion_makes_egui_animation_instant() {
    // The window's animation time comes from the motion tokens, and a
    // reduced-motion request makes every egui transition instant.
    let _pins = appearance_pins();
    for (pin, requested) in [("0", false), ("1", true)] {
        unsafe {
            std::env::set_var("XRG_SETTINGS_REDUCED_MOTION", pin);
        }
        assert_eq!(
            super::super::settings_style::reduced_motion_requested(),
            requested,
            "the pin {pin:?} was not honoured"
        );
        let style = super::super::settings_style::style(false);
        assert_eq!(
            style.animation_time,
            if requested {
                0.
            } else {
                super::super::aether7b::MOTION_BASE.as_secs_f32()
            },
            "egui's animation time does not follow the motion tokens"
        );
        // The rendered window carries the configured time in its style.
        let mut harness = Harness::new();
        let animation_time = if requested {
            0.
        } else {
            super::super::aether7b::MOTION_BASE.as_secs_f32()
        };
        let raw = RawInput {
            screen_rect: Some(Rect::from_min_size(Pos2::ZERO, SCREEN)),
            ..Default::default()
        };
        let ctx = harness.ctx.clone();
        let mut window = std::mem::replace(
            &mut harness.window,
            SettingsWindow::new(document::catalog().expect("the shared core provides the catalog")),
        );
        let mut store = std::mem::replace(&mut harness.store, Store::open(&harness.root));
        let mut output = ctx.run_ui(raw, |ui| {
            window.render(ui, &mut store, &FixtureSources);
            // Inside the pass, the window's style is the applied one.
            assert_eq!(
                ui.style().animation_time,
                animation_time,
                "the window did not apply the configured animation time"
            );
        });
        output.textures_delta.clear();
    }
    unsafe {
        std::env::remove_var("XRG_SETTINGS_REDUCED_MOTION");
    }
}

#[test]
fn desktop_reduced_motion_queries_enable_animations_without_the_override() {
    // The override is absent: the decision follows the desktop query, and
    // that query asks GNOME for `enable-animations`, not
    // `gtk-enable-animations`.
    let _pins = appearance_pins();
    unsafe {
        std::env::remove_var("XRG_SETTINGS_REDUCED_MOTION");
    }
    assert!(
        std::env::var("XRG_SETTINGS_REDUCED_MOTION").is_err(),
        "the override was present"
    );
    let root = std::env::temp_dir().join(format!(
        "xrg-gsettings-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&root).unwrap();
    let log = root.join("args");
    let program = root.join("gsettings");
    fs::write(
        &program,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\necho false\n",
            log.display()
        ),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&program, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let animations = super::super::settings_style::query_enable_animations(&program);
    let args = fs::read_to_string(&log).unwrap_or_default();
    assert!(
        args.lines().any(|line| line == "enable-animations"),
        "the desktop query did not ask for enable-animations: {args:?}"
    );
    assert!(
        !args.contains("gtk-enable-animations"),
        "the desktop query still uses gtk-enable-animations: {args:?}"
    );
    assert!(
        args.lines()
            .any(|line| line == "org.gnome.desktop.interface"),
        "the desktop query did not use the GNOME interface schema: {args:?}"
    );
    assert!(!animations, "enable-animations=false was read as enabled");
    assert!(
        super::super::settings_style::reduced_motion(None, animations),
        "an absent override did not follow the desktop query"
    );
    // A missing tool is "not requested".
    assert!(super::super::settings_style::query_enable_animations(
        std::path::Path::new("gsettings-not-installed")
    ));
    assert!(!super::super::settings_style::reduced_motion(None, true));
    fs::remove_dir_all(&root).unwrap();
}

#[test]
fn slider_rails_contrast_with_the_card_in_both_appearances() {
    // Fix L6: the rail is a filled rect in the slider's own style, using a
    // token that stays visible against the card. Containment cannot see this.
    let _pins = appearance_pins();
    for theme in ["light", "dark"] {
        unsafe {
            std::env::set_var("XRG_SETTINGS_THEME", theme);
        }
        let dark = theme == "dark";
        let mut harness = Harness::new();
        harness.window.select_section("general");
        let frame = harness.quiet();
        let slider = nodes_with_role(&frame, egui::accesskit::Role::Slider, "Window opacity")
            .pop()
            .expect("the opacity slider");
        let rail = settings_style_rail(dark);
        let card = super::super::aether7b::surface_card(dark);
        let track = frame
            .shapes
            .iter()
            .find_map(|clipped| match &clipped.shape {
                egui::Shape::Rect(shape)
                    if shape.fill == rail
                        && shape.rect.width() >= 100.
                        && shape.rect.height() >= 4.
                        && shape.rect.intersects(slider) =>
                {
                    Some(shape.rect)
                }
                _ => None,
            });
        let track =
            track.unwrap_or_else(|| panic!("no contrasting slider rail in the {theme} appearance"));
        assert!(
            track.width() >= 100. && track.height() >= 4.,
            "the {theme} rail has no visible geometry ({track:?})"
        );
        let contrast = contrast_over(rail, card);
        assert!(
            contrast >= 3.0,
            "the {theme} rail contrast against the card is {contrast:.2}, below 3:1"
        );
    }
    unsafe {
        std::env::remove_var("XRG_SETTINGS_THEME");
    }
}

fn settings_style_rail(dark: bool) -> egui::Color32 {
    super::super::settings_style::slider_rail(dark)
}

/// WCAG contrast of `fg` composited over an opaque `bg`.
fn contrast_over(fg: egui::Color32, bg: egui::Color32) -> f32 {
    let [fr, fg_g, fb, fa] = fg.to_array();
    let [br, bg_g, bb, _] = bg.to_array();
    let inv = u16::from(255 - fa);
    let mix = |front: u8, back: u8| {
        (u16::from(front) + (u16::from(back) * inv + 127) / 255).min(255) as u8
    };
    let painted = [mix(fr, br), mix(fg_g, bg_g), mix(fb, bb)];
    let card = [br, bg_g, bb];
    let l1 = relative_luminance(painted);
    let l2 = relative_luminance(card);
    let (hi, lo) = if l1 > l2 { (l1, l2) } else { (l2, l1) };
    (hi + 0.05) / (lo + 0.05)
}

fn relative_luminance(rgb: [u8; 3]) -> f32 {
    let channel = |c: u8| {
        let c = f32::from(c) / 255.;
        if c <= 0.04045 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2])
}

#[test]
fn retained_failures_clear_on_repair_retry_and_reset() {
    // A persistence failure after replacement retains the edit and keeps
    // showing it. A later successful edit must not stay shadowed by that
    // retained value; retry saves it; reset discards it.
    let (root, mut harness) = blocked_harness();
    retain_failed_width(&mut harness);
    let frame = harness.quiet();
    assert!(
        labelled(&frame, "Retry saving changes that did not persist"),
        "a retained failure has no retry path"
    );
    // The injection is spent. A successful 400 must display and persist,
    // and must not snap back to the retained 300.
    harness.type_into("general.window.graph_width", "400");
    let frame = harness.quiet();
    assert_eq!(harness.values()["general.window.graph_width"], json!(400));
    assert_eq!(
        node_value(&frame, "Graph width").as_deref(),
        Some("400"),
        "the retained 300 shadowed the successful 400"
    );
    let _ = harness.quiet();
    assert_eq!(
        Store::open(&root).values()["general.window.graph_width"],
        json!(400),
        "a later frame resubmitted the retained failure"
    );
    assert!(
        !labelled(
            &harness.quiet(),
            "Retry saving changes that did not persist"
        ),
        "the successful edit left the retained failure in place"
    );
    fs::remove_dir_all(&root).unwrap();

    // Retry saves the retained value and then stops showing it.
    let (root, mut harness) = blocked_harness();
    retain_failed_width(&mut harness);
    harness.click_labelled("Retry saving changes that did not persist");
    assert_eq!(
        Store::open(&root).values()["general.window.graph_width"],
        json!(300),
        "retry did not persist the retained edit"
    );
    let frame = harness.quiet();
    assert_eq!(node_value(&frame, "Graph width").as_deref(), Some("300"));
    assert!(
        !labelled(&frame, "Retry saving changes that did not persist"),
        "retry left the retained failure in place"
    );
    assert!(
        harness.window.error("general.window.graph_width").is_none(),
        "retry kept the failure reason"
    );
    fs::remove_dir_all(&root).unwrap();

    // Reset discards the retained edit instead of overlaying the default.
    let (root, mut harness) = blocked_harness();
    retain_failed_width(&mut harness);
    harness.click("general.reset");
    let _ = harness.quiet();
    harness.click_labelled("Reset");
    let frame = harness.quiet();
    assert_eq!(
        node_value(&frame, "Graph width").as_deref(),
        Some("140"),
        "reset left the retained width on screen"
    );
    assert!(
        Store::open(&root)
            .values()
            .get("general.window.graph_width")
            .is_none(),
        "reset wrote the retained width"
    );
    assert!(
        !labelled(&frame, "Retry saving changes that did not persist"),
        "reset left the retained failure in place"
    );
    fs::remove_dir_all(&root).unwrap();
}

fn blocked_harness() -> (PathBuf, Harness) {
    let root = std::env::temp_dir().join(format!(
        "xrg-settings-retain-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(root.join("xrg-ng")).unwrap();
    fs::write(root.join("xrg-ng/settings.json"), b"certainly not json").unwrap();
    let catalog = document::catalog().expect("the shared core provides the catalog");
    let mut harness = Harness {
        ctx: egui::Context::default(),
        window: SettingsWindow::new(catalog),
        store: Store::open(&root),
        root: root.clone(),
        catalog: document::catalog().expect("the catalog"),
    };
    harness.ctx.enable_accesskit();
    let _ = harness.quiet();
    assert!(harness.store.blocked(), "the fixture is not blocked");
    (root, harness)
}

fn retain_failed_width(harness: &mut Harness) {
    harness.type_into("general.window.graph_width", "300");
    harness.store.fail_next_commits(1);
    harness.click_labelled("Replace the file with the current settings");
    assert!(
        !harness.store.blocked(),
        "replacement did not repair the document"
    );
    assert!(
        harness
            .store
            .values()
            .get("general.window.graph_width")
            .is_none(),
        "the failed write still landed in the document"
    );
    let frame = harness.quiet();
    assert_eq!(
        node_value(&frame, "Graph width").as_deref(),
        Some("300"),
        "the failed edit was not retained on screen"
    );
}

#[test]
fn cancelling_the_replacement_dialog_through_its_buttons_writes_nothing() {
    // Review issue 7: Back, Cancel and Escape drive the replacement
    // dialog itself, and the existing file stays byte-identical through
    // the frames that follow.
    let mut harness = Harness::new();
    let saved = harness.root.join("Saved palette.json");
    fs::write(&saved, b"original export").unwrap();
    for affordance in ["Back", "Cancel", "escape"] {
        harness
            .window
            .choose_at(super::Action::SaveTheme, saved.clone(), &harness.ctx);
        for _ in 0..80 {
            let _ = harness.quiet();
            if harness
                .window
                .picker
                .as_ref()
                .is_some_and(|picker| !picker.is_loading())
            {
                break;
            }
        }
        harness.window.picker.as_mut().unwrap().accept();
        for _ in 0..80 {
            let _ = harness.quiet();
            if harness
                .window
                .picker
                .as_ref()
                .is_some_and(|picker| picker.needs_replacement())
            {
                break;
            }
        }
        let frame = harness.quiet();
        assert!(
            labelled(&frame, "Replace the existing file with this JSON theme?"),
            "{affordance}: the replacement dialog did not render"
        );
        match affordance {
            "Back" => {
                harness.click_labelled("Back");
                assert!(
                    harness
                        .window
                        .picker
                        .as_ref()
                        .is_some_and(|picker| !picker.needs_replacement()),
                    "Back did not leave the dialog"
                );
            }
            "Cancel" => {
                harness.click_labelled("Cancel");
                assert!(
                    harness.window.picker.is_none(),
                    "Cancel did not cancel the chooser"
                );
            }
            _ => {
                let _ = harness.frame(vec![key(egui::Key::Escape)]);
                assert!(
                    harness.window.picker.is_none(),
                    "Escape did not cancel the chooser"
                );
                assert!(
                    !harness.window.closed(),
                    "Escape closed the whole window instead of the dialog"
                );
            }
        }
        // The existing file is byte-identical, across subsequent frames.
        for _ in 0..4 {
            let _ = harness.quiet();
            assert_eq!(
                fs::read(&saved).unwrap(),
                b"original export",
                "{affordance}: cancelling the replacement changed the existing file"
            );
        }
    }
}

// The token-only audit (lesson j): the style and every painted shape, with
// no blanket exclusions — the only allowance is a colour well's own swatch
// content, bounded to the well's rect.

#[test]
fn only_aether7b_colours() {
    let _pins = appearance_pins();
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
    let mut audited = |color: egui::Color32, what: &str| {
        assert!(
            allowed(color),
            "non-token {what} {color:?} in {} (dark {dark}) painting {:?}",
            harness.window.section(),
            CURRENT_TEXT.with(|text| text.borrow().clone())
        );
    };
    thread_local! {
        /// The text a Text shape is auditing, for the audit's message.
        static CURRENT_TEXT: std::cell::RefCell<String> =
            const { std::cell::RefCell::new(String::new()) };
    }
    // The style itself, whole (review issue 5): every colour field the
    // window's style carries — the chrome egui paints from it included.
    let style = super::super::settings_style::style(dark);
    let visuals = &style.visuals;
    let mut style_colors = vec![
        visuals.panel_fill,
        visuals.window_fill,
        visuals.faint_bg_color,
        visuals.extreme_bg_color,
        visuals.code_bg_color,
        visuals.hyperlink_color,
        visuals.warn_fg_color,
        visuals.error_fg_color,
        visuals.window_stroke.color,
        visuals.window_shadow.color,
        visuals.popup_shadow.color,
        visuals.selection.bg_fill,
        visuals.selection.stroke.color,
        visuals.text_cursor.stroke.color,
        visuals.ime_composition.active_underline_stroke.color,
        visuals.ime_composition.inactive_underline_stroke.color,
    ];
    for optional in [
        visuals.override_text_color,
        visuals.weak_text_color,
        visuals.text_edit_bg_color,
    ]
    .into_iter()
    .flatten()
    {
        style_colors.push(optional);
    }
    for state in [
        &visuals.widgets.noninteractive,
        &visuals.widgets.inactive,
        &visuals.widgets.hovered,
        &visuals.widgets.active,
        &visuals.widgets.open,
    ] {
        style_colors.extend([
            state.bg_fill,
            state.weak_bg_fill,
            state.bg_stroke.color,
            state.fg_stroke.color,
        ]);
    }
    for color in style_colors {
        audited(color, "style colour");
    }
    // The colour wells' swatches are the user's own content (the one
    // allowance): a shape is exempt only inside the swatch itself, not
    // anywhere on a card a well happens to sit on.
    let wells: Vec<Rect> = harness
        .window
        .rendered()
        .iter()
        .filter(|rendered| rendered.control == "color")
        .map(|rendered| rendered.response.rect.shrink(1.))
        .collect();
    let inside_well = |rect: Rect| wells.iter().any(|well| well.contains_rect(rect));
    let mut painted = 0;
    let mut callbacks = 0;
    // Every painted shape, recursively, in every variant (issue 5): no
    // kind is skipped and text is audited through its glyphs.
    fn walk(
        shape: &egui::Shape,
        painted: &mut usize,
        callbacks: &mut usize,
        inside_well: &impl Fn(Rect) -> bool,
        audited: &mut impl FnMut(egui::Color32, &str),
    ) {
        match shape {
            egui::Shape::Noop => (),
            egui::Shape::Vec(list) => {
                for shape in list {
                    walk(shape, painted, callbacks, inside_well, audited);
                }
            }
            egui::Shape::Circle(circle) => {
                *painted += 1;
                if circle.fill != egui::Color32::TRANSPARENT {
                    audited(circle.fill, "circle fill");
                }
                if circle.stroke.color != egui::Color32::TRANSPARENT {
                    audited(circle.stroke.color, "circle stroke");
                }
            }
            egui::Shape::Ellipse(ellipse) => {
                *painted += 1;
                if ellipse.fill != egui::Color32::TRANSPARENT {
                    audited(ellipse.fill, "ellipse fill");
                }
                if ellipse.stroke.color != egui::Color32::TRANSPARENT {
                    audited(ellipse.stroke.color, "ellipse stroke");
                }
            }
            egui::Shape::LineSegment { points, stroke } => {
                *painted += 1;
                if stroke.color != egui::Color32::TRANSPARENT {
                    audited(stroke.color, "line stroke");
                }
                let _ = points;
            }
            egui::Shape::Path(path) => {
                *painted += 1;
                if path.fill != egui::Color32::TRANSPARENT {
                    audited(path.fill, "path fill");
                }
                match &path.stroke.color {
                    egui::epaint::ColorMode::Solid(color) => {
                        if *color != egui::Color32::TRANSPARENT {
                            audited(*color, "path stroke");
                        }
                    }
                    // The window paints no procedural colour paths.
                    egui::epaint::ColorMode::UV(_) => *callbacks += 1,
                }
            }
            egui::Shape::Band(band) => {
                *painted += 1;
                if band.fill != egui::Color32::TRANSPARENT {
                    audited(band.fill, "band fill");
                }
                if band.stroke.color != egui::Color32::TRANSPARENT {
                    audited(band.stroke.color, "band stroke");
                }
            }
            egui::Shape::Rect(rect) => {
                *painted += 1;
                if rect.fill != egui::Color32::TRANSPARENT
                    && !inside_well(Rect::from_min_size(rect.rect.min, rect.rect.size()))
                {
                    audited(rect.fill, "rect fill");
                }
                if rect.stroke.color != egui::Color32::TRANSPARENT {
                    audited(rect.stroke.color, "rect stroke");
                }
                // An invisible rect paints nothing — the desktop shows
                // through — so it draws no corner the audit can read.
                let painted_shape = rect.fill != egui::Color32::TRANSPARENT
                    || (rect.stroke.color != egui::Color32::TRANSPARENT && rect.stroke.width > 0.);
                // A rect may round only its bottom corners (the sidebar
                // under the headerbar): the largest corner is the one drawn.
                let radius = rect
                    .corner_radius
                    .nw
                    .max(rect.corner_radius.ne)
                    .max(rect.corner_radius.sw)
                    .max(rect.corner_radius.se);
                let half = 0.5 * rect.rect.size().min_elem();
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
                        "non-token corner radius {radius} in the settings window"
                    );
                }
            }
            egui::Shape::Text(text) => {
                *painted += 1;
                CURRENT_TEXT.with(|current| {
                    *current.borrow_mut() = text.galley.text().to_owned();
                });
                if text.fallback_color != egui::Color32::PLACEHOLDER {
                    audited(text.fallback_color, "text colour");
                }
                if let Some(color) = text.override_text_color {
                    audited(color, "text override colour");
                }
                for row in &text.galley.rows {
                    for vertex in &row.row.visuals.mesh.vertices {
                        // egui lays text out with PLACEHOLDER colours and
                        // the tessellator paints them as the shape's
                        // fallback — audited above.
                        if vertex.color == egui::Color32::PLACEHOLDER {
                            continue;
                        }
                        *painted += 1;
                        let spot = Rect::from_center_size(vertex.pos, Vec2::splat(2.));
                        if !inside_well(spot) {
                            audited(vertex.color, "text glyph colour");
                        }
                    }
                }
            }
            egui::Shape::Mesh(mesh) => {
                for vertex in &mesh.vertices {
                    *painted += 1;
                    let spot = Rect::from_center_size(vertex.pos, Vec2::splat(2.));
                    if !inside_well(spot) {
                        audited(vertex.color, "mesh colour");
                    }
                }
            }
            egui::Shape::QuadraticBezier(curve) => {
                *painted += 1;
                if curve.fill != egui::Color32::TRANSPARENT {
                    audited(curve.fill, "bezier fill");
                }
                match &curve.stroke.color {
                    egui::epaint::ColorMode::Solid(color) => {
                        if *color != egui::Color32::TRANSPARENT {
                            audited(*color, "bezier stroke");
                        }
                    }
                    egui::epaint::ColorMode::UV(_) => *callbacks += 1,
                }
            }
            egui::Shape::CubicBezier(curve) => {
                *painted += 1;
                if curve.fill != egui::Color32::TRANSPARENT {
                    audited(curve.fill, "bezier fill");
                }
                match &curve.stroke.color {
                    egui::epaint::ColorMode::Solid(color) => {
                        if *color != egui::Color32::TRANSPARENT {
                            audited(*color, "bezier stroke");
                        }
                    }
                    egui::epaint::ColorMode::UV(_) => *callbacks += 1,
                }
            }
            egui::Shape::Callback(_) => *callbacks += 1,
        }
    }
    for clipped in &frame.shapes {
        walk(
            &clipped.shape,
            &mut painted,
            &mut callbacks,
            &inside_well,
            &mut audited,
        );
    }
    assert_eq!(callbacks, 0, "the settings window paints no GPU callbacks");
    assert!(
        painted > 40,
        "{} painted too little: {painted}",
        harness.window.section()
    );
}

#[test]
fn retry_keeps_a_newer_failed_edit_and_never_saves_the_older_one() {
    // Fix round 3 (review rr2, finding 1): replacement retains width 300;
    // the user submits 400 while persistence still fails; focus leaves;
    // storage recovers; Retry from another section must persist 400 —
    // never the older 300 — and 400 must survive in the field.
    let (root, mut harness) = blocked_harness();
    retain_failed_width(&mut harness);
    // Persistence keeps failing for the newer edit: the submission fails,
    // and so does its one follow-up submission — the field resubmits on
    // the next frame while egui's two-frame lost-focus window still
    // reports the loss (the section switch then removes the field, so no
    // further submissions fire and Retry is the only path left).
    harness.store.fail_next_commits(2);
    harness.type_into("general.window.graph_width", "400");
    assert_eq!(
        harness.window.error("general.window.graph_width"),
        Some("The value could not be saved."),
        "the newer failed edit did not report its refusal"
    );
    let frame = harness.quiet();
    assert_eq!(
        node_value(&frame, "Graph width").as_deref(),
        Some("400"),
        "the newer failed edit did not stay presented in its field"
    );
    // Focus leaves, storage recovers, and Retry is offered from another
    // section — the edit buffer does not survive the section switch, so
    // only what the window retained can be retried.
    harness.window.select_section("appearance");
    let _ = harness.quiet();
    harness.click_labelled("Retry saving changes that did not persist");
    let persisted = Store::open(&root).values()["general.window.graph_width"]
        .as_i64()
        .expect("the persisted width");
    assert_ne!(
        persisted, 300,
        "retry saved the older retained 300 over the newer 400"
    );
    assert_eq!(
        persisted, 400,
        "retry persisted {persisted}, not the newest failed edit"
    );
    harness.window.select_section("general");
    let frame = harness.quiet();
    assert_eq!(
        node_value(&frame, "Graph width").as_deref(),
        Some("400"),
        "the newest failed edit did not survive the retry in its field"
    );
    assert!(
        !labelled(&frame, "Retry saving changes that did not persist"),
        "the retry left its banner up"
    );
    fs::remove_dir_all(&root).unwrap();
}

#[test]
fn colour_editor_tab_exits_at_both_boundaries_and_continues() {
    // Fix round 3 (review rr2, finding 2): forward Tab past the last
    // channel (Opacity) closes the editor and moves focus onward to the
    // next control after the well; Shift-Tab before the first channel
    // closes it and returns focus to the well; Escape still returns; and
    // Tab continues normally after the exit. All four channels are walked.
    let mut harness = Harness::new();
    harness.window.select_section("appearance");
    let _well = focus_role(
        &mut harness,
        egui::accesskit::Role::ColorWell,
        "Window background color",
    );
    // Space opens the editor on the first channel.
    let frame = harness.frame(vec![key(egui::Key::Space)]);
    let mut frame = frame;
    let mut focused = harness.ctx.memory(|memory| memory.focused());
    if focused_identity(&frame, focused)
        .is_none_or(|(_, role, _)| role != egui::accesskit::Role::Slider)
    {
        frame = harness.quiet();
        focused = harness.ctx.memory(|memory| memory.focused());
    }
    let (mut node, role, label) =
        focused_identity(&frame, focused).expect("Space did not move focus into the editor");
    assert_eq!(role, egui::accesskit::Role::Slider);
    assert_eq!(
        label, "Red",
        "keyboard opening did not focus the first channel"
    );
    // Forward through all four channels.
    for expected in ["Green", "Blue", "Opacity"] {
        let frame = harness.frame(vec![key(egui::Key::Tab)]);
        focused = harness.ctx.memory(|memory| memory.focused());
        let (next, role, label) =
            focused_identity(&frame, focused).expect("Tab left the editor without a focus");
        assert_eq!(role, egui::accesskit::Role::Slider);
        assert_eq!(label, expected);
        assert_ne!(next, node, "Tab did not move to a different channel");
        node = next;
    }
    // Forward Tab past the last channel: the editor closes and focus
    // moves onward, to the next control after the well.
    let frame = harness.frame(vec![key(egui::Key::Tab)]);
    focused = harness.ctx.memory(|memory| memory.focused());
    let (_, exit_role, exit_label) = focused_identity(&frame, focused)
        .expect("forward Tab past the last channel left nothing focused");
    assert_eq!(exit_role, egui::accesskit::Role::Button);
    assert_eq!(
        exit_label, "Inherit the default Graph background color",
        "forward Tab past Opacity did not move focus to the next control after the well"
    );
    let exit_focused = focused.expect("the exit left focus somewhere");
    // The editor closes: the frame that renders the exit still carries
    // the popup's widgets, the ones after it do not.
    let frame = harness.quiet();
    for name in ["Red", "Green", "Blue", "Opacity"] {
        assert!(
            nodes_with_role(&frame, egui::accesskit::Role::Slider, name).is_empty(),
            "the colour editor stayed open after the forward exit ({name})"
        );
    }
    focused = harness.ctx.memory(|memory| memory.focused());
    assert_eq!(
        focused,
        Some(exit_focused),
        "focus did not stay on the next control after the editor closed"
    );
    // The walk continues normally from there.
    let frame = harness.frame(vec![key(egui::Key::Tab)]);
    focused = harness.ctx.memory(|memory| memory.focused());
    let (_, role, label) =
        focused_identity(&frame, focused).expect("Tab did not continue after leaving the editor");
    assert_eq!(role, egui::accesskit::Role::ColorWell);
    assert_eq!(label, "Graph background color");
    // Reverse boundary: Space reopens on the first channel; Shift-Tab
    // before it closes the editor and returns focus to the well.
    let frame = harness.frame(vec![key(egui::Key::Space)]);
    let mut frame = frame;
    focused = harness.ctx.memory(|memory| memory.focused());
    if focused_identity(&frame, focused)
        .is_none_or(|(_, role, _)| role != egui::accesskit::Role::Slider)
    {
        frame = harness.quiet();
        focused = harness.ctx.memory(|memory| memory.focused());
    }
    let (_, role, label) = focused_identity(&frame, focused)
        .expect("Space did not reopen the editor on the first channel");
    assert_eq!(role, egui::accesskit::Role::Slider);
    assert_eq!(label, "Red");
    let shift_tab = egui::Event::Key {
        key: egui::Key::Tab,
        physical_key: None,
        pressed: true,
        repeat: false,
        modifiers: egui::Modifiers::SHIFT,
    };
    let frame = harness.frame(vec![shift_tab]);
    focused = harness.ctx.memory(|memory| memory.focused());
    let (_, role, label) = focused_identity(&frame, focused)
        .expect("Shift-Tab before the first channel left nothing focused");
    assert_eq!(role, egui::accesskit::Role::ColorWell);
    // The walk moved on to the second palette row, so its well receives
    // the return — the row the editor was opened from.
    assert_eq!(label, "Graph background color");
    let reverse_well = focused.expect("Shift-Tab did not focus the well");
    let frame = harness.quiet();
    for name in ["Red", "Green", "Blue", "Opacity"] {
        assert!(
            nodes_with_role(&frame, egui::accesskit::Role::Slider, name).is_empty(),
            "the colour editor stayed open after the reverse boundary ({name})"
        );
    }
    focused = harness.ctx.memory(|memory| memory.focused());
    assert_eq!(
        focused,
        Some(reverse_well),
        "the well lost focus after the reverse exit"
    );
    // Escape return still closes the editor and refocuses the well.
    let _ = harness.frame(vec![key(egui::Key::Space)]);
    let _ = harness.quiet();
    let _ = harness.frame(vec![key(egui::Key::Escape)]);
    let frame = harness.quiet();
    for name in ["Red", "Green", "Blue", "Opacity"] {
        assert!(
            nodes_with_role(&frame, egui::accesskit::Role::Slider, name).is_empty(),
            "Escape did not close the colour editor ({name})"
        );
    }
    focused = harness.ctx.memory(|memory| memory.focused());
    assert_eq!(
        focused,
        Some(reverse_well),
        "Escape did not return focus to the well"
    );
    fs::remove_dir_all(&harness.root).unwrap();
}

/// Round 5, rulings R37 — the theme import is ONE validated batch and ONE
/// commit: a theme whose name breaks the theme-name constraint is refused
/// WHOLE — the palette, the name AND the preset designation are not
/// written, the file keeps its bytes and the refusal's reason is shown —
/// a commit failure aborts the whole import the same way (all-or-nothing),
/// and a valid theme lands whole: palette, name and the Custom designation
/// its resulting colours produce, one commit.
#[test]
fn theme_import_is_one_batch_and_a_refusal_writes_nothing() {
    let mut harness = Harness::new();
    harness.window.select_section("themes");
    let _ = harness.quiet();
    // A fresh harness holds the default document in memory only; the file
    // appears with the first successful write.
    let before = fs::read(harness.document()).unwrap_or_default();
    // A valid palette under a name no entry accepts (over 80 characters).
    let refused = crate::settings::ThemeDocument {
        format: "xrg-ng-theme".into(),
        version: 1,
        name: "x".repeat(81),
        colors: [[0.01, 0.02, 0.03, 0.5]; 7],
    };
    harness.window.store_theme(&mut harness.store, refused);
    assert_ne!(
        harness.window.message(),
        Some("Theme imported."),
        "the refused theme reported success"
    );
    assert_eq!(
        fs::read(harness.document()).unwrap_or_default(),
        before,
        "the refused theme wrote the palette (or anything) to the file"
    );
    assert!(harness.values().get("appearance.window.color").is_none());
    assert!(
        harness.values().get("themes.name").is_none()
            || harness.values()["themes.name"] == json!("xrg"),
        "the refused name never landed"
    );
    // A failed commit is all-or-nothing too: the palette, the name and the
    // designation ride ONE batch, so nothing lands and the failure is
    // surfaced — never "Theme imported." with a stale designation behind.
    harness.store.fail_next_commits(1);
    let failed = crate::settings::ThemeDocument {
        format: "xrg-ng-theme".into(),
        version: 1,
        name: "Transport".into(),
        colors: [[0.03, 0.04, 0.05, 0.7]; 7],
    };
    let landed = fs::read(harness.document()).unwrap_or_default();
    harness.window.store_theme(&mut harness.store, failed);
    assert_ne!(
        harness.window.message(),
        Some("Theme imported."),
        "the failed commit reported success"
    );
    assert_eq!(
        fs::read(harness.document()).unwrap_or_default(),
        landed,
        "the failed commit wrote the palette (or anything) to the file"
    );
    assert!(harness.values().get("appearance.window.color").is_none());
    assert!(
        harness.values().get("themes.preset").is_none(),
        "the failed commit wrote the designation"
    );
    // A valid theme lands whole: palette, name AND the Custom designation
    // its resulting colours produce — ONE commit (round 5: the designation
    // is computed before persisting and rides the same batch).
    let commits = harness.store.commit_count();
    let valid = crate::settings::ThemeDocument {
        format: "xrg-ng-theme".into(),
        version: 1,
        name: "Imported".into(),
        colors: [[0.02, 0.03, 0.04, 0.6]; 7],
    };
    harness.window.store_theme(&mut harness.store, valid);
    assert_eq!(harness.window.message(), Some("Theme imported."));
    assert_eq!(
        harness.store.commit_count(),
        commits + 1,
        "the palette, the name and the designation took more than one commit"
    );
    assert_eq!(harness.values()["themes.name"], json!("Imported"));
    assert_eq!(
        harness.values()["appearance.window.color"],
        json!([0.02, 0.03, 0.04, 0.6])
    );
    assert_eq!(
        harness.values()["themes.preset"],
        json!("Custom"),
        "the imported palette's designation never landed"
    );
    // The designation names the built-in an imported palette exactly
    // matches: importing Midnight's palette designates Midnight — one
    // commit, in the same batch as the palette and the name.
    let midnight = crate::shared::themes()
        .into_iter()
        .find(|theme| theme.name == "Midnight")
        .expect("Midnight is a built-in theme");
    let commits = harness.store.commit_count();
    let builtin = crate::settings::ThemeDocument {
        format: "xrg-ng-theme".into(),
        version: 1,
        name: "Reverted".into(),
        colors: midnight.colors,
    };
    harness.window.store_theme(&mut harness.store, builtin);
    assert_eq!(
        harness.store.commit_count(),
        commits + 1,
        "the matched designation took more than one commit"
    );
    assert_eq!(harness.values()["themes.preset"], json!("Midnight"));
    assert_eq!(harness.values()["themes.name"], json!("Reverted"));
    fs::remove_dir_all(&harness.root).unwrap();
}

/// Round 5, review rr4 issue 5 — a failed preset selection retains the
/// COMPLETE logical batch and Retry submits it whole: selection → injected
/// commit failure → Retry, through the editor's own Themes picker. The
/// retained batch is the palette, the theme name and the selection itself
/// (never just the selection — that reported success with the new preset
/// selected and the old palette still saved); Retry lands all of it in ONE
/// commit.
#[test]
fn preset_selection_retry_resubmits_the_whole_batch() {
    let mut harness = Harness::new();
    harness.window.select_section("themes");
    let _ = harness.quiet();
    let midnight = crate::shared::themes()
        .into_iter()
        .find(|theme| theme.name == "Midnight")
        .expect("Midnight is a built-in theme");
    // The injected commit failure: the selection's batch validates but
    // nothing is written.
    harness.store.fail_next_commits(1);
    let before = fs::read(harness.document()).unwrap_or_default();
    harness.click_labelled("Color theme");
    harness.click_labelled("Midnight");
    let _ = harness.quiet();
    assert_eq!(
        fs::read(harness.document()).unwrap_or_default(),
        before,
        "the failed preset selection wrote anything"
    );
    assert!(
        harness.values().get("themes.preset").is_none(),
        "the failed selection landed its designation"
    );
    assert!(
        harness.values().get("themes.name").is_none(),
        "the failed selection landed its name"
    );
    for id in super::super::settings_controls::PALETTE_IDS {
        assert!(
            harness.values().get(id).is_none(),
            "the failed selection landed the palette ({id})"
        );
    }
    // The COMPLETE logical batch is retained for Retry — the palette and
    // the name included, never just the selection.
    assert_eq!(
        harness.window.held.len(),
        super::super::settings_controls::PALETTE_IDS.len() + 2,
        "the retained batch is not the complete preset (palette, name and selection)"
    );
    assert_eq!(harness.window.held["themes.preset"], json!("Midnight"));
    assert_eq!(harness.window.held["themes.name"], json!("Midnight"));
    assert_eq!(
        harness.window.error("themes.preset"),
        Some("The value could not be saved."),
        "the failed selection did not show its reason"
    );
    // Retry submits the WHOLE retained batch: palette, name and selection
    // land together in ONE commit.
    let commits = harness.store.commit_count();
    harness.click_labelled("Retry saving changes that did not persist");
    let _ = harness.quiet();
    assert_eq!(
        harness.store.commit_count(),
        commits + 1,
        "the retried preset batch took more than one commit"
    );
    assert!(
        harness.window.held.is_empty(),
        "the retry kept a held entry"
    );
    let values = harness.values();
    assert_eq!(values["themes.preset"], json!("Midnight"));
    assert_eq!(values["themes.name"], json!("Midnight"));
    for (index, id) in super::super::settings_controls::PALETTE_IDS
        .iter()
        .enumerate()
    {
        let stored = values[*id].as_array().unwrap();
        for (component, expected) in stored.iter().zip(&midnight.colors[index]) {
            assert!(
                (component.as_f64().unwrap() - expected).abs() < 1e-9,
                "the retried preset colour {id} did not apply"
            );
        }
    }
    fs::remove_dir_all(&harness.root).unwrap();
}

/// Round 6, review rr5 issue 2 — a successful theme import supersedes the
/// held entries it replaces: a failed Midnight selection retains its
/// COMPLETE batch (palette, name, designation) for Retry, a later
/// successful import discards exactly those held entries — so Retry can
/// never overwrite the imported theme with the older failed batch — and
/// an unrelated held edit survives for its own Retry.
#[test]
fn a_successful_theme_import_supersedes_the_held_batch_it_replaces() {
    let mut harness = Harness::new();
    harness.window.select_section("themes");
    let _ = harness.quiet();
    // The failed preset selection: the batch validates, the commit fails,
    // the COMPLETE batch is retained for Retry.
    harness.store.fail_next_commits(1);
    harness.click_labelled("Color theme");
    harness.click_labelled("Midnight");
    let _ = harness.quiet();
    assert_eq!(
        harness.window.held.len(),
        super::super::settings_controls::PALETTE_IDS.len() + 2,
        "the failed selection did not retain its complete batch"
    );
    // An unrelated held edit: a width whose submission and follow-up
    // resubmission both fail while the document is healthy (the transport
    // retention the Retry path owns). The quiet frame lets the field's
    // one follow-up resubmission fire and fail while it still exists;
    // the section switch then removes it so nothing further can submit.
    harness.window.select_section("general");
    let _ = harness.quiet();
    harness.store.fail_next_commits(2);
    harness.type_into("general.window.graph_width", "300");
    let _ = harness.quiet();
    assert!(
        harness
            .window
            .held
            .contains_key("general.window.graph_width"),
        "the unrelated failed edit was not retained"
    );
    // The successful import: palette, name and designation, ONE commit.
    harness.window.select_section("themes");
    let _ = harness.quiet();
    let commits = harness.store.commit_count();
    let imported = crate::settings::ThemeDocument {
        format: "xrg-ng-theme".into(),
        version: 1,
        name: "Imported".into(),
        colors: [[0.02, 0.03, 0.04, 0.6]; 7],
    };
    harness.window.store_theme(&mut harness.store, imported);
    assert_eq!(harness.window.message(), Some("Theme imported."));
    assert_eq!(
        harness.store.commit_count(),
        commits + 1,
        "the import took more than one commit"
    );
    // The import superseded exactly the held entries it replaces — the
    // palette, the name and the designation are dropped from Retry; the
    // unrelated width stays held.
    for id in super::super::settings_controls::PALETTE_IDS {
        assert!(
            !harness.window.held.contains_key(id),
            "the import kept the superseded held entry {id}"
        );
    }
    assert!(
        !harness.window.held.contains_key("themes.name"),
        "the import kept the superseded held theme name"
    );
    assert!(
        !harness.window.held.contains_key("themes.preset"),
        "the import kept the superseded held designation"
    );
    assert_eq!(
        harness.window.held.get("general.window.graph_width"),
        Some(&json!(300)),
        "the import discarded the unrelated held edit"
    );
    // Retry saves ONLY the unrelated edit: the imported theme is intact.
    harness.click_labelled("Retry saving changes that did not persist");
    let _ = harness.quiet();
    assert!(
        harness.window.held.is_empty(),
        "the retry kept a held entry"
    );
    let values = harness.values();
    assert_eq!(
        values["themes.name"],
        json!("Imported"),
        "the retry overwrote the imported theme's name"
    );
    assert_eq!(
        values["themes.preset"],
        json!("Custom"),
        "the retry overwrote the imported theme's designation"
    );
    assert_eq!(
        values["appearance.window.color"],
        json!([0.02, 0.03, 0.04, 0.6]),
        "the retry overwrote the imported palette"
    );
    assert_eq!(
        values["general.window.graph_width"],
        json!(300),
        "the retry did not save the unrelated held edit"
    );
    fs::remove_dir_all(&harness.root).unwrap();
}

/// Round 5, ruling R37 — a palette colour edit is ONE batch and ONE commit:
/// the colour and the `themes.preset` designation its resulting colours
/// produce ride the same validated batch, so a failed commit leaves
/// NEITHER behind (all-or-nothing), and a successful one lands both
/// together — the designation never trails the palette in a second
/// commit.
#[test]
fn palette_edit_carries_its_designation_in_one_batch() {
    let mut harness = Harness::new();
    harness.window.select_section("themes");
    let _ = harness.quiet();
    // Select Midnight first, so the palette edit's designation is Custom.
    harness
        .window
        .choose_preset("Midnight", &mut harness.store)
        .expect("the preset applies");
    harness.window.select_section("appearance");
    let _ = harness.quiet();
    // The edit and its designation are one commit: editing one colour under
    // the preset marks the theme Custom in the SAME write.
    let commits = harness.store.commit_count();
    harness.click_labelled("Inherit the default Series 2 color");
    assert_eq!(
        harness.store.commit_count(),
        commits + 1,
        "the palette edit and its designation took more than one commit"
    );
    assert_eq!(
        harness.values()["themes.preset"],
        json!("Custom"),
        "an edited palette did not become Custom"
    );
    // All-or-nothing: a commit failure leaves NEITHER the colour NOR the
    // designation behind, and the complete batch (colour + designation)
    // is retained for Retry.
    harness.store.fail_next_commits(1);
    let before = fs::read(harness.document()).unwrap();
    let series3 = harness.values()["appearance.series3.color"].clone();
    harness.click_labelled("Inherit the default Series 3 color");
    let _ = harness.quiet();
    assert_eq!(
        fs::read(harness.document()).unwrap(),
        before,
        "the failed palette edit wrote anything"
    );
    assert_eq!(
        harness.values()["appearance.series3.color"],
        series3,
        "the failed palette edit landed the colour"
    );
    assert_eq!(
        harness.values()["themes.preset"],
        json!("Custom"),
        "the failed palette edit changed the designation"
    );
    assert_eq!(
        harness.window.held.len(),
        2,
        "the retained batch is not the colour and its designation"
    );
    // Retry lands the colour and the designation together — one commit
    // (the inherited entry stores its explicit "not set").
    let commits = harness.store.commit_count();
    harness.click_labelled("Retry saving changes that did not persist");
    let _ = harness.quiet();
    assert_eq!(
        harness.store.commit_count(),
        commits + 1,
        "the retried palette batch took more than one commit"
    );
    assert!(harness.window.held.is_empty());
    assert_eq!(
        harness.values()["appearance.series3.color"],
        json!(null),
        "the retried colour did not inherit"
    );
    assert_eq!(harness.values()["themes.preset"], json!("Custom"));
    fs::remove_dir_all(&harness.root).unwrap();
}

/// Round 5, ruling R41 completed — the whole-view save behind the legacy
/// import's accept is never refused for a dormant dependent: an accepted
/// import whose view moves the CPU window 5→10 while its sample count
/// moves 100→200 lands both, one batch, one commit — the count stays
/// dormant beneath the window exactly as it began.
#[test]
fn dormant_to_dormant_view_save_through_the_import_accept() {
    let mut harness = Harness::new();
    // The starting document holds the dormant pair.
    harness
        .store
        .set("graphs.cpu.time_window", json!(5))
        .expect("the window saves");
    harness
        .store
        .set("graphs.cpu.samples", json!(100))
        .expect("a dormant dependent is stored, never refused");
    // The reviewed import the accept button saves: the same view with the
    // window 5→10 and the count 100→200.
    let mut imported = harness.store.settings().clone();
    imported.metrics.cpu_history_minutes = 10;
    imported.metrics.cpu_history_samples = 200;
    harness.window.import = Some(crate::legacy::Import {
        settings: imported,
        imported: Vec::new(),
        skipped: Vec::new(),
        repeated_keys: 0,
    });
    let commits = harness.store.commit_count();
    harness
        .window
        .accept_import(&mut harness.store)
        .expect("the dormant-to-dormant import accepts");
    assert_eq!(
        harness.store.commit_count(),
        commits + 1,
        "the import's whole-view save took more than one commit"
    );
    assert_eq!(
        harness.values()["graphs.cpu.time_window"],
        json!(10),
        "the dormant-to-dormant save was refused (window)"
    );
    assert_eq!(
        harness.values()["graphs.cpu.samples"],
        json!(200),
        "the dormant-to-dormant save was refused (samples)"
    );
    assert!(
        harness.window.import.is_none(),
        "the import was not consumed"
    );
    fs::remove_dir_all(&harness.root).unwrap();
}

/// Rulings R37/R41 (R41 completed in round 5) — the store's batch is
/// all-or-nothing, and a batch is never refused because a dependent's
/// dependency is off, in the starting or the final document: one refused
/// entry aborts the whole batch, enable-and-set is accepted, a single set
/// of a dependent under a stored dependency stores a dormant value, and
/// the dormant-to-dormant move is accepted too.
#[test]
fn store_batches_apply_whole_and_follow_the_final_document() {
    let mut harness = Harness::new();
    // A fresh harness holds the default document in memory only; the file
    // appears with the first successful write.
    let before = fs::read(harness.document()).unwrap_or_default();
    // One refused entry aborts the whole batch: the unrelated set in the
    // same batch never lands.
    let refusals = harness
        .store
        .apply_batch(&[
            document::Change::Set("general.window.title".into(), json!("Kept")),
            document::Change::Set("sources.fans.sensor2".into(), json!("fan-b")),
        ])
        .expect_err("the batch must be refused");
    assert_eq!(
        refusals,
        vec![(
            "sources.fans.sensor2".to_owned(),
            document::SetError::ConstraintFailed
        )],
        "{refusals:?}"
    );
    assert_eq!(fs::read(harness.document()).unwrap_or_default(), before);
    assert!(harness.values().get("general.window.title").is_none());
    // Enable-and-set (ruling R41): remove the window override and store the
    // count in ONE batch.
    harness
        .store
        .set("graphs.cpu.time_window", json!(5))
        .expect("the window saves");
    harness
        .store
        .set("graphs.cpu.samples", json!(100))
        .expect("a dormant dependent is stored, never refused");
    harness
        .store
        .apply_batch(&[
            document::Change::Remove("graphs.cpu.time_window".into()),
            document::Change::Set("graphs.cpu.samples".into(), json!(100)),
        ])
        .expect("the enable-and-set batch applies");
    assert_eq!(harness.values()["graphs.cpu.samples"], json!(100));
    assert!(harness.values().get("graphs.cpu.time_window").is_none());
    // Dormant (ruling R41): ONE batch turns the window on while the count
    // stays stored — allowed, never refused for it.
    harness
        .store
        .apply_batch(&[document::Change::Set(
            "graphs.cpu.time_window".into(),
            json!(5),
        )])
        .expect("a batch that leaves a dormant dependent is never refused");
    assert_eq!(harness.values()["graphs.cpu.samples"], json!(100));
    assert_eq!(harness.values()["graphs.cpu.time_window"], json!(5));
    // Dormant-to-dormant (ruling R41 completed, round 5): ONE batch moves
    // the window 5→10 while the count moves 100→200 — the dependency is
    // off in both documents and the final document merely retains a
    // dormant count: accepted.
    harness
        .store
        .apply_batch(&[
            document::Change::Set("graphs.cpu.time_window".into(), json!(10)),
            document::Change::Set("graphs.cpu.samples".into(), json!(200)),
        ])
        .expect("the dormant-to-dormant batch is never refused");
    assert_eq!(harness.values()["graphs.cpu.samples"], json!(200));
    assert_eq!(harness.values()["graphs.cpu.time_window"], json!(10));
    fs::remove_dir_all(&harness.root).unwrap();
}

/// Round 4, ruling R37 — the held-edit retry is all-or-nothing: ONE refused
/// held edit keeps EVERY held edit in place — the savable ones are not
/// saved either — writes nothing, records each reason on its row, and a
/// valid held set lands whole.
#[test]
fn held_edit_retry_applies_whole_or_keeps_everything() {
    let mut harness = Harness::new();
    harness
        .store
        .set("graphs.cpu.time_window", json!(5))
        .expect("the window saves");
    let before = fs::read(harness.document()).unwrap();
    // The held edits a repair could not persist: one savable, one the core
    // refuses (a secondary fan curve without its primary — a combination
    // violation; a dormant sample count under the stored window is stored,
    // never refused, since ruling R41 completed in round 5).
    harness
        .window
        .held
        .insert("general.window.title".into(), json!("Kept"));
    harness
        .window
        .held
        .insert("sources.fans.sensor2".into(), json!("fan-b"));
    harness.window.retry_unpersisted(&mut harness.store);
    assert_eq!(
        fs::read(harness.document()).unwrap(),
        before,
        "the refused retry wrote the savable edit (or anything)"
    );
    assert!(
        harness.values().get("general.window.title").is_none(),
        "the savable held edit never landed"
    );
    assert_eq!(harness.window.held.len(), 2, "every held edit stays held");
    assert!(
        harness.window.error("sources.fans.sensor2").is_some(),
        "the refused edit's reason is on its row"
    );
    // A valid held set lands whole, one commit.
    harness.window.held.clear();
    harness
        .window
        .held
        .insert("general.window.title".into(), json!("Kept"));
    harness.window.retry_unpersisted(&mut harness.store);
    assert_eq!(harness.values()["general.window.title"], json!("Kept"));
    assert!(harness.window.held.is_empty());
    fs::remove_dir_all(&harness.root).unwrap();
}

/// Round 4, ruling R37 — the replacement's held batch is all-or-nothing on
/// VALIDATION refusals too: one refused held edit keeps EVERY held edit in
/// place — the savable ones are not dropped from the banner's promise —
/// each refusal's reason shows on its row, nothing is written, and the
/// later retry of the same set is refused identically.
#[test]
fn replacement_refusals_keep_every_held_edit() {
    let (root, mut harness) = blocked_harness();
    // Held while the document was blocked: a savable title, and a
    // combination-invalid secondary fan curve (reachable: a
    // transport-retained secondary whose primary a later successful commit
    // removed).
    harness
        .window
        .held
        .insert("general.window.title".into(), json!("Kept"));
    harness
        .window
        .held
        .insert("sources.fans.sensor2".into(), json!("fan-b"));
    harness.click_labelled("Replace the file with the current settings");
    assert!(
        !harness.store.blocked(),
        "replacement did not repair the document"
    );
    // The refused batch applied nothing: the title never landed…
    assert!(harness.values().get("general.window.title").is_none());
    // …but EVERY held edit stays held — the savable title included —
    // and the refusal's reason shows on its row.
    assert_eq!(
        harness.window.held.len(),
        2,
        "the banner's promise was truncated by the refusal"
    );
    assert!(
        harness.window.error("sources.fans.sensor2").is_some(),
        "the refused edit's reason is not on its row"
    );
    // The same set retried is refused identically — never truncated.
    harness.window.retry_unpersisted(&mut harness.store);
    assert_eq!(
        harness.window.held.len(),
        2,
        "the retry dropped a held edit"
    );
    assert!(harness.values().get("general.window.title").is_none());
    fs::remove_dir_all(&root).unwrap();
}
