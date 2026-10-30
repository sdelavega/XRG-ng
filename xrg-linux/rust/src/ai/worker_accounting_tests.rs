// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

#[test]
fn reset_during_collection_discards_old_result_and_preserves_graphs() {
    struct Api {
        calls: u64,
        started: mpsc::Sender<()>,
        resume: mpsc::Receiver<()>,
    }
    impl LocalApi for Api {
        fn get(&mut self, _: Endpoint) -> Result<Vec<u8>, String> {
            self.calls += 1;
            if self.calls == 2 {
                self.started.send(()).unwrap();
                self.resume.recv_timeout(Duration::from_secs(2)).unwrap();
            }
            Ok(format!(
                "claude_code_token_usage_total{{type=\"input\"}} {}",
                90 + self.calls * 10
            )
            .into_bytes())
        }
    }
    let root = std::env::temp_dir().join(format!("xrg-accounting-worker-{}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let (started, signal) = mpsc::channel();
    let (resume, paused) = mpsc::channel();
    let control = Control::default();
    let mut preferences = Preferences {
        enabled: [true, false, false, false],
        ollama: false,
        claude_source: ClaudeSource::Metrics,
        ..Default::default()
    };
    preferences.accounting.enabled = true;
    preferences.accounting.notifications = true;
    preferences.accounting.daily_budget = 5;
    let notifications = Arc::new(AtomicU64::new(0));
    let sent = notifications.clone();
    let worker = Worker::controlled_impl(
        Config { home: root.clone() },
        preferences.clone(),
        control.clone(),
        Api {
            calls: 0,
            started,
            resume: paused,
        },
        Some(root.join("ai-usage.json")),
        move |_| {
            sent.fetch_add(1, Ordering::Relaxed);
            Ok(())
        },
    );
    let receive = |revision| {
        let end = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(update) = worker.latest.lock().unwrap().take()
                && update.control_revision == revision
            {
                break update;
            }
            assert!(
                Instant::now() < end,
                "AI accounting command not acknowledged"
            );
            thread::sleep(Duration::from_millis(5));
        }
    };
    assert_eq!(receive(0).accounting.daily.total(), 0);
    control.set(preferences.clone()).unwrap();
    signal.recv_timeout(Duration::from_secs(2)).unwrap();
    control.reset_daily();
    let revision = control.revision();
    resume.send(()).unwrap();
    let reset = receive(revision);
    assert_eq!(reset.accounting.daily.total(), 0);
    assert_eq!(reset.report.providers[0].as_ref().unwrap().usage.total, 120);
    assert_eq!(notifications.load(Ordering::Relaxed), 0);
    control.set(preferences.clone()).unwrap();
    let counted = receive(control.revision());
    assert_eq!(counted.accounting.daily.total(), 10);
    assert_eq!(notifications.load(Ordering::Relaxed), 1);
    control.reset_session();
    let reset = receive(control.revision());
    assert_eq!(reset.accounting.session.total(), 0);
    assert_eq!(reset.accounting.daily.total(), 10);
    assert_eq!(reset.panel.series[0].len(), counted.panel.series[0].len());
    assert_ne!(reset.panel.series[0], vec![0.; 120]);
    control.set(preferences).unwrap();
    let update = receive(control.revision());
    assert_eq!(update.accounting.session.total(), 10);
    assert_eq!(notifications.load(Ordering::Relaxed), 1);
    drop(worker);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn retention_edits_resize_cached_reports_without_collection_or_accounting() {
    struct Api(Arc<AtomicU64>);
    impl LocalApi for Api {
        fn get(&mut self, _: Endpoint) -> Result<Vec<u8>, String> {
            let call = self.0.fetch_add(1, Ordering::Relaxed);
            Ok(format!(
                "claude_code_token_usage_total{{type=\"input\"}} {}",
                100 + call * 10
            )
            .into_bytes())
        }
    }
    let root = std::env::temp_dir().join(format!("xrg-retention-worker-{}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let control = Control::default();
    let mut prefs = Preferences {
        enabled: [true, false, false, false],
        ollama: false,
        claude_source: ClaudeSource::Metrics,
        ..Default::default()
    };
    prefs.accounting.enabled = true;
    prefs.accounting.notifications = true;
    prefs.accounting.daily_budget = 5;
    let reads = Arc::new(AtomicU64::new(0));
    let alerts = Arc::new(AtomicU64::new(0));
    let sent = alerts.clone();
    let worker = Worker::controlled_impl(
        Config { home: root.clone() },
        prefs.clone(),
        control.clone(),
        Api(reads.clone()),
        Some(root.join("accounting.json")),
        move |_| {
            sent.fetch_add(1, Ordering::Relaxed);
            Ok(())
        },
    );
    let receive = |revision| {
        let end = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(update) = worker.latest.lock().unwrap().take()
                && update.control_revision == revision
            {
                break update;
            }
            assert!(Instant::now() < end, "AI retention update not acknowledged");
            thread::sleep(Duration::from_millis(5));
        }
    };
    assert_eq!(receive(0).accounting.session.total(), 0);
    control.set(prefs.clone()).unwrap();
    let observed = receive(control.revision());
    assert_eq!(observed.accounting.session.total(), 10);
    assert_eq!(alerts.load(Ordering::Relaxed), 1);
    let readings = observed.panel.readout.clone();
    for requested in [300, 1, 0] {
        prefs.history_samples = requested;
        control.set(prefs.clone()).unwrap();
        let update = receive(control.revision());
        assert_eq!(update.preferences.history_samples, requested);
        assert_eq!(
            update.panel.series[0].len(),
            prefs.history_capacity() as usize
        );
        assert!(*update.panel.series[0].last().unwrap() > 0.);
        assert_eq!(update.accounting.session.total(), 10);
        assert_eq!(update.accounting.daily.total(), 10);
        assert!(Arc::ptr_eq(&observed.report, &update.report));
        assert_eq!(
            format!("{:?}", update.panel.readout),
            format!("{readings:?}")
        );
        assert_eq!(reads.load(Ordering::Relaxed), 2);
        assert_eq!(alerts.load(Ordering::Relaxed), 1);
        assert!(update.detail.contains(&history_description(&prefs)));
        assert!(
            update
                .detail_for(false)
                .contains(&history_description(&prefs))
        );
    }
    // A pending graph reset is acknowledged through the same cache, without polling.
    let generation = worker.clear_graph();
    prefs.history_samples = 257;
    control.set(prefs.clone()).unwrap();
    let cleared = receive(control.revision());
    assert_eq!(cleared.graph_generation, generation);
    assert!(cleared.panel.series[0].iter().all(|v| v.is_nan()));
    assert_eq!(cleared.accounting.session.total(), 10);
    assert_eq!(reads.load(Ordering::Relaxed), 2);
    let revision = control.revision();
    let mut invalid = prefs.clone();
    invalid.history_samples = 20001;
    assert!(control.set(invalid).is_err());
    assert_eq!(control.revision(), revision);
    // An explicit same-preference refresh retains its existing collection behavior.
    control.set(prefs).unwrap();
    let next = receive(control.revision());
    assert_eq!(next.accounting.session.total(), 20);
    assert_eq!(next.accounting.daily.total(), 20);
    assert_eq!(reads.load(Ordering::Relaxed), 3);
    assert_eq!(alerts.load(Ordering::Relaxed), 1);
    drop(worker);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn history_changes_during_a_scan_keep_that_observation_without_a_second_scan() {
    struct Api {
        reads: Arc<AtomicU64>,
        entered: mpsc::Sender<()>,
        resume: mpsc::Receiver<()>,
    }
    impl LocalApi for Api {
        fn get(&mut self, _: Endpoint) -> Result<Vec<u8>, String> {
            let call = self.reads.fetch_add(1, Ordering::Relaxed);
            if call == 1 {
                self.entered.send(()).unwrap();
                self.resume.recv_timeout(Duration::from_secs(2)).unwrap();
            }
            Ok(format!(
                "claude_code_token_usage_total{{type=\"input\"}} {}",
                100 + call * 10
            )
            .into_bytes())
        }
    }
    let root = std::env::temp_dir().join(format!("xrg-retention-flight-{}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let reads = Arc::new(AtomicU64::new(0));
    let control = Control::default();
    let mut prefs = Preferences {
        enabled: [true, false, false, false],
        ollama: false,
        claude_source: ClaudeSource::Metrics,
        ..Default::default()
    };
    prefs.accounting.enabled = true;
    let (entered, started) = mpsc::channel();
    let (resume, paused) = mpsc::channel();
    let worker = Worker::controlled_impl(
        Config { home: root.clone() },
        prefs.clone(),
        control.clone(),
        Api {
            reads: reads.clone(),
            entered,
            resume: paused,
        },
        None,
        |_| Ok(()),
    );
    let receive = |revision| {
        let end = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(update) = worker.latest.lock().unwrap().take()
                && update.control_revision == revision
            {
                break update;
            }
            assert!(Instant::now() < end);
            thread::sleep(Duration::from_millis(5));
        }
    };
    receive(0);
    control.set(prefs.clone()).unwrap();
    started.recv_timeout(Duration::from_secs(2)).unwrap();
    for count in [300, 600, 257] {
        prefs.history_samples = count;
        control.set(prefs.clone()).unwrap();
    }
    resume.send(()).unwrap();
    let update = receive(control.revision());
    assert_eq!(reads.load(Ordering::Relaxed), 2);
    assert_eq!(update.panel.series[0].len(), 257);
    assert_eq!(
        update.report.providers[0].as_ref().unwrap().usage.total,
        110
    );
    assert_eq!(update.accounting.session.total(), 10);
    assert_eq!(update.accounting.daily.total(), 10);
    assert!(*update.panel.series[0].last().unwrap() > 0.);
    drop(worker);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn late_history_edits_do_not_postpone_the_original_five_second_deadline() {
    struct Api {
        calls: mpsc::Sender<Instant>,
        count: u64,
    }
    impl LocalApi for Api {
        fn get(&mut self, _: Endpoint) -> Result<Vec<u8>, String> {
            self.calls.send(Instant::now()).unwrap();
            self.count += 10;
            Ok(format!(
                "claude_code_token_usage_total{{type=\"input\"}} {}",
                self.count
            )
            .into_bytes())
        }
    }
    let root = std::env::temp_dir().join(format!("xrg-retention-deadline-{}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let (calls, observed) = mpsc::channel();
    let control = Control::default();
    let mut prefs = Preferences {
        enabled: [true, false, false, false],
        ollama: false,
        claude_source: ClaudeSource::Metrics,
        ..Default::default()
    };
    let launched = Instant::now();
    let worker = Worker::controlled_impl(
        Config { home: root.clone() },
        prefs.clone(),
        control.clone(),
        Api { calls, count: 90 },
        None,
        |_| Ok(()),
    );
    let first = observed.recv_timeout(Duration::from_secs(2)).unwrap();
    // No early collection. A retention edit four seconds into the interval must
    // neither collect immediately nor restart a five-second wait from this edit.
    assert!(observed.recv_timeout(Duration::from_secs(4)).is_err());
    prefs.history_samples = 300;
    control.set(prefs).unwrap();
    let end = Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(update) = worker.latest.lock().unwrap().take()
            && update.control_revision == control.revision()
        {
            assert_eq!(update.panel.series[0].len(), 300);
            break;
        }
        assert!(Instant::now() < end);
        thread::sleep(Duration::from_millis(5));
    }
    let second = observed.recv_timeout(Duration::from_secs(4)).unwrap();
    let elapsed = second.duration_since(first);
    assert!(
        second.duration_since(launched)
            >= Duration::from_millis(shared::ai_sampling_milliseconds())
    );
    assert!(
        elapsed < Duration::from_secs(8),
        "Presentation edit postponed collection: {elapsed:?}"
    );
    drop(worker);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn cached_unavailable_reports_remain_unavailable_after_retention_edits() {
    let report = Report {
        providers: std::array::from_fn(|_| Err("fixture offline".into())),
        ollama: "fixture unavailable".into(),
        models: Models::default(),
    };
    let mut display = Display::default();
    let prefs = Preferences::default();
    let panel = display.panel_for(report.clone(), 1., &prefs);
    let mut update = Update::new(prefs.clone(), panel, report);
    let report = update.report.clone();
    let label = update.panel.label.clone();
    let mut next = prefs;
    next.history_samples = 300;
    display.resize_cached(&mut update, next, 7);
    assert!(update.panel.series.is_empty());
    assert_eq!(update.panel.label, label);
    assert!(Arc::ptr_eq(&update.report, &report));
    assert_eq!(update.control_revision, 7);
    assert!(update.detail.contains("fixture offline") && update.detail.contains("1495 seconds"));
    assert_eq!(update.accounting.session.total(), 0);
}

#[test]
fn coalesced_controls_keep_collection_invalidations_separate_from_history_revisions() {
    let control = Control::default();
    let mut prefs = Preferences::default();
    control.set(prefs.clone()).unwrap();
    let baseline = control.collection_revision();
    prefs.history_samples = 300;
    control.set(prefs.clone()).unwrap();
    assert_eq!(control.collection_revision(), baseline);
    assert_eq!(control.revision(), 2);
    prefs.metrics_url = "http://127.0.0.1:8890/metrics".into();
    control.set(prefs.clone()).unwrap();
    let source = control.collection_revision();
    assert_ne!(source, baseline);
    prefs.history_samples = 600;
    control.set(prefs.clone()).unwrap();
    assert_eq!(control.collection_revision(), source);
    prefs.accounting.enabled = !prefs.accounting.enabled;
    control.set(prefs.clone()).unwrap();
    let accounting = control.collection_revision();
    assert_ne!(accounting, source);
    prefs.history_samples = 257;
    control.set(prefs).unwrap();
    assert_eq!(control.collection_revision(), accounting);
    control.reset_session();
    assert_ne!(control.collection_revision(), accounting);
    let session = control.collection_revision();
    control.reset_daily();
    assert_ne!(control.collection_revision(), session);
    assert_eq!(control.revision(), 8);
}
