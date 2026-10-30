// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation

// ABI v1: opaque retained handles, fixed-width scalars and caller-owned buffers.
// Each handle is confined to one thread. The caller must pass a live handle from
// the matching create function and release it exactly once. No Swift layout escapes.
@c(xrg_shared_abi_version) public func abiVersion() -> UInt32 { 1 }

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
