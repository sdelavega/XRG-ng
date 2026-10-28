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

@MainActor private final class WeatherSource: XRGWeatherTransport {
    var address: String?
    var loads = 0
    var cancellations = 0
    var ready = false
    var failed = false
    var data: Data?
    func setURLString(_ value: String?) { address = value }
    func loadURLInBackground() { loads += 1; ready = false; failed = false; data = nil }
    func cancelLoading() { cancellations += 1; ready = false; failed = false; data = nil }
    func isDataReady() -> Bool { ready }
    func didErrorOccur() -> Bool { failed }
    func getData() -> Data? { data }
    func complete(_ text: String) { data = Data(text.utf8); ready = true }
}
@MainActor private final class WeatherHost: NSWindow, XRGWeatherViewHost, XRGModuleWindow {
    var appSettings: XRGSettings?
    var moduleManager: XRGModuleManager?
    var weatherView: XRGWeatherView?
    var minimized = false
    var borderWidth: Int32 = 2
    var timerRequests = 0
    var preferencesOpened = 0
    var woke = false
    var mouseEvents: [String] = []
    init(settings: XRGSettings) {
        appSettings = settings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false; moduleManager = XRGModuleManager(window: self)
    }
    func initTimers() { timerRequests += 1 }
    func checkWindowSize() {}
    func showWeatherPreferences() { preferencesOpened += 1 }
    func systemJustWokeUp() -> Bool { woke }
    func setSystemJustWokeUp(_ value: Bool) { woke = value }
    override func mouseDown(with event: NSEvent) { mouseEvents.append("down") }
    override func mouseDragged(with event: NSEvent) { mouseEvents.append("drag") }
    override func mouseUp(with event: NSEvent) { mouseEvents.append("up") }
}
@MainActor private final class WeatherFixture {
    let domain = "XRG.weatherView.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: XRGSettings
    let sources = [WeatherSource(), WeatherSource()]
    let view: XRGWeatherView
    var host: WeatherHost?
    let history = "KSEA 251953Z 21016G24KT 1 1/2SM 20/10 A2992 RMK AO2\nKSEA 251853Z VRB03KT 9999 10/05 Q1013 RMK AO2\nKSEA 251753Z 00000KT 1/2SM 05/00 A3000 RMK AO2"
    init(show: Bool = true) throws {
        _ = NSApplication.shared
        defaults = try #require(UserDefaults(suiteName: domain)); defaults.set(show, forKey: "showWeatherGraph")
        settings = XRGSettings(defaults: defaults); settings.ICAO = "KSEA"
        settings.graphFont = NSFont.systemFont(ofSize: 10); settings.graphRefresh = 0.2
        settings.textTransparency = 1; settings.textColor = .black
        settings.graphBGTransparency = 1; settings.graphBGColor = .white
        settings.graphFG1Transparency = 0.25; settings.graphFG1Color = .red
        settings.graphFG2Transparency = 1; settings.graphFG2Color = .blue
        view = XRGWeatherView(frame: NSRect(x: 0, y: 0, width: 240, height: 180), settings: settings, defaults: defaults, sources: sources)
    }
    func attach() {
        let host = WeatherHost(settings: settings); self.host = host
        host.contentView?.addSubview(view); view.awakeFromNib()
    }
    func cleanUp() { view.removeFromSuperview(); view.cancelLoading(); host?.close(); defaults.removePersistentDomain(forName: domain) }
    func seed() { view.setMETARFromText(history) }
}
private final class WeatherNibOwner: NSObject {}

private actor WeatherRequests {
    private var next = 0
    private var pending: [Int: CheckedContinuation<Data, Never>] = [:]
    func request() async -> Data {
        let id = next; next += 1
        return await withCheckedContinuation { pending[id] = $0 }
    }
    func count() -> Int { next }
    func resolve(_ id: Int, _ text: String) { pending.removeValue(forKey: id)?.resume(returning: Data(text.utf8)) }
    func finishAll() { for continuation in pending.values { continuation.resume(returning: Data()) }; pending = [:] }
}

@Suite(.serialized) @MainActor
struct XRGWeatherViewTests {
    private func png(_ view: XRGWeatherView) throws -> Data {
        view.needsDisplay = true
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }
    @Test func registrationVisibilityFontSizingAndDetachment() throws {
        let f = try WeatherFixture(show: false); defer { f.cleanUp() }; f.attach()
        let host = try #require(f.host), module = try #require(f.view.module)
        f.view.awakeFromNib(); f.view.awakeFromNib()
        #expect(module.name == "Weather" && module.displayOrder == 8 && module.reference === f.view)
        #expect(module.doesGraphUpdate && module.doesMin30Update && !module.doesFastUpdate && !module.doesMin5Update)
        #expect(!module.isDisplayed && host.weatherView === f.view && host.timerRequests == 1)
        #expect(f.sources.allSatisfy { $0.loads == 0 } && f.view.tickerTimer == nil && f.view.subviews.count == 3)
        let width = module.minWidth; f.settings.graphFont = NSFont.systemFont(ofSize: 28); f.view.updateMinSize()
        #expect(module.minWidth > width && module.minHeight == f.settings.textRectHeight)
        host.moduleManager?.setModule("Weather", isDisplayed: true)
        #expect(f.sources.allSatisfy { $0.loads == 1 } && f.view.gettingData && f.view.tickerTimer != nil)
        let timer = try #require(f.view.tickerTimer)
        f.view.removeFromSuperview()
        #expect(!timer.isValid && f.view.tickerTimer == nil && !f.view.gettingData)
        #expect(f.view.module == nil && host.weatherView == nil && host.moduleManager?.moduleList().isEmpty == true)
    }
    @Test func managerReplacementRemovesOnlyOwnedRegistrations() throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }; f.attach()
        let host = try #require(f.host), first = try #require(host.moduleManager)
        let replacement = XRGModule(name: "Weather", reference: NSView(), defaults: f.defaults)
        first.addModule(replacement)
        f.view.removeFromSuperview()
        #expect(first.getModule(byName: "Weather") === replacement)
        host.contentView?.addSubview(f.view); f.view.awakeFromNib()
        let old = try #require(f.view.module)
        host.moduleManager = XRGModuleManager(window: host); f.view.awakeFromNib()
        #expect(first.getModule(byReference: f.view) == nil && f.view.module !== old)
        #expect(host.moduleManager?.moduleList().count == 1 && host.weatherView === f.view)
    }
    @Test(arguments: ["primary", "secondary", "primaryInvalid", "primaryError", "secondaryEarly", "bothReady"])
    func eitherSourceCanCompleteAndTheFirstUsableResultCancelsBoth(path: String) throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }; f.attach()
        f.view.awakeFromNib(); #expect(f.sources.allSatisfy { $0.loads == 1 })
        switch path {
        case "primary": f.sources[0].complete(f.history)
        case "bothReady": f.sources[0].complete(f.history); f.sources[1].complete("KSEA 252053Z 30/20 A2992")
        case "secondary", "secondaryEarly": f.sources[1].complete(f.history)
        case "primaryInvalid": f.sources[0].complete("<html>unavailable</html>"); f.sources[1].complete(f.history)
        default: f.sources[0].failed = true; f.sources[1].complete(f.history)
        }
        let timer = try #require(f.view.tickerTimer)
        f.view.ticker()
        #expect(!f.view.gettingData && !f.view.hasInvalidData() && f.view.reports.count == 3)
        #expect(f.view.current?.temperatureC == 20 && f.view.high == 20 && f.view.low == 5)
        #expect(!timer.isValid && f.view.tickerTimer == nil && f.sources.allSatisfy { !$0.ready })
        f.sources[0].complete("KSEA 252053Z 30/20 A2999"); f.view.min30UpdatePostProcessing()
        #expect(f.view.current?.temperatureC == 20)
    }
    @Test func invalidFirstResultWaitsForPendingFallbackAndBothFailuresStopTheTicker() throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }; f.attach()
        f.sources[0].complete("bad"); f.view.ticker()
        #expect(f.view.gettingData && !f.view.hasInvalidData())
        f.sources[1].failed = true; f.view.ticker()
        #expect(!f.view.gettingData && f.view.hasInvalidData() && f.view.tickerTimer == nil)
        #expect(f.view.labels.leftLabel.stringValue == "Invalid Data")
        f.view.min30Update(nil); #expect(f.view.labels.leftLabel.stringValue == "Fetching Data")
        f.sources[0].data = Data([0xff, 0xfe]); f.sources[0].ready = true
        f.sources[1].complete("KJFK 251953Z 20/10 A2992"); f.view.ticker()
        #expect(f.view.hasInvalidData() && f.view.reports.isEmpty)
    }
    @Test func stationChangeCancelsResetsAndCannotReuseTheOldStation() throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }; f.attach(); f.seed()
        f.settings.ICAO = " kjfk\n"; f.view.setURL(f.settings.ICAO)
        #expect(f.view.stationName == "KJFK" && f.view.reports.isEmpty && !f.view.gettingData)
        #expect(f.sources[0].address?.hasSuffix("ids=KJFK") == true && f.sources[1].address?.hasSuffix("metarIds=KJFK") == true)
        f.view.min30Update(nil); f.sources[0].complete(f.history); f.view.ticker()
        #expect(f.view.gettingData && f.view.current == nil)
        f.sources[1].complete("KJFK 251953Z 18010KT 10SM 25/15 A2992"); f.view.ticker()
        #expect(f.view.current?.temperatureC == 25 && !f.view.gettingData)
        let cancellations = f.sources[0].cancellations
        f.view.setURL("KJFK"); #expect(f.sources[0].cancellations == cancellations)
        f.settings.ICAO = "KSEA&ids=KJFK"; f.view.setURL(f.settings.ICAO); f.view.min30Update(nil)
        #expect(f.sources.allSatisfy { $0.address == nil } && !f.view.gettingData && f.view.hasInvalidData())
    }
    @Test func productionURLAdaptersRejectLateResultsAfterStationChanges() async throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }
        let requests = WeatherRequests()
        let sources = [XRGURL(transport: { _ in await requests.request() }), XRGURL(transport: { _ in await requests.request() })]
        let view = XRGWeatherView(frame: f.view.frame, settings: f.settings, defaults: f.defaults, sources: sources)
        defer { view.cancelLoading() }
        view.min30Update(nil)
        for _ in 0..<100 where await requests.count() < 2 { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await requests.count() == 2)
        f.settings.ICAO = "KJFK"; view.setURL("KJFK"); view.min30Update(nil)
        for _ in 0..<100 where await requests.count() < 4 { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await requests.count() == 4)
        await requests.resolve(0, f.history); await requests.resolve(1, f.history)
        for _ in 0..<5 { await Task.yield() }
        view.min30UpdatePostProcessing(); #expect(view.current == nil && view.gettingData)
        let response = "KJFK 251953Z 18010KT 10SM 25/15 A2992"
        await requests.resolve(2, response); await requests.resolve(3, response)
        for _ in 0..<100 where !sources.contains(where: { $0.isDataReady() }) { try await Task.sleep(for: .milliseconds(1)) }
        view.min30UpdatePostProcessing()
        #expect(view.stationName == "KJFK" && view.current?.temperatureC == 25 && !view.gettingData)
        await requests.finishAll()
    }

    @Test func fractionalRefreshRetriesAfterFiveMinutesAndIgnoresInvalidIntervals() throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }
        f.settings.graphRefresh = 0.25
        for _ in 0..<1199 { f.view.graphUpdate(nil) }
        #expect(f.sources.allSatisfy { $0.loads == 0 } && f.view.retryElapsed == 299.75)
        f.view.graphUpdate(nil)
        #expect(f.sources.allSatisfy { $0.loads == 1 } && f.view.gettingData && f.view.retryElapsed == 0)
        f.sources.forEach { $0.failed = true }; f.view.min30UpdatePostProcessing()
        for refresh in [Double.nan, Double.infinity, -1, 0] { f.settings.graphRefresh = refresh; f.view.graphUpdate(nil) }
        #expect(f.view.retryElapsed == 0 && f.sources.allSatisfy { $0.loads == 1 })
    }
    @Test func wakeRefreshesOnceAndHidingCancelsWorkUntilDisplayedAgain() throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }; f.attach()
        let host = try #require(f.host)
        host.woke = true; f.view.graphUpdate(nil); #expect(!host.woke && f.sources.allSatisfy { $0.loads == 2 })
        f.view.graphUpdate(nil); #expect(f.sources.allSatisfy { $0.loads == 2 })
        host.moduleManager?.setModule("Weather", isDisplayed: false)
        host.moduleManager?.windowChanged(to: host.frame.size)
        #expect(!f.view.gettingData && f.view.tickerTimer == nil)
        f.view.min30Update(nil); #expect(f.sources.allSatisfy { $0.loads == 2 })
        host.moduleManager?.setModule("Weather", isDisplayed: true)
        #expect(f.view.gettingData && f.sources.allSatisfy { $0.loads == 3 })
    }
    @Test(arguments: Array(0...5))
    func historicalTemperatureAndSecondaryPlotsUseOneUnitAndSkipMissingValues(selection: Int) throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }; f.seed(); f.settings.secondaryWeatherGraph = selection
        let plots = f.view.plots(), primary = try #require(plots.first)
        #expect(primary.values == [5, 10, 20] && primary.lower == -5 && primary.upper == 30 && primary.filled)
        #expect(plots.count == (selection == 0 ? 1 : 2))
        if selection != 0 {
            let second = plots[1]
            #expect(!second.filled && second.lower.isFinite && second.upper > second.lower)
            switch selection {
            case 1: #expect(second.values == [0, 3, 16] && second.lower == 0 && abs(second.upper - 17.6) < 0.0001)
            case 2: #expect(second.values.last == 52 && second.upper == 100)
            case 3: #expect(second.values.first == 0.5 && second.values.last == 1.5)
            case 4: #expect(second.values == [0, 5, 10] && second.lower == -1 && second.upper == 11)
            default: #expect(abs(second.values[0] - 30) < 0.0001 && abs(second.lower - 29.914 * 0.99) < 0.1 && second.upper < 31)
            }
        }
        f.view.setMETARFromText("KSEA 251953Z 20/10 A2992\nKSEA 251853Z ////\nKSEA 251753Z M05/M10 Q1013")
        #expect(f.view.plots()[0].values == [-5, -1000, 20] && f.view.low == -5)
        #expect(f.view.getSecondaryGraphList() == ["None", "Wind Speed", "Relative Humidity", "Visibility", "Dewpoint", "Pressure"])
    }
    @Test func zeroAndMissingSecondaryRangesStayFiniteAndNeverUseSentinelsAsExtrema() throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }
        f.view.setMETARFromText("KSEA 251953Z 00000KT 0000 00/00 Q1013\nKSEA 251853Z ////")
        for selection in 1...5 {
            f.settings.secondaryWeatherGraph = selection
            let plot = try #require(f.view.plots().last)
            #expect(plot.values[0] == -1000 && plot.lower.isFinite && plot.upper > plot.lower)
            #expect(plot.lower > -1000)
        }
        f.view.setMETARFromText("KSEA 251953Z ////")
        #expect(f.view.plots().isEmpty && f.view.high == nil && f.view.low == nil)
        #expect(f.view.fullReading().contains("Dewpoint: n/a") && f.view.fullReading().contains("Wind: n/a"))
    }
    @Test(arguments: [0, 1])
    func unitsMenusAndAccessibleReadingsStayComplete(units: Int) throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }; f.attach(); f.seed()
        f.settings.temperatureUnits = units; f.settings.distanceUnits = units; f.settings.pressureUnits = units
        f.view.setGraphSize(NSSize(width: 280, height: 180))
        let reading = f.view.fullReading()
        #expect(reading.contains(units == 0 ? "68°F" : "20.0°C"))
        #expect(reading.contains("Wind: SSW 16 kt Gusts: 24 kt") && reading.contains("52%"))
        #expect(reading.contains(units == 0 ? "1.50 mi" : "2.4 km"))
        #expect(reading.contains(units == 0 ? "29.92in" : "1013hPa"))
        #expect(f.view.accessibilityLabel() == reading)
        let menu = f.view.makeMenu()
        #expect(menu.items.filter { !$0.isSeparatorItem && $0.action == nil }.count == 9)
        for item in menu.items where item.action != nil {
            #expect(item.target === f.view)
            let selector = try #require(item.action)
            #expect(NSApp.sendAction(selector, to: item.target, from: item))
        }
        #expect(f.host?.preferencesOpened == 1 && f.view.gettingData)
    }
    @Test(arguments: [CGFloat(8), 14, 28], [CGFloat(18), 80, 240])
    func measuredColumnsRemainSeparateAndExposeClippedRows(font: CGFloat, width: CGFloat) throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }; f.seed()
        f.settings.graphFont = NSFont.systemFont(ofSize: font)
        f.view.setGraphSize(NSSize(width: width, height: 4 * f.settings.textRectHeight)); f.view.updateMinSize()
        #expect(f.view.labels.leftLabel.frame.maxX <= f.view.labels.rightLabel.frame.minX)
        if font == 28 && width == 240 { #expect(f.view.labels.leftLabel.stringValue.components(separatedBy: "\n")[1] == "Temp:") }
        let completeValues = try #require(f.view.labels.rightLabel.fullAccessibilityText)
        #expect(completeValues.contains("hPa") || completeValues.contains("in"))
        #expect(!f.view.labels.leftLabel.stringValue.contains("Dewpoint:"))
        #expect(f.view.accessibilityLabel()?.contains("Dewpoint:") == true)
        f.view.setGraphSize(NSSize(width: width, height: f.settings.textRectHeight))
        #expect(f.view.shouldDrawMiniGraph() && f.view.labels.leftLabel.stringValue == "KSEA")
        #expect(f.view.labels.leftLabel.fullAccessibilityText == f.view.fullReading())
    }
    @Test func validInvalidFetchingCompactAndGraphStylesRenderToNativeBitmaps() throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }
        let invalid = try png(f.view)
        f.view.min30Update(nil); let fetching = try png(f.view)
        f.seed(); let valid = try png(f.view)
        #expect(invalid != fetching && fetching != valid)
        for style in 0...3 { f.settings.graphStyle = style; #expect(!(try png(f.view)).isEmpty) }
        f.view.setGraphSize(NSSize(width: 240, height: 10)); #expect(!(try png(f.view)).isEmpty)
        f.view.setGraphSize(NSSize(width: 0, height: 0)); #expect(f.view.graphSize == .zero)
        f.view.setGraphSize(NSSize(width: .infinity, height: -.infinity)); #expect(f.view.graphSize == .zero)
        #expect(f.view.convertHeight(.nan) == 0 && f.view.convertHeight(-1) == 0)
    }
    @Test func mouseEventsAndFirstClickReachTheWindow() throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }; f.attach()
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: f.host!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(f.view.acceptsFirstMouse(for: event))
        f.view.mouseDown(with: event); f.view.mouseDragged(with: event); f.view.mouseUp(with: event)
        #expect(f.host?.mouseEvents == ["down", "drag", "up"])
    }
    @Test(arguments: ["WeatherView", "LegacyWeather"])
    func decodesCurrentAndLegacyNibWithoutStartingRequests(name: String) throws {
        _ = NSApplication.shared
        let nib = try #require(NSNib(nibNamed: name, bundle: Bundle(for: WeatherNibOwner.self)))
        var objects: NSArray?
        #expect(nib.instantiate(withOwner: WeatherNibOwner(), topLevelObjects: &objects))
        let view = try #require(objects?.compactMap { $0 as? XRGWeatherView }.first)
        #expect(view.frame.size == NSSize(width: 76, height: 76) && view.module == nil)
        #expect(view.subviews.count == 3 && !view.gettingData && view.tickerTimer == nil)
    }
    @Test func tickerDoesNotRetainTheViewAfterDetachment() throws {
        let f = try WeatherFixture(); defer { f.cleanUp() }; f.attach()
        let timer = try #require(f.view.tickerTimer)
        f.view.removeFromSuperview(); #expect(!timer.isValid)
        weak var weakView: XRGWeatherView?
        autoreleasepool {
            var view: XRGWeatherView? = XRGWeatherView(frame: .zero, settings: f.settings, defaults: f.defaults, sources: [WeatherSource(), WeatherSource()])
            f.host?.contentView?.addSubview(view!); view?.awakeFromNib()
            weakView = view
            #expect(view?.tickerTimer != nil)
            view?.removeFromSuperview(); view = nil
        }
        #expect(weakView == nil)
    }
}
