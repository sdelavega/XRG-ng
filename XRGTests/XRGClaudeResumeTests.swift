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

    /// A file rewritten (same length) while its sweep runs fails that sweep; the
    /// retry must notice the new bytes and publish a full parse of them.
    @Test func aRewriteDuringASweepNeverReusesTheStaleCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("p/a.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = record("claude-opus-4", 1000, 300) + "\n" + record("claude-opus-4", 2, 2) + "\n"
        let after = record("claude-opus-4", 9000, 300) + "\n" + record("claude-opus-4", 2, 2) + "\n"
        #expect(before.utf8.count == after.utf8.count)
        try Data(before.utf8).write(to: file)
        let scan = XRGScanCache(interval: 0, settle: .zero)
        scan.refreshResumable(root: root.path, layout: 0) { path, state in
            let result = XRGAIPricing.parseClaude(path, resuming: state as? XRGAIPricing.ClaudeResume)
            try? Data(after.utf8).write(to: URL(fileURLWithPath: path))
            return result
        }
        while scan.isScanning { try await Task.sleep(for: .milliseconds(1)) }
        #expect(scan.lastScanFailed)
        scan.refreshResumable(root: root.path, layout: 0) { path, state in
            XRGAIPricing.parseClaude(path, resuming: state as? XRGAIPricing.ClaudeResume)
        }
        while scan.isScanning { try await Task.sleep(for: .milliseconds(1)) }
        let full = XRGAIPricing.parse(file.path, gemini: false)
        #expect(!scan.lastScanFailed && scan.completedSnapshot?.tokens == full.tokens && scan.completedSnapshot?.cost == full.cost)
    }
}
