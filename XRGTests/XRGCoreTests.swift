import AppKit
import Foundation
import Testing
import XRGCore

struct XRGDataSetTests {
    private func dataSet(_ values: [CGFloat]) -> XRGDataSet {
        let data = XRGDataSet()
        data.resize(values.count)
        for value in values { data.setNextValue(value) }
        return data
    }

    @Test func ringOrderAndOverwrite() {
        let data = dataSet([1, 2, 3])
        #expect(data.orderedValues == [1, 2, 3])
        data.setNextValue(4)
        #expect(data.orderedValues == [2, 3, 4])
        #expect(data.currentValue == 4)
        #expect(data.min == 2)
        #expect(data.max == 4)
        #expect(data.sum == 9)
        #expect(data.average == 3)
    }

    @Test func resizePreservesNewestAndPadsWithZero() {
        let data = dataSet([1, 2, 3, 4])
        data.resize(2)
        #expect(data.orderedValues == [3, 4])
        #expect(data.min == 3)
        #expect(data.sum == 7)
        data.resize(4)
        #expect(data.orderedValues == [0, 0, 3, 4])
        #expect(data.min == 0)
        data.setNextValue(5)
        #expect(data.orderedValues == [0, 3, 4, 5])
    }

    @Test func emptyAndResetStatistics() {
        let data = dataSet([2, 4])
        data.reset()
        #expect(data.orderedValues == [0, 0])
        #expect(data.sum == 0 && data.min == 0 && data.max == 0)
        data.resize(0)
        data.setNextValue(9)
        #expect(data.currentValue == 0 && data.average == 0)
        #expect(data.orderedValues.isEmpty)
        data.resize(2)
        data.setNextValue(8)
        #expect(data.orderedValues == [0, 8])
    }

    @Test func copyIsIndependent() throws {
        let original = dataSet([1, 2, 3])
        let copy = try #require(XRGDataSet(contentsOfOtherDataSet: original))
        copy.setNextValue(99)
        #expect(original.orderedValues == [1, 2, 3])
        #expect(copy.orderedValues == [2, 3, 99])
        copy.copyValues(from: original)
        original.setNextValue(4)
        #expect(copy.orderedValues == [1, 2, 3])
        #expect(XRGDataSet(contentsOfOtherDataSet: nil) == nil)
    }

    @Test func vectorArithmeticAndNegativeDivision() {
        let data = dataSet([2, 4, 6])
        let other = dataSet([1, 2, 3])
        data.addOtherDataSetValues(other)
        #expect(data.orderedValues == [3, 6, 9])
        data.subtractOtherDataSetValues(other)
        #expect(data.orderedValues == [2, 4, 6])
        data.divideAllValues(by: -2)
        #expect(data.orderedValues == [-1, -2, -3])
        #expect(data.min == -3 && data.max == -1)
        #expect(data.sum == -6 && data.average == -2)
        data.divideAllValues(by: 0)
        data.addOtherDataSetValues(dataSet([1]))
        data.subtractOtherDataSetValues(nil)
        #expect(data.orderedValues == [-1, -2, -3])
    }

    @Test func rendererCopyAndFill() {
        let data = dataSet([1, 2, 3])
        var output = [CGFloat](repeating: -1, count: 3)
        output.withUnsafeMutableBufferPointer { data.valuesInOrder($0.baseAddress) }
        #expect(output == [1, 2, 3])
        data.setAllValues(5)
        #expect(data.sum == 15 && data.average == 5)
        #expect(data.min == 5 && data.max == 5)
    }
}

struct XRGStatisticsTests {
    @Test func firstSampleCountedOnce() throws {
        let stats = XRGStatsManager()
        stats.observeStat(10, forKey: "CPU", inModule: .nameTemperature)
        stats.observeStat(20, forKey: "CPU", inModule: .nameTemperature)
        let item = try #require(stats.stat(forKey: "CPU", inModule: .nameTemperature))
        #expect(item.average == 15)
        #expect(item.min == 10 && item.max == 20 && item.last == 20)
        stats.observeStat(30, forKey: "CPU", inModule: .nameTemperature)
        #expect(item.average == 15) // Returned snapshots remain stable.
        #expect(stats.stat(forKey: "CPU", inModule: .nameTemperature)?.average == 20)
    }

    @Test func clearingOneModulePreservesOthers() {
        let stats = XRGStatsManager()
        stats.observeStat(1, forKey: "value", inModule: .nameCPU)
        stats.observeStat(2, forKey: "value", inModule: .nameGPU)
        stats.clearHistory(forModule: .nameCPU)
        #expect(stats.stat(forKey: "value", inModule: .nameCPU) == nil)
        #expect(stats.stat(forKey: "value", inModule: .nameGPU)?.last == 2)
        stats.clearHistory()
        #expect(stats.stat(forKey: "value", inModule: .nameGPU) == nil)
    }

    @Test func concurrentSamplesAreSerialized() async {
        let stats = XRGStatsManager()
        await withTaskGroup(of: Void.self) { group in
            for value in 1...100 {
                group.addTask { stats.observeStat(Double(value), forKey: "value", inModule: .nameCPU) }
            }
        }
        let result = stats.stat(forKey: "value", inModule: .nameCPU)
        #expect(abs((result?.average ?? 0) - 50.5) < 0.000001)
        #expect(result?.min == 1 && result?.max == 100)
    }
}

@MainActor
struct XRGSettingsTests {
    @Test func injectedDefaultsRemainIndependent() throws {
        let domain = "XRGSettingsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = XRGSettings(defaults: defaults)
        settings.aiTokensTrackingEnabled = true
        settings.aiTokensDailyBudget = 42
        settings.graphStyle = 2
        #expect(defaults.bool(forKey: "aiTokensTrackingEnabled"))
        #expect(defaults.integer(forKey: "aiTokensDailyBudget") == 42)
        #expect(XRGSettings(defaults: defaults).graphStyle == 2)
        defaults.set(false, forKey: "aiTokensTrackingEnabled")
        #expect(!settings.aiTokensTrackingEnabled)
    }

    @Test func textAndColorAttributesFollowSettings() {
        let settings = XRGSettings()
        settings.textTransparency = 0.5
        settings.textColor = .red
        #expect(settings.textColor.alphaComponent == 0.5)
        let attribute = settings.alignLeftAttributes[NSAttributedString.Key.foregroundColor.rawValue] as? NSColor
        #expect(attribute == settings.textColor)
        let font = NSFont.systemFont(ofSize: 18)
        settings.graphFont = font
        #expect(settings.alignRightAttributes[NSAttributedString.Key.font.rawValue] as? NSFont == font)
        #expect(settings.textRectHeight > 0)
        settings.graphFont = nil
        #expect(settings.graphFont == font)
    }
}
