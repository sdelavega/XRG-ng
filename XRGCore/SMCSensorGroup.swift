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

@objc(SMCSensorSeries) @objcMembers
public final class SMCSensorSeries: NSObject {
    public var characters: [String]
    @objc(initWithStartingCharacter:)
    public init(startingCharacter character: String) { characters = [character]; super.init() }
    public func addCharacter(_ character: String) { characters.append(character) }
    public var concurrentValues: Int { characters.count }
    public var isFullNumericSeries: Bool { characters.count == 10 && characters.first == "0" }
}

@objc(SMCSensorGroup) @objcMembers
public final class SMCSensorGroup: NSObject {
    public var sensorKeyOrder: [String] = []
    public var sensorKeyDescriptions: [String: String] = [:]
    @nonobjc static let wildcardOrder = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz").map(String.init)

    @nonobjc static func series(for pattern: String, sensors: Set<String>) -> [SMCSensorSeries] {
        var groups: [SMCSensorSeries] = [], current: SMCSensorSeries?
        for character in wildcardOrder {
            if sensors.contains(pattern.replacingOccurrences(of: "?", with: character)) {
                if let current { current.addCharacter(character) }
                else { current = SMCSensorSeries(startingCharacter: character) }
            } else if let completed = current {
                groups.append(completed); current = nil
            }
        }
        // A run ending at z has no following missing character to flush it.
        if let current { groups.append(current) }
        if let numeric = groups.firstIndex(where: \.isFullNumericSeries),
           let lowerA = groups.firstIndex(where: { $0.characters.first == "a" }) {
            groups[numeric].characters += groups[lowerA].characters
            groups.remove(at: lowerA)
        }
        return groups
    }
    @objc(initWithPattern:usingAvailableSensors:description:)
    public init?(pattern: String, usingAvailableSensors sensors: Set<String>, description label: String) {
        guard pattern.contains("?") else { return nil }
        var groups = Self.series(for: pattern, sensors: sensors)
        guard let first = groups.first else { return nil }
        if !groups.allSatisfy({ $0.concurrentValues == first.concurrentValues }) { groups = [first] }
        super.init()
        func add(_ character: String, label: String) {
            let key = pattern.replacingOccurrences(of: "?", with: character)
            sensorKeyOrder.append(key); sensorKeyDescriptions[key] = label
        }
        if groups.count == 1 {
            if first.concurrentValues == 1, let character = first.characters.first { add(character, label: label) }
            else if ["0", "1"].contains(first.characters.first ?? "") {
                for (index, character) in first.characters.enumerated() { add(character, label: "\(label) \(index + 1)") }
            }
        } else {
            for (index, group) in groups.enumerated() where group.concurrentValues == 2 || group.concurrentValues == 3 {
                add(group.characters[1], label: "\(label) \(index + 1)")
            }
        }
    }
    public override var description: String { "SMCSensorGroup \(sensorKeyDescriptions)" }
}
