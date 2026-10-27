// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Bounded, shell-free queries. One killed-but-not-yet-reaped child prevents
//! further launches; even a driver stuck in uninterruptible I/O cannot accumulate
//! query processes or block the sampling worker in wait().
use std::{
    io::Read,
    os::{fd::AsRawFd, unix::process::CommandExt},
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

#[derive(Default)]
pub struct BoundedCommand {
    pending: Option<Child>,
}
fn kill_group(child: &mut Child) {
    // process_group(0) gives this query its own group. Kill descendants holding
    // stdout open as well as the direct child; never signal our own process group.
    if let Ok(pid) = i32::try_from(child.id()) {
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
        }
    }
    let _ = child.kill();
}
impl BoundedCommand {
    pub fn output(
        &mut self,
        program: &Path,
        args: &[&str],
        timeout: Duration,
        limit: usize,
    ) -> Result<Vec<u8>, String> {
        if let Some(child) = self.pending.as_mut() {
            match child.try_wait() {
                Ok(Some(_)) => {
                    self.pending.take();
                }
                _ => return Err("Previous query is awaiting termination".into()),
            }
        }
        let mut child = Command::new(program)
            .args(args)
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .map_err(|e| format!("Cannot start query: {e}"))?;
        let mut stdout = child.stdout.take().expect("piped stdout");
        let deadline = Instant::now() + timeout;
        let mut completed = false;
        let result = (|| {
            let fd = stdout.as_raw_fd();
            // The pipe must not block after the direct child exits while a
            // descendant still owns a write end. No reader threads need joining.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if flags == -1
                || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1
            {
                return Err("Cannot make query output nonblocking".into());
            }
            let mut bytes = Vec::new();
            let mut eof = false;
            let mut status = None;
            loop {
                if Instant::now() >= deadline {
                    return Err("Query timed out".into());
                }
                let mut buffer = [0u8; 4096];
                let mut read_data = false;
                if !eof {
                    match stdout.read(&mut buffer) {
                        Ok(0) => eof = true,
                        Ok(count) => {
                            if count > limit.saturating_sub(bytes.len()) {
                                return Err("Query output limit exceeded".into());
                            }
                            bytes.extend_from_slice(&buffer[..count]);
                            read_data = true;
                        }
                        Err(e)
                            if e.kind() == std::io::ErrorKind::WouldBlock
                                || e.kind() == std::io::ErrorKind::Interrupted => {}
                        Err(e) => return Err(format!("Cannot read query: {e}")),
                    }
                }
                if status.is_none() {
                    status = child.try_wait().map_err(|e| e.to_string())?;
                }
                if let Some(status) = status
                    && eof
                {
                    completed = true;
                    return if status.success() {
                        Ok(bytes)
                    } else {
                        Err(format!("Query exited with {status}"))
                    };
                }
                if !read_data {
                    thread::sleep(Duration::from_millis(5));
                }
            }
        })();
        drop(stdout);
        if result.is_err() && !completed {
            kill_group(&mut child);
            // try_wait never blocks. Retain an uninterruptible child for later
            // polling instead of spawning replacements or waiting indefinitely.
            let reap_deadline = Instant::now() + Duration::from_millis(25);
            loop {
                if matches!(child.try_wait(), Ok(Some(_))) {
                    break;
                }
                if Instant::now() >= reap_deadline {
                    self.pending = Some(child);
                    break;
                }
                thread::sleep(Duration::from_millis(5));
            }
        }
        result
    }
}
impl Drop for BoundedCommand {
    fn drop(&mut self) {
        if let Some(mut child) = self.pending.take() {
            kill_group(&mut child);
            if !matches!(child.try_wait(), Ok(Some(_))) {
                // Final reaping cannot hold up application shutdown. At most one
                // such child exists; application exit reparents it if still stuck.
                let _ = thread::Builder::new()
                    .name("xrg-query-reaper".into())
                    .spawn(move || {
                        let _ = child.wait();
                    });
            }
        }
    }
}
