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

@MainActor private final class CPUHost: NSWindow, XRGCPUViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var cpuView: XRGCPUView?
    var minimized = false
    var borderWidth: Int32 = 2
    var timerRequests = 0
    var preferencesOpened = 0
    var mouseEvents: [String] = []
    init(settings: XRGSettings) {
        appSettings = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        moduleManager = XRGModuleManager(window: self)
    }
    func initTimers() { timerRequests += 1 }
    func checkWindowSize() {}
    func showCPUPreferences() { preferencesOpened += 1 }
    override func mouseDown(with event: NSEvent) { mouseEvents.append("down") }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}
private final class CPUNibOwner: NSObject {}
@MainActor private final class CPUSource {
    var samples: [XRGCPUTicks]? = Array(repeating: XRGCPUTicks(user: 0, system: 0, idle: 0, nice: 0), count: 2)
    var reads = 0
    func miner() -> XRGCPUMiner { XRGCPUMiner(source: { self.reads += 1; return self.samples }) }
    func advance() {
        samples = [XRGCPUTicks(user: 40, system: 20, idle: 30, nice: 10),
                   XRGCPUTicks(user: 20, system: 10, idle: 70, nice: 0)]
    }
}

@Suite(.serialized) @MainActor
struct XRGCPUViewTests {
    @Test func explicitHistoryRetainsNewestSamplesAndBaselinesAcrossResizingAndRelaunch() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            view.setGraphSize(view.bounds.size)
            source.advance(); miner.graphUpdate(nil)
            let value = miner.currentUsage(forCPU: 0), reads = source.reads
            let option = NSMenuItem(); option.tag = 300
            view.selectHistory(option)
            #expect(miner.userValues[0].numValues == 300 && miner.currentUsage(forCPU: 0) == value && source.reads == reads)
            #expect(miner.userValues[0].currentValue == 40)
            #expect(miner.userValues[0].orderedValues.prefix(100).allSatisfy { $0 == XRGGraphRenderer.missingValue })
            view.setFrameSize(NSSize(width: 80, height: 90))
            #expect(miner.userValues[0].numValues == 300 && source.reads == reads)
            let restored = panel(miner, settings, defaults); restored.setGraphSize(restored.bounds.size)
            #expect(restored.retainedSamples == 300 && miner.userValues[0].numValues == 300)
            option.tag = 20_001; restored.selectHistory(option)
            #expect(defaults.integer(forKey: XRGCPUView.historyKey) == 300)
            option.tag = 1; restored.selectHistory(option)
            source.samples = [XRGCPUTicks(user: 80, system: 40, idle: 60, nice: 20),
                              XRGCPUTicks(user: 40, system: 20, idle: 140, nice: 0)]
            miner.graphUpdate(nil)
            #expect(miner.userValues[0].numValues == 1 && miner.currentUsage(forCPU: 0) == value)
            option.tag = 0; restored.selectHistory(option)
            #expect(restored.retainedSamples == 0 && miner.userValues[0].numValues == 200)
            #expect(restored.detailText.contains("Nominal span") && restored.detailText.contains("actual span"))
        }
    }
    @Test func cpuTimeWindowsKeepGapsRateBaselinesAndIndependentViewScopes() async throws {
        try await withFixture { settings, defaults, source in
            settings.graphRefresh = 1
            var time = 0.0, wall = 100.0
            let miner = XRGCPUMiner(source: { source.reads += 1; return source.samples }, clock: { time }, historyClock: { wall })
            let aggregate = panel(miner, settings, defaults)
            let option = NSMenuItem(); option.tag = 1
            weak var released: XRGCPUView?
            try autoreleasepool {
            let pinned = panel(miner, settings, defaults); released = pinned
            try pinned.applyCPUSource(1)
            aggregate.selectHistoryWindow(option); pinned.selectHistoryWindow(option)
            source.advance(); time = 1; miner.graphUpdate(nil)
            wall = 110; time = 2
            source.samples = [XRGCPUTicks(user:80,system:40,idle:60,nice:20),XRGCPUTicks(user:40,system:20,idle:140,nice:0)]
            miner.graphUpdate(nil)
            let reads = source.reads, current = miner.currentUsage(forCPU:0)
            #expect(aggregate.historyLayers()[0].numValues == 61 && aggregate.historyLayers()[0].currentValue == 50)
            #expect(pinned.historyLayers()[0].currentValue == 30)
            #expect(aggregate.historyLayers()[0].orderedValues[51..<60].allSatisfy { $0 == XRGGraphRenderer.missingValue })
            settings.graphRefresh = 0.2
            #expect(aggregate.historyLayers()[0].numValues == 301 && source.reads == reads && miner.currentUsage(forCPU:0) == current)
            aggregate.setFrameSize(NSSize(width:60,height:90)); #expect(aggregate.historyLayers()[0].numValues == 301)
            try aggregate.applyCPUSource(0)
            #expect(aggregate.historyLayers()[0].orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue })
            #expect(pinned.historyLayers()[0].currentValue == 30 && source.reads == reads)
            option.tag = 61; aggregate.selectHistoryWindow(option); #expect(aggregate.historyMinutes == 1)
            let choices = try #require(aggregate.makeMenu().items.first { $0.title == "CPU Time Window" }?.submenu)
            #expect(choices.items.allSatisfy { $0.target === aggregate })
            }
            #expect(released == nil)
            wall = 120; time = 3; source.samples = nil; miner.graphUpdate(nil)
            #expect(aggregate.historyLayers()[0].currentValue == XRGGraphRenderer.missingValue)
            aggregate.clearData(nil)
            #expect(aggregate.historyLayers()[0].orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue })
            option.tag = 300; aggregate.selectHistory(option)
            #expect(aggregate.historyMinutes == 0 && aggregate.retainedSamples == 300)
        }
    }
    @Test func cpuTimestampWindowsRestoreAndWallClockRollbackLeavesRateTimingIntact() async throws {
        try await withFixture { settings, defaults, source in
            settings.graphRefresh = 1
            var time = 0.0, wall = 100.0
            defaults.set(1, forKey:XRGCPUView.windowKey)
            let miner = XRGCPUMiner(source: { source.reads += 1; return source.samples }, clock:{time},historyClock:{wall})
            let view = panel(miner,settings,defaults)
            source.advance();time=1;miner.graphUpdate(nil)
            let reads=source.reads
            let restored=panel(miner,settings,defaults)
            #expect(restored.historyMinutes==1 && source.reads==reads)
            // A newly registered view never invents timestamps for older index-only samples.
            #expect(restored.historyLayers()[0].orderedValues.allSatisfy{$0==XRGGraphRenderer.missingValue})
            wall=50;time=2;source.samples=[XRGCPUTicks(user:80,system:40,idle:60,nice:20),XRGCPUTicks(user:40,system:20,idle:140,nice:0)]
            miner.graphUpdate(nil)
            #expect(view.historyLayers()[0].currentValue==50 && miner.currentUsage(forCPU:0)==70)
            #expect(view.historyLayers()[0].orderedValues.dropLast().allSatisfy{$0==XRGGraphRenderer.missingValue})
        }
    }
    private func withFixture(_ body: (XRGSettings, UserDefaults, CPUSource) async throws -> Void) async throws {
        _ = NSApplication.shared
        let domain = "XRG.cpuView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showCPUGraph")
        let settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        settings.textTransparency = 1; settings.textColor = .black
        settings.graphBGTransparency = 1; settings.graphBGColor = .white
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        settings.graphFG3Transparency = 1; settings.graphFG3Color = .green
        settings.fastCPUUsage = false; settings.separateCPUColor = true
        settings.showLoadAverage = false; settings.cpuShowUptime = false; settings.cpuShowAverageUsage = false
        settings.graphStyle = 0
        try await body(settings, defaults, CPUSource())
    }
    private func panel(_ miner: XRGCPUMiner, _ settings: XRGSettings, _ defaults: UserDefaults,
                       processMiner: XRGProcessMiner? = nil, width: CGFloat = 200, height: CGFloat = 100) -> XRGCPUView {
        XRGCPUView(frame: NSRect(x: 0, y: 0, width: width, height: height), miner: miner,
                   processMiner: processMiner ?? XRGProcessMiner(source: { [] }), settings: settings, defaults: defaults)
    }
    private func seed(_ miner: XRGCPUMiner, _ source: CPUSource) {
        miner.loadAverage = false
        source.advance(); miner.graphUpdate(nil)
        miner.systemValues[0].setAllValues(20); miner.userValues[0].setAllValues(40); miner.niceValues[0].setAllValues(10)
        miner.systemValues[1].setAllValues(10); miner.userValues[1].setAllValues(20); miner.niceValues[1].setAllValues(0)
    }
    private func png(_ view: XRGCPUView) throws -> Data {
        view.needsDisplay = true
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func hiddenCoreGraphKeepsNormalHistoryWithoutFastPollingAndDetachesCleanly() async throws {
        try await withFixture { settings, defaults, source in
            defaults.set(false, forKey: "showCPUGraph"); settings.fastCPUUsage = true
            var time = 0.0
            let miner = XRGCPUMiner(source: { source.reads += 1; return source.samples }, clock: { time }, historyClock: { 100 + time })
            let view = panel(miner, settings, defaults), host = CPUHost(settings: settings)
            defer { view.removeFromSuperview(); host.close() }
            host.contentView?.addSubview(view); view.awakeFromNib()
            let manager = try #require(host.moduleManager), module = try #require(view.module)
            #expect(!module.isDisplayed && manager.displayList().isEmpty)
            let before = source.reads
            time = 1; source.advance(); manager.graphUpdate(); manager.fastUpdate()
            #expect(source.reads == before + 1 && miner.currentUsage(forCPU: 0) == 70)
            time = 2; source.samples = source.samples?.map { XRGCPUTicks(user: $0.user * 2, system: $0.system * 2, idle: $0.idle * 2, nice: $0.nice * 2) }
            manager.graphUpdate(); manager.fastUpdate()
            #expect(source.reads == before + 2 && miner.userValues[0].orderedValues.suffix(2).allSatisfy { $0 == 40 })
            view.removeFromSuperview(); time = 3; manager.graphUpdate(); manager.fastUpdate()
            #expect(source.reads == before + 2 && manager.moduleList().isEmpty)
        }
    }

    @Test func registrationVisibilityFontAndDetachment() async throws {
        try await withFixture { settings, defaults, source in
            defaults.set(false, forKey: "showCPUGraph")
            let host = CPUHost(settings: settings)
            defer { host.close() }
            let view = panel(source.miner(), settings, defaults)
            host.contentView?.addSubview(view); view.awakeFromNib(); view.awakeFromNib()
            let module = try #require(view.module)
            #expect(module.name == "CPU" && module.displayOrder == 0)
            #expect(module.doesGraphUpdate && module.doesFastUpdate && !module.doesMin5Update && !module.doesMin30Update)
            #expect(!module.isDisplayed && module.reference === view && host.cpuView === view)
            #expect(host.moduleManager?.moduleList().count == 1 && host.timerRequests == 1 && view.subviews.count == 3)
            let width = module.minWidth
            settings.graphFont = NSFont.systemFont(ofSize: 28); view.updateMinSize()
            #expect(module.minWidth > width)
            view.removeFromSuperview()
            #expect(view.module == nil && host.cpuView == nil && host.moduleManager?.moduleList().isEmpty == true)
        }
    }

    @Test func replacementAndManagerChangesRemoveOnlyTheOwnedModule() async throws {
        try await withFixture { settings, defaults, source in
            let host = CPUHost(settings: settings)
            defer { host.close() }
            let first = panel(source.miner(), settings, defaults), second = panel(source.miner(), settings, defaults)
            host.contentView?.addSubview(first); first.awakeFromNib()
            host.contentView?.addSubview(second); second.awakeFromNib()
            first.removeFromSuperview()
            #expect(host.cpuView === second && host.moduleManager?.moduleList().first === second.module)
            let oldManager = try #require(host.moduleManager)
            host.moduleManager = XRGModuleManager(window: host); second.awakeFromNib()
            #expect(oldManager.moduleList().isEmpty && host.moduleManager?.moduleList().count == 1)
            second.removeFromSuperview()
        }
    }

    @Test func graphAndFastUpdatesUseIndependentSamplesAndPreferenceFlags() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults, width: 10)
            source.advance()
            let reads = source.reads
            view.fastUpdate(nil)
            #expect(source.reads == reads)
            settings.fastCPUUsage = true; view.fastUpdate(nil)
            #expect(miner.fastValues.map(\.intValue) == [17, 7])
            #expect(miner.userValues[0].currentValue == XRGGraphRenderer.missingValue)
            view.graphUpdate(nil)
            #expect(miner.userValues.map(\.currentValue) == [40, 20])
            #expect(miner.systemValues.map(\.currentValue) == [20, 10])
            #expect(view.totalUsage == 100 && view.sortedCoreUsage() == [17, 7])
            #expect(!miner.loadAverage && miner.uptime)
            settings.showLoadAverage = true; view.graphUpdate(nil)
            #expect(miner.loadAverage)
        }
    }

    @Test func historyLayersRetainSystemUserNiceStackWithoutMutatingSamples() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            seed(miner, source)
            let before = (miner.systemValues + miner.userValues + miner.niceValues).map(\.orderedValues)
            #expect(view.historyLayers().map(\.currentValue) == [50, 45, 15])
            #expect(view.totalUsage == 100 && view.averageUsage == 50)
            settings.separateCPUColor = false
            #expect(view.historyLayers().map(\.currentValue) == [50])
            #expect((miner.systemValues + miner.userValues + miner.niceValues).map(\.orderedValues) == before)
        }
    }

    @Test func textFlagsKeepTotalUsagePerCoreAverageLoadAndUptimeUnits() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults, width: 300)
            seed(miner, source)
            settings.cpuShowAverageUsage = true; settings.showLoadAverage = true; settings.cpuShowUptime = true
            view.updateMinSize()
            #expect(view.readings().left == "CPU\nAverage:\nLoad:\nUptime:")
            #expect(view.readings().right == "100%\n50.0%\n0.00\n0d 0:00")
            #expect(view.graphLabels.rightLabel.accessibilityValue() == view.readings().right)
            view.setFrameSize(NSSize(width: 60, height: 100))
            #expect(view.readings().left == "CPU\nAvg:\nLoad:\nU:")
            settings.cpuShowAverageUsage = false; settings.showLoadAverage = false; settings.cpuShowUptime = false
            view.updateMinSize()
            #expect(view.readings().left == "CPU" && view.readings().right == "100%")
        }
    }

    @Test func uptimeAndLoadFormattingHandlePaddingAndUnavailableValues() {
        #expect(XRGCPUView.uptimeText(days: 12, hours: 3, minutes: 5) == "12d 3:05")
        #expect(XRGCPUView.uptimeText(days: 0, hours: 23, minutes: 59) == "0d 23:59")
        #expect(XRGCPUView.loadText(1.25) == "1.25")
        for value: CGFloat in [-1, .nan, .infinity] { #expect(XRGCPUView.loadText(value) == "n/a") }
    }

    @Test func compactModeUsesSlowSamplesWhenFastUsageIsDisabled() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults, height: 10)
            source.advance(); view.graphUpdate(nil)
            #expect(view.sortedCoreUsage() == [70, 30])
            #expect(view.graphLabels.leftLabel.stringValue == "CPU" && view.graphLabels.rightLabel.stringValue == "100%")
            settings.cpuShowAverageUsage = true; view.updateMinSize()
            #expect(view.graphLabels.rightLabel.accessibilityValue()?.contains("\n") == true)
            #expect(view.graphLabels.rightLabel.stringValue == "100%")
            settings.fastCPUUsage = true; view.fastUpdate(nil)
            #expect(view.sortedCoreUsage() == [17, 7])
            settings.fastCPUUsage = false; view.updateMinSize()
            #expect(view.sortedCoreUsage() == [70, 30])
        }
    }

    @Test func fastBarsKeepDescendingOrderAndTheHistoricalSplitGeometry() async throws {
        try await withFixture { settings, defaults, source in
            settings.fastCPUUsage = true
            let miner = source.miner(), view = panel(miner, settings, defaults)
            source.advance(); view.fastUpdate(nil)
            let rect = NSRect(x: 10, y: 20, width: 200, height: 100)
            #expect(view.historyRect(in: rect) == NSRect(x: 10, y: 70, width: 200, height: 49))
            let bars = view.fastBarRects(in: rect)
            #expect(bars.count == 2 && bars[0].origin == NSPoint(x: 10, y: 20) && bars[1].origin == NSPoint(x: 110, y: 20))
            #expect(bars.allSatisfy { $0.width == 99 })
            #expect(abs(bars[0].height - 8.33) < 0.0001 && abs(bars[1].height - 3.43) < 0.0001)
            settings.fastCPUUsage = false
            #expect(view.historyRect(in: rect) == rect && view.fastBarRects(in: rect).isEmpty)
        }
    }

    @Test(arguments: [1, 2, 8, 128])
    func manyCoreCountsAndSmallFramesDoNotProduceNegativeBars(count: Int) async throws {
        try await withFixture { settings, defaults, source in
            settings.fastCPUUsage = true
            source.samples = Array(repeating: XRGCPUTicks(user: 0, system: 0, idle: 0, nice: 0), count: count)
            let miner = source.miner(), view = panel(miner, settings, defaults, width: 4, height: 3)
            source.samples = Array(repeating: XRGCPUTicks(user: 100, system: 0, idle: 0, nice: 0), count: count)
            view.fastUpdate(nil); view.graphUpdate(nil)
            #expect(view.totalUsage == CGFloat(count) * 100)
            #expect(view.sortedCoreUsage().count == count)
            for rect in view.fastBarRects(in: view.bounds) {
                #expect(rect.size.width >= 0 && rect.size.height >= 0)
                #expect(rect.isEmpty || view.bounds.contains(rect))
            }
            view.setFrameSize(.zero)
            #expect(view.fastBarRects(in: view.bounds).isEmpty && view.historyRect(in: view.bounds).isEmpty)
        }
    }

    @Test(arguments: [CGFloat(10), 18, 28], [CGFloat(60), 100, 200])
    func textColumnsStaySeparateAndKeepCompleteAccessibleReadings(font: CGFloat, width: CGFloat) async throws {
        try await withFixture { settings, defaults, source in
            settings.graphFont = NSFont.systemFont(ofSize: font)
            settings.cpuShowAverageUsage = true; settings.showLoadAverage = true; settings.cpuShowUptime = true
            let miner = source.miner(), view = panel(miner, settings, defaults, width: width, height: 30)
            seed(miner, source); view.updateMinSize()
            #expect(view.graphLabels.leftLabel.frame.maxX <= view.graphLabels.rightLabel.frame.minX)
            #expect(view.graphLabels.leftLabel.accessibilityValue() == view.readings().left)
            #expect(view.graphLabels.rightLabel.accessibilityValue() == view.readings().right)
            for label in view.subviews { #expect(label.frame.size.width >= 0 && label.frame.size.height >= 0) }
        }
    }

    @Test func historyBoundsResetFailuresAndCoreCountChangesStaySafe() async throws {
        try await withFixture { settings, defaults, source in
            settings.fastCPUUsage = true
            let miner = source.miner(), view = panel(miner, settings, defaults)
            #expect(miner.userValues[0].numValues == 193)
            source.advance(); view.fastUpdate(nil); view.graphUpdate(nil)
            source.samples = nil; view.graphUpdate(nil)
            #expect(!view.sourceAvailable)
            let reads = source.reads
            view.clearData(nil)
            #expect(source.reads == reads && !view.sourceAvailable && view.sortedCoreUsage() == [17, 7])
            #expect(view.historyLayers().allSatisfy { $0.orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue } })
            view.setGraphSize(NSSize(width: CGFloat.greatestFiniteMagnitude, height: 0))
            #expect(miner.userValues[0].numValues == 19_993)
            view.setWidth(6); #expect(miner.userValues[0].numValues == 19_993)
            view.setWidth(-1); #expect(miner.userValues[0].numValues == 19_993)
            view.setGraphSize(NSSize(width: CGFloat.nan, height: 0))
            #expect(miner.userValues[0].numValues == 1)
            source.samples = [XRGCPUTicks(user: 10, system: 20, idle: 30, nice: 0)]
            view.graphUpdate(nil)
            #expect(miner.numberOfCPUs == 1 && view.totalUsage == 0 && view.historyLayers().count == 3)
        }
    }

    @Test func logicalCPUSelectionUsesCachedPerCoreDataAndPersistsIndependently() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            seed(miner, source)
            let before = miner.userValues.map(\.orderedValues), reads = source.reads
            defaults.set("GPU sentinel", forKey: XRGGPUView.sourceKey)
            try view.applyCPUSource(1)
            #expect(view.totalUsage == 30 && view.averageUsage == 30 && view.sortedCoreUsage() == [30])
            #expect(view.historyLayers().map(\.currentValue) == [30, 30, 10])
            #expect(view.readings().left == "CPU 1" && view.readings().right == "30%")
            #expect(source.reads == reads && miner.userValues.map(\.orderedValues) == before)
            #expect(defaults.string(forKey: XRGGPUView.sourceKey) == "GPU sentinel")
            let restored = panel(miner, settings, defaults)
            #expect(restored.selectedCPU == 1 && restored.totalUsage == 30)
            let submenu = try #require(view.makeMenu().items.first { $0.title == "CPU Source" }?.submenu)
            let selected = try #require(submenu.items.first { $0.tag == 1 })
            #expect(selected.state == .on && selected.target === view)
            let all = try #require(submenu.items.first { $0.tag == -1 })
            #expect(NSApp.sendAction(try #require(all.action), to: all.target, from: all))
            #expect(view.selectedCPU == nil && view.totalUsage == 100 && source.reads == reads)
        }
    }

    @Test func missingLogicalCPURemainsPinnedWithoutSubstitution() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            try view.applyCPUSource(1)
            source.samples = [XRGCPUTicks(user: 40, system: 20, idle: 30, nice: 10)]
            view.graphUpdate(nil)
            #expect(view.selectedCPU == 1 && !view.sourceAvailable)
            #expect(view.readings().right == "n/a" && view.historyLayers().isEmpty && view.sortedCoreUsage().isEmpty)
            #expect(view.detailText.contains("system-wide") && view.detailText.contains("unavailable"))
            let missing = view.makeMenu().items.first { $0.title == "CPU Source" }?.submenu?.items.last
            #expect(missing?.title == "Logical CPU 1 (unavailable)" && missing?.state == .on)
            source.samples = Array(repeating: XRGCPUTicks(user: 50, system: 20, idle: 30, nice: 10), count: 2)
            view.graphUpdate(nil)
            #expect(view.selectedCPU == 1 && !view.sourceAvailable)
            source.samples = Array(repeating: XRGCPUTicks(user: 60, system: 30, idle: 40, nice: 10), count: 2)
            view.graphUpdate(nil)
            #expect(view.selectedCPU == 1 && view.sourceAvailable)
        }
    }

    @Test func invalidCPUSourceBytesSurviveUntilExplicitReplacement() async throws {
        try await withFixture { settings, defaults, source in
            let invalid = Data("{\"version\":1,\"source\":\"-1\"}".utf8)
            defaults.set(invalid, forKey: XRGCPUView.sourceKey)
            let view = panel(source.miner(), settings, defaults)
            #expect(view.selectedCPU == nil && view.detailText.contains("invalid"))
            #expect(defaults.data(forKey: XRGCPUView.sourceKey) == invalid)
            #expect(throws: (any Error).self) { try view.applyCPUSource(1_048_576) }
            #expect(defaults.data(forKey: XRGCPUView.sourceKey) == invalid)
            try view.applyCPUSource(nil)
            #expect(try XRGMonitorSource.load(defaults, key: XRGCPUView.sourceKey).source == nil)
            #expect(!view.detailText.contains("Saved source options are invalid"))
        }
    }

    @Test func CPUReadFailuresAreExplicitWithoutDiscardingHistory() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            source.advance(); view.graphUpdate(nil)
            let history = miner.userValues.map(\.orderedValues)
            source.samples = nil; view.graphUpdate(nil)
            #expect(view.readings().right == "n/a" && view.sortedCoreUsage().isEmpty)
            #expect(zip(miner.userValues, history).allSatisfy { data, old in
                Array(data.orderedValues.dropLast()) == Array(old.dropFirst()) && data.currentValue == XRGGraphRenderer.missingValue
            })
            #expect(view.toolTip?.contains("unavailable") == true)
        }
    }

    @Test func averageUsesLatestIntervalInsteadOfRetainedHistoryOrPadding() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            source.advance(); view.graphUpdate(nil)
            settings.cpuShowAverageUsage = true; view.updateMinSize()
            #expect(view.totalUsage == 100 && view.averageUsage == 50)
            // Change the next interval to 100% / 50%, with a different history.
            source.samples = [XRGCPUTicks(user: 140, system: 20, idle: 30, nice: 10),
                              XRGCPUTicks(user: 70, system: 10, idle: 120, nice: 0)]
            view.graphUpdate(nil)
            #expect(view.totalUsage == 150 && view.averageUsage == 75)
            for width: CGFloat in [1, 500, 20_000] {
                view.setFrameSize(NSSize(width: width, height: 100))
                #expect(view.totalUsage == 150 && view.averageUsage == 75)
            }
            try view.applyCPUSource(0)
            #expect(view.totalUsage == 100 && view.averageUsage == 100)
            try view.applyCPUSource(1)
            #expect(view.totalUsage == 50 && view.averageUsage == 50 && view.sourceAvailable)
            source.samples = [XRGCPUTicks(user: 140, system: 20, idle: 130, nice: 10),
                              XRGCPUTicks(user: 70, system: 10, idle: 220, nice: 0)]
            view.graphUpdate(nil)
            #expect(view.totalUsage == 0 && view.averageUsage == 0 && view.sourceAvailable)
            #expect(view.readings().right == "0%\n0.0%")
        }
    }

    @Test func graphResetPreservesLiveReadoutsAndBarsAndLeavesActualHistoryGaps() async throws {
        try await withFixture { settings, defaults, source in
            settings.fastCPUUsage = true; settings.cpuShowAverageUsage = true
            let miner = source.miner(), view = panel(miner, settings, defaults)
            source.advance(); view.graphUpdate(nil); view.fastUpdate(nil)
            let reads = source.reads, bars = view.sortedCoreUsage(), text = view.readings().right
            try view.applyCPUSource(1)
            let selectedText = view.readings().right
            view.clearData(nil)
            #expect(source.reads == reads && view.readings().right == selectedText && view.selectedCPU == 1)
            #expect(view.totalUsage == 30 && view.averageUsage == 30 && view.sortedCoreUsage() == [7])
            #expect(view.historyLayers().allSatisfy { $0.orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue } })
            try view.applyCPUSource(nil)
            #expect(view.readings().right == text && view.sortedCoreUsage() == bars && source.reads == reads)
            source.samples = [XRGCPUTicks(user: 80, system: 40, idle: 60, nice: 20),
                              XRGCPUTicks(user: 40, system: 20, idle: 140, nice: 0)]
            view.graphUpdate(nil)
            for layer in view.historyLayers() {
                #expect(layer.orderedValues.dropLast().allSatisfy { $0 == XRGGraphRenderer.missingValue })
                #expect(layer.currentValue >= 0)
            }
            #expect(view.totalUsage == 100 && view.averageUsage == 50)
        }
    }

    @Test func incompleteCoreIntervalsCannotMasqueradeAsAnIdleOrCompleteAggregate() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            #expect(!view.sourceAvailable && view.readings().right == "n/a")
            source.samples = [XRGCPUTicks(user: 50, system: 0, idle: 50, nice: 0),
                              XRGCPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
            view.graphUpdate(nil)
            #expect(!view.sourceAvailable && view.readings().right == "n/a")
            #expect(view.historyLayers().allSatisfy { $0.currentValue == XRGGraphRenderer.missingValue })
            try view.applyCPUSource(0)
            #expect(view.sourceAvailable && view.totalUsage == 50 && view.historyLayers()[0].currentValue == 50)
            try view.applyCPUSource(1)
            #expect(!view.sourceAvailable && view.historyLayers().allSatisfy { $0.currentValue == XRGGraphRenderer.missingValue })
        }
    }

    @Test func processMenuKeepsTopTenWideValuesAndExplicitActionTargets() async throws {
        try await withFixture { settings, defaults, source in
            let records = (1...12).map { index in
                XRGProcessRecord(cpu: Double(index) * 100, pid: 5_000_000_000 + index, resident: 0, virtual: 0, swaps: 0, user: "fixture", command: "Process\(index)")
            }
            let processes = XRGProcessMiner(source: { records }); await processes.refresh()
            let miner = source.miner()
            var opened: [URL] = []
            let view = XRGCPUView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), miner: miner,
                processMiner: processes, settings: settings, defaults: defaults, openURL: { opened.append($0); return true })
            let host = CPUHost(settings: settings)
            defer { host.close() }
            host.contentView?.addSubview(view); view.awakeFromNib()
            seed(miner, source)
            let menu = view.makeMenu()
            #expect(menu.items.count == 22)
            #expect(menu.items[1].title == "1200.0% - Process12 (id 5000000012)")
            #expect(menu.items[10].title.contains("Process3"))
            for item in menu.items where !item.isSeparatorItem { #expect(item.target === view) }
            for title in ["Processes…", "Reset Graph", "Open Activity Monitor...", "Open XRG-ng CPU Preferences..."] {
                let item = try #require(menu.items.first { $0.title == title })
                #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            }
            #expect(view.totalUsage == 100 && opened == [XRGCPUView.activityMonitorURL] && host.preferencesOpened == 1)
            #expect(view.processInspector?.rows.first?.pid == 5_000_000_012)
            view.removeFromSuperview()
            #expect(view.processInspector?.refreshTimer == nil)
        }
    }

    @Test func processMenuHandlesNoResultsAndTiedCPUUsage() async throws {
        try await withFixture { settings, defaults, source in
            let empty = panel(source.miner(), settings, defaults)
            #expect(empty.makeMenu().items.count == 12)
            let records = XRGProcessMiner.parse("20 8 1 1 - u Second\n20 2 1 1 - u First\n1 3 1 1 - u Last")
            let processes = XRGProcessMiner(source: { records }); await processes.refresh()
            let view = panel(source.miner(), settings, defaults, processMiner: processes)
            let menu = view.makeMenu()
            #expect(menu.items[1].title == "20.0% - First (id 2)")
            #expect(menu.items[2].title == "20.0% - Second (id 8)")
            #expect(menu.items.count == 15)
        }
    }

    @Test(arguments: ["CPUView", "LegacyCPU"])
    func currentAndLegacyNibArchivesInstantiateTheSwiftPanel(name: String) async throws {
        try await withFixture { _, _, _ in
            let nib = try #require(NSNib(nibNamed: NSNib.Name(name), bundle: Bundle(for: CPUNibOwner.self)))
            var objects: NSArray?
            #expect(nib.instantiate(withOwner: CPUNibOwner(), topLevelObjects: &objects))
            let view = try #require(objects?.compactMap { $0 as? XRGCPUView }.first)
            #expect(view.subviews.count == 3 && view.module == nil)
            #expect(view.frame.size == NSSize(width: 76, height: 76))
            withExtendedLifetime(objects) {}
        }
    }

    @Test func fullMiniFastAndCombinedGraphsRenderToNativeBitmaps() async throws {
        try await withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            seed(miner, source)
            let separated = try png(view)
            settings.separateCPUColor = false
            #expect(try png(view) != separated)
            settings.fastCPUUsage = true
            source.advance(); view.fastUpdate(nil)
            #expect(try png(view) != separated)
            settings.fastCPUUsage = false; view.setFrameSize(NSSize(width: 200, height: 10))
            let slowMini = try png(view)
            settings.fastCPUUsage = true
            #expect(try png(view) != slowMini)
            settings.graphStyle = 1
            #expect(try png(view) != slowMini)
        }
    }

    @Test func mouseEventsStillReachTheWindow() async throws {
        try await withFixture { settings, defaults, source in
            let host = CPUHost(settings: settings)
            defer { host.close() }
            let view = panel(source.miner(), settings, defaults)
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
