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
private final class GPUHost: NSWindow, XRGGPUViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var gpuView: XRGGPUView?
    var minimized = false
    var borderWidth: Int32 = 2
    var timerRequests = 0
    var sizeChecks = 0
    var mouseEvents: [String] = []
    init(settings: XRGSettings) {
        appSettings = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        moduleManager = XRGModuleManager(window: self)
    }
    func initTimers() { timerRequests += 1 }
    func checkWindowSize() { sizeChecks += 1 }
    override func mouseDown(with event: NSEvent) { mouseEvents.append("down") }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}

private final class GPUNibOwner: NSObject {}

@Suite(.serialized) @MainActor
struct XRGGPUViewTests {
    private func withFixture(_ body: (XRGSettings, UserDefaults) throws -> Void) throws {
        _ = NSApplication.shared
        let domain = "XRG.gpuView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "showGPUGraph")
        let settings = XRGSettings(defaults: defaults)
        settings.graphFont = NSFont.systemFont(ofSize: 10)
        settings.textTransparency = 1; settings.textColor = .black
        settings.graphBGTransparency = 1; settings.graphBGColor = .white
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        try body(settings, defaults)
    }
    private func sample(_ id: UInt64 = 1, vendor: String = "Apple", totalMB: Double? = 8,
                        freeMB: Double? = 6, utilization: Double? = 0, wait: Double? = nil) -> XRGGPUSample {
        XRGGPUSample(id: id, vendor: vendor, total: totalMB.map { $0 * 1_048_576 },
                     free: freeMB.map { $0 * 1_048_576 }, wait: wait, utilization: utilization)
    }
    private func panel(_ miner: XRGGPUMiner, settings: XRGSettings, defaults: UserDefaults,
                       width: CGFloat = 200, height: CGFloat = 100) -> XRGGPUView {
        XRGGPUView(frame: NSRect(x: 0, y: 0, width: width, height: height),
                   miner: miner, settings: settings, defaults: defaults)
    }

    private func checkDecodedLabelOwnership(_ view: XRGGPUView) throws {
        // Decoded production views discover the host's GPUs; their count is not a fixture.
        let groups = view.cardLabels
        #expect(!groups.isEmpty)
        let labels = groups.flatMap { [$0.leftLabel, $0.centerLabel, $0.rightLabel] }
        let identities = Set(labels.map(ObjectIdentifier.init))
        #expect(identities.count == groups.count * 3)
        #expect(view.subviews.count == labels.count)
        #expect(Set(view.subviews.map(ObjectIdentifier.init)) == identities)
        view.awakeFromNib(); view.awakeFromNib(); view.setFrameSize(view.frame.size)
        #expect(view.cardLabels.count == groups.count)
        #expect(zip(view.cardLabels, groups).allSatisfy { $0 === $1 })
        #expect(view.subviews.count == labels.count)
        #expect(Set(view.subviews.map(ObjectIdentifier.init)) == identities)
    }

    @Test func nibRegistrationIsIdempotentAndDetachRemovesItsModule() throws {
        try withFixture { settings, defaults in
            let host = GPUHost(settings: settings)
            defer { host.close() }
            let view = panel(XRGGPUMiner(source: { [sample()] }), settings: settings, defaults: defaults)
            host.contentView?.addSubview(view)
            #expect(host.gpuView == nil)
            view.awakeFromNib(); view.awakeFromNib()
            let module = try #require(view.module)
            #expect(module.name == "GPU" && module.displayOrder == 1)
            #expect(module.isDisplayed && module.doesGraphUpdate && !module.doesFastUpdate)
            #expect(module.reference === view)
            #expect(host.gpuView === view)
            #expect(host.moduleManager?.moduleList().count == 1)
            #expect(host.timerRequests == 1)
            #expect(view.subviews.count == 3)
            view.removeFromSuperview()
            #expect(host.gpuView == nil)
            #expect(host.moduleManager?.moduleList().isEmpty == true)
            #expect(view.module == nil)
        }
    }

    @Test func visibilityAndFontChangesUseExistingDefaultsAndModuleSizing() throws {
        try withFixture { settings, defaults in
            defaults.set(false, forKey: "showGPUGraph")
            let host = GPUHost(settings: settings)
            defer { host.close() }
            let view = panel(XRGGPUMiner(source: { [sample()] }), settings: settings, defaults: defaults)
            host.contentView?.addSubview(view); view.awakeFromNib()
            let module = try #require(view.module)
            #expect(!module.isDisplayed)
            let oldWidth = module.minWidth, oldHeight = module.minHeight
            settings.graphFont = NSFont.systemFont(ofSize: 28)
            view.updateMinSize()
            #expect(module.minWidth > oldWidth && module.minHeight > oldHeight)
            host.moduleManager?.setModule("GPU", isDisplayed: true)
            #expect(module.isDisplayed)
            view.removeFromSuperview()
        }
    }

    @Test func fullViewShowsMemoryVendorAndAValidZeroUtilization() throws {
        try withFixture { settings, defaults in
            let view = panel(XRGGPUMiner(source: { [sample()] }), settings: settings, defaults: defaults)
            let labels = try #require(view.cardLabels.first)
            #expect(labels.leftLabel.accessibilityValue() == "GPU\nApple")
            #expect(labels.rightLabel.accessibilityValue() == "2.00M / 8.00M\n0%")
            view.setFrameSize(NSSize(width: 100, height: 100))
            #expect(labels.rightLabel.accessibilityValue() == "2.00M\n0%")
        }
    }

    @Test func missingMemoryDoesNotHideUtilizationAndCPUWaitUsesLegacyUnits() throws {
        try withFixture { settings, defaults in
            let miner = XRGGPUMiner(source: { [sample(totalMB: nil, freeMB: nil, utilization: 25)] })
            let view = panel(miner, settings: settings, defaults: defaults)
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "n/a\n25%")
            for (value, expected) in [(999.0, "999 ns"), (1000, "1 µs"), (1_999_999, "1 ms"),
                (1_000_000, "1 ms"), (1_000_000_000, "1 s"), (-1, "")] {
                #expect(XRGGPUView.waitText(value) == expected)
            }
            #expect(XRGGPUView.waitText(.infinity) == "")
            let waiting = panel(XRGGPUMiner(source: { [sample(utilization: nil, wait: 2000)] }), settings: settings, defaults: defaults)
            #expect(waiting.cardLabels[0].rightLabel.accessibilityValue() == "2.00M / 8.00M\n2 µs")
        }
    }

    @Test func multipleGPUsHaveSeparateBandsAndRemovalClearsOldLabels() throws {
        try withFixture { settings, defaults in
            var samples: [XRGGPUSample]? = [sample(), sample(2, vendor: "AMD", utilization: 40)]
            let view = panel(XRGGPUMiner(source: { samples }), settings: settings, defaults: defaults, height: 200)
            #expect(view.cardLabels.count == 2)
            #expect(view.cardLabels[0].leftLabel.accessibilityValue() == "GPU 1\nApple")
            #expect(view.cardLabels[1].leftLabel.accessibilityValue() == "GPU 2\nAMD")
            #expect(view.cardLabels[0].leftLabel.frame.minY > view.cardLabels[1].leftLabel.frame.maxY)
            let removedLabel = view.cardLabels[1].leftLabel
            samples = [sample()]; view.graphUpdate(nil)
            #expect(view.cardLabels.count == 1)
            #expect(removedLabel.superview == nil)
            #expect(view.cardLabels[0].leftLabel.accessibilityValue() == "GPU\nApple")
            samples = []; view.graphUpdate(nil)
            #expect(view.cardLabels[0].leftLabel.accessibilityValue() == "GPU")
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "n/a")
        }
    }

    @Test func miniViewAggregatesMemoryAndHandlesUnavailableReadings() throws {
        try withFixture { settings, defaults in
            var samples: [XRGGPUSample]? = [sample(), sample(2, vendor: "AMD", totalMB: 16, freeMB: 12)]
            let view = panel(XRGGPUMiner(source: { samples }), settings: settings, defaults: defaults, height: 10)
            #expect(view.cardLabels.count == 1)
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "6M")
            samples = [sample(), sample(2, totalMB: nil, freeMB: nil)]
            view.graphUpdate(nil)
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "n/a")
        }
    }

    @Test func resizingBoundsHistoryAndFailedPollsShowUnavailable() throws {
        try withFixture { settings, defaults in
            var samples: [XRGGPUSample]? = [sample(utilization: 30)]
            let miner = XRGGPUMiner(source: { samples })
            let view = panel(miner, settings: settings, defaults: defaults)
            view.setGraphSize(NSSize(width: CGFloat.nan, height: 0))
            #expect(miner.numSamples == 23)
            view.setGraphSize(NSSize(width: 50_000, height: 20))
            #expect(miner.numSamples == 20_000)
            view.setWidth(-1)
            #expect(miner.numSamples == 20_000)
            view.setFrameSize(NSSize(width: 0, height: 0))
            #expect(miner.numSamples == 23)
            #expect(view.cardLabels[0].leftLabel.frame.size == .zero)
            samples = nil; view.graphUpdate(nil)
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "n/a")
            #expect(miner.utilizationDataSets[0].currentValue == XRGGraphRenderer.missingValue)
        }
    }

    @Test func selectedGPUPersistsByLocationAndMissingPinsNeverChooseAnotherCard() throws {
        try withFixture { settings, defaults in
            var card = sample(2, vendor: "AMD", utilization: 40); card.sourceID = "IOService:/fixtureGPU"
            var samples = [sample(), card], reads = 0
            let miner = XRGGPUMiner(source: { reads += 1; return samples })
            let view = panel(miner, settings: settings, defaults: defaults)
            let count = reads, history = miner.utilizationDataSets[1]
            try view.applyGPUSource(card.selectionID)
            #expect(reads == count && view.cardLabels.count == 1)
            #expect(view.cardLabels[0].leftLabel.accessibilityValue() == "GPU 2\nAMD")
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "2.00M / 8.00M\n40%")
            #expect(miner.utilizationDataSets[1] === history)
            let restored = panel(miner, settings: settings, defaults: defaults)
            #expect(restored.selectedSource == card.selectionID)
            samples = [sample()]; view.graphUpdate(nil)
            #expect(view.selectedSource == card.selectionID)
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "Selected GPU unavailable")
            #expect(view.makeMenu().items[0].submenu?.items.last?.state == .on)
            var replaced = sample(3, vendor: "AMD", utilization: 70); replaced.sourceID = card.sourceID
            samples = [sample(), replaced]; view.graphUpdate(nil)
            #expect(view.cardLabels[0].rightLabel.accessibilityValue()?.contains("70%") == true)
            #expect(miner.utilizationDataSets[1] !== history)
        }
    }

    @Test func utilizationModeUsesReportedPercentAndNeverWaitOrMemoryAsUtilization() throws {
        try withFixture { settings, defaults in
            let miner = XRGGPUMiner(source: { [sample(utilization: 50), sample(2, utilization: 0)] })
            let view = panel(miner, settings: settings, defaults: defaults)
            view.applyPlotMode(.utilization)
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "50%")
            view.setFrameSize(NSSize(width: 200, height: 10))
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "25%")
            try view.applyGPUSource("ioreg-id:2")
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "0%")
            let restored = panel(miner, settings: settings, defaults: defaults)
            #expect(restored.plotMode == .utilization && restored.selectedSource == "ioreg-id:2")
            let unsupported = panel(XRGGPUMiner(source: { [sample(2, utilization: nil, wait: 1000)] }), settings: settings, defaults: defaults)
            #expect(unsupported.cardLabels[0].rightLabel.accessibilityValue() == "n/a")
            #expect(unsupported.detailText.contains("never substitutes"))
        }
    }

    @Test func resetOnlySelectedGPUHistoryAndKeepReadoutsAndVRAMSnapshot() throws {
        try withFixture { settings, defaults in
            let miner = XRGGPUMiner(source: { [sample(utilization: 50), sample(2, utilization: 40)] })
            let view = panel(miner, settings: settings, defaults: defaults)
            miner.getLatestGraphicsInfo()
            try view.applyGPUSource("ioreg-id:2")
            let other = miner.utilizationDataSets[0].orderedValues
            let reading = view.cardLabels[0].rightLabel.accessibilityValue()
            view.clearData(nil)
            #expect(miner.utilizationDataSets[1].orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue })
            #expect(miner.utilizationDataSets[0].orderedValues == other)
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == reading)
            #expect(try miner.memorySnapshot.get().isEmpty)
            view.applyPlotMode(.utilization)
            #expect(view.cardLabels[0].rightLabel.accessibilityValue() == "40%")
        }
    }

    @Test func invalidGPUPreferencesStayUntouchedAndMenusUseCachedInventory() throws {
        try withFixture { settings, defaults in
            let bad = Data("{\"version\":2}".utf8)
            defaults.set(bad, forKey: XRGGPUView.sourceKey); defaults.set("future", forKey: XRGGPUView.modeKey)
            defaults.set("CPU sentinel", forKey: XRGCPUView.sourceKey)
            var reads = 0
            let view = panel(XRGGPUMiner(source: { reads += 1; return [sample()] }), settings: settings, defaults: defaults)
            #expect(view.selectedSource == nil && view.plotMode == .memoryAndActivity)
            #expect(view.detailText.contains("invalid") && defaults.data(forKey: XRGGPUView.sourceKey) == bad)
            let count = reads, menu = view.makeMenu()
            let option = try #require(menu.items[0].submenu?.items[1])
            #expect(NSApp.sendAction(try #require(option.action), to: option.target, from: option))
            #expect(view.selectedSource == "ioreg-id:1" && reads == count)
            #expect(defaults.string(forKey: XRGGPUView.modeKey) == "future")
            #expect(defaults.string(forKey: XRGCPUView.sourceKey) == "CPU sentinel")
            let mode = try #require(menu.items[1].submenu?.items[1])
            #expect(NSApp.sendAction(try #require(mode.action), to: mode.target, from: mode))
            #expect(view.plotMode == .utilization && reads == count)
        }
    }

    @Test func mouseEventsStillReachTheGraphWindow() throws {
        try withFixture { settings, defaults in
            let host = GPUHost(settings: settings)
            defer { host.close() }
            let view = panel(XRGGPUMiner(source: { [] }), settings: settings, defaults: defaults)
            host.contentView?.addSubview(view); view.awakeFromNib()
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            #expect(view.acceptsFirstMouse(for: event))
            view.mouseDown(with: event); view.mouseDragged(with: event); view.mouseUp(with: event)
            #expect(host.mouseEvents == ["down", "drag", "up"])
            view.removeFromSuperview()
        }
    }

    @Test func compiledNibFragmentInstantiatesTheSwiftView() throws {
        try withFixture { _, _ in
            let nib = try #require(NSNib(nibNamed: "GPUView", bundle: Bundle(for: GPUNibOwner.self)))
            var objects: NSArray?
            #expect(nib.instantiate(withOwner: nil, topLevelObjects: &objects))
            let view = try #require(objects?.compactMap { $0 as? XRGGPUView }.first)
            try checkDecodedLabelOwnership(view)
            #expect(view.module == nil)
            #expect(view.frame.size == NSSize(width: 76, height: 76))
            #expect(NSClassFromString("XRGGPUView") === XRGGPUView.self)
            withExtendedLifetime(objects) {}
        }
    }

    @Test func legacyArchiveInstantiatesTheSwiftViewWithoutTheRestOfTheApp() throws {
        try withFixture { _, _ in
            let nib = try #require(NSNib(nibNamed: "LegacyGPU", bundle: Bundle(for: GPUNibOwner.self)))
            var objects: NSArray?
            #expect(nib.instantiate(withOwner: GPUNibOwner(), topLevelObjects: &objects))
            let view = try #require(objects?.compactMap { $0 as? XRGGPUView }.first)
            try checkDecodedLabelOwnership(view)
            #expect(view.module == nil)
            #expect(view.frame.size == NSSize(width: 76, height: 76))
            withExtendedLifetime(objects) {}
        }
    }

    @Test func fullAndMiniPanelsRenderToAppKitBitmaps() throws {
        try withFixture { settings, defaults in
            for height: CGFloat in [10, 100, 200] {
                let view = panel(XRGGPUMiner(source: { [sample(utilization: 50), sample(2, vendor: "AMD")] }),
                                 settings: settings, defaults: defaults, height: height)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                #expect(bitmap.representation(using: .png, properties: [:])?.isEmpty == false)
            }
        }
    }
}
