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
#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(ObjectiveC)
@objc(XRGTokenTotals)
#endif
#if canImport(ObjectiveC)
@objcMembers
#endif
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
#if canImport(ObjectiveC)
@objc(XRGProviderLogParser)
#endif
public final class XRGProviderLogParser: NSObject {
    private struct ClaudeRecord: Decodable {
        let message: Message?
        struct Message: Decodable {
            let id: String?
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

    /// A single bounded record, used by the Linux acquisition layer. Identity lets
    /// the caller replace repeated Claude assistant snapshots instead of summing them.
    public struct UsageRecord: Encodable {
        public let input: UInt64
        public let output: UInt64
        public let total: UInt64
        public let identity: String
        public var model: String? = nil
    }

    public static func claudeRecord(from data: Data) -> UsageRecord? {
        guard let record = try? JSONDecoder().decode(ClaudeRecord.self, from: data),
              let message = record.message, let usage = message.usage,
              let input = sum(usage.input ?? 0, usage.cacheCreation ?? 0, usage.cacheRead ?? 0),
              let total = sum(input, usage.output ?? 0) else { return nil }
        return UsageRecord(input: input, output: usage.output ?? 0, total: total,
                           identity: message.id ?? "", model: modelName(message.model))
    }

    public static func geminiRecord(from data: Data) -> UsageRecord? {
        guard let message = try? JSONDecoder().decode(GeminiMessage.self, from: data),
              let tokens = message.tokens else { return nil }
        let input = tokens.input ?? 0
        let output = tokens.output ?? 0
        guard let total = (tokens.total ?? 0) == 0 ? sum(input, output) : tokens.total else { return nil }
        return UsageRecord(input: input, output: output, total: total, identity: "", model: modelName(message.model))
    }

    /// Optional model metadata must not discard otherwise valid token counts.
    private static func modelName(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 1024,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    public struct UsageDetails: Encodable {
        public let record: UsageRecord
        public let models: [UsageRecord]
    }

    /// Bounded model attribution for Linux. Per-message Gemini metadata takes
    /// precedence over the legacy session-level model; missing names stay unknown.
    public static func usageDetails(from data: Data, kind: UInt32) -> UsageDetails? {
        if kind == 0 || kind == 1 {
            guard let record = kind == 0 ? claudeRecord(from: data) : geminiRecord(from: data),
                  record.identity.utf8.count <= 1024 else { return nil }
            return UsageDetails(record: record, models: [record])
        }
        guard kind == 2, let session = try? JSONDecoder().decode(GeminiSession.self, from: data),
              let messages = session.messages else { return nil }
        let total = XRGTokenTotals()
        var groups: [String: XRGTokenTotals] = [:]
        for message in messages {
            guard let value = message.value, let tokens = value.tokens else { continue }
            let input = tokens.input ?? 0, output = tokens.output ?? 0
            guard let count = (tokens.total ?? 0) == 0 ? sum(input, output) : tokens.total,
                  total.add(input: input, output: output, total: count) else { return nil }
            let model = modelName(value.model ?? session.model) ?? ""
            if groups[model] == nil {
                guard groups.count < 256 else { return nil }
                groups[model] = XRGTokenTotals()
            }
            guard groups[model]!.add(input: input, output: output, total: count) else { return nil }
        }
        return UsageDetails(record: UsageRecord(input: total.input, output: total.output, total: total.total, identity: ""),
            models: groups.keys.sorted().map { model in
                let usage = groups[model]!
                return UsageRecord(input: usage.input, output: usage.output, total: usage.total, identity: "", model: model.isEmpty ? nil : model)
            })
    }

    public static func geminiSession(from data: Data) -> UsageRecord? {
        guard let session = try? JSONDecoder().decode(GeminiSession.self, from: data),
              let messages = session.messages else { return nil }
        let totals = XRGTokenTotals()
        for message in messages {
            guard let tokens = message.value?.tokens else { continue }
            let input = tokens.input ?? 0
            let output = tokens.output ?? 0
            guard let total = (tokens.total ?? 0) == 0 ? sum(input, output) : tokens.total,
                  totals.add(input: input, output: output, total: total) else { return nil }
        }
        return UsageRecord(input: totals.input, output: totals.output, total: totals.total, identity: "")
    }

    #if canImport(ObjectiveC)
    @objc(parseClaudeAtPath:consume:)
    #endif
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

    /// Resumable Claude parse. Records after the checkpoint are reported once each;
    /// `committed` is false only for an unfinished final record, which stays out
    /// of the returned checkpoint so it is never counted twice.
    public static func parseClaude(atPath path: String, resuming checkpoint: XRGAppendCheckpoint?,
                                   begin: (_ resumed: Bool) -> Void = { _ in },
                                   consume: (String?, UInt64, UInt64, _ committed: Bool) -> Void) -> XRGClaudeProgress {
        let decoder = JSONDecoder()
        var committed = XRGTokenCounts(), provisional = XRGTokenCounts()
        guard let handle = FileHandle(forReadingAtPath: path) else {
            begin(false)
            return XRGClaudeProgress(totals: committed, checkpoint: XRGAppendCheckpoint(), resumed: false)
        }
        defer { try? handle.close() }
        let read = XRGLogReader.read(handle, resuming: checkpoint.map { ($0.offset, $0.digest) },
                                     limit: nil, dropOversized: true, begin: { resumed in
            if resumed, let checkpoint { committed = checkpoint.counts }
            // Callers that carry their own per-record state start from it only on a resume.
            begin(resumed)
        }) { line, isCommitted in
            guard let record = try? decoder.decode(ClaudeRecord.self, from: line),
                  let message = record.message, let usage = message.usage,
                  let input = sum(usage.input ?? 0, usage.cacheCreation ?? 0, usage.cacheRead ?? 0),
                  let total = sum(input, usage.output ?? 0) else { return }
            let counts = XRGTokenCounts(input: input, output: usage.output ?? 0, total: total)
            guard let next = committed.adding(counts) else { return }
            if isCommitted { committed = next } else { provisional = counts }
            consume(message.model, input, usage.output ?? 0, isCommitted)
        }
        // A read error keeps the complete records already read, matching the legacy scanner.
        let saved = XRGAppendCheckpoint(offset: read.complete, digest: read.digest, counts: committed)
        return XRGClaudeProgress(totals: committed.adding(provisional) ?? committed, checkpoint: saved, resumed: read.resumed)
    }

    #if canImport(ObjectiveC)
    @objc(parseGeminiAtPath:consume:)
    #endif
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

/// Token counts of complete records, added with overflow checks.
public struct XRGTokenCounts: Equatable, Sendable {
    public var input: UInt64 = 0
    public var output: UInt64 = 0
    public var total: UInt64 = 0
    public init(input: UInt64 = 0, output: UInt64 = 0, total: UInt64 = 0) {
        self.input = input; self.output = output; self.total = total
    }
    /// nil when any field would overflow, so a record is rejected as a whole.
    func adding(_ other: XRGTokenCounts) -> XRGTokenCounts? {
        let (i, a) = input.addingReportingOverflow(other.input)
        let (o, b) = output.addingReportingOverflow(other.output)
        let (t, c) = total.addingReportingOverflow(other.total)
        return a || b || c ? nil : XRGTokenCounts(input: i, output: o, total: t)
    }
}

/// Where an additive log parse stopped: just after the last complete record,
/// with the counts up to there and a digest of every byte before it.
public struct XRGAppendCheckpoint: Sendable {
    public let offset: UInt64
    let digest: Data?
    let counts: XRGTokenCounts
    public var input: UInt64 { counts.input }
    init(offset: UInt64 = 0, digest: Data? = nil, counts: XRGTokenCounts = XRGTokenCounts()) {
        self.offset = offset; self.digest = digest; self.counts = counts
    }
}

public struct XRGClaudeProgress: Sendable {
    public let totals: XRGTokenCounts
    public let checkpoint: XRGAppendCheckpoint
    /// True when the parse continued from the checkpoint instead of the start.
    public let resumed: Bool
}

/// Streams a log once, line by line, hashing every byte it reads. A resume
/// re-hashes the saved prefix and continues only if every byte still matches;
/// the checkpoint digest comes from the same bytes that were parsed. Without
/// CryptoKit (Linux and Windows builds of the shared core) nothing resumes.
enum XRGLogReader {
    struct Result {
        var complete: UInt64 = 0
        var digest: Data?
        var resumed = false
        var error: (any Error)?
    }

    private struct Hasher {
        #if canImport(CryptoKit)
        var sha = SHA256()
        mutating func update(_ bytes: Data) { sha.update(data: bytes) }
        func digest() -> Data? { Data(sha.finalize()) }
        #else
        mutating func update(_ bytes: Data) {}
        func digest() -> Data? { nil }
        #endif
    }

    static let recordLimit = 8 * 1024 * 1024

    /// Whether this build can verify a checkpoint (CryptoKit is available).
    static var canResume: Bool {
        #if canImport(CryptoKit)
        true
        #else
        false
        #endif
    }

    /// - Parameters:
    ///   - limit: largest file size accepted; nil for none.
    ///   - dropOversized: skip a record over the record limit instead of failing.
    ///   - begin: told once, before any record, whether the parse resumed.
    ///   - consume: each record, and whether it ended with LF (an unfinished
    ///     final record is reported last with `false`).
    static func read(_ handle: FileHandle, resuming checkpoint: (offset: UInt64, digest: Data?)?,
                     limit: UInt64?, dropOversized: Bool, begin: (Bool) -> Void,
                     consume: (Data, Bool) throws -> Void) -> Result {
        var result = Result()
        var hasher = Hasher(), committed = Hasher()
        var line = Data(), dropping = false
        do {
            let size = try handle.seekToEnd()
            if let limit, size > limit { throw CocoaError(.fileReadTooLarge) }
            var start: UInt64 = 0
            if let checkpoint, let expected = checkpoint.digest, checkpoint.offset > 0, checkpoint.offset <= size {
                try handle.seek(toOffset: 0)
                var remaining = checkpoint.offset
                while remaining > 0, let chunk = try handle.read(upToCount: Int(min(remaining, 1024 * 1024))),
                      !chunk.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(chunk)
                    remaining -= UInt64(chunk.count)
                }
                if remaining == 0, hasher.digest() == expected {
                    start = checkpoint.offset
                    committed = hasher
                } else {
                    hasher = Hasher()
                }
            }
            result.resumed = start > 0
            result.complete = start
            result.digest = start > 0 ? committed.digest() : nil
            begin(result.resumed)
            try handle.seek(toOffset: start)
            var base = start
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                if let limit, base + UInt64(chunk.count) > limit { throw CocoaError(.fileReadTooLarge) }
                var index = chunk.startIndex
                while index < chunk.endIndex {
                    let newline = chunk[index...].firstIndex(of: 10)
                    let end = newline ?? chunk.endIndex
                    if !dropping {
                        if line.count + (end - index) <= recordLimit {
                            line.append(contentsOf: chunk[index..<end])
                        } else if dropOversized {
                            line.removeAll(keepingCapacity: true)
                            dropping = true
                        } else {
                            throw CocoaError(.fileReadTooLarge)
                        }
                    }
                    let next = newline.map { $0 + 1 } ?? chunk.endIndex
                    hasher.update(chunk[index..<next])
                    if newline != nil {
                        if !dropping, !line.isEmpty { try consume(line, true) }
                        line.removeAll(keepingCapacity: true)
                        dropping = false
                        committed = hasher
                        result.complete = base + UInt64(next - chunk.startIndex)
                        result.digest = committed.digest()
                    }
                    index = next
                }
                base += UInt64(chunk.count)
            }
        } catch {
            result.error = error
            return result
        }
        if !dropping, !line.isEmpty {
            do { try consume(line, false) } catch { result.error = error }
        }
        return result
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
