// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Compact graph faces modeled after the macOS strip. Labels are drawn last.
use gtk::cairo::Context;
use xrg_ng_linux::{
    dashboard::Row,
    engine::Panel,
    graph::{self, Plot},
    settings::{ActivityBars, GraphStyle},
    shared::Theme,
    temperature::Units,
};
fn color(c: &Context, v: [f64; 4]) {
    c.set_source_rgba(v[0], v[1], v[2], v[3]);
}
fn width(c: &Context, text: &str) -> f64 {
    c.text_extents(text).map_or(0., |e| e.x_advance())
}
fn elide(c: &Context, text: &str, available: f64) -> String {
    if available <= 0. {
        return String::new();
    }
    if width(c, text) <= available {
        return text.into();
    }
    if width(c, "…") > available {
        return String::new();
    }
    let mut value = String::new();
    for ch in text.chars() {
        let mut next = value.clone();
        next.push(ch);
        if width(c, &format!("{next}…")) > available {
            break;
        }
        value = next;
    }
    value.push('…');
    value
}
fn row(c: &Context, r: &Row, y: f64, w: f64, units: Units) {
    let right = r.right.render(units);
    let rw = width(c, &right).min((w - 6.) * 0.48);
    let right = elide(c, &right, rw);
    let left = elide(
        c,
        &r.left,
        (w - 6. - if right.is_empty() { 0. } else { rw + 5. }).max(0.),
    );
    c.move_to(3., y);
    let _ = c.show_text(&left);
    c.move_to(w - 3. - width(c, &right), y);
    let _ = c.show_text(&right);
}
pub(super) fn draw(
    c: &Context,
    (width, height): (i32, i32),
    theme: &Theme,
    title: &str,
    panel: Option<&Panel>,
    units: Units,
    (style, bars): (GraphStyle, &ActivityBars),
) {
    let (w, h) = (width as f64, height as f64);
    let title = panel.map_or(title, |p| p.title);
    let title = title.split(" · ").next().unwrap_or(title);
    let _ = c.save();
    c.rectangle(0., 0., w, h);
    c.clip();
    c.set_source_rgb(theme.colors[0][0], theme.colors[0][1], theme.colors[0][2]);
    let _ = c.paint();
    color(c, theme.colors[1]);
    let _ = c.paint();
    let has_cores = panel.is_some_and(|p| !p.readout.cores.is_empty()) && bars.visible;
    let count = panel
        .filter(|_| bars.visible && !has_cores)
        .map_or(0, |p| p.series.len().min(3));
    let reserve = if count > 0 {
        count as f64 * 5. + 3.
    } else {
        0.
    };
    if let Some(p) = panel {
        let (lower, upper) = p.scale.bounds(&p.series);
        let bottom = if has_cores { h - 18. } else { h };
        let plot = Plot {
            left: 0.,
            top: 0.,
            right: w - reserve,
            bottom,
            lower,
            upper,
        };
        let _ = graph::draw(c, &p.series, &theme.colors[2..5], plot, style);
        for index in 0..count {
            let mut appearance = bars.clone();
            if bars.use_series_colors {
                appearance.color = theme.colors[2 + index];
            }
            let _ = graph::draw_bars(
                c,
                &p.series[index..index + 1],
                Plot {
                    left: w - reserve + index as f64 * 5.,
                    right: w - reserve + (index + 1) as f64 * 5.,
                    top: 2.,
                    bottom: h - 2.,
                    lower,
                    upper,
                },
                &appearance,
                theme.colors[5],
            );
        }
        if has_cores {
            let step = w / p.readout.cores.len() as f64;
            for (index, (_, value)) in p.readout.cores.iter().enumerate() {
                let mut appearance = bars.clone();
                if bars.use_series_colors {
                    appearance.color = theme.colors[2];
                }
                if let Some(value) = value.filter(|v| v.is_finite()) {
                    let left = index as f64 * step + 0.5;
                    let right = ((index + 1) as f64 * step - 0.5).max(left + 0.5);
                    color(c, theme.colors[5]);
                    c.set_line_width(0.5);
                    c.rectangle(left, h - 17.5, right - left, 16.5);
                    let _ = c.stroke();
                    let _ = graph::draw(
                        c,
                        &[vec![value, value]],
                        &[appearance.color],
                        Plot {
                            left,
                            right,
                            top: h - 18.,
                            bottom: h - 1.,
                            lower: 0.,
                            upper: 100.,
                        },
                        appearance.style,
                    );
                }
            }
        }
    }
    color(c, theme.colors[6]);
    c.select_font_face(
        "Sans",
        gtk::cairo::FontSlant::Normal,
        gtk::cairo::FontWeight::Normal,
    );
    c.set_font_size(11.);
    let tw = (w - reserve).max(0.);
    if let Some(p) = panel.filter(|p| !p.readout.top.is_empty()) {
        let bottom_rows = p.readout.bottom.len();
        for (index, r) in p.readout.top.iter().enumerate() {
            let y = 12. + index as f64 * 13.;
            if y > h - 3. - bottom_rows as f64 * 13. - if has_cores { 18. } else { 0. } {
                break;
            }
            row(c, r, y, tw, units);
        }
        for (index, r) in p.readout.bottom.iter().enumerate() {
            row(
                c,
                r,
                h - 3. - (bottom_rows - 1 - index) as f64 * 13.,
                tw,
                units,
            );
        }
    } else {
        row(
            c,
            &Row::new(if title == "TPU / NPU" { "NPU" } else { title }, ""),
            12.,
            tw,
            units,
        );
        let label = panel
            .map(|p| p.display_label(units).into_owned())
            .unwrap_or_else(|| "Waiting for sample…".into());
        // Keep statuses readable at narrow widths; full text is in accessibility/details.
        let mut line = String::new();
        let mut y = 25.;
        for word in label.split_whitespace() {
            let next = if line.is_empty() {
                word.into()
            } else {
                format!("{line} {word}")
            };
            if width_text(c, &next) > tw - 6. && !line.is_empty() {
                row(c, &Row::new(&line, ""), y, tw, units);
                y += 13.;
                line = word.into();
            } else {
                line = next;
            }
            if y > h - 7. {
                break;
            }
        }
        if y <= h - 3. {
            row(c, &Row::new(line, ""), y, tw, units);
        }
    }
    let _ = c.restore();
}
fn width_text(c: &Context, text: &str) -> f64 {
    width(c, text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use gtk::cairo::{Context, Format, ImageSurface};
    #[test]
    fn unicode_elision_respects_the_column_and_context_is_restored() {
        let surface = ImageSurface::create(Format::ARgb32, 180, 110).unwrap();
        let c = Context::new(&surface).unwrap();
        c.set_font_size(11.);
        let result = elide(&c, "温度センサー · CPU package", 48.);
        assert!(result.ends_with('…'));
        assert!(width(&c, &result) <= 48.);
        assert_eq!(elide(&c, "温度", 0.), "");
        let theme = Theme {
            name: "Fixture".into(),
            colors: [
                [0., 0., 0., 1.],
                [0., 0., 0., 1.],
                [1., 0., 0., 1.],
                [0., 1., 0., 1.],
                [1., 1., 0., 1.],
                [0., 0., 1., 1.],
                [1., 1., 1., 1.],
            ],
        };
        let panel = Panel {
            title: "CPU",
            label: "Measured cores".into(),
            detail: String::new(),
            series: Vec::new(),
            scale: xrg_ng_linux::engine::Scale::Percent,
            temperature_text: None,
            readout: xrg_ng_linux::dashboard::Readout {
                cores: (0..64)
                    .map(|id| (id, if id == 0 { None } else { Some(50.) }))
                    .collect(),
                ..Default::default()
            },
        };
        c.set_line_width(7.);
        draw(
            &c,
            (140, 90),
            &theme,
            "CPU",
            Some(&panel),
            Units::Celsius,
            (
                GraphStyle::Solid,
                &ActivityBars {
                    visible: true,
                    use_series_colors: true,
                    ..Default::default()
                },
            ),
        );
        assert_eq!(c.line_width(), 7.);
        assert_eq!(c.clip_extents().unwrap(), (0., 0., 180., 110.));
        drop(c);
        let mut surface = surface;
        let stride = surface.stride() as usize;
        let data = surface.data().unwrap();
        // Dense 64-core strip remains visible at 140 px; an unknown core stays blank.
        // A bar is subpixel-width here; require majority coverage at its center.
        assert!(data[85 * stride + 3 * 4 + 2] > 128);
        assert_eq!(data[85 * stride + 2], 0);
        assert_eq!(data[100 * stride + 160 * 4 + 3], 0);
    }
}
