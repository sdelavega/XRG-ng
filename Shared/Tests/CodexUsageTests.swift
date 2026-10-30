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
}
