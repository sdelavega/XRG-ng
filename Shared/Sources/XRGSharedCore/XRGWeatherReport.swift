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

import Foundation

/// METAR body values use Celsius, knots, statute miles and inches Hg internally.
/// Format reference: https://aviationweather.gov/help/data/
struct XRGWeatherReport: Sendable {
    let raw: String
    let time: Int
    var observationDay = 0
    var windDirection: Int?
    var windKnots: Double?
    var gustKnots: Double?
    var visibilityMiles: Double?
    var visibilityQualifier = ""
    var temperatureC: Double?
    var dewpointC: Double?
    var pressureIn: Double?
    var pressureHPA: Double?

    var humidity: Int? {
        guard let t = temperatureC, let d = dewpointC else { return nil }
        let ratio = pow(10, 7.5 * d / (237.7 + d) - 7.5 * t / (237.7 + t)) * 100
        guard ratio.isFinite else { return nil }
        return Int(min(100, max(0, ratio)))
    }
    var directionText: String {
        guard let direction = windDirection else { return "n/a" }
        if direction == -1 { return "VRB" }
        return ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"][Int((Double(direction) + 11.25) / 22.5) % 16]
    }
    static func station(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return text.range(of: "^[A-Z0-9]{4}$", options: .regularExpression) == nil ? nil : text
    }
    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
    static func reports(in text: String, station: String) -> [Self] {
        guard let station = Self.station(station), text.utf8.count <= 2_097_152 else { return [] }
        let clean = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&#160;", with: " ")
        // Split at every station header, not just the requested station. A mixed
        // response must not overwrite one station's values with another's body.
        let pattern = "(?<![A-Z0-9])(?:(?:METAR|SPECI)\\s+)?[A-Z0-9]{4}\\s+[0-9]{6}Z\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: clean, range: NSRange(clean.startIndex..., in: clean))
        let ns = clean as NSString
        return matches.prefix(2048).enumerated().compactMap { index, match in
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let raw = ns.substring(with: NSRange(location: match.range.location, length: end - match.range.location))
            guard raw.utf8.count <= 8192 else { return nil }
            return parse(raw, station: station)
        }
    }
    private static func parse(_ raw: String, station: String) -> Self? {
        var fields = raw.split(whereSeparator: { $0.isWhitespace || $0 == "=" }).map(String.init)
        if fields.first == "METAR" || fields.first == "SPECI" { fields.removeFirst() }
        guard (2...256).contains(fields.count), fields[0] == station,
              let date = captures("^([0-9]{2})([0-9]{2})([0-9]{2})Z$", in: fields[1]),
              let day = Int(date[1]), (1...31).contains(day), let hour = Int(date[2]), hour < 24,
              let minute = Int(date[3]), minute < 60 else { return nil }
        let body = Array(fields.prefix { $0 != "RMK" })
        guard !body.contains("NIL") else { return nil }
        var report = Self(raw: fields.joined(separator: " "), time: hour * 100 + minute, observationDay: day)
        for (index, field) in body.enumerated().dropFirst(2) {
            if let wind = captures("^(VRB|[0-9]{3})([0-9]{2,3})(?:G([0-9]{2,3}))?(KT|MPS|KMH)$", in: field) {
                let direction = wind[1] == "VRB" ? -1 : Int(wind[1]) ?? 361
                if direction <= 360 {
                    report.windDirection = direction
                    let factor = wind[4] == "MPS" ? 3600.0 / 1852.0 : wind[4] == "KMH" ? 1.0 / 1.852 : 1.0
                    report.windKnots = Double(wind[2]).map { $0 * factor }
                    report.gustKnots = Double(wind[3]).map { $0 * factor }
                }
            } else if let visibility = captures("^([MP]?)([0-9]+(?:/[0-9]+)?)SM$", in: field) {
                let parts = visibility[2].split(separator: "/").compactMap { Double($0) }
                var miles: Double?
                if parts.count == 1 { miles = parts[0] }
                if parts.count == 2, parts[1] > 0 {
                    miles = parts[0] / parts[1]
                    if index > 2, let whole = Double(body[index - 1]), whole.isFinite, whole >= 0 { miles! += whole }
                }
                report.visibilityMiles = miles.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                report.visibilityQualifier = visibility[1] == "M" ? "<" : visibility[1] == "P" ? ">" : ""
            } else if field == "CAVOK" || field.range(of: "^[0-9]{4}$", options: .regularExpression) != nil {
                let meters = field == "CAVOK" ? 9999 : Int(field) ?? 0
                report.visibilityMiles = Double(meters == 9999 ? 10_000 : meters) / 1609.344
                report.visibilityQualifier = meters == 9999 ? "≥" : ""
            } else if let temperatures = captures("^(M?[0-9]{2})/(M?[0-9]{2})?$", in: field) {
                func celsius(_ text: String) -> Double? { Double(text.replacingOccurrences(of: "M", with: "-")) }
                report.temperatureC = celsius(temperatures[1]); report.dewpointC = celsius(temperatures[2])
            } else if let pressure = captures("^A([0-9]{4})$", in: field), let value = Double(pressure[1]), value > 0 {
                report.pressureIn = value / 100
            } else if let pressure = captures("^Q([0-9]{3,4})$", in: field), let value = Double(pressure[1]), value > 0 {
                report.pressureHPA = value
            }
        }
        // The remarks group carries higher-precision Celsius readings when present.
        if let remarks = fields.firstIndex(of: "RMK") {
            for field in fields.suffix(from: remarks + 1) {
                if let precise = captures("^T([01])([0-9]{3})([01])([0-9]{3})$", in: field) {
                    report.temperatureC = Double(precise[2])! / 10 * (precise[1] == "1" ? -1 : 1)
                    report.dewpointC = Double(precise[4])! / 10 * (precise[3] == "1" ? -1 : 1)
                    break
                }
            }
        }
        if report.pressureIn == nil { report.pressureIn = report.pressureHPA.map { $0 * 0.02953 } }
        if report.pressureHPA == nil { report.pressureHPA = report.pressureIn.map { $0 / 0.02953 } }
        return report
    }

    /// Infer the month/year only inside the requested 36-hour observation window.
    /// Validate components after Calendar construction, which can normalize an
    /// invalid date (e.g. February 31) into the following month.
    func observationDate(relativeTo reference: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let month = calendar.date(from: calendar.dateComponents([.year, .month], from: reference)) else { return nil }
        return (-1...1).compactMap { offset -> Date? in
            guard let start = calendar.date(byAdding: .month, value: offset, to: month) else { return nil }
            var parts = calendar.dateComponents([.year, .month], from: start)
            parts.day = observationDay; parts.hour = time / 100; parts.minute = time % 100; parts.second = 0
            guard let date = calendar.date(from: parts),
                  calendar.component(.month, from: date) == parts.month,
                  calendar.component(.day, from: date) == observationDay,
                  date.timeIntervalSince(reference) <= 300,
                  date.timeIntervalSince(reference) >= -129_600 else { return nil }
            return date
        }.max()
    }
    static func latest(in text: String, station: String, relativeTo reference: Date) -> (Self, Date)? {
        reports(in: text, station: station).compactMap { report in
            report.observationDate(relativeTo: reference).map { (report, $0) }
        }.max { $0.1 < $1.1 }
    }
}
