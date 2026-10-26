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
import Testing
@testable import XRGCore

private final class WindowPreferencesFixtureOwner: NSObject {}
@Suite(.serialized) @MainActor
struct XRGWindowPreferencesTests {
    private func legacyDefaults() throws -> NSDictionary {
        let url = try #require(Bundle(for: WindowPreferencesFixtureOwner.self).url(forResource: "LegacyWindowDefaults", withExtension: "plist"))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? NSDictionary)
    }
    private func settings(_ body: (XRGSettings, UserDefaults) throws -> Void) throws {
        _ = NSApplication.shared
        let domain = "XRG.windowPreferences.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(XRGSettings(defaults: defaults), defaults)
    }
    @Test func defaultsMatchThePreMigrationObjectiveCSnapshot() throws {
        let legacy = try legacyDefaults()
        let current = XRGWindowPreferences.defaultValues(metric: false, screen: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(current.count == legacy.count)
        for key in legacy.allKeys.compactMap({ $0 as? String }) {
            if ["backgroundColor", "graphBGColor", "graphFG1Color", "graphFG2Color", "graphFG3Color", "borderColor", "textColor"].contains(key) {
                let old = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: try #require(legacy[key] as? Data))
                let new = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: try #require(current[key] as? Data))
                #expect(old == new)
            } else if key == "graphFont" {
                let old = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: try #require(legacy[key] as? Data))
                let new = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: try #require(current[key] as? Data))
                #expect(old == new)
            } else { #expect((current[key] as? NSObject) == (legacy[key] as? NSObject)) }
        }
        #expect(current["icao"] as? String == "KMOP" && current["ICAO"] == nil)
    }
    @Test(arguments: [true, false])
    func metricDefaultsAndNegativeScreenCoordinates(metric: Bool) throws {
        let values = XRGWindowPreferences.defaultValues(metric: metric, screen: NSRect(x: -1920, y: -100, width: 1920, height: 1080))
        for key in ["cpuTemperatureUnits", "tempUnits", "temperatureUnits", "distanceUnits", "pressureUnits"] { #expect(values[key] as? Int == (metric ? 1 : 0)) }
        #expect(values["windowOriginX"] as? Int == -1030 && values["windowOriginY"] as? Int == 230)
        try settings { settings, _ in
            let restored = XRGWindowPreferences.apply([:] as NSDictionary, to: settings, fallback: values)
            #expect(restored.borderWidth == 4 && restored.graphOrientationVertical)
            #expect(settings.tempUnits == (metric ? .c : .f) && settings.pressureUnits == (metric ? 1 : 0))
        }
    }
    @Test func restoresEveryLegacyFieldWithoutWritingPreferences() throws {
        let legacy = try legacyDefaults()
        try settings { settings, defaults in
            defaults.set("keep", forKey: "sentinel")
            let snapshot = defaults.dictionaryRepresentation()
            let restored = XRGWindowPreferences.apply(legacy, to: settings, fallback: [:])
            #expect(restored.borderWidth == 4 && restored.graphOrientationVertical)
            #expect(settings.antiAliasing && settings.graphRefresh == 1 && settings.stickyWindow && settings.windowLevel == 0)
            #expect(settings.checkForUpdates && !settings.dropShadow && settings.autoExpandGraph && !settings.foregroundWhenExpanding)
            #expect(settings.showSummary && settings.minimizeUpDown == 0 && !settings.isDockIconHidden)
            #expect(settings.fastCPUUsage && settings.separateCPUColor && !settings.showCPUTemperature && settings.cpuTemperatureUnits == 0)
            #expect(settings.showLoadAverage && settings.cpuShowAverageUsage && settings.cpuShowUptime)
            #expect(settings.ICAO == "KMOP" && settings.secondaryWeatherGraph == 1 && settings.temperatureUnits == 0 && settings.distanceUnits == 0 && settings.pressureUnits == 0)
            #expect(settings.showMemoryPagingGraph && settings.memoryShowWired && settings.memoryShowActive && settings.memoryShowInactive && settings.memoryShowFree && settings.memoryShowCache && settings.memoryShowPage)
            #expect(settings.tempUnits == .f && settings.tempFG1Location == "0" && settings.tempFG2Location == "1" && settings.tempFG3Location == "2")
            #expect(settings.netMinGraphScale == 1024 && settings.netGraphMode == 0 && settings.networkInterface == "All")
            #expect(settings.showTotalBandwidthSinceBoot && settings.showTotalBandwidthSinceLoad && settings.diskGraphMode == 0)
            #expect(settings.stockSymbols == "AAPL" && settings.stockGraphTimeFrame == 3 && settings.stockShowChange && settings.showDJIA && settings.showAITokenGraph)
            #expect(settings.graphFont.pointSize == 10 && settings.textRectHeight > 0)
            #expect(settings.backgroundColor.alphaComponent == 0.9 && settings.borderColor.alphaComponent == 0.4)
            #expect(settings.textColor.alphaComponent == 1 && settings.alignRightAttributes[NSAttributedString.Key.font.rawValue] as? NSFont == settings.graphFont)
            #expect(NSDictionary(dictionary: defaults.dictionaryRepresentation()).isEqual(to: snapshot))
        }
    }
    @Test(arguments: [("", false), ("0", false), ("NO", false), ("false", true), ("yes", true), (" no ", true)])
    func stringFallbacksKeepLegacyAppBehaviorWithoutACategoryOverride(sample: (String, Bool)) throws {
        try settings { settings, _ in
            let fallback: [String: Any] = ["graphOrientationVertical": sample.0, "antiAliasing": sample.0, "showAITokenGraph": sample.0]
            let restored = XRGWindowPreferences.apply([:] as NSDictionary, to: settings, fallback: fallback)
            #expect(restored.graphOrientationVertical == sample.1)
            #expect(settings.antiAliasing == sample.1 && settings.showAITokenGraph == sample.1)
            let explicit = XRGWindowPreferences.apply(["antiAliasing": "FALSE", "showAITokenGraph": "TRUE"] as NSDictionary, to: settings, fallback: fallback)
            #expect(settings.antiAliasing == false && settings.showAITokenGraph == true)
            #expect(explicit.graphOrientationVertical == sample.1)
        }
    }
    @Test func persistedValuesOverrideDefaultsAndKeepEmptyStringsAndWideScales() throws {
        try settings { settings, _ in
            let values: NSDictionary = ["borderWidth": 12, "graphOrientationVertical": "NO", "graphRefresh": 0.125, "windowLevel": 2,
                                       "antiAliasing": false, "stickyWindow": "NO", "showCPUBars": "NO", "windowTitle": "Host", "icao": "",
                                       "tempUnits": 1, "tempFG1Location": "TC0P", "tempFG2Location": "", "tempFG3Location": "Fan.0",
                                       "networkInterface": "en4", "netMinGraphScale": 2_000_000_000_000, "stockSymbols": "", "showAITokenGraph": "NO"]
            let fallback = XRGWindowPreferences.defaultValues(metric: false, screen: .zero)
            let restored = XRGWindowPreferences.apply(values, to: settings, fallback: fallback)
            #expect(restored.borderWidth == 12 && !restored.graphOrientationVertical)
            #expect(settings.graphRefresh == 0.125 && settings.windowLevel == 2 && !settings.antiAliasing && !settings.stickyWindow && !settings.fastCPUUsage)
            #expect(settings.windowTitle == "Host" && settings.ICAO.isEmpty && settings.stockSymbols.isEmpty && !settings.showAITokenGraph)
            #expect(settings.tempUnits == .c && settings.tempFG1Location == "TC0P" && settings.tempFG2Location.isEmpty && settings.tempFG3Location == "Fan.0")
            #expect(settings.networkInterface == "en4" && settings.netMinGraphScale == 2_000_000_000_000)
            for value: Any in [NSNumber(value: Int.max), String(Int.max)] {
                _ = XRGWindowPreferences.apply(["netMinGraphScale": value], to: settings, fallback: fallback)
                #expect(settings.netMinGraphScale == Int.max)
            }
            // Double(Int.max) rounds to 2^63 and cannot safely convert back to Int.
            _ = XRGWindowPreferences.apply(["netMinGraphScale": Double(Int.max)], to: settings, fallback: fallback)
            #expect(settings.netMinGraphScale == 1024)
        }
    }
    @Test(arguments: ["malformedArchive", "wrongArchiveClass", "wrongValueTypes", "nonfinite", "negative", "oversized", "empty"])
    func malformedPreferencesFallBackToUsableValues(failure: String) throws {
        try settings { settings, _ in
            let fallback = XRGWindowPreferences.defaultValues(metric: false, screen: .zero)
            var values: [String: Any] = [:]
            switch failure {
            case "malformedArchive": values = ["textColor": Data([0, 1]), "graphFont": Data([0xff])]
            case "wrongArchiveClass":
                let data = try NSKeyedArchiver.archivedData(withRootObject: NSDate(), requiringSecureCoding: true)
                values = ["textColor": data, "graphFont": data]
            case "wrongValueTypes": values = ["textColor": "red", "graphFont": [], "windowTitle": NSNull(), "antiAliasing": [1], "icao": 1]
            case "nonfinite": values = ["graphRefresh": Double.nan, "borderWidth": Double.infinity, "textTransparency": Double.infinity, "netMinGraphScale": -Double.infinity]
            case "negative": values = ["graphRefresh": -1, "borderWidth": -2, "windowLevel": -1, "tempUnits": -1, "textTransparency": -1]
            case "oversized": values = ["graphRefresh": "1e999", "borderWidth": Double.greatestFiniteMagnitude, "windowLevel": 99, "tempUnits": 99, "textTransparency": 2]
            default: break
            }
            let restored = XRGWindowPreferences.apply(values as NSDictionary, to: settings, fallback: fallback)
            #expect(restored.borderWidth == 4 && settings.graphRefresh == 1 && settings.windowLevel == 0 && settings.tempUnits == .f)
            #expect(settings.textColor.alphaComponent == 1 && settings.graphFont.pointSize == 10 && settings.antiAliasing)
            #expect(settings.ICAO == "KMOP" && settings.windowTitle == "")
        }
    }
    @Test(arguments: [true, false])
    func acceptsSecureAndExistingColorFontArchives(secure: Bool) throws {
        try settings { settings, _ in
            let color = try NSKeyedArchiver.archivedData(withRootObject: NSColor.red, requiringSecureCoding: secure)
            let font = try NSKeyedArchiver.archivedData(withRootObject: NSFont.systemFont(ofSize: 19), requiringSecureCoding: secure)
            _ = XRGWindowPreferences.apply(["backgroundColor": color, "backgroundTransparency": "0.25", "graphFont": font], to: settings)
            #expect(settings.backgroundColor.usingColorSpace(.deviceRGB)?.redComponent == 1 && settings.backgroundColor.alphaComponent == 0.25)
            #expect(settings.graphFont.pointSize == 19 && settings.alignCenterAttributes[NSAttributedString.Key.font.rawValue] as? NSFont == settings.graphFont)
        }
    }
}

struct XRGWindowVersionTests {
    @Test(arguments: [("2.1", "2.0", true), ("2.0", "2.0", false), ("2.0", "2.1", false), ("2.10", "2.9", true),
                      ("2.0b2", "2.0b1", true), ("2.0", "2.0b999999999999999999999999", true), ("2.0b9", "2.0", false),
                      ("2.0.0", "2.0", true), ("2.0", "2.0.0", false), ("002.001", "2.1", false),
                      ("999999999999999999999999", "999999999999999999999998", true), ("<html>bad</html>", "2.0", false),
                      ("2..1", "2.0", false), ("2.0b", "2.0", false), ("", "2.0", false)])
    func numericAndBetaOrdering(pair: (String, String, Bool)) { #expect(XRGWindowVersion.isLater(pair.0, than: pair.1) == pair.2) }
}
