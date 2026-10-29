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

import Testing
@testable import XRGSharedCore

struct TokenAccountingTests {
    @Test func baselineTotalOnlyAndUnknownSplit() throws {
        var ledger = XRGTokenAccounting()
        #expect(ledger.sample(provider: "p", source: "s", usage: .init(total: 100)) == nil)
        let sampled_delta = ledger.sample(provider: "p", source: "s", usage: .init(total: 130))
        let delta = try #require(sampled_delta)
        #expect(delta.usage.total == 30 && delta.usage.unclassified == 30)
        #expect(ledger.sample(provider: "p", source: "s", usage: .init(total: 130)) == nil)
    }
    @Test func independentProvidersSourceChangesFailuresAndResets() throws {
        var ledger = XRGTokenAccounting()
        _ = ledger.sample(provider: "a", source: "s", usage: .init(total: 100))
        _ = ledger.sample(provider: "b", source: "s", usage: .init(total: 500))
        #expect(ledger.sample(provider: "a", source: "replacement", usage: .init(total: 900)) == nil)
        #expect(ledger.sample(provider: "b", source: "s", usage: .init(total: 510))?.usage.total == 10)
        #expect(ledger.sample(provider: "b", source: "s", usage: .init(total: 5)) == nil)
        #expect(ledger.sample(provider: "b", source: "s", usage: .init(total: 8))?.usage.total == 3)
        _ = ledger.sample(provider: "b", source: "s", usage: nil)
        #expect(ledger.sample(provider: "b", source: "s", usage: .init(total: 90)) == nil)
        _ = ledger.sample(provider: "b", source: "s", usage: .init(input: 91, total: 90))
        #expect(ledger.sample(provider: "b", source: "s", usage: .init(total: 100)) == nil)
    }
    @Test func splitCorrectionsAndLateModelsNeverInventTokens() throws {
        var ledger = XRGTokenAccounting()
        _ = ledger.sample(provider: "p", source: "s", usage: .init(input: 10, output: 10, total: 100), models: ["m": 20])
        let sampled_corrected = ledger.sample(provider: "p", source: "s", usage: .init(input: 90, output: 10, total: 105), models: ["m": 100])
        let corrected = try #require(sampled_corrected)
        #expect(corrected.usage == .init(total: 5) && corrected.models.isEmpty)
        let sampled_current = ledger.sample(provider: "p", source: "s", usage: .init(input: 92, output: 13, total: 115), models: ["m": 105, "new": 2])
        let current = try #require(sampled_current)
        #expect(current.usage == .init(input: 2, output: 3, total: 10))
        #expect(current.models == ["m": 5, "new": 2])
        _ = ledger.sample(provider: "p", source: "s", usage: .init(input: 10, output: 13, total: 120))
        #expect(ledger.sample(provider: "p", source: "s", usage: .init(input: 9, output: 14, total: 125))?.usage == .init(total: 5))
    }
    @Test func extremeCountersRemainExact() {
        var ledger = XRGTokenAccounting()
        _ = ledger.sample(provider: "p", source: "s", usage: .init(total: 0))
        let delta = ledger.sample(provider: "p", source: "s", usage: .init(total: .max), models: ["m": .max])
        #expect(delta?.usage.total == .max && delta?.models["m"] == .max)
        #expect(!XRGTokenUsage(input: .max, output: 1, total: .max).isValid)
    }
}
