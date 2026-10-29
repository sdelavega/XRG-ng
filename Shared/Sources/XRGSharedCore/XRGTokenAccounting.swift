/*
 * XRG-ng: A system resource grapher for macOS and Linux.
 * Copyright (C) 2002-2024 Mike Piatek-Jimenez / Gaucho Software, LLC.
 * Copyright (C) 2025-2026 Marc Shade.
 * Copyright (C) 2026 Stephen de la Vega.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 */

import Foundation

/// A source's cumulative usage. A total may include tokens without a known split.
public struct XRGTokenUsage: Equatable, Sendable {
    public var input: UInt64
    public var output: UInt64
    public var total: UInt64
    public init(input: UInt64 = 0, output: UInt64 = 0, total: UInt64) {
        self.input = input; self.output = output; self.total = total
    }
    public var isValid: Bool { input <= total && output <= total - input }
    public var unclassified: UInt64 { isValid ? total - input - output : total }
}

/// First reads, replaced sources and decreasing totals establish a new baseline.
/// Missing reads break continuity. Model metadata never adds to the provider total.
public struct XRGTokenAccounting: Sendable {
    public struct Delta: Equatable, Sendable {
        public let usage: XRGTokenUsage
        public let models: [String: UInt64]
    }
    private struct Baseline: Sendable {
        let source: String
        let usage: XRGTokenUsage
        let models: [String: UInt64]
    }
    private var previous: [String: Baseline] = [:]
    public init() {}

    public mutating func sample(provider: String, source: String, usage: XRGTokenUsage?,
                                models: [String: UInt64] = [:]) -> Delta? {
        guard let usage, usage.isValid else { previous[provider] = nil; return nil }
        let old = previous.updateValue(Baseline(source: source, usage: usage, models: models), forKey: provider)
        guard let old, old.source == source, usage.total >= old.usage.total else { return nil }
        let total = usage.total - old.usage.total
        guard total > 0 else { return nil }
        var input: UInt64 = 0, output: UInt64 = 0
        if usage.input >= old.usage.input, usage.output >= old.usage.output {
            let i = usage.input - old.usage.input, o = usage.output - old.usage.output
            if i <= total, o <= total - i { input = i; output = o }
        }
        // Corrections/late attribution must not claim historical tokens as new.
        var attributed: UInt64 = 0
        var deltas: [String: UInt64] = [:]
        for (model, count) in models {
            let prior = old.models[model] ?? 0
            guard count >= prior else { deltas = [:]; break }
            let delta = count - prior
            guard delta <= total - attributed else { deltas = [:]; break }
            attributed += delta
            if delta > 0 { deltas[model] = delta }
        }
        return Delta(usage: XRGTokenUsage(input: input, output: output, total: total), models: deltas)
    }
}
