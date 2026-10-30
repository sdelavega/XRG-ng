// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import Testing
@testable import XRGCore

@Suite(.serialized) @MainActor
struct XRGHardwareGraphTests {
    @Test func vramAndFanRetentionHaveIndependentCapacitiesAndCachedReadings() throws {
        try withSettings { defaults, settings in
            var values = [XRGHardwareReading(id:"a",name:"GPU",value:25,capacity:100)], calls = 0, failed = false
            let view = XRGHardwareGraphView(kind:.vram,frame:NSRect(x:0,y:0,width:120,height:90),settings:settings,defaults:defaults,source:{calls += 1; return failed ? .failure(NSError(domain:"fixture",code:1)) : .success(values)})
            view.graphUpdate(nil); let reads = calls
            let option = NSMenuItem(); option.tag = 300; view.selectHistory(option)
            #expect(calls == reads && view.curve("a").count == 300 && view.curve("a").last == 25)
            #expect(view.curve("a").first == XRGGraphRenderer.missingValue)
            view.setFrameSize(NSSize(width:60,height:90)); #expect(calls == reads && view.curve("a").count == 300)
            let fans = XRGHardwareGraphView(kind:.fans,frame:NSRect(x:0,y:0,width:80,height:90),settings:settings,defaults:defaults,source:{.success([XRGHardwareReading(id:"f",name:"Fan",value:1000)])})
            fans.graphUpdate(nil); #expect(fans.retainedSamples == 0 && fans.curve("f").count == 80)
            option.tag = 600; fans.selectHistory(option)
            #expect(fans.retainedSamples == 600 && fans.curve("f").count == 600 && fans.curve("f").last == 1000)
            #expect(fans.curve("f").first == XRGGraphRenderer.missingValue && view.retainedSamples == 300)
            fans.setFrameSize(NSSize(width: 40, height: 90)); #expect(fans.curve("f").count == 600)
            let fanMenu = try #require(fans.makeMenu().items.first { $0.title == "Fans History" }?.submenu)
            #expect(fanMenu.items.allSatisfy { $0.target === fans })
            failed = true; view.graphUpdate(nil); failed = false
            values = [XRGHardwareReading(id:"a",name:"Replacement",value:10,capacity:50)]; view.graphUpdate(nil)
            #expect(view.curve("a").count == 300 && view.curve("a").last == 20)
            #expect(view.curve("a").dropLast().allSatisfy { $0 == XRGGraphRenderer.missingValue })
            let restored = XRGHardwareGraphView(kind:.vram,frame:NSRect(x:0,y:0,width:120,height:90),settings:settings,defaults:defaults,source:{.success(values)})
            restored.graphUpdate(nil); #expect(restored.retainedSamples == 300 && restored.curve("a").count == 300)
            option.tag = 20001; restored.selectHistory(option); #expect(restored.retainedSamples == 300)
            option.tag = 0; restored.selectHistory(option); #expect(restored.curve("a").count == 120)
        }
    }
    @Test func vramTimeWindowsKeepPoolUnitsGapsAndCachedSourceEditsIndependent() throws {
        try withSettings { defaults, settings in
            settings.graphRefresh=1
            var wall=100.0,calls=0
            var values=[XRGHardwareReading(id:"a",name:"Pool",value:50,capacity:100)]
            let view=XRGHardwareGraphView(kind:.vram,frame:NSRect(x:0,y:0,width:200,height:100),settings:settings,defaults:defaults,historyClock:{wall},source:{calls+=1;return .success(values)})
            view.graphUpdate(nil);wall=110;values=[XRGHardwareReading(id:"a",name:"Pool",value:0,capacity:100)];view.graphUpdate(nil)
            let before=calls,option=NSMenuItem();option.tag=1;view.selectHistoryWindow(option)
            #expect(view.curve("a").count==61 && view.curve("a")[50]==50 && view.curve("a").last==0)
            #expect(view.curve("a")[51..<60].allSatisfy { $0==XRGGraphRenderer.missingValue })
            view.setFrameSize(NSSize(width:1,height:100));#expect(calls==before && view.curve("a")[50]==50)
            settings.graphRefresh=0.2;#expect(view.curve("a").count==301)
            let menu=try #require(view.makeMenu().items.first { $0.title=="VRAM Time Window" }?.submenu);#expect(menu.items.allSatisfy { $0.target===view })
            option.tag=61;view.selectHistoryWindow(option);#expect(view.historyMinutes==1)
            view.clearData(nil);#expect(view.curve("a").allSatisfy { $0==XRGGraphRenderer.missingValue } && calls==before)
            wall=111;values=[XRGHardwareReading(id:"a",name:"Allocation",value:25,capacity:nil)];view.graphUpdate(nil)
            #expect(!view.percentage && view.curve("a").last==25 && view.curve("a").dropLast().allSatisfy { $0==XRGGraphRenderer.missingValue })
            wall=112;values=[XRGHardwareReading(id:"a",name:"Pool",value:10,capacity:50)];view.graphUpdate(nil)
            #expect(view.percentage && view.curve("a").last==20 && view.curve("a").dropLast().allSatisfy { $0==XRGGraphRenderer.missingValue })
            option.tag=300;view.selectHistory(option);#expect(view.historyMinutes==0 && view.curve("a").count==300)
            let fans=XRGHardwareGraphView(kind:.fans,frame:NSRect(x:0,y:0,width:200,height:100),settings:settings,defaults:defaults,source:{.success([])})
            option.tag=5;fans.selectHistoryWindow(option);#expect(fans.historyMinutes==5 && defaults.integer(forKey:XRGHardwareGraphView.windowKey)==0)
            #expect(!fans.makeMenu().items.contains { $0.title=="VRAM Time Window" })
        }
    }
    @Test func fanWindowsKeepStoppedReadingsAndVRAMSettingsIndependent() throws {
        try withSettings { defaults, settings in
            settings.graphRefresh=1;defaults.set(7,forKey:XRGHardwareGraphView.windowKey)
            var wall=100.0,rpm=1000.0,calls=0,failed=false
            let view=XRGHardwareGraphView(kind:.fans,frame:NSRect(x:0,y:0,width:200,height:100),settings:settings,defaults:defaults,historyClock:{wall},source:{calls+=1;return failed ? .failure(NSError(domain:"fixture",code:1)) : .success([XRGHardwareReading(id:"fan",name:"Fan",value:rpm)])})
            view.graphUpdate(nil);wall=110;rpm=0;view.graphUpdate(nil)
            let before=calls,option=NSMenuItem();option.tag=1;view.selectHistoryWindow(option)
            #expect(view.curve("fan").count==61 && view.curve("fan")[50]==1000 && view.curve("fan").last==0)
            #expect(view.curve("fan")[51..<60].allSatisfy { $0==XRGGraphRenderer.missingValue })
            view.setFrameSize(NSSize(width:1,height:100));#expect(view.curve("fan")[50]==1000 && calls==before)
            settings.graphRefresh=0.2;#expect(view.curve("fan").count==301)
            #expect(defaults.integer(forKey:XRGHardwareGraphView.windowKey)==7)
            let menu=try #require(view.makeMenu().items.first { $0.title=="Fans Time Window" }?.submenu);#expect(menu.items.allSatisfy { $0.target===view })
            option.tag=61;view.selectHistoryWindow(option);#expect(view.historyMinutes==1)
            view.clearData(nil);#expect(view.curve("fan").allSatisfy { $0==XRGGraphRenderer.missingValue } && calls==before)
            wall=111;rpm=500;view.graphUpdate(nil)
            wall=112;failed=true;view.graphUpdate(nil);#expect(view.curve("fan").isEmpty)
            wall=113;failed=false;view.graphUpdate(nil);#expect(view.curve("fan").dropLast().allSatisfy { $0==XRGGraphRenderer.missingValue })
            option.tag=300;view.selectHistory(option);#expect(view.historyMinutes==0 && view.curve("fan").count==300 && defaults.integer(forKey:XRGHardwareGraphView.windowKey)==7)
        }
    }
    private func withSettings(_ body: (UserDefaults, XRGSettings) throws -> Void) throws {
        _ = NSApplication.shared
        let name = "XRG.hardware-graphs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let settings = XRGSettings(defaults: defaults)
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .blue
        try body(defaults, settings)
    }
    @Test func gpuPoolAndUnifiedAllocationProjectionNeverInventCapacity() throws {
        func read(_ stats: [String: Any], _ extra: [String: Any] = [:]) -> XRGHardwareReading? {
            var accelerator = extra; accelerator["PerformanceStatistics"] = stats
            return XRGHardwareReading.gpuMemory(id: 1, vendor: "Apple", pci: [:], accelerator: accelerator)
        }
        let pool = try #require(read(["vramUsedBytes": 0], ["VRAM,totalMB": 1]))
        #expect(pool.value == 0 && pool.capacity == 1_048_576)
        let allocation = try #require(read(["Alloc system memory": 1000, "In use system memory": 25]))
        #expect(allocation.value == 25 && allocation.capacity == nil && allocation.note.contains("unified"))
        #expect(read(["Alloc system memory": 1000]) == nil)
        #expect(read(["gartSizeBytes": 1000, "gartUsedBytes": 50]) == nil)
        #expect(read(["vramUsedBytes": true]) == nil)
        #expect(read(["vramUsedBytes": Double.nan]) == nil)
        #expect(read(["vramUsedBytes": 2_000_000], ["VRAM,totalMB": 1]) == nil)
        #expect(read(["vramUsedBytes": 10, "vramFreeBytes": 20], ["VRAM,totalMB": 1]) == nil)
        #expect(read(["vramFreeBytes": 0], ["VRAM,totalMB": 1])?.value == 1_048_576)
    }
    @Test func sharedGraphicsTickCoalescesReadsAndFailureDoesNotExposeStaleMemory() throws {
        var calls = 0, failed = false
        let miner = XRGGPUMiner(source: {
            calls += 1
            return failed ? nil : [XRGGPUSample(id: 1, vendor: "Fixture", total: 100, free: 50, wait: 0, utilization: 0,
                memoryReading: XRGHardwareReading(id: "1", name: "GPU", value: 50, capacity: 100))]
        })
        #expect(calls == 1)
        miner.refreshForGraphTick(1); miner.refreshForGraphTick(1); #expect(calls == 2)
        failed = true; miner.refreshForGraphTick(2); #expect(calls == 3)
        if case .success = miner.memorySnapshot { Issue.record("Failed reads exposed stale memory") }
        #expect(miner.totalVRAMDataSets.count == 1) // Legacy integrated display remains compatible.
        miner.refreshForGraphTick(2); #expect(calls == 3)
    }
    @Test func fanZeroMissingReplacementAndResetKeepHonestCurvesAndStableSlots() throws {
        try withSettings { defaults, settings in
            var values = [XRGHardwareReading(id: "a", name: "Fan A", value: 0), XRGHardwareReading(id: "b", name: "Fan B", value: 1200)]
            var calls = 0
            let view = XRGHardwareGraphView(kind: .fans, frame: NSRect(x: 0, y: 0, width: 120, height: 90), settings: settings, defaults: defaults, source: { calls += 1; return .success(values) })
            #expect(calls == 0)
            view.graphUpdate(nil)
            #expect(calls == 1)
            #expect(view.curve("a").last == 0 && view.curve("a").dropLast().allSatisfy { $0 == XRGGraphRenderer.missingValue })
            #expect(view.detailText.contains("0 RPM"))
            values = [XRGHardwareReading(id: "b", name: "Fan B", value: 1300)]
            view.graphUpdate(nil)
            #expect(view.curve("a").isEmpty && view.labels.leftLabel.fullAccessibilityText?.contains("2: Fan B") == true)
            #expect(view.curve("b").suffix(2) == [1200, 1300])
            view.clearData(nil)
            #expect(view.curve("b").allSatisfy { $0 == XRGGraphRenderer.missingValue })
            #expect(view.readings[0].value == 1300)
            values = []; view.graphUpdate(nil)
            #expect(view.readings.isEmpty && view.curve("b").isEmpty && view.status.contains("No readable"))
            values = [XRGHardwareReading(id: "b", name: "Replacement", value: 900)]; view.graphUpdate(nil)
            #expect(view.curve("b").dropLast().allSatisfy { $0 == XRGGraphRenderer.missingValue })
        }
    }
    @Test func fanPanelReusesTheTemperatureCollectorsCacheAndDoesNotInferTargetSpeeds() {
        let reader = HardwareFanReader(); var time = 1.0
        let miner = XRGTemperatureMiner(reader: reader, clock: { time })
        let first = miner.fanGraphReadings()
        #expect(first.first?.value == 0 && first.first?.capacity == nil)
        miner.updateCurrentTemperatures(true); #expect(reader.reads == 1)
        reader.values = [:]; time = 2.1
        #expect(miner.fanGraphReadings().isEmpty && reader.reads == 2)
    }
    @Test func memoryAxisChangesClearHistoryAndOverridesRemainPerGraph() throws {
        try withSettings { defaults, settings in
            var values = [XRGHardwareReading(id: "1", name: "GPU", value: 50, capacity: 100)]
            let view = XRGHardwareGraphView(kind: .vram, frame: NSRect(x: 0, y: 0, width: 120, height: 90), settings: settings, defaults: defaults, source: { .success(values) })
            view.graphUpdate(nil); #expect(view.percentage && view.curve("1").last == 50)
            #expect(view.valueText(XRGHardwareReading(id: "1", name: "GPU", value: 5.94 * 1_073_741_824, capacity: 16 * 1_073_741_824)) == "5.9G/16G")
            values = [XRGHardwareReading(id: "1", name: "GPU", value: 200)]
            view.graphUpdate(nil)
            #expect(!view.percentage && view.heading == "GPU allocations" && view.curve("1").last == 200)
            #expect(view.curve("1").dropLast().allSatisfy { $0 == XRGGraphRenderer.missingValue })
            var prefs = XRGGraphPreferences(); prefs[.vram].colors[1] = [1, 0, 0, 0.5]
            try settings.applyGraphPreferences(prefs)
            #expect(settings.graphColor(.vram, component: 1).alphaComponent == 0.5)
            #expect(settings.graphColor(.gpu, component: 1) == .blue)
            view.setGraphSize(NSSize(width: 32, height: 80)); #expect(view.curve("1").count == 32)
            view.setFrameSize(NSSize(width: 140, height: 8))
            #expect(view.labels.rightLabel.stringValue == "200B")
            values = []; view.graphUpdate(nil)
            #expect(view.labels.rightLabel.stringValue == "n/a")
        }
    }
    @Test func legacyElevenGraphOrderIsExtendedWithoutRewritingSavedPreferences() throws {
        try withSettings { defaults, _ in
            var original = XRGGraphPreferences(); original.order = Array(XRGGraphPreferences.legacyIDs.reversed())
            original[.cpu].height = 128
            let data = try JSONEncoder().encode(original); defaults.set(data, forKey: XRGGraphPreferences.key)
            let loaded = XRGSettings(defaults: defaults).graphPreferences
            #expect(loaded.order?.prefix(11) == original.order?.prefix(11))
            #expect(loaded.order?.suffix(2) == [.vram, .fans] && loaded[.cpu].height == 128)
            #expect(defaults.data(forKey: XRGGraphPreferences.key) == data)
        }
    }
    @Test func aNewHardwarePlotDoesNotFillMissingHistoryWithAFabricatedRamp() throws {
        try withSettings { defaults, settings in
            settings.graphBGTransparency = 1; settings.graphBGColor = .black; settings.graphStyle = 0
            let view = XRGHardwareGraphView(kind: .vram, frame: NSRect(x: 0, y: 0, width: 120, height: 90), settings: settings, defaults: defaults,
                source: { .success([XRGHardwareReading(id: "1", name: "GPU", value: 50, capacity: 100)]) })
            view.graphUpdate(nil)
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 90, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context; view.draw(view.bounds)
            let pixel = try #require(bitmap.colorAt(x: 60, y: 10)?.usingColorSpace(.sRGB))
            #expect(pixel.redComponent < 0.01 && pixel.greenComponent < 0.01 && pixel.blueComponent < 0.01)
        }
    }
    @Test func optionalGraphsRegisterPersistRestoreAndShareGPUReadsThroughTheLiveWindow() throws {
        let domain = "XRG.hardware-lifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain)); defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: "checkForUpdates")
        for id in XRGGraphID.allCases where id != .vram && id != .fans { defaults.set(true, forKey: id.visibilityKey) }
        let scene = try XRGApplicationSmokeScene(defaults: defaults, resources: Bundle(for: XRGAppDelegate.self)); defer { scene.shutdown() }
        scene.delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(scene.window.moduleManager?.moduleList().count == 13)
        #expect(scene.window.vramView?.module?.isDisplayed == false && scene.window.fansView?.module?.isDisplayed == false)
        scene.delegate.showPrefs(nil); let pref = try #require(scene.delegate.prefController)
        let editor = try #require(pref.graphsEditor)
        for id in [XRGGraphID.vram, .fans] {
            let index = try #require(editor.draft.orderedIDs.firstIndex(of: id))
            let button = try #require(editor.table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSButton)
            button.state = .on; #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
        }
        #expect(editor.apply(nil))
        let before = scene.inputs.gpuReads
        scene.inputs.time += 6; scene.window.graphUpdate(nil)
        #expect(scene.inputs.gpuReads == before + 1)
        #expect(scene.window.vramView?.readings.count == 1 && scene.window.fansView?.readings.first?.value == 1200)
        #expect(scene.window.moduleManager?.displayList().prefix(5).compactMap(\.name) == ["CPU", "GPU", "NPU", "VRAM", "Memory"])
        #expect(pref.persistPreferences() && defaults.bool(forKey: "showVRAMGraph") && defaults.bool(forKey: "showFansGraph"))
        scene.window.moduleManager?.setModule("GPU", isDisplayed: false)
        let hidden = scene.inputs.gpuReads; scene.inputs.time += 6; scene.window.graphUpdate(nil)
        #expect(scene.inputs.gpuReads == hidden + 1)
        #expect(scene.window.vramView?.readings.count == 1)
        let reopened = XRGGraphWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 500), defaults: defaults)
        reopened.initializeHardwareViews(vram: { .success([]) }, fans: { .success([]) })
        #expect(reopened.vramView?.module?.isDisplayed == true && reopened.fansView?.module?.isDisplayed == true)
        reopened.close()
    }
}

@MainActor private final class HardwareFanReader: NSObject, XRGTemperatureReader {
    var reads = 0
    var values: [String: Any] = ["F99": ["F99Ac": 0, "F99Tg": 5000, "F99Mx": 6000]]
    var knownTemperatureKeyCount: Int { 20 }
    func temperatures(includingUnknown: Bool) -> [String: Any] { [:] }
    func siliconTemperatures() -> [String: Any] { [:] }
    func fanReadings() -> [String: Any] { reads += 1; return values }
    func name(forKey key: String) -> String? { "Fixture Fan 99" }
    func isKnownKey(_ key: String) -> Bool { true }
}
