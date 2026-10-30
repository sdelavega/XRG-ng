import AppKit
import Foundation
import Testing
@testable import XRGCore

@MainActor
private final class ModuleView: NSView, XRGModuleView {
    var events: [String] = []
    var graphSizes: [NSSize] = []
    var onGraph: (() -> Void)?
    var onMinimum: (() -> Void)?
    func setGraphSize(_ size: NSSize) { graphSizes.append(size) }
    func updateMinSize() { events.append("minimum"); onMinimum?() }
    func min30Update(_ timer: Timer?) { events.append("30") }
    func min5Update(_ timer: Timer?) { events.append("5") }
    func graphUpdate(_ timer: Timer?) { events.append("graph"); onGraph?() }
    func fastUpdate(_ timer: Timer?) { events.append("fast") }
}

@MainActor
private final class ModuleWindow: NSObject, XRGModuleWindow {
    var minimized = false
    var borderWidth: Int32 = 2
    var appSettings: XRGSettings?
    var contentView: NSView? = NSView()
    var minSize: NSSize = .zero
    var frame = NSRect(x: 10, y: 20, width: 200, height: 242)
    var sizeChecks = 0
    var frameChanges = 0
    init(defaults: UserDefaults) {
        appSettings = XRGSettings(defaults: defaults)
        appSettings?.textRectHeight = 20
        super.init()
    }
    func checkWindowSize() { sizeChecks += 1 }
    func setFrame(_ frame: NSRect, display: Bool, animate: Bool) {
        self.frame = frame
        frameChanges += 1
    }
}

@Suite @MainActor
struct XRGModuleTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let domain = "XRG.modules.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults)
    }

    private func module(_ name: String, _ order: Int, defaults: UserDefaults) -> XRGModule {
        let module = XRGModule(name: name, reference: ModuleView(), defaults: defaults)
        module.displayOrder = order
        return module
    }

    @Test func legacySizePersistenceAndValidation() throws {
        try withDefaults { defaults in
            defaults.set(90.5, forKey: "XRGModule_CPU_width")
            defaults.set(110.25, forKey: "XRGModule_CPU_height")
            let module = module("CPU", 0, defaults: defaults)
            #expect(module.currentSize == NSSize(width: 90.5, height: 110.25))
            module.currentSize = NSSize(width: 120.5, height: 130.75)
            let reopened = self.module("CPU", 0, defaults: defaults)
            #expect(reopened.currentSize == module.currentSize)
            defaults.set(-8, forKey: "XRGModule_CPU_width")
            defaults.set(Double.infinity, forKey: "XRGModule_CPU_height")
            #expect(XRGModule.savedSize(forModule: module) == NSSize(width: 55, height: 65))
            module.currentSize = NSSize(width: CGFloat.nan, height: -2)
            #expect(module.currentSize == .zero)
            #expect(XRGModule.savedSize(forModule: nil) == NSSize(width: 55, height: 65))
            let empty = XRGModule(defaults: defaults)
            #expect(empty.isEmptyModule)
            #expect(empty.isDisplayed && empty.doesGraphUpdate)
            empty.doesFastUpdate = true
            #expect(!empty.isEmptyModule)
        }
    }

    @Test func registrationReplacementOrderingAndSnapshots() throws {
        try withDefaults { defaults in
            let manager = XRGModuleManager()
            let cpu = module("CPU", 20, defaults: defaults)
            let gpu = module("GPU", 3, defaults: defaults)
            let memory = module("Memory", 20, defaults: defaults)
            manager.addModule(cpu); manager.addModule(gpu); manager.addModule(memory)
            let previous = manager.moduleList()
            #expect(manager.displayList().compactMap(\.name) == ["GPU", "CPU", "Memory"])
            let replacement = module("CPU", -4, defaults: defaults)
            replacement.alwaysDoesGraphUpdate = true
            manager.addModule(replacement)
            manager.addModule(replacement)
            #expect(manager.moduleList().count == 3)
            #expect(manager.getModule(byName: "CPU") === replacement)
            #expect(previous.first === cpu)
            #expect(manager.displayList().compactMap(\.name) == ["CPU", "GPU", "Memory"])
            let view = ModuleView()
            manager.updateModule(withName: "CPU", toReference: view)
            #expect(manager.getModule(byReference: view) === replacement)
            #expect(manager.getModule(byName: "missing") == nil)
            replacement.displayOrder = 30
            #expect(manager.displayList().compactMap(\.name) == ["GPU", "Memory", "CPU"])
        }
    }

    @Test func timerEligibilityVisibilityAndImmediateRefresh() throws {
        try withDefaults { defaults in
            let manager = XRGModuleManager()
            let visible = module("visible", 0, defaults: defaults)
            let hidden = module("hidden", 1, defaults: defaults)
            visible.doesMin30Update = true; visible.doesMin5Update = true
            visible.doesFastUpdate = true; visible.alwaysDoesGraphUpdate = true
            hidden.isDisplayed = false; hidden.alwaysDoesGraphUpdate = true
            hidden.doesFastUpdate = true; hidden.doesMin5Update = true
            let v = try #require(visible.reference as? ModuleView)
            let h = try #require(hidden.reference as? ModuleView)
            manager.addModule(visible); manager.addModule(hidden)
            manager.min30Update(); manager.min5Update(); manager.graphUpdate(); manager.fastUpdate()
            #expect(v.events == ["30", "5", "graph", "fast"])
            #expect(h.events == ["graph"])
            manager.setModule("hidden", isDisplayed: true)
            #expect(h.events == ["graph", "5", "graph", "fast"])
            #expect(manager.numModulesDisplayed() == 2)
            h.events = []
            manager.graphUpdate()
            #expect(h.events == ["graph"])
            manager.setModule("visible", isDisplayed: false)
            #expect(manager.numModulesDisplayed() == 1)
            manager.setModule("missing", isDisplayed: true)
            #expect(manager.moduleList().count == 2)
        }
    }

    @Test func callbackMeasurementsAreOptInAndPreserveSnapshotAndEligibility() throws {
        try withDefaults { defaults in
            let manager = XRGModuleManager(), first = module("first", 0, defaults: defaults), hidden = module("hidden", 1, defaults: defaults)
            hidden.isDisplayed = false; hidden.alwaysDoesGraphUpdate = true
            let a = try #require(first.reference as? ModuleView), b = try #require(hidden.reference as? ModuleView)
            manager.addModule(first); manager.addModule(hidden)
            defer { a.onGraph = nil; b.onGraph = nil }
            var now = 1.0, clockReads = 0
            manager.updateClock = { clockReads += 1; return now }
            a.onGraph = { now += 0.25 }; b.onGraph = { now += 0.5 }
            manager.graphUpdate(); #expect(clockReads == 0)
            var records: [(String, String, Double)] = []
            manager.onUpdateMeasurement = { records.append(($0, $1, $2)) }
            a.onGraph = { now += 0.25; manager.removeModule(hidden); hidden.name = "changed" }
            manager.graphUpdate()
            #expect(records.map { $0.0 } == ["first", "hidden"] && records.allSatisfy { $0.1 == "normal" })
            #expect(records.map { $0.2 } == [0.25, 0.5] && clockReads == 4)
            first.doesFastUpdate = true; first.doesMin5Update = true; first.doesMin30Update = true
            manager.fastUpdate(); manager.min5Update(); manager.min30Update()
            #expect(records.suffix(3).map { $0.1 } == ["fast", "min5", "min30"] && records.suffix(3).allSatisfy { $0.2 == 0 })
            #expect(b.events == ["graph", "graph"])
        }
    }
    @Test func invalidMeasurementClocksNeverSuppressTheCollectorCallback() throws {
        try withDefaults { defaults in
            let manager = XRGModuleManager(), graph = module("graph", 0, defaults: defaults)
            let view = try #require(graph.reference as? ModuleView); manager.addModule(graph)
            var records = 0
            manager.onUpdateMeasurement = { _, _, _ in records += 1 }
            for pair in [(Double.nan, 2.0), (1.0, Double.infinity), (-1.0, 2.0), (2.0, 1.0)] {
                var times = [pair.0, pair.1]
                manager.updateClock = { times.removeFirst() }
                manager.graphUpdate()
            }
            #expect(records == 0 && view.events == Array(repeating: "graph", count: 4))
        }
    }

    @Test func callbackMutationUsesRecipientSnapshotAndDisplayOrder() throws {
        try withDefaults { defaults in
            let manager = XRGModuleManager()
            let second = module("second", 2, defaults: defaults)
            let first = module("first", 1, defaults: defaults)
            let a = try #require(first.reference as? ModuleView)
            let b = try #require(second.reference as? ModuleView)
            var order: [String] = []
            a.onGraph = {
                order.append("first")
                manager.setModule("second", isDisplayed: false)
            }
            b.onGraph = { order.append("second") }
            manager.addModule(second); manager.addModule(first)
            manager.graphUpdate()
            #expect(order == ["first", "second"])
            #expect(b.events == ["graph"])
            order = []
            manager.graphUpdate()
            #expect(order == ["first"])
            a.onGraph = nil; b.onGraph = nil
        }
    }

    @Test func verticalAndHorizontalGeometryAndDividers() throws {
        try withDefaults { defaults in
            let window = ModuleWindow(defaults: defaults)
            let manager = XRGModuleManager(window: window)
            let first = module("first", 0, defaults: defaults)
            let second = module("second", 1, defaults: defaults)
            manager.addModule(second); manager.addModule(first)
            manager.windowChanged(to: NSSize(width: 200, height: 242))
            #expect(first.currentSize == NSSize(width: 196, height: 107))
            #expect(second.reference?.frame.origin == NSPoint(x: 2, y: 2))
            #expect(first.reference?.frame.origin == NSPoint(x: 2, y: 111))
            #expect(manager.resizeRects().map(\.rectValue) == [NSRect(x: 2, y: 109, width: 196, height: 4)])
            manager.graphOrientationVertical = false
            manager.windowChanged(to: NSSize(width: 242, height: 200))
            #expect(first.currentSize == NSSize(width: 107, height: 196))
            #expect(first.reference?.frame.origin == NSPoint(x: 24, y: 2))
            #expect(second.reference?.frame.origin == NSPoint(x: 133, y: 2))
            #expect(manager.resizeRects().map(\.rectValue) == [NSRect(x: 129, y: 2, width: 4, height: 196)])
            manager.setModule("second", isDisplayed: false)
            manager.windowChanged(to: NSSize(width: 242, height: 200))
            #expect(second.currentSize == .zero)
            #expect(second.reference?.frame.size == .zero)
            #expect(first.currentSize == NSSize(width: 216, height: 196))
            #expect(manager.resizeRects().isEmpty)
        }
    }

    @Test func savedOrderAndPreferredHeightsRestoreWithoutLosingHiddenModulesOrStarvingAutomaticGraphs() throws {
        try withDefaults { defaults in
            let window = ModuleWindow(defaults: defaults)
            let layout = XRGModuleManager(window: window)
            let cpu = module("CPU", 0, defaults: defaults), gpu = module("GPU", 1, defaults: defaults), memory = module("Memory", 2, defaults: defaults)
            layout.addModule(cpu); layout.addModule(gpu); layout.addModule(memory)
            var prefs = XRGGraphPreferences(); prefs.order = [.memory, .gpu, .cpu] + XRGGraphID.allCases.filter { ![.memory, .gpu, .cpu].contains($0) }
            prefs[.cpu].height = 128
            try window.appSettings!.applyGraphPreferences(prefs)
            layout.windowChanged(to: NSSize(width: 200, height: 500))
            #expect(layout.displayList().compactMap(\.name) == ["Memory", "GPU", "CPU"])
            #expect(cpu.currentSize.height == 128)
            #expect(memory.reference!.frame.minY > gpu.reference!.frame.minY && gpu.reference!.frame.minY > cpu.reference!.frame.minY)
            layout.setModule("GPU", isDisplayed: false)
            layout.windowChanged(to: NSSize(width: 200, height: 500))
            #expect(cpu.currentSize.height == 128 && gpu.reference?.isHidden == true)
            layout.setModule("GPU", isDisplayed: true)
            layout.windowChanged(to: NSSize(width: 200, height: 500))
            #expect(layout.displayList().compactMap(\.name) == ["Memory", "GPU", "CPU"])
            prefs[.cpu].height = 240; prefs[.gpu].height = 240
            try window.appSettings!.applyGraphPreferences(prefs)
            layout.windowChanged(to: NSSize(width: 200, height: 180))
            #expect([cpu, gpu, memory].allSatisfy { $0.currentSize.height >= 30 })
            #expect(cpu.currentSize.height < 240 && gpu.currentSize.height < 240)
            #expect(abs([cpu, gpu, memory].reduce(CGFloat(0)) { $0 + $1.currentSize.height } - 150) < 0.001)
            #expect(window.appSettings!.graphPreferences[.cpu].height == 240)
            layout.graphOrientationVertical = false
            layout.windowChanged(to: NSSize(width: 500, height: 300))
            #expect(cpu.currentSize.height == 240 && gpu.currentSize.height == 240)
            #expect(cpu.reference?.frame.maxY == memory.reference?.frame.maxY)
        }
    }

    @Test func preferredHeightDividersPersistClampedSizesAndDisableWhileCompressed() throws {
        try withDefaults { defaults in
            let window = ModuleWindow(defaults: defaults)
            let manager = XRGModuleManager(window: window)
            let cpu = module("CPU", 0, defaults: defaults), gpu = module("GPU", 1, defaults: defaults)
            manager.addModule(cpu); manager.addModule(gpu)
            var value = XRGGraphPreferences(); value[.cpu].height = 128; value[.gpu].height = 128
            try window.appSettings!.applyGraphPreferences(value)
            manager.windowChanged(to: NSSize(width: 200, height: 400))
            #expect(manager.resizeModule(number: 0, byDelta: 50) == 50)
            #expect(window.appSettings!.graphPreferences[.gpu].height == 178)
            #expect(window.appSettings!.graphPreferences[.cpu].height == 78)
            #expect(manager.resizeModule(number: 0, byDelta: 100) == 14)
            #expect(XRGSettings(defaults: defaults).graphPreferences[.cpu].height == 64)
            manager.windowChanged(to: NSSize(width: 200, height: 100))
            #expect(manager.resizeRects().count == 1 && manager.resizeRects()[0].rectValue == .zero)
            #expect(manager.resizeModule(number: 0, byDelta: 10) == 0)
            #expect(window.appSettings!.graphPreferences[.gpu].height == 192)
        }
    }

    @Test func disabledPanelsAreHiddenAndCollapsedLayoutCannotRevealThem() throws {
        try withDefaults { defaults in
            let window = ModuleWindow(defaults: defaults)
            let manager = XRGModuleManager(window: window)
            let visible = module("visible", 0, defaults: defaults)
            let disabled = module("disabled", 1, defaults: defaults)
            disabled.isDisplayed = false
            manager.addModule(visible); manager.addModule(disabled)
            manager.windowChanged(to: window.frame.size)
            #expect(visible.reference?.isHidden == false)
            #expect(disabled.reference?.isHidden == true)
            manager.setModule("disabled", isDisplayed: true)
            manager.windowChanged(to: window.frame.size)
            #expect(disabled.reference?.isHidden == false && disabled.currentSize.width > 0)
            window.minimized = true
            visible.reference?.isHidden = true; disabled.reference?.isHidden = true
            manager.windowChanged(to: window.frame.size)
            #expect(visible.reference?.isHidden == true && disabled.reference?.isHidden == true)
            window.minimized = false
            manager.setModule("disabled", isDisplayed: false)
            manager.windowChanged(to: window.frame.size)
            #expect(visible.reference?.isHidden == false && disabled.reference?.isHidden == true)
        }
    }

    @Test func threeHorizontalDividerPositions() throws {
        try withDefaults { defaults in
            let window = ModuleWindow(defaults: defaults)
            let manager = XRGModuleManager(window: window)
            manager.graphOrientationVertical = false
            for index in 0..<3 { manager.addModule(module("m\(index)", index, defaults: defaults)) }
            manager.windowChanged(to: NSSize(width: 330, height: 100))
            #expect(manager.resizeRects().map { $0.rectValue.origin.x } == [122, 224])
        }
    }

    @Test func minimumSizeFontChangeAndMinimizedLayout() throws {
        try withDefaults { defaults in
            let window = ModuleWindow(defaults: defaults)
            let manager = XRGModuleManager(window: window)
            let first = module("first", 0, defaults: defaults)
            let second = module("second", 1, defaults: defaults)
            first.minWidth = 50; second.minWidth = 80
            first.minHeight = 40; second.minHeight = 60
            manager.addModule(first); manager.addModule(second)
            #expect(manager.getMinSize() == NSSize(width: 84, height: 148))
            window.minimized = true
            #expect(manager.getMinSize() == NSSize(width: 84, height: 24))
            let saved = first.currentSize
            manager.windowChanged(to: NSSize(width: 84, height: 24))
            #expect(first.currentSize == saved)
            #expect(manager.resizeModule(number: 0, byDelta: 10) == 0)
            manager.graphOrientationVertical = false
            #expect(manager.getMinSize() == NSSize(width: 24, height: 64))
            window.minimized = false
            #expect(manager.getMinSize() == NSSize(width: 188, height: 64))
            let view = try #require(first.reference as? ModuleView)
            view.onMinimum = { first.minHeight = 300; first.minWidth = 200 }
            manager.graphFontChanged()
            #expect(view.events == ["minimum"])
            #expect(window.minSize == NSSize(width: 428, height: 304))
            #expect(window.frame.size == window.minSize)
            #expect(window.frame.origin == NSPoint(x: 10, y: 20))
            #expect(window.frameChanges == 1)
            view.onMinimum = nil
        }
    }

    @Test func emptyHiddenAndCollapsedLayoutsStayFinite() throws {
        try withDefaults { defaults in
            let window = ModuleWindow(defaults: defaults)
            let manager = XRGModuleManager(window: window)
            #expect(manager.resizeRects().isEmpty)
            #expect(manager.resizeModule(number: 0, byDelta: 1) == 0)
            manager.windowChanged(to: .zero)
            let empty = XRGModule(defaults: defaults)
            manager.addModule(empty)
            #expect(manager.numModulesDisplayed() == 0)
            manager.windowChanged(to: .zero)
            let graph = module("graph", 0, defaults: defaults)
            manager.addModule(graph)
            manager.windowChanged(to: NSSize(width: 1, height: 1))
            #expect(graph.currentSize == .zero)
            manager.windowChanged(to: NSSize(width: CGFloat.infinity, height: CGFloat.nan))
            #expect(graph.currentSize == .zero)
            manager.setModule("graph", isDisplayed: false)
            manager.windowChanged(to: .zero)
            #expect(manager.numModulesDisplayed() == 0)
            #expect(manager.resizeRects().isEmpty)
            #expect(manager.getMinSize() == NSSize(width: 4, height: 24))
        }
    }

    @Test(arguments: [true, false])
    func dragClampsBothModulesAndReturnsAppliedDelta(vertical: Bool) throws {
        try withDefaults { defaults in
            let window = ModuleWindow(defaults: defaults)
            let manager = XRGModuleManager(window: window)
            manager.graphOrientationVertical = vertical
            let a = module("a", 0, defaults: defaults), b = module("b", 1, defaults: defaults)
            manager.addModule(a); manager.addModule(b)
            manager.windowChanged(to: NSSize(width: 200, height: 242))
            let pair = vertical ? [b, a] : [a, b]
            let initial = vertical ? pair[0].currentSize.height : pair[0].currentSize.width
            let total = initial * 2
            let available = initial - 30
            #expect(manager.resizeModule(number: 0, byDelta: 1000) == Float(available))
            #expect((vertical ? pair[1].currentSize.height : pair[1].currentSize.width) == 30)
            #expect(manager.resizeModule(number: 0, byDelta: -1000) == Float(-2 * available))
            let one = vertical ? pair[0].currentSize.height : pair[0].currentSize.width
            let two = vertical ? pair[1].currentSize.height : pair[1].currentSize.width
            #expect(one == 30)
            #expect(one + two == total)
            let before = pair.map(\.currentSize)
            #expect(manager.resizeModule(number: -1, byDelta: 10) == 0)
            #expect(manager.resizeModule(number: 1, byDelta: 10) == 0)
            #expect(manager.resizeModule(number: 0, byDelta: .nan) == 0)
            #expect(pair.map(\.currentSize) == before)
        }
    }

    @Test func removalUsesIdentityAndKeepsAReplacementWithTheSameName() throws {
        try withDefaults { defaults in
            let window = ModuleWindow(defaults: defaults)
            let manager = XRGModuleManager(window: window)
            let original = module("GPU", 1, defaults: defaults)
            let replacement = module("GPU", 1, defaults: defaults)
            manager.addModule(original)
            manager.addModule(replacement)
            let savedSize = NSSize(width: 101, height: 151)
            replacement.currentSize = savedSize
            manager.removeModule(original)
            #expect(replacement.currentSize == savedSize)
            #expect(manager.getModule(byName: "GPU") === replacement)
            #expect(manager.numModulesDisplayed() == 1)
            manager.removeModule(replacement)
            #expect(manager.moduleList().isEmpty)
            #expect(manager.displayList().isEmpty)
            #expect(manager.resizeRects().isEmpty)
            #expect(window.minSize == NSSize(width: 4, height: 24))
        }
    }

    @Test func windowIsNotRetainedByManager() throws {
        try withDefaults { defaults in
            var window: ModuleWindow? = ModuleWindow(defaults: defaults)
            weak var weakWindow = window
            let manager = XRGModuleManager(window: window)
            manager.addModule(module("a", 0, defaults: defaults))
            window = nil
            #expect(weakWindow == nil)
            weakWindow = nil
            manager.redisplayModules()
            manager.graphFontChanged()
            manager.windowChanged(to: NSSize(width: 100, height: 100))
            #expect(manager.numModulesDisplayed() == 1)
        }
    }
}
