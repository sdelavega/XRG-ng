// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Testing
@testable import XRGSharedCore

struct CodexUsageTests {
    private struct Case: Decodable {
        let name: String; let lines: [String]; let total: UInt64
        let input: UInt64; let output: UInt64; let models: [String: UInt64]
    }
    private func file(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xrg-codex-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        try body(url)
    }
    @Test func commonAttributionCorpusConservesTotalsAndExplicitComponents() throws {
        let url = try #require(Bundle.module.url(forResource:"codex-attribution-cases",withExtension:"json",subdirectory:"Fixtures"))
        let cases = try JSONDecoder().decode([Case].self,from:Data(contentsOf:url))
        for test in cases {
            try file { path in
                try Data(test.lines.joined(separator:"\n").utf8).write(to:path)
                let snapshot = try XRGCodexLogParser.snapshot(atPath:path.path)
                #expect(snapshot.usage == XRGTokenUsage(input:test.input,output:test.output,total:test.total), "\(test.name)")
                #expect(snapshot.modelTotals == test.models, "\(test.name)")
                #expect(snapshot.modelTotals.values.reduce(0,+) <= snapshot.usage.total)
            }
        }
    }
    @Test func modelPartitionIsBoundedAndExistingGroupsContinueAccumulating() throws {
        try file { path in
            var records: [String] = []
            for n in 0..<300 {
                records.append("{\"type\":\"turn_context\",\"payload\":{\"model\":\"m\(n)\"}}")
                records.append(count(n+1,1))
            }
            records.append("{\"type\":\"turn_context\",\"payload\":{\"model\":\"m0\"}}")
            records.append(count(310,10))
            try Data(records.joined(separator:"\n").utf8).write(to:path)
            let sample = try XRGCodexLogParser.snapshot(atPath:path.path)
            #expect(sample.usage.total == 310 && sample.modelTotals.count == 255)
            #expect(sample.modelTotals["m0"] == 11 && sample.modelTotals.values.reduce(0,+) == 265)
        }
    }
    private func count(_ total:Int,_ last:Int)->String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total)},\"last_token_usage\":{\"total_tokens\":\(last)},\"last_usage_includes_reasoning\":true}}}"
    }
    @Test func chunkBoundariesPartialTailAndOversizedRecords() throws {
        try file { path in
            var bytes = Data(repeating:32,count:65520)
            bytes.append(Data((count(72,72)+"\n"+count(80,8)+"\n{\"type\":").utf8))
            try bytes.write(to:path)
            #expect(try XRGCodexLogParser.snapshot(atPath:path.path).usage.total == 80)
            try Data(repeating:120,count:8*1024*1024+1).write(to:path)
            #expect(throws:(any Error).self) { try XRGCodexLogParser.snapshot(atPath:path.path) }
        }
        #expect(throws:(any Error).self) { try XRGCodexLogParser.snapshot(atPath:"/nonexistent-xrg-codex-fixture") }
    }

    /// Resuming after an append must equal one full parse at every split point,
    /// including a split inside a record that is still being written.
    @Test func resumingAfterAnAppendMatchesAFullParseAtEverySplit() throws {
        let url = try #require(Bundle.module.url(forResource:"codex-attribution-cases",withExtension:"json",subdirectory:"Fixtures"))
        let cases = try JSONDecoder().decode([Case].self,from:Data(contentsOf:url))
        for test in cases {
            let whole = Data(test.lines.joined(separator:"\n").utf8)
            try file { path in
                try whole.write(to:path)
                let full = try XRGCodexLogParser.snapshot(atPath:path.path)
                for split in 1..<whole.count {
                    try whole.prefix(split).write(to:path)
                    let first = try XRGCodexLogParser.progress(atPath:path.path, resuming:nil)
                    try whole.write(to:path)
                    let resumed = try XRGCodexLogParser.progress(atPath:path.path, resuming:first.checkpoint)
                    #expect(resumed.snapshot == full, "\(test.name) split \(split)")
                    #expect(resumed.checkpoint.offset <= UInt64(whole.count))
                }
            }
        }
    }

    @Test func checkpointStopsAtTheLastCompleteRecord() throws {
        try file { path in
            let complete = count(10,10) + "\n"
            try Data((complete + count(20,10)).utf8).write(to:path)
            let progress = try XRGCodexLogParser.progress(atPath:path.path, resuming:nil)
            // The unterminated record counts now but is not saved in the checkpoint.
            #expect(progress.snapshot.usage.total == 20)
            #expect(progress.checkpoint.offset == UInt64(complete.utf8.count))
        }
    }

    @Test func logsOverTheOldLimitAreCounted() throws {
        try file { path in
            FileManager.default.createFile(atPath:path.path, contents:nil)
            let handle = try FileHandle(forWritingTo:path)
            let filler = Data(("{\"type\":\"noise\",\"pad\":\"" + String(repeating:"x", count:1000) + "\"}\n").utf8)
            var block = Data(); for _ in 0..<1024 { block.append(filler) }
            try handle.write(contentsOf:Data((count(5,5)+"\n").utf8))
            for _ in 0..<70 { try handle.write(contentsOf:block) }
            try handle.write(contentsOf:Data((count(9,4)+"\n").utf8))
            try handle.close()
            #expect(try XRGCodexLogParser.snapshot(atPath:path.path).usage.total == 9)
        }
    }

    @Test func appendsResumeAndAnyPrefixChangeFallsBackToAFullParse() throws {
        try file { path in
            let noise = "{\"type\":\"noise\",\"pad\":\"" + String(repeating:"x", count:6000) + "\"}\n"
            func log(_ model: String, _ tail: String) -> Data {
                Data(("{\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}\n" + count(10,10) + "\n" + noise + tail).utf8)
            }
            try log("a", "").write(to:path)
            let first = try XRGCodexLogParser.progress(atPath:path.path, resuming:nil)
            let appended = "{\"type\":\"turn_context\",\"payload\":{\"model\":\"c\"}}\n" + count(15,5) + "\n"
            try log("a", appended).write(to:path)
            let resumed = try XRGCodexLogParser.progress(atPath:path.path, resuming:first.checkpoint)
            let full = try XRGCodexLogParser.snapshot(atPath:path.path)
            #expect(resumed.resumed == XRGLogReader.canResume && resumed.snapshot == full)
            #expect(resumed.snapshot.modelTotals == ["a": 10, "c": 5])
            // The same length with one early byte changed: every prefix byte is
            // verified, so this parses from the start.
            try log("b", appended).write(to:path)
            let edited = try XRGCodexLogParser.progress(atPath:path.path, resuming:resumed.checkpoint)
            #expect(!edited.resumed && edited.snapshot.modelTotals == ["b": 10, "c": 5])
            // A shorter file is a rewrite too.
            try Data((count(7,7) + "\n").utf8).write(to:path)
            let rewritten = try XRGCodexLogParser.progress(atPath:path.path, resuming:edited.checkpoint)
            #expect(!rewritten.resumed && rewritten.snapshot.usage.total == 7)
        }
    }
}
