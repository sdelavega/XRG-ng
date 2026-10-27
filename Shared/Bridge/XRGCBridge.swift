// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation

// ABI v1: opaque retained handles, fixed-width scalars and caller-owned buffers.
// Each handle is confined to one thread. The caller must pass a live handle from
// the matching create function and release it exactly once. No Swift layout escapes.
@c(xrg_shared_abi_version) public func abiVersion() -> UInt32 { 1 }

@c(xrg_history_create) public func historyCreate(_ capacity: UInt32) -> UnsafeMutableRawPointer? {
    guard (1...86_400).contains(capacity) else { return nil }
    let history = XRGDataSet()
    history.resize(Int(capacity))
    return Unmanaged.passRetained(history).toOpaque()
}
@c(xrg_history_free) public func historyFree(_ handle: UnsafeMutableRawPointer?) {
    if let handle { Unmanaged<XRGDataSet>.fromOpaque(handle).release() }
}
@c(xrg_history_append) public func historyAppend(_ handle: UnsafeMutableRawPointer?, _ value: Double) -> Int32 {
    guard let handle, value.isFinite else { return -1 }
    Unmanaged<XRGDataSet>.fromOpaque(handle).takeUnretainedValue().setNextValue(CGFloat(value))
    return 0
}
@c(xrg_history_copy) public func historyCopy(_ handle: UnsafeMutableRawPointer?,
    _ output: UnsafeMutablePointer<Double>?, _ capacity: UInt32) -> Int32 {
    guard let handle, let output else { return -1 }
    let history = Unmanaged<XRGDataSet>.fromOpaque(handle).takeUnretainedValue()
    guard capacity >= history.numValues else { return -1 }
    for (index, value) in history.orderedValues.enumerated() { output[index] = Double(value) }
    return Int32(history.numValues)
}
@c(xrg_rate_create) public func rateCreate() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(XRGRateTracker()).toOpaque()
}
@c(xrg_rate_free) public func rateFree(_ handle: UnsafeMutableRawPointer?) {
    if let handle { Unmanaged<XRGRateTracker>.fromOpaque(handle).release() }
}
@c(xrg_rate_sample) public func rateSample(_ handle: UnsafeMutableRawPointer?, _ key: UInt32,
    _ counter: UInt64, _ time: Double, _ delta: UnsafeMutablePointer<UInt64>?) -> UInt32 {
    guard let handle, let delta else { return 0 }
    let sample = Unmanaged<XRGRateTracker>.fromOpaque(handle).takeUnretainedValue()
        .sample(counter: counter, key: String(key), time: time)
    delta.pointee = sample.delta
    return sample.rate
}
@c(xrg_theme_count) public func themeCount() -> UInt32 { UInt32(XRGBuiltinTheme.allCases.count) }
@c(xrg_theme_name) public func themeName(_ index: UInt32, _ output: UnsafeMutablePointer<UInt8>?,
    _ capacity: UInt32) -> Int32 {
    guard index < XRGBuiltinTheme.allCases.count, let output else { return -1 }
    let bytes = Array(XRGBuiltinTheme.allCases[Int(index)].name.utf8)
    guard capacity >= bytes.count else { return -1 }
    for (index, byte) in bytes.enumerated() { output[index] = byte }
    return Int32(bytes.count) // UTF-8 bytes; no trailing NUL.
}
@c(xrg_theme_colors) public func themeColors(_ index: UInt32, _ output: UnsafeMutablePointer<Double>?,
    _ capacity: UInt32) -> Int32 {
    guard index < XRGBuiltinTheme.allCases.count, let output, capacity >= 28 else { return -1 }
    for (index, value) in XRGBuiltinTheme.allCases[Int(index)].rgba.flatMap({ $0 }).enumerated() {
        output[index] = value
    }
    return 28
}
@c(xrg_metrics_parse) public func metricsParse(_ bytes: UnsafePointer<UInt8>?, _ length: UInt32,
    _ tokens: UnsafeMutablePointer<UInt64>?, _ cost: UnsafeMutablePointer<Double>?) -> Int32 {
    guard length <= 8_388_608, let bytes, let tokens, let cost,
          let text = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(length)), encoding: .utf8)
    else { return -1 }
    let result = XRGLocalProviderParser.metrics(from: text)
    tokens.pointee = result.tokens
    cost.pointee = result.cost
    return 0
}
@c(xrg_codex_record_parse) public func codexRecordParse(_ bytes: UnsafePointer<UInt8>?, _ length: UInt32,
    _ tokens: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard length <= 8_388_608, let bytes, let tokens else { return -1 }
    guard let total = XRGCodexLogParser.total(inLine: Data(bytes: bytes, count: Int(length))) else { return 1 }
    tokens.pointee = total
    return 0
}
