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

    @Test func registrationVisibilityFontAndDetachment() throws {
        try withFixture { settings, defaults, source in
            defaults.set(false, forKey: "showDiskGraph")
            let host = DiskPanelHost(settings: settings)
            defer { host.close() }
            let view = panel(source.miner(), settings, defaults)
            host.contentView?.addSubview(view); view.awakeFromNib(); view.awakeFromNib()
            let module = try #require(view.module)
            #expect(module.name == "Disk" && module.displayOrder == 6)
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

    @Test func resetClearsBothGraphsAndSmoothingButKeepsTheByteTotalAndBaselines() throws {
        try withFixture { settings, defaults, source in
            let miner = source.miner(), view = panel(miner, settings, defaults, height: 10)
            source.advance(1, read: 1600, written: 400); view.graphUpdate(nil); view.fastUpdate(nil)
            view.clearData(nil)
            #expect(miner.totalValues.max == 0 && view.fastReadValue == 0 && view.fastWriteValue == 0 && view.fastScale == 1_048_576)
            #expect(miner.totalBytesSinceLoad == 800)
            source.advance(2, read: 2200, written: 600); view.graphUpdate(nil); view.fastUpdate(nil)
            #expect(miner.totalValues.currentValue == 800 && miner.totalBytesSinceLoad == 1600)
            #expect(abs(view.fastReadValue - 120) < 0.0001)
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
            #expect(menu.items.count == 4)
            for item in menu.items where !item.isSeparatorItem {
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
