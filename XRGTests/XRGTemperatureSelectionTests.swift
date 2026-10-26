import Foundation
import Testing
@testable import XRGCore

struct XRGTemperatureSelectionTests {
    @Test func persistenceAndLegacyRepair() throws {
        let suite = "XRG.selection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "tempLocationsAutoconfigured")
        let settings = XRGSettings(defaults: defaults)
        settings.tempFG1Location = "0"
        settings.tempFG2Location = "1"
        settings.tempFG3Location = "2"
        #expect(settings.configureTemperatureSensors(["TC0P", "TC0P", "TG0P"]))
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(reopened.string(forKey: "tempFG1Location") == "TC0P")
        #expect(reopened.string(forKey: "tempFG2Location") == "TG0P")
        #expect(reopened.string(forKey: "tempFG3Location") == "")
        #expect(!settings.configureTemperatureSensors(["other"]))
    }

    @Test func waitForDiscoveryAndPreserveSelection() throws {
        let suite = "XRG.selection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = XRGSettings(defaults: defaults)
        #expect(!settings.configureTemperatureSensors([]))
        #expect(!defaults.bool(forKey: "tempLocationsAutoconfigured"))
        settings.tempFG1Location = "temporarily-unavailable"
        #expect(!settings.configureTemperatureSensors(["new"]))
        settings.tempFG1Location = ""
        defaults.set(true, forKey: "tempLocationsAutoconfigured")
        #expect(!settings.configureTemperatureSensors(["new"]))
        #expect(settings.tempFG1Location.isEmpty)
    }
}
