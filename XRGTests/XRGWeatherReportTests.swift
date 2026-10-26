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
import Testing
@testable import XRGCore

struct XRGWeatherReportTests {
    private func report(_ body: String) throws -> XRGWeatherReport {
        try #require(XRGWeatherReport.reports(in: "KSEA 251953Z " + body, station: "KSEA").first)
    }
    @Test func parsesACompleteReportAndUsesPreciseCelsiusRemarks() throws {
        let r = try report("21016G24KT 1 1/2SM SCT050 06/04 A2990 RMK AO2 T00640036")
        #expect(r.time == 1953 && r.windDirection == 210 && r.windKnots == 16 && r.gustKnots == 24)
        #expect(r.visibilityMiles == 1.5 && r.temperatureC == 6.4 && r.dewpointC == 3.6)
        #expect(r.humidity == 82 && r.directionText == "SSW")
        #expect(r.pressureIn == 29.90)
        #expect(abs(try #require(r.pressureHPA) - 29.90 / 0.02953) < 0.00001)
    }
    @Test(arguments: ["plain", "html", "single", "trailing"])
    func keepsTheFinalReportAndIgnoresStationHeadings(format: String) {
        let a = "KSEA 251953Z 20010KT 10SM 20/10 A2992 RMK AO2"
        let b = "KSEA 251853Z 18008KT 9SM 10/05 A2991 RMK AO2"
        let text: String
        switch format {
        case "html": text = "<h2>Station KSEA</h2><pre>\(a)<br>\(b)</pre>"
        case "single": text = a
        case "trailing": text = a + "=\n" + b + "=\n"
        default: text = a + "\n" + b
        }
        let reports = XRGWeatherReport.reports(in: text, station: "ksea")
        #expect(reports.count == (format == "single" ? 1 : 2))
        #expect(reports.first?.temperatureC == 20)
        #expect(reports.last?.temperatureC == (format == "single" ? 20 : 10))
    }
    @Test(arguments: [("1/2SM", 0.5), ("1 1/2SM", 1.5), ("M1/4SM", 0.25), ("P6SM", 6.0), ("10SM", 10.0), ("9999", 10_000 / 1609.344), ("0800", 800 / 1609.344), ("CAVOK", 10_000 / 1609.344)])
    func visibilityFractionsAndMetricValues(pair: (String, Double)) throws {
        let r = try report("18010KT " + pair.0 + " 20/10 Q1013")
        #expect(abs(try #require(r.visibilityMiles) - pair.1) < 0.000001)
        let qualifier = pair.0.hasPrefix("M") ? "<" : pair.0.hasPrefix("P") ? ">" : ["9999", "CAVOK"].contains(pair.0) ? "≥" : ""
        #expect(r.visibilityQualifier == qualifier)
    }
    @Test(arguments: [("VRB03G12KT", -1, 3, 12), ("270123G140KT", 270, 123, 140), ("00000KT", 0, 0, 0), ("36010KT", 360, 10, 0)])
    func variableCalmAndThreeDigitWind(pair: (String, Int, Int, Int)) throws {
        let r = try report(pair.0 + " 10SM 20/10 A2992")
        #expect(r.windDirection == pair.1 && r.windKnots == Double(pair.2) && (r.gustKnots ?? 0) == Double(pair.3))
        #expect(r.directionText == (pair.1 == -1 ? "VRB" : pair.1 == 270 ? "W" : "N"))
    }
    @Test(arguments: [("20/10", 20.0, 10.0, 52), ("M10/M15", -10.0, -15.0, 66), ("00/00", 0.0, 0.0, 100), ("01/02", 1.0, 2.0, 100)])
    func signedTemperaturesAndHumidityUseCelsius(pair: (String, Double, Double, Int)) throws {
        let r = try report("18010KT 10SM " + pair.0 + " A2992")
        #expect(r.temperatureC == pair.1 && r.dewpointC == pair.2 && r.humidity == pair.3)
        let precise = try report("18010KT 10SM 00/M02 A2992 RMK T10011025")
        #expect(precise.temperatureC == -0.1 && precise.dewpointC == -2.5)
    }
    @Test(arguments: ["KT 1/0SM /// AXXXX QXXXX", "99912KT nopeSM // Q0000", "", "180GKT R25/0600FT // A0000"])
    func malformedOrMissingFieldsRemainMissing(body: String) throws {
        let r = try report(body)
        #expect(r.temperatureC == nil && r.dewpointC == nil && r.humidity == nil)
        #expect(r.windKnots == nil && r.gustKnots == nil && r.directionText == "n/a")
        #expect(r.visibilityMiles == nil && r.pressureIn == nil && r.pressureHPA == nil)
    }
    @Test(arguments: ["KSEA 251953Z NIL", "KSEA", "KSEA 252453Z 20/10", "KSEA 001953Z 20/10", "KSEA 251960Z 20/10", "XKSEA 251953Z 20/10", "KJFK 251953Z 20/10"])
    func rejectsNilWrongStationsAndInvalidTimes(text: String) { #expect(XRGWeatherReport.reports(in: text, station: "KSEA").isEmpty) }
    @Test func normalizesStationsRejectsQueryInjectionAndBoundsHistoryInput() {
        #expect(XRGWeatherReport.station("  ksea\n") == "KSEA")
        for station in ["", "ABC", "ABCDE", "KSEA&ids=KJFK", "KŚEA"] { #expect(XRGWeatherReport.station(station) == nil) }
        let line = "KSEA 251953Z 20/10 A2992\n"
        #expect(XRGWeatherReport.reports(in: String(repeating: line, count: 2050), station: "KSEA").count == 2048)
        #expect(XRGWeatherReport.reports(in: String(repeating: "x", count: 2_097_153), station: "KSEA").isEmpty)
    }
    @Test func pressureConversionsAndRemarksDoNotReplaceBodyVisibility() throws {
        let r = try report("24010KT 10SM 20/10 Q1013 RMK VIS 1/4SM 0800 A2890")
        #expect(r.pressureHPA == 1013 && r.pressureIn == 1013 * 0.02953)
        #expect(r.visibilityMiles == 10)
        #expect(try report("24010KT 10SM 20/").humidity == nil)
    }
}
