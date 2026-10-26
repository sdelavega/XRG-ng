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
import Testing
@testable import XRGCore

struct SMCSensorGroupTests {
    private func group(_ characters: String) -> SMCSensorGroup? {
        SMCSensorGroup(pattern: "Tp0?", usingAvailableSensors: Set(characters.map { "Tp0\($0)" }), description: "CPU")
    }
    private static let groupingCases: [(String, [String])] = [("0", ["0"]), ("1", ["1"]), ("01", ["0", "1"]), ("123", ["1", "2", "3"]),
        ("012ABC", ["1", "B"]), ("01AB", ["1", "B"]), ("01ABC", ["0", "1"]),
        ("012AB", ["0", "1", "2"]), ("ac", []), ("bc", []),
        ("z", ["z"]), ("yz", []), ("01yz", ["1", "z"]),
        ("0123456789abc", Array("0123456789abc").map(String.init)),
        ("0123456789abcdefghijklmnopqrstuvwxyz", Array("0123456789abcdefghijklmnopqrstuvwxyz").map(String.init))]
    @Test(arguments: Self.groupingCases)
    func preservesSeriesFilteringAndSensorOrderIncludingTheTerminalZ(sample: (String, [String])) throws {
        let value = try #require(group(sample.0))
        #expect(value.sensorKeyOrder == sample.1.map { "Tp0\($0)" })
        #expect(value.sensorKeyDescriptions.count == sample.1.count)
        for (index, key) in value.sensorKeyOrder.enumerated() {
            #expect(value.sensorKeyDescriptions[key] == (value.sensorKeyOrder.count == 1 ? "CPU" : "CPU \(index + 1)"))
        }
    }
    @Test func noMatchesAndLiteralPatternsDoNotCreateGroups() {
        #expect(group("") == nil)
        #expect(SMCSensorGroup(pattern: "TC0P", usingAvailableSensors: ["TC0P"], description: "CPU") == nil)
        #expect(SMCSensorGroup(pattern: "Tp0?", usingAvailableSensors: ["Unrelated"], description: "CPU") == nil)
    }
    @Test func seriesMutationAndNumericJoiningKeepTheObjectiveCContract() {
        let series = SMCSensorSeries(startingCharacter: "0")
        for character in "123456789" { series.addCharacter(String(character)) }
        #expect(series.concurrentValues == 10 && series.isFullNumericSeries)
        series.addCharacter("a"); #expect(series.concurrentValues == 11 && !series.isFullNumericSeries)
        let sets = SMCSensorGroup.series(for: "T??X", sensors: ["T00X", "T11X", "TzzX"])
        #expect(sets.map(\.characters) == [["0", "1"], ["z"]])
    }
    @Test func consecutiveUppercaseGroupsChooseTheirMiddleReading() throws {
        let value = try #require(group("ABCEF"))
        // Unequal series retain the first series, which is not numbered from 0/1.
        #expect(value.sensorKeyOrder.isEmpty)
        let concurrent = try #require(group("ABCDEF"))
        #expect(concurrent.sensorKeyOrder.isEmpty)
        let split = try #require(group("ABDE"))
        #expect(split.sensorKeyOrder == ["Tp0B", "Tp0E"])
        #expect(split.sensorKeyDescriptions == ["Tp0B": "CPU 1", "Tp0E": "CPU 2"])
    }
}
