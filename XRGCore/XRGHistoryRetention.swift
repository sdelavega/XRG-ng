// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit

/// Shared presentation for graph-local capacity choices. Zero preserves each
/// view's original automatic sizing; persistence never polls a collector.
@MainActor enum XRGHistoryRetention {
    static func saved(_ defaults: UserDefaults, key: String) -> Int {
        let count = defaults.integer(forKey: key)
        return XRGSamplingSettings.validHistorySamples(count) ? count : 0
    }
    static func store(_ sender: Any?, defaults: UserDefaults, key: String) -> Bool {
        guard let item = sender as? NSMenuItem, XRGSamplingSettings.validHistorySamples(item.tag) else { return false }
        defaults.set(item.tag, forKey: key)
        return true
    }
    static func menu(_ title: String, count: Int, target: AnyObject, action: Selector, rootAction: Selector) -> NSMenuItem {
        let root = NSMenuItem(title: title, action: rootAction, keyEquivalent: "")
        root.target = target
        let choices = NSMenu(title: title)
        var counts = XRGSamplingSettings.historyPresets
        if !counts.contains(count) { counts.append(count); counts.sort() }
        for value in counts {
            let choice = NSMenuItem(title: value == 0 ? "Automatic (graph width)" : "\(value) samples", action: action, keyEquivalent: "")
            choice.tag = value; choice.target = target; choice.state = count == value ? .on : .off
            choices.addItem(choice)
        }
        root.submenu = choices
        return root
    }
}
