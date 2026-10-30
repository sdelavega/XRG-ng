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

@MainActor private final class DiskPanelHost: NSWindow, XRGDiskViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var diskView: XRGDiskView?
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
    func showDiskPreferences() { preferencesOpened += 1 }
    override func mouseDown(with event: NSEvent) { mouseEvents.append("down") }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}
private final class DiskPanelNibOwner: NSObject {}

@Suite(.serialized) @MainActor
struct XRGDiskViewTests {
    @Test func retentionKeepsDiskRatesAndTransfersAcrossResizeAndRelaunch() throws {
        try withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults, height: 10)
            source.advance(1, read: 1600, written: 400); view.graphUpdate(nil); view.fastUpdate(nil)
            let reads = source.reads, fast = view.fastReadValue, total = miner.totalBytesSinceLoad
            #expect(fast > 0)
            let option = NSMenuItem(); option.tag = 300; view.selectHistory(option)
            #expect(source.reads == reads && view.fastReadValue == fast && miner.totalBytesSinceLoad == total)
            #expect(miner.readValues.numValues == 300 && miner.readValues.currentValue == 600)
            #expect(miner.readValues.orderedValues.first == XRGGraphRenderer.missingValue)
            view.setFrameSize(NSSize(width: 60, height: 10))
            #expect(miner.readValues.numValues == 300 && source.reads == reads)
            let restored = panel(miner, settings, defaults)
            #expect(restored.retainedSamples == 300 && miner.readValues.numValues == 300)
            source.advance(2, read: 2200, written: 600); view.graphUpdate(nil); view.fastUpdate(nil)
            #expect(miner.readValues.currentValue == 600 && miner.totalBytesSinceLoad == total + 800)
            #expect(view.fastReadValue > fast)
            option.tag = 20001; restored.selectHistory(option); #expect(restored.retainedSamples == 300)
            option.tag = 0; restored.selectHistory(option); #expect(miner.readValues.numValues == 240)
        }
    }
    @Test func diskTimeWindowKeepsRatesTransfersFastStateAndRealGapsIndependent() throws {
        try withFixture { settings, defaults, source in
            settings.graphRefresh=1;var wall=100.0
            let miner=XRGDiskMiner(source:{source.reads+=1;return source.samples},clock:{source.time},historyClock:{wall})
            let view=panel(miner,settings,defaults)
            wall=101;source.advance(1,read:7000,written:2200);view.graphUpdate(nil)
            wall=111;source.advance(2,read:7600,written:2400);view.graphUpdate(nil);_ = miner.updateFast()
            let reads=source.reads, total=miner.totalBytesSinceLoad, fast=miner.fastReadRate
            let option=NSMenuItem();option.tag=1;view.selectHistoryWindow(option)
            #expect(view.historyMinutes==1 && view.plots()[0].data.numValues==61 && view.plots()[0].data.currentValue==800)
            #expect(view.plots()[0].data.orderedValues[50]==8000 && view.plots()[0].data.orderedValues[51..<60].allSatisfy{$0==XRGGraphRenderer.missingValue})
            view.setFrameSize(NSSize(width:1,height:100))
            #expect(miner.totalValues.numValues==1 && view.graphScale()==8000)
            #expect(source.reads==reads && miner.totalBytesSinceLoad==total && miner.fastReadRate==fast)
            let before=view.plots()[0].data.orderedValues
            view.resetTransfers(nil)
            #expect(miner.totalBytesSinceLoad==0 && view.plots()[0].data.orderedValues==before && miner.readRate==600)
            wall=112;source.advance(3,read:8200,written:2600);view.graphUpdate(nil)
            #expect(miner.totalBytesSinceLoad==0 && miner.readRate==600)
            wall=113;source.advance(4,read:8800,written:2800);view.graphUpdate(nil)
            #expect(miner.totalBytesSinceLoad==800)
            view.clearData(nil)
            #expect(miner.totalBytesSinceLoad==800 && view.plots()[0].data.orderedValues.allSatisfy{$0==XRGGraphRenderer.missingValue})
            wall=50;source.advance(5,read:9400,written:3000);view.graphUpdate(nil)
            #expect(view.plots()[0].data.currentValue==800 && miner.totalBytesSinceLoad==1600)
            #expect(view.plots()[0].data.orderedValues.dropLast().allSatisfy{$0==XRGGraphRenderer.missingValue})
            let restored=panel(miner,settings,defaults);#expect(restored.historyMinutes==1 && restored.plots()[0].data.currentValue==800)
            option.tag=61;restored.selectHistoryWindow(option);#expect(restored.historyMinutes==1)
            let menu=try #require(restored.makeMenu().items.first{$0.title=="Disk Time Window"}?.submenu)
            #expect(menu.items.allSatisfy{$0.target===restored})
            option.tag=300;restored.selectHistory(option);#expect(restored.historyMinutes==0 && restored.retainedSamples==300)
        }
    }
    @Test func diskWindowShowsFailureGapAndClearsReplacementIdentityWithoutImportingBytes() throws {
        try withFixture { settings,defaults,source in
            settings.graphRefresh=1;defaults.set(1,forKey:XRGDiskView.windowKey);var wall=100.0
            let miner=XRGDiskMiner(source:{source.reads+=1;return source.samples},clock:{source.time},historyClock:{wall})
            let view=panel(miner,settings,defaults)
            wall=101;source.advance(1,read:1600,written:400);view.graphUpdate(nil);let total=miner.totalBytesSinceLoad
            wall=110;source.time=2;source.samples=nil;view.graphUpdate(nil)
            #expect(view.plots()[0].data.currentValue==XRGGraphRenderer.missingValue && miner.totalBytesSinceLoad==total)
            #expect(view.plots()[0].data.orderedValues[51]==800)
            wall=111;source.advance(3,read:2200,written:600);view.graphUpdate(nil)
            #expect(miner.totalBytesSinceLoad==total && miner.transfersAreLowerBound)
            wall=112;source.time=4;source.samples=[XRGDiskSample(id:2,read:1_000_000,written:900_000)];view.graphUpdate(nil)
            #expect(miner.totalBytesSinceLoad==0 && view.plots()[0].data.orderedValues.dropLast().allSatisfy{$0==XRGGraphRenderer.missingValue})
        }
    }
    private func withFixture(_ body: (XRGSettings, UserDefaults, DiskSampleSource) throws -> Void) throws {
        _ = NSApplication.shared
        let domain = "XRG.diskView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showDiskGraph")
        let settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        settings.textTransparency = 1; settings.textColor = .black
        settings.graphBGTransparency = 1; settings.graphBGColor = .white
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        settings.diskGraphMode = 0; settings.graphStyle = 0
        try body(settings, defaults, DiskSampleSource())
    }
    private func panel(_ miner: XRGDiskMiner, _ settings: XRGSettings, _ defaults: UserDefaults,
                       width: CGFloat = 240, height: CGFloat = 100) -> XRGDiskView {
        XRGDiskView(frame: NSRect(x: 0, y: 0, width: width, height: height), miner: miner, settings: settings, defaults: defaults)
    }
    private func png(_ view: XRGDiskView) throws -> Data {
        view.needsDisplay = true
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func hiddenCoreGraphKeepsRatesTransfersAndHistoryWithoutFastPolling() throws {
        try withFixture { settings, defaults, source in
            defaults.set(false, forKey: "showDiskGraph")
            let miner = XRGDiskMiner(source: { source.reads += 1; return source.samples }, clock: { source.time }, historyClock: { 100 + source.time })
            let view = panel(miner, settings, defaults), host = DiskPanelHost(settings: settings)
            defer { view.removeFromSuperview(); host.close() }
            host.contentView?.addSubview(view); view.awakeFromNib()
            let manager = try #require(host.moduleManager), module = try #require(view.module)
            #expect(!module.isDisplayed && manager.displayList().isEmpty)
            let capacity = miner.readValues.numValues
            manager.windowChanged(to: host.frame.size)
            #expect(view.frame.size == .zero && miner.readValues.numValues == capacity)
            let before = source.reads, observations = miner.timedHistory.observationCount
            source.advance(1, read: 1600, written: 400); manager.graphUpdate(); manager.fastUpdate()
            #expect(source.reads == before + 1 && miner.readRate == 600 && miner.totalBytesSinceLoad == 800)
            source.advance(2, read: 2200, written: 600); manager.graphUpdate(); manager.fastUpdate()
            #expect(source.reads == before + 2 && miner.readRate == 600 && miner.totalBytesSinceLoad == 1600 && miner.timedHistory.observationCount == observations + 2)
            source.advance(3, read: 2800, written: 800); manager.setModule("Disk", isDisplayed: true)
            #expect(miner.readValues.numValues == capacity)
            #expect(module.isDisplayed && miner.readRate == 600 && miner.totalBytesSinceLoad == 2400)
            view.removeFromSuperview(); let detached = source.reads; manager.graphUpdate(); manager.fastUpdate()
            #expect(source.reads == detached && manager.moduleList().isEmpty)
        }
    }

    @Test func registrationVisibilityFontAndDetachment() throws {
        try withFixture { settings, defaults, source in
            defaults.set(false, forKey: "showDiskGraph")
            let host = DiskPanelHost(settings: settings)
            defer { host.close() }
            let view = panel(source.miner(), settings, defaults)
            host.contentView?.addSubview(view); view.awakeFromNib(); view.awakeFromNib()
            let module = try #require(view.module)
            #expect(module.name == "Disk" && module.displayOrder == 7)
            #expect(module.doesGraphUpdate && module.doesFastUpdate && module.doesMin5Update && !module.doesMin30Update)
            #expect(!module.isDisplayed && module.reference === view && host.diskView === view)
            #expect(host.moduleManager?.moduleList().count == 1 && host.timerRequests == 1 && view.subviews.count == 5)
            let width = module.minWidth
            settings.graphFont = NSFont.systemFont(ofSize: 28); view.updateMinSize()
            #expect(module.minWidth > width)
            view.removeFromSuperview()
            #expect(view.module == nil && host.diskView == nil && host.moduleManager?.moduleList().isEmpty == true)
        }
    }

    @Test func replacementAndManagerChangesRemoveOnlyTheOwnedModule() throws {
        try withFixture { settings, defaults, source in
            let host = DiskPanelHost(settings: settings)
            defer { host.close() }
            let first = panel(source.miner(), settings, defaults), second = panel(source.miner(), settings, defaults)
            host.contentView?.addSubview(first); first.awakeFromNib()
            host.contentView?.addSubview(second); second.awakeFromNib()
            first.removeFromSuperview()
            #expect(host.diskView === second && host.moduleManager?.moduleList().first === second.module)
            let old = try #require(host.moduleManager)
            host.moduleManager = XRGModuleManager(window: host); second.awakeFromNib()
            #expect(old.moduleList().isEmpty && host.moduleManager?.moduleList().count == 1)
            second.removeFromSuperview()
        }
    }

    @Test(arguments: [0, 1, 2])
    func graphModesPreserveSeriesDirectionsAndReadWritePositions(mode: Int) throws {
        try withFixture { settings, defaults, source in
            settings.diskGraphMode = mode
            let miner = source.miner(), view = panel(miner, settings, defaults)
            source.advance(2, read: 1600, written: 400); view.graphUpdate(nil)
            let plots = view.plots()
            #expect(plots[0].data === (mode == 0 ? miner.totalValues : miner.readValues))
            #expect(plots[1].data === miner.writeValues)
            #expect(plots[0].flipped == (mode == 1) && plots[1].flipped == (mode == 2))
            #expect(view.bottomRates.rightLabel.accessibilityValue() == (mode == 0 ? "300B R\n100B W" : mode == 1 ? "100B W" : "300B R"))
            #expect(view.topRates.rightLabel.isHidden == (mode == 0))
            if mode != 0 { #expect(view.topRates.rightLabel.accessibilityValue() == (mode == 1 ? "300B R" : "100B W")) }
            #expect(view.fullLeftReading() == "Disk\n400B/s\n800B")
            #expect(view.graphLabels.leftLabel.accessibilityValue() == view.fullLeftReading())
        }
    }

    @Test(arguments: [0, 1, 2])
    func miniRatesUseFastElapsedTimeFractionalSmoothingAndTheExistingOrder(mode: Int) throws {
        try withFixture { settings, defaults, source in
            settings.diskGraphMode = mode; settings.graphRefresh = 50
            let view = panel(source.miner(), settings, defaults, height: 10)
            source.advance(1, read: 1600, written: 400); view.fastUpdate(nil); view.graphUpdate(nil)
            #expect(abs(view.fastReadValue - 120) < 0.0001 && abs(view.fastWriteValue - 40) < 0.0001)
            let expected: [Double] = mode == 2 ? [40, 120] : [120, 40]
            #expect(zip(view.miniValues(), expected).allSatisfy { abs($0.doubleValue - $1) < 0.0001 })
            #expect(view.graphLabels.rightLabel.accessibilityValue() == "800B/s")
            #expect(view.topRates.rightLabel.isHidden && view.bottomRates.rightLabel.isHidden)
            source.advance(1.25, read: 1601, written: 401); view.fastUpdate(nil)
            #expect(abs(view.fastReadValue - 96.8) < 0.0001 && abs(view.fastWriteValue - 32.8) < 0.0001)
            #expect(view.fastScale == 1_048_576)
        }
    }

    @Test func fullModeSkipsFastReadsAndMiniReentryRebasesTheOldBaseline() throws {
        try withFixture { settings, defaults, source in
            let view = panel(source.miner(), settings, defaults, height: 10)
            source.advance(1, read: 1600, written: 400); view.fastUpdate(nil)
            #expect(view.fastReadValue > 0)
            view.setFrameSize(NSSize(width: 240, height: 100))
            let reads = source.reads
            source.advance(100, read: 1_000_000, written: 500_000); view.fastUpdate(nil)
            #expect(source.reads == reads)
            view.setFrameSize(NSSize(width: 240, height: 10)); view.fastUpdate(nil)
            #expect(view.fastReadValue == 0 && view.fastWriteValue == 0)
            source.advance(101, read: 1_000_600, written: 500_200); view.fastUpdate(nil)
            #expect(abs(view.fastReadValue - 120) < 0.0001)
        }
    }

    @Test func failedFastReadsDoNotDampTheLastRateAgainAndScaleKeepsItsFloor() throws {
        try withFixture { settings, defaults, source in
            let view = panel(source.miner(), settings, defaults, height: 10)
            source.advance(1, read: 1000 + 64 * 1_048_576, written: 200 + 32 * 1_048_576); view.fastUpdate(nil)
            #expect(view.fastScale > 1_048_576 && view.fastScale.isFinite)
            let read = view.fastReadValue, write = view.fastWriteValue, scale = view.fastScale
            source.samples = nil; source.time = 2; view.fastUpdate(nil)
            #expect(view.fastReadValue == read && view.fastWriteValue == write && view.fastScale == scale)
        }
    }

    @Test func resetClearsOnlyGraphsAndKeepsRatesByteTotalsAndBaselines() throws {
        try withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults, height: 10)
            source.advance(1, read: 1600, written: 400); view.graphUpdate(nil); view.fastUpdate(nil)
            let read = view.fastReadValue, write = view.fastWriteValue, scale = view.fastScale
            view.clearData(nil)
            #expect(miner.totalValues.max == 0 && view.fastReadValue == read && view.fastWriteValue == write && view.fastScale == scale)
            #expect(miner.totalBytesSinceLoad == 800)
            source.advance(2, read: 2200, written: 600); view.graphUpdate(nil); view.fastUpdate(nil)
            #expect(miner.totalValues.currentValue == 800 && miner.totalBytesSinceLoad == 1600)
            #expect(abs(view.fastReadValue - 216) < 0.0001)
        }
    }

    @Test func transferResetKeepsPlotAndPartialCoverageIsVisible() throws {
        try withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            source.advance(1, read: 1600, written: 400); view.graphUpdate(nil)
            let history = miner.totalValues.orderedValues
            view.resetTransfers(nil)
            #expect(miner.totalBytesSinceLoad == 0 && miner.totalValues.orderedValues == history)
            #expect(view.readBytesString() == "600B R")
            source.advance(2, read: 2200, written: 600); view.graphUpdate(nil)
            source.advance(3, read: 2800, written: 800); view.graphUpdate(nil)
            source.samples = nil; source.time = 4; view.graphUpdate(nil)
            #expect(view.fullLeftReading().hasSuffix("≥800B") && view.readBytesString() == "— R")
            #expect(view.toolTip?.contains("Partial coverage") == true)
        }
    }

    @Test func strictRowsKeepTheCompleteSessionReadingAndLegacyScaleUnits() throws {
        try withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            source.advance(2, read: 1600, written: 400); view.graphUpdate(nil)
            let h = XRGGraphLabels.lineHeight(settings)
            view.setFrameSize(NSSize(width: 240, height: h * 3))
            #expect(view.graphLabels.leftLabel.stringValue == "Disk\n400B/s")
            #expect(view.graphLabels.leftLabel.accessibilityValue() == "Disk\n400B/s\n800B")
            miner.totalValues.setAllValues(1024); #expect(view.scaleText() == "1.0K/s")
            miner.totalValues.setAllValues(1_048_576); #expect(view.scaleText() == "1.00M/s")
            miner.totalValues.reset(); #expect(view.graphScale() == 1)
            view.setFrameSize(NSSize(width: 30, height: 100))
            #expect(view.fullLeftReading().hasPrefix("D\n"))
        }
    }

    @Test(arguments: [CGFloat(10), 18, 28], [CGFloat(60), 100, 240])
    func fontAndWidthChangesKeepAllSourcesAndSeparateRateColumns(font: CGFloat, width: CGFloat) throws {
        try withFixture { settings, defaults, source in
            settings.graphFont = NSFont.systemFont(ofSize: font)
            let view = panel(source.miner(), settings, defaults, width: width)
            source.advance(2, read: 1600, written: 400); view.graphUpdate(nil)
            #expect(view.graphLabels.leftLabel.accessibilityValue() == view.fullLeftReading())
            #expect(view.bottomRates.rightLabel.accessibilityValue() == "300B R\n100B W")
            #expect(view.graphLabels.leftLabel.frame.maxX <= view.bottomRates.rightLabel.frame.minX)
            for label in view.subviews { #expect(label.frame.size.width >= 0 && label.frame.size.height >= 0) }
        }
    }

    @Test func historyWidthCollapsedFramesAndHeightConversionsAreBounded() throws {
        try withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            view.setGraphSize(NSSize(width: CGFloat.greatestFiniteMagnitude, height: 0))
            #expect(miner.readValues.numValues == 20_000)
            view.setWidth(-1); #expect(miner.readValues.numValues == 20_000)
            view.setGraphSize(NSSize(width: CGFloat.nan, height: 0))
            #expect(miner.readValues.numValues == 1)
            view.setFrameSize(.zero)
            #expect(view.convertHeight(-1) == 0)
            for label in view.subviews { #expect(label.frame.size.width >= 0 && label.frame.size.height >= 0) }
            view.setFrameSize(NSSize(width: 240, height: 1000))
            #expect(view.convertHeight(Int32.max) == Int32.max)
        }
    }

    @Test func menusTargetThePanelAndInjectTheDiskUtilityOpener() throws {
        try withFixture { settings, defaults, source in
            var opened: [URL] = []
            let miner = source.miner()
            let view = XRGDiskView(frame: NSRect(x: 0, y: 0, width: 240, height: 100), miner: miner, settings: settings,
                defaults: defaults, openURL: { opened.append($0); return true })
            let host = DiskPanelHost(settings: settings)
            defer { host.close() }
            host.contentView?.addSubview(view); view.awakeFromNib()
            source.advance(1, read: 1600, written: 400); view.graphUpdate(nil)
            let menu = view.makeMenu()
            #expect(menu.items.count == 8)
            for item in menu.items where !item.isSeparatorItem && item.title != "Transfer Details…" {
                #expect(item.target === view)
                let action = try #require(item.action)
                #expect(NSApp.sendAction(action, to: item.target, from: item))
            }
            #expect(miner.totalValues.max == 0 && opened == [XRGDiskView.diskUtilityURL] && host.preferencesOpened == 1)
            view.removeFromSuperview()
        }
    }

    @Test(arguments: ["DiskView", "LegacyDisk"])
    func currentAndLegacyNibArchivesInstantiateTheSwiftPanel(name: String) throws {
        try withFixture { _, _, _ in
            let nib = try #require(NSNib(nibNamed: NSNib.Name(name), bundle: Bundle(for: DiskPanelNibOwner.self)))
            var objects: NSArray?
            #expect(nib.instantiate(withOwner: DiskPanelNibOwner(), topLevelObjects: &objects))
            let view = try #require(objects?.compactMap { $0 as? XRGDiskView }.first)
            #expect(view.subviews.count == 5 && view.module == nil && view.frame.size == NSSize(width: 76, height: 76))
            withExtendedLifetime(objects) {}
        }
    }

    @Test func allModesRenderAndCompactModeKeepsItsUnstyledBars() throws {
        try withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults)
            miner.readValues.setAllValues(300); miner.writeValues.setAllValues(100); miner.totalValues.setAllValues(400)
            var images: Set<Data> = []
            for mode in 0...2 { settings.diskGraphMode = mode; images.insert(try png(view)) }
            #expect(images.count == 3)
            view.setFrameSize(NSSize(width: 240, height: 10))
            source.advance(1, read: 1600, written: 400); view.fastUpdate(nil)
            source.advance(2, read: 2200, written: 600); view.fastUpdate(nil)
            let mini = try png(view)
            settings.graphStyle = 1
            #expect(try png(view) == mini)
        }
    }

    @Test func mouseEventsStillReachTheWindow() throws {
        try withFixture { settings, defaults, source in
            let host = DiskPanelHost(settings: settings)
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
