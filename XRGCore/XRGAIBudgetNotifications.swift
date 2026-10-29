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
import UserNotifications

private final class XRGAIBudgetSubscription: @unchecked Sendable {
    let events: NotificationCenter
    let token: NSObjectProtocol
    init(events: NotificationCenter, token: NSObjectProtocol) { self.events = events; self.token = token }
    deinit { events.removeObserver(token) }
}

/// Native delivery is installed only by the real application delegate. Tests and
/// smoke scenes inject their own transport and never ask for system permission.
@MainActor public final class XRGAIBudgetNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let events: NotificationCenter
    private let authorized: () async -> Bool
    private let deliver: (Double) async throws -> Void
    private let failure: (Error) -> Void
    private var token: XRGAIBudgetSubscription?
    private var pending: [UUID: Task<Void, Never>] = [:]

    public override convenience init() {
        self.init(events: .default, authorized: {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .authorized
        }, deliver: { percent in
            let content = UNMutableNotificationContent()
            content.title = "AI token budget"
            content.body = String(format: "Observed usage has reached %.0f%% of your daily token budget.", percent)
            let request = UNNotificationRequest(identifier: "xrg-ai-budget", content: content, trigger: nil)
            try await UNUserNotificationCenter.current().add(request)
        }, failure: { NSLog("AI budget notification failed: %@", $0.localizedDescription) })
    }

    init(events: NotificationCenter, authorized: @escaping () async -> Bool,
         deliver: @escaping (Double) async throws -> Void, failure: @escaping (Error) -> Void = { _ in }) {
        self.events = events; self.authorized = authorized; self.deliver = deliver; self.failure = failure
        super.init()
    }

    public func start() {
        guard token == nil else { return }
        let subscription = events.addObserver(forName: .xrgAITokensBudgetThresholdReached, object: nil, queue: .main) { [weak self] note in
            guard let percent = note.userInfo?["percent"] as? Double, percent.isFinite, percent > 0 else { return }
            let observer = note.object as? XRGAITokensObserver
            let generation = note.userInfo?["generation"] as? UUID
            MainActor.assumeIsolated {
                self?.receive(percent, current: {
                    guard let observer, let generation else { return true }
                    return observer.isCurrentNotification(generation)
                })
            }
        }
        token = XRGAIBudgetSubscription(events: events, token: subscription)
    }
    public func stop() {
        token = nil
        pending.values.forEach { $0.cancel() }; pending = [:]
    }
    deinit {
        pending.values.forEach { $0.cancel() }
    }
    private func receive(_ percent: Double, current: @escaping () -> Bool) {
        let id = UUID()
        pending[id] = Task { [weak self] in
            guard let self else { return }
            defer { pending[id] = nil }
            guard await authorized(), !Task.isCancelled, current() else { return }
            do { try await deliver(percent) }
            catch { if !Task.isCancelled { failure(error) } }
        }
    }

    public static func requestPermission() async -> String {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            return granted ? "Budget alerts allowed. Delivery follows macOS notification settings." : "Alerts disabled. Enable XRG-ng in System Settings > Notifications."
        } catch { return "Unable to enable alerts: " + error.localizedDescription }
    }

    // Allow budget banners while the app itself has focus, too.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                  withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier == "xrg-ai-budget" ? [.banner, .list] : [])
    }
    public func installNativeDelegate() { UNUserNotificationCenter.current().delegate = self }
}
