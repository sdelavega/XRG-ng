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

@objc(XRGTokenTotals)
@objcMembers
public final class XRGTokenTotals: NSObject {
    public private(set) var input: UInt64 = 0
    public private(set) var output: UInt64 = 0
    public private(set) var total: UInt64 = 0

    /// Reject an overflowing record atomically, including its cost contribution.
    fileprivate func add(input: UInt64, output: UInt64, total: UInt64) -> Bool {
        let (nextInput, badInput) = self.input.addingReportingOverflow(input)
        let (nextOutput, badOutput) = self.output.addingReportingOverflow(output)
        let (nextTotal, badTotal) = self.total.addingReportingOverflow(total)
        guard !badInput, !badOutput, !badTotal else { return false }
        self.input = nextInput
        self.output = nextOutput
        self.total = nextTotal
        return true
    }
}

/// Decoding and aggregation are Swift-owned. The synchronous callback leaves
/// the existing model-price policy with the caller while it is migrated separately.
@objc(XRGProviderLogParser)
public final class XRGProviderLogParser: NSObject {
    private struct ClaudeRecord: Decodable {
        let message: Message?
        struct Message: Decodable {
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input: UInt64?
            let output: UInt64?
            let cacheCreation: UInt64?
            let cacheRead: UInt64?
            enum CodingKeys: String, CodingKey {
                case input = "input_tokens"
                case output = "output_tokens"
                case cacheCreation = "cache_creation_input_tokens"
                case cacheRead = "cache_read_input_tokens"
            }
        }
    }

    private struct GeminiMessage: Decodable {
        let model: String?
        let tokens: Tokens?
        struct Tokens: Decodable {
            let input: UInt64?
            let output: UInt64?
            let total: UInt64?
        }
    }

    private struct LossyMessage: Decodable {
        let value: GeminiMessage?
        init(from decoder: any Decoder) throws {
            value = try? GeminiMessage(from: decoder)
        }
    }

    private struct GeminiSession: Decodable {
        let model: String?
        let messages: [LossyMessage]?
    }

    private static func sum(_ values: UInt64...) -> UInt64? {
        var total: UInt64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    @objc(parseClaudeAtPath:consume:)
    public static func parseClaude(atPath path: String,
                                   consume: (String?, UInt64, UInt64) -> Void) -> XRGTokenTotals {
        let totals = XRGTokenTotals()
        let decoder = JSONDecoder()
        XRGJSONLines.read(atPath: path) { line in
            guard let record = try? decoder.decode(ClaudeRecord.self, from: line),
                  let message = record.message, let usage = message.usage,
                  let input = sum(usage.input ?? 0, usage.cacheCreation ?? 0, usage.cacheRead ?? 0),
                  let total = sum(input, usage.output ?? 0),
                  totals.add(input: input, output: usage.output ?? 0, total: total) else { return }
            consume(message.model, input, usage.output ?? 0)
        }
        return totals
    }

    @objc(parseGeminiAtPath:consume:)
    public static func parseGemini(atPath path: String,
                                   consume: (String?, UInt64, UInt64) -> Void) -> XRGTokenTotals {
        let totals = XRGTokenTotals()
        let decoder = JSONDecoder()
        func accept(_ message: GeminiMessage, model: String?) {
            guard let tokens = message.tokens else { return }
            let input = tokens.input ?? 0
            let output = tokens.output ?? 0
            let total = (tokens.total ?? 0) == 0 ? sum(input, output) : tokens.total
            guard let total, totals.add(input: input, output: output, total: total) else { return }
            consume(model, input, output)
        }

        if path.hasSuffix(".jsonl") {
            XRGJSONLines.read(atPath: path) { line in
                guard let message = try? decoder.decode(GeminiMessage.self, from: line) else { return }
                accept(message, model: message.model)
            }
        } else if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let session = try? decoder.decode(GeminiSession.self, from: data) {
            for message in session.messages ?? [] {
                if let value = message.value {
                    // Legacy session files use the top-level model for pricing.
                    accept(value, model: session.model)
                }
            }
        }
        return totals
    }
}

/// Shared bounded JSONL reader. Invalid JSON is handled by each typed decoder.
enum XRGJSONLines {
    static func read(atPath path: String, consume: (Data) -> Void) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var line = Data()
        var dropping = false
        let limit = 8 * 1024 * 1024
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    let newline = chunk[start...].firstIndex(of: 10)
                    let end = newline ?? chunk.endIndex
                    if !dropping {
                        if line.count + end - start <= limit {
                            line.append(contentsOf: chunk[start..<end])
                        } else {
                            line.removeAll(keepingCapacity: true)
                            dropping = true
                        }
                    }
                    if let newline {
                        if !dropping { consume(line) }
                        line.removeAll(keepingCapacity: true)
                        dropping = false
                        start = newline + 1
                    } else {
                        start = chunk.endIndex
                    }
                }
            }
            if !dropping, !line.isEmpty { consume(line) }
        } catch {
            // Keep complete records already read, matching the legacy scanner.
        }
    }
}
