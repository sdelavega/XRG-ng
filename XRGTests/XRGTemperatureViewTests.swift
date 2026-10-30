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

@MainActor private final class TemperaturePanelHost: NSWindow, XRGTemperatureViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var temperatureView: XRGTemperatureView?
    var minimized = false
    var borderWidth: Int32 = 2
    var timerRequests = 0
    var preferencesOpened = 0
    var sensorWindowsOpened = 0
    var mouseEvents: [String] = []
    init(settings: XRGSettings) {
        appSettings = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        moduleManager = XRGModuleManager(window: self)
    }
    func initTimers() { timerRequests += 1 }
    func checkWindowSize() {}
    func showTemperaturePreferences() { preferencesOpened += 1 }
    func showTemperatureSensors() { sensorWindowsOpened += 1 }
    override func mouseDown(with event: NSEvent) { mouseEvents.append("down") }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}
private final class TemperaturePanelNibOwner: NSObject {}

@MainActor private final class PanelTemperatureReader: NSObject, XRGTemperatureReader {
    var smc: [String: Any] = ["cpu": 50, "gpu": 75, "ssd": 30]
    var fans: [String: Any] = ["Fan #0": ["F0Ac": 1500, "F0Mx": 6000], "Fan #1": ["F1Ac": 2000, "F1Mx": 8000]]
    var labels = ["cpu": "CPU Core", "gpu": "GPU Proximity", "ssd": "SSD", "F0Ac": "Fan Left", "F1Ac": "Fan Right"]
    var known: Set<String> = ["cpu", "gpu", "ssd", "F0Ac", "F1Ac"]
    var knownTemperatureKeyCount = 10
    var requests: [Bool] = []
    var fanRequests = 0
    var time: TimeInterval = 0
    func temperatures(includingUnknown: Bool) -> [String: Any] {
        requests.append(includingUnknown)
        return includingUnknown ? smc : smc.filter { known.contains($0.key) }
    }
    func siliconTemperatures() -> [String: Any] { [:] }
    func fanReadings() -> [String: Any] { fanRequests += 1; return fans }
    func name(forKey key: String) -> String? { labels[key] }
    func isKnownKey(_ key: String) -> Bool { known.contains(key) }
    func miner() -> XRGTemperatureMiner { XRGTemperatureMiner(reader: self, clock: { self.time }) }
}

@Suite(.serialized) @MainActor
struct XRGTemperatureViewTests {
    @Test func retentionKeepsCachedReadingsThrottleSelectionsAndStatistics() throws {
        try withFixture { settings, defaults, reader in
            let miner = reader.miner(), stats = XRGStatsManager()
            let view = panel(miner, settings, defaults, stats: stats)
            view.graphUpdate(nil)
            let sensor = try #require(miner.sensor(forLocation: "cpu"))
            let reads = reader.requests.count, fanReads = reader.fanRequests
            stats.observeStat(55, forKey: "retained", inModule: .nameTemperature)
            reader.time = 2
            let option = NSMenuItem(); option.tag = 300; view.selectHistory(option)
            #expect(sensor.dataSet.numValues == 300 && sensor.dataSet.currentValue == 50)
            #expect(sensor.dataSet.orderedValues.prefix(60).allSatisfy { $0 == XRGGraphRenderer.missingValue })
            #expect(reader.requests.count == reads && reader.fanRequests == fanReads)
            #expect(settings.tempFG1Location == "cpu" && stats.stat(forKey: "retained", inModule: .nameTemperature)?.last == 55)
            view.setFrameSize(NSSize(width: 60, height: 90))
            #expect(sensor.dataSet.numValues == 300)
            let restored = panel(miner, settings, defaults)
            #expect(restored.retainedSamples == 300 && sensor.dataSet.numValues == 300)
            option.tag = 20001; restored.selectHistory(option)
            #expect(restored.retainedSamples == 300)
            option.tag = 1; restored.selectHistory(option)
            #expect(sensor.dataSet.orderedValues == [50])
            reader.time = 3; reader.smc["cpu"] = 60; restored.graphUpdate(nil)
            #expect(reader.requests.count == reads && sensor.currentValue == 50)
            reader.time = 5; restored.graphUpdate(nil)
            #expect(reader.requests.count == reads + 1 && sensor.dataSet.orderedValues == [60])
            option.tag = 0; restored.selectHistory(option)
            #expect(sensor.dataSet.numValues == 240 && sensor.currentValue == 60)
            let history = try #require(restored.makeMenu().items.first { $0.title == "Temperature History" }?.submenu)
            #expect(history.items.allSatisfy { $0.target === restored })
        }
    }
    @Test func explicitTemperaturePaddingDoesNotDistortColdReadingsOrBounds() throws {
        try withFixture { settings, defaults, reader in
            defaults.set(300, forKey: XRGTemperatureView.historyKey)
            settings.tempFG2Location = "absent"; settings.tempFG3Location = "absent"
            let miner = reader.miner(), view = panel(miner, settings, defaults)
            view.graphUpdate(nil)
            let sensor = try #require(miner.sensor(forLocation: "cpu"))
            #expect(sensor.dataSet.orderedValues.dropLast().allSatisfy { $0 == XRGGraphRenderer.missingValue })
            sensor.dataSet.setNextValue(-10); sensor.currentValue = -10
            let row = try #require(view.rows().first)
            #expect(row.lower == -16 && row.upper == 56 && row.value == "-10.0°C")
            settings.tempUnits = .f
            #expect(view.rows().first?.value == "14.0°F" && sensor.dataSet.currentValue == -10)
        }
    }
    private func withFixture(_ body: (XRGSettings, UserDefaults, PanelTemperatureReader) throws -> Void) throws {
        _ = NSApplication.shared
        let domain = "XRG.temperatureView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showTemperatureGraph")
        let settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        settings.textTransparency = 1; settings.textColor = .black
        settings.graphBGTransparency = 1; settings.graphBGColor = .white
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        settings.graphFG3Transparency = 1; settings.graphFG3Color = .green
        settings.borderTransparency = 1; settings.borderColor = .black
        settings.graphStyle = 0; settings.tempUnits = .c
        settings.tempFG1Location = "cpu"; settings.tempFG2Location = "gpu"; settings.tempFG3Location = "F0Ac"
        try body(settings, defaults, PanelTemperatureReader())
    }
    private func panel(_ miner: XRGTemperatureMiner, _ settings: XRGSettings, _ defaults: UserDefaults,
                       stats: XRGStatsManager = XRGStatsManager(), width: CGFloat = 240, height: CGFloat = 160) -> XRGTemperatureView {
        XRGTemperatureView(frame: NSRect(x: 0, y: 0, width: width, height: height), miner: miner,
            statsManager: stats, settings: settings, defaults: defaults)
    }
    private func png(_ view: XRGTemperatureView) throws -> Data {
        view.needsDisplay = true
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func registrationVisibilityFontAndDetachment() throws {
        try withFixture { settings, defaults, reader in
            defaults.set(false, forKey: "showTemperatureGraph")
            let host = TemperaturePanelHost(settings: settings)
            defer { host.close() }
            let view = panel(reader.miner(), settings, defaults)
            host.contentView?.addSubview(view); view.awakeFromNib(); view.awakeFromNib()
            let module = try #require(view.module)
            #expect(module.name == "Temperature" && module.displayOrder == 5)
            #expect(module.doesGraphUpdate && !module.doesFastUpdate && !module.doesMin5Update && !module.doesMin30Update && !module.alwaysDoesGraphUpdate)
            #expect(!module.isDisplayed && module.reference === view && host.temperatureView === view)
            #expect(host.moduleManager?.moduleList().count == 1 && host.timerRequests == 1 && view.subviews.count == 3)
            let width = module.minWidth
            settings.graphFont = NSFont.systemFont(ofSize: 28); view.updateMinSize()
            #expect(module.minWidth > width)
            view.removeFromSuperview()
            #expect(view.module == nil && host.temperatureView == nil && host.moduleManager?.moduleList().isEmpty == true)
        }
    }

    @Test func replacementAndManagerChangesRemoveOnlyTheOwnedModule() throws {
        try withFixture { settings, defaults, reader in
            let host = TemperaturePanelHost(settings: settings)
            defer { host.close() }
            let first = panel(reader.miner(), settings, defaults), second = panel(reader.miner(), settings, defaults)
            host.contentView?.addSubview(first); first.awakeFromNib()
            host.contentView?.addSubview(second); second.awakeFromNib()
            first.removeFromSuperview()
            #expect(host.temperatureView === second && host.moduleManager?.moduleList().first === second.module)
            let oldManager = try #require(host.moduleManager)
            host.moduleManager = XRGModuleManager(window: host); second.awakeFromNib()
            #expect(oldManager.moduleList().isEmpty && host.moduleManager?.moduleList().count == 1)
            second.removeFromSuperview()
        }
    }

    @Test(arguments: [XRGTemperatureUnits.c, .f])
    func unitsChangeTextWhileBarsAndHistoryStayInNativeUnits(units: XRGTemperatureUnits) throws {
        try withFixture { settings, defaults, reader in
            let view = panel(reader.miner(), settings, defaults)
            view.graphUpdate(nil)
            let native = view.headerBarRects(in: view.bounds)
            settings.tempUnits = units; view.updateMinSize()
            #expect(view.rows().map(\.value) == (units == .c ? ["50.0°C", "75.0°C", "1500 rpm"] : ["122.0°F", "167.0°F", "1500 rpm"]))
            #expect(view.rows().map(\.lower) == [47.5, 47.5, 0])
            #expect(view.rows().map(\.upper) == [77.5, 77.5, 6000])
            #expect(view.headerBarRects(in: view.bounds) == native)
            #expect(abs(native[0].width - 20) < 0.0001 && abs(native[1].width - 220) < 0.0001 && native[2].width == 60)
            #expect(view.graphLabels.leftLabel.accessibilityValue() == "CPU Core\nGPU Proximity\nFan Left")
            #expect(view.graphLabels.rightLabel.accessibilityValue() == view.rows().map(\.value).joined(separator: "\n"))
        }
    }

    @Test func compactPrimaryTemperatureUsesTheFullRangeAndFansUseTheirMaxima() throws {
        try withFixture { settings, defaults, reader in
            let view = panel(reader.miner(), settings, defaults, height: 10)
            view.graphUpdate(nil)
            let values = view.miniValues().map(\.doubleValue)
            #expect(values.count == 3)
            #expect(abs(values[0] - 30.0 / 70 * 100) < 0.0001 && values[1] == 25 && values[2] == 25)
            #expect(view.graphLabels.leftLabel.stringValue == "CPU Core" && view.graphLabels.rightLabel.stringValue == "50.0°C")
            settings.tempUnits = .f; view.updateMinSize()
            #expect(view.miniValues().map(\.doubleValue) == values)
            #expect(view.graphLabels.rightLabel.accessibilityValue() == "122.0°F")
        }
    }

    @Test func selectedFanIsNotDuplicatedAndAStoppedFanIsAValidReading() throws {
        try withFixture { settings, defaults, reader in
            settings.tempFG1Location = "F0Ac"
            let view = panel(reader.miner(), settings, defaults, height: 10)
            view.graphUpdate(nil)
            #expect(view.miniValues().map(\.doubleValue) == [25, 25])
            reader.fans["Fan #0"] = ["F0Ac": 0, "F0Mx": 6000]; reader.time = 5; view.graphUpdate(nil)
            #expect(view.rows().first?.value == "0 rpm")
            #expect(view.miniValues().map(\.doubleValue) == [0, 25])
            #expect(view.makeMenu().items.contains { $0.title == "Fan Left: 0 rpm" })
        }
    }

    @Test func missingSensorsShowUnavailableAndRecoverWithoutLosingSelections() throws {
        try withFixture { settings, defaults, reader in
            let miner = reader.miner(), view = panel(miner, settings, defaults)
            view.graphUpdate(nil)
            reader.smc.removeValue(forKey: "cpu"); reader.time = 5; view.graphUpdate(nil)
            #expect(view.rows().first?.value == "n/a" && view.headerBarRects(in: view.bounds)[0].isEmpty)
            #expect(settings.tempFG1Location == "cpu")
            #expect(view.makeMenu().items.contains { $0.title == "CPU Core: n/a" })
            reader.smc["cpu"] = 60; reader.time = 10; view.graphUpdate(nil)
            #expect(view.rows().first?.value == "60.0°C" && miner.sensor(forLocation: "cpu")?.isEnabled == true)
            #expect(!view.headerBarRects(in: view.bounds)[0].isEmpty)
        }
    }

    @Test func aDisappearingFanCannotChangeTheTemperatureAxisToRPM() throws {
        try withFixture { settings, defaults, reader in
            let view = panel(reader.miner(), settings, defaults)
            view.graphUpdate(nil)
            let scale = view.rows().prefix(2).map { [$0.lower, $0.upper] }
            reader.fans.removeValue(forKey: "Fan #0"); reader.time = 5; view.graphUpdate(nil)
            #expect(view.rows().prefix(2).map { [$0.lower, $0.upper] } == scale)
            let fan = try #require(view.rows().last)
            #expect(fan.value == "n/a" && fan.lower == 0 && fan.upper == 0 && !fan.hasRange)
            #expect(view.headerBarRects(in: view.bounds).last?.isEmpty == true)
        }
    }

    @Test func unknownSensorPolicyRetainsTheFewKnownKeysFallbackAndRefreshesOnChanges() throws {
        try withFixture { settings, defaults, reader in
            reader.smc["mystery"] = 65
            let view = panel(reader.miner(), settings, defaults)
            #expect(!view.includesUnknown)
            view.graphUpdate(nil)
            #expect(reader.requests == [false] && !view.makeMenu().items.contains { $0.title.hasPrefix("mystery:") })
            defaults.set(true, forKey: "tempShowUnknownSensors"); view.graphUpdate(nil)
            #expect(reader.requests == [false, true])
            #expect(view.makeMenu().items.contains { $0.title == "mystery: 65.0°C" })
            defaults.set(false, forKey: "tempShowUnknownSensors")
            reader.knownTemperatureKeyCount = 9
            #expect(view.includesUnknown)
            reader.knownTemperatureKeyCount = 10
            #expect(!view.includesUnknown)
            reader.knownTemperatureKeyCount = 0
            #expect(view.includesUnknown)
        }
    }

    @Test func graphCallbacksKeepTheMinersFiveSecondCadence() throws {
        try withFixture { settings, defaults, reader in
            let view = panel(reader.miner(), settings, defaults)
            view.graphUpdate(nil); view.graphUpdate(nil)
            reader.time = 4.99; view.graphUpdate(nil)
            #expect(reader.requests.count == 1)
            reader.time = 5; view.graphUpdate(nil)
            #expect(reader.requests.count == 2)
        }
    }

    @Test func defaultChoicesPreferFanCPUAndGPUAndPreserveExplicitSelections() throws {
        try withFixture { settings, defaults, reader in
            settings.tempFG1Location = "0"; settings.tempFG2Location = "1"; settings.tempFG3Location = "2"
            defaults.set(true, forKey: "tempLocationsAutoconfigured")
            let view = panel(reader.miner(), settings, defaults)
            view.graphUpdate(nil)
            #expect([settings.tempFG1Location, settings.tempFG2Location, settings.tempFG3Location] == ["F0Ac", "cpu", "gpu"])
            #expect(defaults.string(forKey: "tempFG1Location") == "F0Ac")
            settings.tempFG1Location = "ssd"; view.graphUpdate(nil)
            #expect(settings.tempFG1Location == "ssd")
            settings.tempFG1Location = ""; settings.tempFG2Location = ""; settings.tempFG3Location = ""
            view.graphUpdate(nil)
            #expect(settings.tempFG1Location.isEmpty && view.emptyMessage() == "Select Sensors in Prefs")
        }
    }

    @Test func emptyDiscoveryWaitsForReadingsThenSelectsTheAvailableCPUAndSSD() throws {
        try withFixture { settings, defaults, reader in
            settings.tempFG1Location = ""; settings.tempFG2Location = ""; settings.tempFG3Location = ""
            reader.smc = [:]; reader.fans = [:]
            let view = panel(reader.miner(), settings, defaults)
            view.graphUpdate(nil)
            #expect(view.emptyMessage() == "No Sensors Found" && !defaults.bool(forKey: "tempLocationsAutoconfigured"))
            reader.smc = ["cpu": 50, "ssd": 30]; reader.time = 5; view.graphUpdate(nil)
            #expect([settings.tempFG1Location, settings.tempFG2Location, settings.tempFG3Location] == ["cpu", "ssd", ""])
            #expect(defaults.bool(forKey: "tempLocationsAutoconfigured"))
            #expect(view.emptyMessage() == nil)
        }
    }

    @Test func emptyAndUnselectedMessagesClearOldReadingsAcrossSizes() throws {
        try withFixture { settings, defaults, reader in
            defaults.set(true, forKey: "tempLocationsAutoconfigured")
            reader.smc = [:]; reader.fans = [:]
            let view = panel(reader.miner(), settings, defaults, width: 60)
            view.graphUpdate(nil)
            #expect(view.graphLabels.leftLabel.accessibilityValue() == "No Sensors\nFound")
            view.setFrameSize(NSSize(width: 200, height: 10))
            #expect(view.graphLabels.leftLabel.accessibilityValue() == "Temperature n/a")
            reader.smc = ["gpu": 75]; reader.time = 5
            settings.tempFG1Location = ""; settings.tempFG2Location = "gpu"; settings.tempFG3Location = ""
            view.graphUpdate(nil)
            #expect(view.emptyMessage() == "Temperature n/a")
            view.setFrameSize(NSSize(width: 60, height: 100))
            #expect(view.rows().first?.slot == 1 && view.emptyMessage() == nil)
            settings.tempFG2Location = ""; view.updateMinSize()
            #expect(view.graphLabels.leftLabel.accessibilityValue() == "Select Sensors\nin Prefs")
            #expect(view.graphLabels.rightLabel.stringValue.isEmpty)
        }
    }

    @Test func percentageZeroValuesMissingNamesAndInvalidScalesStaySafe() throws {
        try withFixture { settings, defaults, reader in
            let miner = reader.miner(), view = panel(miner, settings, defaults)
            view.graphUpdate(nil)
            miner.setCurrentValue(0, andUnits: "%", forLocation: "percentage")
            settings.tempFG1Location = "percentage"; view.updateMinSize()
            #expect(view.rows().first?.value == "0%" && view.rows().first?.sensor.label() == "percentage")
            #expect(view.rows().first?.lower == 0 && view.rows().first?.upper == 100)
            let sensor = try #require(miner.sensor(forLocation: "percentage"))
            sensor.currentValue = .nan; view.updateMinSize()
            #expect(view.rows().first?.value == "n/a" && view.headerBarRects(in: view.bounds)[0].isEmpty)
            reader.fans["Fan #0"] = ["F0Ac": 1500, "F0Mx": 0]; reader.time = 5; view.graphUpdate(nil)
            settings.tempFG1Location = "F0Ac"; view.updateMinSize()
            #expect(view.rows().first?.hasRange == false && view.headerBarRects(in: view.bounds)[0].isEmpty)
            view.setFrameSize(NSSize(width: 240, height: 10))
            #expect(view.miniValues().map(\.doubleValue) == [25])
        }
    }

    @Test func resetClearsOnlyTemperatureStatisticsAndAllSensorHistories() throws {
        try withFixture { settings, defaults, reader in
            let miner = reader.miner(), stats = XRGStatsManager()
            let view = panel(miner, settings, defaults, stats: stats)
            view.graphUpdate(nil)
            stats.observeStat(55, forKey: "fixture", inModule: .nameTemperature)
            stats.observeStat(12, forKey: "other", inModule: .nameCPU)
            view.clearData(nil)
            #expect(stats.stat(forKey: "fixture", inModule: .nameTemperature) == nil)
            #expect(stats.stat(forKey: "other", inModule: .nameCPU)?.last == 12)
            for key in miner.allSensorKeys() { #expect(miner.sensor(forLocation: key)?.dataSet.max == 0) }
            #expect(view.rows().first?.value == "50.0°C")
        }
    }

    @Test func historyBoundsAndCollapsedLayoutsStayNonnegative() throws {
        try withFixture { settings, defaults, reader in
            let miner = reader.miner(), view = panel(miner, settings, defaults)
            view.graphUpdate(nil)
            let sensor = try #require(miner.sensor(forLocation: "cpu"))
            #expect(sensor.dataSet.numValues == 240)
            view.setGraphSize(NSSize(width: CGFloat.greatestFiniteMagnitude, height: 0))
            #expect(sensor.dataSet.numValues == 20_000)
            view.setWidth(-1); #expect(sensor.dataSet.numValues == 20_000)
            view.setGraphSize(NSSize(width: CGFloat.nan, height: 0))
            #expect(sensor.dataSet.numValues == 1)
            for height: CGFloat in [0, 1, 10, 26, 40, 100] {
                view.setFrameSize(NSSize(width: 4, height: height))
                for rect in view.headerBarRects(in: view.bounds) + [view.historyRect(in: view.bounds)] {
                    #expect(rect.size.width >= 0 && rect.size.height >= 0)
                    #expect(rect.isEmpty || view.bounds.contains(rect))
                }
            }
        }
    }

    @Test(arguments: [CGFloat(10), 18, 28], [CGFloat(60), 100, 240])
    func columnsKeepCompleteReadingsAcrossFontsAndWidths(font: CGFloat, width: CGFloat) throws {
        try withFixture { settings, defaults, reader in
            settings.graphFont = NSFont.systemFont(ofSize: font)
            let view = panel(reader.miner(), settings, defaults, width: width, height: 75)
            view.graphUpdate(nil)
            #expect(view.graphLabels.leftLabel.frame.maxX <= view.graphLabels.rightLabel.frame.minX)
            #expect(view.graphLabels.leftLabel.accessibilityValue() == "CPU Core\nGPU Proximity\nFan Left")
            #expect(view.graphLabels.rightLabel.accessibilityValue() == "50.0°C\n75.0°C\n1500 rpm")
            for label in view.subviews { #expect(label.frame.size.width >= 0 && label.frame.size.height >= 0) }
        }
    }

    @Test func menusUseCachedReadingsExplicitTargetsAndBothWindowRoutes() throws {
        try withFixture { settings, defaults, reader in
            let miner = reader.miner(), stats = XRGStatsManager()
            let view = panel(miner, settings, defaults, stats: stats)
            let host = TemperaturePanelHost(settings: settings)
            defer { host.close() }
            host.contentView?.addSubview(view); view.awakeFromNib(); view.graphUpdate(nil)
            let requests = reader.requests, fans = reader.fanRequests
            let menu = view.makeMenu()
            #expect(reader.requests == requests && reader.fanRequests == fans)
            #expect(menu.items.contains { $0.title == "CPU Core: 50.0°C" })
            #expect(menu.items.count == 11)
            for item in menu.items where !item.isSeparatorItem { #expect(item.target === view) }
            stats.observeStat(5, forKey: "reset", inModule: .nameTemperature)
            for title in ["Reset Graph", "Open XRG-ng Temperature Preferences...", "Open Temperature Sensors Window..."] {
                let item = try #require(menu.items.first { $0.title == title })
                #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            }
            #expect(stats.stat(forKey: "reset", inModule: .nameTemperature) == nil)
            #expect(host.preferencesOpened == 1 && host.sensorWindowsOpened == 1)
            view.removeFromSuperview()
        }
    }

    @Test(arguments: ["TemperatureView", "LegacyTemperature"])
    func currentAndLegacyNibArchivesInstantiateTheSwiftPanel(name: String) throws {
        try withFixture { _, _, _ in
            let nib = try #require(NSNib(nibNamed: NSNib.Name(name), bundle: Bundle(for: TemperaturePanelNibOwner.self)))
            var objects: NSArray?
            #expect(nib.instantiate(withOwner: TemperaturePanelNibOwner(), topLevelObjects: &objects))
            let view = try #require(objects?.compactMap { $0 as? XRGTemperatureView }.first)
            #expect(view.subviews.count == 3 && view.module == nil)
            #expect(view.frame.size == NSSize(width: 76, height: 76))
            withExtendedLifetime(objects) {}
        }
    }

    @Test func fullCompactAndUnavailablePanelsRenderToNativeBitmaps() throws {
        try withFixture { settings, defaults, reader in
            let view = panel(reader.miner(), settings, defaults)
            view.graphUpdate(nil)
            let full = try png(view)
            settings.tempUnits = .f
            #expect(try png(view) != full)
            reader.smc.removeValue(forKey: "cpu"); reader.time = 5; view.graphUpdate(nil)
            #expect(try png(view) != full)
            view.setFrameSize(NSSize(width: 240, height: 10))
            let mini = try png(view)
            settings.graphStyle = 1
            #expect(try png(view) != mini)
            settings.tempFG1Location = ""; settings.tempFG2Location = ""; settings.tempFG3Location = ""
            #expect(try png(view) != mini)
        }
    }

    @Test func mouseEventsStillReachTheWindow() throws {
        try withFixture { settings, defaults, reader in
            let host = TemperaturePanelHost(settings: settings)
            defer { host.close() }
            let view = panel(reader.miner(), settings, defaults)
            host.contentView?.addSubview(view); view.awakeFromNib()
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: host.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            #expect(view.acceptsFirstMouse(for: event))
            view.mouseDown(with: event); view.mouseDragged(with: event); view.mouseUp(with: event)
            #expect(host.mouseEvents == ["down", "drag", "up"])
            view.removeFromSuperview()
        }
    }
}
