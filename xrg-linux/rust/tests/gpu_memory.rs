// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use xrg_ng_linux::{gpu::Gpu, gpu_memory::View, hardware::Readings};
fn gpu(id: &str, used: Option<u64>, total: Option<u64>) -> Gpu {
    Gpu {
        id: id.into(),
        label: id.into(),
        name: "fixture".into(),
        driver: "amdgpu".into(),
        memory_used: used,
        memory_total: total,
        ..Default::default()
    }
}
fn report(values: Vec<Gpu>) -> Result<Readings<Gpu>, String> {
    Ok(Readings {
        values,
        errors: Vec::new(),
    })
}
#[test]
fn retained_capacity_preserves_values_and_survives_pool_driver_and_input_changes() {
    let mut view = View::default();
    view.set_history_samples(3).unwrap();
    view.panel(&report(vec![gpu("a", Some(25), Some(100))]));
    view.panel(&report(vec![gpu("a", Some(50), Some(100))]));
    view.set_history_samples(6).unwrap();
    let p = view.panel(&report(vec![gpu("a", Some(75), Some(100))]));
    assert_eq!(p.series[0].len(), 6);
    assert_eq!(&p.series[0][3..], &[25., 50., 75.]);
    assert!(p.series[0][..2].iter().all(|v| v.is_nan()));
    assert!(view.set_history_samples(20001).is_err());
    let mut replacement = gpu("a", Some(25), Some(50));
    replacement.driver = "replacement".into();
    let p = view.panel(&report(vec![replacement.clone()]));
    assert_eq!(p.series[0].len(), 6);
    assert_eq!(p.series[0][5], 50.);
    assert!(!p.series[0].contains(&75.));
    view.clear_graph();
    let p = view.panel(&report(vec![replacement.clone()]));
    assert!(p.series[0][..5].iter().all(|v| v.is_nan()));
    view.panel(&Err("unavailable".into()));
    assert_eq!(
        view.panel(&report(vec![replacement.clone()])).series[0].len(),
        6
    );
    view.set_history_samples(0).unwrap();
    assert_eq!(view.panel(&report(vec![replacement])).series[0].len(), 120);
}
#[test]
fn dedicated_memory_percentages_include_real_empty_zero_without_activity() {
    let mut v = View::default();
    let p = v.panel(&report(vec![
        gpu("a", Some(2 * 1024 * 1024), Some(8 * 1024 * 1024)),
        gpu("b", Some(0), Some(100)),
    ]));
    assert_eq!(p.series.len(), 2);
    assert_eq!(p.series[0].last(), Some(&25.));
    assert_eq!(p.series[1].last(), Some(&0.));
    assert!(p.detail.contains("2.0 / 8.0 MiB VRAM pool"));
}
#[test]
fn shared_client_allocations_and_incomplete_totals_do_not_become_vram() {
    let mut v = View::default();
    let mut uma = gpu("uma", None, None);
    uma.client_resident_bytes = Some(8_000_000_000);
    let p = v.panel(&report(vec![uma, gpu("partial", Some(100), None)]));
    assert!(p.series.is_empty());
    assert!(p.label.contains("unavailable"));
    assert!(p.detail.contains("VRAM total unavailable"));
    assert!(p.detail.contains("not used as VRAM totals"));
}
#[test]
fn memory_capacity_driver_and_missing_values_reset_only_the_affected_history() {
    let mut v = View::default();
    v.panel(&report(vec![
        gpu("a", Some(25), Some(100)),
        gpu("b", Some(50), Some(100)),
    ]));
    let mut changed = gpu("a", Some(25), Some(50));
    let p = v.panel(&report(vec![
        changed.clone(),
        gpu("b", Some(60), Some(100)),
    ]));
    assert!(p.series[0][..119].iter().all(|n| *n == 0.));
    assert_eq!(p.series[1][118..], [50., 60.]);
    changed.driver = "nouveau".into();
    let p = v.panel(&report(vec![changed.clone()]));
    assert!(p.series[0][..119].iter().all(|n| *n == 0.));
    v.panel(&report(vec![gpu("a", None, None)]));
    let p = v.panel(&report(vec![changed.clone()]));
    assert!(p.series[0][..119].iter().all(|n| *n == 0.));
    assert!(v.panel(&Err("discovery failed".into())).series.is_empty());
    let p = v.panel(&report(vec![changed]));
    assert!(p.series[0][..119].iter().all(|n| *n == 0.));
}
#[test]
fn invalid_totals_are_unavailable_and_three_adapter_limit_is_explicit() {
    let mut v = View::default();
    assert!(
        v.panel(&report(vec![
            gpu("a", Some(10), Some(0)),
            gpu("b", Some(101), Some(100))
        ]))
        .series
        .is_empty()
    );
    let p = v.panel(&report(
        (0..4)
            .map(|n| gpu(&n.to_string(), Some(10), Some(100)))
            .collect(),
    ));
    assert_eq!(p.series.len(), 3);
    assert!(p.label.contains("(+more)"));
    v.reset();
    let p = v.panel(&report(vec![gpu("0", Some(20), Some(100))]));
    assert!(p.series[0][..119].iter().all(|n| *n == 0.));
}
