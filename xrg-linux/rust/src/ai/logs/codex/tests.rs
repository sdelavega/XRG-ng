// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::*;
use serde_json::{Value, json};

pub(in crate::ai::logs) fn context(model: Value) -> String {
    json!({"type":"turn_context","payload":{"model":model}}).to_string()
}
pub(in crate::ai::logs) fn count(total: u64, last: Value, marker: Value) -> String {
    json!({"type":"event_msg","payload":{"type":"token_count","info":{
        "total_token_usage":{"total_tokens":total},
        "last_token_usage":{"total_tokens":last},
        "last_usage_includes_reasoning":marker
    }}})
    .to_string()
}
fn feed(ledger: &mut Ledger, line: impl AsRef<[u8]>) {
    let line = line.as_ref();
    ledger
        .update(Update::parse(line), crate::shared::codex_record(line))
        .unwrap();
}
fn tokens(ledger: &Ledger, model: Option<&str>) -> u64 {
    ledger
        .rows
        .0
        .get(&model.map(String::from))
        .copied()
        .unwrap_or(0)
}
fn conserved(ledger: &Ledger, total: u64) {
    assert_eq!(ledger.total, total);
    assert_eq!(ledger.rows.0.values().sum::<u64>(), total);
}
#[test]
fn switches_partition_only_qualified_deltas_and_ignore_duplicate_snapshots() {
    let mut ledger = Ledger::default();
    feed(&mut ledger, context(json!("a")));
    feed(&mut ledger, count(10, json!(10), json!(true)));
    feed(&mut ledger, context(json!("b")));
    feed(&mut ledger, count(10, json!(10), json!(true)));
    feed(&mut ledger, count(30, json!(20), json!(false)));
    assert_eq!(tokens(&ledger, Some("a")), 10);
    assert_eq!(tokens(&ledger, Some("b")), 20);
    conserved(&ledger, 30);
}
#[test]
fn initial_history_and_unmatched_deltas_stay_unknown() {
    let mut ledger = Ledger::default();
    feed(&mut ledger, context(json!("a")));
    feed(&mut ledger, count(100, json!(10), json!(true)));
    feed(&mut ledger, count(120, json!(20), json!(true)));
    feed(&mut ledger, count(150, json!(40), json!(true)));
    assert_eq!(tokens(&ledger, Some("a")), 20);
    assert_eq!(tokens(&ledger, None), 130);
    conserved(&ledger, 150);
}
#[test]
fn synthetic_and_legacy_usage_never_inherit_a_model() {
    for info in [
        json!({"last_token_usage":{"total_tokens":10}}),
        json!({"last_token_usage":{"total_tokens":10},"last_usage_includes_reasoning":null}),
        json!({"last_token_usage":{"total_tokens":10},"last_usage_includes_reasoning":"true"}),
        json!({"last_usage_includes_reasoning":true}),
        json!({"last_token_usage":{"total_tokens":-1},"last_usage_includes_reasoning":true}),
        json!({"last_token_usage":{"total_tokens":10.5},"last_usage_includes_reasoning":true}),
    ] {
        let mut info = info;
        info["total_token_usage"] = json!({"total_tokens":10});
        let mut ledger = Ledger::default();
        feed(&mut ledger, context(json!("a")));
        feed(
            &mut ledger,
            json!({"type":"event_msg","payload":{"type":"token_count","info":info}}).to_string(),
        );
        conserved(&ledger, 10);
        assert!(ledger.rows.finish().is_none());
    }
}
#[test]
fn malformed_context_and_records_clear_stale_models_without_losing_totals() {
    for invalid in [
        context(Value::Null),
        context(json!(12)),
        context(json!(" ")),
        context(json!("bad\nname")),
        context(json!("x".repeat(1025))),
        r#"{"type":"turn_context","payload":{}}"#.into(),
        r#"{"type":"turn_context","payload":[]}"#.into(),
        "invalid-json".into(),
    ] {
        let mut ledger = Ledger::default();
        feed(&mut ledger, context(json!("a")));
        feed(&mut ledger, count(10, json!(10), json!(true)));
        feed(&mut ledger, invalid);
        feed(&mut ledger, count(20, json!(10), json!(true)));
        assert_eq!(tokens(&ledger, Some("a")), 10);
        assert_eq!(tokens(&ledger, None), 10);
        conserved(&ledger, 20);
    }
}
#[test]
fn routing_and_lifecycle_boundaries_require_a_new_context() {
    for event in [
        "model_reroute",
        "context_compacted",
        "thread_rolled_back",
        "task_started",
        "turn_started",
        "task_complete",
        "turn_complete",
        "turn_aborted",
        "error",
    ] {
        let mut ledger = Ledger::default();
        feed(&mut ledger, context(json!("a")));
        feed(&mut ledger, count(10, json!(10), json!(true)));
        feed(
            &mut ledger,
            json!({"type":"event_msg","payload":{"type":event,"to_model":"b"}}).to_string(),
        );
        feed(&mut ledger, count(20, json!(10), json!(true)));
        feed(&mut ledger, context(json!("c")));
        feed(&mut ledger, count(30, json!(10), json!(true)));
        assert_eq!(tokens(&ledger, Some("a")), 10, "{event}");
        assert_eq!(tokens(&ledger, Some("b")), 0, "{event}");
        assert_eq!(tokens(&ledger, Some("c")), 10, "{event}");
        assert_eq!(tokens(&ledger, None), 10, "{event}");
        conserved(&ledger, 30);
    }
    for kind in ["compacted", "session_meta"] {
        let mut ledger = Ledger::default();
        feed(&mut ledger, context(json!("a")));
        feed(&mut ledger, json!({"type":kind,"payload":{}}).to_string());
        feed(&mut ledger, count(10, json!(10), json!(true)));
        assert!(ledger.rows.finish().is_none());
    }
}
#[test]
fn ordinary_events_preserve_context_and_quota_aliases_never_supply_it() {
    let quota = json!({"type":"event_msg","payload":{"type":"token_count","info":null,
        "rate_limits":{"normal_model_slug":"fake","limit_id":"fake","limit_name":"fake"}}});
    let mut ledger = Ledger::default();
    feed(&mut ledger, quota.to_string());
    feed(&mut ledger, count(10, json!(10), json!(true)));
    feed(&mut ledger, context(json!("real")));
    feed(
        &mut ledger,
        r#"{"type":"response_item","payload":{"type":"message","model":"fake"}}"#,
    );
    feed(
        &mut ledger,
        r#"{"type":"event_msg","payload":{"type":"exec_command_end"}}"#,
    );
    feed(&mut ledger, count(20, json!(10), json!(true)));
    assert_eq!(tokens(&ledger, Some("real")), 10);
    assert_eq!(tokens(&ledger, None), 10);
    conserved(&ledger, 20);
}
#[test]
fn cumulative_regression_discards_the_partition_and_clears_context() {
    let mut ledger = Ledger::default();
    feed(&mut ledger, context(json!("a")));
    feed(&mut ledger, count(100, json!(100), json!(true)));
    feed(&mut ledger, count(5, json!(5), json!(true)));
    feed(&mut ledger, count(10, json!(5), json!(true)));
    assert!(ledger.rows.clone().finish().is_none());
    feed(&mut ledger, context(json!("b")));
    feed(&mut ledger, count(15, json!(5), json!(true)));
    assert_eq!(tokens(&ledger, Some("a")), 0);
    assert_eq!(tokens(&ledger, Some("b")), 5);
    assert_eq!(tokens(&ledger, None), 10);
    conserved(&ledger, 15);
    feed(&mut ledger, count(0, json!(0), json!(true)));
    conserved(&ledger, 0);
    assert!(ledger.rows.finish().is_none());
}
#[test]
fn invalid_cumulative_usage_cannot_leave_a_stale_model_active() {
    let mut ledger = Ledger::default();
    feed(&mut ledger, context(json!("a")));
    feed(
        &mut ledger,
        r#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#,
    );
    feed(&mut ledger, count(10, json!(10), json!(true)));
    conserved(&ledger, 10);
    assert!(ledger.rows.finish().is_none());
}
#[test]
fn excess_models_fold_into_unknown_and_retained_models_continue_updating() {
    let mut ledger = Ledger::default();
    for n in 0..300 {
        feed(&mut ledger, context(json!(format!("m{n}"))));
        feed(&mut ledger, count(n + 1, json!(1), json!(true)));
    }
    feed(&mut ledger, context(json!("m0")));
    feed(&mut ledger, count(310, json!(10), json!(true)));
    conserved(&ledger, 310);
    assert_eq!(tokens(&ledger, None), 45);
    assert_eq!(tokens(&ledger, Some("m0")), 11);
    let rows = ledger.rows.finish().unwrap();
    assert_eq!(rows.len(), 256);
    assert!(
        rows.iter()
            .all(|r| r.cost.is_none() && r.usage.input == 0 && r.usage.output == 0)
    );
}
#[test]
fn model_metadata_without_usage_does_not_consume_groups() {
    let mut ledger = Ledger::default();
    for n in 0..300 {
        feed(&mut ledger, context(json!(format!("m{n}"))));
    }
    feed(&mut ledger, count(10, json!(10), json!(true)));
    assert_eq!(tokens(&ledger, Some("m299")), 10);
    assert_eq!(ledger.rows.0.len(), 1);
}
#[test]
fn cross_session_merge_is_bounded_and_preserves_unknown_and_total() {
    let mut rows = Rows::default();
    for n in 0..300 {
        let mut session = Rows::default();
        session.add(Some(format!("m{n}")), 10).unwrap();
        session.add(None, 2).unwrap();
        rows.merge(&session).unwrap();
    }
    let rows = rows.finish().unwrap();
    assert_eq!(rows.len(), 256);
    assert_eq!(rows.iter().map(|r| r.usage.total).sum::<u64>(), 3600);
    assert_eq!(
        rows.iter().find(|r| r.model.is_none()).unwrap().usage.total,
        1050
    );
}
