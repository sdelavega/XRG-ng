// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Wakeable system sampling cadence; collectors keep their elapsed-time baselines.
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
pub const MIN_MS: u32 = 250;
pub const MAX_MS: u32 = 10_000;
pub fn default_interval() -> u32 {
    1000
}
pub fn interval(milliseconds: u32) -> Result<Duration, String> {
    if !(MIN_MS..=MAX_MS).contains(&milliseconds) {
        return Err("System sampling interval must be between 250 and 10000 milliseconds".into());
    }
    Ok(Duration::from_millis(u64::from(milliseconds)))
}
pub struct Schedule {
    period: Duration,
    last_start: Option<Instant>,
    next: Instant,
}
impl Schedule {
    pub fn new(milliseconds: u32, now: Instant) -> Result<Self, String> {
        Ok(Self {
            period: interval(milliseconds)?,
            last_start: None,
            next: now,
        })
    }
    pub fn remaining(&self, now: Instant) -> Duration {
        self.next.saturating_duration_since(now)
    }
    pub fn sampled(&mut self, started: Instant, finished: Instant) {
        self.last_start = Some(started);
        let planned = started + self.period;
        // Skip missed deadlines, without a catch-up burst or a tight overrun loop.
        self.next = if planned <= finished {
            finished + self.period
        } else {
            planned
        };
    }
    fn change(&mut self, period: Duration, now: Instant) {
        if self.period == period {
            return;
        }
        self.period = period;
        self.next = self
            .last_start
            .map_or(now, |start| (start + period).max(now));
    }
}
enum Message {
    Wake,
    Stop,
}
#[derive(Clone)]
pub struct Control {
    pending: Arc<Mutex<Option<Duration>>>,
    immediate: Arc<AtomicBool>,
    wake: mpsc::SyncSender<Message>,
}
impl Control {
    pub fn set(&self, milliseconds: u32) -> Result<(), String> {
        let period = interval(milliseconds)?;
        *self.pending.lock().unwrap() = Some(period);
        match self.wake.try_send(Message::Wake) {
            Ok(()) | Err(mpsc::TrySendError::Full(_)) => Ok(()),
            Err(mpsc::TrySendError::Disconnected(_)) => {
                Err("System sampling worker is closed".into())
            }
        }
    }
    pub(crate) fn request(&self) -> Result<(), String> {
        self.immediate.store(true, Ordering::Release);
        match self.wake.try_send(Message::Wake) {
            Ok(()) | Err(mpsc::TrySendError::Full(_)) => Ok(()),
            Err(mpsc::TrySendError::Disconnected(_)) => {
                Err("System sampling worker is closed".into())
            }
        }
    }
    pub(crate) fn stop(&self) {
        let _ = self.wake.send(Message::Stop);
    }
}
pub(crate) struct Timer {
    schedule: Schedule,
    control: Control,
    receiver: mpsc::Receiver<Message>,
}
impl Timer {
    pub(crate) fn new(milliseconds: u32) -> Result<Self, String> {
        let (wake, receiver) = mpsc::sync_channel(1);
        Ok(Self {
            schedule: Schedule::new(milliseconds, Instant::now())?,
            control: Control {
                pending: Arc::new(Mutex::new(None)),
                immediate: Arc::new(AtomicBool::new(false)),
                wake,
            },
            receiver,
        })
    }
    pub(crate) fn control(&self) -> Control {
        self.control.clone()
    }
    pub(crate) fn wait(&mut self) -> bool {
        loop {
            match self
                .receiver
                .recv_timeout(self.schedule.remaining(Instant::now()))
            {
                Ok(Message::Wake) => {
                    if let Some(period) = self.control.pending.lock().unwrap().take() {
                        self.schedule.change(period, Instant::now());
                    }
                    if self.control.immediate.swap(false, Ordering::AcqRel) {
                        self.schedule.next = Instant::now();
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => return true,
                Ok(Message::Stop) | Err(mpsc::RecvTimeoutError::Disconnected) => return false,
            }
        }
    }
    pub(crate) fn sampled(&mut self, started: Instant) {
        self.schedule.sampled(started, Instant::now());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn interval_bounds_and_default_are_explicit() {
        assert_eq!(
            interval(default_interval()).unwrap(),
            Duration::from_secs(1)
        );
        for value in [MIN_MS, MAX_MS, 375] {
            assert!(interval(value).is_ok());
        }
        for value in [0, MIN_MS - 1, MAX_MS + 1, u32::MAX] {
            assert!(interval(value).is_err());
        }
    }
    #[test]
    fn normal_work_is_included_in_the_interval_and_overruns_do_not_catch_up() {
        let now = Instant::now();
        let mut schedule = Schedule::new(1000, now).unwrap();
        assert!(schedule.remaining(now).is_zero());
        schedule.sampled(now, now + Duration::from_millis(100));
        assert_eq!(
            schedule.remaining(now + Duration::from_millis(100)),
            Duration::from_millis(900)
        );
        schedule.sampled(now + Duration::from_secs(1), now + Duration::from_secs(3));
        assert_eq!(
            schedule.remaining(now + Duration::from_secs(3)),
            Duration::from_secs(1)
        );
        assert!(schedule.remaining(now + Duration::from_secs(20)).is_zero());
        schedule.sampled(now + Duration::from_secs(20), now + Duration::from_secs(20));
        assert_eq!(
            schedule.remaining(now + Duration::from_secs(20)),
            Duration::from_secs(1)
        );
    }
    #[test]
    fn interval_changes_retime_the_next_sample_without_resetting_the_last_start() {
        let now = Instant::now();
        let mut schedule = Schedule::new(1000, now).unwrap();
        schedule.sampled(now, now + Duration::from_millis(100));
        schedule.change(interval(500).unwrap(), now + Duration::from_millis(200));
        assert_eq!(
            schedule.remaining(now + Duration::from_millis(200)),
            Duration::from_millis(300)
        );
        schedule.change(interval(10000).unwrap(), now + Duration::from_millis(200));
        assert_eq!(
            schedule.remaining(now + Duration::from_millis(200)),
            Duration::from_millis(9800)
        );
        schedule.change(interval(250).unwrap(), now + Duration::from_secs(1));
        assert!(schedule.remaining(now + Duration::from_secs(1)).is_zero());
        assert_eq!(schedule.last_start, Some(now));
    }
    #[test]
    fn identical_interval_preserves_overrun_backoff_and_initial_sample_is_immediate() {
        let now = Instant::now();
        let mut schedule = Schedule::new(1000, now).unwrap();
        schedule.change(interval(10000).unwrap(), now);
        assert!(schedule.remaining(now).is_zero());
        schedule.sampled(now, now + Duration::from_secs(15));
        schedule.change(interval(10000).unwrap(), now + Duration::from_secs(16));
        assert_eq!(
            schedule.remaining(now + Duration::from_secs(16)),
            Duration::from_secs(9)
        );
    }
    #[test]
    fn controls_coalesce_and_invalid_updates_do_not_replace_the_pending_value() {
        let mut timer = Timer::new(1000).unwrap();
        let control = timer.control();
        control.set(250).unwrap();
        control.set(10000).unwrap();
        assert!(control.set(0).is_err());
        assert!(timer.wait());
        assert_eq!(timer.schedule.period, Duration::from_secs(10));
        drop(timer);
        assert!(control.set(500).is_err());
    }
    #[test]
    fn a_shorter_interval_wakes_a_long_wait_and_stop_does_not_wait_for_the_period() {
        let mut timer = Timer::new(10000).unwrap();
        assert!(timer.wait());
        timer.sampled(Instant::now());
        let control = timer.control();
        let (ready, started) = mpsc::channel();
        let (done, finished) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            ready.send(()).unwrap();
            assert!(timer.wait());
            done.send(timer.schedule.period).unwrap();
            timer.sampled(Instant::now());
            assert!(!timer.wait());
        });
        started.recv().unwrap();
        control.set(250).unwrap();
        assert_eq!(
            finished.recv_timeout(Duration::from_secs(5)).unwrap(),
            Duration::from_millis(250)
        );
        control.stop();
        worker.join().unwrap();
    }
}

#[cfg(test)]
mod request_tests {
    use super::*;
    #[test]
    fn explicit_requests_wake_long_waits_and_coalesce_without_changing_the_period() {
        let mut timer = Timer::new(10000).unwrap();
        timer.sampled(Instant::now());
        let control = timer.control();
        for _ in 0..100 {
            control.request().unwrap();
        }
        assert!(timer.wait());
        assert_eq!(timer.schedule.period, Duration::from_secs(10));
        timer.sampled(Instant::now());
        assert!(timer.schedule.remaining(Instant::now()) > Duration::from_secs(9));
        control.stop();
        assert!(!timer.wait());
    }
}
