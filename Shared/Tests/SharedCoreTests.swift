// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Testing
@testable import XRGSharedCore

struct SharedCoreTests {
    @Test func historyRetainsNewestAndArithmeticStatistics() {
        let history = XRGDataSet()
        history.resize(3)
        for value in [1.0, 2, 3, 4] { history.setNextValue(CGFloat(value)) }
        #expect(history.orderedValues == [2, 3, 4])
        history.resize(5)
        #expect(history.orderedValues == [0, 0, 2, 3, 4])
        history.divideAllValues(by: 2)
        #expect(history.orderedValues == [0, 0, 1, 1.5, 2])
        #expect(history.sum == 4.5 && history.max == 2 && history.min == 0)
        let other = XRGDataSet(contentsOfOtherDataSet: history)!
        history.addOtherDataSetValues(other)
        #expect(history.sum == 9)
        history.subtractOtherDataSetValues(other)
        #expect(history.sum == 4.5)
        history.resize(0)
        #expect(history.orderedValues.isEmpty && history.average == 0)
    }
    @Test func rateRolloverStaleTimeAndSaturation() {
        let rates = XRGRateTracker()
        #expect(rates.sample(counter: 100, key: "rx", time: 1).rate == 0)
        #expect(rates.sample(counter: 600, key: "rx", time: 3).rate == 250)
        #expect(rates.sample(counter: 800, key: "rx", time: 2).rate == 0)
        #expect(rates.sample(counter: 10, key: "rx", time: 4).delta == 0)
        #expect(rates.sample(counter: .max, key: "rx", time: 5).rate == .max)
        #expect(rates.sample(counter: .max, key: "rx", time: .nan).rate == 0)
    }
    @Test func bridgeBoundsAndFiniteValues() throws {
        #expect(abiVersion() == 1)
        #expect(historyCreate(0) == nil)
        let handle = try #require(historyCreate(3))
        defer { historyFree(handle) }
        #expect(historyAppend(handle, .infinity) == -1)
        for value in [1.0, 2, 3, 4] { #expect(historyAppend(handle, value) == 0) }
        var destination = [99.0, 99, 99, 99]
        #expect(historyCopy(handle, &destination, 2) == -1)
        #expect(destination == [99, 99, 99, 99])
        #expect(historyCopy(handle, &destination, 3) == 3)
        #expect(destination == [2, 3, 4, 99])
    }
    @Test func parsersRejectMalformedOrOverflowingData() {
        let metrics = XRGLocalProviderParser.metrics(from: "tokens_input_total{model=\"a b\"} 7\ncost_total 0.25\ntokens_output_total NaN\n")
        #expect(metrics.tokens == 7 && metrics.cost == 0.25)
        let overflow = Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":18446744073709551615,"output_tokens":1}}}}"#.utf8)
        #expect(XRGCodexLogParser.total(inLine: overflow) == nil)
        #expect(XRGLocalProviderParser.modelNames(from: Data(#"{"models":[{"name":"local"}]}"#.utf8)) == ["local"])
    }
    @Test func claudeAndGeminiUseTheExistingParsers() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"message":{"model":"test","usage":{"input_tokens":10,"cache_read_input_tokens":20,"output_tokens":3}}}"#.utf8).write(to: file)
        let claude = XRGProviderLogParser.parseClaude(atPath: file.path, consume: { _, _, _ in })
        #expect(claude.input == 30 && claude.output == 3 && claude.total == 33)
        try Data(#"{"messages":[{"tokens":{"input":4,"output":6,"total":10}}]}"#.utf8).write(to: file)
        #expect(XRGProviderLogParser.parseGemini(atPath: file.path, consume: { _, _, _ in }).total == 10)
    }
    @Test func metarParsingWorksWithoutAppKit() throws {
        let report = try #require(XRGWeatherReport.reports(in: "KSEA 251953Z 21016G24KT 1 1/2SM SCT050 06/04 A2990", station: "KSEA").first)
        #expect(report.windKnots == 16 && report.gustKnots == 24 && report.visibilityMiles == 1.5)
        #expect(XRGWeatherReport.reports(in: "KSEA 251953Z NIL", station: "KSEA").isEmpty)
    }
    @Test func metarDatesCrossMonthAndLeapBoundariesWithoutMixingStations() throws {
        let formatter = ISO8601DateFormatter()
        let reference = try #require(formatter.date(from: "2026-11-01T00:10:00Z"))
        let body = "KSEA 312353Z 00000KT 10SM 00/M02 A3000\nKJFK 010001Z 09040KT 1SM 30/20 A2900\nKSEA 312253Z 18005KT 10SM 10/05 A2990"
        let latest = try #require(XRGWeatherReport.latest(in: body, station: "ksea", relativeTo: reference))
        #expect(latest.0.temperatureC == 0 && latest.0.windKnots == 0)
        #expect(latest.1 == formatter.date(from: "2026-10-31T23:53:00Z"))
        #expect(!latest.0.raw.contains("KJFK"))
        let leap = try #require(formatter.date(from: "2024-03-01T00:10:00Z"))
        #expect(XRGWeatherReport.latest(in: "KSEA 292353Z 00000KT", station: "KSEA", relativeTo: leap)?.1 == formatter.date(from: "2024-02-29T23:53:00Z"))
        let nonLeap = try #require(formatter.date(from: "2025-03-01T00:10:00Z"))
        #expect(XRGWeatherReport.latest(in: "KSEA 292353Z 00000KT", station: "KSEA", relativeTo: nonLeap) == nil)
    }
    @Test func metarAndSpeciPrefixesStayWithTheirOwnReport() throws {
        let body = "METAR KSEA 272053Z 22012KT 10SM 12/07 A2997 RMK AO2\nSPECI KSEA 272032Z 22012KT 10SM 11/07 A2997\nMETAR KJFK 272000Z 09005KT 10SM 20/10 A3000"
        let reports = XRGWeatherReport.reports(in: body, station: "KSEA")
        #expect(reports.count == 2)
        #expect(reports.first?.raw == "KSEA 272053Z 22012KT 10SM 12/07 A2997 RMK AO2")
        #expect(reports.last?.raw == "KSEA 272032Z 22012KT 10SM 11/07 A2997")
        #expect(reports.last?.temperatureC == 11)
    }
    @Test func metarFreshnessAndInternationalWindUnits() throws {
        let reference = try #require(ISO8601DateFormatter().date(from: "2026-10-27T12:10:00Z"))
        #expect(XRGWeatherReport.latest(in: "KSEA 271230Z 00000KT", station: "KSEA", relativeTo: reference) == nil)
        #expect(XRGWeatherReport.latest(in: "KSEA 251200Z 00000KT", station: "KSEA", relativeTo: reference) == nil)
        let report = try #require(XRGWeatherReport.latest(in: "KSEA 271200Z VRB05G10MPS CAVOK M01/M03 Q1013", station: "KSEA", relativeTo: reference)?.0)
        #expect(abs((report.windKnots ?? 0) * 1.852 - 18) < 0.000001)
        #expect(report.windDirection == -1 && report.temperatureC == -1)
        #expect(report.visibilityQualifier == "≥")
        let kmh = try #require(XRGWeatherReport.reports(in: "KSEA 271200Z 09020KMH", station: "KSEA").first)
        #expect(abs((kmh.windKnots ?? 0) * 1.852 - 20) < 0.000001)
    }
    @Test(arguments: XRGBuiltinTheme.allCases) func palettesKeepSevenBoundedColors(_ theme: XRGBuiltinTheme) {
        #expect(theme.rgba.count == 7)
        #expect(theme.rgba.allSatisfy { $0.count == 4 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } })
    }
    @Test func usageRecordsAndMetricsValidity() throws {
        let bytes = Data(#"{"message":{"id":"msg-1","usage":{"input_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4,"output_tokens":5}}}"#.utf8)
        let record = try #require(XRGProviderLogParser.claudeRecord(from: bytes))
        #expect(record.total == 14 && record.identity == "msg-1")
        var input: UInt64 = 99, output: UInt64 = 99, total: UInt64 = 99
        var name = [UInt8](repeating: 42, count: 8)
        let status = bytes.withUnsafeBytes { raw in
            providerUsageParse(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(bytes.count), 0, &input, &output, &total, &name, 2)
        }
        #expect(status == -2 && input == 99 && output == 99 && total == 99 && name == Array(repeating: 42, count: 8))
        let metrics = XRGLocalProviderParser.metrics(from: "claude_code.token.usage{type=\"cacheRead\"} 7\nclaude_code_token_usage_total{type=\"cacheCreation\"} 3\n")
        #expect(metrics.hasTokenSamples && !metrics.hasCostSamples && metrics.tokens == 10)
        #expect(!XRGLocalProviderParser.metrics(from: "tokens_input_total NaN").hasTokenSamples)
        #expect(XRGLocalProviderParser.metrics(from: "tokens_input_total 0").hasTokenSamples)
        #expect(XRGProviderLogParser.geminiSession(from: Data(#"{"messages":[{"tokens":{"input":18446744073709551615,"output":1}}]}"#.utf8)) == nil)
    }
}
