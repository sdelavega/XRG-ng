// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    ai::{
        self,
        accounting::{Accountant, Preferences},
    },
    shared::Usage,
};
static NEXT: AtomicU64 = AtomicU64::new(0);
const DAY: &str = "2026-10-29";
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "xrg-accounting-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        Self(p)
    }
    fn path(&self) -> PathBuf {
        self.0.join("ai-usage.json")
    }
    fn open(&self, p: ai::Preferences) -> Accountant {
        Accountant::open(Some(self.path()), p, DAY)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn preferences() -> ai::Preferences {
    ai::Preferences {
        enabled: [true, false, false, false],
        accounting: Preferences {
            enabled: true,
            by_provider: true,
            by_model: true,
            ..Default::default()
        },
        ..Default::default()
    }
}
fn report(total: u64, input: u64, output: u64, model: Option<&str>) -> ai::Report {
    let usage = Usage {
        input,
        output,
        total,
    };
    let mut providers = std::array::from_fn(|_| Err("disabled".into()));
    providers[0] = Ok(ai::Reading {
        continuity: 0,
        usage,
        cost: None,
        source: "fixture".into(),
        models: model.map(|m| {
            vec![ai::ModelUsage {
                model: Some(m.into()),
                usage,
                cost: None,
            }]
        }),
    });
    ai::Report {
        providers,
        ollama: "disabled".into(),
        models: ai::Models::default(),
    }
}
#[test]
fn initial_history_independent_resets_splits_models_and_restart() {
    let f = Fixture::new();
    let p = preferences();
    let mut a = f.open(p.clone());
    a.observe(&report(200, 100, 50, Some("model")), DAY);
    assert_eq!(a.snapshot().daily.total(), 0);
    a.observe(&report(250, 110, 70, Some("model")), DAY);
    let snapshot = a.snapshot();
    assert_eq!(
        (
            snapshot.session.input,
            snapshot.session.output,
            snapshot.session.unclassified
        ),
        (10, 20, 20)
    );
    assert_eq!(snapshot.models["model"], 50);
    assert_eq!(snapshot.providers["Claude"], 50);
    a.reset(true, false, DAY);
    a.observe(&report(260, 115, 75, Some("model")), DAY);
    assert_eq!(a.snapshot().session.total(), 0);
    assert_eq!(a.snapshot().daily.total(), 50);
    a.observe(&report(270, 120, 80, Some("model")), DAY);
    a.reset(false, true, DAY);
    a.observe(&report(280, 125, 85, Some("model")), DAY);
    assert_eq!(a.snapshot().session.total(), 10);
    assert_eq!(a.snapshot().daily.total(), 0);
    a.observe(&report(285, 127, 88, Some("model")), DAY);
    drop(a);
    let mut reopened = f.open(p);
    assert_eq!(reopened.snapshot().daily.total(), 5);
    assert_eq!(reopened.snapshot().session.total(), 0);
    reopened.observe(&report(999, 500, 400, Some("model")), DAY);
    assert_eq!(reopened.snapshot().daily.total(), 5);
    assert!(
        reopened
            .snapshot()
            .detail(&preferences().accounting)
            .contains("unknown split")
    );
}
#[test]
fn durable_threshold_once_per_day_restart_reset_and_midnight() {
    let f = Fixture::new();
    let mut p = preferences();
    p.accounting.daily_budget = 100;
    p.accounting.notifications = true;
    let mut a = f.open(p.clone());
    a.observe(&report(0, 0, 0, None), DAY);
    assert_eq!(a.observe(&report(79, 0, 0, None), DAY), None);
    assert_eq!(a.observe(&report(80, 0, 0, None), DAY), Some(80.));
    a.set_notification_status(Err("fixture daemon denied request".into()));
    assert!(a.snapshot().notification_status.contains("failed"));
    assert_eq!(a.observe(&report(100, 0, 0, None), DAY), None);
    drop(a);
    let mut a = f.open(p);
    a.observe(&report(100, 0, 0, None), DAY);
    assert_eq!(a.observe(&report(110, 0, 0, None), DAY), None);
    a.reset(false, true, DAY);
    a.observe(&report(120, 0, 0, None), DAY);
    assert_eq!(a.observe(&report(200, 0, 0, None), DAY), Some(80.));
    a.observe(&report(300, 0, 0, None), "2026-10-30");
    assert_eq!(a.snapshot().daily.total(), 0);
    assert_eq!(a.observe(&report(380, 0, 0, None), "2026-10-30"), Some(80.));
}
#[test]
fn source_failures_tracking_transitions_and_model_corrections_do_not_backfill() {
    let f = Fixture::new();
    let mut p = preferences();
    let mut a = f.open(p.clone());
    a.observe(&report(100, 0, 0, None), DAY);
    a.observe(&report(110, 0, 0, None), DAY);
    p.accounting.enabled = false;
    a.configure(&p);
    a.observe(&report(200, 0, 0, None), DAY);
    p.accounting.enabled = true;
    a.configure(&p);
    a.observe(&report(300, 0, 0, None), DAY);
    a.observe(&report(310, 0, 0, Some("late")), DAY);
    assert_eq!(a.snapshot().daily.total(), 20);
    assert!(a.snapshot().models.is_empty());
    let mut missing = report(310, 0, 0, None);
    missing.providers[0] = Err("read failed".into());
    a.observe(&missing, DAY);
    a.observe(&report(500, 0, 0, None), DAY);
    assert_eq!(a.snapshot().daily.total(), 20);
    let mut replaced = report(1000, 0, 0, None);
    replaced.providers[0].as_mut().unwrap().source = "replacement".into();
    a.observe(&replaced, DAY);
    assert_eq!(a.snapshot().daily.total(), 20);
    replaced.providers[0].as_mut().unwrap().usage.total = 1005;
    a.observe(&replaced, DAY);
    assert_eq!(a.snapshot().daily.total(), 25);
}
#[test]
fn corrupt_future_symlink_and_externally_changed_state_are_preserved() {
    for bytes in [b"not json".as_slice(), br#"{"version":999}"#] {
        let f = Fixture::new();
        fs::write(f.path(), bytes).unwrap();
        let mut p = preferences();
        p.accounting.notifications = true;
        p.accounting.daily_budget = 1;
        let mut a = f.open(p);
        a.observe(&report(0, 0, 0, None), DAY);
        assert_eq!(a.observe(&report(10, 0, 0, None), DAY), None);
        assert!(a.snapshot().persistence_error.is_some());
        assert_eq!(fs::read(f.path()).unwrap(), bytes);
    }
    let f = Fixture::new();
    let target = f.0.join("original");
    fs::write(&target, b"keep").unwrap();
    std::os::unix::fs::symlink(&target, f.path()).unwrap();
    let mut a = f.open(preferences());
    a.observe(&report(0, 0, 0, None), DAY);
    a.observe(&report(10, 0, 0, None), DAY);
    assert!(a.snapshot().persistence_error.is_some());
    assert_eq!(fs::read(target).unwrap(), b"keep");
    let f = Fixture::new();
    let mut a = f.open(preferences());
    a.observe(&report(0, 0, 0, None), DAY);
    a.observe(&report(10, 0, 0, None), DAY);
    fs::write(f.path(), b"external replacement").unwrap();
    a.observe(&report(20, 0, 0, None), DAY);
    assert!(
        a.snapshot()
            .persistence_error
            .as_ref()
            .unwrap()
            .contains("changed on disk")
    );
    assert_eq!(fs::read(f.path()).unwrap(), b"external replacement");
}
#[test]
fn exclusive_owner_prevents_second_instance_from_persisting_or_alerting() {
    let f = Fixture::new();
    let mut p = preferences();
    p.accounting.notifications = true;
    p.accounting.daily_budget = 1;
    let mut owner = f.open(p.clone());
    owner.observe(&report(0, 0, 0, None), DAY);
    assert!(owner.observe(&report(1, 0, 0, None), DAY).is_some());
    let mut second = f.open(p.clone());
    assert!(second.snapshot().persistence_error.is_some());
    second.observe(&report(0, 0, 0, None), DAY);
    assert_eq!(second.observe(&report(10, 0, 0, None), DAY), None);
    assert_eq!(second.snapshot().session.total(), 10);
    drop(owner);
    drop(second);
    assert_eq!(f.open(p).snapshot().daily.total(), 1);
}
#[test]
fn reset_daily_while_paused_persists_and_disabled_rollover_retains_bucket() {
    let f = Fixture::new();
    let mut p = preferences();
    p.accounting.auto_reset = false;
    let mut a = f.open(p.clone());
    a.observe(&report(0, 0, 0, None), DAY);
    a.observe(&report(10, 0, 0, None), DAY);
    a.observe(&report(20, 0, 0, None), "2026-10-30");
    assert_eq!(a.snapshot().daily.total(), 20);
    p.accounting.enabled = false;
    a.configure(&p);
    a.reset(false, true, "2026-10-30");
    a.observe(&report(30, 0, 0, None), "2026-10-30");
    drop(a);
    assert_eq!(f.open(p).snapshot().daily.total(), 0);
}
#[test]
fn saturation_is_marked_and_large_model_state_roundtrips() {
    let f = Fixture::new();
    let mut a = f.open(preferences());
    a.observe(&report(0, 0, 0, None), DAY);
    a.observe(&report(u64::MAX, 0, 0, None), DAY);
    a.observe(&report(0, 0, 0, None), DAY);
    a.observe(&report(u64::MAX, 0, 0, None), DAY);
    assert_eq!(a.snapshot().daily.total(), u64::MAX);
    assert!(a.snapshot().daily.saturated);
    let f = Fixture::new();
    let mut a = f.open(preferences());
    a.observe(&report(0, 0, 0, None), DAY);
    let mut r = report(256, 0, 0, None);
    r.providers[0].as_mut().unwrap().models = Some(
        (0..256)
            .map(|i| ai::ModelUsage {
                model: Some(format!("{i}-{}", "x".repeat(1000))),
                usage: Usage {
                    total: 1,
                    ..Usage::default()
                },
                cost: None,
            })
            .collect(),
    );
    a.observe(&r, DAY);
    assert!(a.snapshot().persistence_error.is_none());
    drop(a);
    assert!(fs::metadata(f.path()).unwrap().len() > 128 * 1024);
    assert_eq!(f.open(preferences()).snapshot().models.len(), 256);
}
#[test]
fn accounting_settings_migrate_without_enabling_tracking_or_alerts() {
    let mut value = serde_json::to_value(xrg_ng_linux::settings::Settings::default()).unwrap();
    value["version"] = 21.into();
    value["ai"].as_object_mut().unwrap().remove("accounting");
    let migrated =
        xrg_ng_linux::settings::Settings::parse(&serde_json::to_vec(&value).unwrap()).unwrap();
    assert_eq!(migrated.version, 39);
    assert!(!migrated.ai.accounting.enabled);
    assert!(!migrated.ai.accounting.notifications);
    let mut bad = migrated;
    bad.ai.accounting.notify_percent = 0;
    assert!(bad.validate().is_err());
}
#[test]
fn accounting_preferences_do_not_reset_provider_graphs_or_rates() {
    let mut p = preferences();
    let mut display = ai::Display::default();
    display.panel_for(report(100, 0, 0, None), 1., &p);
    display.panel_for(report(110, 0, 0, None), 2., &p);
    p.accounting.daily_budget = 500;
    let panel = display.panel_for(report(120, 0, 0, None), 3., &p);
    assert!(panel.label.contains("10 tok/s"));
    assert_eq!(panel.series[0].iter().filter(|n| **n > 0.).count(), 2);
}

#[test]
fn invalid_calendar_dates_and_inconsistent_aggregates_are_preserved() {
    for (key, value) in [
        ("day", serde_json::json!("2026-02-30")),
        ("models", serde_json::json!({"invented":10000})),
    ] {
        let f = Fixture::new();
        let mut a = f.open(preferences());
        a.observe(&report(0, 0, 0, None), DAY);
        a.observe(&report(10, 0, 0, None), DAY);
        drop(a);
        let mut wire: serde_json::Value =
            serde_json::from_slice(&fs::read(f.path()).unwrap()).unwrap();
        wire[key] = value;
        let original = serde_json::to_vec(&wire).unwrap();
        fs::write(f.path(), &original).unwrap();
        let mut a = f.open(preferences());
        assert!(a.snapshot().persistence_error.is_some());
        a.observe(&report(0, 0, 0, None), DAY);
        a.observe(&report(20, 0, 0, None), DAY);
        assert_eq!(fs::read(f.path()).unwrap(), original);
    }
}

#[test]
fn temporary_state_failure_does_not_consume_an_unsent_alert() {
    let f = Fixture::new();
    let mut p = preferences();
    p.accounting.notifications = true;
    p.accounting.daily_budget = 10;
    let mut a = f.open(p);
    a.observe(&report(0, 0, 0, None), DAY);
    let moved = f.0.with_extension("temporarily-moved");
    fs::rename(&f.0, &moved).unwrap();
    fs::write(&f.0, b"temporary obstruction").unwrap();
    assert_eq!(a.observe(&report(10, 0, 0, None), DAY), None);
    assert!(a.snapshot().persistence_error.is_some());
    fs::remove_file(&f.0).unwrap();
    fs::rename(moved, &f.0).unwrap();
    assert_eq!(a.observe(&report(20, 0, 0, None), DAY), Some(200.));
    assert!(a.snapshot().persistence_error.is_none());
    assert_eq!(a.observe(&report(30, 0, 0, None), DAY), None);
}

#[test]
fn inventory_revision_rebaselines_both_model_and_component_accounting() {
    let f = Fixture::new();
    let mut accountant = f.open(preferences());
    accountant.observe(&report(100, 60, 40, Some("old")), DAY);
    accountant.observe(&report(110, 66, 44, Some("old")), DAY);
    assert_eq!(accountant.snapshot().session.total(), 10);
    let mut imported = report(10000, 6000, 4000, Some("archive"));
    imported.providers[0].as_mut().unwrap().continuity = 1;
    accountant.observe(&imported, DAY);
    assert_eq!(accountant.snapshot().session.total(), 10);
    let mut current = report(10010, 6006, 4004, Some("archive"));
    current.providers[0].as_mut().unwrap().continuity = 1;
    accountant.observe(&current, DAY);
    let snapshot = accountant.snapshot();
    assert_eq!(snapshot.session.total(), 20);
    assert_eq!(snapshot.session.input, 12);
    assert_eq!(snapshot.session.output, 8);
    assert_eq!(snapshot.models.get("archive"), Some(&10));
}
