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

/// Shared names for Swift observers and the Objective-C compatibility headers.
@objc(XRGAITokensNotifications)
public final class XRGAITokensNotifications: NSObject {
    @objc public static let resetSession = "XRGAITokensDidResetSession"
    @objc public static let resetDaily = "XRGAITokensDidResetDaily"
    @objc public static let budgetThresholdReached = "XRGAITokensBudgetThresholdReached"
}

public extension Notification.Name {
    static let xrgAITokensDidResetSession = Notification.Name(XRGAITokensNotifications.resetSession)
    static let xrgAITokensDidResetDaily = Notification.Name(XRGAITokensNotifications.resetDaily)
    static let xrgAITokensBudgetThresholdReached = Notification.Name(XRGAITokensNotifications.budgetThresholdReached)
}
