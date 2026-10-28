// Copyright (C) 2026 Stephen de la Vega.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing
@testable import XRGCore

@MainActor private final class NPUHost: NSWindow, XRGNPUViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var npuView: XRGNPUView?
    var minimized = false
    var borderWidth: Int32 = 2
    var timerRequests = 0
    init(settings: XRGSettings) {
        appSettings = settings
        super.init(contentRect: NSRect(x: 0,y: 0,width: 400,height: 360),styleMask: .borderless,backing: .buffered,defer: false)
        isReleasedWhenClosed = false; moduleManager = XRGModuleManager(window: self)
    }
    func initTimers() { timerRequests += 1 }
    func checkWindowSize() {}
    func showGeneralPreferences() {}
}

@Suite(.serialized) @MainActor struct XRGNPUTests {
    private let device = XRGNPUDevice(id: 1,cores: 16,architecture: "fixture",firmwareLoaded: true)
    private func reading(_ time: Double,_ value: Int64?,unit: String = "mJ",id: String = "ane") -> XRGNPUReading {
        XRGNPUReading(time: time,devices: [device],appleSilicon: true,
                      energy: value.map { [XRGNPUEnergy(id: id,unit: unit,value: $0)] },error: value == nil ? "Fixture unavailable" : nil)
    }
    @Test func discoveryMetadataDoesNotBecomeUtilizationAndRejectsMalformedCoreCounts() {
        let p = XRGNPUDevice.parse(id: 1,properties: ["FirmwareLoaded": true,"DeviceProperties": ["ANEDevicePropertyNumANECores":16,"ANEDevicePropertyTypeANEArchitectureTypeStr":"h17\n"]])
        #expect(p.cores == 16 && p.firmwareLoaded == true && p.architecture == "h17")
        for invalid in [true,-1,0,1.5,1025,"16"] as [Any] {
            #expect(XRGNPUDevice.parse(id: 2,properties: ["DeviceProperties":["ANEDevicePropertyNumANECores":invalid]]).cores == nil)
        }
        for name in ["ANE","ANE0","ANE12","ANE Energy"] { #expect(XRGNPUReader.isEnergyChannel(name)) }
        for name in ["GPU","LANE0","ANEXL","ANE SRAM","ANE0 RD","ANE²"] { #expect(!XRGNPUReader.isEnergyChannel(name)) }
    }
    @Test func energyDeltaUsesElapsedSecondsAndKeepsRealZeroAndMissingPadding() {
        var now = 1.0, sample = reading(1,1000)
        let miner = XRGNPUMiner(source: { sample },clock: { now }); miner.setDataSize(4)
        #expect(miner.powerWatts == nil)
        #expect(miner.powerDataSet.orderedValues.allSatisfy { $0 == XRGGraphRenderer.missingValue })
        now = 3; sample = reading(3,3000); miner.getLatestNPUInfo()
        #expect(miner.powerWatts == 1)
        now = 4; sample = reading(4,3000); miner.getLatestNPUInfo()
        #expect(miner.powerWatts == 0)
        #expect(Array(miner.powerDataSet.orderedValues.suffix(2)) == [1,0])
        miner.setDataSize(6)
        #expect(Array(miner.powerDataSet.orderedValues.prefix(4)) == [-1000,-1000,-1000,-1000])
        #expect(Array(miner.powerDataSet.orderedValues.suffix(2)) == [1,0])
        #expect(miner.fullReading().contains("Power: 0.000 W"))
        #expect(miner.fullReading().contains("not utilization"))
    }
    @Test func unitChangesCounterResetsAndMissingTelemetryRequireNewIntervals() {
        var now = 1.0, sample = reading(1,1000)
        let miner = XRGNPUMiner(source: { sample },clock: { now })
        now = 2;sample = reading(2,2000);miner.getLatestNPUInfo();#expect(miner.powerWatts == 1)
        now = 3;sample = reading(3,1);miner.getLatestNPUInfo();#expect(miner.powerWatts == nil)
        now = 4;sample = reading(4,1001);miner.getLatestNPUInfo();#expect(miner.powerWatts == 1)
        now = 5;sample = reading(5,nil);miner.getLatestNPUInfo();#expect(miner.powerWatts == nil)
        now = 6;sample = reading(6,2001);miner.getLatestNPUInfo();#expect(miner.powerWatts == nil)
        now = 7;sample = reading(7,3001,unit:"uJ");miner.getLatestNPUInfo();#expect(miner.powerWatts == nil)
        now = 8;sample = reading(8,1_003_001,unit:"uJ");miner.getLatestNPUInfo();#expect(miner.powerWatts == 1)
    }
    @Test func invalidOrStaleSamplesDuplicatesAndDeviceReplacementDoNotInventPower() {
        var now = 1.0, sample: XRGNPUReading? = reading(1,1000)
        let miner = XRGNPUMiner(source: { sample },clock: { now })
        now = 2;sample = reading(2,2000);miner.getLatestNPUInfo();#expect(miner.powerWatts == 1)
        sample = reading(2,9000);miner.getLatestNPUInfo();#expect(miner.powerWatts == 1)
        now = 3;sample = reading(3,3000);miner.getLatestNPUInfo();#expect(miner.powerWatts == 1)
        now = 9;sample = nil;miner.getLatestNPUInfo();#expect(miner.powerWatts == nil && miner.fullReading().contains("stale"))
        now = 10;sample = reading(10,5000);miner.getLatestNPUInfo();#expect(miner.powerWatts == nil)
        now = 11;sample = reading(11,6000,id:"replacement");miner.getLatestNPUInfo();#expect(miner.powerWatts == nil)
        for bad in [reading(.nan,7000),reading(100,7000)] {
            sample = bad;miner.getLatestNPUInfo();#expect(miner.powerWatts == nil)
        }
        now=12;sample=reading(12,-1);miner.getLatestNPUInfo();#expect(miner.powerWatts == nil)
        now=13;sample=reading(13,7000,unit:"MHz");miner.getLatestNPUInfo();#expect(miner.powerWatts == nil)
        now=14;sample=XRGNPUReading(time:14,devices:[device],appleSilicon:true,
            energy:[.init(id:"same",unit:"mJ",value:1),.init(id:"same",unit:"mJ",value:2)],error:nil)
        miner.getLatestNPUInfo();#expect(miner.powerWatts == nil)
    }
    @Test func mixedCounterUnitsSumEnergyAndIntegerDeltasStayExact() {
        var now = 1.0
        var sample = XRGNPUReading(time: 1,devices: [device],appleSilicon: true,
                                  energy: [.init(id:"a",unit:"mJ",value:Int64.max-1000),.init(id:"b",unit:"nJ",value:0)],error:nil)
        let miner = XRGNPUMiner(source: { sample },clock: { now })
        now = 2;sample = XRGNPUReading(time: 2,devices:[device],appleSilicon:true,
                                     energy:[.init(id:"a",unit:"mJ",value:Int64.max),.init(id:"b",unit:"nJ",value:1_000_000_000)],error:nil)
        miner.getLatestNPUInfo();#expect(miner.powerWatts == 2)
    }
    @Test(arguments: [true,false]) func newGraphRegistersBetweenGPUAndMemoryAndDetaches(vertical: Bool) throws {
        _ = NSApplication.shared
        let domain = "XRG.npu.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName:domain))
        defer { defaults.removePersistentDomain(forName:domain) }
        defaults.set(true,forKey:"showNPUGraph")
        let settings = XRGSettings(defaults:defaults), host = NPUHost(settings:settings)
        defer { host.contentView?.subviews.forEach { $0.removeFromSuperview() };host.close() }
        let manager = try #require(host.moduleManager);manager.graphOrientationVertical = vertical
        for (name,order) in [("Memory",3),("GPU",1)] {
            let view = NSView(frame:.zero);host.contentView?.addSubview(view)
            let module = XRGModule(name:name,reference:view,defaults:defaults);module.displayOrder=order;manager.addModule(module)
        }
        var now = 1.0, sample = reading(1,0)
        let miner = XRGNPUMiner(source:{sample},clock:{now})
        let view = XRGNPUView(frame:NSRect(x:0,y:0,width:200,height:100),miner:miner,settings:settings,defaults:defaults)
        host.contentView?.addSubview(view);view.awakeFromNib();view.awakeFromNib()
        #expect(host.npuView === view && host.timerRequests == 1)
        #expect(manager.displayList().compactMap(\.name) == ["GPU","NPU","Memory"])
        manager.windowChanged(to:host.frame.size)
        let gpu = try #require(manager.getModule(byName:"GPU")?.reference), memory = try #require(manager.getModule(byName:"Memory")?.reference)
        if vertical { #expect(gpu.frame.minY > view.frame.maxY && view.frame.minY > memory.frame.maxY) }
        else { #expect(gpu.frame.maxX < view.frame.minX && view.frame.maxX < memory.frame.minX) }
        now=2;sample=reading(2,500);view.graphUpdate(nil)
        #expect(view.fullReading().contains("Power: 0.500 W") && view.labels.rightLabel.stringValue.contains("W"))
        view.setFrameSize(NSSize(width:86,height:90))
        #expect(view.labels.leftLabel.stringValue == "NPU\nANE")
        #expect(view.labels.rightLabel.stringValue.contains("16c"))
        #expect(!view.labels.leftLabel.frame.intersects(view.labels.rightLabel.frame))
        let watts = view.labels.rightLabel.stringValue.components(separatedBy:"\n")[0]
        let attributes = view.labels.rightLabel.attributedStringValue.attributes(at:0,effectiveRange:nil)
        #expect((watts as NSString).size(withAttributes:attributes).width + 4 <= view.labels.rightLabel.frame.width)
        view.removeFromSuperview();#expect(host.npuView == nil && manager.getModule(byName:"NPU") == nil)
    }
    @Test func liveReadOnlyAppleTelemetryDegradesGracefully() async throws {
        let readings = await Task.detached {
            let reader = XRGNPUReader();let first=reader.sample()
            try? await Task.sleep(for:.milliseconds(1100))
            return [first,reader.sample()]
        }.value
        for reading in readings {
            #expect(Set(reading.devices.map(\.id)).count == reading.devices.count)
            #expect(reading.energy?.allSatisfy { $0.value >= 0 && $0.joulesPerUnit != nil } ?? true)
        }
    }
}
