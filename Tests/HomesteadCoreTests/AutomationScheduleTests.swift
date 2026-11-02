// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class AutomationScheduleTests: XCTestCase {
    private let newYork = SunLocation(latitude: 40.7128, longitude: -74.0060)
    private let eastern = TimeZone(identifier: "America/New_York")!

    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    private func config(_ triggers: [JSONValue]) -> JSONValue {
        .object(["alias": .string("Test"), "triggers": .array(triggers)])
    }

    private func next(_ triggers: [JSONValue], after now: String, location: SunLocation? = nil) -> Date? {
        AutomationSchedule.nextRun(of: AutomationSchedule.triggers(fromConfig: config(triggers)),
                                   after: utc(now), location: location ?? newYork, timeZone: eastern)
    }

    private func assertClose(_ date: Date?, _ expected: String, within seconds: TimeInterval = 30,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let date else { return XCTFail("no run", file: file, line: line) }
        XCTAssertEqual(date.timeIntervalSince1970, utc(expected).timeIntervalSince1970, accuracy: seconds,
                       file: file, line: line)
    }

    // MARK: - Sun

    /// Against astral, which Home Assistant uses, for New York.
    func testSunTimesMatchAstral() {
        let day = utc("2026-11-02T00:00:00Z")
        assertClose(SolarTimes.time(of: .sunrise, onUTCDay: day, at: newYork), "2026-11-02T11:27:48Z")
        assertClose(SolarTimes.time(of: .sunset, onUTCDay: day, at: newYork), "2026-11-02T21:50:45Z")
        assertClose(SolarTimes.time(of: .dawn, onUTCDay: day, at: newYork), "2026-11-02T10:58:46Z")
        assertClose(SolarTimes.time(of: .dusk, onUTCDay: day, at: newYork), "2026-11-02T22:19:46Z")
        assertClose(SolarTimes.time(of: .noon, onUTCDay: day, at: newYork), "2026-11-02T16:39:32Z")
        let midsummer = utc("2026-06-21T00:00:00Z")
        assertClose(SolarTimes.time(of: .sunrise, onUTCDay: midsummer, at: newYork), "2026-06-21T09:25:17Z")
        assertClose(SolarTimes.time(of: .noon, onUTCDay: midsummer, at: newYork), "2026-06-21T16:57:44Z")
    }

    func testPolarNightHasNoSunrise() {
        let tromso = SunLocation(latitude: 69.6492, longitude: 18.9553)
        XCTAssertNil(SolarTimes.time(of: .sunrise, onUTCDay: utc("2026-12-21T00:00:00Z"), at: tromso))
    }

    func testSunsetWithNoOffsetIsTodaysSunset() {
        let sunset: JSONValue = .object(["trigger": .string("sun"), "event": .string("sunset"),
                                         "offset": .string("00:00:00")])
        assertClose(next([sunset], after: "2026-11-02T15:00:00Z"), "2026-11-02T21:50:45Z")
    }

    /// Thirty minutes before sunset, asked between that and sunset: today's
    /// has gone, so it is tomorrow's.
    func testNegativeOffsetAlreadyPassedIsTomorrow() {
        let early: JSONValue = .object(["platform": .string("sun"), "event": .string("sunset"),
                                        "offset": .string("-00:30:00")])
        assertClose(next([early], after: "2026-11-02T21:30:00Z"), "2026-11-03T21:19:45Z", within: 120)
    }

    /// Thirty minutes after sunset, asked after sunset: still today's.
    func testPositiveOffsetAfterTheEventIsStillToday() {
        let late: JSONValue = .object(["trigger": .string("sun"), "event": .string("sunset"),
                                       "offset": .number(1_800)])
        assertClose(next([late], after: "2026-11-02T22:00:00Z"), "2026-11-02T22:20:45Z")
    }

    func testNewStyleSolarNoonWithOffsetBefore() {
        let noon: JSONValue = .object([
            "trigger": .string("sun.solar_noon"),
            "options": .object(["offset": .object(["hours": .number(1), "minutes": .number(0),
                                                   "seconds": .number(0), "days": .number(0)]),
                                "offset_type": .string("before")]),
        ])
        assertClose(next([noon], after: "2026-11-02T12:00:00Z"), "2026-11-02T15:39:32Z")
    }

    func testSunTriggerWithoutALocationHasNoTime() {
        let triggers = AutomationSchedule.triggers(fromConfig: config([
            .object(["trigger": .string("sun"), "event": .string("sunrise")]),
        ]))
        XCTAssertNil(AutomationSchedule.nextRun(of: triggers, after: Date(), location: nil, timeZone: eastern))
    }

    /// Home Assistant's own sunrise wins over the worked-out one a few
    /// seconds away, and only for the day it names.
    func testReportedSunTimesReplaceWorkedOutOnes() {
        let sun = EntityState(state: "above_horizon", attributes: [
            "next_rising": .string("2026-11-03T11:29:03.514692+00:00"),
            "next_setting": .string("2026-11-02T21:50:59+00:00"),
        ])
        let reported = SolarTimes.reported(by: sun)
        XCTAssertEqual(reported[.sunrise]?.timeIntervalSince1970 ?? 0, 1_793_705_343.514692, accuracy: 0.001)
        XCTAssertEqual(reported[.sunset], utc("2026-11-02T21:50:59Z"))
        let early: JSONValue = .object(["trigger": .string("sun"), "event": .string("sunrise"),
                                        "offset": .string("-00:20:00")])
        let triggers = AutomationSchedule.triggers(fromConfig: config([early]))
        let run = AutomationSchedule.nextRun(of: triggers, after: utc("2026-11-02T15:00:00Z"), location: newYork,
                                             timeZone: eastern, reported: reported)
        XCTAssertEqual(run?.timeIntervalSince1970 ?? 0, 1_793_705_343.514692 - 1_200, accuracy: 0.001)
        // The day after the reported one is still worked out.
        let later = AutomationSchedule.nextRun(of: triggers, after: utc("2026-11-03T12:00:00Z"), location: newYork,
                                               timeZone: eastern, reported: reported)
        assertClose(later, "2026-11-04T11:10:00Z", within: 120)
    }

    // MARK: - Clock

    func testTimeOfDayInTheHousesZone() {
        let six: JSONValue = .object(["trigger": .string("time"), "at": .string("18:00:00")])
        XCTAssertEqual(next([six], after: "2026-11-02T15:00:00Z"), utc("2026-11-02T23:00:00Z"))
        XCTAssertEqual(next([six], after: "2026-11-02T23:00:00Z"), utc("2026-11-03T23:00:00Z"))
    }

    func testTimeOnWeekdays() {
        // 2026-11-02 is a Monday.
        let friday: JSONValue = .object(["trigger": .string("time"), "at": .array([.string("07:30")]),
                                         "weekday": .array([.string("fri")])])
        XCTAssertEqual(next([friday], after: "2026-11-02T15:00:00Z"), utc("2026-11-06T12:30:00Z"))
    }

    func testTimeFromAHelperIsSkipped() {
        let helper: JSONValue = .object(["trigger": .string("time"), "at": .string("input_datetime.wake")])
        XCTAssertTrue(AutomationSchedule.triggers(fromConfig: config([helper])).isEmpty)
    }

    func testHourlyPattern() {
        let hourly: JSONValue = .object(["trigger": .string("time_pattern"), "minutes": .number(0)])
        XCTAssertEqual(next([hourly], after: "2026-11-02T15:24:10Z"), utc("2026-11-02T16:00:00Z"))
    }

    func testEveryFiveMinutesPattern() {
        let five: JSONValue = .object(["trigger": .string("time_pattern"), "minutes": .string("/5")])
        XCTAssertEqual(next([five], after: "2026-11-02T15:24:10Z"), utc("2026-11-02T15:25:00Z"))
    }

    func testEveryMinutePattern() {
        let minute: JSONValue = .object(["trigger": .string("time_pattern"), "minutes": .string("*")])
        XCTAssertEqual(next([minute], after: "2026-11-02T15:24:10Z"), utc("2026-11-02T15:25:00Z"))
    }

    func testHoursOnlyPatternRunsOnTheHour() {
        let three: JSONValue = .object(["trigger": .string("time_pattern"), "hours": .string("3")])
        XCTAssertEqual(next([three], after: "2026-11-02T15:24:10Z"), utc("2026-11-03T08:00:00Z"))
    }

    // MARK: - Mixed

    /// The soonest trigger wins, and ones with no time (a state change, a
    /// disabled trigger) are ignored.
    func testSoonestOfSeveralTriggers() {
        let triggers: [JSONValue] = [
            .object(["trigger": .string("state"), "entity_id": .string("sensor.door")]),
            .object(["trigger": .string("time"), "at": .string("09:00"), "enabled": .bool(false)]),
            .object(["trigger": .string("time"), "at": .string("18:00:00")]),
            .object(["trigger": .string("sun"), "event": .string("sunset")]),
        ]
        assertClose(next(triggers, after: "2026-11-02T15:00:00Z"), "2026-11-02T21:50:45Z")
    }

    func testNothingScheduled() {
        let state: JSONValue = .object(["trigger": .string("state"), "entity_id": .string("sensor.door")])
        XCTAssertNil(next([state], after: "2026-11-02T15:00:00Z"))
    }

    func testOldSingularTriggerKey() {
        let old: JSONValue = .object(["trigger": .object(["platform": .string("time"), "at": .string("18:00")])])
        XCTAssertEqual(AutomationSchedule.triggers(fromConfig: old),
                       [.time(hour: 18, minute: 0, second: 0, weekdays: nil)])
    }

    func testOffsetSpellings() {
        XCTAssertEqual(AutomationSchedule.duration(.string("-00:30:00")), -1_800)
        XCTAssertEqual(AutomationSchedule.duration(.string("01:15")), 4_500)
        XCTAssertEqual(AutomationSchedule.duration(.number(90)), 90)
        XCTAssertEqual(AutomationSchedule.duration(.object(["minutes": .number(20)])), 1_200)
        XCTAssertNil(AutomationSchedule.duration(.string("soon")))
    }

    // MARK: - Text

    func testText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        let locale = Locale(identifier: "en_US")
        let now = utc("2026-11-02T15:00:00Z")  // Monday 10:00 AM
        func text(_ run: String) -> String {
            AutomationSchedule.text(for: utc(run), now: now, calendar: calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(text("2026-11-02T22:28:02Z"), "5:28 PM")
        XCTAssertEqual(text("2026-11-03T11:20:00Z"), "Tomorrow 6:20 AM")
        XCTAssertEqual(text("2026-11-06T23:00:00Z"), "Fri 6:00 PM")
        XCTAssertEqual(text("2026-11-20T23:00:00Z"), "Nov 20 6:00 PM")
    }
}
