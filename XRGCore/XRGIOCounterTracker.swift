// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.

import Foundation

struct XRGIOCounters: Equatable {
    let first: UInt64
    let second: UInt64
}

/// One sampling stream. Graph storage and transfer-reset boundaries are independent
/// of its rate baseline. Callers must supply stable identities, not display names.
struct XRGIOCounterTracker<Key: Hashable> {
    private var previous: [Key: XRGIOCounters]?
    // Retain identity/counter evidence across read gaps, independently of the
    // discarded rate baseline, so a visible restart still begins a new session.
    private var lastCounters: [Key: XRGIOCounters]?
    private var membership: Set<Key>?
    private var time: TimeInterval?
    private var skipNextTransfer = true
    private var needsRateBaseline = false
    private var waitingForRateInterval = false
    private(set) var first: UInt64 = 0
    private(set) var second: UInt64 = 0
    private(set) var partial = false
    private(set) var saturated = false
    private(set) var available = false
    private(set) var started: TimeInterval?

    var total: UInt64 { Self.sum(first, second).value }
    var lowerBound: Bool { partial || saturated }

    static func sum(_ a: UInt64, _ b: UInt64) -> (value: UInt64, overflow: Bool) {
        let (value, overflow) = a.addingReportingOverflow(b)
        return (overflow ? .max : value, overflow)
    }

    mutating func resetTransfers() {
        first = 0; second = 0; partial = false; saturated = false
        started = nil
        // The next counter interval straddles the user's reset. Exclude it from
        // transfers while retaining it for rates; no pre-reset bytes are imported.
        skipNextTransfer = true
    }

    // Keep counter/identity evidence and exact byte accounting; only the next
    // rate interval is unsuitable after an explicit lifecycle boundary.
    mutating func invalidateRateInterval() {
        needsRateBaseline = true; waitingForRateInterval = true; available = false
    }

    mutating func fail() {
        previous = nil; time = nil; available = false; partial = true; waitingForRateInterval = false
    }

    struct Reading {
        let firstRate: CGFloat
        let secondRate: CGFloat
        let newSession: Bool
        let ratesAvailable: Bool
    }

    mutating func sample(_ counters: [Key: XRGIOCounters], at now: TimeInterval) -> Reading? {
        guard now.isFinite, time.map({ now > $0 }) ?? true else { fail(); return nil }
        let members = Set(counters.keys)
        let restarted = lastCounters.map { old in
            counters.contains { key, value in
                guard let before = old[key] else { return false }
                return value.first < before.first || value.second < before.second
            }
        } ?? false
        let newSession = membership != members || restarted
        if newSession {
            resetTransfers()
            previous = nil; time = nil
            membership = members
        }
        var a: UInt64 = 0, b: UInt64 = 0
        var overflow = false
        let elapsed = time.map { now - $0 } ?? 0
        if let previous {
            for (key, value) in counters {
                guard let old = previous[key] else { continue }
                let x = Self.sum(a, value.first - old.first)
                let y = Self.sum(b, value.second - old.second)
                a = x.value; b = y.value; overflow = overflow || x.overflow || y.overflow
            }
        }
        let suppressRates = needsRateBaseline
        let ar = elapsed > 0 && !suppressRates ? Double(a) / elapsed : 0
        let br = elapsed > 0 && !suppressRates ? Double(b) / elapsed : 0
        guard ar.isFinite, br.isFinite, (ar + br).isFinite else { fail(); return nil }
        if skipNextTransfer {
            skipNextTransfer = false; started = now; partial = false
        } else {
            let x = Self.sum(first, a), y = Self.sum(second, b)
            first = x.value; second = y.value
            saturated = saturated || overflow || x.overflow || y.overflow || Self.sum(first, second).overflow
        }
        previous = counters; lastCounters = counters; time = now
        available = !suppressRates; waitingForRateInterval = suppressRates; needsRateBaseline = false
        return Reading(firstRate: CGFloat(ar), secondRate: CGFloat(br), newSession: newSession, ratesAvailable: !suppressRates)
    }

    func details(firstLabel: String, secondLabel: String) -> String {
        var text = "Session observed transfers: \(firstLabel) \(first) bytes / \(secondLabel) \(second) bytes.\n"
        text += "Totals count valid counter deltas since monitoring or Reset Session Transfers. The first sample establishes a baseline. Selection, membership, identity changes and counter restarts begin a new session.\nReset Graph preserves totals and rate baselines. Reset Session Transfers preserves graphs and rates; the next sample starts accounting, excluding the interval spanning the reset.\n"
        if !available {
            text += waitingForRateInterval
                ? "Current rates unavailable across a wake boundary; valid observed counter deltas still count toward transfers. The next completed interval restores rates.\n"
                : "Current counters unavailable; last successful snapshot retained.\n"
        }
        if partial { text += "Partial coverage: missed intervals are excluded; totals are lower bounds. Recovery establishes a fresh rate baseline.\n" }
        if saturated { text += "Counter arithmetic saturated at UInt64 maximum; totals are lower bounds.\n" }
        return text
    }
}
