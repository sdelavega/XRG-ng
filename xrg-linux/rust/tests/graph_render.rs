// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
#![cfg(feature = "egui-ui")]
use eframe::egui::{self, Color32, Rect, pos2};
use xrg_ng_linux::{
    graph::{self, Plot},
    settings::GraphStyle,
};
fn plot(lower: f64, upper: f64) -> Plot {
    Plot {
        rect: Rect::from_min_max(pos2(10., 10.), pos2(90., 90.)),
        lower,
        upper,
    }
}
fn color(v: [f64; 4]) -> Color32 {
    Color32::from_rgba_unmultiplied(
        (v[0] * 255.) as u8,
        (v[1] * 255.) as u8,
        (v[2] * 255.) as u8,
        (v[3] * 255.) as u8,
    )
}
// Rasterize egui's production tessellated triangles to inspect fill semantics.
// Native OpenGL and font rendering are separately exercised by the Xvfb gate.
fn raster(draw: impl FnOnce(&egui::Painter)) -> Vec<u8> {
    let ctx = egui::Context::default();
    let mut draw = Some(draw);
    let mut output = ctx.run_ui(
        egui::RawInput {
            screen_rect: Some(Rect::from_min_max(pos2(0., 0.), pos2(100., 100.))),
            ..Default::default()
        },
        |ui| draw.take().unwrap()(ui.painter()),
    );
    output.textures_delta.clear();
    let mut image = vec![[0f32; 4]; 100 * 100];
    let edge = |a: egui::Pos2, b: egui::Pos2, p: egui::Pos2| {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    };
    for primitive in ctx.tessellate(output.shapes, 1.) {
        let egui::epaint::Primitive::Mesh(mesh) = primitive.primitive else {
            panic!("Unexpected custom GPU callback")
        };
        for triangle in mesh.indices.as_chunks::<3>().0 {
            let [a, b, c] = [
                mesh.vertices[triangle[0] as usize],
                mesh.vertices[triangle[1] as usize],
                mesh.vertices[triangle[2] as usize],
            ];
            let area = edge(a.pos, b.pos, c.pos);
            if area.abs() < 1e-8 {
                continue;
            }
            for y in 0..100 {
                for x in 0..100 {
                    let p = pos2(x as f32 + 0.31, y as f32 + 0.37);
                    if !primitive.clip_rect.contains(p) {
                        continue;
                    }
                    let weights = [
                        edge(b.pos, c.pos, p) / area,
                        edge(c.pos, a.pos, p) / area,
                        edge(a.pos, b.pos, p) / area,
                    ];
                    if weights.iter().any(|v| *v < -1e-6) {
                        continue;
                    }
                    let colors = [a.color.to_array(), b.color.to_array(), c.color.to_array()];
                    let mut source = [0f32; 4];
                    for channel in 0..4 {
                        source[channel] = (0..3)
                            .map(|i| weights[i] * colors[i][channel] as f32 / 255.)
                            .sum();
                    }
                    let dest = &mut image[y * 100 + x];
                    for channel in 0..4 {
                        dest[channel] = source[channel] + dest[channel] * (1. - source[3]);
                    }
                }
            }
        }
    }
    image
        .into_iter()
        .flat_map(|p| {
            u32::from_be_bytes([
                (p[3] * 255.).round() as u8,
                (p[0] * 255.).round() as u8,
                (p[1] * 255.).round() as u8,
                (p[2] * 255.).round() as u8,
            ])
            .to_ne_bytes()
        })
        .collect()
}
fn image(
    style: GraphStyle,
    series: &[Vec<f64>],
    colors: &[[f64; 4]],
    range: (f64, f64),
) -> Vec<u8> {
    raster(|p| {
        graph::draw(
            p,
            series,
            &colors.iter().copied().map(color).collect::<Vec<_>>(),
            plot(range.0, range.1),
            style,
        )
    })
}
fn pixel(image: &[u8], x: usize, y: usize) -> u32 {
    u32::from_ne_bytes(
        image[(y * 100 + x) * 4..(y * 100 + x + 1) * 4]
            .try_into()
            .unwrap(),
    )
}
fn coverage(image: &[u8]) -> u64 {
    image
        .as_chunks::<4>()
        .0
        .iter()
        .map(|p| (u32::from_ne_bytes(*p) >> 24) as u64)
        .sum()
}
#[test]
fn styles_have_distinct_fills_and_all_clip_below_headers() {
    let colors = [[1., 0., 0., 1.]];
    let data = [vec![50., 50.]];
    let rendered = GraphStyle::ALL.map(|style| image(style, &data, &colors, (0., 100.)));
    assert!(coverage(&rendered[0]) > coverage(&rendered[1]));
    assert!(coverage(&rendered[0]) > coverage(&rendered[2]));
    assert!(coverage(&rendered[1]) > coverage(&rendered[3]));
    assert!(coverage(&rendered[2]) > coverage(&rendered[3]));
    assert_ne!(rendered[1], rendered[2]);
    assert_eq!(pixel(&rendered[0], 20, 70) >> 24, 255);
    assert_eq!(pixel(&rendered[3], 20, 70) >> 24, 0);
    for img in rendered {
        assert_eq!(pixel(&img, 20, 5), 0);
        assert_eq!(pixel(&img, 5, 70), 0);
    }
}
#[test]
fn signed_temperature_fills_to_zero_and_missing_points_never_bridge_gaps() {
    let colors = [[1., 0., 0., 1.]];
    let signed = image(
        GraphStyle::Solid,
        &[vec![-50., -50.]],
        &colors,
        (-100., 100.),
    );
    assert!(pixel(&signed, 20, 60) >> 24 > 0);
    assert_eq!(pixel(&signed, 20, 80), 0);
    assert_eq!(pixel(&signed, 20, 30), 0);
    for style in GraphStyle::ALL {
        let img = image(
            style,
            &[vec![50., 50., f64::NAN, 50., 50.]],
            &colors,
            (0., 100.),
        );
        assert_eq!(pixel(&img, 50, 50), 0);
        assert_eq!(pixel(&img, 50, 70), 0);
        assert_eq!(
            coverage(&image(
                style,
                &[vec![f64::NAN, f64::INFINITY]],
                &colors,
                (0., 100.)
            )),
            0
        );
        assert_eq!(coverage(&image(style, &[], &colors, (0., 100.))), 0);
    }
}
#[test]
fn opaque_overlaps_keep_other_curves_visible_and_fills_retain_theme_alpha() {
    let img = image(
        GraphStyle::Solid,
        &[vec![50., 50.], vec![70., 70.]],
        &[[1., 0., 0., 1.], [0., 1., 0., 1.]],
        (0., 100.),
    );
    assert!(
        (pixel(&img, 20, 50) >> 16) & 255 > 0,
        "First curve must remain outlined above the second fill"
    );
    let translucent = image(
        GraphStyle::Solid,
        &[vec![50., 50.]],
        &[[1., 0., 0., 0.25]],
        (0., 100.),
    );
    let alpha = pixel(&translucent, 20, 70) >> 24;
    assert!(alpha > 0 && alpha < 128);
    assert_eq!(
        coverage(&image(
            GraphStyle::Solid,
            &[vec![50., 50.]],
            &[[1., 0., 0., 1.]],
            (0., 0.)
        )),
        0
    );
}

fn bars_image(style: GraphStyle, series: &[Vec<f64>], range: (f64, f64), visible: bool) -> Vec<u8> {
    raster(|p| {
        if !visible {
            return;
        }
        let count = series.len() as f32;
        for (i, series) in series.iter().enumerate() {
            let mut plot = plot(range.0, range.1);
            plot.rect = Rect::from_min_max(
                pos2(10. + i as f32 * 80. / count, 10.),
                pos2(10. + (i + 1) as f32 * 80. / count - 1., 90.),
            );
            graph::bar(
                p,
                series.last().copied(),
                plot,
                color([1., 0., 0., 0.5]),
                color([0., 0., 1., 1.]),
                style,
            );
        }
    })
}
#[test]
fn bars_keep_zero_visible_missing_blank_and_never_reuse_a_stale_endpoint() {
    for style in GraphStyle::ALL {
        let zero = bars_image(style, &[vec![50., 0.]], (0., 100.), true);
        assert!(coverage(&zero) > 0);
        assert_eq!(pixel(&zero, 40, 40), 0);
        for series in [
            vec![],
            vec![vec![]],
            vec![vec![50., f64::NAN]],
            vec![vec![50., f64::INFINITY]],
        ] {
            assert_eq!(coverage(&bars_image(style, &series, (0., 100.), true)), 0);
        }
        assert_eq!(
            coverage(&bars_image(style, &[vec![50.]], (0., 100.), false)),
            0
        );
    }
}
#[test]
fn bar_fills_use_signed_zero_baseline_clip_and_preserve_opacity() {
    let img = bars_image(GraphStyle::Solid, &[vec![-50.]], (-100., 100.), true);
    assert_eq!(pixel(&img, 40, 40), 0);
    assert_eq!(pixel(&img, 40, 80), 0);
    assert!((120..=136).contains(&(pixel(&img, 40, 60) >> 24)));
    let img = bars_image(GraphStyle::Solid, &[vec![500.]], (0., 100.), true);
    assert!(pixel(&img, 40, 20) >> 24 > 0);
    assert_eq!(pixel(&img, 5, 40), 0);
    assert_eq!(pixel(&img, 40, 5), 0);
    let img = bars_image(
        GraphStyle::Solid,
        &[vec![50.], vec![f64::NAN], vec![0.]],
        (0., 100.),
        true,
    );
    assert!(pixel(&img, 20, 70) >> 24 > 0);
    assert_eq!(pixel(&img, 45, 70), 0);
    assert!(pixel(&img, 65, 89) >> 24 > 0);
}
#[test]
fn bar_styles_are_distinct_and_auto_rates_use_the_graph_range() {
    let rendered = GraphStyle::ALL.map(|s| bars_image(s, &[vec![50.]], (0., 100.), true));
    assert_ne!(rendered[0], rendered[1]);
    assert_ne!(rendered[1], rendered[2]);
    assert!(coverage(&rendered[0]) > coverage(&rendered[3]));
    let range = xrg_ng_linux::engine::Scale::Automatic.bounds(&[vec![100., 50.]]);
    let img = bars_image(GraphStyle::Solid, &[vec![100., 50.]], range, true);
    assert_eq!(pixel(&img, 40, 40), 0);
    assert!(pixel(&img, 40, 65) >> 24 > 0);
    assert_eq!(
        coverage(&bars_image(GraphStyle::Solid, &[vec![50.]], (0., 0.), true)),
        0
    );
}
