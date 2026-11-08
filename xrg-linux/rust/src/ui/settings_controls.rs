// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! One Aether7b control per catalog entry kind (0.2.3 spec §5): toggles,
//! choice menus, segmented buttons, number and duration fields with their
//! unit and range shown, sliders where the catalog gives a step, colour
//! wells with their own editor and an Inherit affordance, path pickers,
//! text fields, source pickers, the reorderable graph list and action
//! buttons. Every control applies its edit instantly through the store;
//! the shared core is the only validator — a refused value shows the
//! danger rim, dot and mono reason and saves nothing, and malformed text
//! is refused before the store is ever asked (lesson a). Every control is
//! keyboard operable with the 2 px Carolina focus halo, and disabled
//! (dependent) controls take neither mouse nor keyboard (lesson b).
use super::{aether7b, preferences::SourceProvider, settings_style};
use crate::settings::document::{CatalogEntry, SetError};
use eframe::egui::{self, CornerRadius, Id, Rect, Response, Sense, Vec2};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// The catalog's "no meaningful upper bound" sentinel: the maximum a JSON
/// whole number can carry without losing precision. A range whose max is
/// the sentinel has no real upper bound to show, so the control shows no
/// range text at all (lesson i).
pub const UNBOUNDED_MAXIMUM: f64 = 9_007_199_254_740_991.0;

/// The appearance palette entry ids, in the shared ABI's theme order:
/// window background, graph background, the three series fills, the border,
/// the text.
pub const PALETTE_IDS: [&str; 7] = [
    "appearance.window.color",
    "appearance.graph_background.color",
    "appearance.series1.color",
    "appearance.series2.color",
    "appearance.series3.color",
    "appearance.border.color",
    "appearance.text.color",
];

/// The bytes/s unit selector (lesson g): the units the old preferences used
/// — bytes, KB, MB on the 1024-power series — extended with GB, a
/// presentation of the single stored bytes/s value. No new stored setting;
/// every conversion is checked.
pub const SCALE_UNITS: [(&str, i64); 4] = [
    ("bytes/s", 1),
    ("KB/s", 1024),
    ("MB/s", 1_048_576),
    ("GB/s", 1_073_741_824),
];

/// Per-entry state the controls carry between frames: the text the user
/// is typing, the danger reasons refused values show, the exact bytes/s a
/// unit selector presents (held independently of the displayed text), the
/// chosen unit, the open colour pickers, and the generation each text
/// field renders at — bumping a generation re-presents the stored value,
/// replacing in-flight text after a reset, an import or a save.
#[derive(Default)]
pub struct Fields {
    edits: BTreeMap<String, String>,
    errors: BTreeMap<String, String>,
    bytes: BTreeMap<String, i64>,
    units: BTreeMap<String, usize>,
    colors_open: BTreeSet<String>,
    generations: BTreeMap<String, u32>,
    order_focus: Option<(String, bool)>,
}
impl Fields {
    /// Re-present one entry's stored value, dropping any in-flight text
    /// and its reason.
    pub fn bump(&mut self, id: &str) {
        *self.generations.entry(id.to_owned()).or_default() += 1;
        self.edits.remove(id);
        self.errors.remove(id);
    }
    fn generation(&self, id: &str) -> u32 {
        self.generations.get(id).copied().unwrap_or_default()
    }
    /// The danger reason one entry currently shows, if any.
    pub fn error(&self, id: &str) -> Option<&str> {
        self.errors.get(id).map(String::as_str)
    }
    /// How many colour pickers are open (Escape belongs to them first).
    pub fn color_popups_open(&self) -> usize {
        self.colors_open.len()
    }
}

/// One rendered control, recorded each frame for the window's tests.
pub struct Rendered {
    pub id: String,
    pub control: String,
    pub label: String,
    pub enabled: bool,
    pub response: Response,
}

/// What an action control asked the window to do.
pub enum Outcome {
    None,
    /// `<section>.reset` was pressed.
    Reset(String),
    ImportTheme,
    ExportTheme,
    /// A path control's `Choose…` was pressed.
    ChoosePath(String),
}

/// The entry's value from the store's document, or its catalog default.
pub fn entry_value(values: &serde_json::Map<String, Value>, entry: &CatalogEntry) -> Value {
    values
        .get(&entry.id)
        .cloned()
        .unwrap_or_else(|| entry.default.clone())
}

/// The `depends` requirement of one entry: the other entry's stored value
/// (or its catalog default) must equal the required one. A missing other
/// entry or a missing `depends` never disables anything.
pub fn depends_holds(
    values: &serde_json::Map<String, Value>,
    catalog: &[CatalogEntry],
    entry: &CatalogEntry,
) -> bool {
    let Some(depends) = &entry.depends else {
        return true;
    };
    let Some(other) = catalog.iter().find(|candidate| candidate.id == depends.id) else {
        return true;
    };
    same_value(&entry_value(values, other), &depends.equals)
}

/// Value equality the way the core's typed values compare: JSON numbers
/// compare numerically (`1` and `1.0` are one number), everything else
/// structurally.
pub fn same_value(a: &Value, b: &Value) -> bool {
    match (a.as_f64(), b.as_f64()) {
        (Some(a), Some(b)) if a.is_finite() && b.is_finite() => a == b,
        _ => a == b,
    }
}

/// The plain text a stored value shows in a field or when it names no
/// listed option.
pub fn value_text(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::Bool(flag) => if *flag { "on" } else { "off" }.into(),
        Value::Number(number) => number
            .as_f64()
            .map(|number| {
                if number.fract() == 0. && number.abs() < 1e15 {
                    format!("{}", number as i64)
                } else {
                    format!("{number}")
                }
            })
            .unwrap_or_else(|| number.to_string()),
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

/// The reason a refusal shows, from the catalog's own bounds and options
/// (mirroring the macOS window's reasons).
pub fn refusal_reason(error: &SetError, entry: &CatalogEntry) -> String {
    let unit = entry
        .range
        .as_ref()
        .and_then(|range| range.unit.clone())
        .filter(|unit| !unit.is_empty())
        .map(|unit| format!(" {unit}"))
        .unwrap_or_default();
    let number = |value: f64| {
        if value.fract() == 0. && value.abs() < 1e15 {
            format!("{}", value as i64)
        } else {
            format!("{value}")
        }
    };
    match error {
        SetError::UnknownId => "Unknown setting.".into(),
        SetError::RequestTooLarge | SetError::UnparsableRequest => "Enter a number.".into(),
        SetError::WrongType => match entry.control.as_str() {
            "integer" => "Enter a whole number.".into(),
            "decimal" | "duration" => "Enter a number.".into(),
            "choice" | "segmented" | "source" => "Choose one of the options.".into(),
            _ => "The value has the wrong shape for this setting.".into(),
        },
        SetError::OutOfRange { min, max } => {
            format!("Between {}{unit} and {}{unit}.", number(*min), number(*max))
        }
        SetError::NotAnOption => "Choose one of the listed options.".into(),
        SetError::DependencyNotMet => "Another setting must change first.".into(),
        SetError::InvalidDocument => {
            "The settings document did not load; replace it before saving.".into()
        }
        SetError::Transport => "The value could not be saved.".into(),
    }
}

/// Store one edit through the window's apply path, recording the refusal's
/// reason on the entry and clearing any earlier one on success.
fn apply(
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
    fields: &mut Fields,
    entry: &CatalogEntry,
    value: Value,
) -> Result<(), SetError> {
    match set(&entry.id, value) {
        Ok(()) => {
            fields.errors.remove(&entry.id);
            Ok(())
        }
        Err(error) => {
            fields
                .errors
                .insert(entry.id.clone(), refusal_reason(&error, entry));
            Err(error)
        }
    }
}

/// The sized, keyboard-focusable region custom controls are built on.
/// Disabled controls keep their size but take no interaction and never
/// join the focus walk.
fn region(ui: &mut egui::Ui, size: Vec2, enabled: bool) -> (Rect, Response) {
    if enabled {
        ui.allocate_exact_size(size, Sense::click())
    } else {
        ui.add_enabled_ui(false, |ui| ui.allocate_exact_size(size, Sense::click()))
            .inner
    }
}

/// Paint a control's rim — the strong 3:1 border, the danger colour while
/// the entry shows a reason (and nothing else turns red), Carolina while
/// focused — plus the 2 px halo.
fn rim(ui: &mut egui::Ui, rect: Rect, radius: u8, dark: bool, danger: bool, focused: bool) {
    ui.painter().rect_stroke(
        rect,
        CornerRadius::same(radius),
        settings_style::rim_stroke(dark, danger, focused),
        egui::StrokeKind::Middle,
    );
    if focused {
        settings_style::paint_focus_halo(ui.painter(), rect, radius);
    }
}

fn rendered(entry: &CatalogEntry, control: &str, enabled: bool, response: Response) -> Rendered {
    Rendered {
        id: entry.id.clone(),
        control: control.to_owned(),
        label: entry.label.clone(),
        enabled,
        response,
    }
}

/// Lay one entry out as the macOS window does: the label on the left and
/// the control right-aligned in one column, the reason — dot and mono
/// text — inside its row below; action buttons align with the label
/// column (fix V8), and the order list spans below its label.
#[allow(clippy::too_many_arguments)]
pub fn entry_row(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    fields: &mut Fields,
    sources: &dyn SourceProvider,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> (Rendered, Outcome) {
    let control = entry.control.as_str();
    if control == "action" {
        return show(ui, dark, entry, value, enabled, fields, sources, set);
    }
    if control == "order" {
        row_label(ui, entry, dark, enabled);
        return show(ui, dark, entry, value, enabled, fields, sources, set);
    }
    let reason = fields.errors.get(&entry.id).cloned();
    let mut rendered: Option<(Rendered, Outcome)> = None;
    ui.vertical(|ui| {
        let inner = ui
            .horizontal(|ui| {
                ui.set_min_height(30.);
                show(ui, dark, entry, value, enabled, fields, sources, set)
            })
            .inner;
        if let Some(reason) = reason {
            reason_line(ui, dark, &reason);
        }
        rendered = Some(inner);
    });
    rendered.expect("the row always renders")
}

fn row_label(ui: &mut egui::Ui, entry: &CatalogEntry, dark: bool, enabled: bool) {
    let color = if enabled {
        aether7b::text_main(dark)
    } else {
        aether7b::text_muted(dark)
    };
    let label = ui.add(
        egui::Label::new(
            egui::RichText::new(entry.label.clone())
                .font(settings_style::sans(aether7b::TYPE_SM.0))
                .color(color),
        )
        .wrap(),
    );
    if let Some(help) = &entry.help {
        label.on_hover_text(help);
    }
}

/// The danger reason line a refused entry shows: a 7 pt danger dot and the
/// mono reason, laid out inside the entry's row (the mockup's status dot).
fn reason_line(ui: &mut egui::Ui, dark: bool, reason: &str) {
    ui.horizontal(|ui| {
        let (rect, _) = ui.allocate_exact_size(Vec2::splat(7.), Sense::hover());
        ui.painter().rect_filled(
            rect,
            settings_style::pill(rect.size()),
            aether7b::status_danger(dark),
        );
        ui.label(
            egui::RichText::new(reason)
                .font(settings_style::mono(aether7b::TYPE_XS.0))
                .color(aether7b::status_danger(dark)),
        );
    });
}

/// The control dispatch.
#[allow(clippy::too_many_arguments)]
fn show(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    fields: &mut Fields,
    sources: &dyn SourceProvider,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> (Rendered, Outcome) {
    let danger = fields.errors.contains_key(&entry.id);
    let control = entry.control.as_str();
    match control {
        "toggle" => (
            toggle(ui, dark, entry, value, enabled, danger, fields, set),
            Outcome::None,
        ),
        "choice" => (
            choice(ui, dark, entry, value, enabled, danger, fields, set),
            Outcome::None,
        ),
        "segmented" => (
            segmented(ui, dark, entry, value, enabled, danger, fields, set),
            Outcome::None,
        ),
        "integer" | "decimal" | "duration" => (
            number(ui, dark, entry, value, enabled, danger, fields, set),
            Outcome::None,
        ),
        "color" => (
            color(ui, dark, entry, value, enabled, danger, fields, set),
            Outcome::None,
        ),
        "path" => {
            let (render, choose) = path(ui, dark, entry, value, enabled, danger, fields, set);
            (
                render,
                if choose {
                    Outcome::ChoosePath(entry.id.clone())
                } else {
                    Outcome::None
                },
            )
        }
        "text" => (
            text(ui, dark, entry, value, enabled, danger, fields, set),
            Outcome::None,
        ),
        "source" => (
            source(
                ui, dark, entry, value, enabled, danger, fields, sources, set,
            ),
            Outcome::None,
        ),
        "order" => (
            order(ui, dark, entry, value, enabled, fields, set),
            Outcome::None,
        ),
        "action" => {
            let (render, clicked) = action(ui, dark, entry, enabled);
            (
                render,
                if clicked {
                    action_outcome(entry)
                } else {
                    Outcome::None
                },
            )
        }
        other => unreachable!("the shared catalog defines the control kinds: {other}"),
    }
}

fn action_outcome(entry: &CatalogEntry) -> Outcome {
    if entry.id.ends_with(".reset") {
        Outcome::Reset(entry.section.clone())
    } else if entry.id == "themes.import" {
        Outcome::ImportTheme
    } else if entry.id == "themes.export" {
        Outcome::ExportTheme
    } else {
        Outcome::None
    }
}

// MARK: Toggle

/// The mockup's pill toggle: a 34×20 track on the strong rim, knob 14 pt,
/// both corners the CSS-clamped pill. Mouse, keyboard (Space/Enter) and
/// AccessKit activation all take the one `clicked()` path egui synthesizes
/// for enabled, focusable widgets.
#[allow(clippy::too_many_arguments)]
fn toggle(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    danger: bool,
    fields: &mut Fields,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> Rendered {
    let on = value.as_bool().unwrap_or_default();
    let (rect, response) = region(ui, Vec2::new(50., 24.), enabled);
    let focused = response.has_focus() && enabled;
    rim(ui, rect, aether7b::RADIUS_MD as u8, dark, danger, focused);
    let track = Rect::from_min_size(
        egui::pos2(rect.min.x + aether7b::SPACE_S2, rect.min.y + 2.),
        Vec2::new(34., 20.),
    );
    let (fill, stroke) = if on {
        (
            aether7b::accent_fill(dark),
            egui::Stroke::new(1., aether7b::brand_ice_specular()),
        )
    } else {
        (
            aether7b::surface_card(dark),
            egui::Stroke::new(1., aether7b::border_strong(dark)),
        )
    };
    ui.painter()
        .rect_filled(track, settings_style::pill(track.size()), fill);
    ui.painter().rect_stroke(
        track,
        settings_style::pill(track.size()),
        stroke,
        egui::StrokeKind::Middle,
    );
    let knob = Vec2::splat(14.);
    let knob_rect = Rect::from_min_size(
        egui::pos2(
            track.min.x + if on { track.width() - 2. - knob.x } else { 2. },
            track.center().y - knob.y / 2.,
        ),
        knob,
    );
    let knob_color = if on {
        aether7b::brand_obsidian()
    } else {
        aether7b::text_muted(dark)
    };
    ui.painter()
        .rect_filled(knob_rect, settings_style::pill(knob), knob_color);
    if response.clicked() {
        // A click also takes keyboard focus — the macOS window's controls
        // become first responder on click, so the halo follows.
        response.request_focus();
        let _ = apply(set, fields, entry, json!(!on));
    }
    response.widget_info(|| {
        egui::WidgetInfo::labeled(egui::accesskit::Role::CheckBox, enabled, &entry.label)
    });
    ui.ctx().accesskit_node_builder(response.id, |node| {
        node.set_value(if on { "checked" } else { "unchecked" });
    });
    rendered(entry, "toggle", enabled, response)
}

// MARK: Choice and source

/// A choice menu inside the rim: mono type, token text. Selection is by
/// value — the stored value names its option, and a stored value outside
/// the list still shows itself rather than jumping to an index.
#[allow(clippy::too_many_arguments)]
fn choice(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    danger: bool,
    fields: &mut Fields,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> Rendered {
    let options = entry.options.as_deref().unwrap_or_default();
    let selected = options
        .iter()
        .find(|option| same_value(&option.value, value))
        .map(|option| option.label.clone());
    let text = selected.unwrap_or_else(|| value_text(value));
    let mut response = None;
    ui.add_enabled_ui(enabled, |ui| {
        ui.scope(|ui| {
            ui.style_mut().visuals.widgets.inactive.bg_stroke =
                settings_style::rim_stroke(dark, danger, false);
            ui.style_mut().visuals.widgets.hovered.bg_stroke =
                settings_style::rim_stroke(dark, danger, false);
            ui.style_mut().text_styles.insert(
                egui::TextStyle::Button,
                settings_style::mono(aether7b::TYPE_SM.0),
            );
            let combo = egui::ComboBox::from_id_salt(&entry.id)
                .selected_text(text.clone())
                .width(160.)
                .show_ui(ui, |ui| {
                    for option in options {
                        let is_selected = same_value(&option.value, value);
                        if ui
                            .selectable_label(is_selected, option.label.clone())
                            .clicked()
                        {
                            let _ = apply(set, fields, entry, option.value.clone());
                        }
                    }
                });
            response = Some(combo.response);
        });
    });
    let response = response.expect("the combo always reports");
    if response.has_focus() && enabled {
        settings_style::paint_focus_halo(ui.painter(), response.rect, aether7b::RADIUS_MD as u8);
    }
    response.widget_info(|| {
        egui::WidgetInfo::labeled(egui::accesskit::Role::ComboBox, enabled, &entry.label)
    });
    ui.ctx()
        .accesskit_node_builder(response.id, |node| node.set_value(text));
    rendered(entry, "choice", enabled, response)
}

/// A source picker: the provider's options for the entry's `source` kind
/// with a none/automatic first option. Selection is by value, never by
/// index (lesson c): a stored source that is not currently offered still
/// shows itself as `Unavailable: …` and stays selected.
#[allow(clippy::too_many_arguments)]
fn source(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    danger: bool,
    fields: &mut Fields,
    sources: &dyn SourceProvider,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> Rendered {
    let kind = entry.source.clone().unwrap_or_default();
    let options = sources.options(&kind);
    let current = value.as_str().unwrap_or_default().to_owned();
    let none_label = if kind == "temperature" {
        "None"
    } else {
        "Automatic"
    };
    let text = if current.is_empty() {
        none_label.to_owned()
    } else {
        options
            .iter()
            .find(|option| option.id == current)
            .map(|option| option.label.clone())
            .unwrap_or_else(|| format!("Unavailable: {current}"))
    };
    let mut response = None;
    ui.add_enabled_ui(enabled, |ui| {
        ui.scope(|ui| {
            ui.style_mut().visuals.widgets.inactive.bg_stroke =
                settings_style::rim_stroke(dark, danger, false);
            ui.style_mut().visuals.widgets.hovered.bg_stroke =
                settings_style::rim_stroke(dark, danger, false);
            ui.style_mut().visuals.widgets.active.bg_stroke =
                settings_style::rim_stroke(dark, danger, false);
            ui.style_mut().text_styles.insert(
                egui::TextStyle::Button,
                settings_style::mono(aether7b::TYPE_SM.0),
            );
            let combo = egui::ComboBox::from_id_salt(&entry.id)
                .selected_text(text.clone())
                .width(240.)
                .show_ui(ui, |ui| {
                    if ui
                        .selectable_label(current.is_empty(), none_label)
                        .clicked()
                    {
                        let _ = apply(set, fields, entry, Value::Null);
                    }
                    for option in &options {
                        if ui
                            .selectable_label(option.id == current, option.label.clone())
                            .clicked()
                        {
                            let _ = apply(set, fields, entry, json!(option.id));
                        }
                    }
                });
            response = Some(combo.response);
        });
    });
    let response = response.expect("the source combo always reports");
    if response.has_focus() && enabled {
        settings_style::paint_focus_halo(ui.painter(), response.rect, aether7b::RADIUS_MD as u8);
    }
    response.widget_info(|| {
        egui::WidgetInfo::labeled(egui::accesskit::Role::ComboBox, enabled, &entry.label)
    });
    ui.ctx()
        .accesskit_node_builder(response.id, |node| node.set_value(text));
    rendered(entry, "source", enabled, response)
}

// MARK: Segmented

/// The mockup's segmented control: one flat button per option, the selected
/// one on the accent tint with accent text, in a shared rim.
#[allow(clippy::too_many_arguments)]
fn segmented(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    danger: bool,
    fields: &mut Fields,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> Rendered {
    let options = entry.options.as_deref().unwrap_or_default();
    let mut responses = Vec::new();
    let mut bounds: Option<Rect> = None;
    ui.horizontal(|ui| {
        for option in options {
            let selected = same_value(&option.value, value);
            let text = if selected {
                aether7b::accent_active(dark)
            } else {
                aether7b::text_muted(dark)
            };
            let galley = ui.painter().layout_no_wrap(
                option.label.clone(),
                settings_style::sans(aether7b::TYPE_XS.0),
                text,
            );
            let size = galley.size() + Vec2::new(2. * aether7b::SPACE_S3, 2. * aether7b::SPACE_S1);
            let (rect, response) = region(ui, size, enabled);
            if selected {
                ui.painter().rect_filled(
                    rect,
                    CornerRadius::same(aether7b::RADIUS_SM as u8),
                    aether7b::accent_tint(dark),
                );
            }
            ui.painter().add(egui::epaint::TextShape::new(
                egui::pos2(
                    rect.center().x - galley.size().x / 2.,
                    rect.center().y - galley.size().y / 2.,
                ),
                galley,
                text,
            ));
            if response.has_focus() && enabled {
                settings_style::paint_focus_halo(ui.painter(), rect, aether7b::RADIUS_SM as u8);
            }
            if response.clicked() {
                response.request_focus();
                let _ = apply(set, fields, entry, option.value.clone());
            }
            response.widget_info(|| {
                egui::WidgetInfo::labeled(
                    egui::accesskit::Role::Button,
                    enabled,
                    format!("{}: {}", entry.label, option.label),
                )
            });
            bounds = Some(bounds.map_or(rect, |bounds: Rect| bounds.union(rect)));
            responses.push(response);
        }
    });
    let bounds = bounds.expect("a segmented control has options");
    rim(ui, bounds, aether7b::RADIUS_SM as u8, dark, danger, false);
    let response = responses
        .first()
        .expect("a segmented control has options")
        .clone();
    rendered(entry, "segmented", enabled, response)
}

// MARK: Number (integer, decimal, duration)

/// The largest dividing unit a stored bytes/s value presents in: a unit
/// divides the value exactly, and the largest such unit wins.
fn scale_unit(bytes: i64) -> usize {
    for (index, (_, multiplier)) in SCALE_UNITS.iter().enumerate().rev() {
        if bytes >= *multiplier && bytes % multiplier == 0 {
            return index;
        }
    }
    0
}

fn field_text(bytes: i64, multiplier: i64) -> String {
    if multiplier <= 1 {
        format!("{bytes}")
    } else {
        let value = bytes as f64 / multiplier as f64;
        if value.fract() == 0. && value.abs() < 1e15 {
            format!("{}", value as i64)
        } else {
            format!("{value}")
        }
    }
}

/// One range bound as the mockup prints plain numbers: whole numbers
/// without their decimal point (the macOS window's `format`).
fn number_text(value: f64) -> String {
    if value.fract() == 0. && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        format!("{value}")
    }
}

/// A duration bound with its unit ("200 ms – 10 s"); a missing unit is
/// seconds, like the macOS window's `durationText`.
fn range_text(value: f64, unit: &str) -> String {
    let number = number_text(value);
    match unit {
        "" | "s" => format!("{number} s"),
        "min" => format!("{number} min"),
        other => format!("{number} {other}"),
    }
}

/// The text a stored value presents in a number field; a bytes/s entry
/// presents in its chosen unit, recording the exact bytes it stands for.
fn presented_text(entry: &CatalogEntry, value: &Value, fields: &mut Fields) -> String {
    let stored_in_bytes = entry
        .range
        .as_ref()
        .is_some_and(|range| range.unit.as_deref() == Some("bytes/s"));
    if stored_in_bytes {
        let bytes = value.as_i64().unwrap_or_default();
        fields.bytes.insert(entry.id.clone(), bytes);
        let index = *fields
            .units
            .entry(entry.id.clone())
            .or_insert(scale_unit(bytes));
        let multiplier = SCALE_UNITS
            .get(index)
            .map(|(_, multiplier)| *multiplier)
            .unwrap_or(1);
        field_text(bytes, multiplier)
    } else {
        value_text(value)
    }
}

/// A number or duration field with its unit and range shown, a bytes/s unit
/// selector where the entry is stored in bytes/s, and a slider when the
/// catalog gives a step. Malformed text is refused before submission — the
/// store is never offered a phantom default, and the field keeps what the
/// user typed (lesson a). The bytes/s value is held exactly, independently
/// of the displayed text, and every conversion is checked (lesson g).
#[allow(clippy::too_many_arguments)]
fn number(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    danger: bool,
    fields: &mut Fields,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> Rendered {
    let range = entry.range.as_ref();
    let stored_in_bytes = range.is_some_and(|range| range.unit.as_deref() == Some("bytes/s"));
    let bounded = range.is_some_and(|range| range.max < UNBOUNDED_MAXIMUM);
    let control = entry.control.as_str();
    let presented = presented_text(entry, value, fields);
    let mut edit_response = None;
    ui.horizontal(|ui| {
        ui.add_enabled_ui(enabled, |ui| {
            let id = Id::unique(&entry.id).with(fields.generation(&entry.id));
            let focused = ui.ctx().memory(|m| m.has_focus(id));
            ui.scope(|ui| {
                ui.style_mut().visuals.widgets.inactive.bg_stroke =
                    settings_style::rim_stroke(dark, danger, focused);
                ui.style_mut().visuals.widgets.hovered.bg_stroke =
                    settings_style::rim_stroke(dark, danger, focused);
                ui.style_mut().visuals.widgets.active.bg_stroke =
                    settings_style::rim_stroke(dark, danger, focused);
                ui.style_mut().visuals.widgets.inactive.weak_bg_fill = aether7b::surface_card(dark);
                fields
                    .edits
                    .entry(entry.id.clone())
                    .or_insert_with(|| presented.clone());
                let edit = ui.add(
                    egui::TextEdit::singleline(
                        fields
                            .edits
                            .get_mut(&entry.id)
                            .expect("the buffer was just inserted"),
                    )
                    .id(id)
                    .font(settings_style::mono(aether7b::TYPE_SM.0))
                    .desired_width(72.)
                    .clip_text(true),
                );
                edit_response = Some(edit.clone());
                let enter = edit.has_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
                if enter || edit.lost_focus() {
                    submit_number(entry, fields, set, stored_in_bytes);
                }
            });
        });
        if stored_in_bytes {
            let index = *fields.units.entry(entry.id.clone()).or_insert(0);
            let selected = SCALE_UNITS
                .get(index)
                .map(|(label, _)| *label)
                .unwrap_or("bytes/s");
            let combo = egui::ComboBox::from_id_salt(format!("{}-unit", entry.id))
                .selected_text(selected)
                .width(72.)
                .show_ui(ui, |ui| {
                    for (unit_index, (label, _)) in SCALE_UNITS.iter().enumerate() {
                        if ui.selectable_label(index == unit_index, *label).clicked() {
                            fields.units.insert(entry.id.clone(), unit_index);
                            // The exact bytes never move; only the display
                            // changes, and nothing is submitted (lesson g).
                            fields.bump(&entry.id);
                        }
                    }
                });
            combo.response.widget_info(|| {
                egui::WidgetInfo::labeled(
                    egui::accesskit::Role::ComboBox,
                    enabled,
                    format!("{} unit", entry.label),
                )
            });
        } else if let Some(unit) = range
            .and_then(|range| range.unit.clone())
            .filter(|unit| !unit.is_empty())
        {
            ui.label(
                egui::RichText::new(unit)
                    .font(settings_style::mono(aether7b::TYPE_XS.0))
                    .color(aether7b::text_muted(dark)),
            );
        }
        if bounded {
            let range = range.expect("a bounded entry has a range");
            let unit = range.unit.clone().unwrap_or_default();
            // The mockup's "N – N": a duration carries its units into the
            // text ("0.2 s – 10 s"); every other control shows plain
            // numbers, its unit already standing beside the field.
            let (min, max) = if control == "duration" {
                (range_text(range.min, &unit), range_text(range.max, &unit))
            } else {
                (number_text(range.min), number_text(range.max))
            };
            ui.label(
                egui::RichText::new(format!("{min} – {max}"))
                    .font(settings_style::sans(aether7b::TYPE_XS.0))
                    .color(aether7b::text_muted(dark)),
            );
        }
        if let (Some(range), Some(step)) = (
            range.filter(|_| bounded),
            range.and_then(|range| range.step).filter(|step| *step > 0.),
        ) {
            let mut slider_value = value
                .as_f64()
                .unwrap_or_default()
                .clamp(range.min, range.max);
            let slider = ui.add(
                egui::Slider::new(&mut slider_value, range.min..=range.max)
                    .step_by(step)
                    .show_value(false),
            );
            if slider.changed() {
                let stepped = (slider_value / step).round() * step;
                let number = if control == "integer" {
                    json!(stepped.round() as i64)
                } else {
                    json!(stepped)
                };
                let _ = apply(set, fields, entry, number);
            }
        }
    });
    let edit_response = edit_response.expect("the number field always reports");
    if edit_response.has_focus() && enabled {
        settings_style::paint_focus_halo(
            ui.painter(),
            edit_response.rect,
            aether7b::RADIUS_MD as u8,
        );
    }
    edit_response.widget_info(|| {
        egui::WidgetInfo::labeled(egui::accesskit::Role::TextInput, enabled, &entry.label)
    });
    ui.ctx().accesskit_node_builder(edit_response.id, |node| {
        node.set_value(fields.edits.get(&entry.id).cloned().unwrap_or(presented));
    });
    rendered(entry, control, enabled, edit_response)
}

/// Parse the field's text and offer it to the store, or refuse it with the
/// danger reason and save nothing. Empty text stores the entry's null
/// default when it has one (the graph heights inherit); otherwise it is an
/// error, never a phantom default (lesson a).
fn submit_number(
    entry: &CatalogEntry,
    fields: &mut Fields,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
    stored_in_bytes: bool,
) {
    let text = fields
        .edits
        .get(&entry.id)
        .map(|text| text.trim().to_owned())
        .unwrap_or_default();
    let outcome = if text.is_empty() {
        if entry.default.is_null() {
            apply(set, fields, entry, Value::Null)
        } else {
            fields
                .errors
                .insert(entry.id.clone(), "Enter a number.".into());
            Err(SetError::UnparsableRequest)
        }
    } else if stored_in_bytes {
        let multiplier = fields
            .units
            .get(&entry.id)
            .and_then(|index| SCALE_UNITS.get(*index))
            .map(|(_, multiplier)| *multiplier)
            .unwrap_or(1);
        match text.parse::<f64>() {
            Ok(display) if display.is_finite() => {
                let scaled = display * multiplier as f64;
                if !scaled.is_finite() || scaled.fract() != 0. {
                    fields.errors.insert(
                        entry.id.clone(),
                        "Enter a whole number of bytes per second.".into(),
                    );
                    Err(SetError::UnparsableRequest)
                } else if scaled.abs() < 9_007_199_254_740_990.0 {
                    let bytes = scaled as i64;
                    fields.bytes.insert(entry.id.clone(), bytes);
                    apply(set, fields, entry, json!(bytes))
                } else {
                    fields
                        .errors
                        .insert(entry.id.clone(), "The value is too large.".into());
                    Err(SetError::OutOfRange {
                        min: 0.,
                        max: UNBOUNDED_MAXIMUM,
                    })
                }
            }
            _ => {
                fields
                    .errors
                    .insert(entry.id.clone(), "Enter a number.".into());
                Err(SetError::UnparsableRequest)
            }
        }
    } else {
        match entry.control.as_str() {
            "integer" => match text.parse::<i64>() {
                Ok(number) => apply(set, fields, entry, json!(number)),
                Err(_) => {
                    fields
                        .errors
                        .insert(entry.id.clone(), "Enter a whole number.".into());
                    Err(SetError::UnparsableRequest)
                }
            },
            _ => match text.parse::<f64>() {
                Ok(number) if number.is_finite() => apply(set, fields, entry, json!(number)),
                _ => {
                    fields
                        .errors
                        .insert(entry.id.clone(), "Enter a number.".into());
                    Err(SetError::UnparsableRequest)
                }
            },
        }
    };
    if outcome.is_ok() {
        fields.edits.remove(&entry.id);
        fields.bump(&entry.id);
    }
}

// MARK: Colour

fn color_description(stored: Option<[f64; 4]>) -> String {
    match stored {
        None => "Inherited".into(),
        Some(rgba) => {
            let hex = format!(
                "#{:02X}{:02X}{:02X}",
                (rgba[0] * 255.).round() as u8,
                (rgba[1] * 255.).round() as u8,
                (rgba[2] * 255.).round() as u8
            );
            let opacity = (rgba[3] * 100.).round() as u8;
            format!("{hex}, {opacity}% opacity")
        }
    }
}

/// A colour well with its own token-styled editor and an "Inherit"
/// affordance (lesson e): pressing Inherit stores `null` — the unset value
/// the palette inherits from — without resetting any unrelated setting.
/// An explicit transparent colour is an override with its own hex and
/// opacity, never inheritance.
#[allow(clippy::too_many_arguments)]
fn color(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    danger: bool,
    fields: &mut Fields,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> Rendered {
    let stored: Option<[f64; 4]> = value.as_array().and_then(|rgba| {
        let rgba: Vec<f64> = rgba.iter().filter_map(Value::as_f64).collect();
        (rgba.len() == 4).then(|| [rgba[0], rgba[1], rgba[2], rgba[3]])
    });
    let mut well = None;
    ui.horizontal(|ui| {
        let (rect, response) = region(ui, Vec2::new(44., 22.), enabled);
        let swatch = stored.map(|rgba| {
            egui::Color32::from_rgba_unmultiplied(
                (rgba[0] * 255.) as u8,
                (rgba[1] * 255.) as u8,
                (rgba[2] * 255.) as u8,
                (rgba[3] * 255.) as u8,
            )
        });
        ui.painter().rect_filled(
            rect.shrink(1.),
            CornerRadius::same(aether7b::RADIUS_SM as u8),
            swatch.unwrap_or(aether7b::surface_code(dark)),
        );
        rim(
            ui,
            rect,
            aether7b::RADIUS_SM as u8,
            dark,
            danger,
            response.has_focus() && enabled,
        );
        if response.clicked() {
            response.request_focus();
            fields.colors_open.insert(entry.id.clone());
        }
        response.widget_info(|| {
            egui::WidgetInfo::labeled(egui::accesskit::Role::ColorWell, enabled, &entry.label)
        });
        ui.ctx().accesskit_node_builder(response.id, |node| {
            node.set_value(color_description(stored));
        });
        well = Some(response.clone());
        let inherit = settings_style::ghost_button(ui, "Inherit", enabled, dark);
        if inherit.clicked() {
            fields.colors_open.remove(&entry.id);
            let _ = apply(set, fields, entry, Value::Null);
        }
        inherit.widget_info(|| {
            egui::WidgetInfo::labeled(
                egui::accesskit::Role::Button,
                enabled,
                format!("Inherit the default {}", entry.label),
            )
        });
        let was_open = fields.colors_open.contains(&entry.id);
        let mut open = was_open && enabled;
        egui::Popup::from_response(&response)
            .open_bool(&mut open)
            .show(|ui| {
                ui.set_width(220.);
                let mut rgba = stored.unwrap_or([0.2, 0.6, 1., 1.]);
                ui.label(
                    egui::RichText::new(color_description(Some(rgba)))
                        .font(settings_style::mono(aether7b::TYPE_XS.0))
                        .color(aether7b::text_muted(dark)),
                );
                for (index, name) in ["Red", "Green", "Blue", "Opacity"].into_iter().enumerate() {
                    let mut component = rgba[index] * 255.;
                    let slider = ui.add(
                        egui::Slider::new(&mut component, 0.0..=255.0)
                            .step_by(1.)
                            .show_value(true)
                            .text(name),
                    );
                    if slider.changed() {
                        rgba[index] = component / 255.;
                        let _ = apply(set, fields, entry, json!(rgba));
                    }
                }
            });
        if open != was_open {
            if open {
                fields.colors_open.insert(entry.id.clone());
            } else {
                fields.colors_open.remove(&entry.id);
            }
        }
    });
    let response = well.expect("the colour well always reports");
    rendered(entry, "color", enabled, response)
}

// MARK: Path and text

/// A mono editable field on the strong rim, submitting on Enter or when
/// focus leaves (the macOS field's action).
#[allow(clippy::too_many_arguments)]
fn field(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    presented: &str,
    enabled: bool,
    danger: bool,
    fields: &mut Fields,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
    width: f32,
) -> Response {
    let mut response = None;
    ui.add_enabled_ui(enabled, |ui| {
        let id = Id::unique(&entry.id).with(fields.generation(&entry.id));
        let focused = ui.ctx().memory(|m| m.has_focus(id));
        ui.scope(|ui| {
            ui.style_mut().visuals.widgets.inactive.bg_stroke =
                settings_style::rim_stroke(dark, danger, focused);
            ui.style_mut().visuals.widgets.hovered.bg_stroke =
                settings_style::rim_stroke(dark, danger, focused);
            ui.style_mut().visuals.widgets.active.bg_stroke =
                settings_style::rim_stroke(dark, danger, focused);
            ui.style_mut().visuals.widgets.inactive.weak_bg_fill = aether7b::surface_card(dark);
            fields
                .edits
                .entry(entry.id.clone())
                .or_insert_with(|| presented.to_owned());
            let edit = ui.add(
                egui::TextEdit::singleline(
                    fields
                        .edits
                        .get_mut(&entry.id)
                        .expect("the buffer was just inserted"),
                )
                .id(id)
                .font(settings_style::mono(aether7b::TYPE_SM.0))
                .desired_width(width)
                .clip_text(true),
            );
            response = Some(edit);
        });
    });
    let response = response.expect("the field always reports");
    let enter = response.has_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
    if enter || response.lost_focus() {
        let text = fields
            .edits
            .get(&entry.id)
            .cloned()
            .map(|text| text.trim().to_owned())
            .unwrap_or_else(|| presented.to_owned());
        let value = if text.is_empty() && entry.default.is_null() {
            Value::Null
        } else {
            json!(text)
        };
        if apply(set, fields, entry, value).is_ok() {
            fields.edits.remove(&entry.id);
            fields.bump(&entry.id);
        }
    }
    if response.has_focus() && enabled {
        settings_style::paint_focus_halo(ui.painter(), response.rect, aether7b::RADIUS_MD as u8);
    }
    response.widget_info(|| {
        egui::WidgetInfo::labeled(egui::accesskit::Role::TextInput, enabled, &entry.label)
    });
    ui.ctx().accesskit_node_builder(response.id, |node| {
        node.set_value(
            fields
                .edits
                .get(&entry.id)
                .cloned()
                .unwrap_or_else(|| presented.to_owned()),
        );
    });
    response
}

/// A path field: typed paths, empty uses the default location, and the
/// `Choose…` button asks the window for the chooser.
#[allow(clippy::too_many_arguments)]
fn path(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    danger: bool,
    fields: &mut Fields,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> (Rendered, bool) {
    let presented = value.as_str().unwrap_or_default().to_owned();
    let mut response = None;
    let mut choose = false;
    ui.horizontal(|ui| {
        response = Some(field(
            ui, dark, entry, &presented, enabled, danger, fields, set, 180.,
        ));
        let chooser = settings_style::ghost_button(ui, "Choose…", enabled, dark);
        chooser.widget_info(|| {
            egui::WidgetInfo::labeled(
                egui::accesskit::Role::Button,
                enabled,
                format!("Choose {}", entry.label),
            )
        });
        choose = chooser.clicked();
    });
    (
        rendered(
            entry,
            "path",
            enabled,
            response.expect("the path field always reports"),
        ),
        choose,
    )
}

#[allow(clippy::too_many_arguments)]
fn text(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    danger: bool,
    fields: &mut Fields,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> Rendered {
    let presented = value.as_str().unwrap_or_default().to_owned();
    let response = field(
        ui, dark, entry, &presented, enabled, danger, fields, set, 150.,
    );
    rendered(entry, "text", enabled, response)
}

// MARK: Order

/// The graph ids' display names — the same names the macOS window's list
/// shows (XRGGraphID.name).
pub fn graph_name(id: &str) -> String {
    match id {
        "cpu" => "CPU".into(),
        "gpu" => "GPU".into(),
        "npu" => "NPU".into(),
        "vram" => "VRAM".into(),
        "ai" => "AI Tokens".into(),
        other => {
            let mut characters = other.chars();
            match characters.next() {
                Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
                None => String::new(),
            }
        }
    }
}

/// The reorderable graph list (lesson g): one row per graph, named in one
/// aligned column (W2), with keyboard-operable Move up / Move down buttons
/// writing the existing `order` setting. A move preserves keyboard focus on
/// the moved graph's button — following to the enabled opposite-direction
/// button at an endpoint — and the endpoint rows' outward buttons are
/// disabled (lesson d).
#[allow(clippy::too_many_arguments)]
fn order(
    ui: &mut egui::Ui,
    dark: bool,
    entry: &CatalogEntry,
    value: &Value,
    enabled: bool,
    fields: &mut Fields,
    set: &mut dyn FnMut(&str, Value) -> Result<(), SetError>,
) -> Rendered {
    let list: Vec<String> = value
        .as_str()
        .unwrap_or_else(|| entry.default.as_str().unwrap_or_default())
        .split(',')
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .collect();
    let galleys: Vec<_> = list
        .iter()
        .map(|id| {
            ui.painter().layout_no_wrap(
                graph_name(id),
                settings_style::sans(aether7b::TYPE_SM.0),
                aether7b::text_main(dark),
            )
        })
        .collect();
    let name_width = galleys
        .iter()
        .map(|galley| galley.size().x)
        .fold(0., f32::max)
        + 4. * aether7b::SPACE_S2;
    let mut first_response = None;
    let pending = fields.order_focus.take();
    let mut next_focus: Option<(String, bool)> = None;
    ui.vertical(|ui| {
        for (index, id) in list.iter().enumerate() {
            let mut moved = None;
            let mut focus_here = None;
            ui.push_id(id, |ui| {
                ui.horizontal(|ui| {
                    let (name_rect, name_response) = ui.allocate_exact_size(
                        Vec2::new(name_width, galleys[index].size().y),
                        Sense::hover(),
                    );
                    ui.painter().add(egui::epaint::TextShape::new(
                        name_rect.min,
                        galleys[index].clone(),
                        aether7b::text_main(dark),
                    ));
                    // The row's name is the list's content: announce it as
                    // text, the same role a plain label carries.
                    name_response.widget_info(|| {
                        egui::WidgetInfo::labeled(
                            egui::accesskit::Role::Label,
                            enabled,
                            graph_name(id),
                        )
                    });
                    let up_allowed = enabled && index > 0;
                    let down_allowed = enabled && index + 1 < list.len();
                    let up = move_button(ui, id, true, up_allowed, dark);
                    let down = move_button(ui, id, false, down_allowed, dark);
                    if up.clicked() {
                        up.request_focus();
                        moved = Some((index, index - 1, true));
                    }
                    if down.clicked() {
                        down.request_focus();
                        moved = Some((index, index + 1, false));
                    }
                    if first_response.is_none() {
                        first_response = Some(up.clone());
                    }
                    // Focus stays on the moved graph (lesson d): its own
                    // direction button when the move keeps it enabled, the
                    // opposite one at an endpoint.
                    if let Some((_, up_pressed)) = pending
                        .as_ref()
                        .filter(|(target, _)| target == id)
                        .map(|(target, up)| (target.clone(), *up))
                    {
                        let at_start = index == 0;
                        let at_end = index + 1 == list.len();
                        // Moving up from the first row keeps the focus on
                        // its own (enabled) down button, and moving down
                        // from the last row on its up — the follow-the-move
                        // rule at the endpoints.
                        let target = if up_pressed {
                            if at_start { &down } else { &up }
                        } else if at_end {
                            &up
                        } else {
                            &down
                        };
                        focus_here = Some(target.id);
                    }
                });
            });
            if let Some(target) = focus_here {
                ui.ctx().memory_mut(|m| m.request_focus(target));
            }
            if let Some((from, to, up_pressed)) = moved {
                let mut moved_list = list.clone();
                moved_list.swap(from, to);
                if apply(set, fields, entry, json!(moved_list.join(","))).is_ok() {
                    next_focus = Some((moved_list[to].clone(), up_pressed));
                }
            }
        }
    });
    fields.order_focus = next_focus;
    let response = first_response.expect("an order list has rows");
    rendered(entry, "order", enabled, response)
}

/// One Move button: a ghost button whose widget id is stable across a
/// rebuild (its graph and direction), so focus survives the move.
fn move_button(ui: &mut egui::Ui, id: &str, up: bool, enabled: bool, dark: bool) -> Response {
    let (label, direction) = if up {
        ("Move up", "up")
    } else {
        ("Move down", "down")
    };
    let font = settings_style::sans(aether7b::TYPE_XS.0);
    let color = if enabled {
        aether7b::text_main(dark)
    } else {
        aether7b::text_muted(dark)
    };
    let galley = ui.painter().layout_no_wrap(label.to_owned(), font, color);
    let size = galley.size() + Vec2::new(2. * aether7b::SPACE_S3, 2. * aether7b::SPACE_S1);
    let (rect, _) = ui.allocate_exact_size(size, Sense::hover());
    let widget = ui.scope_id().with(("order", id, direction));
    let response = if enabled {
        ui.interact(rect, widget, Sense::click())
    } else {
        ui.add_enabled_ui(false, |ui| ui.interact(rect, widget, Sense::click()))
            .inner
    };
    let corner = CornerRadius::same(aether7b::RADIUS_SM as u8);
    let (fill, stroke) = if response.has_focus() {
        (
            aether7b::accent_tint(dark),
            egui::Stroke::new(1., settings_style::focus_border()),
        )
    } else if response.hovered() {
        (
            aether7b::accent_tint(dark),
            egui::Stroke::new(1., aether7b::border_strong(dark)),
        )
    } else {
        (
            egui::Color32::TRANSPARENT,
            egui::Stroke::new(1., aether7b::border_strong(dark)),
        )
    };
    ui.painter().rect_filled(rect, corner, fill);
    ui.painter()
        .rect_stroke(rect, corner, stroke, egui::StrokeKind::Middle);
    ui.painter().add(egui::epaint::TextShape::new(
        egui::pos2(
            rect.min.x + aether7b::SPACE_S3,
            rect.center().y - galley.size().y / 2.,
        ),
        galley,
        color,
    ));
    if response.has_focus() && enabled {
        settings_style::paint_focus_halo(ui.painter(), rect, aether7b::RADIUS_SM as u8);
    }
    response.widget_info(|| {
        egui::WidgetInfo::labeled(
            egui::accesskit::Role::Button,
            enabled,
            format!("Move {} {direction}", graph_name(id)),
        )
    });
    response
}

// MARK: Action

/// A ghost action button (spec §5): the entry's label is the button's
/// text — Reset section, Import theme, Export theme.
fn action(ui: &mut egui::Ui, dark: bool, entry: &CatalogEntry, enabled: bool) -> (Rendered, bool) {
    let response = settings_style::ghost_button(ui, &entry.label, enabled, dark);
    response.widget_info(|| {
        egui::WidgetInfo::labeled(egui::accesskit::Role::Button, enabled, &entry.label)
    });
    let clicked = response.clicked();
    (rendered(entry, "action", enabled, response), clicked)
}
