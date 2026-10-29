// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use eframe::egui::{self, Color32, FontId, Painter, Rect, Sense, Stroke, StrokeKind, pos2, vec2};
use xrg_ng_linux::{
    dashboard::Row,
    engine::Panel,
    graph::{self, Plot},
    settings::{GraphStyle, Module, Settings},
    shared::Theme,
    temperature::Units,
};
pub(super) fn color(v: [f64; 4]) -> Color32 {
    Color32::from_rgba_unmultiplied(
        (v[0] * 255.).round() as u8,
        (v[1] * 255.).round() as u8,
        (v[2] * 255.).round() as u8,
        (v[3] * 255.).round() as u8,
    )
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
    let (rect, response) = ui.allocate_exact_size(size, Sense::click());
    if !ui.is_rect_visible(rect) {
        return response;
    }
    let p = ui.painter_at(rect);
    p.rect_filled(rect, 0., color(theme.colors[0]));
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
        let (lower, upper) = panel
            .scale
            .bounds_with_minimum(&panel.series, settings.minimum_scale(module));
        let body = Rect::from_min_max(
            face.min,
            pos2(face.right(), face.bottom() - if cores { 18. } else { 0. }),
        );
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
        for i in 0..count {
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
    response.widget_info(|| {
        egui::WidgetInfo::labeled(
            egui::Role::Label,
            true,
            format!(
                "{}: {}",
                module.title(),
                panel
                    .map(|p| p.display_label(units).into_owned())
                    .unwrap_or_else(|| "Waiting for selected source".into())
            ),
        )
    });
    response
}
