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

#if canImport(ObjectiveC)
@objc(XRGCodexLogParser)
#endif
public final class XRGCodexLogParser: NSObject {
    private struct Record: Decodable {
        let type: String
        let payload: Payload
        struct Payload: Decodable {
            let type: String
            let info: Info?
        }
        struct Info: Decodable {
            let totalTokenUsage: Usage?
            enum CodingKeys: String, CodingKey {
                case totalTokenUsage = "total_token_usage"
            }
        }
        struct Usage: Decodable {
            let totalTokens: UInt64?
            let inputTokens: UInt64?
            let outputTokens: UInt64?
            enum CodingKeys: String, CodingKey {
                case totalTokens = "total_tokens"
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }

            var total: UInt64? {
                if let totalTokens { return totalTokens }
                let (sum, overflow) = (inputTokens ?? 0).addingReportingOverflow(outputTokens ?? 0)
                return overflow ? nil : sum
            }
        }
    }

    /// Each event contains a cumulative session total, so repeated events must
    /// replace the previous value rather than contribute to a running sum.
    public static func total(inLine data: Data) -> UInt64? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.type == "event_msg", record.payload.type == "token_count" else { return nil }
        return record.payload.info?.totalTokenUsage?.total
    }

    /// Preserve explicit components only when they fit the authoritative total.
    /// Missing or inconsistent components never manufacture a prompt/output split.
    public static func usage(inLine data: Data) -> XRGTokenUsage? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.type == "event_msg", record.payload.type == "token_count",
              let counts = record.payload.info?.totalTokenUsage, let total = counts.total else { return nil }
        let usage = XRGTokenUsage(input: counts.inputTokens ?? 0, output: counts.outputTokens ?? 0, total: total)
        return usage.isValid ? usage : XRGTokenUsage(total: total)
    }

    public struct Snapshot: Equatable, Sendable {
        public let usage: XRGTokenUsage
        public let modelTotals: [String: UInt64]
    }

    /// Complete bounded file snapshot. I/O/size failures throw so callers can
    /// retain their last complete snapshot instead of publishing a false zero.
    public static func snapshot(atPath path: String) throws -> Snapshot {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var ledger = Attribution(), usage = XRGTokenUsage(total: 0)
        var line = Data(), bytesRead = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            bytesRead += chunk.count
            guard bytesRead <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            for byte in chunk {
                if byte == 10 {
                    if !line.isEmpty {
                        let sample = self.usage(inLine: line)
                        ledger.consume(line, usage: sample)
                        if let sample { usage = sample }
                    }
                    line.removeAll(keepingCapacity: true)
                } else {
                    guard line.count < 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    line.append(byte)
                }
            }
        }
        // A complete final record without LF is valid. A partially written one
        // cannot change totals or donate a model to the next complete scan.
        if !line.isEmpty {
            let sample = self.usage(inLine: line)
            ledger.consume(line, usage: sample)
            if let sample { usage = sample }
        }
        return Snapshot(usage: usage, modelTotals: ledger.models)
    }

    private struct Attribution {
        private struct Metadata: Decodable {
            let type: String
            let payload: Payload?
            struct Payload: Decodable {
                let type: String?
                let model: String?
                let info: Info?
            }
            struct Info: Decodable {
                let lastTokenUsage: Last?
                let includesReasoning: Bool?
                enum CodingKeys: String, CodingKey {
                    case lastTokenUsage = "last_token_usage"
                    case includesReasoning = "last_usage_includes_reasoning"
                }
            }
            struct Last: Decodable {
                let totalTokens: UInt64?
                enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens" }
            }
        }
        private var total: UInt64 = 0
        private var model: String?
        private(set) var models: [String: UInt64] = [:]
        mutating func consume(_ line: Data, usage: XRGTokenUsage?) {
            let record = try? JSONDecoder().decode(Metadata.self, from: line)
            if let usage {
                if usage.total < total {
                    models = [:]; model = nil
                } else {
                    let delta = usage.total - total
                    // Both true and false identify a real request's usage.
                    // An absent marker can be a synthetic context-window fill.
                    if delta > 0, let model, let record,
                       record.type == "event_msg", record.payload?.type == "token_count",
                       let info = record.payload?.info, info.includesReasoning != nil,
                       info.lastTokenUsage?.totalTokens == delta,
                       models[model] != nil || models.count < 255 {
                        models[model, default: 0] += delta
                    }
                }
                total = usage.total
            }
            guard let record else { model = nil; return }
            switch record.type {
            case "turn_context":
                let candidate = record.payload?.model
                model = candidate.flatMap {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1024
                        && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } ? $0 : nil
                }
            case "compacted", "session_meta": model = nil
            case "event_msg":
                switch record.payload?.type {
                case "token_count": if usage == nil { model = nil }
                case "model_reroute", "context_compacted", "thread_rolled_back", "task_started",
                     "turn_started", "task_complete", "turn_complete", "turn_aborted", "error", nil: model = nil
                default: break
                }
            default: break
            }
        }
    }

    #if canImport(ObjectiveC)
    @objc(totalTokensAtPath:)
    #endif
    public static func totalTokens(atPath path: String) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? handle.close() }
        var lastTotal: UInt64 = 0
        var line = Data()
        var droppingOversizedLine = false
        // Session logs can grow large. Bound memory even for corrupt files with
        // no newlines; token-count records are far smaller than this limit.
        let maximumLineBytes = 8 * 1024 * 1024
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                for byte in chunk {
                    if byte == 10 {
                        if !droppingOversizedLine, let total = total(inLine: line) {
                            lastTotal = total
                        }
                        line.removeAll(keepingCapacity: true)
                        droppingOversizedLine = false
                    } else if !droppingOversizedLine {
                        if line.count < maximumLineBytes {
                            line.append(byte)
                        } else {
                            line.removeAll(keepingCapacity: true)
                            droppingOversizedLine = true
                        }
                    }
                }
            }
            // Preserve compatibility with complete final records lacking LF.
            // A partially written JSON object fails decoding and is ignored.
            if !droppingOversizedLine, let total = total(inLine: line) {
                lastTotal = total
            }
        } catch {
            return 0
        }
        return lastTotal
    }
}
