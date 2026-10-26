import Foundation
import Testing
@testable import XRGCore

struct XRGAITokensObserverTests {
    private func fixture(_ body: (UserDefaults, NotificationCenter) throws -> Void) throws {
        let name = "XRG.observer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "aiTokensTrackingEnabled")
        defaults.set(true, forKey: "aiTokensAggregateByModel")
        defaults.set(true, forKey: "aiTokensAggregateByProvider")
        try body(defaults, NotificationCenter())
    }

    @Test func persistenceAndIndependentResets() throws {
        try fixture { defaults, center in
            let observer = XRGAITokensObserver(defaults: defaults, center: center, calendar: .current, now: Date.init)
            observer.recordEvent(promptTokens: 10, completionTokens: 20, model: "model", provider: "provider")
            #expect(observer.sessionTotalTokens == 30)
            #expect(observer.dailyByModel["model"] == 30)
            #expect(observer.dailyByProvider["provider"] == 30)
            let reopened = XRGAITokensObserver(defaults: defaults, center: NotificationCenter(), calendar: .current, now: Date.init)
            #expect(reopened.dailyTotalTokens == 30)
            #expect(reopened.sessionTotalTokens == 0)
            center.post(name: Notification.Name("XRGAITokensDidResetSession"), object: nil)
            #expect(observer.sessionTotalTokens == 0)
            #expect(observer.dailyTotalTokens == 30)
            observer.recordEvent(promptTokens: 1, completionTokens: 2, model: nil, provider: nil)
            center.post(name: Notification.Name("XRGAITokensDidResetDaily"), object: nil)
            #expect(observer.dailyTotalTokens == 0)
            #expect(observer.dailyByModel.isEmpty)
            #expect(observer.sessionTotalTokens == 3)
        }
    }

    @Test func rolloverWithoutNewEventsAndDisabledAutoReset() throws {
        try fixture { defaults, center in
            var date = Date(timeIntervalSince1970: 1_700_000_000)
            defaults.set(true, forKey: "aiTokensDailyAutoReset")
            let observer = XRGAITokensObserver(defaults: defaults, center: center, calendar: Calendar(identifier: .gregorian), now: { date })
            observer.recordEvent(promptTokens: 5, completionTokens: 5, model: "m", provider: nil)
            date = date.addingTimeInterval(86400)
            #expect(observer.dailyTotalTokens == 0)
            #expect(observer.sessionTotalTokens == 10)
            defaults.set(false, forKey: "aiTokensDailyAutoReset")
            observer.recordEvent(promptTokens: 3, completionTokens: 0, model: nil, provider: nil)
            date = date.addingTimeInterval(86400)
            #expect(observer.dailyTotalTokens == 3)
        }
    }

    @Test func corruptValuesAndOverflow() throws {
        try fixture { defaults, center in
            defaults.set(-1, forKey: "aiTokensDailyPromptTokens")
            defaults.set(["bad": -5, "bool": true, "text": "99", "valid": 3], forKey: "aiTokensDailyModelPromptTokens")
            let observer = XRGAITokensObserver(defaults: defaults, center: center, calendar: .current, now: Date.init)
            #expect(observer.dailyTotalTokens == 0)
            #expect(observer.dailyByModel["valid"] == 3)
            #expect(observer.dailyByModel["bad"] == 0)
            #expect(observer.dailyByModel["text"] == 0)
            observer.recordEvent(promptTokens: .max, completionTokens: .max, model: "m", provider: "p")
            observer.recordEvent(promptTokens: 1, completionTokens: 1, model: "m", provider: "p")
            #expect(observer.sessionTotalTokens == .max)
            #expect(observer.dailyTotalTokens == .max)
            #expect(observer.dailyByModel["m"]?.uint64Value == .max)
        }
    }

    @Test func concurrentEventsAndTrackingDisabled() throws {
        try fixture { defaults, center in
            let observer = XRGAITokensObserver(defaults: defaults, center: center, calendar: .current, now: Date.init)
            DispatchQueue.concurrentPerform(iterations: 100) { _ in
                observer.recordEvent(promptTokens: 2, completionTokens: 1, model: "m", provider: "p")
                _ = observer.dailyByModel
            }
            #expect(observer.dailyTotalTokens == 300)
            #expect(observer.dailyByProvider["p"] == 300)
            defaults.set(false, forKey: "aiTokensTrackingEnabled")
            observer.recordEvent(promptTokens: 10, completionTokens: 10, model: "m", provider: "p")
            #expect(observer.dailyTotalTokens == 300)
        }
    }

    @Test @MainActor func notificationThresholdAndRestartDeduplication() async throws {
        let name = "XRG.observer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "aiTokensTrackingEnabled")
        defaults.set(100, forKey: "aiTokensDailyBudget")
        let center = NotificationCenter()
        let received = NotificationValues()
        let token = center.addObserver(forName: Notification.Name("XRGAITokensBudgetThresholdReached"), object: nil, queue: nil) {
            received.append($0.userInfo?["percent"] as? Double ?? -1)
        }
        defer { center.removeObserver(token) }
        let observer = XRGAITokensObserver(defaults: defaults, center: center, calendar: .current, now: Date.init)
        observer.recordEvent(promptTokens: 79, completionTokens: 0, model: nil, provider: nil)
        #expect(received.values.isEmpty)
        observer.recordEvent(promptTokens: 1, completionTokens: 0, model: nil, provider: nil)
        let reopened = XRGAITokensObserver(defaults: defaults, center: center, calendar: .current, now: Date.init)
        reopened.recordEvent(promptTokens: 20, completionTokens: 0, model: nil, provider: nil)
        for _ in 0..<100 {
            if !received.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(received.values == [80])
    }
}

private final class NotificationValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    var values: [Double] { lock.withLock { storage } }
    func append(_ value: Double) { lock.withLock { storage.append(value) } }
}
