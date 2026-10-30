// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit

@MainActor enum XRGSystemTimeWindow {
    static func saved(_ defaults: UserDefaults, key: String) -> Int {
        let value = defaults.integer(forKey: key)
        return (0...XRGTimedHistory.systemMaximumMinutes).contains(value) ? value : 0
    }
    static func store(_ sender: Any?, defaults: UserDefaults, key: String) -> Bool {
        guard let item = sender as? NSMenuItem, (0...XRGTimedHistory.systemMaximumMinutes).contains(item.tag) else { return false }
        defaults.set(item.tag, forKey: key); return true
    }
    static func menu(_ title: String, minutes: Int, target: AnyObject, action: Selector, rootAction: Selector) -> NSMenuItem {
        let root = NSMenuItem(title: title, action: rootAction, keyEquivalent: ""); root.target = target
        let choices = NSMenu(title: title); var presets = [0, 1, 5, 10, 30, 60]
        if !presets.contains(minutes) { presets.append(minutes); presets.sort() }
        for value in presets {
            let label = value == 0 ? "Use sample count" : value == 1 ? "1 minute" : "\(value) minutes"
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.tag = value; item.target = target; item.state = value == minutes ? .on : .off; choices.addItem(item)
        }
        root.submenu = choices; return root
    }
}

/// Per-view projection cache; the miner owns the normal observation stream.
@MainActor final class XRGTimeWindowProjection {
    private let data: [XRGDataSet]
    private var identity: ObjectIdentifier?
    private var revision: UInt64?
    private var minutes = 0
    private var interval = 0.0
    init(channels: Int) { data = (0..<channels).map { _ in XRGDataSet() } }
    func values(from history: XRGTimedHistory, minutes: Int, interval requested: Double) -> [XRGDataSet]? {
        guard minutes > 0 else { return nil }
        let step = requested.isFinite && requested >= XRGTimedHistory.minimumInterval ? requested : XRGTimedHistory.minimumInterval
        guard history.channels == data.count, let count = XRGTimedHistory.binCount(minutes: minutes, interval: step) else { return nil }
        if identity != ObjectIdentifier(history) || revision != history.revision || self.minutes != minutes || interval != step {
            guard let values = history.values(minutes: minutes, interval: step) else { return nil }
            for index in data.indices {
                data[index].resize(count)
                for value in values[index] { data[index].setNextValue(value.isFinite ? value : Double(XRGGraphRenderer.missingValue)) }
            }
            identity = ObjectIdentifier(history); revision = history.revision; self.minutes = minutes; interval = step
        }
        return data
    }
}
