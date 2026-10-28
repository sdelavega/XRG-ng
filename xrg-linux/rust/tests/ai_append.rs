// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::ai::logs::{Layout, LogScan};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "xrg-ai-append-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn put(&self, path: &str, text: &str) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }
    fn append(&self, path: &str, text: &str) {
        OpenOptions::new()
            .append(true)
            .open(self.0.join(path))
            .unwrap()
            .write_all(text.as_bytes())
            .unwrap();
    }
    fn scan(&self, layout: Layout) -> LogScan {
        LogScan::new(self.0.clone(), layout)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn claude(id: Option<&str>, model: &str, total: u64) -> String {
    let mut value = serde_json::json!({"message":{"model":model,"usage":{"input_tokens":total}}});
    if let Some(id) = id {
        value["message"]["id"] = id.into();
    }
    value.to_string()
}
fn codex(total: u64) -> String {
    format!(
        r#"{{"type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"total_tokens":{total}}}}}}}}}"#
    )
}
#[test]
fn anonymous_eof_and_partial_records_are_counted_exactly_once_after_append() {
    let f = Fixture::new();
    f.put(
        "a.jsonl",
        &format!("{}\n{}", claude(None, "a", 10), claude(None, "a", 20)),
    );
    let mut scan = f.scan(Layout::Claude);
    assert_eq!(scan.scan().unwrap().total, 30);
    f.append("a.jsonl", &format!("\n{}", claude(None, "b", 30)));
    assert_eq!(scan.scan().unwrap().total, 60);
    f.append("a.jsonl", "invalid\n{\"message\":");
    assert_eq!(scan.scan().unwrap().total, 30);
    f.append("a.jsonl", "{\"usage\":{\"input_tokens\":7}}}");
    assert_eq!(scan.scan().unwrap().total, 37);
    assert_eq!(
        scan.scan_details()
            .unwrap()
            .models
            .unwrap()
            .iter()
            .map(|m| m.usage.total)
            .sum::<u64>(),
        37
    );
}
#[test]
fn appended_message_replacements_update_model_and_copied_id_deduplication() {
    let f = Fixture::new();
    f.put("a.jsonl", &format!("{}\n", claude(Some("id"), "old", 10)));
    f.put("copy.jsonl", &claude(Some("id"), "old", 10));
    let mut scan = f.scan(Layout::Claude);
    assert_eq!(scan.scan().unwrap().total, 10);
    f.append("a.jsonl", &claude(Some("id"), "new", 20));
    let details = scan.scan_details().unwrap();
    assert_eq!(details.usage.total, 20);
    let models = details.models.unwrap();
    assert_eq!(models.len(), 1);
    assert_eq!(models[0].model.as_deref(), Some("new"));
}
#[test]
fn a_growing_file_with_a_rewritten_middle_discards_old_prefix_counts() {
    let f = Fixture::new();
    let first = format!(
        "{}\n{}\n{}\n",
        claude(Some("a"), "a", 1),
        claude(Some("b"), "b", 2),
        claude(Some("c"), "c", 3)
    );
    f.put("a.jsonl", &first);
    let mut scan = f.scan(Layout::Claude);
    assert_eq!(scan.scan().unwrap().total, 6);
    f.put(
        "a.jsonl",
        &format!(
            "{}{}\n",
            first.replace("\"input_tokens\":2", "\"input_tokens\":9"),
            claude(Some("d"), "d", 4)
        ),
    );
    assert_eq!(scan.scan().unwrap().total, 17);
}
#[test]
fn gemini_jsonl_appends_but_full_json_sessions_are_always_replaced() {
    let f = Fixture::new();
    f.put("hash/chats/session-a.jsonl", "{\"tokens\":{\"input\":3}}\n");
    f.put(
        "hash/chats/session-b.json",
        "{\"messages\":[{\"tokens\":{\"input\":4}}]}",
    );
    let mut scan = f.scan(Layout::Gemini);
    assert_eq!(scan.scan().unwrap().total, 7);
    f.append("hash/chats/session-a.jsonl", "{\"tokens\":{\"input\":5}}");
    f.put(
        "hash/chats/session-b.json",
        "{\"messages\":[{\"tokens\":{\"input\":10}},{\"tokens\":{\"input\":20}}]}",
    );
    assert_eq!(scan.scan().unwrap().total, 38);
}
#[test]
fn oversized_append_failure_recovers_without_publishing_partial_counts() {
    let f = Fixture::new();
    f.put("rollout-a.jsonl", &format!("{}\n", codex(10)));
    let mut scan = f.scan(Layout::Codex);
    assert_eq!(scan.scan().unwrap().total, 10);
    f.append(
        "rollout-a.jsonl",
        &format!("{}\n{}", codex(20), "x".repeat(8 * 1024 * 1024 + 1)),
    );
    assert!(scan.scan().unwrap_err().contains("8 MiB"));
    f.put("rollout-a.jsonl", &format!("{}\n{}", codex(10), codex(30)));
    assert_eq!(scan.scan().unwrap().total, 30);
}
#[test]
fn append_total_overflow_is_atomic_and_reset_recovers() {
    let f = Fixture::new();
    f.put("a.jsonl", &format!("{}\n", claude(None, "m", u64::MAX)));
    let mut scan = f.scan(Layout::Claude);
    assert_eq!(scan.scan().unwrap().total, u64::MAX);
    f.append("a.jsonl", &claude(None, "m", 1));
    assert!(scan.scan().is_err());
    f.put("a.jsonl", &claude(None, "m", 0));
    assert_eq!(scan.scan().unwrap().total, 0);
}
#[test]
fn same_size_rewrite_with_restored_mtime_still_invalidates_the_cache() {
    let f = Fixture::new();
    f.put("rollout-a.jsonl", &codex(10));
    let path = f.0.join("rollout-a.jsonl");
    let modified = fs::metadata(&path).unwrap().modified().unwrap();
    let mut scan = f.scan(Layout::Codex);
    assert_eq!(scan.scan().unwrap().total, 10);
    f.put("rollout-a.jsonl", &codex(20));
    fs::File::open(path)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(modified))
        .unwrap();
    assert_eq!(scan.scan().unwrap().total, 20);
}
