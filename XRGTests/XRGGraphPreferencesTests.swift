// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import Testing
@testable import XRGCore

@Suite(.serialized) @MainActor
struct XRGGraphPreferencesTests {
    private func withSettings(_ body: (XRGSettings, UserDefaults) throws -> Void) throws {
        let t = TestDefaults(prefix: "XRG.graph-options.")
        let defaults = t.defaults; defer { t.cleanUp() }
        defaults.set(3, forKey: "graphStyle"); defaults.set(333, forKey: "aiTokensDailyBudget")
        let settings = XRGSettings(defaults: defaults)
        settings.graphFG1Transparency = 1; settings.graphFG1Color = .blue
        try body(settings, defaults)
    }
    @Test func presentationRoundTripAndInheritanceStayIndependentOfTheGlobalTheme() throws {
        try withSettings { settings, defaults in
            var value = XRGGraphPreferences(); value.order = Array(XRGGraphID.allCases.reversed())
            value[.cpu].height = 128; value[.cpu].curve = .hollow; value[.cpu].effect = 1
            value[.cpu].colors[1] = [1, 0, 0, 0.5]
            try settings.applyGraphPreferences(value)
            #expect(XRGSettings(defaults: defaults).graphPreferences == value)
            #expect(settings.graphColor(.cpu, component: 1).alphaComponent == 0.5)
            #expect(settings.graphColor(.gpu, component: 1) == .blue)
            settings.graphFG1Color = .green
            #expect(settings.graphColor(.cpu, component: 1).usingColorSpace(.sRGB)?.redComponent == 1)
            #expect(settings.graphColor(.gpu, component: 1) == .green)
            #expect(settings.graphEffect(.cpu) == 1 && settings.graphEffect(.gpu) == 3)
            #expect(settings.curveStyle(.cpu) == .hollow && settings.curveStyle(.gpu) == nil)
            #expect(defaults.integer(forKey: "graphStyle") == 3 && defaults.integer(forKey: "aiTokensDailyBudget") == 333)
            value[.cpu] = XRGGraphOverride(); try settings.applyGraphPreferences(value)
            #expect(settings.graphColor(.cpu, component: 1) == .green)
            #expect(settings.curveStyle(.cpu) == nil && settings.graphEffect(.cpu) == 3)
        }
    }
    @Test func malformedSavedOptionsArePreservedUntilAnExplicitValidApply() throws {
        try withSettings { _, defaults in
            let original = Data("{\"version\":999}".utf8); defaults.set(original, forKey: XRGGraphPreferences.key)
            let settings = XRGSettings(defaults: defaults)
            #expect(settings.graphPreferences == XRGGraphPreferences() && settings.graphPreferencesError != nil)
            #expect(defaults.data(forKey: XRGGraphPreferences.key) == original)
            var value = XRGGraphPreferences(); value[.cpu].height = 63
            #expect(throws: (any Error).self) { try settings.applyGraphPreferences(value) }
            #expect(defaults.data(forKey: XRGGraphPreferences.key) == original)
            value[.cpu].height = 128; try settings.applyGraphPreferences(value)
            #expect(settings.graphPreferencesError == nil && settings.graphPreferences == value)
        }
    }
    @Test func invalidOrderColorsDimensionsAndVersionsAreRejected() throws {
        var bad: [XRGGraphPreferences] = []
        var value = XRGGraphPreferences(); value.version = 2; bad.append(value)
        value = XRGGraphPreferences(); value.order = [.cpu, .cpu]; bad.append(value)
        value = XRGGraphPreferences(); value[.cpu].height = 241; bad.append(value)
        value = XRGGraphPreferences(); value[.cpu].effect = 4; bad.append(value)
        value = XRGGraphPreferences(); value[.cpu].colors = [nil]; bad.append(value)
        value = XRGGraphPreferences(); value[.cpu].colors[3] = [1, 1, 1, -.infinity]; bad.append(value)
        value = XRGGraphPreferences(); value.overrides["unknown"] = XRGGraphOverride(); bad.append(value)
        for item in bad { #expect(throws: (any Error).self) { try item.encoded() } }
    }
}
