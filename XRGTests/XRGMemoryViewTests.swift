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
import Foundation
import Testing
@testable import XRGCore

@MainActor
private final class MemoryHost: NSWindow, XRGMemoryViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var memoryView: XRGMemoryView?
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
    func showMemoryPreferences() { preferencesOpened += 1 }
    override func mouseDown(with event: NSEvent) { mouseEvents.append("down") }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}
private final class MemoryNibOwner: NSObject {}

@Suite(.serialized) @MainActor
struct XRGMemoryViewTests {
    private func withFixture(_ body: (XRGSettings, UserDefaults) async throws -> Void) async throws {
        _ = NSApplication.shared
        let domain = "XRG.memoryView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showMemoryGraph")
        let settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        settings.textTransparency = 1; settings.textColor = .black
        settings.graphBGTransparency = 1; settings.graphBGColor = .white
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        settings.graphFG3Transparency = 1; settings.graphFG3Color = .green
        try await body(settings, defaults)
    }
    private func sample() -> XRGMemorySnapshot {
        var sample = XRGMemorySnapshot()
        sample.free = 256; sample.active = 512; sample.inactive = 768; sample.wired = 1024
        sample.faults = 100; sample.pageIns = 10; sample.pageOuts = 20
        sample.lookups = 4; sample.hits = 3
        sample.usedSwap = 1_048_576; sample.totalSwap = 8_388_608
        return sample
    }
    private func panel(_ miner: XRGMemoryMiner, settings: XRGSettings, defaults: UserDefaults,
                       processMiner: XRGProcessMiner? = nil, height: CGFloat = 200) -> XRGMemoryView {
        XRGMemoryView(frame: NSRect(x: 0, y: 0, width: 200, height: height), memoryMiner: miner,
                      processMiner: processMiner ?? XRGProcessMiner(source: { [] }), settings: settings, defaults: defaults)
    }
    private func png(_ view: XRGMemoryView) throws -> Data {
        view.needsDisplay = true
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func registrationVisibilityAndDetachmentPreserveTheMemoryModule() async throws {
        try await withFixture { settings, defaults in
            defaults.set(false, forKey: "showMemoryGraph")
            let host = MemoryHost(settings: settings)
            defer { host.close() }
            let miner = XRGMemoryMiner(pageSize: 4096, source: { sample() })
            let view = panel(miner, settings: settings, defaults: defaults)
            host.contentView?.addSubview(view)
            view.awakeFromNib(); view.awakeFromNib()
            let module = try #require(view.module)
            #expect(module.name == "Memory" && module.displayOrder == 3)
            #expect(!module.isDisplayed && module.doesGraphUpdate && !module.doesFastUpdate)
            #expect(module.reference === view && host.memoryView === view)
            #expect(host.moduleManager?.moduleList().count == 1)
            #expect(host.timerRequests == 1 && view.subviews.count == 3)
            let minimum = module.minWidth
            settings.graphFont = NSFont.systemFont(ofSize: 28)
            view.updateMinSize()
            #expect(module.minWidth > minimum)
            host.moduleManager?.setModule("Memory", isDisplayed: true)
            #expect(module.isDisplayed)
            view.removeFromSuperview()
            #expect(view.module == nil && host.memoryView == nil)
            #expect(host.moduleManager?.moduleList().isEmpty == true)
        }
    }

    @Test func fullReadingsRetainOrderFlagsAndAccessibleSource() async throws {
        try await withFixture { settings, defaults in
            var next = sample()
            let miner = XRGMemoryMiner(pageSize: 4096, source: { next })
            let view = panel(miner, settings: settings, defaults: defaults)
            next.faults += 12; next.pageIns += 3; next.pageOuts += 5
            view.graphUpdate(nil)
            let expected = "Memory\nF: 1.00M\nI: 3.00M\nA: 2.00M\nW: 4.00M\nCa: 75%\nPF: 48K/s\nVu: 1.00M\nVt: 8.00M"
            #expect(view.fullReading() == expected)
            #expect(view.graphLabels.leftLabel.accessibilityValue() == expected)
            #expect(view.graphLabels.leftLabel.frame.maxX <= view.bounds.maxX - 19)
            settings.memoryShowFree = false; settings.memoryShowInactive = false
            settings.memoryShowActive = false; settings.memoryShowWired = false
            settings.memoryShowCache = false; settings.memoryShowPage = false
            view.graphUpdate(nil)
            #expect(view.fullReading() == "Memory\nVu: 1.00M\nVt: 8.00M")
        }
    }

    @Test(arguments: [UInt64(4096), 16384])
    func pageFaultTextUsesTheHostPageSizeAndValidIntervals(pageSize: UInt64) async throws {
        try await withFixture { settings, defaults in
            var next = sample()
            let miner = XRGMemoryMiner(pageSize: pageSize, source: { next })
            let view = panel(miner, settings: settings, defaults: defaults)
            next.faults += 1; settings.graphRefresh = 2
            view.graphUpdate(nil)
            #expect(view.fullReading().contains(pageSize == 4096 ? "PF: 2K/s" : "PF: 8K/s"))
            settings.graphRefresh = 0
            #expect(!view.fullReading().contains("PF:"))
            settings.graphRefresh = .nan
            #expect(view.fullReading().contains("PF: n/a"))
            settings.graphRefresh = -1
            #expect(view.fullReading().contains("PF: n/a"))
        }
    }

    @Test func pagingLayersShareOneScaleAndDoNotMutateTheirHistories() async throws {
        try await withFixture { settings, defaults in
            var next = sample()
            let miner = XRGMemoryMiner(pageSize: 4096, source: { next })
            let view = panel(miner, settings: settings, defaults: defaults)
            next.faults += 12; next.pageIns += 3; next.pageOuts += 5
            view.graphUpdate(nil)
            let before = miner.faultData().orderedValues
            let layers = view.pagingLayers()
            #expect(layers.maximum == 20)
            #expect(layers.values.map(\.currentValue) == [20, 15, 12])
            #expect(miner.faultData().orderedValues == before)
            view.clearData(nil)
            #expect(view.pagingLayers().values.isEmpty)
        }
    }

    @Test func verticalAndMiniBarsRetainTheirUnitsAndLayout() async throws {
        try await withFixture { settings, defaults in
            let view = panel(XRGMemoryMiner(pageSize: 4096, source: { sample() }), settings: settings, defaults: defaults)
            let rects = view.statusRects(in: NSRect(x: 0, y: 0, width: 200, height: 100), mini: false)
            #expect(rects.paging == NSRect(x: 0, y: 0, width: 181, height: 100))
            #expect(rects.ram == [NSRect(x: 183, y: 0, width: 8, height: 40),
                                  NSRect(x: 183, y: 40, width: 8, height: 20),
                                  NSRect(x: 183, y: 60, width: 8, height: 30)])
            #expect(rects.swap == NSRect(x: 192, y: 0, width: 8, height: 12.5))
            let mini = view.statusRects(in: NSRect(x: 10, y: 20, width: 200, height: 10), mini: true)
            #expect(mini.ram[0] == NSRect(x: 10, y: 24, width: 80, height: 6))
            #expect(mini.swap == NSRect(x: 10, y: 20, width: 20, height: 3))
            view.setFrameSize(NSSize(width: 200, height: 10))
            #expect(view.graphLabels.leftLabel.accessibilityValue() == "Mem")
            #expect(view.graphLabels.rightLabel.accessibilityValue() == "1M Vu")
        }
    }

    @Test func zeroSwapExtremeCountersAndCollapsedBarsStayFinite() async throws {
        try await withFixture { settings, defaults in
            var next = sample()
            next.free = .max; next.active = .max; next.inactive = .max; next.wired = .max
            next.usedSwap = .max; next.totalSwap = .max
            let miner = XRGMemoryMiner(pageSize: 16384, source: { next })
            let view = panel(miner, settings: settings, defaults: defaults, height: 10)
            #expect(view.graphLabels.rightLabel.accessibilityValue() == "17592186044415M Vu")
            let bounds = NSRect(x: 0, y: 0, width: 200, height: 100)
            let bars = view.statusRects(in: bounds, mini: false)
            for rect in bars.ram + [bars.swap] {
                #expect(rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite)
                #expect(bounds.contains(rect))
            }
            next.usedSwap = 0; next.totalSwap = 0
            view.graphUpdate(nil)
            #expect(view.statusRects(in: bounds, mini: false).swap.isEmpty)
            for height: CGFloat in [0, 1, 2, 3] {
                let rects = view.statusRects(in: NSRect(x: 0, y: 0, width: 4, height: height), mini: true)
                #expect(rects.ram.allSatisfy { $0.size.width >= 0 && $0.size.height >= 0 })
                #expect(rects.swap.size.height >= 0)
            }
        }
    }

    @Test func boundedHistoryAndResetKeepTheLatestMemorySnapshot() async throws {
        try await withFixture { settings, defaults in
            var next: XRGMemorySnapshot? = sample()
            let miner = XRGMemoryMiner(pageSize: 4096, source: { next })
            let view = panel(miner, settings: settings, defaults: defaults)
            #expect(miner.faultData().numValues == 181)
            next?.faults += 10; view.graphUpdate(nil)
            #expect(miner.faultData().max == 10)
            next = nil; view.graphUpdate(nil)
            #expect(miner.faultData().max == 10)
            view.clearData(nil)
            #expect(miner.faultData().max == 0 && miner.recentFaults() == 0)
            #expect(view.fullReading().contains("Vu: 1.00M"))
            view.setGraphSize(NSSize(width: CGFloat.greatestFiniteMagnitude, height: 10))
            #expect(miner.faultData().numValues == 19_981)
            view.setWidth(18)
            #expect(miner.faultData().numValues == 19_981)
            view.setGraphSize(NSSize(width: CGFloat.nan, height: 0))
            #expect(miner.faultData().numValues == 4)
            view.setFrameSize(.zero)
            #expect(view.graphLabels.leftLabel.frame.size == .zero)
        }
    }

    @Test func processMenuKeepsSortOrderUnitsAndExplicitActions() async throws {
        try await withFixture { settings, defaults in
            let records = XRGProcessMiner.parse("0 1 1 1 - u Tiny\n0 2 1025 1 - u Medium\n0 3 5000000000 1 - u Big")
            let processes = XRGProcessMiner(source: { records })
            await processes.refresh()
            let host = MemoryHost(settings: settings)
            defer { host.close() }
            let miner = XRGMemoryMiner(pageSize: 4096, source: { sample() })
            let view = panel(miner, settings: settings, defaults: defaults, processMiner: processes)
            host.contentView?.addSubview(view); view.awakeFromNib()
            let menu = view.makeMenu()
            #expect(menu.items.count == 8)
            #expect(menu.items[1].title == "4768.4G - Big (id 3)")
            #expect(menu.items[2].title == "1.0M - Medium (id 2)")
            #expect(menu.items[3].title == "1K - Tiny (id 1)")
            let reset = try #require(menu.items.first { $0.title == "Reset Graph" })
            #expect(reset.target === view)
            #expect(NSApp.sendAction(try #require(reset.action), to: reset.target, from: reset))
            let preferences = try #require(menu.items.last)
            #expect(preferences.target === view)
            #expect(NSApp.sendAction(try #require(preferences.action), to: preferences.target, from: preferences))
            #expect(host.preferencesOpened == 1)
            view.removeFromSuperview()
        }
    }

    @Test func processMenuHandlesEmptyAndMoreThanTenResults() async throws {
        try await withFixture { settings, defaults in
            let records = (1...12).map { index in
                XRGProcessRecord(cpu: 0, pid: index, resident: UInt64(index), virtual: 0, swaps: 0, user: "fixture", command: "Process\(index)")
            }
            let processes = XRGProcessMiner(source: { records })
            await processes.refresh()
            let view = panel(XRGMemoryMiner(pageSize: 4096, source: { sample() }), settings: settings, defaults: defaults, processMiner: processes)
            let menu = view.makeMenu()
            #expect(menu.items.count == 15)
            #expect(menu.items[1].title.contains("Process12"))
            #expect(menu.items[10].title.contains("Process3"))
            let empty = panel(XRGMemoryMiner(pageSize: 4096, source: { nil }), settings: settings, defaults: defaults)
            #expect(empty.makeMenu().items.count == 5)
            #expect(XRGMemoryView.processMemoryText(1024) == "1024K")
            #expect(XRGMemoryView.processMemoryText(1_048_576) == "1024.0M")
        }
    }

    @Test(arguments: ["MemoryView", "LegacyMemory"])
    func currentAndLegacyNibArchivesInstantiateTheSwiftPanel(name: String) async throws {
        try await withFixture { _, _ in
            let nib = try #require(NSNib(nibNamed: NSNib.Name(name), bundle: Bundle(for: MemoryNibOwner.self)))
            var objects: NSArray?
            #expect(nib.instantiate(withOwner: MemoryNibOwner(), topLevelObjects: &objects))
            let view = try #require(objects?.compactMap { $0 as? XRGMemoryView }.first)
            #expect(view.subviews.count == 3 && view.module == nil)
            #expect(view.frame.size == NSSize(width: 76, height: 76))
            withExtendedLifetime(objects) {}
        }
    }

    @Test func pagingAndMiniRenderingUseTheExpectedMode() async throws {
        try await withFixture { settings, defaults in
            let miner = XRGMemoryMiner(pageSize: 4096, source: { sample() })
            let view = panel(miner, settings: settings, defaults: defaults)
            miner.faultData().setAllValues(12); miner.pageInData().setAllValues(3); miner.pageOutData().setAllValues(5)
            let paging = try png(view)
            settings.showMemoryPagingGraph = false
            #expect(try png(view) != paging)
            view.setFrameSize(NSSize(width: 200, height: 10))
            settings.graphStyle = 0
            let mini = try png(view)
            settings.graphStyle = 1
            #expect(try png(view) == mini)
        }
    }

    @Test func mouseEventsStillReachTheWindow() async throws {
        try await withFixture { settings, defaults in
            let host = MemoryHost(settings: settings)
            defer { host.close() }
            let view = panel(XRGMemoryMiner(pageSize: 4096, source: { sample() }), settings: settings, defaults: defaults)
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
