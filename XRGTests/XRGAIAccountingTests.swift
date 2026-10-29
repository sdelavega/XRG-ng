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

import AppKit
import Foundation
import SQLite3
import Testing
@testable import XRGCore

@Suite @MainActor struct XRGAIAccountingTests {
    @Test func endpointPollingWaitsPreserveUsageContinuity() async throws {
        actor Endpoint {
            var calls = 0
            func data() async throws -> Data {
                calls += 1
                let total = 100 + (calls - 1) * 20
                try await Task.sleep(for: .milliseconds(60))
                return Data("claude_code_input_tokens_total \(total)\n".utf8)
            }
        }
        let endpoint = Endpoint()
        let request = XRGURL(timeoutInterval: 2, transport: { _ in try await endpoint.data() })
        let miner = XRGAITokenMiner(home: "/nonexistent-xrg-accounting-fixture", clock: { 0 }, otelRequest: request)
        defer { miner.reset() }
        miner.setAccountingEnabled(true)
        var deltas: [UInt64] = []
        miner.usageEventHandler = { _, delta in deltas.append(delta.usage.total) }
        func waitForResponse() async throws {
            for _ in 0..<100 { if request.isDataReady() { break }; try await Task.sleep(for: .milliseconds(5)) }
            #expect(request.isDataReady())
        }
        _ = miner.fetchFromOTelEndpoint(); try await waitForResponse()
        _ = miner.fetchFromOTelEndpoint(); miner.publish(time: 1, hermesReady: false)
        #expect(deltas.isEmpty)
        _ = miner.fetchFromOTelEndpoint(); miner.publish(time: 2, hermesReady: false)
        try await waitForResponse()
        _ = miner.fetchFromOTelEndpoint(); miner.publish(time: 3, hermesReady: false)
        #expect(deltas == [20])
    }

    @Test func totalOnlyUsageTriggersOneNativeAlertAndResetCancelsQueuedAlert() async throws {
        let suite = "XRG.budget." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "aiTokensTrackingEnabled")
        defaults.set(false, forKey: "aiTokensDailyAutoReset")
        defaults.set(100, forKey: "aiTokensDailyBudget")
        defaults.set(80, forKey: "aiTokensBudgetNotifyPercent")
        let events = NotificationCenter()
        var delivered: [Double] = []
        let notifier = XRGAIBudgetNotifications(events: events, authorized: { true }, deliver: { delivered.append($0) })
        notifier.start(); defer { notifier.stop() }
        let observer = XRGAITokensObserver(defaults: defaults, center: events, calendar: .current, now: Date.init)
        let onlyTotal = XRGTokenAccounting.Delta(usage: .init(total: 80), models: [:])
        observer.recordUsage(onlyTotal, provider: "Codex")
        observer.resetDaily() // Invalidate the alert before its main-queue delivery.
        try await Task.sleep(for: .milliseconds(20))
        #expect(delivered.isEmpty && observer.sessionTotalTokens == 80)
        observer.recordUsage(onlyTotal, provider: "Codex")
        for _ in 0..<100 { if !delivered.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        observer.recordUsage(onlyTotal, provider: "Codex")
        try await Task.sleep(for: .milliseconds(10))
        #expect(delivered == [80])
        #expect(observer.dailyTotalTokens == 160 && observer.dailyUnclassifiedTokens == 160)
        #expect(observer.dailyPromptTokens == 0 && observer.dailyCompletionTokens == 0)
    }

    @Test func allCollectedProvidersFeedObservedCountersWithoutBackfill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xrg-ai-" + UUID().uuidString)
        let suite = "XRG.accounting." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "aiTokensTrackingEnabled")
        defaults.set(true, forKey: "aiTokensAggregateByProvider")
        defaults.set(true, forKey: "aiTokensAggregateByModel")
        let observer = XRGAITokensObserver(defaults: defaults, center: NotificationCenter(), calendar: .current, now: Date.init)
        let miner = XRGAITokenMiner(home: root.path, clock: { 0 }, scanInterval: 0)
        miner.setAccountingEnabled(true)
        miner.usageEventHandler = { observer.recordUsage($1, provider: $0) }
        let claude = root.appendingPathComponent(".claude/projects/project/session.jsonl")
        let codex = root.appendingPathComponent(".codex/sessions/2026/10/29/rollout-test.jsonl")
        let gemini = root.appendingPathComponent(".gemini/tmp/hash/chats/session-test.json")
        let hermes = root.appendingPathComponent(".hermes/state.db")
        for file in [claude, codex, gemini, hermes] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        func logs(_ input: Int, _ output: Int, _ codexTotal: Int) throws {
            try Data("{\"message\":{\"model\":\"claude-test\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output)}}}\n".utf8).write(to: claude)
            try Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(codexTotal)}}}}\n".utf8).write(to: codex)
            try Data("{\"model\":\"gemini-test\",\"messages\":[{\"tokens\":{\"input\":\(input),\"output\":\(output),\"total\":\(input + output + 5)}}]}".utf8).write(to: gemini)
        }
        var db: OpaquePointer?
        try #require(sqlite3_open(hermes.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "CREATE TABLE sessions(model TEXT,input_tokens INTEGER,output_tokens INTEGER,actual_cost_usd REAL,estimated_cost_usd REAL); INSERT INTO sessions VALUES ('hermes-test',10,20,0,NULL)", nil, nil, nil) == SQLITE_OK)
        func scan(expected: UInt64) async throws {
            for attempt in 0..<300 {
                _ = miner.fetchFromJSONLTranscripts(); _ = miner.fetchFromCodexCLI(); _ = miner.fetchFromGeminiCLI()
                if attempt > 2 && miner.totalClaudeTokens == expected && miner.totalGeminiTokens == expected + 5 && miner.totalCodexTokens == expected + 70 { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Complete fixture scans did not publish")
        }
        try logs(10, 20, 100)
        try await scan(expected: 30)
        miner.publish(time: 1, hermesReady: miner.fetchFromHermesDatabase())
        #expect(observer.sessionTotalTokens == 0)
        try logs(14, 26, 110)
        try #require(sqlite3_exec(db, "UPDATE sessions SET input_tokens=14,output_tokens=26", nil, nil, nil) == SQLITE_OK)
        try await scan(expected: 40)
        miner.publish(time: 2, hermesReady: miner.fetchFromHermesDatabase())
        #expect(observer.sessionTotalTokens == 40)
        #expect(observer.sessionPromptTokens == 12 && observer.sessionCompletionTokens == 18)
        #expect(observer.sessionUnclassifiedTokens == 10)
        #expect(observer.dailyByProvider.mapValues(\.uint64Value) == ["Claude": 10, "Codex": 10, "Gemini": 10, "Hermes": 10])
        #expect(observer.dailyByModel.mapValues(\.uint64Value) == ["claude-test": 10, "gemini-test": 10, "hermes-test": 10])
        miner.publish(time: 3, hermesReady: miner.fetchFromHermesDatabase())
        #expect(observer.dailyTotalTokens == 40)
        observer.resetSession(); miner.resetAccountingBaseline()
        miner.publish(time: 4, hermesReady: miner.fetchFromHermesDatabase())
        #expect(observer.sessionTotalTokens == 0 && observer.dailyTotalTokens == 40)
        miner.setAccountingEnabled(false)
        miner.totalCodexTokens = 200; miner.publish(time: 5, hermesReady: true)
        miner.setAccountingEnabled(true)
        try await scan(expected: 40)
        miner.publish(time: 6, hermesReady: true)
        #expect(observer.dailyTotalTokens == 40)
        miner.totalCodexTokens = 115; miner.publish(time: 7, hermesReady: true)
        #expect(observer.sessionTotalTokens == 5 && observer.dailyUnclassifiedTokens == 15)
        let reopened = XRGAITokensObserver(defaults: defaults, center: NotificationCenter(), calendar: .current, now: Date.init)
        #expect(reopened.dailyTotalTokens == 45 && reopened.sessionTotalTokens == 0)
        #expect(reopened.dailyByProvider["Codex"] == 15)
        reopened.resetDaily()
        #expect(reopened.dailyTotalTokens == 0 && reopened.dailyByModel.isEmpty)
    }

    @Test func notificationDeliveryRespectsAuthorizationFailuresAndLifetime() async throws {
        let events = NotificationCenter()
        var allowed = false, checks = 0, delivered: [Double] = [], failures = 0
        let notifier = XRGAIBudgetNotifications(events: events, authorized: { checks += 1; return allowed }, deliver: {
            delivered.append($0)
            if $0 == 95 { throw CocoaError(.fileWriteUnknown) }
        }, failure: { _ in failures += 1 })
        func post(_ percent: Double) { events.post(name: .xrgAITokensBudgetThresholdReached, object: nil, userInfo: ["percent": percent]) }
        func waitFor(_ expected: Int) async throws {
            for _ in 0..<100 { if checks >= expected { break }; try await Task.sleep(for: .milliseconds(5)) }
        }
        notifier.start(); notifier.start()
        post(.nan); post(-1); post(80)
        try await waitFor(1)
        #expect(checks == 1 && delivered.isEmpty)
        allowed = true; post(90); try await waitFor(2)
        #expect(delivered == [90])
        post(95); try await waitFor(3)
        #expect(delivered == [90, 95] && failures == 1)
        notifier.stop(); post(100)
        try await Task.sleep(for: .milliseconds(10))
        #expect(checks == 3)
    }

    @Test func notificationPermissionIsRequestedOnlyByExplicitPreferencesAction() async throws {
        let suite = "XRG.permissions." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests = 0
        let pref = XRGPrefController(defaults: defaults, notificationPermission: { requests += 1; return "Allowed in fixture" })
        pref.setUpAIPanel(); pref.setUpAIPanel()
        #expect(requests == 0)
        let button = try #require(pref.AIPrefView?.viewWithTag(1008) as? NSButton)
        #expect(button.target === pref && button.action == #selector(XRGPrefController.allowBudgetNotifications(_:)))
        pref.allowBudgetNotifications(button); pref.allowBudgetNotifications(button)
        #expect(!button.isEnabled)
        for _ in 0..<100 { if button.isEnabled { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(requests == 1 && button.isEnabled)
        #expect((pref.AIPrefView?.viewWithTag(1009) as? NSTextField)?.stringValue == "Allowed in fixture")
    }
}
