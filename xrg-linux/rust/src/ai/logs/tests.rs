// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::*;
use std::io::Cursor;
fn parse(
    bytes: &[u8],
    layout: Layout,
    session: bool,
    stamp: Stamp,
    deadline: Instant,
    old: Option<&Entry>,
) -> Result<Entry, String> {
    let mut budget = IO_BUDGET;
    stream::parse(
        &mut Cursor::new(bytes),
        layout,
        session,
        stamp,
        deadline,
        old,
        &mut budget,
    )
}
fn checkpoint<'a>(
    bytes: &[u8],
    stamp: Stamp,
    old: Option<&'a Entry>,
    deadline: Instant,
) -> Result<Option<&'a Checkpoint>, String> {
    let mut cursor = Cursor::new(bytes);
    let mut budget = IO_BUDGET;
    let mut input = stream::Input::new(&mut cursor, &mut budget, deadline);
    stream::checkpoint(&mut input, stamp, old).map(|(checkpoint, _)| checkpoint)
}
fn digest(bytes: &[u8], deadline: Instant) -> Result<blake3::Hash, String> {
    let mut cursor = Cursor::new(bytes);
    let mut budget = IO_BUDGET;
    let mut input = stream::Input::new(&mut cursor, &mut budget, deadline);
    stream::digest(&mut input, bytes.len()).map(|hash| hash.finalize())
}
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
fn attributed(model: &str, total: u64, last: u64) -> String {
    use super::codex::tests::{context, count};
    use serde_json::json;
    format!(
        "{}\n{}",
        context(json!(model)),
        count(total, json!(last), json!(true))
    )
}
#[test]
fn eof_replay_removes_attribution_when_an_appended_record_becomes_invalid() {
    let first = format!("{}\n{}", attributed("a", 10, 10), attributed("b", 20, 10));
    let entry = read(first.as_bytes(), None);
    assert_eq!(entry.parsed.codex.rows.clone().finish().unwrap().len(), 2);
    let next = format!("{first}invalid-json");
    let entry = read(next.as_bytes(), Some(&entry));
    let rows = entry.parsed.codex.rows.clone().finish().unwrap();
    assert_eq!(entry.parsed.anonymous.total, 10);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].model.as_deref(), Some("a"));
    assert_eq!(rows[0].usage.total, 10);
}
#[test]
fn resumed_attribution_matches_a_fresh_complete_scan() {
    let f = ScanFixture::new();
    let records: Vec<_> = (0..100)
        .map(|n| attributed(&format!("m{}", n % 3), (n + 1) * 10, 10))
        .collect();
    let mut data = records.join("\n");
    f.put("rollout-a.jsonl", &data);
    let mut scan = f.scanner();
    let first = finish(&mut scan, 71);
    assert_eq!(first.usage.total, 1000);
    assert_eq!(first.models, f.scanner().scan_details().unwrap().models);
    data.push_str(&format!("\n{}", attributed("appended", 1010, 10)));
    f.put("rollout-a.jsonl", data);
    let next = finish(&mut scan, 71);
    assert_eq!(next.usage.total, 1010);
    assert_eq!(next.models, f.scanner().scan_details().unwrap().models);
    assert_eq!(
        next.models
            .unwrap()
            .iter()
            .map(|r| r.usage.total)
            .sum::<u64>(),
        1010
    );
}
#[test]
fn rewritten_and_replaced_files_discard_old_model_partitions() {
    let f = ScanFixture::new();
    f.put("rollout-a.jsonl", attributed("old", 100, 100));
    let mut scan = f.scanner();
    assert_eq!(
        scan.scan_details().unwrap().models.unwrap()[0]
            .model
            .as_deref(),
        Some("old")
    );
    for (model, total) in [("new", 100), ("short", 2)] {
        f.put("rollout-a.jsonl", attributed(model, total, total));
        let result = scan.scan_details().unwrap();
        assert_eq!(result.usage.total, total);
        let rows = result.models.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].model.as_deref(), Some(model));
    }
    f.put("replacement", attributed("replacement", 50, 50));
    std::fs::rename(f.0.join("replacement"), f.0.join("rollout-a.jsonl")).unwrap();
    let rows = scan.scan_details().unwrap().models.unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].model.as_deref(), Some("replacement"));
}
#[test]
fn provider_rows_include_unattributed_usage_from_other_sessions() {
    let f = ScanFixture::new();
    f.put("rollout-a.jsonl", codex(200));
    f.put("rollout-b.jsonl", attributed("recorded", 10, 10));
    let scan = f.scanner().scan_details().unwrap();
    assert_eq!(scan.usage.total, 210);
    let rows = scan.models.unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].model, None);
    assert_eq!(rows[0].usage.total, 200);
    assert_eq!(rows.iter().map(|r| r.usage.total).sum::<u64>(), 210);
}
#[test]
fn failed_append_cannot_mutate_cached_attribution() {
    let first = format!("{}\n", attributed("old", 10, 10));
    let entry = read(first.as_bytes(), None);
    let original = entry.parsed.codex.rows.clone().finish();
    let next = format!(
        "{first}{}\n{}",
        attributed("new", 20, 10),
        "x".repeat(RECORD_LIMIT + 1)
    );
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
    assert_eq!(entry.parsed.codex.rows.clone().finish(), original);
    assert_eq!(
        entry
            .checkpoint
            .as_ref()
            .unwrap()
            .parsed
            .codex
            .rows
            .clone()
            .finish(),
        original
    );
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
    let reused = self::checkpoint(next.as_bytes(), stamp(next.len()), Some(&entry), deadline())
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
        self::checkpoint(next.as_bytes(), stamp(next.len()), Some(&entry), deadline())
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
        self::checkpoint(next.as_bytes(), replaced, Some(&entry), deadline())
            .unwrap()
            .is_none()
    );
    replaced = stamp(next.len());
    replaced.device += 1;
    assert!(
        self::checkpoint(next.as_bytes(), replaced, Some(&entry), deadline())
            .unwrap()
            .is_none()
    );
    for bytes in [first.as_bytes(), &first.as_bytes()[..first.len() - 1]] {
        assert!(
            self::checkpoint(bytes, stamp(bytes.len()), Some(&entry), deadline())
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

struct Meter {
    cursor: Cursor<Vec<u8>>,
    bytes: u64,
    largest: usize,
    calls: usize,
    short: usize,
    interrupts: usize,
    fail_after: Option<u64>,
}
impl Meter {
    fn new(bytes: Vec<u8>) -> Self {
        Self {
            cursor: Cursor::new(bytes),
            bytes: 0,
            largest: 0,
            calls: 0,
            short: usize::MAX,
            interrupts: 0,
            fail_after: None,
        }
    }
}
impl std::io::Read for Meter {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        use std::io::{Error, ErrorKind};
        self.calls += 1;
        self.largest = self.largest.max(buffer.len());
        if self.interrupts > 0 {
            self.interrupts -= 1;
            return Err(Error::from(ErrorKind::Interrupted));
        }
        if self.fail_after.is_some_and(|limit| self.bytes >= limit) {
            return Err(Error::other("injected read failure"));
        }
        let limit = self.short.min(buffer.len()).min(
            self.fail_after
                .map_or(usize::MAX, |v| (v - self.bytes) as usize),
        );
        let count = self.cursor.read(&mut buffer[..limit])?;
        self.bytes += count as u64;
        Ok(count)
    }
}
impl std::io::Seek for Meter {
    fn seek(&mut self, position: std::io::SeekFrom) -> std::io::Result<u64> {
        std::io::Seek::seek(&mut self.cursor, position)
    }
}
#[test]
fn cold_and_verified_append_reads_use_small_blocks_and_hash_each_completed_byte() {
    let first = format!("{}\n{}\n", codex(10), "ignored".repeat(20_000));
    let mut meter = Meter::new(first.as_bytes().to_vec());
    let mut budget = IO_BUDGET;
    let entry = stream::parse(
        &mut meter,
        Layout::Codex,
        false,
        stamp(first.len()),
        deadline(),
        None,
        &mut budget,
    )
    .unwrap();
    assert_eq!(meter.bytes, first.len() as u64);
    assert!(meter.largest <= stream::CHUNK);
    assert_eq!(entry.parsed.anonymous.total, 10);
    assert_eq!(
        entry.checkpoint.as_ref().unwrap().hash,
        blake3::hash(first.as_bytes())
    );
    let next = format!("{first}ignored-tail\n");
    let mut meter = Meter::new(next.as_bytes().to_vec());
    let mut budget = IO_BUDGET;
    let appended = stream::parse(
        &mut meter,
        Layout::Codex,
        false,
        stamp(next.len()),
        deadline(),
        Some(&entry),
        &mut budget,
    )
    .unwrap();
    assert_eq!(meter.bytes, next.len() as u64);
    assert!(meter.largest <= stream::CHUNK);
    assert!(Arc::ptr_eq(&appended.parsed, &entry.parsed));
    assert_eq!(
        appended.checkpoint.as_ref().unwrap().hash,
        blake3::hash(next.as_bytes())
    );
    assert_eq!(IO_BUDGET - budget, meter.bytes);
}
#[test]
fn rewritten_middle_is_reparsed_and_both_input_reads_charge_the_io_budget() {
    let first = format!(
        "{}\n{}\n{}\n",
        "x".repeat(70_000),
        codex(10),
        "y".repeat(70_000)
    );
    let old = read(first.as_bytes(), None);
    let next = format!("{}tail\n", first.replace("tokens\":10", "tokens\":99"));
    let mut meter = Meter::new(next.as_bytes().to_vec());
    let mut budget = IO_BUDGET;
    let entry = stream::parse(
        &mut meter,
        Layout::Codex,
        false,
        stamp(next.len()),
        deadline(),
        Some(&old),
        &mut budget,
    )
    .unwrap();
    assert_eq!(entry.parsed.anonymous.total, 99);
    assert_eq!(meter.bytes, (first.len() + next.len()) as u64);
    assert_eq!(IO_BUDGET - budget, meter.bytes);
    assert!(meter.largest <= stream::CHUNK);
    assert_eq!(
        entry.checkpoint.as_ref().unwrap().hash,
        blake3::hash(next.as_bytes())
    );
    assert_eq!(old.parsed.anonymous.total, 10);
}
#[test]
fn a_rewrite_that_exhausts_the_read_budget_cannot_mutate_cached_counts() {
    let first = format!("{}\n{}\n", codex(10), "x".repeat(70_000));
    let old = read(first.as_bytes(), None);
    let next = format!("{}tail\n", first.replace("tokens\":10", "tokens\":99"));
    let mut meter = Meter::new(next.as_bytes().to_vec());
    let mut budget = next.len() as u64;
    let error = stream::parse(
        &mut meter,
        Layout::Codex,
        false,
        stamp(next.len()),
        deadline(),
        Some(&old),
        &mut budget,
    )
    .err()
    .unwrap();
    assert!(error.contains("I/O budget"));
    assert_eq!(meter.bytes, next.len() as u64);
    assert_eq!(budget, 0);
    assert_eq!(old.parsed.anonymous.total, 10);
    assert_eq!(
        old.checkpoint.as_ref().unwrap().hash,
        blake3::hash(first.as_bytes())
    );
}
#[test]
fn interrupted_and_short_reads_preserve_records_and_io_errors_preserve_checkpoints() {
    let first = format!("{}\n", codex(10));
    let old = read(first.as_bytes(), None);
    let next = format!("{first}{}", codex(20));
    let mut meter = Meter::new(next.as_bytes().to_vec());
    meter.short = 7;
    meter.interrupts = 3;
    let mut budget = IO_BUDGET;
    let entry = stream::parse(
        &mut meter,
        Layout::Codex,
        false,
        stamp(next.len()),
        deadline(),
        Some(&old),
        &mut budget,
    )
    .unwrap();
    assert_eq!(entry.parsed.anonymous.total, 20);
    assert_eq!(
        entry.checkpoint.as_ref().unwrap().parsed.anonymous.total,
        10
    );
    assert_eq!(meter.bytes, next.len() as u64);
    let mut meter = Meter::new(next.as_bytes().to_vec());
    meter.fail_after = Some(first.len() as u64 + 5);
    let mut budget = IO_BUDGET;
    assert!(
        stream::parse(
            &mut meter,
            Layout::Codex,
            false,
            stamp(next.len()),
            deadline(),
            Some(&old),
            &mut budget
        )
        .err()
        .unwrap()
        .contains("injected read failure")
    );
    assert_eq!(old.parsed.anonymous.total, 10);
    assert_eq!(old.checkpoint.as_ref().unwrap().parsed.anonymous.total, 10);
}
#[test]
fn record_buffers_accept_the_exact_limit_and_reject_oversize_without_reading_the_file() {
    use std::io::BufReader;
    for newline in [false, true] {
        let mut bytes = vec![b'x'; RECORD_LIMIT];
        if newline {
            bytes.push(b'\n');
        }
        let mut reader = BufReader::with_capacity(stream::CHUNK, Cursor::new(bytes));
        let mut line = Vec::new();
        stream::record(&mut reader, &mut line, deadline()).unwrap();
        assert_eq!(line.len(), RECORD_LIMIT + usize::from(newline));
        assert!(line.capacity() <= RECORD_LIMIT + 1);
    }
    let mut meter = Meter::new(vec![b'x'; 3 * RECORD_LIMIT]);
    let mut budget = IO_BUDGET;
    let error = stream::parse(
        &mut meter,
        Layout::Codex,
        false,
        stamp(3 * RECORD_LIMIT),
        deadline(),
        None,
        &mut budget,
    )
    .err()
    .unwrap();
    assert!(error.contains("record exceeds 8 MiB"));
    assert!(meter.bytes <= (RECORD_LIMIT + stream::CHUNK) as u64);
    assert!(meter.largest <= stream::CHUNK);
}
#[test]
fn pretty_gemini_sessions_use_bounded_reads_and_reject_oversize_before_io() {
    let bytes = b"{\n\"messages\":[{\"tokens\":{\"input\":4,\"output\":2}}]\n}";
    let mut meter = Meter::new(bytes.to_vec());
    meter.short = 5;
    let mut budget = IO_BUDGET;
    let entry = stream::parse(
        &mut meter,
        Layout::Gemini,
        true,
        stamp(bytes.len()),
        deadline(),
        None,
        &mut budget,
    )
    .unwrap();
    assert_eq!(
        entry.parsed.anonymous,
        Usage {
            input: 4,
            output: 2,
            total: 6
        }
    );
    assert!(entry.checkpoint.is_none());
    assert_eq!(meter.bytes, bytes.len() as u64);
    let mut meter = Meter::new(Vec::new());
    assert!(
        stream::parse(
            &mut meter,
            Layout::Gemini,
            true,
            stamp(RECORD_LIMIT + 1),
            deadline(),
            None,
            &mut budget
        )
        .err()
        .unwrap()
        .contains("session exceeds 8 MiB")
    );
    assert_eq!(meter.calls, 0);
}
#[test]
fn premature_eof_and_expired_deadlines_cannot_publish_partial_results() {
    let bytes = format!("{}\n", codex(10));
    let mut meter = Meter::new(bytes.as_bytes().to_vec());
    let mut budget = IO_BUDGET;
    assert!(
        stream::parse(
            &mut meter,
            Layout::Codex,
            false,
            stamp(bytes.len() + 1),
            deadline(),
            None,
            &mut budget
        )
        .err()
        .unwrap()
        .contains("changed while reading")
    );
    let mut meter = Meter::new(bytes.as_bytes().to_vec());
    assert!(
        stream::parse(
            &mut meter,
            Layout::Codex,
            false,
            stamp(bytes.len()),
            Instant::now(),
            None,
            &mut budget
        )
        .is_err()
    );
    assert_eq!(meter.calls, 0);
}

#[test]
fn underreported_sizes_cannot_turn_extra_content_into_an_empty_or_complete_log() {
    let first = format!("{}\n", codex(10));
    let bytes = format!("{first}{}\n", codex(20));
    for claimed in [0, first.len()] {
        let mut meter = Meter::new(bytes.as_bytes().to_vec());
        let mut budget = IO_BUDGET;
        assert!(
            stream::parse(
                &mut meter,
                Layout::Codex,
                false,
                stamp(claimed),
                deadline(),
                None,
                &mut budget
            )
            .err()
            .unwrap()
            .contains("changed while reading")
        );
        assert_eq!(meter.bytes, claimed as u64 + 1);
        assert_eq!(IO_BUDGET - budget, meter.bytes);
    }
    let valid = br#"{"messages":[{"tokens":{"input":4}}]}"#;
    let mut bytes = valid.to_vec();
    bytes.extend_from_slice(b"extra");
    let mut meter = Meter::new(bytes);
    let mut budget = IO_BUDGET;
    assert!(
        stream::parse(
            &mut meter,
            Layout::Gemini,
            true,
            stamp(valid.len()),
            deadline(),
            None,
            &mut budget
        )
        .err()
        .unwrap()
        .contains("changed while reading")
    );
    assert_eq!(meter.bytes, valid.len() as u64 + 1);
}

#[test]
fn resumable_cold_reads_and_prefix_verification_charge_each_byte_once() {
    let first = format!("{}\n{}\n{}", codex(10), "ignored".repeat(20_000), codex(20));
    let mut meter = Meter::new(first.as_bytes().to_vec());
    let mut job = stream::Job::new(Layout::Codex, stamp(first.len()), None).unwrap();
    let mut polls = 0;
    let old = loop {
        let mut budget = 4093;
        let before = meter.bytes;
        let result = job.advance(&mut meter, &mut budget, deadline()).unwrap();
        assert_eq!(4093 - budget, meter.bytes - before);
        assert!(meter.bytes - before <= 4093);
        polls += 1;
        if let Some(entry) = result {
            break entry;
        }
        assert!(polls < 100);
    };
    assert!(polls > 1);
    assert_eq!(old.parsed.anonymous.total, 20);
    assert_eq!(meter.bytes, first.len() as u64);
    let next = format!("{first}\n{}", codex(30));
    let mut meter = Meter::new(next.as_bytes().to_vec());
    let mut job = stream::Job::new(Layout::Codex, stamp(next.len()), Some(&old)).unwrap();
    let appended = loop {
        let mut budget = 4093;
        if let Some(entry) = job.advance(&mut meter, &mut budget, deadline()).unwrap() {
            break entry;
        }
    };
    assert_eq!(meter.bytes, next.len() as u64);
    assert!(meter.largest <= stream::CHUNK);
    assert_eq!(appended.parsed.anonymous.total, 30);
    assert_eq!(appended.checkpoint.unwrap().parsed.anonymous.total, 20);
    assert_eq!(old.parsed.anonymous.total, 20);
}

#[test]
fn yielding_during_rewritten_prefix_verification_reparses_and_keeps_old_counts() {
    let first = format!("{}\n{}\n", "x".repeat(70_000), codex(10));
    let old = read(first.as_bytes(), None);
    let next = format!("{}tail\n", first.replace("tokens\":10", "tokens\":99"));
    let mut job = stream::Job::new(Layout::Codex, stamp(next.len()), Some(&old)).unwrap();
    let mut meter = Meter::new(next.as_bytes().to_vec());
    let entry = loop {
        let mut budget = 4093;
        let result = job.advance(&mut meter, &mut budget, deadline()).unwrap();
        assert_eq!(old.parsed.anonymous.total, 10);
        if let Some(entry) = result {
            break entry;
        }
    };
    assert_eq!(entry.parsed.anonymous.total, 99);
    assert_eq!(meter.bytes, (first.len() + next.len()) as u64);
}

#[test]
fn an_expired_slice_preserves_progress_and_io_errors_remain_errors() {
    let bytes = format!("{}\n{}", codex(10), codex(20));
    let mut meter = Meter::new(bytes.as_bytes().to_vec());
    let mut job = stream::Job::new(Layout::Codex, stamp(bytes.len()), None).unwrap();
    let mut budget = 23;
    assert!(
        job.advance(&mut meter, &mut budget, deadline())
            .unwrap()
            .is_none()
    );
    let read = meter.bytes;
    let mut budget = IO_BUDGET;
    assert!(
        job.advance(&mut meter, &mut budget, Instant::now())
            .unwrap()
            .is_none()
    );
    assert_eq!(meter.bytes, read);
    meter.fail_after = Some(read);
    assert!(
        job.advance(&mut meter, &mut budget, deadline())
            .err()
            .unwrap()
            .contains("injected read failure")
    );
    meter.fail_after = None;
    assert_eq!(
        job.advance(&mut meter, &mut budget, deadline())
            .unwrap()
            .unwrap()
            .parsed
            .anonymous
            .total,
        20
    );
    assert_eq!(meter.bytes, bytes.len() as u64);
}

struct ScanFixture(std::path::PathBuf);
impl ScanFixture {
    fn new() -> Self {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "xrg-ai-resume-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn put(&self, name: &str, bytes: impl AsRef<[u8]>) {
        use std::sync::atomic::{AtomicU64, Ordering};
        use std::time::UNIX_EPOCH;
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = self.0.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, bytes).unwrap();
        // Same-size rewrites can land inside the filesystem's timestamp
        // granularity (measured 4.000 ms steps on Raspberry Pi 5), making
        // the scanner's metadata stamp collide and serve the cached parse.
        // Pin a fresh, distinct mtime on every write so each rewrite is
        // deterministic and always visible, whatever the clock does.
        let tick = NEXT.fetch_add(1, Ordering::Relaxed);
        let at = UNIX_EPOCH + Duration::from_secs(1_700_000_000 + tick);
        fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_accessed(at).set_modified(at))
            .unwrap();
    }
    fn scanner(&self) -> LogScan {
        // put() pins distinct mtimes, so these scans keep exact cache-hit I/O
        // accounting; racy_rewrites_* cover the production settle window.
        LogScan {
            settle: Duration::ZERO,
            ..LogScan::new(self.0.clone(), Layout::Codex)
        }
    }
}
impl Drop for ScanFixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn finish(scan: &mut LogScan, budget: u64) -> Scan {
    for _ in 0..1000 {
        match scan.scan_with_budget(budget, deadline()) {
            Ok(scan) => return scan,
            Err(error) => assert!(error.contains("continuing next poll"), "{error}"),
        }
    }
    panic!("Bounded scan did not make progress");
}
#[test]
fn complete_provider_totals_publish_only_after_all_slices_and_then_use_the_cache() {
    let f = ScanFixture::new();
    f.put(
        "rollout-a.jsonl",
        format!("{}\n{}", codex(10), "ignored\n".repeat(20_000)),
    );
    f.put("rollout-b.jsonl", codex(20));
    let mut scan = f.scanner();
    assert!(scan.scan_with_budget(4093, deadline()).is_err());
    assert!(scan.cache.is_empty());
    assert_eq!(finish(&mut scan, 4093).usage.total, 30);
    assert!(scan.pending.is_none());
    // An unchanged sweep does no data I/O, even with no read allowance.
    assert_eq!(
        scan.scan_with_budget(0, deadline()).unwrap().usage.total,
        30
    );
}
#[test]
#[cfg(all(test, unix))] // Asserts inode/ctime rotation identity (POSIX metadata).
fn replacements_truncation_and_same_size_rewrites_invalidate_inflight_work() {
    for replacement in [false, true] {
        let f = ScanFixture::new();
        let first = format!("{}\n{}", codex(10), "ignored\n".repeat(20_000));
        f.put("rollout-a.jsonl", &first);
        let mut scan = f.scanner();
        assert!(scan.scan_with_budget(4093, deadline()).is_err());
        if replacement {
            f.put("new", codex(70));
            fs::rename(f.0.join("new"), f.0.join("rollout-a.jsonl")).unwrap();
        } else {
            f.put("rollout-a.jsonl", codex(70));
        }
        assert_eq!(finish(&mut scan, 4093).usage.total, 70);
        // Restore mtime to prove ctime still invalidates an unfinished snapshot.
        f.put("rollout-a.jsonl", &first);
        assert!(scan.scan_with_budget(4093, deadline()).is_err());
        // The rewrite below restores the cached mtime on purpose, so the
        // invalidation must come from ctime rotation. Kernel file timestamps
        // advance in coarse ticks (measured 4.000 ms on Raspberry Pi 5), and
        // the whole sequence can run inside one tick on fast boards, leaving
        // the rewrite indistinguishable from the cached parse. Sleep past two
        // ticks so the rewrite deterministically lands on a fresh ctime.
        std::thread::sleep(Duration::from_millis(30));
        let modified = fs::metadata(f.0.join("rollout-a.jsonl"))
            .unwrap()
            .modified()
            .unwrap();
        f.put(
            "rollout-a.jsonl",
            first.replace("tokens\":10", "tokens\":99"),
        );
        File::open(f.0.join("rollout-a.jsonl"))
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(modified))
            .unwrap();
        assert_eq!(finish(&mut scan, 4093).usage.total, 99);
    }
}
#[test]
fn deleted_pending_logs_are_dropped_without_poisoning_new_work() {
    let f = ScanFixture::new();
    f.put(
        "rollout-a.jsonl",
        format!("{}\n{}", codex(10), "ignored\n".repeat(20_000)),
    );
    let mut scan = f.scanner();
    assert!(scan.scan_with_budget(4093, deadline()).is_err());
    assert!(scan.pending.is_some());
    fs::remove_file(f.0.join("rollout-a.jsonl")).unwrap();
    f.put("rollout-b.jsonl", codex(40));
    assert_eq!(finish(&mut scan, 4093).usage.total, 40);
    assert!(scan.pending.is_none());
}

#[test]
fn resumable_claude_appends_keep_copy_deduplication_models_and_cache_atomic() {
    let f = ScanFixture::new();
    let message = |tokens, model| {
        serde_json::json!({"message":{"id":"shared", "model":model, "usage":{"input_tokens":tokens}}}).to_string()
    };
    let first = format!("{}\n{}", message(10, "old"), "ignored\n".repeat(2000));
    f.put("a.jsonl", &first);
    f.put("copy.jsonl", message(10, "old"));
    // Windows file times are 1601-epoch FILETIMEs, so NTFS itself can hold
    // these 1970 stamps; FAT-family volumes (FAT/exFAT) cannot: their date
    // fields start at 1980 with 2-second granularity, which would collapse
    // the ordering this test relies on if the scratch dir sat on one. Only
    // the ordering matters, so on Windows use a modern base date.
    #[cfg(windows)]
    const TIME_BASE: u64 = 1_000_000_000; // 2001-09-09, past every filesystem floor.
    #[cfg(not(windows))]
    const TIME_BASE: u64 = 0;
    let set_time = |name, seconds| {
        // Windows SetFileTime needs FILE_WRITE_ATTRIBUTES, which a read-only
        // File::open handle lacks; a write handle carries it everywhere.
        #[cfg(windows)]
        let file = fs::OpenOptions::new()
            .write(true)
            .open(f.0.join(name))
            .unwrap();
        #[cfg(not(windows))]
        let file = File::open(f.0.join(name)).unwrap();
        file.set_times(
            fs::FileTimes::new()
                .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(TIME_BASE + seconds)),
        )
        .unwrap()
    };
    set_time("a.jsonl", 100);
    set_time("copy.jsonl", 200);
    let mut scan = LogScan::new(f.0.clone(), Layout::Claude);
    assert_eq!(finish(&mut scan, 4093).usage.total, 10);
    f.put("a.jsonl", format!("{first}{}", message(30, "new")));
    set_time("a.jsonl", 300);
    assert!(scan.scan_with_budget(4093, deadline()).is_err());
    assert_eq!(
        scan.cache[&f.0.join("a.jsonl")].parsed.identified["shared"]
            .usage
            .total,
        10
    );
    let next = finish(&mut scan, 4093);
    assert_eq!(next.usage.total, 30);
    let models = next.models.unwrap();
    assert_eq!(models.len(), 1);
    assert_eq!(models[0].model.as_deref(), Some("new"));
    assert_eq!(models[0].usage.total, 30);
}
#[test]
fn oversize_records_after_multiple_slices_never_replace_a_good_snapshot() {
    let f = ScanFixture::new();
    f.put("rollout-a.jsonl", format!("{}\n", codex(10)));
    let mut scan = f.scanner();
    assert_eq!(scan.scan().unwrap().total, 10);
    f.put(
        "rollout-a.jsonl",
        format!("{}\n{}", codex(20), "x".repeat(RECORD_LIMIT + 1)),
    );
    let mut failed = false;
    for _ in 0..100 {
        let error = scan
            .scan_with_budget(128 * 1024, deadline())
            .err()
            .expect("Partial totals must not publish");
        assert_eq!(
            scan.cache[&f.0.join("rollout-a.jsonl")]
                .parsed
                .anonymous
                .total,
            10
        );
        if error.contains("record exceeds 8 MiB") {
            failed = true;
            break;
        }
        assert!(error.contains("continuing next poll"), "{error}");
    }
    assert!(failed);
    assert!(scan.pending.is_none());
    f.put("rollout-a.jsonl", codex(30));
    assert_eq!(finish(&mut scan, 4093).usage.total, 30);
}
#[test]
fn an_exact_byte_budget_can_finish_the_eof_probe_next_poll_without_recounting() {
    let bytes = format!("{}\n{}", codex(10), codex(20));
    let mut job = stream::Job::new(Layout::Codex, stamp(bytes.len()), None).unwrap();
    let mut meter = Meter::new(bytes.as_bytes().to_vec());
    let mut budget = bytes.len() as u64;
    assert!(
        job.advance(&mut meter, &mut budget, deadline())
            .unwrap()
            .is_none()
    );
    assert_eq!(budget, 0);
    let mut budget = 1;
    let entry = job
        .advance(&mut meter, &mut budget, deadline())
        .unwrap()
        .unwrap();
    assert_eq!(entry.parsed.anonymous.total, 20);
    assert_eq!(entry.checkpoint.unwrap().parsed.anonymous.total, 10);
    assert_eq!(meter.bytes, bytes.len() as u64);
    assert_eq!(budget, 1);
}
#[test]
fn gemini_jsonl_resumes_alongside_whole_document_sessions() {
    let f = ScanFixture::new();
    f.put(
        "hash/chats/session-a.json",
        r#"{"model":"legacy","messages":[{"tokens":{"input":7}}]}"#,
    );
    f.put(
        "hash/chats/session-b.jsonl",
        format!(
            "{}\n{}\n{}",
            r#"{"model":"stream","tokens":{"input":3}}"#,
            "ignored\n".repeat(2000),
            r#"{"model":"stream","tokens":{"output":5}}"#
        ),
    );
    let mut scan = LogScan::new(f.0.clone(), Layout::Gemini);
    let result = finish(&mut scan, 4093);
    assert_eq!(result.usage.total, 15);
    let models = result.models.unwrap();
    assert_eq!(
        models
            .iter()
            .find(|m| m.model.as_deref() == Some("legacy"))
            .unwrap()
            .usage
            .total,
        7
    );
    assert_eq!(
        models
            .iter()
            .find(|m| m.model.as_deref() == Some("stream"))
            .unwrap()
            .usage
            .total,
        8
    );
}
#[test]
fn appending_during_an_unfinished_read_restarts_without_double_counting_eof() {
    use std::io::Write;
    let f = ScanFixture::new();
    let anonymous =
        |tokens| serde_json::json!({"message":{"usage":{"input_tokens":tokens}}}).to_string();
    f.put(
        "a.jsonl",
        format!("{}\n{}", anonymous(10), "ignored\n".repeat(2000)),
    );
    let mut scan = LogScan::new(f.0.clone(), Layout::Claude);
    assert!(scan.scan_with_budget(4093, deadline()).is_err());
    OpenOptions::new()
        .append(true)
        .open(f.0.join("a.jsonl"))
        .unwrap()
        .write_all(anonymous(20).as_bytes())
        .unwrap();
    assert_eq!(finish(&mut scan, 4093).usage.total, 30);
    OpenOptions::new()
        .append(true)
        .open(f.0.join("a.jsonl"))
        .unwrap()
        .write_all(b"invalid\n")
        .unwrap();
    assert_eq!(finish(&mut scan, 4093).usage.total, 10);
}
#[test]
fn an_earlier_active_log_does_not_discard_a_later_files_read_progress() {
    let f = ScanFixture::new();
    f.put(
        "rollout-z.jsonl",
        format!("{}\n{}", codex(20), "ignored\n".repeat(2000)),
    );
    let mut scan = f.scanner();
    for tick in 1..100 {
        f.put("rollout-a.jsonl", codex(tick));
        if let Ok(result) = scan.scan_with_budget(4093, deadline()) {
            assert_eq!(result.usage.total, tick + 20);
            return;
        }
    }
    panic!("An earlier active log repeatedly discarded the later file's progress");
}

#[test]
fn codex_components_replace_cumulative_snapshots_without_adding_subfields() {
    let bytes=concat!(
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":6,\"output_tokens\":4,\"total_tokens\":10}}}}\n",
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":12,\"cached_input_tokens\":10,\"output_tokens\":8,\"reasoning_output_tokens\":7,\"total_tokens\":20}}}}\n"
    ).as_bytes();
    let mut budget = IO_BUDGET;
    let entry = stream::parse(
        &mut std::io::Cursor::new(bytes),
        Layout::Codex,
        false,
        stamp(bytes.len()),
        Instant::now() + Duration::from_secs(3),
        None,
        &mut budget,
    )
    .unwrap();
    assert_eq!(
        entry.parsed.anonymous,
        Usage {
            input: 12,
            output: 8,
            total: 20
        }
    );
}

#[test]
#[cfg(all(test, unix))] // Asserts inode/ctime rotation identity (POSIX metadata).
fn complete_inventory_boundaries_include_import_remove_replace_truncate_and_masked_rollbacks() {
    let f = ScanFixture::new();
    f.put("rollout-a.jsonl", codex(10));
    let mut scan = f.scanner();
    let first = finish(&mut scan, IO_BUDGET);
    f.put("rollout-a.jsonl", codex(20));
    let ordinary = finish(&mut scan, IO_BUDGET);
    assert_eq!(ordinary.continuity, first.continuity);
    f.put("rollout-b.jsonl", codex(10000));
    let imported = finish(&mut scan, IO_BUDGET);
    assert_ne!(imported.continuity, ordinary.continuity);
    assert_eq!(finish(&mut scan, IO_BUDGET).continuity, imported.continuity);
    f.put("rollout-a.jsonl", codex(10));
    f.put("rollout-b.jsonl", codex(20000));
    let rollback = finish(&mut scan, IO_BUDGET);
    assert!(rollback.usage.total > imported.usage.total);
    assert_ne!(rollback.continuity, imported.continuity);
    fs::remove_file(f.0.join("rollout-b.jsonl")).unwrap();
    let removed = finish(&mut scan, IO_BUDGET);
    assert_ne!(removed.continuity, rollback.continuity);
    f.put("replacement", codex(10000));
    fs::rename(f.0.join("replacement"), f.0.join("rollout-a.jsonl")).unwrap();
    let replaced = finish(&mut scan, IO_BUDGET);
    assert_ne!(replaced.continuity, removed.continuity);
    // Reduce bytes while increasing the cumulative count in the same inode.
    f.put(
        "rollout-a.jsonl",
        format!("{}\n{}", codex(20000), "ignored\n".repeat(100)),
    );
    let padded = finish(&mut scan, IO_BUDGET);
    f.put("rollout-a.jsonl", codex(30000));
    let truncated = finish(&mut scan, IO_BUDGET);
    assert_ne!(truncated.continuity, padded.continuity);
}

#[test]
fn unfinished_and_failed_sweeps_cannot_commit_a_draft_continuity_inventory() {
    let f = ScanFixture::new();
    f.put("rollout-a.jsonl", codex(10));
    let mut scan = f.scanner();
    let first = finish(&mut scan, IO_BUDGET);
    f.put(
        "rollout-b.jsonl",
        format!("{}\n{}", codex(10000), "ignored\n".repeat(1000)),
    );
    assert!(scan.scan_with_budget(10, deadline()).is_err());
    assert_eq!(scan.continuity, first.continuity);
    assert_eq!(scan.published.as_ref().unwrap().len(), 1);
    let result = finish(&mut scan, 4096);
    assert_ne!(result.continuity, first.continuity);
    assert_eq!(result.usage.total, 10010);
    assert_eq!(finish(&mut scan, 0).continuity, result.continuity);
}

fn collide(scan: &mut LogScan, path: &Path) {
    // Model a coarse-timestamp filesystem: the snapshot was read early in a
    // tick and the rewrite landed later in that tick, so it reports the very
    // stamp the cached snapshot recorded.
    let stamp = Stamp::from(&fs::symlink_metadata(path).unwrap());
    let entry = scan.cache.get_mut(path).unwrap();
    entry.stamp = stamp;
    entry.observed = std::time::UNIX_EPOCH + stamp.changed() + Duration::from_millis(1);
}
fn rewrite_keeping_mtime(f: &ScanFixture, name: &str, bytes: &str) {
    let path = f.0.join(name);
    let old = fs::metadata(&path).unwrap();
    assert_eq!(old.len(), bytes.len() as u64, "rewrite must keep the size");
    fs::write(&path, bytes).unwrap();
    File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(old.modified().unwrap()))
        .unwrap();
    assert_eq!(
        fs::metadata(&path).unwrap().modified().unwrap(),
        old.modified().unwrap()
    );
}
fn only_model(scan: &Scan) -> String {
    let rows = scan.models.as_ref().unwrap();
    assert_eq!(rows.len(), 1);
    rows[0].model.clone().unwrap()
}
#[test]
fn racy_rewrites_with_identical_size_and_mtime_publish_new_totals_models_and_continuity() {
    for colliding in [false, true] {
        let f = ScanFixture::new();
        let path = f.0.join("rollout-a.jsonl");
        f.put("rollout-a.jsonl", attributed("model-a", 100, 100));
        let mut scan = LogScan::new(f.0.clone(), Layout::Codex);
        let first = finish(&mut scan, IO_BUDGET);
        assert_eq!(
            (first.usage.total, only_model(&first)),
            (100, "model-a".into())
        );

        rewrite_keeping_mtime(&f, "rollout-a.jsonl", &attributed("model-b", 200, 200));
        if colliding {
            collide(&mut scan, &path);
        }
        let grown = finish(&mut scan, IO_BUDGET);
        assert_eq!(
            (grown.usage.total, only_model(&grown)),
            (200, "model-b".into())
        );
        assert_eq!(grown.continuity, first.continuity);

        // Fewer tokens in the same bytes and inode is a new baseline.
        rewrite_keeping_mtime(&f, "rollout-a.jsonl", &attributed("model-c", 100, 100));
        if colliding {
            collide(&mut scan, &path);
        }
        let reset = finish(&mut scan, IO_BUDGET);
        assert_eq!(
            (reset.usage.total, only_model(&reset)),
            (100, "model-c".into())
        );
        assert_ne!(reset.continuity, grown.continuity);
    }
}
#[test]
fn racy_rewrites_recheck_young_snapshots_and_never_reread_settled_ones() {
    let f = ScanFixture::new();
    let path = f.0.join("rollout-a.jsonl");
    f.put(
        "rollout-a.jsonl",
        format!("{}\n{}", codex(10), "ignored\n".repeat(20_000)),
    );
    let mut scan = LogScan::new(f.0.clone(), Layout::Codex);
    assert_eq!(finish(&mut scan, IO_BUDGET).usage.total, 10);
    // Just written: an equal stamp is not yet proof, so the next poll reads.
    let Err(error) = scan.scan_with_budget(0, deadline()) else {
        panic!("A young snapshot was served without re-reading");
    };
    assert!(error.contains("continuing next poll"), "{error}");
    assert_eq!(finish(&mut scan, IO_BUDGET).usage.total, 10);
    // Once observed past the settle window, unchanged sweeps do no data I/O.
    let entry = scan.cache.get_mut(&path).unwrap();
    entry.observed =
        std::time::UNIX_EPOCH + entry.stamp.changed() + SETTLE + Duration::from_secs(1);
    for _ in 0..3 {
        assert_eq!(
            scan.scan_with_budget(0, deadline()).unwrap().usage.total,
            10
        );
    }
    // A settled snapshot is still dropped by any visible stamp change.
    f.put(
        "rollout-a.jsonl",
        format!("{}\n{}", codex(20), "ignored\n".repeat(20_000)),
    );
    assert_eq!(finish(&mut scan, IO_BUDGET).usage.total, 20);
}
