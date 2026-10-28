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

#if canImport(Accelerate)
import Accelerate
#endif
import Foundation

/// Ring-buffer storage owned by Swift. Swift rendering consumes orderedValues;
/// remaining Objective-C callers may copy samples into their own destination.
#if canImport(ObjectiveC)
@objc(XRGDataSet)
#endif
#if canImport(ObjectiveC)
@objcMembers
#endif
public final class XRGDataSet: NSObject {
    private var samples: [Double] = []
    public var numValues: Int { samples.count }
    public private(set) var currentIndex = 0
    public private(set) var min: CGFloat = 0
    public private(set) var max: CGFloat = 0
    public private(set) var sum: CGFloat = 0
    public var average: CGFloat { samples.isEmpty ? 0 : sum / CGFloat(samples.count) }
    public var currentValue: CGFloat { samples.isEmpty ? 0 : CGFloat(samples[currentIndex]) }

    public override init() {
        super.init()
    }

    #if canImport(ObjectiveC)
    @objc(initWithContentsOfOtherDataSet:)
    #endif
    public init?(contentsOfOtherDataSet other: XRGDataSet?) {
        guard let other else { return nil }
        super.init()
        copyValues(from: other)
    }

    #if canImport(ObjectiveC)
    @objc(copyValuesFromDataSet:)
    #endif
    public func copyValues(from other: XRGDataSet) {
        samples = other.samples
        currentIndex = other.currentIndex
        min = other.min
        max = other.max
        sum = other.sum
    }

    #if canImport(ObjectiveC)
    @nonobjc
    #endif
    public var orderedValues: [CGFloat] {
        guard !samples.isEmpty else { return [] }
        let start = (currentIndex + 1) % samples.count
        let ordered = Array(samples[start...]) + Array(samples[..<start])
        return ordered.map { CGFloat($0) }
    }

    /// The Objective-C renderer provides room for numValues elements.
    public func valuesInOrder(_ destination: UnsafeMutablePointer<CGFloat>?) {
        guard let destination, !samples.isEmpty else { return }
        let start = (currentIndex + 1) % samples.count
        for index in samples.indices {
            destination[index] = CGFloat(samples[(start + index) % samples.count])
        }
    }

    public func reset() {
        setAllValues(0)
    }

    public func resize(_ count: Int) {
        resize(count, fillingWith: 0)
    }

    #if canImport(ObjectiveC)
    @nonobjc
    #endif
    public func resize(_ count: Int, fillingWith value: CGFloat) {
        guard count >= 0 else { return }
        let wasEmpty = samples.isEmpty
        let retained = orderedValues.suffix(count)
        samples = Array(repeating: Double(value), count: count - retained.count) + retained.map(Double.init)
        currentIndex = count == 0 || wasEmpty ? 0 : count - 1
        updateStatistics()
    }

    public func setNextValue(_ value: CGFloat) {
        guard !samples.isEmpty else { return }
        currentIndex = (currentIndex + 1) % samples.count
        let oldValue = CGFloat(samples[currentIndex])
        samples[currentIndex] = Double(value)
        if oldValue == min || oldValue == max {
            updateStatistics()
        } else {
            sum += value - oldValue
            min = Swift.min(min, value)
            max = Swift.max(max, value)
        }
    }

    public func setAllValues(_ value: CGFloat) {
        samples = Array(repeating: Double(value), count: samples.count)
        updateStatistics()
    }

    public func addOtherDataSetValues(_ other: XRGDataSet?) {
        guard let other, other.numValues == numValues, !samples.isEmpty else { return }
        #if canImport(Accelerate)
        samples = vDSP.add(samples, other.samples)
        #else
        samples = zip(samples, other.samples).map(+)
        #endif
        updateStatistics()
    }

    public func subtractOtherDataSetValues(_ other: XRGDataSet?) {
        guard let other, other.numValues == numValues, !samples.isEmpty else { return }
        #if canImport(Accelerate)
        samples = vDSP.subtract(samples, other.samples)
        #else
        samples = zip(samples, other.samples).map(-)
        #endif
        updateStatistics()
    }

    public func divideAllValues(by divisor: CGFloat) {
        guard divisor != 0, !samples.isEmpty else { return }
        #if canImport(Accelerate)
        samples = vDSP.divide(samples, Double(divisor))
        #else
        samples = samples.map { $0 / Double(divisor) }
        #endif
        updateStatistics()
    }

    private func updateStatistics() {
        guard !samples.isEmpty else {
            min = 0
            max = 0
            sum = 0
            return
        }
        #if canImport(Accelerate)
        min = CGFloat(vDSP.minimum(samples))
        max = CGFloat(vDSP.maximum(samples))
        sum = CGFloat(vDSP.sum(samples))
        #else
        min = CGFloat(samples.min() ?? 0)
        max = CGFloat(samples.max() ?? 0)
        sum = CGFloat(samples.reduce(0, +))
        #endif
    }
}
