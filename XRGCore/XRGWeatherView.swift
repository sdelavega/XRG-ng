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

@MainActor @objc public protocol XRGWeatherViewHost: NSObjectProtocol {
    var appSettings: XRGSettings? { get }
    var moduleManager: XRGModuleManager? { get }
    var weatherView: XRGWeatherView? { get set }
    func initTimers()
    func showWeatherPreferences()
    func systemJustWokeUp() -> Bool
    func setSystemJustWokeUp(_ value: Bool)
}

@MainActor protocol XRGWeatherTransport: AnyObject {
    func setURLString(_ value: String?)
    func loadURLInBackground()
    func cancelLoading()
    func isDataReady() -> Bool
    func didErrorOccur() -> Bool
    func getData() -> Data?
}
extension XRGURL: XRGWeatherTransport {}

@MainActor
@objc(XRGWeatherView) @objcMembers
public final class XRGWeatherView: NSView, XRGModuleView {
    private let defaults: UserDefaults
    private let standaloneSettings: XRGSettings?
    private let sources: [any XRGWeatherTransport]
    private weak var host: (any XRGWeatherViewHost)?
    private weak var registeredManager: XRGModuleManager?
    private var didAwake = false
    private var tried = [false, false]
    @nonobjc private(set) var retryElapsed: TimeInterval = 0
    @nonobjc private(set) var tickerTimer: Timer?
    @nonobjc private(set) var reports: [XRGWeatherReport] = []
    @nonobjc let labels = XRGGraphLabels()
    public private(set) weak var module: XRGModule?
    public private(set) var stationName = ""
    public private(set) var gettingData = false
    private var settings: XRGSettings? { host?.appSettings ?? standaloneSettings }
    private var active: Bool {
        if let module { return module.isDisplayed && window != nil }
        return host == nil && !didAwake && standaloneSettings != nil
    }
    public var graphSize: NSSize { bounds.size }
    @nonobjc var current: XRGWeatherReport? { reports.first }
    @nonobjc var high: Double? { reports.compactMap(\.temperatureC).max() }
    @nonobjc var low: Double? { reports.compactMap(\.temperatureC).min() }

    public override init(frame frameRect: NSRect) {
        defaults = .standard; standaloneSettings = nil; sources = [XRGURL(), XRGURL()]
        super.init(frame: frameRect); prepare()
    }
    public required init?(coder: NSCoder) {
        defaults = .standard; standaloneSettings = nil; sources = [XRGURL(), XRGURL()]
        super.init(coder: coder); prepare()
    }
    @nonobjc init(frame: NSRect, settings: XRGSettings, defaults: UserDefaults, sources: [any XRGWeatherTransport]) {
        precondition(sources.count == 2)
        self.defaults = defaults; standaloneSettings = settings; self.sources = sources
        super.init(frame: frame); prepare(); setURL(settings.ICAO)
    }
    private func prepare() {
        for label in [labels.leftLabel, labels.centerLabel, labels.rightLabel] { addSubview(label) }
        updateLabels()
    }
    public nonisolated override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { didAwake = true; bindToWindow() }
    }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bindToWindow() }
    private func bindToWindow() {
        let next = window as? any XRGWeatherViewHost
        if host !== next || registeredManager !== next?.moduleManager {
            cancelLoading()
            if host?.weatherView === self { host?.weatherView = nil }
            if let module { registeredManager?.removeModule(module) }
            registeredManager = nil; module = nil; host = next
        }
        guard didAwake, let host, let manager = host.moduleManager, settings != nil,
              registeredManager !== manager else { updateLabels(); return }
        let module = XRGModule(name: "Weather", reference: self, defaults: defaults)
        module.displayOrder = 8; module.doesGraphUpdate = true; module.doesFastUpdate = false
        module.doesMin5Update = false; module.doesMin30Update = true
        module.isDisplayed = defaults.bool(forKey: "showWeatherGraph")
        self.module = module; registeredManager = manager; host.weatherView = self
        host.initTimers(); updateMinSize(); manager.addModule(module); setGraphSize(module.currentSize)
        setURL(settings?.ICAO ?? "")
        if module.isDisplayed { min30Update(nil) }
        updateLabels()
    }
    public func setGraphSize(_ size: NSSize) {
        setFrameSize(NSSize(width: XRGModule.dimension(size.width), height: XRGModule.dimension(size.height)))
        if module?.isDisplayed == false { cancelLoading() }
    }
    public override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); updateLabels() }
    public func updateMinSize() {
        module?.minWidth = ("H/L:199/99" as NSString).size(withAttributes: [.font: settings?.graphFont ?? NSFont.systemFont(ofSize: 10)]).width + 6
        module?.minHeight = XRGGraphLabels.lineHeight(settings)
        updateLabels()
    }
    @nonobjc static func endpointStrings(_ station: String) -> [String] {
        guard let station = XRGWeatherReport.station(station) else { return [] }
        return ["https://aviationweather.gov/api/data/metar/?format=raw&hours=24&taf=off&layout=off&date=0&ids=" + station,
                "https://weather.ral.ucar.edu/surface/index.php?hoursStr=24&metarIds=" + station]
    }
    public func setURL(_ text: String?) {
        let station = XRGWeatherReport.station(text ?? "") ?? ""
        guard stationName != station || reports.isEmpty else { return }
        cancelLoading(); stationName = station; reports = []; retryElapsed = 0
        let endpoints = Self.endpointStrings(station)
        for (index, source) in sources.enumerated() { source.setURLString(endpoints.indices.contains(index) ? endpoints[index] : nil) }
        updateLabels(); needsDisplay = true
    }
    public func cancelLoading() {
        for source in sources { source.cancelLoading() }
        gettingData = false; tried = [false, false]; stopTicker(); updateLabels(); needsDisplay = true
    }
    private func stopTicker() { tickerTimer?.invalidate(); tickerTimer = nil }
    private func synchronizeTicker() {
        guard gettingData, module?.isDisplayed == true, window != nil else { stopTicker(); return }
        guard tickerTimer == nil else { return }
        tickerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            let alive = MainActor.assumeIsolated {
                guard let self else { return false }
                self.ticker(); return true
            }
            if !alive { timer.invalidate() }
        }
    }
    public func ticker() {
        guard active else { cancelLoading(); return }
        if gettingData { min30UpdatePostProcessing() }
    }
    public func graphUpdate(_ timer: Timer?) {
        guard active else { cancelLoading(); return }
        if host?.systemJustWokeUp() == true {
            min30Update(nil); host?.setSystemJustWokeUp(false)
        }
        if hasInvalidData(), let refresh = settings?.graphRefresh, refresh.isFinite, refresh > 0 {
            retryElapsed += min(300, Double(refresh))
            if retryElapsed >= 300 { min30Update(nil) }
        }
        updateLabels(); needsDisplay = true
    }
    public func fastUpdate(_ timer: Timer?) {}
    public func min5Update(_ timer: Timer?) {}
    public func min30Update(_ timer: Timer?) {
        guard active else { cancelLoading(); return }
        if stationName != (XRGWeatherReport.station(settings?.ICAO ?? "") ?? "") { setURL(settings?.ICAO) }
        cancelLoading(); reports = []; retryElapsed = 0
        guard !stationName.isEmpty else { updateLabels(); return }
        gettingData = true
        for source in sources { source.loadURLInBackground() }
        synchronizeTicker(); updateLabels(); needsDisplay = true
    }
    public func min30UpdatePostProcessing() {
        guard active, gettingData else { return }
        for index in sources.indices where !tried[index] {
            let source = sources[index]
            if source.didErrorOccur() { tried[index] = true; continue }
            guard source.isDataReady() else { continue }
            tried[index] = true
            let text = source.getData().flatMap { String(data: $0, encoding: .utf8) }
            let candidate = text.map { XRGWeatherReport.reports(in: $0, station: stationName) } ?? []
            if !candidate.isEmpty {
                reports = candidate; cancelLoading(); retryElapsed = 0; updateLabels(); return
            }
        }
        if tried.allSatisfy({ $0 }) { cancelLoading() }
        updateLabels(); needsDisplay = true
    }
    /// Retained selectors also support direct METAR input without starting a request.
    public func setMETARFromText(_ text: String?) {
        cancelLoading(); reports = XRGWeatherReport.reports(in: text ?? "", station: stationName)
        retryElapsed = 0; updateLabels(); needsDisplay = true
    }
    public func setCurrentWeatherDataFromMETAR() { updateLabels(); needsDisplay = true }
    public func hasInvalidData() -> Bool { current == nil && !gettingData }
    public func getSecondaryGraphList() -> [String] { ["None", "Wind Speed", "Relative Humidity", "Visibility", "Dewpoint", "Pressure"] }
    public func setUpSecondaryGraph() { needsDisplay = true }
    public func shouldDrawMiniGraph() -> Bool { XRGGraphLabels.shouldDrawMiniGraph(in: bounds, settings: settings) }
    public func convertHeight(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        let result = max(0, value) / 100 * max(0, bounds.height - XRGGraphLabels.lineHeight(settings))
        return result.isFinite ? result : CGFloat.greatestFiniteMagnitude
    }
    struct Plot { let values: [CGFloat]; let lower: CGFloat; let upper: CGFloat; let filled: Bool }
    @nonobjc func plots() -> [Plot] {
        guard !reports.isEmpty else { return [] }
        var plots: [Plot] = []
        if let high, let low {
            plots.append(Plot(values: reports.reversed().map { CGFloat($0.temperatureC ?? -1000) }, lower: low - 10, upper: high + 10, filled: true))
        }
        let selection = settings?.secondaryWeatherGraph ?? 0
        guard (1...5).contains(selection) else { return plots }
        let values: [Double?] = reports.reversed().map { report in
            switch selection {
            case 1: return report.windKnots
            case 2: return report.humidity.map(Double.init)
            case 3: return report.visibilityMiles
            case 4: return report.dewpointC
            default: return report.pressureIn
            }
        }
        guard let minimum = values.compactMap({ $0 }).min(), let maximum = values.compactMap({ $0 }).max() else { return plots }
        let lower: Double, upper: Double
        switch selection {
        case 1, 3: lower = 0; upper = max(1, maximum * 1.1)
        case 2: lower = 0; upper = 100
        case 4: lower = minimum - max(1, abs(minimum) * 0.1); upper = maximum + max(1, abs(maximum) * 0.1)
        default: lower = minimum * 0.99; upper = maximum * 1.01
        }
        plots.append(Plot(values: values.map { CGFloat($0 ?? -1000) }, lower: lower, upper: upper, filled: false))
        return plots
    }
    private func temperature(_ celsius: Double?, precise: Bool = false) -> String {
        guard let celsius else { return "n/a" }
        if settings?.temperatureUnits == 1 { return String(format: "%.1f°C", celsius) }
        return precise ? String(format: "%.1f°F", celsius * 1.8 + 32) : "\(Int(celsius * 1.8 + 32))°F"
    }
    @nonobjc var windReading: String {
        guard let current, let speed = current.windKnots else { return "n/a" }
        if speed == 0 { return "calm" }
        return "\(current.directionText) \(Int(speed)) kt" + (current.gustKnots.map { " Gusts: \(Int($0)) kt" } ?? "")
    }
    @nonobjc var visibilityReading: String {
        guard let current, let miles = current.visibilityMiles else { return "n/a" }
        if settings?.distanceUnits == 1 { return current.visibilityQualifier + String(format: "%.1f km", miles * 1.609344) }
        return current.visibilityQualifier + String(format: abs(miles.rounded() - miles) < 0.0001 ? "%.0f mi" : "%.2f mi", miles)
    }
    @nonobjc var pressureReading: String {
        if settings?.pressureUnits == 1 { return current?.pressureHPA.map { "\(Int($0))hPa" } ?? "n/a" }
        return current?.pressureIn.map { String(format: "%.2fin", $0) } ?? "n/a"
    }
    @nonobjc func fullReading() -> String {
        guard let current else { return gettingData ? "Fetching Data" : "Invalid Data" }
        return ["Station: \(stationName)", "Current Temperature: \(temperature(current.temperatureC))",
                "High/Low: \(temperature(high, precise: true))/\(temperature(low, precise: true))", "Wind: \(windReading)",
                "Relative Humidity: \(current.humidity.map { "\($0)%" } ?? "n/a")", "Visibility: \(visibilityReading)",
                "Dewpoint: \(temperature(current.dewpointC))", "Barometric Pressure: \(pressureReading)"].joined(separator: "\n")
    }
    private func fittingTitle(_ candidates: [String], value: String, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: settings?.graphFont ?? NSFont.systemFont(ofSize: 10)]
        return candidates.first {
            let text = value.isEmpty ? $0 : $0 + " " + value
            return (text as NSString).size(withAttributes: attributes).width + (value.isEmpty ? 0 : 8) <= width
        } ?? candidates.last ?? ""
    }
    private func updateLabels() {
        let rect = XRGGraphLabels.paddedTextRect(for: bounds)
        let mini = shouldDrawMiniGraph()
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(fullReading())
        guard let current else {
            labels.layout(leftText: fullReading(), centerText: nil, rightText: nil, in: rect, mini: mini, settings: settings); return
        }
        if mini {
            labels.layoutColumnText(stationName, rightText: temperature(current.temperatureC), in: rect, mini: true, settings: settings)
            labels.leftLabel.fullAccessibilityText = fullReading(); return
        }
        let wide = fittingTitle(["Station:", ""], value: stationName, width: rect.width) == "Station:"
        let highLow: String
        if let high, let low {
            highLow = settings?.temperatureUnits == 1 ? String(format: "%.0f°C/%.0f°C", high, low) : "\(Int(high * 1.8 + 32))°F/\(Int(low * 1.8 + 32))°F"
        } else { highLow = "n/a" }
        let values = [wide ? stationName : "", temperature(current.temperatureC), highLow, windReading,
                      current.humidity.map { "\($0)%" } ?? "n/a", visibilityReading, temperature(current.dewpointC), pressureReading]
        let candidates = [["Station:"], ["Current Temperature:", "Temperature:", "Temp:", "T:"], ["High/Low:", "H/L:"], ["Wind:", "W:"],
                          ["Relative Humidity:", "Rel Humidity:", "RH:"], ["Visibility:", "V:"], ["Dewpoint:", "D:"], ["Barometric Pressure:", "Pressure:", "P:"]]
        let attributes: [NSAttributedString.Key: Any] = [.font: settings?.graphFont ?? NSFont.systemFont(ofSize: 10)]
        let measuredValues = values.map { ($0 as NSString).size(withAttributes: attributes).width + 6 }.max() ?? 0
        let rightWidth = min(measuredValues, rect.width * 0.48)
        let titleWidth = max(0, rect.width - rightWidth - (rightWidth > 0 ? min(8, max(0, rect.width - rightWidth)) : 0))
        let titles = candidates.enumerated().map { index, options in
            index == 0 && !wide ? stationName : fittingTitle(options, value: "", width: titleWidth)
        }
        labels.layoutColumnText(titles.joined(separator: "\n"), rightText: values.joined(separator: "\n"), in: rect, mini: false, settings: settings)
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let settings, let context = NSGraphicsContext.current, XRGGraphRenderer.validRect(bounds) else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        updateLabels(); settings.graphBGColor.set(); context.cgContext.fill(bounds)
        if shouldDrawMiniGraph() {
            if let value = current?.temperatureC, let high, let low {
                XRGGraphRenderer.drawMiniValues([NSNumber(value: value)], upperBound: high, lowerBound: low, in: bounds, settings: settings)
            }
        } else {
            context.shouldAntialias = settings.antiAliasing
            for plot in plots() {
                plot.values.withUnsafeBufferPointer { values in
                    XRGGraphRenderer.drawSamples(values.baseAddress, count: values.count, currentIndex: values.count - 1,
                        upperBound: plot.upper, lowerBound: plot.lower, in: bounds, flipped: false, filled: plot.filled,
                        color: plot.filled ? settings.graphFG1Color : settings.graphFG2Color)
                }
            }
        }
        XRGGraphRenderer.drawStyle(in: bounds, settings: settings)
    }
    @nonobjc func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Weather View")
        let lines = ["Current Conditions for \(stationName)...", "Temperature: \(temperature(current?.temperatureC))",
                     "Last 24 hour high temperature: \(temperature(high, precise: true))", "Last 24 hour low temperature: \(temperature(low, precise: true))",
                     "Wind: \(windReading)", "Relative Humidity: \(current?.humidity.map { "\($0)%" } ?? "n/a")",
                     "Visibility: \(visibilityReading)", "Dewpoint: \(temperature(current?.dewpointC))", "Barometric Pressure: \(pressureReading)"]
        for line in lines { menu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        for (title, selector) in [("Update Weather Graph Now", #selector(min30Update(_:))), ("Open XRG-ng Weather Preferences...", #selector(openWeatherPreferences(_:)))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
            if title == "Update Weather Graph Now" { menu.addItem(.separator()) }
        }
        return menu
    }
    public override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
    public func emptyEvent(_ sender: Any?) {}
    public func openWeatherPreferences(_ sender: Any?) { host?.showWeatherPreferences() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    public override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    public override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
}
