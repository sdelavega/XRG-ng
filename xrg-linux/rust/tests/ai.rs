// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use rusqlite::Connection;
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    ai::{
        self, Collector, Config, Display, Endpoint, LocalApi, Reading, Report,
        logs::{Layout, LogScan},
    },
    shared::{self, Usage},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "xrg-ai-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn put(&self, name: &str, bytes: impl AsRef<[u8]>) {
        let path = self.0.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }
    fn db(&self, name: &str, schema: &str) -> Connection {
        let path = self.0.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let conn = Connection::open(path).unwrap();
        conn.execute_batch(schema).unwrap();
        conn
    }
    fn collector(&self) -> Collector {
        Collector::new(Config {
            home: self.0.clone(),
        })
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn claude(id: &str, input: u64, output: u64) -> String {
    format!(
        r#"{{"message":{{"id":"{id}","usage":{{"input_tokens":{input},"output_tokens":{output}}}}}}}"#
    )
}
fn codex(total: u64) -> String {
    format!(
        r#"{{"type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"total_tokens":{total}}}}}}}}}"#
    )
}
#[derive(Default)]
struct Api {
    metrics: Option<String>,
    models: Option<String>,
    running: Option<String>,
    metric_calls: usize,
}
impl LocalApi for Api {
    fn get(&mut self, endpoint: Endpoint) -> Result<Vec<u8>, String> {
        match endpoint {
            Endpoint::Metrics => {
                self.metric_calls += 1;
                &self.metrics
            }
            Endpoint::Models => &self.models,
            Endpoint::Running => &self.running,
        }
        .as_ref()
        .map(|s| s.as_bytes().to_vec())
        .ok_or("Fixture API unavailable".into())
    }
}
#[test]
fn claude_replaces_repeated_messages_and_deduplicates_copies() {
    let f = Fixture::new();
    f.put(
        "logs/p/a.jsonl",
        format!(
            "{}\n{}\n{{broken\n",
            claude("one", 10, 2),
            claude("one", 10, 6)
        ),
    );
    f.put("logs/p/subagents/copy.jsonl", claude("one", 10, 6));
    f.put("logs/p/b.jsonl", claude("two", 20, 1));
    let mut scan = LogScan::new(f.0.join("logs"), Layout::Claude);
    assert_eq!(
        scan.scan().unwrap(),
        Usage {
            input: 30,
            output: 7,
            total: 37
        }
    );
    assert_eq!(scan.scan().unwrap().total, 37);
}
#[test]
fn codex_keeps_last_cumulative_record_and_accepts_complete_eof() {
    let f = Fixture::new();
    f.put(
        "logs/2026/10/27/rollout-one.jsonl",
        format!("{}\n{}\n{{broken\n{}", codex(100), codex(150), codex(170)),
    );
    f.put("logs/not-rollout.jsonl", codex(900));
    let mut scan = LogScan::new(f.0.join("logs"), Layout::Codex);
    assert_eq!(scan.scan().unwrap().total, 170);
}
#[test]
fn changed_logs_append_truncate_replace_and_delete_without_stale_cache() {
    let f = Fixture::new();
    f.put("logs/rollout-a.jsonl", codex(10));
    let mut scan = LogScan::new(f.0.join("logs"), Layout::Codex);
    assert_eq!(scan.scan().unwrap().total, 10);
    f.put(
        "logs/rollout-a.jsonl",
        format!("{}\n{}", codex(10), codex(50)),
    );
    assert_eq!(scan.scan().unwrap().total, 50);
    f.put("logs/rollout-a.jsonl", codex(1));
    assert_eq!(scan.scan().unwrap().total, 1);
    f.put("replace", codex(70));
    fs::rename(f.0.join("replace"), f.0.join("logs/rollout-a.jsonl")).unwrap();
    assert_eq!(scan.scan().unwrap().total, 70);
    fs::remove_file(f.0.join("logs/rollout-a.jsonl")).unwrap();
    assert_eq!(scan.scan().unwrap().total, 0);
}
#[test]
fn gemini_session_and_jsonl_share_swift_decoders() {
    let f = Fixture::new();
    f.put("tmp/hash/chats/session-a.json",r#"{"messages":[{"tokens":{"input":4,"output":2}}, {"tokens":"invalid"}, {"tokens":{"input":7,"output":3,"total":14}}]}"#);
    f.put(
        "tmp/hash/chats/session-b.jsonl",
        "{\"tokens\":{\"input\":5,\"output\":1}}\n{broken",
    );
    f.put(
        "tmp/hash/not-chats/session-c.json",
        r#"{"messages":[{"tokens":{"total":999}}]}"#,
    );
    let mut scan = LogScan::new(f.0.join("tmp"), Layout::Gemini);
    assert_eq!(
        scan.scan().unwrap(),
        Usage {
            input: 16,
            output: 6,
            total: 26
        }
    );
}
#[test]
fn failures_never_publish_a_partial_total_and_recover() {
    let f = Fixture::new();
    f.put("logs/p/a.jsonl", claude("a", 10, 0));
    f.put("logs/p/b.jsonl", claude("b", 20, 0));
    let mut scan = LogScan::new(f.0.join("logs"), Layout::Claude);
    assert_eq!(scan.scan().unwrap().total, 30);
    f.put("logs/p/a.jsonl", claude("a", 30, 0));
    fs::File::create(f.0.join("logs/p/b.jsonl"))
        .unwrap()
        .set_len(64 * 1024 * 1024 + 1)
        .unwrap();
    assert!(scan.scan().unwrap_err().contains("64 MiB"));
    f.put("logs/p/b.jsonl", claude("b", 40, 0));
    assert_eq!(scan.scan().unwrap().total, 70);
}
#[test]
fn rejects_total_overflow_and_ignores_symlinks_and_fifo() {
    let f = Fixture::new();
    f.put("logs/p/a.jsonl", claude("a", u64::MAX, 0));
    f.put("logs/p/b.jsonl", claude("b", 1, 0));
    let mut scan = LogScan::new(f.0.join("logs"), Layout::Claude);
    assert!(scan.scan().is_err());
    fs::remove_file(f.0.join("logs/p/b.jsonl")).unwrap();
    std::os::unix::fs::symlink(f.0.join("logs/p/a.jsonl"), f.0.join("logs/p/copy.jsonl")).unwrap();
    assert_eq!(scan.scan().unwrap().total, u64::MAX);
    let path = std::ffi::CString::new(f.0.join("fifo").as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    assert!(ai::database::snapshot(&f.0.join("fifo"), true).is_err());
}
const HERMES: &str = "CREATE TABLE sessions(model TEXT,input_tokens INTEGER,output_tokens INTEGER,actual_cost_usd REAL,estimated_cost_usd REAL);";
#[test]
fn hermes_cost_precedence_nulls_and_zero_actual_cost() {
    let f = Fixture::new();
    let c = f.db("state.db", HERMES);
    c.execute_batch("INSERT INTO sessions VALUES('m',10,3,0,9),('n',20,2,NULL,0.5),('z',NULL,NULL,0.1,NULL),('',900,900,9,9);").unwrap();
    let v = ai::database::snapshot(&f.0.join("state.db"), true).unwrap();
    assert_eq!(v.usage.total, 35);
    assert_eq!(v.cost, Some(0.6));
    c.execute_batch("INSERT INTO sessions VALUES('x',1,1,NULL,NULL);")
        .unwrap();
    assert_eq!(
        ai::database::snapshot(&f.0.join("state.db"), true)
            .unwrap()
            .cost,
        None
    );
}
#[test]
fn sqlite_read_only_missing_locked_and_malformed_are_unavailable() {
    let f = Fixture::new();
    assert!(ai::database::snapshot(&f.0.join("missing.db"), true).is_err());
    assert!(!f.0.join("missing.db").exists());
    let c = f.db("state.db", HERMES);
    c.execute_batch("INSERT INTO sessions VALUES('m',-1,4,0,0);")
        .unwrap();
    assert!(ai::database::snapshot(&f.0.join("state.db"), true).is_err());
    c.execute_batch(
        "DELETE FROM sessions; INSERT INTO sessions VALUES('m',1,4,0,0); BEGIN EXCLUSIVE;",
    )
    .unwrap();
    assert!(ai::database::snapshot(&f.0.join("state.db"), true).is_err());
    c.execute_batch("ROLLBACK;").unwrap();
    assert_eq!(
        ai::database::snapshot(&f.0.join("state.db"), true)
            .unwrap()
            .usage
            .total,
        5
    );
}
#[test]
fn sqlite_reads_committed_wal_without_changing_writer_state() {
    let f = Fixture::new();
    let c = f.db("state.db", HERMES);
    c.execute_batch("PRAGMA journal_mode=WAL; INSERT INTO sessions VALUES('m',3,4,0.1,NULL); BEGIN; INSERT INTO sessions VALUES('m',100,100,1,NULL);").unwrap();
    assert_eq!(
        ai::database::snapshot(&f.0.join("state.db"), true)
            .unwrap()
            .usage
            .total,
        7
    );
    c.execute_batch("COMMIT;").unwrap();
    assert_eq!(
        ai::database::snapshot(&f.0.join("state.db"), true)
            .unwrap()
            .usage
            .total,
        207
    );
}
#[test]
fn claude_uses_one_source_and_missing_providers_are_not_idle_samples() {
    let f = Fixture::new();
    f.put(".claude/projects/p/a.jsonl", claude("a", 10, 2));
    let _c=f.db(".claude/monitoring/claude_usage.db","CREATE TABLE sessions(tokens_used INTEGER,estimated_cost REAL); INSERT INTO sessions VALUES(999,2);");
    let mut api = Api {
        metrics: Some("claude_code_token_usage_total{type=\"input\"} 900".into()),
        ..Api::default()
    };
    let mut collector = f.collector();
    let report = collector.sample(&mut api);
    assert_eq!(report.providers[0].as_ref().unwrap().usage.total, 12);
    assert_eq!(api.metric_calls, 0);
    assert!(report.providers[1..].iter().all(Result::is_err));
    fs::remove_dir_all(f.0.join(".claude/projects")).unwrap();
    assert_eq!(
        collector.sample(&mut api).providers[0]
            .as_ref()
            .unwrap()
            .usage
            .total,
        999
    );
    assert_eq!(api.metric_calls, 0);
}
#[test]
fn metrics_and_ollama_inventory_are_validated_without_inventing_tokens() {
    let f = Fixture::new();
    let mut collector = f.collector();
    let mut api=Api{metrics:Some("claude_code_token_usage_total{type=\"input\"} 10\nclaude_code.token.usage{type=\"cacheRead\"} 20\nclaude_code_cost_usage_total 0.25\nunrelated_tokens_input 900".into()),models:Some(r#"{"models":[{"name":"a"},{"name":"b"}]}"#.into()),running:Some(r#"{"models":[{"name":"a"}]}"#.into()),..Api::default()};
    let report = collector.sample(&mut api);
    assert_eq!(report.providers[0].as_ref().unwrap().usage.total, 30);
    assert_eq!(report.providers[0].as_ref().unwrap().cost, Some(0.25));
    assert!(report.ollama.contains("2 installed, 1 loaded (a)"));
    api.metrics = Some("claude_code_token_usage_total{type=\"input\"} NaN".into());
    assert!(collector.sample(&mut api).providers[0].is_err());
    api.metrics = Some("claude_code_token_usage_total{type=\"input\"} 0".into());
    let r = collector.sample(&mut api);
    assert_eq!(r.providers[0].as_ref().unwrap().usage.total, 0);
    assert_eq!(r.providers[0].as_ref().unwrap().cost, None);
    assert!(shared::model_names(br#"{"models":[{"name":"a\nb"}]}"#).is_none());
}
fn report(total: u64, source: &str) -> Report {
    Report {
        providers: [
            Ok(Reading {
                usage: Usage {
                    total,
                    ..Usage::default()
                },
                cost: None,
                source: source.into(),
            }),
            Err("missing".into()),
            Err("missing".into()),
            Err("missing".into()),
        ],
        ollama: "Ollama fixture".into(),
        models: ai::Models::default(),
    }
}
#[test]
fn rate_baselines_reset_on_source_change_failure_recovery_and_counter_reset() {
    let mut display = Display::default();
    assert!(
        display
            .panel(report(100, "log"), 1.)
            .label
            .starts_with("0 tok/s")
    );
    assert!(
        display
            .panel(report(150, "log"), 6.)
            .label
            .starts_with("10 tok/s")
    );
    assert!(
        display
            .panel(report(900, "db"), 11.)
            .label
            .starts_with("0 tok/s")
    );
    let mut failed = report(0, "db");
    failed.providers[0] = Err("locked".into());
    let panel = display.panel(failed, 16.);
    assert!(panel.series.is_empty());
    assert!(panel.detail.contains("900 (stale)"));
    assert!(
        display
            .panel(report(1200, "db"), 21.)
            .label
            .starts_with("0 tok/s")
    );
    assert!(
        display
            .panel(report(1, "db"), 26.)
            .label
            .starts_with("0 tok/s")
    );
    assert!(
        display
            .panel(report(51, "db"), 31.)
            .label
            .starts_with("10 tok/s")
    );
}

#[test]
fn oversized_records_and_database_row_budget_fail_explicitly() {
    let f = Fixture::new();
    f.put("logs/p/a.jsonl", vec![b'x'; 8 * 1024 * 1024 + 1]);
    let mut scan = LogScan::new(f.0.join("logs"), Layout::Claude);
    assert!(scan.scan().unwrap_err().contains("8 MiB"));
    let c = f.db("state.db", HERMES);
    c.execute_batch("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100001) INSERT INTO sessions SELECT 'm',1,1,0,0 FROM n;").unwrap();
    assert!(ai::database::snapshot(&f.0.join("state.db"), true).is_err());
}

#[test]
fn ai_preferences_validate_local_urls_and_absolute_paths_without_probing_them() {
    for url in [
        "http://127.0.0.1:18889/metrics",
        "http://127.0.0.2/metrics",
        "http://[::1]:11434/ollama",
        "http://[::1]",
    ] {
        assert!(ai::validate_url(url).is_ok(), "{url}");
    }
    for url in [
        "https://127.0.0.1/",
        "http://example.com/",
        "http://localhost/",
        "file:///tmp/source",
        "--help",
        "http://127.0.0.1:0/",
        "http://127.0.0.1:65536/",
        "http://127.0.0.1@remote/",
        "http://127.0.0.1/?key=secret",
        "http://127.0.0.1/#x",
        "http://127.0.0.1/\n",
        "http://[127.0.0.1]/",
        "http://::1/",
        "http://[::ffff:127.0.0.1]/",
    ] {
        assert!(ai::validate_url(url).is_err(), "{url}");
    }
    let mut preferences = ai::Preferences {
        claude_logs: Some("/not-present/custom projects".into()),
        ..Default::default()
    };
    assert!(preferences.validate().is_ok());
    preferences.claude_logs = Some("relative".into());
    assert!(preferences.validate().is_err());
    preferences.claude_logs = Some("/tmp/line\nbreak".into());
    assert!(preferences.validate().is_err());
}
#[test]
fn disabled_providers_do_not_open_roots_databases_or_local_endpoints() {
    struct NoApi;
    impl LocalApi for NoApi {
        fn get(&mut self, _: Endpoint) -> Result<Vec<u8>, String> {
            panic!("Disabled API was queried")
        }
    }
    let f = Fixture::new();
    f.put("logs", "not a directory");
    f.put("database", "not SQLite");
    let preferences = ai::Preferences {
        enabled: [false; 4],
        ollama: false,
        claude_logs: Some(f.0.join("logs")),
        claude_database: Some(f.0.join("database")),
        codex_logs: Some(f.0.join("logs")),
        gemini_logs: Some(f.0.join("logs")),
        hermes_database: Some(f.0.join("database")),
        ..Default::default()
    };
    let mut collector =
        Collector::configured(Config { home: f.0.clone() }, preferences.clone()).unwrap();
    let report = collector.sample(&mut NoApi);
    assert!(
        report
            .providers
            .iter()
            .all(|r| r.as_ref().unwrap_err().contains("Disabled"))
    );
    let panel = Display::default().panel_for(report, 1., &preferences);
    assert!(panel.series.is_empty());
    assert_eq!(panel.label, "AI token monitoring disabled");
}
#[test]
fn explicit_claude_source_selection_never_falls_back_or_adds_other_sources() {
    let f = Fixture::new();
    f.put("custom/p/a.jsonl", claude("custom", 10, 2));
    let _db = f.db("custom.db", "CREATE TABLE sessions(tokens_used INTEGER,estimated_cost REAL); INSERT INTO sessions VALUES(500,1);");
    let mut preferences = ai::Preferences {
        enabled: [true, false, false, false],
        ollama: false,
        claude_source: ai::ClaudeSource::Logs,
        claude_logs: Some(f.0.join("custom")),
        claude_database: Some(f.0.join("custom.db")),
        ..Default::default()
    };
    let mut api = Api {
        metrics: Some("claude_code_token_usage_total{type=\"input\"} 900".into()),
        ..Default::default()
    };
    let sample = |prefs: ai::Preferences, api: &mut Api| {
        Collector::configured(Config { home: f.0.clone() }, prefs)
            .unwrap()
            .sample(api)
            .providers[0]
            .clone()
    };
    assert_eq!(
        sample(preferences.clone(), &mut api).unwrap().usage.total,
        12
    );
    preferences.claude_logs = Some(f.0.join("missing"));
    assert!(sample(preferences.clone(), &mut api).is_err());
    preferences.claude_source = ai::ClaudeSource::Database;
    assert_eq!(
        sample(preferences.clone(), &mut api).unwrap().usage.total,
        500
    );
    preferences.claude_source = ai::ClaudeSource::Metrics;
    assert_eq!(sample(preferences, &mut api).unwrap().usage.total, 900);
}
#[test]
fn custom_provider_paths_and_ollama_inventory_keep_exact_model_names_and_partial_state() {
    let f = Fixture::new();
    f.put("custom-codex/rollout-custom.jsonl", codex(17));
    let c = f.db("custom-hermes.db", HERMES);
    c.execute_batch("INSERT INTO sessions VALUES('m',3,4,0.2,NULL);")
        .unwrap();
    let preferences = ai::Preferences {
        enabled: [false, true, false, true],
        codex_logs: Some(f.0.join("custom-codex")),
        hermes_database: Some(f.0.join("custom-hermes.db")),
        ..Default::default()
    };
    let mut collector = Collector::configured(Config { home: f.0.clone() }, preferences).unwrap();
    let mut api = Api {
        models: Some(r#"{"models":[{"name":"fixture-model:latest"},{"name":"other"}]}"#.into()),
        ..Default::default()
    };
    let report = collector.sample(&mut api);
    assert_eq!(report.providers[1].as_ref().unwrap().usage.total, 17);
    assert_eq!(report.providers[3].as_ref().unwrap().usage.total, 7);
    assert_eq!(
        report.models.installed.as_ref().unwrap(),
        &["fixture-model:latest", "other"]
    );
    assert!(report.models.running.is_err());
    assert!(report.ollama.contains("loaded models unavailable"));
    api.models = None;
    api.running = Some(r#"{"models":[{"name":"loaded-only"}]}"#.into());
    let report = collector.sample(&mut api);
    assert!(report.models.installed.is_err());
    assert_eq!(report.models.running.as_ref().unwrap(), &["loaded-only"]);
    assert!(report.ollama.contains("1 loaded"));
}
#[test]
fn source_configuration_changes_reset_the_graph_and_rate_baseline() {
    let mut display = Display::default();
    let first = ai::Preferences::default();
    display.panel_for(report(10, "same parser"), 0., &first);
    assert!(
        display
            .panel_for(report(20, "same parser"), 5., &first)
            .series[0]
            .last()
            .is_some_and(|v| *v > 0.)
    );
    let second = ai::Preferences {
        metrics_url: "http://127.0.0.1:18889/metrics".into(),
        ..first
    };
    let changed = display.panel_for(report(1000, "same parser"), 10., &second);
    assert!(changed.series[0].iter().all(|v| *v == 0.));
}
