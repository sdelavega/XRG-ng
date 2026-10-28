// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::*;
fn stamp(size: usize) -> Stamp {
    Stamp {
        device: 1,
        inode: 2,
        size: size as u64,
        seconds: 3,
        nanos: 4,
        changed_seconds: 5,
        changed_nanos: 6,
    }
}
fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(2)
}
fn codex(total: u64) -> String {
    format!(
        r#"{{"type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"total_tokens":{total}}}}}}}}}"#
    )
}
fn read(bytes: &[u8], old: Option<&Entry>) -> Entry {
    parse(
        bytes,
        Layout::Codex,
        false,
        stamp(bytes.len()),
        deadline(),
        old,
    )
    .unwrap()
}
#[test]
fn verified_append_reuses_the_decoded_prefix_and_never_the_eof_line() {
    let first = format!("{}\n{}", codex(10), codex(20));
    let entry = read(first.as_bytes(), None);
    let checkpoint = entry.checkpoint.as_ref().unwrap();
    assert_eq!(checkpoint.length, codex(10).len() + 1);
    assert_eq!(checkpoint.parsed.anonymous.total, 10);
    assert_eq!(entry.parsed.anonymous.total, 20);
    let next = format!("{first}\n{}", codex(30));
    let reused = super::checkpoint(next.as_bytes(), stamp(next.len()), Some(&entry), deadline())
        .unwrap()
        .unwrap();
    assert!(Arc::ptr_eq(&reused.parsed, &checkpoint.parsed));
    assert_eq!(
        read(next.as_bytes(), Some(&entry)).parsed.anonymous.total,
        30
    );
}
#[test]
fn an_unterminated_record_can_become_invalid_after_append() {
    let first = format!("{}\n{}", codex(10), codex(20));
    let entry = read(first.as_bytes(), None);
    assert_eq!(entry.parsed.anonymous.total, 20);
    let next = format!("{first}invalid-json");
    assert_eq!(
        read(next.as_bytes(), Some(&entry)).parsed.anonymous.total,
        10
    );
}
#[test]
fn prefix_digest_detects_changes_far_from_file_boundaries() {
    let first = format!(
        "header\n{}\n{}\n{}\nfooter\n",
        "x".repeat(8192),
        codex(10),
        "y".repeat(8192)
    );
    let entry = read(first.as_bytes(), None);
    let next = format!("{}longer\n", first.replace("tokens\":10", "tokens\":99"));
    assert!(
        super::checkpoint(next.as_bytes(), stamp(next.len()), Some(&entry), deadline())
            .unwrap()
            .is_none()
    );
    assert_eq!(
        read(next.as_bytes(), Some(&entry)).parsed.anonymous.total,
        99
    );
}
#[test]
fn replacement_truncation_and_same_size_rewrites_do_not_reuse_prefixes() {
    let first = format!("{}\n", codex(10));
    let entry = read(first.as_bytes(), None);
    let next = format!("{first}{}\n", codex(20));
    let mut replaced = stamp(next.len());
    replaced.inode += 1;
    assert!(
        super::checkpoint(next.as_bytes(), replaced, Some(&entry), deadline())
            .unwrap()
            .is_none()
    );
    replaced = stamp(next.len());
    replaced.device += 1;
    assert!(
        super::checkpoint(next.as_bytes(), replaced, Some(&entry), deadline())
            .unwrap()
            .is_none()
    );
    for bytes in [first.as_bytes(), &first.as_bytes()[..first.len() - 1]] {
        assert!(
            super::checkpoint(bytes, stamp(bytes.len()), Some(&entry), deadline())
                .unwrap()
                .is_none()
        );
    }
}
#[test]
fn failed_append_parsing_cannot_mutate_the_cached_checkpoint_or_snapshot() {
    let first = format!("{}\n", codex(10));
    let entry = read(first.as_bytes(), None);
    let next = format!("{first}{}\n{}", codex(20), "x".repeat(RECORD_LIMIT + 1));
    assert!(
        parse(
            next.as_bytes(),
            Layout::Codex,
            false,
            stamp(next.len()),
            deadline(),
            Some(&entry)
        )
        .is_err()
    );
    assert_eq!(entry.parsed.anonymous.total, 10);
    assert_eq!(
        entry.checkpoint.as_ref().unwrap().parsed.anonymous.total,
        10
    );
    let next = format!("{first}{}\n", codex(30));
    assert_eq!(
        read(next.as_bytes(), Some(&entry)).parsed.anonymous.total,
        30
    );
}
#[test]
fn complete_newline_snapshots_share_storage_and_hashing_obeys_deadlines() {
    let first = format!("{}\n", codex(10));
    let entry = read(first.as_bytes(), None);
    assert!(Arc::ptr_eq(
        &entry.parsed,
        &entry.checkpoint.as_ref().unwrap().parsed
    ));
    assert!(digest(first.as_bytes(), Instant::now()).is_err());
}
