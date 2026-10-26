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

/// Keeps the AppKit polling API while publishing a complete pair of responses.
/// Mutable state is protected by lock; old requests cannot overwrite a new symbol.
@objc(XRGStock)
public final class XRGStock: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private let transport: @Sendable (URL) async throws -> Data
    private var ticker: String?
    private var history: [Double] = []
    private var quote: Quote?
    private var loading = false
    private var generation = UUID()
    private var task: Task<Void, Never>?

    private struct Quote: Sendable {
        let price: Double
        let change: Double
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

    public override init() {
        transport = { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            return data
        }
        super.init()
    }

    public init(transport: @escaping @Sendable (URL) async throws -> Data) {
        self.transport = transport
        super.init()
    }

    deinit { task?.cancel() }

    @objc public var symbol: String? {
        get { lock.withLock { ticker } }
        set {
            lock.withLock {
                invalidate()
                ticker = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                if ticker?.isEmpty == true { ticker = nil }
                history = []
                quote = nil
                startLoading()
            }
        }
    }
    @objc public var label: String? { symbol }
    @objc public var gettingData: Bool { lock.withLock { loading } }
    @objc public var haveGoodURL: Bool { lock.withLock { urls != nil } }
    @objc public var haveGoodStockArray: Bool { lock.withLock { !history.isEmpty } }
    @objc public var haveGoodDisplayData: Bool { lock.withLock { quote != nil || !history.isEmpty } }
    @objc public var closingPrices: [NSNumber]? { lock.withLock { history.isEmpty ? nil : history.map(NSNumber.init(value:)) } }
    @objc public var currentPrice: Double { lock.withLock { quote?.price ?? 0 } }
    @objc public var lastChange: Double { lock.withLock { quote?.change ?? 0 } }

    /// URLComponents encodes the symbol as one path segment, including indices.
    private var urls: (URL, URL)? {
        guard let ticker else { return nil }
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
        return (historyURL, quoteURL)
    }

    @objc public func resetData() {
        lock.withLock {
            invalidate()
            history = []
            quote = nil
        }
    }

    @objc public func loadData() {
        lock.withLock {
            invalidate()
            startLoading()
        }
    }

    /// Caller holds lock. The two requests run concurrently and publish once.
    private func startLoading() {
        guard let (historyURL, quoteURL) = urls else { return }
        let id = generation
        let transport = transport
        loading = true
        task = Task { [weak self] in
            async let historyData = try? transport(historyURL)
            async let quoteData = try? transport(quoteURL)
            let (first, second) = await (historyData, quoteData)
            let prices = first.flatMap(Self.parseHistory) ?? []
            let quote = second.flatMap(Self.parseQuote)
            self?.finish(id: id, history: prices, quote: quote)
        }
    }

    private static func result(_ data: Data) -> Response.Result? {
        (try? JSONDecoder().decode(Response.self, from: data))?.chart.result?.first
    }

    private static func parseHistory(_ data: Data) -> [Double]? {
        result(data)?.indicators?.quote?.first?.close?.compactMap(\.value)
    }

    private static func parseQuote(_ data: Data) -> Quote? {
        guard let meta = result(data)?.meta,
              let price = meta.regularMarketPrice, let previous = meta.previousClose,
              price.isFinite, price >= 0, previous.isFinite, previous >= 0,
              (price - previous).isFinite else { return nil }
        return Quote(price: price, change: price - previous)
    }

    private func finish(id: UUID, history: [Double], quote: Quote?) {
        let accepted = lock.withLock {
            guard generation == id else { return false }
            self.history = history
            self.quote = quote
            loading = false
            task = nil
            return true
        }
        if accepted {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lock.withLock({ self.generation == id }) else { return }
                NotificationCenter.default.post(name: Notification.Name("XRGStockDataUpdated"), object: self)
            }
        }
    }

    private func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        loading = false
    }

    @objc public func errorOccurred() -> Bool {
        lock.withLock { !loading && quote == nil && history.isEmpty }
    }

    private func values(divisor: Int) -> [NSNumber]? {
        lock.withLock {
            guard !history.isEmpty else { return nil }
            return history.suffix(history.count / divisor).map(NSNumber.init(value:))
        }
    }
    @objc public func get1MonthValues() -> [NSNumber]? { values(divisor: 12) }
    @objc public func get3MonthValues() -> [NSNumber]? { values(divisor: 4) }
    @objc public func get6MonthValues() -> [NSNumber]? { values(divisor: 2) }
    @objc public func get12MonthValues() -> [NSNumber]? { values(divisor: 1) }

    @objc public func getCurrentPriceAndChange() -> [NSNumber]? {
        lock.withLock {
            if let quote { return [NSNumber(value: quote.price), NSNumber(value: quote.change)] }
            guard history.count >= 2, let last = history.last else { return nil }
            return [NSNumber(value: last), NSNumber(value: last - history[history.count - 2])]
        }
    }

    @objc public func priceString() -> String {
        guard let values = getCurrentPriceAndChange() else { return "n/a" }
        return String(format: "$%.2f", values[0].doubleValue)
    }

    @objc public func changeString() -> String {
        guard let values = getCurrentPriceAndChange() else { return "n/a" }
        let change = values[1].doubleValue
        if change == 0 { return "unch" }
        return String(format: "%@%.2f", change > 0 ? "▲" : "▼", abs(change))
    }
}
