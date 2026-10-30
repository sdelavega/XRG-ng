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

@MainActor private final class BatteryHost: NSWindow, XRGBatteryViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var batteryView: XRGBatteryView?
    var minimized = false
    var borderWidth: Int32 = 2
    var timerRequests = 0
    var mouseEvents: [String] = []
    init(settings: XRGSettings) {
        appSettings = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        moduleManager = XRGModuleManager(window: self)
    }
    func initTimers() { timerRequests += 1 }
    func checkWindowSize() {}
    override func mouseDown(with event: NSEvent) { mouseEvents.append("down") }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}
private final class BatteryNibOwner: NSObject {}

@MainActor private final class BatterySource {
    var samples: [XRGBatteryInfo]?
    var reads = 0
    init(_ samples: [XRGBatteryInfo]?) { self.samples = samples }
    func miner() -> XRGBatteryMiner { XRGBatteryMiner(source: { self.reads += 1; return self.samples }) }
}

@Suite(.serialized) @MainActor
struct XRGBatteryViewTests {
    @Test func retentionKeepsSignedPowerStatusAndPollingIndependentOfGraphSize() throws {
        try withFixture { settings, defaults in
            let source = BatterySource([battery()]), view = panel(source, settings, defaults)
            let reads = source.reads, label = view.graphLabels.rightLabel.accessibilityValue()
            let option = NSMenuItem(); option.tag = 300; view.selectHistory(option)
            #expect(source.reads == reads && view.currentWatts == -12 && view.batteryMiner.chargePercent() == 50)
            #expect(view.batteryMiner.dischargeWatts.numValues == 300)
            #expect(view.batteryMiner.dischargeWatts.orderedValues.prefix(100).allSatisfy { $0 == XRGGraphRenderer.missingValue })
            #expect(view.graphLabels.rightLabel.accessibilityValue() == label)
            view.setFrameSize(NSSize(width: 60, height: 90))
            #expect(view.batteryMiner.numSamples == 300 && source.reads == reads)
            let restored = panel(source, settings, defaults)
            #expect(restored.retainedSamples == 300 && restored.currentWatts == -12)
            option.tag = 20001; restored.selectHistory(option); #expect(restored.retainedSamples == 300)
            option.tag = 1; restored.selectHistory(option)
            #expect(restored.batteryMiner.dischargeWatts.orderedValues == [12])
            source.samples = [battery(amperage: 500, plugged: true, charging: true)]
            restored.batteryMiner.graphUpdate(nil)
            #expect(restored.currentWatts == 6 && restored.batteryMiner.chargeWatts.orderedValues == [6])
            option.tag = 0; restored.selectHistory(option)
            #expect(restored.batteryMiner.numSamples == 200 && restored.currentWatts == 6)
            let history = try #require(restored.makeMenu().items.first { $0.title == "Battery History" }?.submenu)
            #expect(history.items.allSatisfy { $0.target === restored })
        }
    }
    @Test func savedBatteryCapacityStartsWithMissingPaddingAndKeepsTheSnapshotOnFailure() throws {
        try withFixture { settings, defaults in
            defaults.set(257, forKey: XRGBatteryView.historyKey)
            let source = BatterySource([battery(amperage: 0)]), view = panel(source, settings, defaults)
            #expect(view.batteryMiner.numSamples == 257 && view.currentWatts == 0)
            #expect(view.batteryMiner.dischargeWatts.orderedValues.dropLast().allSatisfy { $0 == XRGGraphRenderer.missingValue })
            source.samples = nil
            view.batteryMiner.graphUpdate(nil)
            let reads = source.reads, option = NSMenuItem(); option.tag = 600; view.selectHistory(option)
            #expect(source.reads == reads && view.batteryMiner.chargePercent() == 50 && view.currentWatts == 0)
            #expect(view.batteryMiner.numSamples == 600)
        }
    }
    @Test func batteryWindowsKeepPowerPeaksCurrentBarsAndPollingCadenceIndependent() throws {
        try withFixture { settings, defaults in
            settings.graphRefresh=5;var wall=100.0
            let source=BatterySource([battery(amperage:-10000)])
            let miner=XRGBatteryMiner(source:{source.reads+=1;return source.samples},historyClock:{wall})
            let view=XRGBatteryView(frame:NSRect(x:0,y:0,width:200,height:100),miner:miner,settings:settings,defaults:defaults)
            wall=110;source.samples=[battery()];miner.graphUpdate(nil)
            let before=source.reads,option=NSMenuItem();option.tag=1;view.selectHistoryWindow(option)
            #expect(view.historyData()[1].numValues==13 && view.historyData()[1].orderedValues[10]==120 && view.historyData()[1].currentValue==12)
            #expect(view.historyData()[1].orderedValues[11]==XRGGraphRenderer.missingValue)
            view.setFrameSize(NSSize(width:1,height:100));#expect(view.historyWattScale==120 && view.wattScale==30 && view.currentWatts == -12 && source.reads==before)
            let count=miner.timedHistory.observationCount
            wall=115;view.graphUpdate(nil);wall=120;view.graphUpdate(nil);#expect(source.reads==before && miner.timedHistory.observationCount==count)
            wall=125;source.samples=[battery(amperage:2000,plugged:true,charging:true)];view.graphUpdate(nil)
            #expect(source.reads==before+1 && miner.timedHistory.observationCount==count+1 && view.currentWatts==24)
            settings.graphRefresh=0.2;#expect(view.historyData()[0].numValues==301 && view.historyWattScale==120)
            let menu=try #require(view.makeMenu().items.first { $0.title=="Battery Time Window" }?.submenu);#expect(menu.items.allSatisfy { $0.target===view })
            option.tag=61;view.selectHistoryWindow(option);#expect(view.historyMinutes==1)
            wall=126;source.samples=nil;miner.graphUpdate(nil);#expect(view.historyData()[0].currentValue==XRGGraphRenderer.missingValue && view.currentWatts==24)
            wall=127;source.samples=[];miner.graphUpdate(nil);#expect(miner.batteryStatus() == .noBattery && view.historyData()[0].orderedValues.allSatisfy { $0==XRGGraphRenderer.missingValue })
            wall=128;source.samples=[battery()];miner.graphUpdate(nil);#expect(view.historyData()[1].orderedValues.dropLast().allSatisfy { $0==XRGGraphRenderer.missingValue })
            wall=129;source.samples=[battery(),battery()];miner.graphUpdate(nil);#expect(view.historyData()[1].currentValue==24 && view.historyData()[1].orderedValues.dropLast().allSatisfy { $0==XRGGraphRenderer.missingValue })
            miner.reset();#expect(view.historyData()[1].orderedValues.allSatisfy { $0==XRGGraphRenderer.missingValue } && view.currentWatts == 0 && miner.chargePercent()==50 && miner.batteries.count==2)
            option.tag=300;view.selectHistory(option);#expect(view.historyMinutes==0 && miner.numSamples==300)
        }
    }
    private func battery(current: Int = 2000, maximum: Int = 4000, amperage: Int = -1000,
                         minutes: Int = 95, plugged: Bool = false, charging: Bool = false, charged: Bool = false,
                         raw: Bool = true) -> XRGBatteryInfo {
        var dictionary: [String: Any] = ["Voltage": 12000, "Amperage": amperage, "TimeRemaining": minutes,
            "ExternalConnected": plugged, "IsCharging": charging, "FullyCharged": charged]
        if raw { dictionary["AppleRawCurrentCapacity"] = current; dictionary["AppleRawMaxCapacity"] = maximum }
        else { dictionary["CurrentCapacity"] = current; dictionary["MaxCapacity"] = maximum }
        return XRGBatteryInfo(dictionary: dictionary)
    }
    private func withFixture(_ body: (XRGSettings, UserDefaults) throws -> Void) throws {
        _ = NSApplication.shared
        let domain = "XRG.batteryView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showBatteryGraph")
        let settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        settings.graphRefresh = 1
        settings.textTransparency = 1; settings.textColor = .black
        settings.graphBGTransparency = 1; settings.graphBGColor = .white
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        settings.borderTransparency = 1; settings.borderColor = .black
        settings.graphStyle = 0
        try body(settings, defaults)
    }
    private func panel(_ source: BatterySource, _ settings: XRGSettings, _ defaults: UserDefaults,
                       width: CGFloat = 200, height: CGFloat = 100) -> XRGBatteryView {
        XRGBatteryView(frame: NSRect(x: 0, y: 0, width: width, height: height), miner: source.miner(), settings: settings, defaults: defaults)
    }
    private func png(_ view: XRGBatteryView) throws -> Data {
        view.needsDisplay = true
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func registrationVisibilityFontAndDetachment() throws {
        try withFixture { settings, defaults in
            defaults.set(false, forKey: "showBatteryGraph")
            let host = BatteryHost(settings: settings)
            defer { host.close() }
            let source = BatterySource([battery()])
            let view = panel(source, settings, defaults)
            host.contentView?.addSubview(view); view.awakeFromNib(); view.awakeFromNib()
            let module = try #require(view.module)
            #expect(module.name == "Battery" && module.displayOrder == 4)
            #expect(module.doesGraphUpdate && !module.doesFastUpdate && !module.doesMin5Update && !module.doesMin30Update)
            #expect(!module.isDisplayed && module.reference === view && host.batteryView === view)
            #expect(host.moduleManager?.moduleList().count == 1 && host.timerRequests == 1)
            #expect(source.reads == 1 && view.subviews.count == 3)
            let width = module.minWidth
            settings.graphFont = NSFont.systemFont(ofSize: 28); view.updateMinSize()
            #expect(module.minWidth > width)
            view.removeFromSuperview()
            #expect(view.module == nil && host.batteryView == nil && host.moduleManager?.moduleList().isEmpty == true)
        }
    }

    @Test func replacementAndManagerChangesRemoveOnlyTheOwnedModule() throws {
        try withFixture { settings, defaults in
            let host = BatteryHost(settings: settings)
            defer { host.close() }
            let source = BatterySource([battery()])
            let first = panel(source, settings, defaults), second = panel(source, settings, defaults)
            host.contentView?.addSubview(first); first.awakeFromNib()
            host.contentView?.addSubview(second); second.awakeFromNib()
            first.removeFromSuperview()
            #expect(host.batteryView === second && host.moduleManager?.moduleList().first === second.module)
            let oldManager = try #require(host.moduleManager)
            host.moduleManager = XRGModuleManager(window: host)
            second.awakeFromNib()
            #expect(oldManager.moduleList().isEmpty)
            #expect(host.moduleManager?.moduleList().count == 1)
            second.removeFromSuperview()
        }
    }

    @Test func animationTicksDoNotIncreaseTheBatteryPollingCadence() throws {
        try withFixture { settings, defaults in
            let source = BatterySource([battery(plugged: true, charging: true)])
            let view = panel(source, settings, defaults)
            for phase in [1, 2, 3, 0] { view.graphUpdate(nil); #expect(view.chargingPhase == phase) }
            for _ in 0..<6 { view.graphUpdate(nil) }
            #expect(source.reads == 1)
            view.graphUpdate(nil)
            #expect(source.reads == 2)
            settings.graphRefresh = 5
            view.graphUpdate(nil); view.graphUpdate(nil)
            #expect(source.reads == 2)
            view.graphUpdate(nil)
            #expect(source.reads == 3)
        }
    }

    @Test func powerStateChangesRestartTheAnimationOnTheFreshSample() throws {
        try withFixture { settings, defaults in
            let source = BatterySource([battery()])
            let view = panel(source, settings, defaults)
            view.graphUpdate(nil)
            settings.graphRefresh = 11
            source.samples = [battery(amperage: 1000, plugged: true, charging: true)]
            view.graphUpdate(nil)
            #expect(view.batteryMiner.batteryStatus() == .charging && view.chargingPhase == 0)
            view.graphUpdate(nil)
            #expect(view.chargingPhase == 1 && view.currentWatts == 12)
            source.samples = [battery(amperage: 0, plugged: true, charged: true)]
            view.graphUpdate(nil)
            #expect(view.chargingPhase == 0 && view.readings().right.hasPrefix("Charged"))
        }
    }

    @Test func invalidIntervalsAndFailedPollsPreserveTheLastReading() throws {
        try withFixture { settings, defaults in
            let source = BatterySource([battery()])
            let view = panel(source, settings, defaults)
            for interval: CGFloat in [0, -1, .nan, .infinity] {
                settings.graphRefresh = interval; view.graphUpdate(nil)
            }
            #expect(source.reads == 1 && view.currentWatts == -12)
            source.samples = nil; settings.graphRefresh = 11; view.graphUpdate(nil)
            #expect(source.reads == 2 && view.currentWatts == -12)
            #expect(view.readings().left == "50% Charged\n2000mAh\nPower:")
        }
    }

    @Test(arguments: ["unknown", "absent", "running", "charging", "charged", "hold"])
    func statusMessagesAndCapacityUnitsAreRetained(state: String) throws {
        try withFixture { settings, defaults in
            let sample: [XRGBatteryInfo]?
            switch state {
            case "unknown": sample = nil
            case "absent": sample = []
            default: sample = [battery(plugged: state != "running", charging: state == "charging", charged: state == "charged")]
            }
            let view = panel(BatterySource(sample), settings, defaults)
            let reading = view.readings()
            if state == "unknown" || state == "absent" {
                #expect(reading.left == "No Battery Found" && reading.right.isEmpty)
                #expect(view.graphLabels.leftLabel.accessibilityValue() == "No Battery Found")
            } else {
                let status = state == "charged" ? "Charged" : state == "hold" ? "On Hold" : "1:35 Left"
                #expect(reading.right == status + "\n4000mAh\n-12.0W")
                #expect(reading.left == (state == "charged" || state == "hold" ? "50%" : "50% Charged") + "\n2000mAh\nPower:")
                #expect(view.graphLabels.rightLabel.accessibilityValue() == reading.right)
            }
        }
    }

    @Test func narrowMiniAndEstimatedReadingsUseTheExistingAbbreviations() throws {
        try withFixture { settings, defaults in
            let source = BatterySource([battery(minutes: 0)])
            let view = panel(source, settings, defaults, width: 60)
            #expect(view.readings().right == "Est.\n4000mAh\n ")
            #expect(view.readings().center == "\n\n-12.0W")
            view.setFrameSize(NSSize(width: 100, height: 100))
            #expect(view.readings().right.hasPrefix("Estimating"))
            view.setFrameSize(NSSize(width: 200, height: 100))
            #expect(view.readings().right.hasPrefix("Estimating Left"))
            settings.graphRefresh = 11
            source.samples = [battery(plugged: true, charged: true)]; view.graphUpdate(nil)
            view.setFrameSize(NSSize(width: 50, height: 10))
            #expect(view.readings().right == "Chgd.\n4000mAh")
            #expect(view.graphLabels.leftLabel.stringValue == "50%")
            #expect(view.graphLabels.leftLabel.accessibilityValue() == "50%\n2000mAh")
            #expect(view.graphLabels.rightLabel.accessibilityValue() == "Chgd.\n4000mAh")
            source.samples = [battery(plugged: true)]; view.graphUpdate(nil)
            #expect(view.readings().right.hasPrefix("Hold"))
            source.samples = [battery(minutes: 65)]; view.graphUpdate(nil)
            #expect(view.readings().right.hasPrefix("1:05"))
        }
    }

    @Test func normalizedCapacitiesDoNotInventMilliampHoursAndWideCountersStayIntSized() throws {
        try withFixture { settings, defaults in
            settings.graphRefresh = 11
            let source = BatterySource([battery(current: 50, maximum: 100, raw: false)])
            let view = panel(source, settings, defaults)
            #expect(view.readings().left == "50% Charged\nn/a\nPower:")
            #expect(view.readings().right.contains("\nn/a\n"))
            source.samples = [battery(current: 5_000_000_000, maximum: 10_000_000_000)]
            view.graphUpdate(nil)
            #expect(view.readings().left.contains("5000000000mAh"))
            #expect(view.readings().right.contains("10000000000mAh"))
        }
    }

    @Test func barGeometryPreservesHeaderPowerDirectionAndSharedWattScale() throws {
        try withFixture { settings, defaults in
            let view = panel(BatterySource([battery()]), settings, defaults)
            let h = XRGGraphLabels.lineHeight(settings)
            let rect = NSRect(x: 10, y: 20, width: 200, height: 100)
            let bars = view.bars(in: rect, mini: false)
            #expect(bars.charge == NSRect(x: 10, y: 120 - h * 2, width: 100, height: h * 2))
            #expect(bars.power == NSRect(x: 70, y: 120 - h * 3, width: 40, height: h))
            #expect(bars.charging.isEmpty)
            #expect(bars.history == NSRect(x: 10, y: 20, width: 200, height: 99 - h * 3))
            #expect(bars.borders.count == 3 && view.wattScale == 30)
            view.batteryMiner.chargeWatts.setAllValues(60)
            view.batteryMiner.dischargeWatts.setAllValues(0)
            #expect(view.wattScale == 60 && view.currentWatts == 60)
            #expect(view.bars(in: rect, mini: false).power == NSRect(x: 110, y: 120 - h * 3, width: 100, height: h))
            let mini = view.bars(in: rect, mini: true)
            #expect(mini.charge == NSRect(x: 10, y: 20, width: 100, height: 100))
            #expect(mini.history.isEmpty && mini.power.isEmpty && mini.borders.isEmpty)
        }
    }

    @Test func chargingBarCyclesThroughTheRemainingCapacity() throws {
        try withFixture { settings, defaults in
            let view = panel(BatterySource([battery(plugged: true, charging: true)]), settings, defaults, height: 10)
            #expect(view.bars(in: view.bounds, mini: true).charging.isEmpty)
            for phase in 1...3 {
                view.graphUpdate(nil)
                let bar = view.bars(in: view.bounds, mini: true).charging
                #expect(bar.minX == 100 && abs(bar.width - 100 * CGFloat(phase) / 3) < 0.0001)
            }
            view.graphUpdate(nil)
            #expect(view.bars(in: view.bounds, mini: true).charging.isEmpty)
        }
    }

    @Test(arguments: [CGFloat(0), 1, 10, 26, 40, 100])
    func collapsedAndSmallLayoutsHaveBoundedBarsAndAccessibleReadings(height: CGFloat) throws {
        try withFixture { settings, defaults in
            let view = panel(BatterySource([battery(plugged: true, charging: true)]), settings, defaults, width: 4, height: height)
            view.graphUpdate(nil)
            let bars = view.bars(in: view.bounds, mini: view.shouldDrawMiniGraph())
            for rect in [bars.charge, bars.charging, bars.power, bars.history] + bars.borders {
                #expect(rect.size.width >= 0 && rect.size.height >= 0)
                #expect(rect.isEmpty || view.bounds.contains(rect))
            }
            #expect(view.graphLabels.leftLabel.accessibilityValue()?.hasPrefix("50%") == true)
            for label in view.subviews { #expect(label.frame.size.width >= 0 && label.frame.size.height >= 0) }
        }
    }

    @Test(arguments: [CGFloat(10), 18, 28], [CGFloat(60), 100, 200])
    func capacityColumnsStaySeparateAcrossFontsAndWidths(fontSize: CGFloat, width: CGFloat) throws {
        try withFixture { settings, defaults in
            settings.graphFont = NSFont.systemFont(ofSize: fontSize)
            let view = panel(BatterySource([battery()]), settings, defaults, width: width, height: 200)
            #expect(view.graphLabels.leftLabel.frame.maxX <= view.graphLabels.rightLabel.frame.minX)
            #expect(view.graphLabels.leftLabel.accessibilityValue()?.contains("2000mAh") == true)
            #expect(view.graphLabels.rightLabel.accessibilityValue()?.contains("4000mAh") == true)
            if let center = view.readings().center {
                #expect(view.graphLabels.centerLabel.accessibilityValue() == center)
            }
        }
    }

    @Test func historyBoundsAndResetKeepTheCurrentBatterySnapshot() throws {
        try withFixture { settings, defaults in
            let view = panel(BatterySource([battery()]), settings, defaults)
            #expect(view.batteryMiner.numSamples == 200 && view.batteryMiner.dischargeWatts.max == 12)
            view.setGraphSize(NSSize(width: CGFloat.greatestFiniteMagnitude, height: 0))
            #expect(view.batteryMiner.numSamples == 20_000)
            view.setWidth(-1); #expect(view.batteryMiner.numSamples == 20_000)
            view.setGraphSize(NSSize(width: CGFloat.nan, height: 0))
            #expect(view.batteryMiner.numSamples == 1)
            view.batteryMiner.reset()
            #expect(view.batteryMiner.dischargeWatts.max == 0 && view.batteryMiner.chargePercent() == 50)
        }
    }

    @Test func settingsMenuHasAnExplicitTargetAndInjectableOpener() throws {
        try withFixture { settings, defaults in
            var opened: [URL] = []
            let view = XRGBatteryView(frame: NSRect(x: 0, y: 0, width: 200, height: 100),
                miner: BatterySource([battery()]).miner(), settings: settings, defaults: defaults,
                openURL: { opened.append($0); return true })
            let item = try #require(view.makeMenu().items.first)
            #expect(item.title == "Open Battery Settings..." && item.target === view)
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            #expect(opened == [XRGBatteryView.batterySettingsURL])
        }
    }

    @Test(arguments: ["BatteryView", "LegacyBattery"])
    func currentAndLegacyNibArchivesInstantiateTheSwiftPanel(name: String) throws {
        try withFixture { _, _ in
            let nib = try #require(NSNib(nibNamed: NSNib.Name(name), bundle: Bundle(for: BatteryNibOwner.self)))
            var objects: NSArray?
            #expect(nib.instantiate(withOwner: BatteryNibOwner(), topLevelObjects: &objects))
            let view = try #require(objects?.compactMap { $0 as? XRGBatteryView }.first)
            #expect(view.subviews.count == 3 && view.module == nil)
            #expect(view.frame.size == NSSize(width: 76, height: 76))
            withExtendedLifetime(objects) {}
        }
    }

    @Test func emptyStateWrapsAndRecoveryClearsTheOldMessage() throws {
        try withFixture { settings, defaults in
            settings.graphRefresh = 11
            let source = BatterySource([battery()])
            let view = panel(source, settings, defaults, width: 65, height: 50)
            source.samples = []; view.graphUpdate(nil)
            #expect(view.graphLabels.leftLabel.stringValue == "No Battery Found")
            #expect(view.graphLabels.leftLabel.lineBreakMode == .byWordWrapping)
            #expect(view.graphLabels.rightLabel.stringValue.isEmpty && view.graphLabels.centerLabel.stringValue.isEmpty)
            let empty = try png(view)
            source.samples = [battery()]; view.graphUpdate(nil)
            #expect(try png(view) != empty)
            #expect(view.graphLabels.leftLabel.accessibilityValue()?.hasPrefix("50%") == true)
            #expect(view.graphLabels.rightLabel.accessibilityValue()?.contains("4000mAh") == true)
            #expect(view.graphLabels.leftLabel.lineBreakMode == .byTruncatingTail)
        }
    }

    @Test func chargingPowerHistoryAndEmptyStateRenderToNativeBitmaps() throws {
        try withFixture { settings, defaults in
            settings.graphRefresh = 11
            let source = BatterySource([battery(plugged: true, charging: true)])
            let view = panel(source, settings, defaults)
            let initial = try png(view)
            view.graphUpdate(nil)
            #expect(try png(view) != initial)
            source.samples = [battery()]; view.graphUpdate(nil)
            #expect(try png(view) != initial)
            let power = try png(view)
            view.batteryMiner.dischargeWatts.setAllValues(30)
            #expect(try png(view) != power)
            source.samples = []; view.graphUpdate(nil)
            #expect(try png(view) != power)
            #expect(view.graphLabels.leftLabel.accessibilityValue() == "No Battery Found")
        }
    }

    @Test func mouseEventsStillReachTheWindow() throws {
        try withFixture { settings, defaults in
            let host = BatteryHost(settings: settings)
            defer { host.close() }
            let view = panel(BatterySource([battery()]), settings, defaults)
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
