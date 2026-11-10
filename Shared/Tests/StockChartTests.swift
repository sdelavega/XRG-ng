// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import Testing
@testable import XRGSharedCore

/// Fixtures under Shared/Tests/Fixtures/stocks/ are captured live from
/// query1.finance.yahoo.com (AAPL, 2026-11-06) and stripped of the fields the
/// parser does not read; error/empty/malformed cover the failure shapes Yahoo
/// returns. No API keys, cookies or tracking data appear in any fixture.
struct StockChartTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/stocks"))
        return try Data(contentsOf: url)
    }

    @Test func parsesRecordedHistory() throws {
        let chart = try #require(XRGStockChart.parse(history: fixture("history-1y")))
        // One trading year of daily closes, decoded exactly as macOS 0.2.2 did.
        #expect(chart.closes.count == 251)
        #expect(chart.closes.first == 268.4700012207031)
        #expect(chart.closes.last == 342.3699951171875)
        // The history parse carries closes only; price and change come from
        // the 15-minute quote response, matching XRGStock on macOS.
        #expect(chart.price == nil && chart.change == nil)
    }

    @Test func parsesRecordedQuote() throws {
        let chart = try #require(XRGStockChart.parse(quote: fixture("quote-15m")))
        #expect(chart.price == 342.37)
        #expect(chart.change == 342.37 - 344.17)
        #expect(chart.closes == [])
    }

    @Test func errorResponseIsNil() throws {
        for name in ["error-not-found", "malformed"] {
            let data = try fixture(name)
            #expect(XRGStockChart.parse(history: data) == nil)
            #expect(XRGStockChart.parse(quote: data) == nil)
        }
        #expect(XRGStockChart.parse(history: Data("{\"chart\":{\"result\":null,\"error\":{\"code\":\"Not Found\"}}}".utf8)) == nil)
        #expect(XRGStockChart.parse(quote: Data("{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":342.37}}]}}".utf8)) == nil)
    }

    @Test func emptyResultIsNil() throws {
        let data = try fixture("empty-result")
        #expect(XRGStockChart.parse(history: data) == nil)
        #expect(XRGStockChart.parse(quote: data) == nil)
    }

    /// The exact URLs XRGStock 0.2.2 built, unchanged by the move into the core.
    @Test func urlsMatchTheMacOS022Urls() throws {
        let aapl = try #require(XRGStockChart.urls(ticker: "AAPL"))
        #expect(aapl.history.absoluteString == "https://query1.finance.yahoo.com/v7/finance/chart/AAPL?range=1y&interval=1d&indicators=quote&includeTimestamps=true")
        #expect(aapl.quote.absoluteString == "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?region=US&lang=en-US&includePrePost=false&interval=15m&range=1d")
        let gspc = try #require(XRGStockChart.urls(ticker: "^GSPC"))
        #expect(gspc.history.absoluteString == "https://query1.finance.yahoo.com/v7/finance/chart/%5EGSPC?range=1y&interval=1d&indicators=quote&includeTimestamps=true")
        #expect(gspc.quote.absoluteString == "https://query1.finance.yahoo.com/v8/finance/chart/%5EGSPC?region=US&lang=en-US&includePrePost=false&interval=15m&range=1d")
    }
}
