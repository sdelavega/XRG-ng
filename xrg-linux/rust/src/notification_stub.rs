// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Linux twin of the publication wakeup registry. Wakeups are core
//! engine plumbing with no telemetry in them, so the twin keeps the exact
//! Linux behaviour (registration replays the latest value, publication calls
//! the registered consumer outside every lock) instead of silencing the
//! worker; nothing is invented either way. It is marked as the stub so a
//! cfg mistake cannot pass the platform selection test.
use std::sync::{Arc, Mutex};

pub const IMPLEMENTATION: &str = "stub";

type Callback = Arc<dyn Fn() + Send + Sync>;

#[derive(Clone, Default)]
pub(crate) struct Notification(Arc<Mutex<Option<Callback>>>);

impl Notification {
    pub fn set(&self, callback: impl Fn() + Send + Sync + 'static) {
        let callback: Callback = Arc::new(callback);
        *self.0.lock().unwrap() = Some(callback.clone());
        // Catch a value published before registration, including the startup race.
        callback();
    }
    pub fn notify(&self) {
        let callback = self.0.lock().unwrap().clone();
        // Call outside both the notification lock and the publisher's value lock.
        if let Some(callback) = callback {
            callback();
        }
    }
}
