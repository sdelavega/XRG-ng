// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation

/// Yahoo Finance chart data shared by every platform: the one-year daily
/// close history and the fifteen-minute intraday quote, parsed exactly as
/// macOS has done since 0.2.2. Foundation only, so Linux and Windows build it.
public struct XRGStockChart: Equatable, Sendable {
    public let price: Double?
    public let change: Double?
    public let closes: [Double]

    public init(price: Double? = nil, change: Double? = nil, closes: [Double] = []) {
        self.price = price
        self.change = change
        self.closes = closes
    }

    /// One-year daily closes. Nil on error or malformed responses.
    public static func parse(history data: Data) -> XRGStockChart? {
        // An empty close array parses (to no data) rather than failing, as it
        // always has; only a missing result chain is an error.
        guard let closes = result(data)?.indicators?.quote?.first?.close else { return nil }
        return XRGStockChart(closes: closes.compactMap(\.value))
    }

    /// Intraday quote price and its change from the previous close. Nil on
    /// error or malformed responses.
    public static func parse(quote data: Data) -> XRGStockChart? {
        guard let meta = result(data)?.meta,
              let price = meta.regularMarketPrice, let previous = meta.previousClose,
              price.isFinite, price >= 0, previous.isFinite, previous >= 0,
              (price - previous).isFinite else { return nil }
        return XRGStockChart(price: price, change: price - previous)
    }

    /// URLComponents encodes the symbol as one path segment, including indices.
    /// Identical to the URLs XRGStock built on macOS 0.2.2.
    public static func urls(ticker: String) -> (history: URL, quote: URL)? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = ticker.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var history = URLComponents()
        history.scheme = "https"
        history.host = "query1.finance.yahoo.com"
        history.percentEncodedPath = "/v7/finance/chart/" + encoded
        history.queryItems = [
            URLQueryItem(name: "range", value: "1y"),
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "indicators", value: "quote"),
            URLQueryItem(name: "includeTimestamps", value: "true")
        ]
        var quote = history
        quote.percentEncodedPath = "/v8/finance/chart/" + encoded
        quote.queryItems = [
            URLQueryItem(name: "region", value: "US"),
            URLQueryItem(name: "lang", value: "en-US"),
            URLQueryItem(name: "includePrePost", value: "false"),
            URLQueryItem(name: "interval", value: "15m"),
            URLQueryItem(name: "range", value: "1d")
        ]
        guard let historyURL = history.url, let quoteURL = quote.url else { return nil }
        return (history: historyURL, quote: quoteURL)
    }

    private static func result(_ data: Data) -> Response.Result? {
        (try? JSONDecoder().decode(Response.self, from: data))?.chart.result?.first
    }

    private struct Response: Decodable {
        let chart: Chart
        struct Chart: Decodable { let result: [Result]? }
        struct Result: Decodable {
            let meta: Meta?
            let indicators: Indicators?
        }
        struct Meta: Decodable {
            let regularMarketPrice: Double?
            let previousClose: Double?
        }
        struct Indicators: Decodable {
            let quote: [Prices]?
        }
        struct Prices: Decodable { let close: [Price]? }
        struct Price: Decodable {
            let value: Double?
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                let number = try? container.decode(Double.self)
                value = number.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
        }
    }
}
