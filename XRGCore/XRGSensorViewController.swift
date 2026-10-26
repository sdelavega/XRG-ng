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

/// Supplies the existing hardware readings without tying the controller to the app target.
@MainActor @objc public protocol XRGSensorWindowDataSource: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var sensorWindowIncludesUnknownSensors: Bool { get }
    func sensorWindowSensors(includingUnknown: Bool) -> [XRGSensorData]
}

@MainActor
@objc(XRGSensorViewController) @objcMembers
public final class XRGSensorViewController: NSViewController {
    @IBOutlet var nameValuesLabel: NSTextField?
    @IBOutlet var currentValuesLabel: NSTextField?
    @IBOutlet var statsValuesLabel: NSTextField?
    @IBOutlet weak var exportButton: NSButton?
    private(set) var statsWidthConstraint: NSLayoutConstraint?
    public weak var dataSource: (any XRGSensorWindowDataSource)?

    @nonobjc var statsManager = XRGStatsManager.shared
    @nonobjc private(set) var refreshTimer: Timer?

    public override func viewDidLoad() {
        super.viewDidLoad()
        if dataSource == nil { dataSource = NSApp?.delegate as? any XRGSensorWindowDataSource }
        if statsWidthConstraint == nil, let label = statsValuesLabel {
            // The nib also requires this column to fit its header. A lower bound
            // avoids conflicting with that constraint before the first refresh.
            let constraint = label.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
            constraint.isActive = true
            statsWidthConstraint = constraint
        }
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        refreshTimer?.invalidate()
        refresh()
        // Scheduled on the main run loop; the callback therefore runs on the main actor.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            let hasController = MainActor.assumeIsolated {
                guard let self else { return false }
                self.refresh()
                return true
            }
            if !hasController { timer.invalidate() }
        }
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    public func refresh() {
        let sensors = dataSource?.sensorWindowSensors(
            includingUnknown: dataSource?.sensorWindowIncludesUnknownSensors ?? false) ?? []
        let fahrenheit = dataSource?.appSettings?.tempUnits == .f
        var names: [String] = [], currentValues: [String] = [], statistics: [String] = []
        for sensor in sensors {
            let stats = statsManager.stat(forKey: sensor.key, inModule: .nameTemperature)
            let convert = fahrenheit && sensor.units == "°C"
            let units = convert ? "°F" : (sensor.units ?? "")
            func display(_ value: Double?) -> String {
                guard let value else { return "n/a" }
                let converted = convert ? value * 1.8 + 32 : value
                return converted.isFinite ? String(format: "%.0f", converted) : "n/a"
            }
            names.append(sensor.label())
            // A missing sensor must not present its last historical reading as current.
            if sensor.isEnabled {
                let value = display(stats?.last ?? sensor.currentValue)
                currentValues.append(value == "n/a" ? value : value + units)
            } else {
                currentValues.append("n/a")
            }
            statistics.append("\(display(stats?.min)) - \(display(stats?.average)) - \(display(stats?.max))")
        }
        func lines(_ values: [String]) -> String { values.isEmpty ? "" : values.joined(separator: "\n") + "\n" }
        nameValuesLabel?.stringValue = lines(names)
        currentValuesLabel?.stringValue = lines(currentValues)
        statsValuesLabel?.stringValue = lines(statistics)
        if let label = statsValuesLabel {
            label.sizeToFit()
            statsWidthConstraint?.constant = max(20, label.frame.width)
        }
    }

    @IBAction public func exportAction(_ sender: Any?) {
        copySensorReport(to: .general,
                         version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                         model: XRGCPUMiner.systemModelIdentifier() ?? "",
                         operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    @nonobjc @discardableResult
    func copySensorReport(to pasteboard: NSPasteboard, version: String,
                          model: String, operatingSystem: String) -> Bool {
        var text = "XRG-ng \(version)\nMac model: \(model)\nRunning macOS \(operatingSystem)\n\nDiscovered Sensors:\n"
        // Diagnostic exports include unknown sensors and retain raw sensor units.
        for sensor in dataSource?.sensorWindowSensors(includingUnknown: true) ?? [] {
            text += "\t\(sensor.label()):  \(String(format: "%.1f", sensor.currentValue))\n"
        }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
