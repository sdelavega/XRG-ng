// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Testing
@testable import XRGSharedCore

/// Claude logs are additive, so a resumed parse must report exactly the records
/// a full parse reports, each once, with only the unfinished tail provisional.
struct ClaudeResumeTests {
    private struct Seen: Equatable { let model: String?; let input: UInt64; let output: UInt64 }
    private func record(_ model: String, _ input: Int, _ output: Int) -> String {
        #"{"message":{"id":"m","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_read_input_tokens":1,"output_tokens":\#(output)}}}"#
    }
    private func file(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xrg-claude-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
    private func parse(_ path: URL, _ checkpoint: XRGAppendCheckpoint?) -> (seen: [Seen], committed: [Seen], progress: XRGClaudeProgress) {
        var seen: [Seen] = [], committed: [Seen] = []
        let progress = XRGProviderLogParser.parseClaude(atPath: path.path, resuming: checkpoint) { model, input, output, isCommitted in
            seen.append(Seen(model: model, input: input, output: output))
            if isCommitted { committed.append(Seen(model: model, input: input, output: output)) }
        }
        return (seen, committed, progress)
    }

    @Test func resumingMatchesAFullParseAtEverySplit() throws {
        let lines = [record("a", 10, 3), "not json", record("b", 5, 2), #"{"message":{}}"#, record("a", 7, 1)]
        let whole = Data((lines.joined(separator: "\n")).utf8)
        try file { path in
            try whole.write(to: path)
            let full = parse(path, nil)
            #expect(full.seen.count == 3 && full.progress.totals.total == 31)
            for split in 1..<whole.count {
                try whole.prefix(split).write(to: path)
                let first = parse(path, nil)
                try whole.write(to: path)
                let resumed = parse(path, first.progress.checkpoint)
                // Committed records before the split plus everything reported after
                // it equal one full parse: nothing is lost or counted twice. Builds
                // that cannot verify a checkpoint parse from the start instead.
                let reported = resumed.progress.resumed ? first.committed + resumed.seen : resumed.seen
                #expect(resumed.progress.resumed == (XRGLogReader.canResume && first.progress.checkpoint.offset > 0), "split \(split)")
                #expect(reported == full.seen, "split \(split)")
                #expect(resumed.progress.totals == full.progress.totals, "split \(split)")
            }
        }
    }

    @Test func unfinishedTailIsProvisionalAndOutsideTheCheckpoint() throws {
        try file { path in
            let complete = record("a", 10, 3) + "\n"
            try Data((complete + record("b", 4, 4)).utf8).write(to: path)
            let result = parse(path, nil)
            #expect(result.seen.count == 2 && result.committed.count == 1)
            #expect(result.progress.checkpoint.offset == UInt64(complete.utf8.count))
            #expect(result.progress.checkpoint.input == 11 && result.progress.totals.total == 23)
        }
    }

    @Test func appendsResumeAndAnyPrefixChangeFallsBackToAFullParse() throws {
        try file { path in
            let noise = String(repeating: "x", count: 6000) + "\n"
            try Data((record("a", 10, 3) + "\n" + noise).utf8).write(to: path)
            let first = parse(path, nil)
            try Data((record("a", 10, 3) + "\n" + noise + record("c", 1, 1) + "\n").utf8).write(to: path)
            let resumed = parse(path, first.progress.checkpoint)
            // Only the appended record is decoded and reported, where a checkpoint
            // can be verified; otherwise everything is parsed again.
            if XRGLogReader.canResume {
                #expect(resumed.progress.resumed && resumed.seen == [Seen(model: "c", input: 2, output: 1)])
            } else {
                #expect(!resumed.progress.resumed && resumed.seen.map(\.model) == ["a", "c"])
            }
            // One early byte changed at the same length: a full parse, every record again.
            try Data((record("b", 10, 3) + "\n" + noise + record("c", 1, 1) + "\n").utf8).write(to: path)
            let edited = parse(path, resumed.progress.checkpoint)
            #expect(!edited.progress.resumed && edited.seen.map(\.model) == ["b", "c"])
            // A shorter file parses from the start.
            try Data((record("d", 1, 1) + "\n").utf8).write(to: path)
            let rewritten = parse(path, edited.progress.checkpoint)
            #expect(!rewritten.progress.resumed && rewritten.seen == [Seen(model: "d", input: 2, output: 1)])
        }
    }
}
