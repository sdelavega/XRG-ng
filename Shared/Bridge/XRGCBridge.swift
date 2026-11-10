// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation

// ABI v1: opaque retained handles, fixed-width scalars and caller-owned buffers.
// Each handle is confined to one thread. The caller must pass a live handle from
// the matching create function and release it exactly once. No Swift layout escapes.
@c(xrg_shared_abi_version) public func abiVersion() -> UInt32 { 2 }

@c(xrg_sampling_settings) public func samplingSettings(_ output: UnsafeMutablePointer<UInt32>?, _ capacity: UInt32) -> Int32 {
    guard let output, capacity >= 4 else { return -1 }
    let values = [XRGSamplingSettings.minimumMilliseconds, XRGSamplingSettings.maximumMilliseconds,
                  XRGSamplingSettings.defaultMilliseconds, UInt32(XRGSamplingSettings.maximumHistorySamples)]
    for (index, value) in values.enumerated() { output[index] = value }
    return 4
}

/// Additive ABI v1: the same CPU interval boundary on both platforms.
@c(xrg_cpu_interval_valid) public func cpuIntervalValid(_ previous: Double, _ current: Double) -> Int32 {
    XRGCPUInterval.isValid(previous: previous, current: current) ? 1 : 0
}

// Additive weather ABI. Fixed-width scalar arrays, never Swift struct layout.
@c(xrg_metar_station) public func metarStation(_ bytes: UnsafePointer<UInt8>?, _ length: UInt32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32) -> Int32 {
    guard length <= 64, let bytes, let output, capacity >= 4,
          let text = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(length)), encoding: .utf8),
          let station = XRGWeatherReport.station(text) else { return -1 }
    for (index, byte) in station.utf8.enumerated() { output[index] = byte }
    return 4
}
@c(xrg_metar_latest_parse) public func metarLatestParse(_ bytes: UnsafePointer<UInt8>?, _ length: UInt32,
    _ station: UnsafePointer<UInt8>?, _ stationLength: UInt32, _ reference: Int64,
    _ values: UnsafeMutablePointer<Double>?, _ capacity: UInt32, _ flags: UnsafeMutablePointer<UInt32>?,
    _ raw: UnsafeMutablePointer<UInt8>?, _ rawCapacity: UInt32) -> Int32 {
    guard length <= 2_097_152, stationLength <= 64, (0...253_402_300_799).contains(reference),
          let bytes, let station, let values, capacity >= 10, let flags, let raw,
          let body = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(length)), encoding: .utf8),
          let code = String(bytes: UnsafeBufferPointer(start: station, count: Int(stationLength)), encoding: .utf8),
          let (report, date) = XRGWeatherReport.latest(in: body, station: code, relativeTo: Date(timeIntervalSince1970: Double(reference))),
          report.raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return -1 }
    let encoded = Array(report.raw.utf8)
    guard encoded.count <= 8192 else { return -1 }
    guard encoded.count <= rawCapacity else { return -2 }
    let fields: [Double?] = [report.temperatureC, report.dewpointC, report.humidity.map(Double.init),
        report.windDirection.map(Double.init), report.windKnots, report.gustKnots, report.visibilityMiles,
        report.pressureHPA, report.pressureIn]
    var valid: UInt32 = 0
    var result = [date.timeIntervalSince1970]
    for (index, field) in fields.enumerated() {
        if let field, field.isFinite { valid |= 1 << index; result.append(field) }
        else { result.append(0) }
    }
    switch report.visibilityQualifier {
    case "<": valid |= 1 << 16
    case ">": valid |= 1 << 17
    case "≥": valid |= 1 << 18
    default: break
    }
    for (index, value) in result.enumerated() { values[index] = value }
    for (index, byte) in encoded.enumerated() { raw[index] = byte }
    flags.pointee = valid
    return Int32(encoded.count)
}

@c(xrg_history_create) public func historyCreate(_ capacity: UInt32) -> UnsafeMutableRawPointer? {
    guard (1...86_400).contains(capacity) else { return nil }
    let history = XRGDataSet()
    history.resize(Int(capacity))
    return Unmanaged.passRetained(history).toOpaque()
}
@c(xrg_history_free) public func historyFree(_ handle: UnsafeMutableRawPointer?) {
    if let handle { Unmanaged<XRGDataSet>.fromOpaque(handle).release() }
}
@c(xrg_history_resize) public func historyResize(_ handle: UnsafeMutableRawPointer?, _ capacity: UInt32) -> Int32 {
    guard let handle, (1...86_400).contains(capacity) else { return -1 }
    Unmanaged<XRGDataSet>.fromOpaque(handle).takeUnretainedValue().resize(Int(capacity))
    return 0
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

/// Explicit cumulative Codex components. Invalid splits become unclassified totals.
@c(xrg_codex_usage_parse) public func codexUsageParse(_ bytes: UnsafePointer<UInt8>?, _ length: UInt32,
    _ input: UnsafeMutablePointer<UInt64>?, _ output: UnsafeMutablePointer<UInt64>?,
    _ total: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard length <= 8_388_608, let bytes, let input, let output, let total else { return -1 }
    guard let usage = XRGCodexLogParser.usage(inLine: Data(bytes: bytes, count: Int(length))) else { return 1 }
    input.pointee = usage.input; output.pointee = usage.output; total.pointee = usage.total
    return 0
}

// Additive ABI v1 entry points. Outputs are untouched on failure.
// kind: 0 Claude record, 1 Gemini record, 2 Gemini session. Returns identity byte
// count (zero when absent), -1 invalid/nonmatching input, -2 insufficient capacity.
@c(xrg_provider_usage_parse) public func providerUsageParse(_ bytes: UnsafePointer<UInt8>?, _ length: UInt32,
    _ kind: UInt32, _ input: UnsafeMutablePointer<UInt64>?, _ output: UnsafeMutablePointer<UInt64>?,
    _ total: UnsafeMutablePointer<UInt64>?, _ identity: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32) -> Int32 {
    guard length <= 8_388_608, let bytes, let input, let output, let total, let identity else { return -1 }
    let data = Data(bytes: bytes, count: Int(length))
    let record: XRGProviderLogParser.UsageRecord?
    switch kind {
    case 0: record = XRGProviderLogParser.claudeRecord(from: data)
    case 1: record = XRGProviderLogParser.geminiRecord(from: data)
    case 2: record = XRGProviderLogParser.geminiSession(from: data)
    default: return -1
    }
    guard let record else { return -1 }
    let name = Array(record.identity.utf8)
    guard name.count <= capacity else { return -2 }
    for (index, byte) in name.enumerated() { identity[index] = byte }
    input.pointee = record.input
    output.pointee = record.output
    total.pointee = record.total
    return Int32(name.count)
}

// Additive ABI v1: bounded JSON keeps strings and UInt64 values intact without
// exporting Swift layouts. Existing scalar entry points remain available.
@c(xrg_provider_details_parse) public func providerDetailsParse(_ bytes: UnsafePointer<UInt8>?, _ length: UInt32,
    _ kind: UInt32, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32) -> Int32 {
    guard length <= 8_388_608, let bytes, let output,
          let details = XRGProviderLogParser.usageDetails(from: Data(bytes: bytes, count: Int(length)), kind: kind),
          let encoded = try? JSONEncoder().encode(details), encoded.count <= 524_288 else { return -1 }
    guard encoded.count <= capacity else { return -2 }
    for (index, byte) in encoded.enumerated() { output[index] = byte }
    return Int32(encoded.count)
}

// Model names are newline-delimited UTF-8. Reject embedded newlines and bound
// names before crossing the ABI. No model inventory is interpreted as token usage.
@c(xrg_model_names_parse) public func modelNamesParse(_ bytes: UnsafePointer<UInt8>?, _ length: UInt32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32) -> Int32 {
    guard length <= 8_388_608, let bytes, let output,
          let names = XRGLocalProviderParser.modelNames(from: Data(bytes: bytes, count: Int(length))),
          names.count <= 1024,
          names.allSatisfy({ $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } && $0.utf8.count <= 1024 }) else { return -1 }
    let result = Array(names.joined(separator: "\n").utf8)
    guard result.count <= capacity else { return -1 }
    for (index, byte) in result.enumerated() { output[index] = byte }
    return Int32(result.count)
}

// Returns valid sample flags (1 tokens, 2 cost), or -1 for invalid arguments.
@c(xrg_metrics_sample_parse) public func metricsSampleParse(_ bytes: UnsafePointer<UInt8>?, _ length: UInt32,
    _ tokens: UnsafeMutablePointer<UInt64>?, _ cost: UnsafeMutablePointer<Double>?) -> Int32 {
    guard length <= 8_388_608, let bytes, let tokens, let cost,
          let text = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(length)), encoding: .utf8)
    else { return -1 }
    let result = XRGLocalProviderParser.metrics(from: text)
    tokens.pointee = result.tokens
    cost.pointee = result.cost
    return (result.hasTokenSamples ? 1 : 0) | (result.hasCostSamples ? 2 : 0)
}

// Additive ABI v1 accounting. Copy the value ledger before sampling so a short
// output buffer cannot consume a delta. No Swift value layout crosses the ABI.
private final class TokenLedgerBox {
    var ledger = XRGTokenAccounting()
}
private struct TokenLedgerRequest: Decodable {
    let provider: String
    let source: String
    let usage: XRGTokenUsage?
    let models: [String: UInt64]
}
private struct TokenLedgerResponse: Encodable { let delta: XRGTokenAccounting.Delta? }
@c(xrg_accounting_create) public func accountingCreate() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(TokenLedgerBox()).toOpaque()
}
@c(xrg_accounting_free) public func accountingFree(_ handle: UnsafeMutableRawPointer?) {
    if let handle { Unmanaged<TokenLedgerBox>.fromOpaque(handle).release() }
}
@c(xrg_accounting_reset) public func accountingReset(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return -1 }
    Unmanaged<TokenLedgerBox>.fromOpaque(handle).takeUnretainedValue().ledger = XRGTokenAccounting()
    return 0
}
@c(xrg_accounting_sample) public func accountingSample(_ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?, _ length: UInt32, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32) -> Int32 {
    guard let handle, let bytes, let output, length <= 1_048_576,
          let request = try? JSONDecoder().decode(TokenLedgerRequest.self, from: Data(bytes: bytes, count: Int(length))),
          !request.provider.isEmpty, request.provider.utf8.count <= 64, request.source.utf8.count <= 4096,
          request.models.count <= 256,
          request.models.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }) else { return -1 }
    let box = Unmanaged<TokenLedgerBox>.fromOpaque(handle).takeUnretainedValue()
    var ledger = box.ledger
    let delta = ledger.sample(provider: request.provider, source: request.source, usage: request.usage, models: request.models)
    guard let data = try? JSONEncoder().encode(TokenLedgerResponse(delta: delta)) else { return -1 }
    guard data.count <= capacity else { return -2 }
    for (index, byte) in data.enumerated() { output[index] = byte }
    box.ledger = ledger
    return Int32(data.count)
}

private struct WeatherHistoryRow: Encodable {
    let station: String
    let observed_at: Int64
    let temperature_c: Double?
    let dewpoint_c: Double?
    let humidity: Int?
    let wind_degrees: Int?
    let wind_knots: Double?
    let gust_knots: Double?
    let visibility_miles: Double?
    let visibility_qualifier: String
    let pressure_hpa: Double?
    let pressure_in: Double?
    let raw: String
}
/// Additive ABI v1: all dated matching observations, deduplicated and oldest first.
@c(xrg_metar_history_parse) public func metarHistoryParse(_ bytes: UnsafePointer<UInt8>?, _ length: UInt32,
    _ station: UnsafePointer<UInt8>?, _ stationLength: UInt32, _ reference: Int64,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32) -> Int32 {
    guard length <= 2_097_152, stationLength <= 64, (0...253_402_300_799).contains(reference),
          let bytes, let station, let output,
          let text = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(length)), encoding: .utf8),
          let name = String(bytes: UnsafeBufferPointer(start: station, count: Int(stationLength)), encoding: .utf8),
          let code = XRGWeatherReport.station(name) else { return -1 }
    let now = Date(timeIntervalSince1970: Double(reference))
    var rows: [Int64: WeatherHistoryRow] = [:]
    for report in XRGWeatherReport.reports(in: text, station: code) {
        guard let date = report.observationDate(relativeTo: now),
              report.raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { continue }
        let time = Int64(date.timeIntervalSince1970)
        // The first report for a timestamp wins within one response. Later
        // successful responses may replace that timestamp with a correction.
        guard rows[time] == nil else { continue }
        rows[time] = WeatherHistoryRow(station: code, observed_at: time,
            temperature_c: report.temperatureC, dewpoint_c: report.dewpointC, humidity: report.humidity,
            wind_degrees: report.windDirection, wind_knots: report.windKnots, gust_knots: report.gustKnots,
            visibility_miles: report.visibilityMiles, visibility_qualifier: report.visibilityQualifier,
            pressure_hpa: report.pressureHPA, pressure_in: report.pressureIn, raw: report.raw)
    }
    guard !rows.isEmpty, let data = try? JSONEncoder().encode(rows.keys.sorted().compactMap { rows[$0] }) else { return -1 }
    guard data.count <= capacity else { return -2 }
    for (index, byte) in data.enumerated() { output[index] = byte }
    return Int32(data.count)
}

/// Additive ABI v1: a complete per-file observation may continue an old baseline.
@c(xrg_log_file_continues) public func logFileContinues(
    _ oldDevice: UInt64, _ oldInode: UInt64, _ oldBytes: UInt64, _ oldTokens: UInt64,
    _ device: UInt64, _ inode: UInt64, _ bytes: UInt64, _ tokens: UInt64) -> Int32 {
    XRGLogFileState(device: device, inode: inode, bytes: bytes, tokens: tokens)
        .continues(XRGLogFileState(device: oldDevice, inode: oldInode, bytes: oldBytes, tokens: oldTokens)) ? 1 : 0
}

/// Additive ABI v1: shared nominal AI polling cadence.
@c(xrg_ai_sampling_milliseconds) public func aiSamplingMilliseconds() -> UInt64 {
    XRGAISamplingCadence.milliseconds
}

@c(xrg_timed_history_settings) public func timedHistorySettings(_ output: UnsafeMutablePointer<UInt32>?, _ capacity: UInt32) -> Int32 {
    guard let output, capacity >= 4 else { return -1 }
    for (i, value) in [XRGTimedHistory.maximumMinutes, XRGTimedHistory.binSeconds, XRGTimedHistory.maximumObservations, XRGTimedHistory.maximumChannels].enumerated() { output[i] = UInt32(value) }
    return 4
}
@c(xrg_timed_history_create) public func timedHistoryCreate(_ channels: UInt32) -> UnsafeMutableRawPointer? {
    guard let history = XRGTimedHistory(channels: Int(channels)) else { return nil }
    return Unmanaged.passRetained(history).toOpaque()
}
@c(xrg_timed_history_free) public func timedHistoryFree(_ handle: UnsafeMutableRawPointer?) {
    if let handle { Unmanaged<XRGTimedHistory>.fromOpaque(handle).release() }
}
@c(xrg_timed_history_clear) public func timedHistoryClear(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return -1 }
    Unmanaged<XRGTimedHistory>.fromOpaque(handle).takeUnretainedValue().clear(); return 0
}
@c(xrg_timed_history_append) public func timedHistoryAppend(_ handle: UnsafeMutableRawPointer?, _ time: Double, _ values: UnsafePointer<Double>?, _ count: UInt32) -> Int32 {
    guard let handle, let values else { return -1 }
    let history = Unmanaged<XRGTimedHistory>.fromOpaque(handle).takeUnretainedValue()
    guard count == history.channels else { return -1 }
    return history.append(time: time, values: Array(UnsafeBufferPointer(start: values, count: Int(count)))) ? 0 : -1
}
@c(xrg_timed_history_projection_settings) public func timedHistoryProjectionSettings(_ output: UnsafeMutablePointer<UInt32>?, _ capacity: UInt32) -> Int32 {
    guard let output, capacity >= 3 else { return -1 }
    output[0] = UInt32(XRGTimedHistory.systemMaximumMinutes); output[1] = UInt32(XRGTimedHistory.minimumInterval * 1000); output[2] = UInt32(XRGTimedHistory.maximumPositions)
    return 3
}
@c(xrg_timed_history_create_limited) public func timedHistoryCreateLimited(_ channels: UInt32, _ minutes: UInt32) -> UnsafeMutableRawPointer? {
    guard let history = XRGTimedHistory(channels: Int(channels), retentionMinutes: Int(minutes)) else { return nil }
    return Unmanaged.passRetained(history).toOpaque()
}
@c(xrg_timed_history_create_signed_limited) public func timedHistoryCreateSignedLimited(_ channels: UInt32, _ minutes: UInt32) -> UnsafeMutableRawPointer? {
    guard let history = XRGTimedHistory(channels: Int(channels), retentionMinutes: Int(minutes), allowsNegativeValues: true) else { return nil }
    return Unmanaged.passRetained(history).toOpaque()
}
@c(xrg_timed_history_bin_count) public func timedHistoryBinCount(_ minutes: UInt32, _ interval: Double) -> Int32 {
    guard let count = XRGTimedHistory.binCount(minutes: Int(minutes), interval: interval) else { return -1 }
    return Int32(count)
}
@c(xrg_timed_history_copy) public func timedHistoryCopy(_ handle: UnsafeMutableRawPointer?, _ minutes: UInt32, _ output: UnsafeMutablePointer<Double>?, _ capacity: UInt32) -> Int32 {
    timedHistoryCopyInterval(handle, minutes, Double(XRGTimedHistory.binSeconds), output, capacity)
}
@c(xrg_timed_history_copy_interval) public func timedHistoryCopyInterval(_ handle: UnsafeMutableRawPointer?, _ minutes: UInt32, _ interval: Double, _ output: UnsafeMutablePointer<Double>?, _ capacity: UInt32) -> Int32 {
    guard let handle, let output, let bins = XRGTimedHistory.binCount(minutes: Int(minutes), interval: interval) else { return -1 }
    let history = Unmanaged<XRGTimedHistory>.fromOpaque(handle).takeUnretainedValue()
    guard minutes <= history.retentionMinutes else { return -1 }
    let required = bins * history.channels
    guard capacity >= required else { return -2 }
    let values = history.values(minutes: Int(minutes), interval: interval)!
    for channel in 0..<history.channels { for slot in 0..<bins { output[channel * bins + slot] = values[channel][slot] } }
    return Int32(required)
}

// Additive ABI v2: the shared settings model and the stock chart. Every entry
// point speaks UTF-8 JSON through caller-provided buffers: the return value is
// the byte count written, -1 rejects invalid arguments, non-UTF-8 names,
// oversized input or input the model refuses, and -2 means the buffer was too
// small, leaving the required size in *needed without touching the output.

/// Canonical JSON for one ABI response: sorted keys, no whitespace, so the
/// bytes a platform receives do not depend on dictionary ordering.
private func settingsJSON<T: Encodable>(_ value: T) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(value)
}

/// Copy a UTF-8 response into the caller's buffer: the byte count, or -2 with
/// the required size in *needed. Nothing is written unless it all fits.
private func settingsWrite(_ data: Data, _ output: UnsafeMutablePointer<UInt8>?,
                           _ capacity: UInt32, _ needed: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard data.count <= Int32.max else { return -1 }
    if let output, Int(capacity) >= data.count {
        for (index, byte) in data.enumerated() { output[index] = byte }
        return Int32(data.count)
    }
    if let needed { needed.pointee = UInt32(data.count) }
    return -2
}

private struct SettingsCatalogJSON: Encodable {
    let sections: [String]
    let entries: [XRGSettingsEntry]
}
private struct SettingsLoadJSON: Encodable {
    let document: String?
    let diagnostics: [XRGSettingsDiagnostic]
    let unreadable: Bool
}
private struct SettingsMigrateJSON: Encodable {
    let document: String
    let diagnostics: [XRGSettingsDiagnostic]
}
private struct SettingsMutationJSON: Encodable {
    let document: String?
    let error: SettingsErrorJSON?
}
private struct SettingsErrorJSON: Encodable {
    let kind: String
    let min: Double?
    let max: Double?

    init(kind: String, min: Double?, max: Double?) {
        self.kind = kind
        self.min = min
        self.max = max
    }

    /// The wire form of one core refusal, with the bounds an out-of-range
    /// value carries.
    init(_ error: XRGSettingsError) {
        switch error {
        case .unknownId: self.init(kind: "unknown-id", min: nil, max: nil)
        case .wrongType: self.init(kind: "wrong-type", min: nil, max: nil)
        case .outOfRange(let min, let max): self.init(kind: "out-of-range", min: min, max: max)
        case .notAnOption: self.init(kind: "not-an-option", min: nil, max: nil)
        case .dependencyNotMet: self.init(kind: "dependency-not-met", min: nil, max: nil)
        case .constraint: self.init(kind: "constraint-failed", min: nil, max: nil)
        }
    }
}
private struct StockChartJSON: Encodable {
    let price: Double?
    let change: Double?
    let closes: [Double]?
}
private struct StockURLsJSON: Encodable {
    let history: String
    let quote: String
}

/// The catalog entries a platform renders, in display order, with the
/// section list. `platform` is 0 for macOS, 1 for Linux.
@c(xrg_settings_catalog) public func settingsCatalog(_ platform: UInt32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32,
    _ needed: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard platform <= 1, let catalog = try? XRGSettingsCatalog.load(),
          let data = settingsJSON(SettingsCatalogJSON(sections: XRGSettingsCatalog.sections,
              entries: catalog.entries.filter { $0.platforms.contains(platform == 0 ? .macos : .linux) }))
    else { return -1 }
    return settingsWrite(data, output, capacity, needed)
}

/// A settings document in: the canonical document bytes and the load's
/// diagnostics out. An unreadable document is reported, not refused.
@c(xrg_settings_load) public func settingsLoad(_ doc: UnsafePointer<UInt8>?, _ len: UInt32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32,
    _ needed: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard len <= 1_048_576, let doc, let catalog = try? XRGSettingsCatalog.load() else { return -1 }
    switch XRGSettingsDocument.load(Data(bytes: doc, count: Int(len)), catalog: catalog) {
    case .ok(let document, let diagnostics):
        guard let bytes = String(data: document.serialized(), encoding: .utf8),
              let data = settingsJSON(SettingsLoadJSON(document: bytes, diagnostics: diagnostics,
                                                      unreadable: false)) else { return -1 }
        return settingsWrite(data, output, capacity, needed)
    case .unreadable(let diagnostic):
        guard let data = settingsJSON(SettingsLoadJSON(document: nil, diagnostics: [diagnostic],
                                                       unreadable: true)) else { return -1 }
        return settingsWrite(data, output, capacity, needed)
    }
}

/// Write one refusal of `xrg_settings_set` as its wire response.
private func settingsRefusal(_ error: SettingsErrorJSON,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32,
    _ needed: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard let data = settingsJSON(SettingsMutationJSON(document: nil, error: error)) else { return -1 }
    return settingsWrite(data, output, capacity, needed)
}

/// Store one value: the new document, or the core's refusal with its kind
/// and, for an out-of-range value, the entry's bounds. A request that cannot
/// cross — an id over 256 bytes, a value over 8 KiB, or an id or value that
/// cannot be parsed (invalid UTF-8, malformed JSON, or nesting past the
/// parser's depth limit) — is reported as request-too-large or
/// unparsable-request through the same wire, so a caller can tell it from a
/// document that does not load (-1).
@c(xrg_settings_set) public func settingsSet(_ doc: UnsafePointer<UInt8>?, _ len: UInt32,
    _ id: UnsafePointer<UInt8>?, _ idLen: UInt32,
    _ value: UnsafePointer<UInt8>?, _ valueLen: UInt32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32,
    _ needed: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard len <= 1_048_576, let doc, let id, let value,
          let catalog = try? XRGSettingsCatalog.load(),
          case .ok(var document, _) = XRGSettingsDocument.load(Data(bytes: doc, count: Int(len)), catalog: catalog)
    else { return -1 }
    // Request-level problems ride the wire: the document itself may be fine,
    // so the size of a request must not masquerade as an unreadable document.
    guard idLen <= 256, valueLen <= 8192 else {
        return settingsRefusal(SettingsErrorJSON(kind: "request-too-large", min: nil, max: nil),
                               output, capacity, needed)
    }
    // A request that cannot be parsed — an id that is not UTF-8, or a value
    // that is not UTF-8, not JSON, or nested past the parser's depth limit —
    // is a request problem while the document is fine, so it rides the wire
    // like the size refusal, never -1.
    guard let idText = String(bytes: UnsafeBufferPointer(start: id, count: Int(idLen)), encoding: .utf8) else {
        return settingsRefusal(SettingsErrorJSON(kind: "unparsable-request", min: nil, max: nil),
                               output, capacity, needed)
    }
    guard let valueText = String(bytes: UnsafeBufferPointer(start: value, count: Int(valueLen)), encoding: .utf8),
          let json = JSONValue.parse(valueText)
    else {
        return settingsRefusal(SettingsErrorJSON(kind: "unparsable-request", min: nil, max: nil),
                               output, capacity, needed)
    }
    guard let settingsValue = XRGSettingsValue(json: json) else {
        // A shape no control can hold, reported as the type refusal `set`
        // itself would give.
        return settingsRefusal(SettingsErrorJSON(kind: "wrong-type", min: nil, max: nil),
                               output, capacity, needed)
    }
    do {
        try document.set(idText, settingsValue, catalog: catalog)
        guard let bytes = String(data: document.serialized(), encoding: .utf8),
              let data = settingsJSON(SettingsMutationJSON(document: bytes, error: nil)) else { return -1 }
        return settingsWrite(data, output, capacity, needed)
    } catch {
        // `set` is `throws(XRGSettingsError)`, so this catches exactly its
        // typed refusals.
        return settingsRefusal(SettingsErrorJSON(error), output, capacity, needed)
    }
}

/// Restore one section to its defaults; unknown keys at either level, and
/// every other section, are untouched. The section must be one of the
/// catalog's, and the document must load; a section name that cannot be
/// parsed (invalid UTF-8) rides the wire as unparsable-request.
@c(xrg_settings_reset_section) public func settingsResetSection(_ doc: UnsafePointer<UInt8>?, _ len: UInt32,
    _ section: UnsafePointer<UInt8>?, _ sectionLen: UInt32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32,
    _ needed: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard len <= 1_048_576, sectionLen <= 256, let doc, let section,
          let catalog = try? XRGSettingsCatalog.load(),
          case .ok(var document, _) = XRGSettingsDocument.load(Data(bytes: doc, count: Int(len)), catalog: catalog)
    else { return -1 }
    // A section name that cannot be parsed — invalid UTF-8 — is a request
    // problem while the document is fine, so it rides the wire like the
    // `set` refusals, never -1.
    guard let name = String(bytes: UnsafeBufferPointer(start: section, count: Int(sectionLen)), encoding: .utf8) else {
        return settingsRefusal(SettingsErrorJSON(kind: "unparsable-request", min: nil, max: nil),
                               output, capacity, needed)
    }
    guard XRGSettingsCatalog.sections.contains(name) else { return -1 }
    // The ABI names no platform, so both platforms' entries of the section
    // return to their default: a stored value of either survives neither.
    document.resetSection(name, catalog: catalog, platform: .macos)
    document.resetSection(name, catalog: catalog, platform: .linux)
    guard let bytes = String(data: document.serialized(), encoding: .utf8),
          let data = settingsJSON(SettingsMutationJSON(document: bytes, error: nil)) else { return -1 }
    return settingsWrite(data, output, capacity, needed)
}

/// A version-40 Linux settings file in: the migrated document and its
/// diagnostics out. Bytes that are not a JSON object are refused.
@c(xrg_settings_migrate_linux_v40) public func settingsMigrateLinuxV40(_ v40: UnsafePointer<UInt8>?, _ len: UInt32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32,
    _ needed: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard len <= 1_048_576, let v40, let catalog = try? XRGSettingsCatalog.load(),
          let (document, diagnostics) = try? XRGSettingsMigration.fromLinuxV40(
              Data(bytes: v40, count: Int(len)), catalog: catalog),
          let bytes = String(data: document.serialized(), encoding: .utf8),
          let data = settingsJSON(SettingsMigrateJSON(document: bytes, diagnostics: diagnostics))
    else { return -1 }
    return settingsWrite(data, output, capacity, needed)
}

/// The version-40-shaped view of a document, exactly what the Rust serde
/// model deserialises. An unreadable document is refused.
@c(xrg_settings_linux_view) public func settingsLinuxView(_ doc: UnsafePointer<UInt8>?, _ len: UInt32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32,
    _ needed: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard len <= 1_048_576, let doc, let catalog = try? XRGSettingsCatalog.load(),
          case .ok(let document, _) = XRGSettingsDocument.load(Data(bytes: doc, count: Int(len)), catalog: catalog)
    else { return -1 }
    return settingsWrite(XRGSettingsMigration.linuxView(document, catalog: catalog), output, capacity, needed)
}

/// Yahoo chart responses: kind 0 is the one-year daily history (closes only),
/// kind 1 the intraday quote (price and change only); the side a parse does
/// not fill is null. A response that does not parse is refused.
@c(xrg_stock_chart_parse) public func stockChartParse(_ kind: UInt32, _ bytes: UnsafePointer<UInt8>?, _ len: UInt32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32,
    _ needed: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard len <= 8_388_608, let bytes, kind <= 1 else { return -1 }
    let data = Data(bytes: bytes, count: Int(len))
    let chart = kind == 0 ? XRGStockChart.parse(history: data) : XRGStockChart.parse(quote: data)
    guard let chart, let response = settingsJSON(kind == 0
        ? StockChartJSON(price: nil, change: nil, closes: chart.closes)
        : StockChartJSON(price: chart.price, change: chart.change, closes: nil)) else { return -1 }
    return settingsWrite(response, output, capacity, needed)
}

/// The history and quote URLs for a ticker, percent-encoded exactly as the
/// macOS 0.2.2 stock module built them.
@c(xrg_stock_urls) public func stockUrls(_ ticker: UnsafePointer<UInt8>?, _ len: UInt32,
    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: UInt32,
    _ needed: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard len <= 256, let ticker,
          let text = String(bytes: UnsafeBufferPointer(start: ticker, count: Int(len)), encoding: .utf8),
          let urls = XRGStockChart.urls(ticker: text),
          let data = settingsJSON(StockURLsJSON(history: urls.history.absoluteString,
                                                 quote: urls.quote.absoluteString))
    else { return -1 }
    return settingsWrite(data, output, capacity, needed)
}
