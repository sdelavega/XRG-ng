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
import XRGCore

struct XRGCommonTests {
    @Test func dampingRetainsCoefficientsAndMaximumFloor() {
        #expect(abs(XRGCommon.dampedValue(usingPreviousValue: 100, currentValue: 0) - 80) < 0.00001)
        #expect(abs(XRGCommon.dampedValue(usingPreviousValue: 100, currentValue: 0, dampingCoefficient: 0.25) - 25) < 0.00001)
        #expect(XRGCommon.dampedMax(usingPreviousMax: 100, currentMax: 0, baseMax: 200) == 200)
        #expect(abs(XRGCommon.dampedMax(usingPreviousMax: 100, currentMax: 0, baseMax: 1) - 95) < 0.00001)
    }
    @Test func byteFormattingPreservesLegacyBoundariesAndRejectsNonfiniteInput() {
        for (value, expected) in [(0.0, "0B"), (1023, "1023B"), (1024, "1.0K"),
            (102400, "100K"), (1048576, "1.00M"), (104857600, "100.0M"),
            (1073741824, "1.00G"), (107374182400, "100.0G"),
            (1099511627776, "1.00T"), (109951162777600, "100.0T"),
            (1125899906842624, "1.00P"), (112589990684262400, "100.0P"), (-1.9, "-1B")] {
            #expect(XRGCommon.formattedString(forBytes: value) == expected)
        }
        #expect(XRGCommon.formattedString(forBytes: .nan) == "n/a")
        #expect(XRGCommon.formattedString(forBytes: .infinity) == "n/a")
        #expect(XRGCommon.formattedString(forBytes: -.greatestFiniteMagnitude) == "\(Int.min)B")
    }
}
