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

@MainActor private final class NetworkHost: NSWindow, XRGNetViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var netView: XRGNetView?
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
    func showNetworkPreferences() { preferencesOpened += 1 }
    override func mouseDown(with event: NSEvent) { mouseEvents.append("down") }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}
private final class NetworkNibOwner: NSObject {}

@MainActor private final class NetworkSource {
    var time: TimeInterval = 0
    var samples: [XRGNetworkSample]? = [XRGNetworkSample(name: "en0", index: 1, received: 1000, sent: 200)]
    var reads = 0
    func miner() -> XRGNetMiner {
        XRGNetMiner(source: { self.reads += 1; return self.samples }, clock: { self.time })
    }
    func advance(_ time: TimeInterval, rx: UInt64, tx: UInt64) {
        self.time = time
        samples = [XRGNetworkSample(name: "en0", index: 1, received: rx, sent: tx)]
    }
}

@Suite(.serialized) @MainActor
struct XRGNetViewTests {
    @Test func retentionKeepsNormalFastRatesAndTransfersAcrossResizeAndRelaunch() throws {
        try withFixture { settings, defaults, source in
            let view = panel(source, settings, defaults, height: 10)
            source.advance(1, rx: 1600, tx: 400); view.graphUpdate(nil); view.fastUpdate(nil)
            let reads = source.reads, fast = view.fastRXValue, total = view.miner.totalBytesSinceLoad
            #expect(fast > 0)
            let option = NSMenuItem(); option.tag = 300; view.selectHistory(option)
            #expect(source.reads == reads && view.fastRXValue == fast && view.miner.totalBytesSinceLoad == total)
            #expect(view.miner.rxValues.numValues == 300 && view.miner.rxValues.currentValue == 600)
            #expect(view.miner.rxValues.orderedValues.first == XRGGraphRenderer.missingValue)
            view.setFrameSize(NSSize(width: 60, height: 10))
            #expect(view.miner.rxValues.numValues == 300 && source.reads == reads)
            let restored = panel(source, settings, defaults)
            #expect(restored.retainedSamples == 300 && restored.miner.rxValues.numValues == 300)
            source.advance(2, rx: 2200, tx: 600); view.graphUpdate(nil); view.fastUpdate(nil)
            #expect(view.miner.currentRX() == 600 && view.miner.totalBytesSinceLoad == total + 800)
            #expect(view.fastRXValue > fast)
            option.tag = 20001; view.selectHistory(option); #expect(view.retainedSamples == 300)
            option.tag = 0; view.selectHistory(option); #expect(view.miner.rxValues.numValues == 60)
        }
    }
    @Test func networkWindowsPreserveTransfersRateBaselinesFastStreamAndScale() throws {
        try withFixture { settings,defaults,source in
            settings.graphRefresh=1;settings.netMinGraphScale=1;settings.netGraphMode=0;var wall=100.0
            let miner=XRGNetMiner(source:{source.reads+=1;return source.samples},clock:{source.time},historyClock:{wall}), fast=source.miner()
            let view=XRGNetView(frame:NSRect(x:0,y:0,width:200,height:100),miner:miner,fastMiner:fast,settings:settings,defaults:defaults)
            wall=101;source.advance(1,rx:7000,tx:2200);view.graphUpdate(nil)
            wall=111;source.advance(2,rx:7600,tx:2400);view.graphUpdate(nil);_ = fast.getLatestFastInfo()
            let reads=source.reads,total=miner.totalBytesSinceLoad,fastRate=fast.currentRX()
            let option=NSMenuItem();option.tag=1;view.selectHistoryWindow(option)
            #expect(view.historyMinutes==1 && view.plots()[0].data.numValues==61 && view.plots()[0].data.currentValue==800)
            #expect(view.plots()[0].data.orderedValues[50]==8000 && view.plots()[0].data.orderedValues[51..<60].allSatisfy{$0==XRGGraphRenderer.missingValue})
            view.setFrameSize(NSSize(width:1,height:100));#expect(view.graphScale()==8000 && miner.totalValues.numValues==1)
            #expect(source.reads==reads && miner.totalBytesSinceLoad==total && fast.currentRX()==fastRate && fast.timedHistory.observationCount==1)
            let before=view.plots()[0].data.orderedValues;view.resetTransfers(nil)
            #expect(miner.totalBytesSinceLoad==0 && view.plots()[0].data.orderedValues==before && miner.currentRX()==600)
            wall=112;source.advance(3,rx:8200,tx:2600);view.graphUpdate(nil)
            #expect(miner.totalBytesSinceLoad==0 && miner.currentRX()==600)
            wall=113;source.advance(4,rx:8800,tx:2800);view.graphUpdate(nil);#expect(miner.totalBytesSinceLoad==800)
            let restored=XRGNetView(frame:NSRect(x:0,y:0,width:200,height:100),miner:miner,fastMiner:fast,settings:settings,defaults:defaults)
            #expect(restored.historyMinutes==1 && restored.plots()[0].data.currentValue==800)
            option.tag=61;restored.selectHistoryWindow(option);#expect(restored.historyMinutes==1)
            let choices=try #require(restored.makeMenu().items.first{$0.title=="Network Time Window"}?.submenu)
            #expect(choices.items.allSatisfy{$0.target===restored})
            restored.clearData(nil)
            #expect(miner.totalBytesSinceLoad==800 && restored.plots()[0].data.orderedValues.allSatisfy{$0==XRGGraphRenderer.missingValue})
            option.tag=300;restored.selectHistory(option);#expect(restored.historyMinutes==0 && restored.retainedSamples==300)
        }
    }
    @Test func networkWindowFailureAndInterfaceReplacementRespectProvenance() throws {
        try withFixture { settings,defaults,source in
            settings.graphRefresh=1;settings.netGraphMode=0;defaults.set(1,forKey:XRGNetView.windowKey);var wall=100.0
            let miner=XRGNetMiner(source:{source.reads+=1;return source.samples},clock:{source.time},historyClock:{wall})
            let view=XRGNetView(frame:NSRect(x:0,y:0,width:200,height:100),miner:miner,fastMiner:source.miner(),settings:settings,defaults:defaults)
            wall=101;source.advance(1,rx:1600,tx:400);view.graphUpdate(nil);let total=miner.totalBytesSinceLoad
            wall=110;source.time=2;source.samples=nil;view.graphUpdate(nil)
            #expect(miner.totalBytesSinceLoad==total && view.plots()[0].data.currentValue==XRGGraphRenderer.missingValue)
            #expect(view.plots()[0].data.orderedValues[51]==800)
            wall=111;source.advance(3,rx:2200,tx:600);view.graphUpdate(nil)
            #expect(miner.totalBytesSinceLoad==total && miner.transfersAreLowerBound)
            wall=112;source.time=4;source.samples=[XRGNetworkSample(name:"en0",index:7,received:900_000,sent:800_000)];view.graphUpdate(nil)
            #expect(miner.totalBytesSinceLoad==0 && view.plots()[0].data.orderedValues.dropLast().allSatisfy{$0==XRGGraphRenderer.missingValue})
            let reads=source.reads;miner.monitorNetworkInterface="en0"
            #expect(source.reads==reads && view.plots()[0].data.orderedValues.allSatisfy{$0==XRGGraphRenderer.missingValue})
        }
    }
    private func withFixture(_ body: (XRGSettings, UserDefaults, NetworkSource) throws -> Void) throws {
        _ = NSApplication.shared
        let domain = "XRG.networkView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showNetworkGraph")
        let settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        settings.textTransparency = 1; settings.textColor = .black
        settings.graphBGTransparency = 1; settings.graphBGColor = .white
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        settings.netMinGraphScale = 1024
        settings.networkInterface = "All"
        settings.showTotalBandwidthSinceBoot = true; settings.showTotalBandwidthSinceLoad = true
        try body(settings, defaults, NetworkSource())
    }
    private func panel(_ source: NetworkSource, _ settings: XRGSettings, _ defaults: UserDefaults,
                       height: CGFloat = 100) -> XRGNetView {
        XRGNetView(frame: NSRect(x: 0, y: 0, width: 200, height: height), miner: source.miner(),
                   fastMiner: source.miner(), settings: settings, defaults: defaults)
    }
    private func png(_ view: XRGNetView) throws -> Data {
        view.needsDisplay = true
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func hiddenCoreGraphKeepsRatesTransfersAndHistoryWithoutFastPolling() throws {
        try withFixture { settings, defaults, source in
            defaults.set(false, forKey: "showNetworkGraph")
            let miner = XRGNetMiner(source: { source.reads += 1; return source.samples }, clock: { source.time }, historyClock: { 100 + source.time })
            let view = XRGNetView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), miner: miner, fastMiner: source.miner(), settings: settings, defaults: defaults)
            let host = NetworkHost(settings: settings)
            defer { view.removeFromSuperview(); host.close() }
            host.contentView?.addSubview(view); view.awakeFromNib()
            let manager = try #require(host.moduleManager), module = try #require(view.module)
            #expect(!module.isDisplayed && manager.displayList().isEmpty)
            let before = source.reads, observations = miner.timedHistory.observationCount
            source.advance(1, rx: 1600, tx: 400); manager.graphUpdate(); manager.fastUpdate()
            #expect(source.reads == before + 1 && miner.currentRX() == 600 && miner.totalBytesSinceLoad == 800)
            source.advance(2, rx: 2200, tx: 600); manager.graphUpdate(); manager.fastUpdate()
            #expect(source.reads == before + 2 && miner.currentRX() == 600 && miner.totalBytesSinceLoad == 1600 && miner.timedHistory.observationCount == observations + 2)
            source.advance(3, rx: 2800, tx: 800); manager.setModule("Network", isDisplayed: true)
            #expect(module.isDisplayed && miner.currentRX() == 600 && miner.totalBytesSinceLoad == 2400)
            view.removeFromSuperview(); let detached = source.reads; manager.graphUpdate(); manager.fastUpdate()
            #expect(source.reads == detached && manager.moduleList().isEmpty)
        }
    }

    @Test func registrationVisibilityFontAndDetachment() throws {
        try withFixture { settings, defaults, source in
            defaults.set(false, forKey: "showNetworkGraph")
            let host = NetworkHost(settings: settings)
            defer { host.close() }
            let view = panel(source, settings, defaults)
            host.contentView?.addSubview(view); view.awakeFromNib(); view.awakeFromNib()
            let module = try #require(view.module)
            #expect(module.name == "Network" && module.displayOrder == 6)
            #expect(module.doesGraphUpdate && module.doesFastUpdate && !module.doesMin5Update && !module.doesMin30Update)
            #expect(!module.isDisplayed && host.netView === view && module.reference === view)
            #expect(host.moduleManager?.moduleList().count == 1 && host.timerRequests == 1)
            #expect(view.subviews.count == 5)
            let minimum = module.minWidth
            settings.graphFont = NSFont.systemFont(ofSize: 28); view.updateMinSize()
            #expect(module.minWidth > minimum)
            view.removeFromSuperview()
            #expect(view.module == nil && host.netView == nil && host.moduleManager?.moduleList().isEmpty == true)
        }
    }

    @Test func detachingAnOlderPanelPreservesItsReplacement() throws {
        try withFixture { settings, defaults, source in
            let host = NetworkHost(settings: settings)
            defer { host.close() }
            let first = panel(source, settings, defaults), second = panel(source, settings, defaults)
            host.contentView?.addSubview(first); first.awakeFromNib()
            host.contentView?.addSubview(second); second.awakeFromNib()
            first.removeFromSuperview()
            #expect(host.netView === second)
            #expect(host.moduleManager?.moduleList().count == 1)
            #expect(host.moduleManager?.moduleList().first === second.module)
            second.removeFromSuperview()
        }
    }

    @Test(arguments: [0, 1, 2])
    func fullGraphModesKeepSeriesDirectionsAndRatePositions(mode: Int) throws {
        try withFixture { settings, defaults, source in
            settings.netGraphMode = mode
            let view = panel(source, settings, defaults)
            source.advance(2, rx: 1600, tx: 400); view.graphUpdate(nil)
            let plots = view.plots()
            #expect(plots[0].data === (mode == 0 ? view.miner.totalValues : view.miner.rxValues))
            #expect(plots[1].data === view.miner.txValues)
            #expect(plots[0].flipped == (mode == 2) && plots[1].flipped == (mode == 1))
            #expect(view.bottomRates.rightLabel.accessibilityValue() == (mode == 0 ? "300B Rx\n100B Tx" : mode == 1 ? "300B Rx" : "100B Tx"))
            #expect(view.topRates.rightLabel.isHidden == (mode == 0))
            if mode != 0 {
                #expect(view.topRates.rightLabel.accessibilityValue() == (mode == 1 ? "100B Tx" : "300B Rx"))
                #expect(view.topRates.rightLabel.frame.minY > view.bottomRates.rightLabel.frame.minY)
            }
            #expect(view.fullLeftReading() == "Net\n1.0K/s\n2.0K\n800B")
            #expect(view.graphLabels.leftLabel.accessibilityValue() == view.fullLeftReading())
        }
    }

    @Test func totalsFlagsAndStrictRowCapacityKeepCompleteAccessibilityText() throws {
        try withFixture { settings, defaults, source in
            let view = panel(source, settings, defaults)
            let line = XRGGraphLabels.lineHeight(settings)
            view.setFrameSize(NSSize(width: 200, height: line * 3))
            #expect(!view.shouldDrawMiniGraph())
            #expect(view.graphLabels.leftLabel.stringValue == "Net\n1.0K/s")
            #expect(view.graphLabels.leftLabel.accessibilityValue() == "Net\n1.0K/s\n1.2K\n0B")
            settings.showTotalBandwidthSinceBoot = false; settings.showTotalBandwidthSinceLoad = false
            view.graphUpdate(nil)
            #expect(view.fullLeftReading() == "Net\n1.0K/s")
            view.setFrameSize(NSSize(width: 30, height: 100))
            #expect(view.fullLeftReading().hasPrefix("N\n"))
        }
    }

    @Test(arguments: [0, 1, 2])
    func miniSmoothingAndOrderingRetainFractionalRates(mode: Int) throws {
        try withFixture { settings, defaults, source in
            settings.netGraphMode = mode
            let view = panel(source, settings, defaults, height: 10)
            source.advance(1, rx: 1600, tx: 400); view.fastUpdate(nil); view.graphUpdate(nil)
            #expect(abs(view.fastRXValue - 120) < 0.0001 && abs(view.fastTXValue - 40) < 0.0001)
            let expected: [Double] = mode == 1 ? [40, 120] : [120, 40]
            #expect(zip(view.miniValues(), expected).allSatisfy { abs($0.doubleValue - $1) < 0.0001 })
            #expect(view.graphLabels.rightLabel.accessibilityValue() == "800B/s")
            #expect(view.bottomRates.rightLabel.isHidden && view.topRates.rightLabel.isHidden)
            source.advance(2, rx: 1601, tx: 401); view.fastUpdate(nil)
            #expect(abs(view.fastRXValue - 96.2) < 0.0001 && abs(view.fastTXValue - 32.2) < 0.0001)
        }
    }

    @Test func fullModeSkipsFastPollsAndMiniReentryRebasesStaleCounters() throws {
        try withFixture { settings, defaults, source in
            let view = panel(source, settings, defaults, height: 10)
            source.advance(1, rx: 1600, tx: 400); view.fastUpdate(nil)
            #expect(view.fastRXValue > 0)
            view.setFrameSize(NSSize(width: 200, height: 100))
            let reads = source.reads
            source.advance(100, rx: 100000, tx: 20000); view.fastUpdate(nil)
            #expect(source.reads == reads)
            view.setFrameSize(NSSize(width: 200, height: 10)); view.fastUpdate(nil)
            #expect(view.fastRXValue == 0 && view.fastTXValue == 0)
            source.advance(101, rx: 100600, tx: 20200); view.fastUpdate(nil)
            #expect(abs(view.fastRXValue - 120) < 0.0001)
        }
    }

    @Test func interfaceChangesResetBothHistoriesAndUseTheSelectedSource() throws {
        try withFixture { settings, defaults, source in
            let view = panel(source, settings, defaults, height: 10)
            source.advance(1, rx: 1600, tx: 400); view.fastUpdate(nil); view.graphUpdate(nil)
            settings.networkInterface = "en1"
            source.time = 2
            source.samples = [XRGNetworkSample(name: "en0", index: 1, received: 5000, sent: 5000),
                              XRGNetworkSample(name: "en1", index: 2, received: 100, sent: 100)]
            view.graphUpdate(nil); view.fastUpdate(nil)
            #expect(view.miner.monitorNetworkInterface == "en1" && view.fastMiner.monitorNetworkInterface == "en1")
            #expect(view.miner.totalBytesSinceLoad == 0 && view.fastRXValue == 0 && view.miner.maxBandwidth() == 0)
            source.time = 3
            source.samples = [XRGNetworkSample(name: "en0", index: 1, received: 9000, sent: 9000),
                              XRGNetworkSample(name: "en1", index: 2, received: 150, sent: 125)]
            view.graphUpdate(nil); view.fastUpdate(nil)
            #expect(view.miner.currentRX() == 50 && view.miner.currentTX() == 25)
            #expect(view.miner.totalBytesSinceLoad == 75 && abs(view.fastRXValue - 10) < 0.0001)
        }
    }

    @Test func graphAndTransferResetsAreIndependentAndPreserveRates() throws {
        try withFixture { settings, defaults, source in
            let view = panel(source, settings, defaults, height: 10)
            source.advance(1, rx: 1600, tx: 400); view.graphUpdate(nil); view.fastUpdate(nil)
            let fastRx = view.fastRXValue, fastTx = view.fastTXValue
            view.clearData(nil)
            #expect(view.miner.maxBandwidth() == 0 && view.fastMiner.maxBandwidth() == 0)
            #expect(view.fastRXValue == fastRx && view.fastTXValue == fastTx)
            #expect(view.miner.totalBytesSinceLoad == 800 && view.miner.currentRX() == 600)
            #expect(view.graphLabels.rightLabel.accessibilityValue() == "800B/s")
            source.advance(2, rx: 2200, tx: 600); view.graphUpdate(nil); view.fastUpdate(nil)
            #expect(view.miner.currentRX() == 600 && abs(view.fastRXValue - 216) < 0.0001)
            let history = view.miner.rxValues.orderedValues
            view.resetTransfers(nil)
            #expect(view.miner.totalBytesSinceLoad == 0 && view.miner.rxValues.orderedValues == history)
            #expect(abs(view.fastRXValue - 216) < 0.0001 && view.miner.currentRX() == 600)
            source.advance(3, rx: 2800, tx: 800); view.graphUpdate(nil)
            #expect(view.miner.currentRX() == 600 && view.miner.totalBytesSinceLoad == 0)
            source.advance(4, rx: 3400, tx: 1000); view.graphUpdate(nil)
            #expect(view.miner.receivedBytesSinceLoad == 600 && view.miner.sentBytesSinceLoad == 200)
            source.samples = nil; source.time = 5; view.graphUpdate(nil)
            #expect(view.graphLabels.rightLabel.accessibilityValue() == "—")
            #expect(view.toolTip?.contains("Partial coverage") == true)
        }
    }

    @Test func menuUsesCachedWideCountersAndExplicitTargets() throws {
        try withFixture { settings, defaults, source in
            source.samples = [XRGNetworkSample(name: "en1", index: 2, received: 5_000_000_000, sent: 6_000_000_000),
                              XRGNetworkSample(name: "en0", index: 1, received: 0, sent: 0),
                              XRGNetworkSample(name: "lo0", index: 3, received: 1, sent: 1)]
            var opened: [URL] = []
            var utility: URL? = nil
            let view = XRGNetView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), miner: source.miner(),
                fastMiner: source.miner(), settings: settings, defaults: defaults,
                openURL: { opened.append($0); return true }, utilityURL: { utility })
            let host = NetworkHost(settings: settings)
            defer { host.close() }
            host.contentView?.addSubview(view); view.awakeFromNib()
            let reads = source.reads
            let menu = view.makeMenu()
            #expect(source.reads == reads)
            #expect(menu.items[1].title == "en0: RX(0.0M) TX(0.0M)")
            #expect(menu.items[2].title == "en1: RX(4768.4M) TX(5722.0M)")
            #expect(!menu.items.contains { $0.title.contains("Utility") || $0.title.contains("lo0:") })
            for item in menu.items where !item.isSeparatorItem { #expect(item.target === view) }
            for title in ["Reset Graph", "Open Network Settings...", "Open XRG-ng Network Preferences..."] {
                let item = try #require(menu.items.first { $0.title == title })
                #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            }
            #expect(opened == [XRGNetView.networkSettingsURL] && host.preferencesOpened == 1)
            utility = URL(fileURLWithPath: "/tmp/Network Utility.app")
            let item = try #require(view.makeMenu().items.first { $0.title == "Open Network Utility..." })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            #expect(opened.last == utility)
            utility = nil; view.openNetworkUtility(nil)
            #expect(opened.count == 2)
            view.removeFromSuperview()
        }
    }

    @Test func historyScaleAndGeometryAreBoundedWithoutNarrowingCounters() throws {
        try withFixture { settings, defaults, source in
            settings.netMinGraphScale = 0
            let view = panel(source, settings, defaults)
            #expect(view.graphScale() == 1)
            source.advance(1, rx: UInt64.max - 1, tx: UInt64.max - 1); view.graphUpdate(nil)
            #expect(view.graphScale().isFinite && view.graphScale() > CGFloat(Int64.max))
            #expect(view.fullLeftReading() == "Net\n32768.0P/s\n≥16384.0P\n≥16384.0P")
            view.setGraphSize(NSSize(width: CGFloat.greatestFiniteMagnitude, height: 0))
            #expect(view.miner.rxValues.numValues == 20_000 && view.fastMiner.rxValues.numValues == 20_000)
            view.setWidth(-1)
            #expect(view.miner.rxValues.numValues == 20_000)
            view.setGraphSize(NSSize(width: CGFloat.nan, height: 0))
            #expect(view.miner.rxValues.numValues == 1 && view.fastMiner.rxValues.numValues == 1)
            view.setFrameSize(.zero)
            for label in view.subviews { #expect(label.frame.size.width >= 0 && label.frame.size.height >= 0) }
            #expect(view.convertHeight(-1) == 0)
            view.setFrameSize(NSSize(width: 200, height: 1000))
            #expect(view.convertHeight(Int.max) == Int.max)
        }
    }

    @Test(arguments: ["NetworkView", "LegacyNetwork"])
    func currentAndLegacyNibArchivesInstantiateTheSwiftPanel(name: String) throws {
        try withFixture { _, _, _ in
            let nib = try #require(NSNib(nibNamed: NSNib.Name(name), bundle: Bundle(for: NetworkNibOwner.self)))
            var objects: NSArray?
            #expect(nib.instantiate(withOwner: NetworkNibOwner(), topLevelObjects: &objects))
            let view = try #require(objects?.compactMap { $0 as? XRGNetView }.first)
            #expect(view.subviews.count == 5 && view.module == nil)
            #expect(view.frame.size == NSSize(width: 76, height: 76))
            withExtendedLifetime(objects) {}
        }
    }

    @Test func bitmapModesAndMiniStyleUseTheExpectedSeries() throws {
        try withFixture { settings, defaults, source in
            let view = panel(source, settings, defaults)
            view.miner.rxValues.setAllValues(300); view.miner.txValues.setAllValues(100); view.miner.totalValues.setAllValues(400)
            var images: Set<Data> = []
            for mode in 0...2 { settings.netGraphMode = mode; images.insert(try png(view)) }
            #expect(images.count == 3)
            view.setFrameSize(NSSize(width: 200, height: 10))
            source.advance(1, rx: 1600, tx: 400); view.fastUpdate(nil)
            source.advance(2, rx: 2200, tx: 600); view.fastUpdate(nil)
            settings.graphStyle = 0
            let mini = try png(view)
            settings.graphStyle = 1
            #expect(try png(view) == mini)
        }
    }

    @Test func mouseEventsStillReachTheWindow() throws {
        try withFixture { settings, defaults, source in
            let host = NetworkHost(settings: settings)
            defer { host.close() }
            let view = panel(source, settings, defaults)
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
