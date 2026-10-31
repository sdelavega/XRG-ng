// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::*;
use egui::{Event, Key, Modifiers, PointerButton, Pos2, RawInput, ViewportId, accesskit};

fn frame(
    ctx: &egui::Context,
    scale: f32,
    modules: &[Module],
    events: Vec<Event>,
) -> (egui::FullOutput, Vec<egui::Response>) {
    let mut raw = RawInput {
        screen_rect: Some(Rect::from_min_size(Pos2::ZERO, vec2(400., 600.))),
        events,
        ..Default::default()
    };
    raw.viewports
        .get_mut(&ViewportId::ROOT)
        .unwrap()
        .native_pixels_per_point = Some(scale);
    let settings = Settings::default();
    let theme = crate::shared::themes().remove(0);
    let mut responses = Vec::new();
    let mut output = ctx.run_ui(raw, |ui| {
        responses.clear();
        for &module in modules {
            responses.push(show(
                ui,
                vec2(140., 90.),
                &theme,
                module,
                None,
                &settings,
                GraphStyle::ALL[0],
            ));
        }
    });
    // This fixture has no renderer; acknowledge uploads even on setup frames.
    output.textures_delta.clear();
    (output, responses)
}
fn key(key: Key) -> Event {
    Event::Key {
        key,
        physical_key: None,
        pressed: true,
        repeat: false,
        modifiers: Modifiers::NONE,
    }
}
#[test]
fn graph_nodes_have_names_status_and_activation_at_fractional_scales() {
    for scale in [1., 1.25, 1.5, 2.] {
        let ctx = egui::Context::default();
        ctx.enable_accesskit();
        let (mut output, responses) = frame(&ctx, scale, &Module::ALL, vec![]);
        assert_eq!(output.pixels_per_point, scale);
        let tree = output.platform_output.accesskit_update.as_ref().unwrap();
        for (module, response) in Module::ALL.iter().zip(&responses) {
            let node = &tree
                .nodes
                .iter()
                .find(|(id, _)| *id == response.id.accesskit_id())
                .unwrap()
                .1;
            assert_eq!(node.role(), accesskit::Role::Button);
            assert_eq!(
                node.label(),
                Some(format!("{} graph", module.title()).as_str())
            );
            assert!(
                node.description()
                    .unwrap()
                    .contains("Waiting for selected source")
            );
            assert!(node.supports_action(accesskit::Action::Click));
            assert!(node.supports_action(accesskit::Action::Focus));
            assert_eq!(node.bounds().unwrap().width(), 140.);
        }
        output.textures_delta.clear();
    }
}
#[test]
fn enter_space_and_accessibility_click_open_details_without_pointer_double_click() {
    let ctx = egui::Context::default();
    ctx.enable_accesskit();
    let (_, initial) = frame(&ctx, 1., &[Module::Cpu], vec![]);
    let id = initial[0].id;
    for event in [
        key(Key::Enter),
        key(Key::Space),
        Event::AccessKitActionRequest(accesskit::ActionRequest {
            action: accesskit::Action::Click,
            target_tree: accesskit::TreeId::ROOT,
            target_node: id.accesskit_id(),
            data: None,
        }),
    ] {
        ctx.memory_mut(|m| m.request_focus(id));
        let (mut output, response) = frame(&ctx, 1., &[Module::Cpu], vec![event]);
        assert!(details_requested(&response[0]));
        assert!(
            output
                .shapes
                .iter()
                .any(|s| matches!(&s.shape, egui::Shape::Rect(r) if r.stroke.width == 1.5))
        );
        output.textures_delta.clear();
    }
}
#[test]
fn a_single_mouse_click_focuses_without_opening_details() {
    let ctx = egui::Context::default();
    let (_, initial) = frame(&ctx, 1.25, &[Module::Cpu], vec![]);
    let pos = initial[0].rect.center();
    for pressed in [true, false] {
        let (_, response) = frame(
            &ctx,
            1.25,
            &[Module::Cpu],
            vec![
                Event::PointerMoved(pos),
                Event::PointerButton {
                    pos,
                    button: PointerButton::Primary,
                    pressed,
                    modifiers: Modifiers::NONE,
                },
            ],
        );
        assert!(!details_requested(&response[0]));
    }
}
#[test]
fn graph_focus_identity_survives_reordering() {
    let ctx = egui::Context::default();
    let (_, before) = frame(&ctx, 1., &[Module::Cpu, Module::Memory], vec![]);
    ctx.memory_mut(|m| m.request_focus(before[0].id));
    let (_, after) = frame(&ctx, 1., &[Module::Memory, Module::Cpu], vec![]);
    assert_eq!(before[0].id, after[1].id);
    assert!(after[1].has_focus());
}
#[test]
fn focusing_an_offscreen_graph_scrolls_it_into_view() {
    let ctx = egui::Context::default();
    ctx.enable_accesskit();
    let settings = Settings::default();
    let theme = crate::shared::themes().remove(0);
    let mut last: Option<egui::Id> = None;
    let mut offset = 0.;
    for step in 0..8 {
        let mut output = ctx.run_ui(
            RawInput {
                screen_rect: Some(Rect::from_min_size(Pos2::ZERO, vec2(220., 200.))),
                time: Some(step as f64 * 0.1),
                events: if step == 1 {
                    vec![Event::AccessKitActionRequest(accesskit::ActionRequest {
                        action: accesskit::Action::Focus,
                        target_tree: accesskit::TreeId::ROOT,
                        target_node: last.unwrap().accesskit_id(),
                        data: None,
                    })]
                } else {
                    vec![]
                },
                ..Default::default()
            },
            |ui| {
                let scroll = egui::ScrollArea::vertical()
                    .max_height(180.)
                    .show(ui, |ui| {
                        for module in Module::ALL {
                            let response = show(
                                ui,
                                vec2(140., 90.),
                                &theme,
                                module,
                                None,
                                &settings,
                                GraphStyle::ALL[0],
                            );
                            last = Some(response.id);
                        }
                    });
                offset = scroll.state.clamped_offset().y;
            },
        );
        output.textures_delta.clear();
    }
    assert!(
        offset > 900.,
        "Focused graph remained outside the viewport: offset={offset}"
    );
}

#[test]
fn keyboard_context_menu_remains_visible_without_pointer_position() {
    let ctx = egui::Context::default();
    let settings = Settings::default();
    let theme = crate::shared::themes().remove(0);
    let mut shown = Vec::new();
    for step in 0..3 {
        let mut raw = RawInput {
            screen_rect: Some(Rect::from_min_size(Pos2::ZERO, vec2(400., 600.))),
            ..Default::default()
        };
        if step == 1 {
            raw.events.push(Event::ModifiersChanged(Modifiers::SHIFT));
            raw.events.push(Event::Key {
                key: Key::F10,
                physical_key: None,
                pressed: true,
                repeat: false,
                modifiers: Modifiers::SHIFT,
            });
        }
        let mut output = ctx.run_ui(raw, |ui| {
            let response = show(
                ui,
                vec2(140., 90.),
                &theme,
                Module::Cpu,
                None,
                &settings,
                GraphStyle::ALL[0],
            );
            if step == 0 {
                response.request_focus();
            }
            let popup = context_menu(&response, Module::Cpu);
            let visible = popup
                .show(|ui| {
                    let _ = ui.button("Live details…");
                })
                .is_some();
            shown.push(visible);
        });
        output.textures_delta.clear();
    }
    assert!(!shown[0]);
    assert!(
        shown[1..].iter().all(|visible| *visible),
        "Keyboard menu disappeared between frames: {shown:?}"
    );
}
