// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Cairo presentation only; immutable series enter here, never collectors.
use crate::settings::GraphStyle;
use gtk::cairo::{Antialias, Context, Error, Extend, Filter, Format, ImageSurface, SurfacePattern};
#[derive(Clone, Copy)]
pub struct Plot {
    pub left: f64,
    pub top: f64,
    pub right: f64,
    pub bottom: f64,
    pub lower: f64,
    pub upper: f64,
}
impl Plot {
    fn y(self, value: f64) -> f64 {
        self.bottom
            - ((value - self.lower) / (self.upper - self.lower)).clamp(0., 1.)
                * (self.bottom - self.top)
    }
    fn trace(self, context: &Context, values: &[f64], filled: bool) {
        context.new_path();
        let zero = self.y(0.);
        let mut active = false;
        let mut last_x = self.left;
        for (index, value) in values.iter().enumerate() {
            let x = self.left
                + index as f64 * (self.right - self.left)
                    / values.len().saturating_sub(1).max(1) as f64;
            if value.is_finite() {
                let y = self.y(*value);
                if !active {
                    context.move_to(x, if filled { zero } else { y });
                    if filled {
                        context.line_to(x, y);
                    }
                    active = true;
                } else {
                    context.line_to(x, y);
                }
                last_x = x;
            } else if active {
                if filled {
                    context.line_to(last_x, zero);
                    context.close_path();
                }
                active = false;
            }
        }
        if active && filled {
            context.line_to(last_x, zero);
            context.close_path();
        }
    }
}
fn color(context: &Context, color: [f64; 4]) {
    context.set_source_rgba(color[0], color[1], color[2], color[3]);
}
fn pattern(style: GraphStyle, rgba: [f64; 4]) -> Result<SurfacePattern, Error> {
    let size = if style == GraphStyle::Pixel { 6 } else { 3 };
    let surface = ImageSurface::create(Format::ARgb32, size, size)?;
    let context = Context::new(&surface)?;
    color(&context, rgba);
    if style == GraphStyle::Pixel {
        context.set_antialias(Antialias::None);
        context.rectangle(1., 1., 3., 3.);
    } else {
        context.arc(1.5, 1.5, 0.65, 0., std::f64::consts::TAU);
    }
    context.fill()?;
    let pattern = SurfacePattern::create(&surface);
    pattern.set_extend(Extend::Repeat);
    pattern.set_filter(Filter::Nearest);
    Ok(pattern)
}
/// Fill each curve against zero, then outline all curves so a smaller series
/// remains visible even beneath another opaque area. Curves are never stacked.
pub fn draw(
    context: &Context,
    series: &[Vec<f64>],
    colors: &[[f64; 4]],
    plot: Plot,
    style: GraphStyle,
) -> Result<(), Error> {
    if ![
        plot.left,
        plot.right,
        plot.top,
        plot.bottom,
        plot.lower,
        plot.upper,
    ]
    .iter()
    .all(|v| v.is_finite())
        || plot.right <= plot.left
        || plot.bottom <= plot.top
        || plot.upper <= plot.lower
    {
        return Ok(());
    }
    context.save()?;
    let result = (|| {
        context.rectangle(
            plot.left,
            plot.top,
            plot.right - plot.left,
            plot.bottom - plot.top,
        );
        context.clip();
        if style != GraphStyle::Hollow {
            for (values, rgba) in series.iter().zip(colors).take(3) {
                plot.trace(context, values, true);
                if style == GraphStyle::Solid {
                    color(context, *rgba);
                } else {
                    context.set_source(pattern(style, *rgba)?)?;
                }
                context.fill()?;
            }
        }
        for (values, rgba) in series.iter().zip(colors).take(3) {
            plot.trace(context, values, false);
            color(context, *rgba);
            context.set_line_width(1.5);
            context.stroke()?;
        }
        Ok(())
    })();
    let restored = context.restore();
    result.and(restored)
}
