// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
#![cfg(feature = "gtk-ui")]
use gtk::cairo::{Context, Format, ImageSurface};
use xrg_ng_linux::{
    graph::{self, Plot},
    settings::GraphStyle,
};
fn plot(lower: f64, upper: f64) -> Plot {
    Plot {
        left: 10.,
        right: 90.,
        top: 10.,
        bottom: 90.,
        lower,
        upper,
    }
}
fn image(
    style: GraphStyle,
    series: &[Vec<f64>],
    colors: &[[f64; 4]],
    range: (f64, f64),
) -> Vec<u8> {
    let mut surface = ImageSurface::create(Format::ARgb32, 100, 100).unwrap();
    let context = Context::new(&surface).unwrap();
    context.set_line_width(7.);
    graph::draw(&context, series, colors, plot(range.0, range.1), style).unwrap();
    assert_eq!(context.line_width(), 7.);
    assert_eq!(context.clip_extents().unwrap(), (0., 0., 100., 100.));
    drop(context);
    surface.flush();
    surface.data().unwrap().to_vec()
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
