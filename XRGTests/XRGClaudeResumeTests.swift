/*
 * XRG-ng: A system resource grapher for macOS and Linux.
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

struct XRGClaudeResumeTests {
    private func record(_ model: String, _ input: Int, _ output: Int) -> String {
        #"{"message":{"id":"m","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":2,"output_tokens":\#(output)}}}"#
    }

    /// Priced totals, cost and model counts after a resume equal one full parse.
    @Test func resumedPricingEqualsAFullParseAtEverySplit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xrg-claude-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [record("claude-opus-4", 1000, 300), "noise", record("claude-haiku-4-5", 77, 13),
                     record("claude-sonnet-4", 5, 9), record("claude-opus-4", 1, 1)]
        let whole = Data(lines.joined(separator: "\n").utf8)
        try whole.write(to: url)
        let full = XRGAIPricing.parse(url.path, gemini: false)
        for split in 1..<whole.count {
            try whole.prefix(split).write(to: url)
            let (_, state) = XRGAIPricing.parseClaude(url.path, resuming: nil)
            try whole.write(to: url)
            let (resumed, _) = XRGAIPricing.parseClaude(url.path, resuming: state)
            #expect(resumed.tokens == full.tokens && resumed.input == full.input && resumed.output == full.output,
                    "split \(split)")
            #expect(resumed.cost == full.cost && resumed.modelTotals == full.modelTotals, "split \(split)")
        }
    }
}
