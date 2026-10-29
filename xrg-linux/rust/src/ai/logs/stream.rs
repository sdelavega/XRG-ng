// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Bound raw read buffers while retaining byte-verified append checkpoints.
use super::{Entry, FILE_LIMIT, Layout, ModelUsage, Parsed, RECORD_LIMIT, Stamp, check};
mod job;
#[cfg(test)]
use super::Checkpoint;
use crate::shared;
pub(super) use job::Job;
use std::{
    io::{self, Read, Seek},
    sync::Arc,
    time::Instant,
};
pub(super) const CHUNK: usize = 64 * 1024;

pub(super) struct Input<'a, R> {
    inner: &'a mut R,
    budget: &'a mut u64,
    deadline: Instant,
}
impl<'a, R> Input<'a, R> {
    pub fn new(inner: &'a mut R, budget: &'a mut u64, deadline: Instant) -> Self {
        Self {
            inner,
            budget,
            deadline,
        }
    }
}
impl<R: Read> Read for Input<'_, R> {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        if bytes.is_empty() {
            return Ok(0);
        }
        loop {
            check(self.deadline).map_err(|e| io::Error::new(io::ErrorKind::TimedOut, e))?;
            if *self.budget == 0 {
                return Err(io::Error::other(
                    "Log scan I/O budget reached; continuing next poll",
                ));
            }
            let limit = bytes.len().min(CHUNK).min(*self.budget as usize);
            match self.inner.read(&mut bytes[..limit]) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                result => {
                    let count = result?;
                    *self.budget -= count as u64;
                    return Ok(count);
                }
            }
        }
    }
}
impl<R: Read> Input<'_, R> {
    fn eof(&mut self) -> Result<(), String> {
        let mut extra = [0u8; 1];
        if self.read(&mut extra).map_err(|e| e.to_string())? != 0 {
            return Err("Log changed while reading; retrying".into());
        }
        Ok(())
    }
}

#[cfg(test)]
pub(super) fn digest(input: &mut impl Read, length: usize) -> Result<blake3::Hasher, String> {
    let mut hash = blake3::Hasher::new();
    let mut buffer = [0u8; CHUNK];
    let mut left = length;
    while left > 0 {
        let count = left.min(CHUNK);
        input
            .read_exact(&mut buffer[..count])
            .map_err(|e| e.to_string())?;
        hash.update(&buffer[..count]);
        left -= count;
    }
    Ok(hash)
}
#[cfg(test)]
pub(super) fn checkpoint<'a>(
    input: &mut impl Read,
    stamp: Stamp,
    old: Option<&'a Entry>,
) -> Result<(Option<&'a Checkpoint>, blake3::Hasher), String> {
    let Some(old) = old.filter(|old| {
        old.stamp.device == stamp.device
            && old.stamp.inode == stamp.inode
            && old.stamp.size < stamp.size
    }) else {
        return Ok((None, blake3::Hasher::new()));
    };
    let Some(checkpoint) = old
        .checkpoint
        .as_ref()
        .filter(|c| c.length as u64 <= stamp.size)
    else {
        return Ok((None, blake3::Hasher::new()));
    };
    let hash = digest(input, checkpoint.length)?;
    if hash.finalize() == checkpoint.hash {
        Ok((Some(checkpoint), hash))
    } else {
        Ok((None, blake3::Hasher::new()))
    }
}

#[cfg(test)]
pub(super) fn record(
    reader: &mut impl std::io::BufRead,
    line: &mut Vec<u8>,
    deadline: Instant,
) -> Result<(), String> {
    line.clear();
    loop {
        check(deadline)?;
        let bytes = reader.fill_buf().map_err(|e| e.to_string())?;
        if bytes.is_empty() {
            return Ok(());
        }
        let end = bytes.iter().position(|b| *b == b'\n').map(|i| i + 1);
        let count = end.unwrap_or(bytes.len());
        let payload = line.len() + count - usize::from(end.is_some());
        if payload > RECORD_LIMIT {
            return Err("JSONL record exceeds 8 MiB".into());
        }
        if line.capacity() < line.len() + count {
            let capacity = (line.len() + count)
                .next_power_of_two()
                .min(RECORD_LIMIT + 1);
            line.try_reserve_exact(capacity - line.len())
                .map_err(|_| "Could not buffer bounded log record")?;
        }
        line.extend_from_slice(&bytes[..count]);
        reader.consume(count);
        if end.is_some() {
            return Ok(());
        }
    }
}

pub(super) fn parse<R: Read + Seek>(
    reader: &mut R,
    layout: Layout,
    session: bool,
    stamp: Stamp,
    deadline: Instant,
    old: Option<&Entry>,
    budget: &mut u64,
) -> Result<Entry, String> {
    check(deadline)?;
    if stamp.size > FILE_LIMIT {
        return Err("Log exceeds the 64 MiB per-file limit".into());
    }
    if matches!(layout, Layout::Gemini) && session {
        reader.rewind().map_err(|e| e.to_string())?;
        let mut input = Input::new(reader, budget, deadline);
        let mut parsed = Arc::new(Parsed::default());
        if stamp.size > RECORD_LIMIT as u64 {
            return Err("Gemini session exceeds 8 MiB".into());
        }
        let mut bytes = Vec::new();
        bytes
            .try_reserve_exact(stamp.size as usize)
            .map_err(|_| "Could not buffer bounded Gemini session")?;
        let mut buffer = [0u8; CHUNK];
        let mut limited = (&mut input).take(stamp.size);
        loop {
            let count = limited.read(&mut buffer).map_err(|e| e.to_string())?;
            if count == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..count]);
        }
        if bytes.len() as u64 != stamp.size {
            return Err("Log changed while reading; retrying".into());
        }
        input.eof()?;
        let details =
            shared::provider_details(&bytes, 2).ok_or("Invalid or over-limit Gemini session")?;
        let entry = Arc::make_mut(&mut parsed);
        entry.anonymous = details.record.usage;
        for row in details.models {
            entry.anonymous_models.add(ModelUsage {
                model: row.model,
                usage: row.usage,
                cost: None,
            })?;
        }
        check(deadline)?;
        return Ok(Entry {
            stamp,
            parsed,
            checkpoint: None,
        });
    }
    let mut job = Job::new(layout, stamp, old)?;
    let entry = job.advance(reader, budget, deadline)?;
    check(deadline)?;
    entry.ok_or_else(|| "Log scan I/O budget reached; continuing next poll".into())
}
