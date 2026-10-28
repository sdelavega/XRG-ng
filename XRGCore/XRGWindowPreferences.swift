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

/// Startup preferences are decoded before the window creates timers or lays out modules.
@MainActor @objc(XRGWindowPreferences) @objcMembers
public final class XRGWindowPreferences: NSObject {
    public let borderWidth: Int32
    public let graphOrientationVertical: Bool
    private init(borderWidth: Int32, vertical: Bool) { self.borderWidth = borderWidth; graphOrientationVertical = vertical; super.init() }

    public static func defaultPreferences() -> NSMutableDictionary {
        NSMutableDictionary(dictionary: defaultValues(metric: Locale.current.measurementSystem != .us, screen: NSScreen.main?.frame ?? .zero))
    }
    @nonobjc static func defaultValues(metric: Bool, screen: NSRect) -> [String: Any] {
        var values: [String: Any] = [
            "windowWidth": "140",
            "windowHeight": "700",
            "borderWidth": "4",
            "graphOrientationVertical": "YES",
            "antiAliasing": "YES",
            "graphRefresh": "1.0",
            "showCPUGraph": "YES",
            "showMemoryGraph": "YES",
            "showBatteryGraph": "YES",
            "showTemperatureGraph": "YES",
            "showNetworkGraph": "YES",
            "showDiskGraph": "YES",
            "showWeatherGraph": "YES",
            "showStockGraph": "YES",
            "showGPUGraph": "YES",
            "showNPUGraph": XRGNPUReader.isAppleSilicon() ? "YES" : "NO",
            "showAITokenGraph": "YES",
            "windowLevel": "0",
            "stickyWindow": "YES",
            "checkForUpdates": "YES",
            "dropShadow": "NO",
            "autoExpandGraph": "YES",
            "foregroundWhenExpanding": "NO",
            "showSummary": "YES",
            "minimizeUpDown": "",
            "isDockIconHidden": "NO",
            "showCPUBars": "YES",
            "separateCPUColor": "YES",
            "showCPUTemperature": "NO",
            "showLoadAverage": "YES",
            "cpuShowAverageUsage": "YES",
            "cpuShowUptime": "YES",
            "showMemoryPagingGraph": "YES",
            "memoryShowWired": "YES",
            "memoryShowActive": "YES",
            "memoryShowInactive": "YES",
            "memoryShowFree": "YES",
            "memoryShowCache": "YES",
            "memoryShowPage": "YES",
            "tempFG1Location": "0",
            "tempFG2Location": "1",
            "tempFG3Location": "2",
            "netMinGraphScale": "1024",
            "netGraphMode": "0",
            "showTotalBandwidthSinceBoot": "YES",
            "showTotalBandwidthSinceLoad": "YES",
            "networkInterface": "All",
            "diskGraphMode": "0",
            "icao": "KMOP",
            "secondaryWeatherGraph": "1",
            "stockSymbols": "AAPL",
            "stockGraphTimeFrame": "3",
            "stockShowChange": "YES",
            "showDJIA": "YES",
        ]
        values["cpuTemperatureUnits"] = metric ? 1 : 0
        values["tempUnits"] = metric ? 1 : 0
        values["temperatureUnits"] = metric ? 1 : 0
        values["distanceUnits"] = metric ? 1 : 0
        values["pressureUnits"] = metric ? 1 : 0
        for (name, rgba) in zip(XRGTheme.colorNames, XRGTheme.Builtin.classic.rgba) {
            let color = NSColor(deviceRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
            values[name + "Color"] = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
            values[name + "Transparency"] = String(rgba[3])
        }
        values["graphFont"] = try? NSKeyedArchiver.archivedData(withRootObject: NSFont.systemFont(ofSize: 10), requiringSecureCoding: true)
        let x = screen.origin.x + screen.width * 0.5 - 70, y = screen.maxY - 750
        values["windowOriginX"] = x.isFinite && abs(x) < Double(Int32.max) ? Int(x) : 0
        values["windowOriginY"] = y.isFinite && abs(y) < Double(Int32.max) ? Int(y) : 0
        return values
    }

    @objc(applyDictionary:toSettings:)
    public static func apply(_ dictionary: NSDictionary, to settings: XRGSettings) -> XRGWindowPreferences {
        apply(dictionary, to: settings, fallback: defaultValues(metric: Locale.current.measurementSystem != .us, screen: NSScreen.main?.frame ?? .zero))
    }
    @nonobjc static func apply(_ dictionary: NSDictionary, to settings: XRGSettings, fallback: [String: Any]) -> XRGWindowPreferences {
        func bool(_ key: String) -> Bool {
            if let value = dictionary[key] as? NSNumber { return value.boolValue }
            if let text = dictionary[key] as? String {
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if ["YES", "TRUE", "1"].contains(normalized) { return true }
                if ["NO", "FALSE", "0", ""].contains(normalized) { return false }
            }
            if let value = fallback[key] as? NSNumber { return value.boolValue }
            if let text = fallback[key] as? String { return XRGStringUtilities.legacyBoolValue(text) }
            return false
        }
        func number(_ value: Any?) -> Double? {
            let result: Double?
            if let number = value as? NSNumber { result = number.doubleValue }
            else if let text = value as? String { result = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            else { result = nil }
            return result.flatMap { $0.isFinite ? $0 : nil }
        }
        func double(_ key: String, valid: (Double) -> Bool = { _ in true }) -> Double {
            if let value = number(dictionary[key]), valid(value) { return value }
            return number(fallback[key]) ?? 0
        }
        func integer(_ key: String, range: ClosedRange<Int> = 0...Int(Int32.max)) -> Int {
            func parsed(_ value: Any?) -> Int? {
                // NSNumber-to-Int bridging can saturate an out-of-range Double.
                // Parse its exact numeric text before considering a bounded float.
                if let number = value as? NSNumber, let exact = Int(number.stringValue) { return exact }
                if let text = value as? String, let exact = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return exact }
                guard let value = number(value), value >= Double(Int.min), value < Double(Int.max) else { return nil }
                return Int(value)
            }
            if let value = parsed(dictionary[key]), range.contains(value) { return value }
            return parsed(fallback[key]) ?? 0
        }
        func string(_ key: String) -> String { dictionary[key] as? String ?? fallback[key] as? String ?? "" }
        settings.antiAliasing = bool("antiAliasing")
        settings.stickyWindow = bool("stickyWindow")
        settings.checkForUpdates = bool("checkForUpdates")
        settings.dropShadow = bool("dropShadow")
        settings.autoExpandGraph = bool("autoExpandGraph")
        settings.foregroundWhenExpanding = bool("foregroundWhenExpanding")
        settings.showSummary = bool("showSummary")
        settings.isDockIconHidden = bool("isDockIconHidden")
        settings.fastCPUUsage = bool("showCPUBars")
        settings.separateCPUColor = bool("separateCPUColor")
        settings.showCPUTemperature = bool("showCPUTemperature")
        settings.showLoadAverage = bool("showLoadAverage")
        settings.cpuShowAverageUsage = bool("cpuShowAverageUsage")
        settings.cpuShowUptime = bool("cpuShowUptime")
        settings.showMemoryPagingGraph = bool("showMemoryPagingGraph")
        settings.memoryShowWired = bool("memoryShowWired")
        settings.memoryShowActive = bool("memoryShowActive")
        settings.memoryShowInactive = bool("memoryShowInactive")
        settings.memoryShowFree = bool("memoryShowFree")
        settings.memoryShowCache = bool("memoryShowCache")
        settings.memoryShowPage = bool("memoryShowPage")
        settings.showTotalBandwidthSinceBoot = bool("showTotalBandwidthSinceBoot")
        settings.showTotalBandwidthSinceLoad = bool("showTotalBandwidthSinceLoad")
        settings.stockShowChange = bool("stockShowChange")
        settings.showDJIA = bool("showDJIA")
        settings.windowLevel = integer("windowLevel", range: 0...2)
        settings.minimizeUpDown = integer("minimizeUpDown", range: 0...1)
        settings.cpuTemperatureUnits = integer("cpuTemperatureUnits", range: 0...1)
        settings.secondaryWeatherGraph = integer("secondaryWeatherGraph", range: 0...5)
        settings.temperatureUnits = integer("temperatureUnits", range: 0...1)
        settings.distanceUnits = integer("distanceUnits", range: 0...1)
        settings.pressureUnits = integer("pressureUnits", range: 0...1)
        settings.tempUnits = XRGTemperatureUnits(rawValue: integer("tempUnits", range: 0...1)) ?? .f
        settings.netMinGraphScale = integer("netMinGraphScale", range: 0...Int.max)
        settings.netGraphMode = integer("netGraphMode", range: 0...2)
        settings.diskGraphMode = integer("diskGraphMode", range: 0...2)
        settings.stockGraphTimeFrame = integer("stockGraphTimeFrame", range: 0...3)
        settings.windowTitle = string("windowTitle")
        settings.ICAO = string("icao")
        settings.tempFG1Location = string("tempFG1Location")
        settings.tempFG2Location = string("tempFG2Location")
        settings.tempFG3Location = string("tempFG3Location")
        settings.networkInterface = string("networkInterface")
        settings.stockSymbols = string("stockSymbols")
        settings.graphRefresh = double("graphRefresh") { $0 > 0 }
        for name in ["background", "graphBG", "graphFG1", "graphFG2", "graphFG3", "border", "text"] {
            let key = name + "Color"
            func color(_ value: Any?) -> NSColor? {
                guard let data = value as? Data else { return nil }
                return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
            }
            let alpha = double(name + "Transparency") { (0...1).contains($0) }
            settings.setValue(alpha, forKey: name + "Transparency")
            if let color = color(dictionary[key]) ?? color(fallback[key]) { settings.setValue(color, forKey: key) }
        }
        func font(_ value: Any?) -> NSFont? {
            guard let data = value as? Data else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data)
        }
        settings.graphFont = font(dictionary["graphFont"]) ?? font(fallback["graphFont"]) ?? NSFont.systemFont(ofSize: 10)
        settings.showAITokenGraph = bool("showAITokenGraph")
        return XRGWindowPreferences(borderWidth: Int32(integer("borderWidth")), vertical: bool("graphOrientationVertical"))
    }
}
