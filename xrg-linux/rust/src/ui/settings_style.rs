// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The Aether7b egui style for the settings window (0.2.3 spec §5): every
//! colour, corner radius, spacing and font size comes from the generated
//! tokens in `super::aether7b`, and both the style and every painted shape
//! are audited against exactly this module's colour set. Light and dark
//! follow the system; egui's animation time comes from the motion tokens
//! and reduced motion makes every transition instant.
use super::aether7b;
use eframe::egui::{
    self, Color32, CornerRadius, FontId, Margin, Response, Sense, Stroke, Vec2,
    text::{LayoutJob, TextFormat},
};

/// The 2 px Carolina focus halo: the mockup's `--a7b-focus-ring`, the
/// carolinaWeb token at the mockup's 0.35 halo alpha. The rim colour focus
/// turns on is the carolinaClassic token (the focus-visible border).
pub fn focus_halo() -> Color32 {
    let [r, g, b, _] = aether7b::brand_carolina_web().to_array();
    Color32::from_rgba_unmultiplied(r, g, b, 89)
}
pub fn focus_border() -> Color32 {
    aether7b::brand_carolina_classic()
}

/// The aurora wash's enumerated alpha stops: the orb token's alpha ladder,
/// the shape a 64 px blur of one orb gives — a soft wash, never a
/// hard-edged disc (fix V7). The colour audit allows exactly these values.
pub const WASH_STOPS: [f32; 5] = [1.0, 0.6, 0.32, 0.14, 0.05];
fn wash_color(dark: bool, stop: f32) -> Color32 {
    // `orb`'s bytes are premultiplied (every Color32 is); the wash scales
    // the straight colour's alpha, so un-premultiply before scaling.
    let [r, g, b, a] = aether7b::orb(dark).to_array();
    let straight = |channel: u8| {
        if a == 0 {
            0
        } else {
            ((u32::from(channel) * 255) / u32::from(a)).min(255) as u8
        }
    };
    Color32::from_rgba_unmultiplied(
        straight(r),
        straight(g),
        straight(b),
        (f32::from(a) * stop).round().min(255.) as u8,
    )
}
/// Whether the settings window follows the system's dark appearance. Under
/// a backend that reports no system theme (Xvfb, headless tests) the
/// context's resolved theme decides; `XRG_SETTINGS_THEME=light|dark` pins
/// one for the snapshot tool, standing in for a system theme the same way
/// the macOS tool pins an appearance.
pub fn dark(ctx: &egui::Context) -> bool {
    match std::env::var("XRG_SETTINGS_THEME").as_deref() {
        Ok("light") => false,
        Ok("dark") => true,
        _ => ctx.system_theme().unwrap_or_else(|| ctx.theme()) == egui::Theme::Dark,
    }
}

/// Whether reduced motion was requested: the explicit environment pin
/// first (`XRG_SETTINGS_REDUCED_MOTION`, standing in for the desktop's
/// request exactly the way `XRG_SETTINGS_THEME` stands in for its
/// appearance — the macOS counterpart reads
/// `accessibilityDisplayShouldReduceMotion`), then the GTK desktop's
/// own animation preference, read once per process. Absent tools and
/// failed reads mean "not requested". An absent or unrecognised pin is
/// the desktop-query path (`reduced_motion(None, …)`).
pub fn reduced_motion_requested() -> bool {
    let pin = std::env::var("XRG_SETTINGS_REDUCED_MOTION").ok();
    if let Some(answer) = reduced_motion_pin(pin.as_deref()) {
        return answer;
    }
    reduced_motion(None, desktop_animations_enabled())
}

/// The reduced-motion decision for one pin. `None` — the override is
/// absent — follows the desktop query: animations disabled means reduced
/// motion was requested. A recognised pin wins and the desktop is not asked.
pub fn reduced_motion(pin: Option<&str>, animations_enabled: bool) -> bool {
    reduced_motion_pin(pin).unwrap_or(!animations_enabled)
}

fn reduced_motion_pin(pin: Option<&str>) -> Option<bool> {
    match pin {
        Some("1" | "true" | "yes" | "on") => Some(true),
        Some("0" | "false" | "no" | "off") => Some(false),
        _ => None,
    }
}

/// The desktop's animation preference, read once: a GNOME session stores
/// it as `enable-animations` under `org.gnome.desktop.interface` (not
/// `gtk-enable-animations`). The query is bounded and cached; a missing
/// `gsettings` (headless CI, other desktops) is "not requested".
fn desktop_animations_enabled() -> bool {
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| query_enable_animations(std::path::Path::new("gsettings")))
}

/// Run the desktop animation query. `false` from the tool means animations
/// are off; a missing tool or a failed read means they are on. The key is
/// GNOME's `enable-animations`.
pub fn query_enable_animations(program: &std::path::Path) -> bool {
    crate::command::BoundedCommand::default()
        .output(
            program,
            &["get", "org.gnome.desktop.interface", "enable-animations"],
            std::time::Duration::from_secs(2),
            32,
        )
        .map(|answer| String::from_utf8_lossy(&answer).trim() != "false")
        .unwrap_or(true)
}

/// The CSS-clamped pill radius (W1): `border-radius` clamps to half the
/// shape's shortest side, never the raw 9999 token.
pub fn pill(size: Vec2) -> u8 {
    (0.5 * size.min_elem()).round().clamp(0., 127.) as u8
}
/// Every colour the settings window may paint with, for one appearance:
/// the adaptive tokens, the brand constants, the focus halo and the
/// aurora wash's enumerated stops. This is the token-only audit's complete
/// allowance; nothing else is exempt.
#[cfg_attr(not(test), allow(dead_code))]
pub fn token_colors(dark: bool) -> Vec<Color32> {
    let mut colors = vec![
        aether7b::bg_canvas(dark),
        aether7b::surface_chrome(dark),
        aether7b::surface_chrome_fallback(dark),
        aether7b::surface_card(dark),
        aether7b::surface_code(dark),
        aether7b::text_main(dark),
        aether7b::text_muted(dark),
        aether7b::accent_active(dark),
        aether7b::accent_fill(dark),
        aether7b::accent_tint(dark),
        aether7b::border(dark),
        aether7b::border_strong(dark),
        aether7b::specular(dark),
        aether7b::status_nominal(dark),
        aether7b::status_warning(dark),
        aether7b::status_danger(dark),
        aether7b::status_success(dark),
        aether7b::orb(dark),
        aether7b::brand_carolina_classic(),
        aether7b::brand_carolina_web(),
        aether7b::brand_carolina_ink(),
        aether7b::brand_ice_specular(),
        aether7b::brand_navy_core(),
        aether7b::brand_obsidian(),
        Color32::TRANSPARENT,
        focus_halo(),
    ];
    colors.extend(WASH_STOPS.iter().map(|&stop| wash_color(dark, stop)));
    colors
}
/// The named corner radii the window draws: the generated tokens and the
/// focus halo's 2 px outset. Pill chrome draws the CSS-clamped half-side
/// (`pill`), which follows the shape's size instead of a named token.
#[cfg_attr(not(test), allow(dead_code))]
pub const TOKEN_RADII: [u8; 5] = [
    aether7b::RADIUS_SM as u8,
    aether7b::RADIUS_MD as u8,
    aether7b::RADIUS_LG as u8,
    aether7b::RADIUS_MD as u8 + 2,
    aether7b::RADIUS_SM as u8 + 2,
];

/// The complete egui style for one appearance. Everything egui paints
/// itself — text edits, combos, popups, menus, sliders, tooltips, carets,
/// scroll bars — takes its colours from these visuals, so the token
/// palette holds even inside egui's own widget chrome. Animation time
/// comes from the motion tokens, and a reduced-motion request makes
/// every egui transition instant (spec §5).
pub fn style(dark: bool) -> egui::Style {
    let mut style = egui::Style::default();
    let visuals = &mut style.visuals;
    visuals.dark_mode = dark;
    visuals.panel_fill = aether7b::bg_canvas(dark);
    visuals.window_fill = aether7b::surface_card(dark);
    visuals.window_stroke = Stroke::new(1., aether7b::border(dark));
    visuals.faint_bg_color = aether7b::bg_canvas(dark);
    visuals.extreme_bg_color = aether7b::surface_card(dark);
    visuals.code_bg_color = aether7b::surface_code(dark);
    visuals.hyperlink_color = aether7b::accent_active(dark);
    visuals.warn_fg_color = aether7b::status_warning(dark);
    visuals.error_fg_color = aether7b::status_danger(dark);
    visuals.window_shadow = egui::Shadow::NONE;
    visuals.popup_shadow = egui::Shadow::NONE;
    visuals.text_cursor.stroke = Stroke::new(2., aether7b::text_main(dark));
    visuals.ime_composition.active_underline_stroke =
        Stroke::new(1., aether7b::accent_active(dark));
    visuals.ime_composition.inactive_underline_stroke =
        Stroke::new(1., aether7b::border_strong(dark));
    // Inputs sit on the strong 3:1 rim (spec §5); everything else is flat.
    let (rim, flat) = (
        Stroke::new(1., aether7b::border_strong(dark)),
        Stroke::new(1., aether7b::border(dark)),
    );
    let text = Stroke::new(1., aether7b::text_main(dark));
    let radius = CornerRadius::same(aether7b::RADIUS_MD as u8);
    for (state, strong) in [
        (&mut visuals.widgets.noninteractive, false),
        (&mut visuals.widgets.inactive, true),
        (&mut visuals.widgets.hovered, true),
        (&mut visuals.widgets.active, true),
        (&mut visuals.widgets.open, true),
    ] {
        state.bg_fill = aether7b::surface_card(dark);
        state.weak_bg_fill = aether7b::surface_card(dark);
        state.bg_stroke = if strong { rim } else { flat };
        state.fg_stroke = text;
        state.corner_radius = radius;
    }
    visuals.widgets.hovered.weak_bg_fill = aether7b::accent_tint(dark);
    visuals.widgets.hovered.bg_fill = aether7b::accent_tint(dark);
    visuals.widgets.active.weak_bg_fill = aether7b::accent_tint(dark);
    visuals.widgets.active.bg_fill = aether7b::accent_tint(dark);
    visuals.widgets.open.weak_bg_fill = aether7b::accent_tint(dark);
    visuals.widgets.open.bg_fill = aether7b::accent_tint(dark);
    visuals.selection.bg_fill = aether7b::accent_tint(dark);
    visuals.selection.stroke = Stroke::new(1., aether7b::accent_active(dark));
    // egui's own chrome — its windows and menus — carries the named
    // radii too, so no painted corner strays from the tokens.
    visuals.window_corner_radius = CornerRadius::same(aether7b::RADIUS_LG as u8);
    visuals.menu_corner_radius = CornerRadius::same(aether7b::RADIUS_LG as u8);
    style.text_styles = [
        (egui::TextStyle::Heading, sans(aether7b::TYPE_LG.0)),
        (egui::TextStyle::Body, sans(aether7b::TYPE_MD.0)),
        (egui::TextStyle::Button, sans(aether7b::TYPE_SM.0)),
        (egui::TextStyle::Small, sans(aether7b::TYPE_XS.0)),
        (egui::TextStyle::Monospace, mono(aether7b::TYPE_SM.0)),
    ]
    .into_iter()
    .collect();
    style.spacing.item_spacing = Vec2::splat(aether7b::SPACE_S2);
    style.spacing.button_padding = Vec2::new(aether7b::SPACE_S3, aether7b::SPACE_S2);
    style.spacing.window_margin = Margin::same(aether7b::SPACE_S2 as i8);
    style.spacing.menu_margin = Margin::same(aether7b::SPACE_S2 as i8);
    // The mockup's slider width, through the style's spacing.
    style.spacing.slider_width = SLIDER_WIDTH;
    // Motion (spec §5): a typical transition lasts the base motion token,
    // and reduced motion makes every egui animation instant.
    style.animation_time = if reduced_motion_requested() {
        0.
    } else {
        aether7b::MOTION_BASE.as_secs_f32()
    };
    style
}

/// A mono font of the token type scale.
pub fn mono(size: f32) -> FontId {
    FontId::monospace(size)
}
/// A proportional font of the token type scale.
pub fn sans(size: f32) -> FontId {
    FontId::proportional(size)
}

/// Paint the 2 px Carolina focus halo around a focused control's rim, at
/// the rim's radius widened by the 2 px ring (the mockup's 1 px offset).
pub fn paint_focus_halo(painter: &egui::Painter, rect: egui::Rect, radius: u8) {
    let halo = rect.expand(2.);
    let corner = CornerRadius::same((radius as u16 + 2).min(255) as u8);
    painter.rect_stroke(
        halo,
        corner,
        Stroke::new(2., focus_halo()),
        egui::StrokeKind::Middle,
    );
}

/// A rim's stroke colour: the danger colour while the entry shows a reason
/// (and nothing else turns red), Carolina while the control holds keyboard
/// focus, the strong border otherwise — the mockup's inputs.
pub fn rim_stroke(dark: bool, danger: bool, focused: bool) -> Stroke {
    Stroke::new(
        1.,
        if danger {
            aether7b::status_danger(dark)
        } else if focused {
            focus_border()
        } else {
            aether7b::border_strong(dark)
        },
    )
}

/// The mockup's slider width (`.slider { width: 150px }`): the width the
/// window's sliders draw at, set through the style's spacing so both the
/// row sliders and the colour editor's channel sliders share it.
pub const SLIDER_WIDTH: f32 = 150.;

/// The slider rail's thickness, set in the slider's own style scope so the
/// track has visible geometry (fix L6). egui paints the rail from
/// `slider_rail_height` with no outline.
pub const SLIDER_RAIL_HEIGHT: f32 = 6.;

/// The slider rail's fill. egui paints the rail with
/// `widgets.inactive.bg_fill` and no outline; the inactive fill is otherwise
/// the card colour, so a rail that used it would vanish into the card
/// (fix L6). `border_strong` is the 3:1 rim token — it contrasts with the
/// card in both appearances, and it is applied only inside the slider's
/// own style scope so other widgets keep the card fill.
pub fn slider_rail(dark: bool) -> Color32 {
    aether7b::border_strong(dark)
}

/// The mockup's aurora wash: concentric circles of the orb token at the
/// enumerated `WASH_STOPS`, anchored above-left of the canvas — one soft
/// low-alpha wash, never a hard-edged disc. Clipped inside the canvas so
/// the 12 px rounded window corners stay unpainted.
pub fn aurora_wash(painter: &egui::Painter, canvas: egui::Rect, dark: bool) {
    let side = 0.6 * canvas.width();
    let center = egui::pos2(
        canvas.left() - 0.15 * canvas.width() + side / 2.,
        canvas.top() - 0.35 * canvas.height() + side / 2.,
    );
    let painter = painter.with_clip_rect(canvas.shrink(aether7b::RADIUS_LG));
    let rings = WASH_STOPS.len();
    for (index, stop) in WASH_STOPS.iter().enumerate() {
        // Each ring paints inside-out, so no later ring can overpaint an
        // earlier one and every band is one enumerated colour.
        let inner = side * index as f32 / rings as f32 / 2.;
        let outer = side * (index + 1) as f32 / rings as f32 / 2.;
        let color = wash_color(dark, *stop);
        let mid = (inner + outer) / 2.;
        painter.add(egui::Shape::circle_stroke(
            center,
            mid,
            Stroke::new(outer - inner, color),
        ));
    }
}

/// One flat, opaque card (spec §5): surface-card fill, hairline border,
/// `radius-lg` corners — the frame every catalog group renders in.
pub fn card(dark: bool) -> egui::Frame {
    egui::Frame::new()
        .fill(aether7b::surface_card(dark))
        .stroke(Stroke::new(1., aether7b::border(dark)))
        .corner_radius(CornerRadius::same(aether7b::RADIUS_LG as u8))
        .inner_margin(Margin {
            left: aether7b::SPACE_S4 as i8,
            right: aether7b::SPACE_S4 as i8,
            top: aether7b::SPACE_S3 as i8,
            bottom: aether7b::SPACE_S3 as i8,
        })
}

/// The signature `// EYEBROW` label (the mockup's CSS-rendered slashes):
/// mono, the slashes muted, the text upper-case in the accent colour.
pub fn eyebrow(ui: &mut egui::Ui, text: &str, dark: bool) -> Response {
    let font = mono(aether7b::TYPE_XS.0);
    let mut job = LayoutJob::default();
    job.append(
        "// ",
        0.,
        TextFormat::simple(font.clone(), aether7b::text_muted(dark)),
    );
    job.append(
        &text.to_uppercase(),
        0.,
        TextFormat::simple(font, aether7b::accent_active(dark)),
    );
    ui.add(egui::Label::new(job))
}

/// A flat ghost button (the mockup's `.a7b-btn-ghost`): transparent until
/// hovered, the strong rim, `radius-md` corners, keyboard focusable with
/// the Carolina rim and the 2 px halo. A disabled ghost button takes no
/// interaction and no focus, but still lays out and paints. A click takes
/// the focus — egui leaves it with the pointer alone, and the macOS window
/// makes a pressed control the first responder. The salt gives the button
/// a stable id, so its hover and focus state never bleed onto another
/// button that allocates at the same point in egui's auto-id sequence.
pub fn ghost_button(
    ui: &mut egui::Ui,
    salt: impl std::hash::Hash + std::fmt::Debug,
    label: &str,
    enabled: bool,
    dark: bool,
) -> Response {
    let font = sans(aether7b::TYPE_SM.0);
    let galley =
        ui.painter()
            .layout_no_wrap(label.to_owned(), font.clone(), aether7b::text_main(dark));
    let size = galley.size() + Vec2::new(2. * aether7b::SPACE_S3, 2. * aether7b::SPACE_S2);
    let (rect, response) = ui
        .push_id(salt, |ui| {
            if enabled {
                ui.allocate_exact_size(size, Sense::click())
            } else {
                ui.add_enabled_ui(false, |ui| ui.allocate_exact_size(size, Sense::click()))
                    .inner
            }
        })
        .inner;
    let corner = CornerRadius::same(aether7b::RADIUS_MD as u8);
    let (fill, stroke) = if !enabled {
        (
            Color32::TRANSPARENT,
            Stroke::new(1., aether7b::border(dark)),
        )
    } else if response.has_focus() {
        (aether7b::accent_tint(dark), Stroke::new(1., focus_border()))
    } else if response.hovered() {
        (
            aether7b::accent_tint(dark),
            Stroke::new(1., aether7b::border_strong(dark)),
        )
    } else {
        (
            Color32::TRANSPARENT,
            Stroke::new(1., aether7b::border_strong(dark)),
        )
    };
    ui.painter().rect_filled(rect, corner, fill);
    ui.painter()
        .rect_stroke(rect, corner, stroke, egui::StrokeKind::Middle);
    let color = if enabled {
        aether7b::text_main(dark)
    } else {
        aether7b::text_muted(dark)
    };
    ui.painter().galley(
        egui::pos2(
            rect.min.x + aether7b::SPACE_S3,
            rect.min.y + (rect.height() - galley.size().y) / 2.,
        ),
        galley,
        color,
    );
    if response.has_focus() {
        paint_focus_halo(ui.painter(), rect, aether7b::RADIUS_MD as u8);
    }
    if enabled && response.clicked() {
        response.request_focus();
    }
    response
        .widget_info(|| egui::WidgetInfo::labeled(egui::accesskit::Role::Button, enabled, label));
    response
}
