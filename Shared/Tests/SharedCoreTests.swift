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
    @Test(arguments: XRGBuiltinTheme.allCases) func palettesKeepSevenBoundedColors(_ theme: XRGBuiltinTheme) {
        #expect(theme.rgba.count == 7)
        #expect(theme.rgba.allSatisfy { $0.count == 4 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } })
    }
}
