// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Metadata-cached bounded scans. Only a complete provider sweep is published.
use super::{ModelUsage, models::Totals};
use crate::shared::{self, Usage};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
const FILE_LIMIT: u64 = 64 * 1024 * 1024;
const RECORD_LIMIT: usize = 8 * 1024 * 1024;
const ENTRY_LIMIT: usize = 20_000;
const USAGE_LIMIT: usize = 100_000;

#[derive(Clone, Copy, Debug)]
pub enum Layout {
    Claude,
    Codex,
    Gemini,
}
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    device: u64,
    inode: u64,
    size: u64,
    seconds: i64,
    nanos: i64,
    changed_seconds: i64,
    changed_nanos: i64,
}
impl Stamp {
    fn from(m: &fs::Metadata) -> Self {
        Self {
            device: m.dev(),
            inode: m.ino(),
            size: m.len(),
            seconds: m.mtime(),
            nanos: m.mtime_nsec(),
            changed_seconds: m.ctime(),
            changed_nanos: m.ctime_nsec(),
        }
    }
}
#[derive(Clone)]
struct Recorded {
    usage: Usage,
    models: Vec<ModelUsage>,
}
#[derive(Clone, Default)]
struct Parsed {
    anonymous: Usage,
    anonymous_models: Totals,
    identified: BTreeMap<String, Recorded>,
}
struct Checkpoint {
    length: usize,
    hash: blake3::Hash,
    parsed: Arc<Parsed>,
}
struct Entry {
    stamp: Stamp,
    parsed: Arc<Parsed>,
    checkpoint: Option<Checkpoint>,
}
pub struct Scan {
    pub usage: Usage,
    pub models: Option<Vec<ModelUsage>>,
}
pub struct LogScan {
    root: PathBuf,
    layout: Layout,
    cache: BTreeMap<PathBuf, Entry>,
}
impl LogScan {
    pub fn new(root: PathBuf, layout: Layout) -> Self {
        Self {
            root,
            layout,
            cache: BTreeMap::new(),
        }
    }
    pub fn scan(&mut self) -> Result<Usage, String> {
        self.scan_details().map(|s| s.usage)
    }
    pub fn scan_details(&mut self) -> Result<Scan, String> {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut paths = Vec::new();
        let mut visited = 0;
        discover(
            &self.root,
            self.layout,
            0,
            deadline,
            &mut visited,
            &mut paths,
        )?;
        paths.sort();
        // Prune after complete discovery, before admitting new records. Otherwise
        // deleting old logs could leave the cache permanently stuck at its cap.
        let keep: BTreeSet<_> = paths.iter().cloned().collect();
        self.cache.retain(|path, _| keep.contains(path));
        let mut budget = 128 * 1024 * 1024u64;
        let mut cached_records: usize =
            self.cache.values().map(|e| e.parsed.identified.len()).sum();
        for path in &paths {
            check(deadline)?;
            let before = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
            if !before.is_file() {
                return Err("Log changed type during scan".into());
            }
            let stamp = Stamp::from(&before);
            if self.cache.get(path).is_some_and(|old| old.stamp == stamp) {
                continue;
            }
            if stamp.size > FILE_LIMIT {
                return Err("Log exceeds the 64 MiB per-file limit".into());
            }
            if stamp.size > budget {
                return Err("Log scan budget reached; continuing next poll".into());
            }
            budget -= stamp.size;
            let file = open_regular(path)?;
            if Stamp::from(&file.metadata().map_err(|e| e.to_string())?) != stamp {
                return Err("Log changed while opening; retrying".into());
            }
            let mut bytes = Vec::new();
            (&file)
                .take(FILE_LIMIT + 1)
                .read_to_end(&mut bytes)
                .map_err(|e| e.to_string())?;
            if bytes.len() as u64 != stamp.size {
                return Err("Log changed while reading; retrying".into());
            }
            let entry = parse(
                &bytes,
                self.layout,
                path.extension().is_some_and(|e| e == "json"),
                stamp,
                deadline,
                self.cache.get(path),
            )?;
            if Stamp::from(&file.metadata().map_err(|e| e.to_string())?) != stamp
                || Stamp::from(&fs::symlink_metadata(path).map_err(|e| e.to_string())?) != stamp
            {
                return Err("Log changed during parsing; retrying".into());
            }
            let old_count = self
                .cache
                .get(path)
                .map_or(0, |e| e.parsed.identified.len());
            let next_count = cached_records - old_count + entry.parsed.identified.len();
            if next_count > USAGE_LIMIT {
                return Err("Provider message cache limit exceeded".into());
            }
            cached_records = next_count;
            self.cache.insert(path.clone(), entry);
        }
        let mut total = Usage::default();
        let mut models = Totals::default();
        // Claude IDs are global, so copied/subagent transcripts cannot count the
        // same assistant message twice. Newest file snapshot wins deterministically.
        let mut identified = BTreeMap::new();
        for entry in self.cache.values() {
            check(deadline)?;
            total = add(total, entry.parsed.anonymous)?;
            for row in entry.parsed.anonymous_models.rows() {
                models.add(row.clone())?;
            }
            for (id, usage) in &entry.parsed.identified {
                check(deadline)?;
                if identified.len() >= USAGE_LIMIT && !identified.contains_key(id) {
                    return Err("Provider message identity limit exceeded".into());
                }
                let stamp = (entry.stamp.seconds, entry.stamp.nanos);
                let value = identified.entry(id).or_insert((stamp, usage));
                if stamp >= value.0 {
                    *value = (stamp, usage);
                }
            }
        }
        for (_, usage) in identified.values() {
            check(deadline)?;
            total = add(total, usage.usage)?;
            for row in &usage.models {
                models.add(row.clone())?;
            }
        }
        Ok(Scan {
            usage: total,
            models: (!matches!(self.layout, Layout::Codex)).then(|| models.finish()),
        })
    }
}
fn add(a: Usage, b: Usage) -> Result<Usage, String> {
    a.checked_add(b)
        .ok_or_else(|| "Token total overflow".into())
}
fn check(deadline: Instant) -> Result<(), String> {
    if Instant::now() >= deadline {
        Err("Log scan time budget reached; continuing next poll".into())
    } else {
        Ok(())
    }
}
fn discover(
    root: &Path,
    layout: Layout,
    depth: usize,
    deadline: Instant,
    visited: &mut usize,
    paths: &mut Vec<PathBuf>,
) -> Result<(), String> {
    check(deadline)?;
    let metadata =
        fs::symlink_metadata(root).map_err(|e| format!("Log directory unavailable: {e}"))?;
    if !metadata.is_dir() {
        return Err("Log root must be a directory, without symlinks".into());
    }
    for entry in fs::read_dir(root).map_err(|e| e.to_string())? {
        check(deadline)?;
        *visited += 1;
        if *visited > ENTRY_LIMIT {
            return Err("Log discovery entry limit exceeded".into());
        }
        let entry = entry.map_err(|e| e.to_string())?;
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_dir() {
            if depth >= 6 {
                return Err("Log directory depth limit exceeded".into());
            }
            discover(&entry.path(), layout, depth + 1, deadline, visited, paths)?;
        } else if kind.is_file() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let accepted = match layout {
                Layout::Claude => name.ends_with(".jsonl"),
                Layout::Codex => name.starts_with("rollout-") && name.ends_with(".jsonl"),
                Layout::Gemini => {
                    root.file_name().is_some_and(|n| n == "chats")
                        && name.starts_with("session-")
                        && (name.ends_with(".json") || name.ends_with(".jsonl"))
                }
            };
            if accepted {
                paths.push(entry.path());
            }
        }
    }
    Ok(())
}
pub(super) fn open_regular(path: &Path) -> Result<File, String> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|e| e.to_string())?;
    if !file.metadata().map_err(|e| e.to_string())?.is_file() {
        return Err("Expected a regular file".into());
    }
    Ok(file)
}
fn parse(
    bytes: &[u8],
    layout: Layout,
    session: bool,
    stamp: Stamp,
    deadline: Instant,
    old: Option<&Entry>,
) -> Result<Entry, String> {
    let mut parsed = Arc::new(Parsed::default());
    if matches!(layout, Layout::Gemini) && session {
        if bytes.len() > RECORD_LIMIT {
            return Err("Gemini session exceeds 8 MiB".into());
        }
        let details =
            shared::provider_details(bytes, 2).ok_or("Invalid or over-limit Gemini session")?;
        let entry = Arc::make_mut(&mut parsed);
        entry.anonymous = details.record.usage;
        for row in details.models {
            entry.anonymous_models.add(ModelUsage {
                model: row.model,
                usage: row.usage,
                cost: None,
            })?;
        }
        return Ok(Entry {
            stamp,
            parsed,
            checkpoint: None,
        });
    }
    // Metadata alone cannot prove an append. Verify every cached prefix byte,
    // including the middle of the file, before reusing any decoded records.
    let reused = checkpoint(bytes, stamp, old, deadline)?;
    let offset = reused.map_or(0, |c| c.length);
    if let Some(reused) = reused {
        parsed = reused.parsed.clone();
    }
    let end = bytes[offset..]
        .iter()
        .rposition(|b| *b == b'\n')
        .map_or(offset, |last| offset + last + 1);
    lines(&bytes[offset..end], layout, &mut parsed, deadline)?;
    let checkpoint = Checkpoint {
        length: end,
        hash: if end == offset {
            reused.map(|c| c.hash).unwrap_or_else(|| blake3::hash(&[]))
        } else {
            digest(&bytes[..end], deadline)?
        },
        parsed: parsed.clone(),
    };
    // Complete records without LF remain visible, but are deliberately absent
    // from the checkpoint. Appending may extend or invalidate this same line.
    lines(&bytes[end..], layout, &mut parsed, deadline)?;
    Ok(Entry {
        stamp,
        parsed,
        checkpoint: Some(checkpoint),
    })
}
fn digest(bytes: &[u8], deadline: Instant) -> Result<blake3::Hash, String> {
    let mut hash = blake3::Hasher::new();
    for chunk in bytes.chunks(64 * 1024) {
        check(deadline)?;
        hash.update(chunk);
    }
    Ok(hash.finalize())
}
fn checkpoint<'a>(
    bytes: &[u8],
    stamp: Stamp,
    old: Option<&'a Entry>,
    deadline: Instant,
) -> Result<Option<&'a Checkpoint>, String> {
    let Some(old) = old.filter(|old| {
        old.stamp.device == stamp.device
            && old.stamp.inode == stamp.inode
            && old.stamp.size < stamp.size
    }) else {
        return Ok(None);
    };
    let Some(checkpoint) = old.checkpoint.as_ref().filter(|c| c.length <= bytes.len()) else {
        return Ok(None);
    };
    Ok((digest(&bytes[..checkpoint.length], deadline)? == checkpoint.hash).then_some(checkpoint))
}
fn lines(
    bytes: &[u8],
    layout: Layout,
    parsed: &mut Arc<Parsed>,
    deadline: Instant,
) -> Result<(), String> {
    for line in bytes.split(|b| *b == b'\n').filter(|line| !line.is_empty()) {
        check(deadline)?;
        if line.len() > RECORD_LIMIT {
            return Err("JSONL record exceeds 8 MiB".into());
        }
        if matches!(layout, Layout::Codex) {
            if let Some(total) = shared::codex_record(line) {
                // Each event is a cumulative session snapshot, never an increment.
                Arc::make_mut(parsed).anonymous.total = total;
            }
        } else if let Some(details) = shared::provider_details(
            line,
            if matches!(layout, Layout::Claude) {
                0
            } else {
                1
            },
        ) {
            let entry = Arc::make_mut(parsed);
            let usage = details.record.usage;
            let id = details.record.identity;
            let models: Vec<_> = details
                .models
                .into_iter()
                .map(|row| ModelUsage {
                    model: row.model,
                    usage: row.usage,
                    cost: None,
                })
                .collect();
            if id.is_empty() {
                entry.anonymous = add(entry.anonymous, usage)?;
                for row in models {
                    entry.anonymous_models.add(row)?;
                }
            } else {
                if entry.identified.len() >= USAGE_LIMIT && !entry.identified.contains_key(&id) {
                    return Err("Message identity limit exceeded".into());
                }
                entry.identified.insert(id, Recorded { usage, models });
            }
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests;
