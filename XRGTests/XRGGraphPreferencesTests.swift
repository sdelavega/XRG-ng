// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import AppKit
import Testing
@testable import XRGCore

@Suite(.serialized) @MainActor
struct XRGGraphPreferencesTests {
    private func withSettings(_ body: (XRGSettings, UserDefaults) throws -> Void) throws {
        let name = "XRG.graph-options.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
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
    @Test func graphEditorDraftApplyCancelInvalidInputAndExternalChangesAreTransactional() throws {
        try withSettings { settings, defaults in
            _ = NSApplication.shared
            var visibility = Dictionary(uniqueKeysWithValues: XRGGraphID.allCases.map { ($0, true) })
            var applies = 0
            let editor = XRGGraphPreferencesEditor(manager: nil, settings: settings, visibility: { visibility }, apply: { value, next in
                try settings.applyGraphPreferences(value); visibility = next; applies += 1
            })
            editor.customHeight.state = .on; editor.heightField.integerValue = 128
            editor.curvePicker.selectItem(at: 4)
            editor.moveGraphDown(nil)
            #expect(editor.draft.order?.first == .gpu && settings.graphPreferences.order == nil)
            #expect(defaults.data(forKey: XRGGraphPreferences.key) == nil)
            editor.cancel(nil)
            #expect(editor.draft == XRGGraphPreferences() && applies == 0)
            editor.customHeight.state = .on; editor.heightField.stringValue = "not a height"
            editor.refreshIfClean()
            #expect(editor.heightField.stringValue == "not a height")
            #expect(!editor.apply(nil) && applies == 0)
            #expect(defaults.data(forKey: XRGGraphPreferences.key) == nil)
            editor.heightField.integerValue = 128; editor.curvePicker.selectItem(at: 4)
            let useColor = try #require(editor.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Series 1" })
            useColor.state = .on
            let wells = editor.subviews.compactMap { $0 as? NSColorWell }
            wells[1].color = .red
            let opacity = editor.subviews.compactMap { $0 as? NSSlider }
            opacity[1].doubleValue = 0.5
            #expect(editor.apply(nil) && applies == 1)
            #expect(settings.graphPreferences[.cpu].height == 128 && settings.graphPreferences[.cpu].curve == .hollow)
            #expect(settings.graphPreferences[.cpu].colors[1] == [1, 0, 0, 0.5])
            #expect(settings.graphColor(.gpu, component: 1) == .blue)
            editor.heightField.integerValue = 144
            editor.refreshIfClean()
            #expect(editor.draft[.cpu].height == 144 && settings.graphPreferences[.cpu].height == 128)
            editor.customHeight.state = .off
            visibility[.weather] = false
            #expect(!editor.apply(nil) && applies == 1)
            #expect(settings.graphPreferences[.cpu].height == 128)
            editor.cancel(nil)
            #expect(editor.visibility[.weather] == false)
            editor.resetSelected(nil); #expect(editor.apply(nil) && settings.graphPreferences[.cpu].isEmpty)
        }
    }
}
