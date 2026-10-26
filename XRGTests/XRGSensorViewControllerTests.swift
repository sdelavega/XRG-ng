import AppKit
import Foundation
import Testing
@testable import XRGCore

@MainActor
private final class SensorWindowSource: NSObject, XRGSensorWindowDataSource {
    var appSettings: XRGSettings?
    var sensorWindowIncludesUnknownSensors = false
    var sensors: [XRGSensorData] = []
    var unknownKeys: Set<String> = []
    var requests: [Bool] = []

    func sensorWindowSensors(includingUnknown: Bool) -> [XRGSensorData] {
        requests.append(includingUnknown)
        return sensors.filter { includingUnknown || !unknownKeys.contains($0.key) }
    }
}

@MainActor
private final class SensorNibOwner: NSObject, NSWindowDelegate {
    @objc var sensorViewController: XRGSensorViewController?
    @objc var sensorWindow: NSWindow?
}

@Suite(.serialized) @MainActor
struct XRGSensorViewControllerTests {
    private func withSource(_ body: (SensorWindowSource) throws -> Void) throws {
        let domain = "XRG.sensorWindow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let source = SensorWindowSource()
        source.appSettings = XRGSettings(defaults: defaults)
        try body(source)
    }

    private func sensor(_ key: String, name: String? = nil, units: String? = "°C",
                        value: Double = 50, enabled: Bool = true) -> XRGSensorData {
        let sensor = XRGSensorData(sensorKey: key)
        sensor.humanReadableName = name
        sensor.units = units
        sensor.currentValue = value
        sensor.isEnabled = enabled
        return sensor
    }

    private func controller(_ source: SensorWindowSource) -> XRGSensorViewController {
        let controller = XRGSensorViewController(nibName: nil, bundle: nil)
        controller.dataSource = source
        controller.statsManager = XRGStatsManager()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let name = NSTextField(labelWithString: "")
        let current = NSTextField(labelWithString: "")
        let stats = NSTextField(labelWithString: "")
        for label in [name, current, stats] {
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }
        controller.nameValuesLabel = name
        controller.currentValuesLabel = current
        controller.statsValuesLabel = stats
        controller.view = view
        controller.viewDidLoad()
        return controller
    }

    @Test(arguments: [XRGTemperatureUnits.c, .f])
    func sensorNamesStatisticsAndTemperatureConversion(units: XRGTemperatureUnits) throws {
        try withSource { source in
            source.appSettings?.tempUnits = units
            source.sensors = [sensor("cpu", name: "CPU Core", value: 60),
                              sensor("fan", name: "Fan", units: " rpm", value: 1100)]
            let controller = controller(source)
            for value in [40.0, 50, 60] {
                controller.statsManager.observeStat(value, forKey: "cpu", inModule: .nameTemperature)
            }
            for value in [900.0, 1000, 1100] {
                controller.statsManager.observeStat(value, forKey: "fan", inModule: .nameTemperature)
            }
            controller.refresh()
            #expect(controller.nameValuesLabel?.stringValue == "CPU Core\nFan\n")
            #expect(controller.currentValuesLabel?.stringValue == (units == .f ? "140°F\n1100 rpm\n" : "60°C\n1100 rpm\n"))
            #expect(controller.statsValuesLabel?.stringValue == (units == .f
                ? "104 - 122 - 140\n900 - 1000 - 1100\n" : "40 - 50 - 60\n900 - 1000 - 1100\n"))
            #expect((controller.statsWidthConstraint?.constant ?? 0) >= 20)
            #expect(controller.statsWidthConstraint?.relation == .greaterThanOrEqual)
        }
    }

    @Test func unavailableAndMissingStatisticsDoNotLookLikeZeroMeasurements() throws {
        try withSource { source in
            source.appSettings?.tempUnits = .c
            source.sensors = [sensor("missing", enabled: false),
                              sensor("fresh", units: nil, value: 12),
                              sensor("invalid", value: .infinity)]
            let controller = controller(source)
            controller.statsManager.observeStat(55, forKey: "missing", inModule: .nameTemperature)
            controller.refresh()
            #expect(controller.nameValuesLabel?.stringValue == "missing\nfresh\ninvalid\n")
            #expect(controller.currentValuesLabel?.stringValue == "n/a\n12\nn/a\n")
            #expect(controller.statsValuesLabel?.stringValue == "55 - 55 - 55\nn/a - n/a - n/a\nn/a - n/a - n/a\n")
            source.sensors = []
            controller.refresh()
            #expect(controller.nameValuesLabel?.stringValue == "")
            #expect(controller.currentValuesLabel?.stringValue == "")
            #expect(controller.statsValuesLabel?.stringValue == "")
        }
    }

    @Test func visibilityPreferenceChangesAreReadAtEveryRefresh() throws {
        try withSource { source in
            source.sensors = [sensor("known"), sensor("unknown")]
            source.unknownKeys = ["unknown"]
            let controller = controller(source)
            controller.refresh()
            #expect(controller.nameValuesLabel?.stringValue == "known\n")
            source.sensorWindowIncludesUnknownSensors = true
            controller.refresh()
            #expect(controller.nameValuesLabel?.stringValue == "known\nunknown\n")
            source.appSettings?.tempUnits = .c
            controller.refresh()
            #expect(controller.currentValuesLabel?.stringValue == "50°C\n50°C\n")
            #expect(source.requests == [false, true, true])
        }
    }

    @Test func appearanceStartsOneTimerAndDisappearanceStopsIt() throws {
        try withSource { source in
            source.sensors = [sensor("cpu")]
            let controller = controller(source)
            controller.viewWillAppear()
            #expect(source.requests == [false])
            let first = try #require(controller.refreshTimer)
            #expect(first.isValid)
            first.fire()
            #expect(source.requests.count == 2)
            controller.viewWillAppear()
            let second = try #require(controller.refreshTimer)
            #expect(first !== second)
            #expect(!first.isValid)
            #expect(second.isValid)
            controller.viewDidDisappear()
            #expect(!second.isValid)
            #expect(controller.refreshTimer == nil)
            second.fire()
            #expect(source.requests.count == 3)
            controller.viewWillAppear()
            #expect(controller.refreshTimer?.isValid == true)
            controller.viewDidDisappear()
        }
    }

    @Test func timerDoesNotRetainController() throws {
        try withSource { source in
            var controller: XRGSensorViewController? = self.controller(source)
            weak var weakController = controller
            controller?.viewWillAppear()
            let timer = try #require(controller?.refreshTimer)
            controller = nil
            #expect(weakController == nil)
            weakController = nil
            timer.fire()
            #expect(!timer.isValid)
        }
    }

    @Test func copyReportIncludesUnknownSensorsAndUsesAnIsolatedPasteboard() throws {
        try withSource { source in
            source.sensors = [sensor("cpu", name: "CPU", value: 50.25),
                              sensor("Tnew", value: 70)]
            source.unknownKeys = ["Tnew"]
            let controller = controller(source)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            #expect(controller.copySensorReport(to: pasteboard, version: "3.2.2",
                model: "TestMac", operatingSystem: "Test OS"))
            #expect(pasteboard.string(forType: .string) == "XRG-ng 3.2.2\nMac model: TestMac\nRunning macOS Test OS\n\nDiscovered Sensors:\n\tCPU:  50.2\n\tTnew:  70.0\n")
            #expect(source.requests == [true])
        }
    }

    @Test func compiledSensorNibRestoresSwiftClassesOutletsAndAction() throws {
        try withSource { source in
            _ = NSApplication.shared
            let owner = SensorNibOwner()
            let nib = try #require(NSNib(nibNamed: "Sensors", bundle: Bundle(for: SensorNibOwner.self)))
            var topLevel: NSArray?
            #expect(nib.instantiate(withOwner: owner, topLevelObjects: &topLevel))
            let window = try #require(owner.sensorWindow)
            defer { window.orderOut(nil); window.close() }
            let controller = try #require(owner.sensorViewController)
            controller.dataSource = source
            controller.statsManager = XRGStatsManager()
            source.sensors = [sensor("cpu", name: "CPU")]
            _ = controller.view
            controller.refresh()
            #expect(controller.nameValuesLabel?.stringValue == "CPU\n")
            #expect(controller.currentValuesLabel != nil)
            #expect(controller.statsValuesLabel != nil)
            #expect(controller.exportButton?.target === controller)
            #expect(controller.exportButton?.action == #selector(XRGSensorViewController.exportAction(_:)))
            let statsLabel = try #require(controller.statsValuesLabel)
            #expect(controller.statsWidthConstraint?.isActive == true)
            let existing = controller.statsWidthConstraint
            controller.viewDidLoad()
            #expect(controller.statsWidthConstraint === existing)
            #expect(statsLabel.constraints.filter { $0 === existing }.count == 1)
            let scroll = try #require(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
            #expect(scroll.documentView is XRGFlippedView)
            #expect(scroll.documentView?.isFlipped == true)
            controller.viewDidDisappear()
            withExtendedLifetime(topLevel) {}
        }
    }
}
