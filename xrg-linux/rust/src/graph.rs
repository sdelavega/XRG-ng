// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Cairo-free graph geometry and painting. Missing samples split every curve.
use crate::settings::GraphStyle;
use eframe::egui::{Color32, Painter, Pos2, Rect, Shape, Stroke, StrokeKind, pos2};

#[derive(Clone, Copy)]
pub struct Plot {
    pub rect: Rect,
    pub lower: f64,
    pub upper: f64,
}
impl Plot {
    pub fn valid(self) -> bool {
        self.rect.is_finite()
            && self.rect.is_positive()
            && self.lower.is_finite()
            && self.upper.is_finite()
            && self.upper > self.lower
    }
    pub fn y(self, value: f64) -> f32 {
        self.rect.bottom()
            - ((value - self.lower) / (self.upper - self.lower)).clamp(0., 1.) as f32
                * self.rect.height()
    }
    /// Each run keeps its original history positions; gaps never shift samples.
    pub fn runs_at(self, values: &[f64], positions: &[f64]) -> Vec<Vec<Pos2>> {
        if !self.valid()
            || values.len() != positions.len()
            || positions
                .iter()
                .any(|x| !x.is_finite() || !(0.0..=1.0).contains(x))
            || positions.windows(2).any(|w| w[0] > w[1])
        {
            return Vec::new();
        }
        let mut runs = Vec::new();
        let mut run = Vec::new();
        for (v, x) in values.iter().zip(positions) {
            if v.is_finite() {
                run.push(pos2(
                    self.rect.left() + *x as f32 * self.rect.width(),
                    self.y(*v),
                ));
            } else if !run.is_empty() {
                runs.push(std::mem::take(&mut run));
            }
        }
        if !run.is_empty() {
            runs.push(run);
        }
        runs
    }
    pub fn runs(self, values: &[f64]) -> Vec<Vec<Pos2>> {
        if !self.valid() {
            return Vec::new();
        }
        let mut runs = Vec::new();
        let mut run = Vec::new();
        for (i, v) in values.iter().enumerate() {
            if v.is_finite() {
                run.push(pos2(
                    self.rect.left()
                        + i as f32 * self.rect.width()
                            / values.len().saturating_sub(1).max(1) as f32,
                    self.y(*v),
                ));
            } else if !run.is_empty() {
                runs.push(std::mem::take(&mut run));
            }
        }
        if !run.is_empty() {
            runs.push(run);
        }
        runs
    }
}

/// Mesh strips avoid the convex-polygon assumption for arbitrary sampled curves.
fn fill(painter: &Painter, run: &[Pos2], baseline: f32, color: Color32, style: GraphStyle) {
    if style == GraphStyle::Hollow {
        return;
    }
    if style == GraphStyle::Solid {
        let mut mesh = eframe::egui::Mesh::default();
        for pair in run.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            let offset = mesh.vertices.len() as u32;
            // Split crossings at zero, so translucent fills cannot overlap.
            if (a.y - baseline) * (b.y - baseline) < 0. {
                let crossing = pos2(a.x + (b.x - a.x) * (baseline - a.y) / (b.y - a.y), baseline);
                for p in [
                    pos2(a.x, baseline),
                    a,
                    crossing,
                    crossing,
                    b,
                    pos2(b.x, baseline),
                ] {
                    mesh.colored_vertex(p, color);
                }
                mesh.add_triangle(offset, offset + 1, offset + 2);
                mesh.add_triangle(offset + 3, offset + 4, offset + 5);
            } else {
                for p in [pos2(a.x, baseline), a, b, pos2(b.x, baseline)] {
                    mesh.colored_vertex(p, color);
                }
                mesh.add_triangle(offset, offset + 1, offset + 2);
                mesh.add_triangle(offset, offset + 2, offset + 3);
            }
        }
        painter.add(Shape::mesh(mesh));
        return;
    }
    let step = if style == GraphStyle::Pixel { 6. } else { 3. };
    for pair in run.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        let mut x = ((a.x - 1.5) / step).ceil() * step + 1.5;
        while x < b.x {
            let y = a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x);
            let (top, bottom) = (baseline.min(y), baseline.max(y));
            let mut py = (top / step).ceil() * step + 1.5;
            while py < bottom {
                if style == GraphStyle::Pixel {
                    painter.rect_filled(
                        Rect::from_min_max(
                            pos2((x - 1.5).max(a.x), py - 1.5),
                            pos2((x + 1.5).min(b.x), (py + 1.5).min(bottom)),
                        ),
                        0.,
                        color,
                    );
                } else {
                    painter.circle_filled(pos2(x, py), 0.65, color);
                }
                py += step;
            }
            x += step;
        }
    }
}

pub fn draw(
    painter: &Painter,
    series: &[Vec<f64>],
    colors: &[Color32],
    plot: Plot,
    style: GraphStyle,
) {
    if !plot.valid() {
        return;
    }
    let painter = painter.with_clip_rect(plot.rect);
    let curves: Vec<_> = series
        .iter()
        .zip(colors)
        .map(|(v, c)| (plot.runs(v), *c))
        .collect();
    for (runs, color) in &curves {
        for run in runs {
            fill(&painter, run, plot.y(0.), *color, style);
        }
    }
    // Draw outlines after all fills to retain smaller overlapping series.
    for (runs, color) in curves {
        for run in runs {
            if run.len() == 1 {
                painter.circle_filled(run[0], 0.6, color);
            } else {
                painter.add(Shape::line(run, Stroke::new(1., color)));
            }
        }
    }
}

pub fn bar(
    painter: &Painter,
    value: Option<f64>,
    plot: Plot,
    color: Color32,
    border: Color32,
    style: GraphStyle,
) {
    if !plot.valid() || value.is_none_or(|v| !v.is_finite()) {
        return;
    }
    painter.rect_stroke(plot.rect, 0., Stroke::new(0.5, border), StrokeKind::Inside);
    if let Some(value) = value.filter(|v| v.is_finite()) {
        draw(painter, &[vec![value, value]], &[color], plot, style);
    }
}

/// Observation curves have explicit time positions and independent vertical axes.
pub fn draw_positioned(
    painter: &Painter,
    series: &[Vec<f64>],
    colors: &[Color32],
    positions: &[f64],
    bounds: &[(f64, f64)],
    rect: Rect,
    style: GraphStyle,
) {
    let painter = painter.with_clip_rect(rect);
    let curves: Vec<_> = series
        .iter()
        .zip(colors)
        .zip(bounds)
        .map(|((values, color), (lower, upper))| {
            let plot = Plot {
                rect,
                lower: *lower,
                upper: *upper,
            };
            (plot, plot.runs_at(values, positions), *color)
        })
        .collect();
    for (index, (plot, runs, color)) in curves.iter().enumerate() {
        if index == 0 {
            for run in runs {
                fill(&painter, run, plot.y(0.), *color, style);
            }
        }
    }
    for (_, runs, color) in curves {
        for run in runs {
            if run.len() == 1 {
                painter.circle_filled(run[0], 0.9, color);
            } else {
                painter.add(Shape::line(run, Stroke::new(1., color)));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn plot() -> Plot {
        Plot {
            rect: Rect::from_min_max(pos2(0., 0.), pos2(100., 100.)),
            lower: 0.,
            upper: 100.,
        }
    }
    #[test]
    fn gaps_keep_positions_and_zero_is_measured() {
        let runs = plot().runs(&[0., f64::NAN, 50., f64::INFINITY, 100.]);
        assert_eq!(
            runs,
            vec![
                vec![pos2(0., 100.)],
                vec![pos2(50., 50.)],
                vec![pos2(100., 0.)]
            ]
        );
    }
    #[test]
    fn timestamp_geometry_preserves_spacing_and_rejects_invalid_positions() {
        assert_eq!(
            plot().runs_at(&[0., f64::NAN, 100.], &[0.1, 0.5, 0.8]),
            vec![vec![pos2(10., 100.)], vec![pos2(80., 0.)]]
        );
        for xs in [vec![0.8, 0.1], vec![0., 1.1], vec![0., f64::NAN], vec![0.]] {
            assert!(plot().runs_at(&[0., 100.], &xs).is_empty());
        }
    }
    #[test]
    fn clamps_values_and_rejects_invalid_axes() {
        assert_eq!(
            plot().runs(&[-50., 150.]),
            vec![vec![pos2(0., 100.), pos2(100., 0.)]]
        );
        assert!(
            Plot {
                upper: 0.,
                ..plot()
            }
            .runs(&[1., 2.])
            .is_empty()
        );
        assert!(
            Plot {
                lower: f64::NAN,
                ..plot()
            }
            .runs(&[1.])
            .is_empty()
        );
        assert!(plot().runs(&[]).is_empty());
    }
}
