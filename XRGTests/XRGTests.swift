import AppKit
import Foundation
import Testing
import XRGCore

@MainActor
struct XRGThemeTests {
    let colorKeys = ["backgroundColor", "graphBGColor", "graphFG1Color", "graphFG2Color",
                     "graphFG3Color", "borderColor", "textColor"]
    let alphaKeys = ["backgroundTransparency", "graphBGTransparency", "graphFG1Transparency",
                     "graphFG2Transparency", "graphFG3Transparency", "borderTransparency", "textTransparency"]

    func theme(secure: Bool = true) throws -> [String: Any] {
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: NSColor.red, requiringSecureCoding: secure)
        var result: [String: Any] = [:]
        for key in colorKeys { result[key] = archive }
        for key in alphaKeys { result[key] = 0.5 }
        return result
    }

    @Test(arguments: [true, false])
    func importsExistingAndSecureArchives(secure: Bool) throws {
        let domain = "XRGThemeTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = XRGSettings()
        try settings.applyThemeDictionary(theme(secure: secure), defaults: defaults)
        #expect(settings.backgroundTransparency == 0.5)
        #expect(settings.backgroundColor.alphaComponent == 0.5)
        #expect(defaults.double(forKey: "textTransparency") == 0.5)
        let archived = try #require(defaults.data(forKey: "textColor"))
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: archived)
        let restored = try #require(decoded)
        #expect(restored.alphaComponent == 0.5)
        #expect(restored.usingColorSpace(.deviceRGB)?.redComponent == 1)
    }

    @Test(arguments: ["missingColor", "badArchive", "wrongArchiveClass", "stringAlpha",
                      "negativeAlpha", "largeAlpha", "nanAlpha", "infiniteAlpha", "booleanAlpha",
                      "missingAlpha", "wrongRoot"])
    func rejectsWithoutChangingSettingsOrDefaults(failure: String) throws {
        let domain = "XRGThemeTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = XRGSettings()
        settings.backgroundColor = .blue
        settings.backgroundTransparency = 0.75
        defaults.set("unchanged", forKey: "sentinel")
        let original = defaults.persistentDomain(forName: domain) ?? [:]
        let originalColor = settings.backgroundColor
        var candidate = try theme()
        // Corrupt the final fields to catch implementations that apply earlier ones first.
        switch failure {
        case "missingColor": candidate.removeValue(forKey: "textColor")
        case "badArchive": candidate["textColor"] = Data([0, 1, 2])
        case "wrongArchiveClass":
            candidate["textColor"] = try NSKeyedArchiver.archivedData(withRootObject: NSDate(), requiringSecureCoding: true)
        case "stringAlpha": candidate["textTransparency"] = "0.5"
        case "negativeAlpha": candidate["textTransparency"] = -0.1
        case "largeAlpha": candidate["textTransparency"] = 1.1
        case "nanAlpha": candidate["textTransparency"] = Double.nan
        case "infiniteAlpha": candidate["textTransparency"] = Double.infinity
        case "booleanAlpha": candidate["textTransparency"] = true
        case "missingAlpha": candidate.removeValue(forKey: "textTransparency")
        default: break
        }
        let input: Any = failure == "wrongRoot" ? ["invalid"] : candidate
        #expect(throws: (any Error).self) {
            try settings.applyThemeDictionary(input, defaults: defaults)
        }
        #expect(settings.backgroundColor == originalColor)
        #expect(settings.backgroundTransparency == 0.75)
        #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:])
            .isEqual(to: original))
    }

    @Test(arguments: [0.0, 1.0])
    func acceptsTransparencyBoundaries(alpha: Double) throws {
        let domain = "XRGThemeTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var candidate = try theme()
        for key in alphaKeys { candidate[key] = alpha }
        candidate["unknownFutureField"] = "ignored"
        let settings = XRGSettings()
        try settings.applyThemeDictionary(candidate, defaults: defaults)
        #expect(settings.textColor.alphaComponent == CGFloat(alpha))
        #expect(defaults.object(forKey: "unknownFutureField") == nil)
    }
}
