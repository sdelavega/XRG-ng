// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The publication wakeup registry shared by the Linux module and its stub
//! twin. Registration replays the latest value so a consumer catches
//! everything published before it existed (including the startup race), and
//! publication calls the registered consumer outside every lock. Wakeups are
//! core engine plumbing with no telemetry in them, so the identical shared
//! implementation keeps every platform honest without inventing readings.
use std::sync::{Arc, Mutex};

type Callback = Arc<dyn Fn() + Send + Sync>;

#[derive(Clone, Default)]
pub struct Notification(Arc<Mutex<Option<Callback>>>);

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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn registration_catches_existing_value_and_publication_can_read_slot() {
        let value = Arc::new(Mutex::new(41));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let notification = Notification::default();
        notification.notify(); // Publication before a consumer exists.
        let (read, record) = (value.clone(), seen.clone());
        notification.set(move || record.lock().unwrap().push(*read.lock().unwrap()));
        *value.lock().unwrap() = 42;
        notification.notify();
        assert_eq!(*seen.lock().unwrap(), [41, 42]);
    }
    #[test]
    fn callback_can_replace_itself_without_holding_notification_lock() {
        let notification = Notification::default();
        let nested = notification.clone();
        notification.set(move || nested.set(|| {}));
        notification.notify();
    }
}
