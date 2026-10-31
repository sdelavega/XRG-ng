// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Metadata-cached bounded scans. Only a complete provider sweep is published.
mod codex;
mod stream;
use super::{ModelUsage, models::Totals};
use crate::shared::{self, Usage};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
const IO_BUDGET: u64 = 128 * 1024 * 1024;
const FILE_LIMIT: u64 = 64 * 1024 * 1024;
const RECORD_LIMIT: usize = 8 * 1024 * 1024;
const ENTRY_LIMIT: usize = 20_000;
const USAGE_LIMIT: usize = 100_000;
const TIME_BUDGET_ERROR: &str = "Log scan time budget reached; continuing next poll";

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
    // MetadataExt (device/inode/modification/change times) is POSIX; every
    // unix target keeps the full rotation-identity stamp.
    #[cfg(unix)]
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
    #[cfg(not(unix))]
    fn from(m: &fs::Metadata) -> Self {
        // std::fs::Metadata has no device/inode/change times off Unix; size
        // and modification time still detect log rotation, best effort.
        let (seconds, nanos) = m
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| (d.as_secs() as i64, d.subsec_nanos() as i64))
            .unwrap_or((0, 0));
        Self {
            device: 0,
            inode: 0,
            size: m.len(),
            seconds,
            nanos,
            changed_seconds: 0,
            changed_nanos: 0,
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
    codex: codex::Ledger,
    identified: BTreeMap<String, Recorded>,
}
#[derive(Clone)]
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
    pub continuity: u64,
    pub usage: Usage,
    pub models: Option<Vec<ModelUsage>>,
}
pub struct LogScan {
    root: PathBuf,
    layout: Layout,
    cache: BTreeMap<PathBuf, Entry>,
    pending: Option<(PathBuf, stream::Job)>,
    published: Option<BTreeMap<PathBuf, shared::LogFileState>>,
    continuity: u64,
}
impl LogScan {
    pub fn new(root: PathBuf, layout: Layout) -> Self {
        Self {
            root,
            layout,
            cache: BTreeMap::new(),
            pending: None,
            published: None,
            continuity: 0,
        }
    }
    pub fn scan(&mut self) -> Result<Usage, String> {
        self.scan_details().map(|s| s.usage)
    }
    pub fn scan_details(&mut self) -> Result<Scan, String> {
        self.scan_with_budget(IO_BUDGET, Instant::now() + Duration::from_secs(2))
    }
    fn scan_with_budget(&mut self, mut budget: u64, deadline: Instant) -> Result<Scan, String> {
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
        if self
            .pending
            .as_ref()
            .is_some_and(|(path, _)| !keep.contains(path))
        {
            self.pending = None;
        }
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
                if self
                    .pending
                    .as_ref()
                    .is_some_and(|(saved, _)| saved == path)
                {
                    self.pending = None;
                }
                continue;
            }
            if stamp.size > FILE_LIMIT {
                return Err("Log exceeds the 64 MiB per-file limit".into());
            }
            let mut file = open_regular(path)?;
            if Stamp::from(&file.metadata().map_err(|e| e.to_string())?) != stamp {
                return Err("Log changed while opening; retrying".into());
            }
            let session = matches!(self.layout, Layout::Gemini)
                && path.extension().is_some_and(|e| e == "json");
            let (entry, pending) = if session {
                if stamp.size > budget {
                    return Err("Log scan budget reached; continuing next poll".into());
                }
                (
                    Some(stream::parse(
                        &mut file,
                        self.layout,
                        true,
                        stamp,
                        deadline,
                        self.cache.get(path),
                        &mut budget,
                    )?),
                    None,
                )
            } else {
                // A small earlier log may change every poll. Preserve a later
                // pending file while that earlier file completes in this slice.
                let saved = if self
                    .pending
                    .as_ref()
                    .is_some_and(|(saved, _)| saved == path)
                {
                    self.pending.take()
                } else {
                    None
                };
                let mut job = match saved {
                    Some((_, job)) if job.stamp() == stamp => job,
                    _ => stream::Job::new(self.layout, stamp, self.cache.get(path))?,
                };
                let entry = job.advance(&mut file, &mut budget, deadline)?;
                (entry, Some(job))
            };
            if Stamp::from(&file.metadata().map_err(|e| e.to_string())?) != stamp
                || Stamp::from(&fs::symlink_metadata(path).map_err(|e| e.to_string())?) != stamp
            {
                return Err("Log changed during parsing; retrying".into());
            }
            let Some(entry) = entry else {
                let position = pending
                    .as_ref()
                    .map(|job| job.position())
                    .unwrap_or_default();
                self.pending = pending.map(|job| (path.clone(), job));
                return Err(format!(
                    "Log scan in progress: {} / {} bytes; continuing next poll",
                    position.0, position.1
                ));
            };
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
        let mut codex_models = codex::Rows::default();
        // Claude IDs are global, so copied/subagent transcripts cannot count the
        // same assistant message twice. Newest file snapshot wins deterministically.
        let mut identified = BTreeMap::new();
        let mut inventory = BTreeMap::new();
        for (path, entry) in &self.cache {
            check(deadline)?;
            total = add(total, entry.parsed.anonymous)?;
            let file_tokens = entry.parsed.identified.values().try_fold(
                entry.parsed.anonymous.total,
                |sum, row| {
                    sum.checked_add(row.usage.total)
                        .ok_or("File token total overflow")
                },
            )?;
            inventory.insert(
                path.clone(),
                shared::LogFileState {
                    device: entry.stamp.device,
                    inode: entry.stamp.inode,
                    bytes: entry.stamp.size,
                    tokens: file_tokens,
                },
            );
            codex_models.merge(&entry.parsed.codex.rows)?;
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
        // Compare with the last complete published inventory, never a draft
        // cache modified during a pending or failed sweep.
        if let Some(old) = &self.published
            && (old.len() != inventory.len()
                || inventory.iter().any(|(path, state)| {
                    old.get(path).is_none_or(|prior| !state.continues(*prior))
                }))
        {
            self.continuity = self
                .continuity
                .checked_add(1)
                .ok_or("Log continuity exhausted")?;
        }
        self.published = Some(inventory);
        Ok(Scan {
            continuity: self.continuity,
            usage: total,
            models: if matches!(self.layout, Layout::Codex) {
                codex_models.finish()
            } else {
                Some(models.finish())
            },
        })
    }
}
fn add(a: Usage, b: Usage) -> Result<Usage, String> {
    a.checked_add(b)
        .ok_or_else(|| "Token total overflow".into())
}
fn check(deadline: Instant) -> Result<(), String> {
    if Instant::now() >= deadline {
        Err(TIME_BUDGET_ERROR.into())
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
    // Hardened no-follow/nonblocking opens are POSIX; every unix target keeps
    // the protection instead of silently opening through symlinks.
    #[cfg(unix)]
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|e| e.to_string())?;
    #[cfg(not(unix))]
    let file = OpenOptions::new()
        .read(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    if !file.metadata().map_err(|e| e.to_string())?.is_file() {
        return Err("Expected a regular file".into());
    }
    Ok(file)
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
            let usage = shared::codex_usage(line);
            let total = usage.map(|u| u.total);
            let update = codex::Update::parse(line);
            if total.is_some() || parsed.codex.changes_context(&update) {
                let entry = Arc::make_mut(parsed);
                entry.codex.update(update, total)?;
                // Each event is a cumulative session snapshot, never an increment.
                if let Some(usage) = usage {
                    entry.anonymous = usage;
                }
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
