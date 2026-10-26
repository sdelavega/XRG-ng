import Foundation
import Testing
import XRGCore

private let historyFixture = Data(#"{"chart":{"result":[{"indicators":{"quote":[{"close":[10,null,11,true,"bad",12,0.5]}]}}]}}"#.utf8)
private let quoteFixture = Data(#"{"chart":{"result":[{"meta":{"regularMarketPrice":0.75,"previousClose":0.75}}]}}"#.utf8)

private func finished(_ stock: XRGStock) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while stock.gettingData && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return !stock.gettingData
}

private actor StockRequests {
    var pending: [String: CheckedContinuation<Data, Error>] = [:]
    func fetch(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { pending[url.path] = $0 }
    }
    func count() -> Int { pending.count }
    func complete(_ path: String, data: Data) {
        pending.removeValue(forKey: path)?.resume(returning: data)
    }
}

struct XRGStockTests {
    @Test func validHistoryAndUnchangedSubDollarQuote() async {
        let stock = XRGStock(transport: { url in
            url.path.contains("/v7/") ? historyFixture : quoteFixture
        })
        stock.symbol = "TEST"
        #expect(await finished(stock))
        #expect(stock.get12MonthValues()?.map(\.doubleValue) == [10, 11, 12, 0.5])
        #expect(stock.get6MonthValues()?.map(\.doubleValue) == [12, 0.5])
        #expect(stock.get3MonthValues()?.map(\.doubleValue) == [0.5])
        #expect(stock.priceString() == "$0.75")
        #expect(stock.changeString() == "unch")
        #expect(!stock.errorOccurred())
    }

    @Test func historyFallbackWhenQuoteFails() async {
        let stock = XRGStock(transport: { url in
            if url.path.contains("/v8/") { throw URLError(.timedOut) }
            return historyFixture
        })
        stock.symbol = "TEST"
        #expect(await finished(stock))
        #expect(stock.getCurrentPriceAndChange()?.map(\.doubleValue) == [0.5, -11.5])
        #expect(stock.changeString() == "▼11.50")
    }

    @Test func quoteWorksWithoutHistory() async {
        let stock = XRGStock(transport: { url in
            if url.path.contains("/v7/") { throw URLError(.badServerResponse) }
            return quoteFixture
        })
        stock.symbol = "TEST"
        #expect(await finished(stock))
        #expect(stock.haveGoodDisplayData && !stock.haveGoodStockArray)
        #expect(stock.priceString() == "$0.75")
        #expect(stock.get12MonthValues() == nil)
    }

    @Test(arguments: ["null", "[]", #"{"chart":{"result":null}}"#,
                      #"{"chart":{"result":[{"meta":{"regularMarketPrice":true,"previousClose":1}}]}}"#])
    func invalidResponses(_ json: String) async {
        let stock = XRGStock(transport: { _ in Data(json.utf8) })
        stock.symbol = "TEST"
        #expect(await finished(stock))
        #expect(stock.errorOccurred() && stock.priceString() == "n/a")
    }

    @Test func symbolIsEncodedAsOnePathSegment() async {
        let stock = XRGStock(transport: { url in
            #expect(url.host == "query1.finance.yahoo.com")
            #expect(url.absoluteString.contains("%5EINDEX%2F%3F%23%26"))
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            #expect(components?.queryItems?.filter { $0.name == "range" }.count == 1)
            return quoteFixture
        })
        stock.symbol = "^INDEX/?#&"
        #expect(await finished(stock))
        #expect(stock.label == "^INDEX/?#&")
    }

    @Test func waitsForBothResponsesAndIgnoresReplacedSymbol() async {
        let requests = StockRequests()
        let stock = XRGStock(transport: { try await requests.fetch($0) })
        stock.symbol = "OLD"
        let deadline = ContinuousClock.now + .seconds(3)
        while await requests.count() < 2 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await requests.count() == 2)
        await requests.complete("/v7/finance/chart/OLD", data: historyFixture)
        #expect(stock.gettingData)
        stock.symbol = "NEW"
        while await requests.count() < 3 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await requests.count() == 3)
        await requests.complete("/v7/finance/chart/NEW", data: historyFixture)
        await requests.complete("/v8/finance/chart/NEW", data: quoteFixture)
        #expect(await finished(stock))
        await requests.complete("/v8/finance/chart/OLD", data: Data(#"{"chart":{"result":[{"meta":{"regularMarketPrice":999,"previousClose":1}}]}}"#.utf8))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(stock.symbol == "NEW" && stock.currentPrice == 0.75)
        stock.resetData()
        #expect(stock.currentPrice == 0 && stock.lastChange == 0)
        #expect(!stock.gettingData && !stock.haveGoodDisplayData)
    }

    @Test func clearingSymbolCancelsAndClearsData() async {
        let stock = XRGStock(transport: { _ in quoteFixture })
        stock.symbol = "TEST"
        #expect(await finished(stock))
        stock.symbol = ""
        #expect(!stock.haveGoodURL && !stock.gettingData && stock.currentPrice == 0)
        #expect(stock.label == nil)
    }
}
