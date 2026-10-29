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

/// All counters, dictionaries, and persistence operations are protected by lock.
@objc(XRGAITokensObserver)
public final class XRGAITokensObserver: NSObject, @unchecked Sendable {
    @objc public static let shared = XRGAITokensObserver()
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let center: NotificationCenter
    private let now: () -> Date
    private let calendar: Calendar
    private var generation = UUID()
    private var notificationGeneration = UUID()
    private var sessionPrompt: UInt64 = 0
    private var sessionCompletion: UInt64 = 0
    private var sessionUnclassified: UInt64 = 0
    private var dailyUnclassified: UInt64
    private var modelUnclassified: [String: UInt64]
    private var providerUnclassified: [String: UInt64]
    private var dailyPrompt: UInt64
    private var dailyCompletion: UInt64
    private var modelPrompt: [String: UInt64]
    private var modelCompletion: [String: UInt64]
    private var providerPrompt: [String: UInt64]
    private var providerCompletion: [String: UInt64]
    private var dailyDate: Date?
    private var notifiedDate: Date?

    public override convenience init() {
        self.init(defaults: .standard, center: .default, calendar: .autoupdatingCurrent, now: Date.init)
    }

    init(defaults: UserDefaults, center: NotificationCenter, calendar: Calendar, now: @escaping () -> Date) {
        self.defaults = defaults
        self.center = center
        self.calendar = calendar
        self.now = now
        dailyUnclassified = Self.count(defaults.object(forKey: "aiTokensDailyUnclassifiedTokens"))
        modelUnclassified = Self.counts(defaults.dictionary(forKey: "aiTokensDailyModelUnclassifiedTokens"))
        providerUnclassified = Self.counts(defaults.dictionary(forKey: "aiTokensDailyProviderUnclassifiedTokens"))
        dailyPrompt = Self.count(defaults.object(forKey: "aiTokensDailyPromptTokens"))
        dailyCompletion = Self.count(defaults.object(forKey: "aiTokensDailyCompletionTokens"))
        modelPrompt = Self.counts(defaults.dictionary(forKey: "aiTokensDailyModelPromptTokens"))
        modelCompletion = Self.counts(defaults.dictionary(forKey: "aiTokensDailyModelCompletionTokens"))
        providerPrompt = Self.counts(defaults.dictionary(forKey: "aiTokensDailyProviderPromptTokens"))
        providerCompletion = Self.counts(defaults.dictionary(forKey: "aiTokensDailyProviderCompletionTokens"))
        dailyDate = defaults.object(forKey: "aiTokensDailyDate") as? Date
        notifiedDate = defaults.object(forKey: "aiTokensLastNotifyDate") as? Date
        super.init()
        center.addObserver(self, selector: #selector(resetSession), name: .xrgAITokensDidResetSession, object: nil)
        center.addObserver(self, selector: #selector(resetDaily), name: .xrgAITokensDidResetDaily, object: nil)
    }

    deinit { center.removeObserver(self) }

    private static func count(_ raw: Any?) -> UInt64 {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        return UInt64(number.stringValue) ?? 0
    }
    private static func counts(_ raw: [String: Any]?) -> [String: UInt64] {
        (raw ?? [:]).mapValues { count($0) }
    }
    private func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : value
    }
    private func combined(_ a: [String: UInt64], _ b: [String: UInt64], _ c: [String: UInt64]) -> [String: NSNumber] {
        var result = a
        for values in [b, c] { for (key, value) in values { result[key] = add(result[key] ?? 0, value) } }
        return result.mapValues { NSNumber(value: $0) }
    }

    var accountingGeneration: UUID { lock.withLock { rollover(); return generation } }
    @objc public var sessionPromptTokens: UInt64 { lock.withLock { sessionPrompt } }
    @objc public var sessionCompletionTokens: UInt64 { lock.withLock { sessionCompletion } }
    @objc public var sessionTotalTokens: UInt64 { lock.withLock { add(add(sessionPrompt, sessionCompletion), sessionUnclassified) } }
    @objc public var sessionUnclassifiedTokens: UInt64 { lock.withLock { sessionUnclassified } }
    @objc public var dailyUnclassifiedTokens: UInt64 { lock.withLock { rollover(); return dailyUnclassified } }
    @objc public var dailyPromptTokens: UInt64 { lock.withLock { rollover(); return dailyPrompt } }
    @objc public var dailyCompletionTokens: UInt64 { lock.withLock { rollover(); return dailyCompletion } }
    @objc public var dailyTotalTokens: UInt64 { lock.withLock { rollover(); return add(add(dailyPrompt, dailyCompletion), dailyUnclassified) } }
    @objc public var dailyByModel: [String: NSNumber] { lock.withLock { rollover(); return combined(modelPrompt, modelCompletion, modelUnclassified) } }
    @objc public var dailyByProvider: [String: NSNumber] { lock.withLock { rollover(); return combined(providerPrompt, providerCompletion, providerUnclassified) } }

    @objc(recordEventWithPromptTokens:completionTokens:model:provider:)
    public func recordEvent(promptTokens: UInt64, completionTokens: UInt64, model: String?, provider: String?) {
        record(usage: XRGTokenUsage(input: promptTokens, output: completionTokens, total: add(promptTokens, completionTokens)),
               models: [:], legacyModel: model, provider: provider)
    }

    func recordUsage(_ delta: XRGTokenAccounting.Delta, provider: String) {
        record(usage: delta.usage, models: delta.models, legacyModel: nil, provider: provider)
    }

    private func record(usage: XRGTokenUsage, models: [String: UInt64], legacyModel model: String?, provider: String?) {
        let promptTokens = usage.input, completionTokens = usage.output
        let progress: (Double, UUID)? = lock.withLock {
            guard defaults.bool(forKey: "aiTokensTrackingEnabled") else { return nil }
            rollover()
            let unclassified = usage.isValid ? usage.unclassified : 0
            sessionUnclassified = add(sessionUnclassified, unclassified)
            dailyUnclassified = add(dailyUnclassified, unclassified)
            sessionPrompt = add(sessionPrompt, promptTokens)
            sessionCompletion = add(sessionCompletion, completionTokens)
            dailyPrompt = add(dailyPrompt, promptTokens)
            dailyCompletion = add(dailyCompletion, completionTokens)
            if defaults.bool(forKey: "aiTokensAggregateByModel"), let model, !model.isEmpty {
                modelPrompt[model] = add(modelPrompt[model] ?? 0, promptTokens)
                modelCompletion[model] = add(modelCompletion[model] ?? 0, completionTokens)
            }
            if defaults.bool(forKey: "aiTokensAggregateByModel") {
                for (name, count) in models { modelUnclassified[name] = add(modelUnclassified[name] ?? 0, count) }
            }
            if defaults.bool(forKey: "aiTokensAggregateByProvider"), let provider, !provider.isEmpty {
                providerUnclassified[provider] = add(providerUnclassified[provider] ?? 0, unclassified)
                providerPrompt[provider] = add(providerPrompt[provider] ?? 0, promptTokens)
                providerCompletion[provider] = add(providerCompletion[provider] ?? 0, completionTokens)
            }
            let budget = defaults.integer(forKey: "aiTokensDailyBudget")
            let configuredPercent = defaults.integer(forKey: "aiTokensBudgetNotifyPercent")
            let threshold = configuredPercent > 0 ? configuredPercent : 80
            let today = now()
            var result: Double?
            if budget > 0, !(notifiedDate.map { calendar.isDate($0, inSameDayAs: today) } ?? false) {
                let fraction = Double(add(add(dailyPrompt, dailyCompletion), dailyUnclassified)) / Double(budget)
                if fraction * 100 >= Double(threshold) {
                    notifiedDate = calendar.startOfDay(for: today)
                    result = fraction
                }
            }
            persist()
            return result.map { ($0, notificationGeneration) }
        }
        // Deliver outside the lock so notification consumers can safely read counters.
        if let progress {
            let center = center
            DispatchQueue.main.async { [self] in
                guard isCurrentNotification(progress.1) else { return }
                center.post(name: .xrgAITokensBudgetThresholdReached, object: self,
                            userInfo: ["progress": progress.0, "percent": progress.0 * 100, "generation": progress.1])
            }
        }
    }

    func isCurrentNotification(_ id: UUID) -> Bool {
        lock.withLock { rollover(); return notificationGeneration == id && defaults.bool(forKey: "aiTokensTrackingEnabled") }
    }
    @objc public func resetSession() {
        lock.withLock { sessionPrompt = 0; sessionCompletion = 0; sessionUnclassified = 0; generation = UUID() }
    }
    @objc public func resetDaily() {
        lock.withLock { clearDaily(); persist() }
    }

    private func rollover() {
        guard defaults.bool(forKey: "aiTokensDailyAutoReset") else { return }
        if !(dailyDate.map { calendar.isDate($0, inSameDayAs: now()) } ?? false) {
            clearDaily()
            persist()
        }
    }
    private func clearDaily() {
        generation = UUID(); notificationGeneration = UUID()
        dailyPrompt = 0; dailyCompletion = 0; dailyUnclassified = 0
        modelUnclassified = [:]; providerUnclassified = [:]
        modelPrompt = [:]; modelCompletion = [:]
        providerPrompt = [:]; providerCompletion = [:]
        notifiedDate = nil
        dailyDate = calendar.startOfDay(for: now())
    }
    private func persist() {
        defaults.set(NSNumber(value: dailyUnclassified), forKey: "aiTokensDailyUnclassifiedTokens")
        defaults.set(modelUnclassified.mapValues { NSNumber(value: $0) }, forKey: "aiTokensDailyModelUnclassifiedTokens")
        defaults.set(providerUnclassified.mapValues { NSNumber(value: $0) }, forKey: "aiTokensDailyProviderUnclassifiedTokens")
        defaults.set(NSNumber(value: dailyPrompt), forKey: "aiTokensDailyPromptTokens")
        defaults.set(NSNumber(value: dailyCompletion), forKey: "aiTokensDailyCompletionTokens")
        defaults.set(modelPrompt.mapValues { NSNumber(value: $0) }, forKey: "aiTokensDailyModelPromptTokens")
        defaults.set(modelCompletion.mapValues { NSNumber(value: $0) }, forKey: "aiTokensDailyModelCompletionTokens")
        defaults.set(providerPrompt.mapValues { NSNumber(value: $0) }, forKey: "aiTokensDailyProviderPromptTokens")
        defaults.set(providerCompletion.mapValues { NSNumber(value: $0) }, forKey: "aiTokensDailyProviderCompletionTokens")
        defaults.set(notifiedDate, forKey: "aiTokensLastNotifyDate")
        defaults.set(dailyDate, forKey: "aiTokensDailyDate")
    }
}
