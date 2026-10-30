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
fn retention_edits_preserve_live_accounting_continuity_and_worker_rate_baselines() {
    struct Api(u64);
    impl LocalApi for Api {
        fn get(&mut self, _: Endpoint) -> Result<Vec<u8>, String> {
            self.0 += 10;
            Ok(format!("claude_code_token_usage_total{{type=\"input\"}} {}", self.0).into_bytes())
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
    let worker = Worker::controlled_impl(
        Config { home: root.clone() },
        prefs.clone(),
        control.clone(),
        Api(90),
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
            assert!(Instant::now() < end, "AI retention update not acknowledged");
            thread::sleep(Duration::from_millis(5));
        }
    };
    assert_eq!(receive(0).accounting.session.total(), 0);
    for (index, requested) in [300, 1, 0].into_iter().enumerate() {
        prefs.history_samples = requested;
        control.set(prefs.clone()).unwrap();
        let update = receive(control.revision());
        assert_eq!(update.preferences.history_samples, requested);
        assert_eq!(
            update.panel.series[0].len(),
            prefs.history_capacity() as usize
        );
        assert!(*update.panel.series[0].last().unwrap() > 0.);
        assert_eq!(update.accounting.session.total(), 10 * (index as u64 + 1));
        assert_eq!(update.accounting.daily.total(), 10 * (index as u64 + 1));
    }
    let revision = control.revision();
    prefs.history_samples = 20001;
    assert!(control.set(prefs).is_err());
    assert_eq!(control.revision(), revision);
    drop(worker);
    std::fs::remove_dir_all(root).unwrap();
}
