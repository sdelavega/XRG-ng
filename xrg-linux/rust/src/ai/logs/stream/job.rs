// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! A resumable JSONL snapshot. No file descriptors or whole-file byte buffers survive a poll.
use super::super::{
    Checkpoint, Entry, FILE_LIMIT, Layout, Parsed, RECORD_LIMIT, Stamp, TIME_BUDGET_ERROR, lines,
};
use super::{CHUNK, Input};
use std::{
    io::{Read, Seek, SeekFrom},
    sync::Arc,
    time::Instant,
};

pub(in super::super) struct Job {
    stamp: Stamp,
    layout: Layout,
    verify: Option<Checkpoint>,
    hash: blake3::Hasher,
    parsed: Arc<Parsed>,
    // offset follows the reader; complete ends at the last decoded newline.
    offset: u64,
    complete: usize,
    chunk: Box<[u8; CHUNK]>,
    at: usize,
    available: usize,
    line: Vec<u8>,
}
impl Job {
    pub(in super::super) fn new(
        layout: Layout,
        stamp: Stamp,
        old: Option<&Entry>,
    ) -> Result<Self, String> {
        if stamp.size > FILE_LIMIT {
            return Err("Log exceeds the 64 MiB per-file limit".into());
        }
        let verify = old
            .filter(|old| {
                old.stamp.device == stamp.device
                    && old.stamp.inode == stamp.inode
                    && old.stamp.size < stamp.size
            })
            .and_then(|old| old.checkpoint.as_ref())
            .filter(|c| c.length as u64 <= stamp.size)
            .cloned();
        Ok(Self {
            stamp,
            layout,
            verify,
            hash: blake3::Hasher::new(),
            parsed: Arc::new(Parsed::default()),
            offset: 0,
            complete: 0,
            chunk: Box::new([0; CHUNK]),
            at: 0,
            available: 0,
            line: Vec::new(),
        })
    }
    pub(in super::super) fn stamp(&self) -> Stamp {
        self.stamp
    }

    pub(in super::super) fn position(&self) -> (u64, u64) {
        (self.offset, self.stamp.size)
    }

    /// None means the caller must retain this job and validate the same stamp
    /// before its next slice. Only a complete, EOF-checked Entry can be published.
    pub(in super::super) fn advance<R: Read + Seek>(
        &mut self,
        reader: &mut R,
        budget: &mut u64,
        deadline: Instant,
    ) -> Result<Option<Entry>, String> {
        reader
            .seek(SeekFrom::Start(self.offset))
            .map_err(|e| e.to_string())?;
        let mut input = Input::new(reader, budget, deadline);
        loop {
            if Instant::now() >= deadline {
                return Ok(None);
            }
            if let Some(checkpoint) = &self.verify {
                if self.offset == checkpoint.length as u64 {
                    if self.hash.finalize() == checkpoint.hash {
                        self.parsed = checkpoint.parsed.clone();
                        self.complete = checkpoint.length;
                    } else {
                        // A growing file may have been rewritten in its middle.
                        // Discard the draft, rewind, and charge the second read.
                        self.hash = blake3::Hasher::new();
                        self.offset = 0;
                        input.inner.rewind().map_err(|e| e.to_string())?;
                    }
                    self.verify = None;
                    continue;
                }
                let left = checkpoint.length as u64 - self.offset;
                let size = (left as usize).min(CHUNK);
                let Some(count) = Self::read(&mut input, &mut self.chunk[..size])? else {
                    return Ok(None);
                };
                if count == 0 {
                    return Err("Log changed while reading; retrying".into());
                }
                self.hash.update(&self.chunk[..count]);
                self.offset += count as u64;
                continue;
            }
            // Decoding can yield between records while unread bytes from the
            // previous small read stay buffered, without charging them twice.
            if self.line.last() == Some(&b'\n') {
                match lines(&self.line, self.layout, &mut self.parsed, deadline) {
                    Ok(()) => (),
                    Err(error) if error == TIME_BUDGET_ERROR => return Ok(None),
                    Err(error) => return Err(error),
                }
                self.hash.update(&self.line);
                self.complete += self.line.len();
                self.line.clear();
            }
            if self.at < self.available {
                let bytes = &self.chunk[self.at..self.available];
                let newline = bytes.iter().position(|b| *b == b'\n');
                let count = newline.map_or(bytes.len(), |n| n + 1);
                let payload = self.line.len() + count - usize::from(newline.is_some());
                if payload > RECORD_LIMIT {
                    return Err("JSONL record exceeds 8 MiB".into());
                }
                if self.line.capacity() < self.line.len() + count {
                    let capacity = (self.line.len() + count)
                        .next_power_of_two()
                        .min(RECORD_LIMIT + 1);
                    self.line
                        .try_reserve_exact(capacity - self.line.len())
                        .map_err(|_| "Could not buffer bounded log record")?;
                }
                self.line.extend_from_slice(&bytes[..count]);
                self.at += count;
                continue;
            }
            if self.offset == self.stamp.size {
                let mut extra = [0u8; 1];
                let Some(count) = Self::read(&mut input, &mut extra)? else {
                    return Ok(None);
                };
                if count != 0 {
                    return Err("Log changed while reading; retrying".into());
                }
                let checkpoint = Checkpoint {
                    length: self.complete,
                    hash: self.hash.finalize(),
                    parsed: self.parsed.clone(),
                };
                let mut parsed = self.parsed.clone();
                // Complete EOF records are visible, but remain outside the
                // reusable newline checkpoint and are replayed after an append.
                match lines(&self.line, self.layout, &mut parsed, deadline) {
                    Ok(()) => (),
                    Err(error) if error == TIME_BUDGET_ERROR => return Ok(None),
                    Err(error) => return Err(error),
                }
                return Ok(Some(Entry {
                    stamp: self.stamp,
                    parsed,
                    checkpoint: Some(checkpoint),
                }));
            }
            let size = (self.stamp.size - self.offset).min(CHUNK as u64) as usize;
            let Some(count) = Self::read(&mut input, &mut self.chunk[..size])? else {
                return Ok(None);
            };
            if count == 0 {
                return Err("Log changed while reading; retrying".into());
            }
            self.offset += count as u64;
            self.at = 0;
            self.available = count;
        }
    }
    fn read<R: Read>(input: &mut Input<'_, R>, bytes: &mut [u8]) -> Result<Option<usize>, String> {
        if *input.budget == 0 || Instant::now() >= input.deadline {
            return Ok(None);
        }
        match input.read(bytes) {
            Ok(count) => Ok(Some(count)),
            Err(error)
                if error.kind() == std::io::ErrorKind::TimedOut
                    && error.to_string() == TIME_BUDGET_ERROR =>
            {
                Ok(None)
            }
            Err(error) => Err(error.to_string()),
        }
    }
}
