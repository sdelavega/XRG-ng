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

struct XRGStringUtilitiesTests {
    @Test(arguments: [("", ""), ("plain 😀 café", "plain 😀 café"), ("a<b>c</b>d", "acd"),
        ("a<>b", "ab"), ("a<unfinished", "a<unfinished"), ("a<b>x<c", "ax<c"),
        ("<<tag>>", ">"), ("a>b", "a>b"), ("&lt;b&gt;", "&lt;b&gt;"),
        ("<outer><inner>😀</inner></outer>", "😀"), ("a<\n>\nb", "a\nb"),
        ("<\u{301}tag>e\u{301}", "e\u{301}"), ("e\u{301}<\u{301}>👍🏽", "e\u{301}👍🏽")])
    func stripsOnlyCompleteSpansWithoutChangingUnicodeOrEntities(sample: (String, String)) {
        #expect(XRGStringUtilities.stringWithoutXMLTags(sample.0) == sample.1)
        #expect((sample.0 as NSString).stringWithoutXMLTags == sample.1)
    }
    @Test(arguments: [("", false), ("0", false), ("no", false), ("NO", false), ("nO", false),
        ("false", true), ("FALSE", true), ("true", true), ("yes", true), ("1", true),
        ("0.0", true), (" no ", true), (" 0 ", true), ("unknown", true)])
    func explicitLegacyBooleansRetainTheOldRule(sample: (String, Bool)) {
        #expect(XRGStringUtilities.legacyBoolValue(sample.0) == sample.1)
    }
    @Test func largeTaggedInputTerminatesAndKeepsEveryReading() {
        let input = String(repeating: "α<b>😀</b>", count: 10_000)
        #expect(XRGStringUtilities.stringWithoutXMLTags(input) == String(repeating: "α😀", count: 10_000))
    }
    @Test func legacyParsingDoesNotOverrideFoundationBooleans() {
        #expect(XRGStringUtilities.legacyBoolValue("false"))
        #expect(!("false" as NSString).boolValue)
        #expect(("YES" as NSString).boolValue)
    }
}
