// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::{
    dashboard::Row,
    engine::Panel,
    graph::{self, Plot},
    settings::{GraphStyle, Module, Settings},
    shared::Theme,
    temperature::Units,
};
use eframe::egui::{self, Color32, FontId, Painter, Rect, Sense, Stroke, StrokeKind, pos2, vec2};
pub(super) fn color(v: [f64; 4]) -> Color32 {
    Color32::from_rgba_unmultiplied(
        (v[0] * 255.).round() as u8,
        (v[1] * 255.).round() as u8,
        (v[2] * 255.).round() as u8,
        (v[3] * 255.).round() as u8,
    )
}
pub(super) fn opaque(v: [f64; 4]) -> Color32 {
    color([v[0], v[1], v[2], 1.])
}
fn text(p: &Painter, text: &str, width: f32) -> std::sync::Arc<egui::Galley> {
    let mut job = egui::text::LayoutJob::simple_singleline(
        text.into(),
        FontId::proportional(11.),
        Color32::WHITE,
    );
    job.wrap.max_width = width.max(0.);
    job.wrap.max_rows = 1;
    job.wrap.break_anywhere = true;
    p.layout_job(job)
}
fn row(p: &Painter, r: &Row, rect: Rect, y: f32, units: Units, ink: Color32) {
    let right = r.right.render(units);
    let right = text(p, &right, (rect.width() - 6.) * 0.48);
    let rw = if right.is_empty() {
        0.
    } else {
        right.size().x + 5.
    };
    let left = text(p, &r.left, (rect.width() - 6. - rw).max(0.));
    p.galley_with_override_text_color(pos2(rect.left() + 3., y), left, ink);
    p.galley_with_override_text_color(pos2(rect.right() - 3. - right.size().x, y), right, ink);
}
pub(super) fn show(
    ui: &mut egui::Ui,
    size: egui::Vec2,
    theme: &Theme,
    module: Module,
    panel: Option<&Panel>,
    settings: &Settings,
    style: GraphStyle,
) -> egui::Response {
    // Keep keyboard/accessibility identity attached to the module after reordering.
    let (rect, _) = ui.allocate_exact_size(size, Sense::hover());
    let response = ui.interact(
        rect,
        ui.scope_id().with(("graph", module.index())),
        Sense::click(),
    );
    response.widget_info(|| {
        egui::WidgetInfo::labeled(
            egui::Role::Button,
            true,
            format!("{} graph", module.title()),
        )
    });
    let status = panel
        .map(|p| p.display_label(settings.temperature_units).into_owned())
        .unwrap_or_else(|| "Waiting for selected source".into());
    ui.ctx().accesskit_node_builder(response.id, |node| {
        node.set_description(format!(
            "{status}. Activate for live details. Shift+F10 for graph options."
        ));
    });
    if response.gained_focus() {
        super::diagnostics::focus(&response, &format!("{} graph", module.title()));
        response.scroll_to_me(None);
    }
    if !ui.is_rect_visible(rect) {
        return response;
    }
    let p = ui.painter_at(rect);
    p.rect_filled(rect, 0., opaque(theme.colors[0]));
    p.rect_filled(rect, 0., color(theme.colors[1]));
    p.rect_stroke(
        rect,
        0.,
        Stroke::new(0.5, color(theme.colors[5])),
        StrokeKind::Inside,
    );
    let bars = &settings.activity_bars;
    let cores = bars.visible && panel.is_some_and(|p| !p.readout.cores.is_empty());
    let count = panel
        .filter(|_| bars.visible && !cores)
        .map_or(0, |p| p.series.len().min(3));
    let reserve = if count > 0 {
        count as f32 * 5. + 3.
    } else {
        0.
    };
    let face = Rect::from_min_max(rect.min, pos2(rect.right() - reserve, rect.bottom()));
    let units = panel.map_or(settings.temperature_units, |p| {
        p.scale.temperature_units(settings.temperature_units)
    });
    if let Some(panel) = panel {
        let (lower, upper) = panel.plot_bounds(0, settings.minimum_scale(module));
        let body = Rect::from_min_max(
            face.min,
            pos2(face.right(), face.bottom() - if cores { 18. } else { 0. }),
        );
        if let Some(meta) = &panel.weather_plot {
            let colors: Vec<_> = theme.colors[2..5].iter().copied().map(color).collect();
            let axes: Vec<_> = (0..panel.series.len())
                .map(|i| panel.plot_bounds(i, 0))
                .collect();
            graph::draw_positioned(
                &p,
                &panel.series,
                &colors,
                &meta.positions,
                &axes,
                body,
                style,
            );
        } else {
            graph::draw(
                &p,
                &panel.series,
                &theme.colors[2..5]
                    .iter()
                    .copied()
                    .map(color)
                    .collect::<Vec<_>>(),
                Plot {
                    rect: body,
                    lower,
                    upper,
                },
                style,
            );
        }
        for i in 0..count {
            let (lower, upper) = panel.plot_bounds(i, settings.minimum_scale(module));
            let r = Rect::from_min_max(
                pos2(face.right() + i as f32 * 5., rect.top() + 2.),
                pos2(face.right() + (i + 1) as f32 * 5. - 1., rect.bottom() - 2.),
            );
            graph::bar(
                &p,
                panel.series[i].last().copied(),
                Plot {
                    rect: r,
                    lower,
                    upper,
                },
                color(if bars.use_series_colors {
                    theme.colors[2 + i]
                } else {
                    bars.color
                }),
                color(theme.colors[5]),
                bars.style,
            );
        }
        if cores {
            let step = rect.width() / panel.readout.cores.len() as f32;
            for (i, (_, value)) in panel.readout.cores.iter().enumerate() {
                let left = rect.left() + i as f32 * step + 0.5;
                let r = Rect::from_min_max(
                    pos2(left, rect.bottom() - 17.5),
                    pos2(
                        (rect.left() + (i + 1) as f32 * step - 0.5).max(left + 0.5),
                        rect.bottom() - 1.,
                    ),
                );
                graph::bar(
                    &p,
                    *value,
                    Plot {
                        rect: r,
                        lower: 0.,
                        upper: 100.,
                    },
                    color(if bars.use_series_colors {
                        theme.colors[2]
                    } else {
                        bars.color
                    }),
                    color(theme.colors[5]),
                    bars.style,
                );
            }
        }
    }
    let ink = color(theme.colors[6]);
    if let Some(panel) = panel.filter(|p| !p.readout.top.is_empty()) {
        for (i, r) in panel.readout.top.iter().enumerate() {
            let y = rect.top() + 1. + i as f32 * 13.;
            if y > rect.bottom()
                - 14.
                - panel.readout.bottom.len() as f32 * 13.
                - if cores { 18. } else { 0. }
            {
                break;
            }
            row(&p, r, face, y, units, ink);
        }
        for (i, r) in panel.readout.bottom.iter().enumerate() {
            row(
                &p,
                r,
                face,
                rect.bottom() - 14. - (panel.readout.bottom.len() - 1 - i) as f32 * 13.,
                units,
                ink,
            );
        }
    } else {
        let title = panel
            .map_or(module.title(), |p| p.title)
            .split(" · ")
            .next()
            .unwrap_or(module.title());
        row(
            &p,
            &Row::new(if module == Module::Tpu { "NPU" } else { title }, ""),
            face,
            rect.top() + 1.,
            units,
            ink,
        );
        let label = panel
            .map(|p| p.display_label(units).into_owned())
            .unwrap_or_else(|| "Waiting for sample…".into());
        let label_rect = Rect::from_min_max(rect.min + vec2(3., 15.), rect.max - vec2(3., 3.));
        let galley = p.layout(label, FontId::proportional(11.), ink, label_rect.width());
        p.with_clip_rect(label_rect)
            .galley(label_rect.min, galley, ink);
    }
    if response.has_focus() {
        p.rect_stroke(
            rect.shrink(1.),
            0.,
            Stroke::new(1.5, ui.visuals().widgets.active.fg_stroke.color),
            StrokeKind::Inside,
        );
    }
    response
}
/// Mouse activation stays a double click; Enter, Space and AccessKit Click are
/// synthesized primary clicks and must use the same details action.
pub(super) fn details_requested(response: &egui::Response) -> bool {
    response.double_clicked()
        || (response.clicked() && !response.clicked_by(egui::PointerButton::Primary))
}
/// Pointer-fixed anchors require a pointer position; retain a graph-relative
/// anchor across frames when the menu was opened from the keyboard instead.
pub(super) fn context_menu(response: &egui::Response, module: Module) -> egui::Popup<'_> {
    let ctx = &response.ctx;
    let mut popup = egui::Popup::context_menu(response);
    let keyboard = popup.get_id().with("keyboard-anchor");
    if response.has_focus()
        && ctx.input_mut(|i| i.consume_key(egui::Modifiers::SHIFT, egui::Key::F10))
    {
        egui::Popup::open_id(ctx, popup.get_id());
        ctx.data_mut(|data| data.insert_temp(keyboard, true));
    } else if response.secondary_clicked() || !popup.is_open() {
        ctx.data_mut(|data| data.remove::<bool>(keyboard));
    }
    if ctx.data(|data| data.get_temp::<bool>(keyboard)) == Some(true) {
        popup = popup.at_position(response.rect.left_bottom());
    }
    popup.accessible_name(format!("{} graph options", module.title()))
}
#[cfg(test)]
#[path = "dashboard_tests.rs"]
mod tests;
