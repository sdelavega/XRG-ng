// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Portable DRM client types and counter math shared by the Linux fdinfo scan
//! and its stub twin, so percentages and busy accounting can never diverge
//! between platforms. The types keep the crate-visible API shape of the
//! collectors; off Linux the scan entry point is the only thing reached, and
//! it reports "unavailable" rather than fabricating counters.
// The scan constructor and the Client/Scan constructors only exist on the
// Linux side; the shared types must still compile everywhere for API parity.
#![allow(dead_code)]

use std::{collections::BTreeMap, time::Duration};

#[derive(Debug)]
pub(crate) struct Client {
    pub(crate) driver: String,
    pub(crate) id: u64,
    pub(crate) engines: BTreeMap<String, (Counter, u64)>,
    pub(crate) resident: Option<u64>,
    pub(crate) frequency: Option<u64>,
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum Counter {
    Nanoseconds(u64),
    Cycles { busy: u64, total: u64 },
}

impl Counter {
    pub(crate) fn busy(self) -> u64 {
        match self {
            Self::Nanoseconds(value) | Self::Cycles { busy: value, .. } => value,
        }
    }
    pub(crate) fn same_kind(self, other: Self) -> bool {
        matches!(
            (self, other),
            (Self::Nanoseconds(_), Self::Nanoseconds(_))
                | (Self::Cycles { .. }, Self::Cycles { .. })
        )
    }
    pub(crate) fn percent(self, previous: Self, elapsed: Duration, capacity: u64) -> Option<f64> {
        let busy = self.busy().checked_sub(previous.busy())?;
        let denominator = match (self, previous) {
            (Self::Nanoseconds(_), Self::Nanoseconds(_)) => elapsed.as_secs_f64() * 1_000_000_000.,
            (Self::Cycles { total, .. }, Self::Cycles { total: old, .. }) => {
                total.checked_sub(old)? as f64
            }
            _ => return None,
        };
        (denominator > 0.).then(|| 100. * busy as f64 / denominator / capacity as f64)
    }
}

pub(crate) struct Scan {
    pub(crate) values: BTreeMap<(String, u64), Client>,
    pub(crate) partial: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn busy_extracts_the_busy_component_of_each_counter_kind() {
        assert_eq!(Counter::Nanoseconds(7).busy(), 7);
        assert_eq!(Counter::Cycles { busy: 3, total: 9 }.busy(), 3);
    }
    #[test]
    fn same_kind_requires_matching_counter_kinds() {
        assert!(Counter::Nanoseconds(1).same_kind(Counter::Nanoseconds(2)));
        assert!(
            Counter::Cycles { busy: 1, total: 2 }.same_kind(Counter::Cycles { busy: 3, total: 4 })
        );
        assert!(!Counter::Nanoseconds(1).same_kind(Counter::Cycles { busy: 1, total: 2 }));
        assert!(!Counter::Cycles { busy: 1, total: 2 }.same_kind(Counter::Nanoseconds(1)));
    }
    #[test]
    fn percent_divides_elapsed_busy_nanoseconds_by_elapsed_time_and_capacity() {
        let previous = Counter::Nanoseconds(0);
        let current = Counter::Nanoseconds(500_000_000);
        let percent = current
            .percent(previous, Duration::from_secs(1), 1)
            .unwrap();
        assert!((percent - 50.).abs() < 1e-9);
        assert_eq!(
            current.percent(previous, Duration::from_secs(0), 1),
            None,
            "A zero denominator must never produce a percentage"
        );
        assert_eq!(
            previous.percent(current, Duration::from_secs(1), 1),
            None,
            "A backwards counter must never produce a percentage"
        );
        // Capacity scales the result to one engine's share.
        let percent = current
            .percent(previous, Duration::from_secs(1), 2)
            .unwrap();
        assert!((percent - 25.).abs() < 1e-9);
    }
    #[test]
    fn percent_divides_busy_cycles_by_the_total_cycle_delta() {
        let previous = Counter::Cycles {
            busy: 100,
            total: 400,
        };
        let current = Counter::Cycles {
            busy: 200,
            total: 800,
        };
        let percent = current
            .percent(previous, Duration::from_secs(1), 1)
            .unwrap();
        assert!((percent - 25.).abs() < 1e-9);
        // Xe exports busy and total cycles; the polling interval is irrelevant.
        assert_eq!(
            current
                .percent(previous, Duration::from_secs(99), 1)
                .unwrap(),
            percent
        );
        assert_eq!(
            current.percent(
                Counter::Cycles {
                    busy: 0,
                    total: 900
                },
                Duration::from_secs(1),
                1
            ),
            None,
            "A shrinking total must never produce a percentage"
        );
    }
}
