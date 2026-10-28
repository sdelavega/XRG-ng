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
