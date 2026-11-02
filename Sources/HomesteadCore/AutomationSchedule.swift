// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// Where the house is, from Home Assistant's own config: what sun triggers
/// are worked out for.
public struct SunLocation: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// The moments of the sun's day a trigger can follow.
public enum SunEvent: String, Equatable, Sendable {
    case sunrise, sunset, dawn, dusk, noon, midnight

    /// A trigger's own name for it: `sunset` in a classic sun trigger,
    /// `solar_noon` in a `sun.solar_noon` one.
    init?(name: String) {
        switch name {
        case "sunrise": self = .sunrise
        case "sunset": self = .sunset
        case "dawn": self = .dawn
        case "dusk": self = .dusk
        case "noon", "solar_noon": self = .noon
        case "midnight", "solar_midnight": self = .midnight
        default: return nil
        }
    }
}

/// When the sun does each thing, by NOAA's solar equations, which agree with
/// the astral library Home Assistant uses to within a few seconds. Sunrise
/// and sunset are when the sun's upper edge meets the horizon (0.833° below
/// it, allowing for refraction); dawn and dusk are civil twilight, 6° below.
public enum SolarTimes {
    /// The event during the UTC day that starts at `day` (midnight UTC); nil
    /// when the sun never reaches that angle that day (polar day and night).
    public static func time(of event: SunEvent, onUTCDay day: Date, at location: SunLocation) -> Date? {
        let start = (day.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400
        // Two passes: the sun's position at the first estimate puts the second
        // within a second of the answer.
        var minutes = 720.0
        for _ in 0..<2 {
            let instant = start + minutes * 60
            guard let next = Self.minutes(of: event, at: instant, location: location) else { return nil }
            minutes = next
        }
        return Date(timeIntervalSince1970: start + minutes * 60)
    }

    /// Minutes after midnight UTC, with the sun's position taken at `instant`.
    private static func minutes(of event: SunEvent, at instant: TimeInterval, location: SunLocation) -> Double? {
        let julianDay = instant / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545) / 36_525

        let meanLongitude = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let meanAnomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let m = radians(meanAnomaly)
        let centre = sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m) * (0.019993 - 0.000101 * t)
            + sin(3 * m) * 0.000289
        let omega = radians(125.04 - 1934.136 * t)
        let apparentLongitude = meanLongitude + centre - 0.00569 - 0.00478 * sin(omega)
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = radians(meanObliquity + 0.00256 * cos(omega))
        let declination = asin(sin(obliquity) * sin(radians(apparentLongitude)))

        let y = pow(tan(obliquity / 2), 2)
        let l0 = radians(meanLongitude)
        let equationOfTime = 4 * degrees(y * sin(2 * l0) - 2 * eccentricity * sin(m)
            + 4 * eccentricity * y * sin(m) * cos(2 * l0)
            - 0.5 * y * y * sin(4 * l0) - 1.25 * eccentricity * eccentricity * sin(2 * m))
        let noon = 720 - 4 * location.longitude - equationOfTime

        let depression: Double
        switch event {
        case .noon: return noon
        case .midnight: return noon + 720
        case .sunrise, .sunset: depression = 0.833
        case .dawn, .dusk: depression = 6
        }
        let latitude = radians(location.latitude)
        let cosHourAngle = (cos(radians(90 + depression)) - sin(latitude) * sin(declination))
            / (cos(latitude) * cos(declination))
        guard (-1...1).contains(cosHourAngle) else { return nil }
        let hourAngle = degrees(acos(cosHourAngle))
        let rising = event == .sunrise || event == .dawn
        return rising ? noon - 4 * hourAngle : noon + 4 * hourAngle
    }

    /// The next of each event as `sun.sun` reports it (`next_rising`,
    /// `next_setting`, …): Home Assistant's own times, which its triggers
    /// fire at, to the second.
    public static func reported(by sun: EntityState?) -> [SunEvent: Date] {
        let names: [(String, SunEvent)] = [("next_rising", .sunrise), ("next_setting", .sunset),
                                           ("next_dawn", .dawn), ("next_dusk", .dusk),
                                           ("next_noon", .noon), ("next_midnight", .midnight)]
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var times: [SunEvent: Date] = [:]
        for (attribute, event) in names {
            guard let text = sun?.attributes[attribute]?.string,
                  let date = precise.date(from: text) ?? plain.date(from: text) else { continue }
            times[event] = date
        }
        return times
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

/// One field of a time-pattern trigger: `*`, `/5` or a number.
public enum TimeField: Equatable, Sendable {
    case any
    case every(Int)
    case value(Int)

    func matches(_ value: Int) -> Bool {
        switch self {
        case .any: return true
        case .every(let step): return step > 0 && value % step == 0
        case .value(let wanted): return value == wanted
        }
    }

    /// Home Assistant writes the fields as numbers or strings; nil is a
    /// field the trigger leaves out, and anything unreadable is too.
    static func parse(_ json: JSONValue?) -> TimeField?? {
        guard let json else { return .some(nil) }
        if let number = json.int { return .value(number) }
        guard let text = json.string?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text == "*" { return .any }
        if text.hasPrefix("/"), let step = Int(text.dropFirst()) { return .every(step) }
        if let number = Int(text) { return .value(number) }
        return nil
    }
}

/// An automation trigger that fires at a time the clock or the sun can tell
/// in advance. Triggers that wait on something happening — a state change,
/// an event — have no time to show and are not read.
public enum ScheduleTrigger: Equatable, Sendable {
    case sun(SunEvent, offset: TimeInterval)
    /// A time of day, on the given weekdays (Calendar's 1 = Sunday) or every
    /// day when nil.
    case time(hour: Int, minute: Int, second: Int, weekdays: Set<Int>?)
    case pattern(hours: TimeField, minutes: TimeField, seconds: TimeField)
}

public enum AutomationSchedule {
    // MARK: - Reading a config

    /// The scheduled triggers of an automation's config, as `automation/config`
    /// returns it. Both spellings are read: `triggers`/`trigger` for the list,
    /// `trigger`/`platform` for each one's kind.
    public static func triggers(fromConfig config: JSONValue) -> [ScheduleTrigger] {
        let list = config["triggers"] ?? config["trigger"]
        let items = list?.array ?? list.map { [$0] } ?? []
        return items.flatMap(triggers(from:))
    }

    private static func triggers(from item: JSONValue) -> [ScheduleTrigger] {
        guard item.object != nil, item["enabled"]?.bool != false,
              let kind = item["trigger"]?.string ?? item["platform"]?.string
        else { return [] }

        switch kind {
        case "sun":
            guard let event = item["event"]?.string.flatMap(SunEvent.init(name:)) else { return [] }
            let offset = item["offset"].map(duration) ?? 0
            return offset.map { [.sun(event, offset: $0)] } ?? []

        case _ where kind.hasPrefix("sun."):
            // The newer `sun.solar_noon` style, with its offset among options.
            guard let event = SunEvent(name: String(kind.dropFirst(4))) else { return [] }
            let options = item["options"]
            guard let offset = options?["offset"].map(duration) ?? 0 else { return [] }
            let before = options?["offset_type"]?.string == "before"
            return [.sun(event, offset: before ? -abs(offset) : offset)]

        case "time":
            let at = item["at"]
            let times = (at?.array ?? at.map { [$0] } ?? []).compactMap { $0.string.flatMap(timeOfDay) }
            let weekdays = weekdays(item["weekday"])
            return times.map { .time(hour: $0.hour, minute: $0.minute, second: $0.second, weekdays: weekdays) }

        case "time_pattern":
            guard let hours = TimeField.parse(item["hours"]),
                  var minutes = TimeField.parse(item["minutes"]),
                  var seconds = TimeField.parse(item["seconds"])
            else { return [] }
            // As Home Assistant does: a larger unit given zeroes the smaller
            // ones left out, and whatever is still missing matches anything.
            if minutes == nil, hours != nil { minutes = .value(0) }
            if seconds == nil, minutes != nil { seconds = .value(0) }
            guard hours != nil || minutes != nil || seconds != nil else { return [] }
            return [.pattern(hours: hours ?? .any, minutes: minutes ?? .any, seconds: seconds ?? .any)]

        default:
            return []
        }
    }

    /// `"-00:30:00"`, `"00:30"`, seconds as a number, or
    /// `{hours: 1, minutes: 0}` — every way Home Assistant writes an offset.
    static func duration(_ json: JSONValue) -> TimeInterval? {
        if let seconds = json.double { return seconds }
        if let parts = json.object {
            var total = 0.0
            for (unit, scale) in [("days", 86_400.0), ("hours", 3_600), ("minutes", 60), ("seconds", 1),
                                  ("milliseconds", 0.001)] {
                guard let value = parts[unit] else { continue }
                guard let number = value.double else { return nil }
                total += number * scale
            }
            return total
        }
        guard var text = json.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        var sign = 1.0
        if text.hasPrefix("-") { sign = -1; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        let fields = text.split(separator: ":").map { Double($0) }
        guard (1...3).contains(fields.count), !fields.contains(nil) else { return nil }
        let numbers = fields.compactMap { $0 }
        if numbers.count == 1 { return sign * numbers[0] }
        let seconds = numbers[0] * 3_600 + numbers[1] * 60 + (numbers.count == 3 ? numbers[2] : 0)
        return sign * seconds
    }

    /// `"18:00"` or `"18:00:00"`. An entity id (a helper holding the time)
    /// is not a time of day, and is skipped.
    private static func timeOfDay(_ text: String) -> (hour: Int, minute: Int, second: Int)? {
        let fields = text.split(separator: ":").map { Int($0) }
        guard (2...3).contains(fields.count), !fields.contains(nil) else { return nil }
        let numbers = fields.compactMap { $0 }
        let second = numbers.count == 3 ? numbers[2] : 0
        guard (0..<24).contains(numbers[0]), (0..<60).contains(numbers[1]), (0..<60).contains(second) else { return nil }
        return (numbers[0], numbers[1], second)
    }

    private static let weekdayNames = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]

    private static func weekdays(_ json: JSONValue?) -> Set<Int>? {
        guard let json else { return nil }
        let names = json.array?.compactMap(\.string) ?? json.string.map { [$0] } ?? []
        let days = Set(names.compactMap { weekdayNames[$0.lowercased()] })
        return days.isEmpty ? nil : days
    }

    // MARK: - The next run

    /// The soonest moment after `now` any of the triggers fires, nil when none
    /// can say (no triggers, or a sun trigger with no location).
    ///
    /// - Parameters:
    ///   - timeZone: Home Assistant's, which its clock triggers keep.
    ///   - reported: `sun.sun`'s next times, which replace the worked-out
    ///     ones they match: the two differ by seconds, enough to show 6:19
    ///     for a trigger that fires at 6:20:03.
    public static func nextRun(of triggers: [ScheduleTrigger], after now: Date,
                               location: SunLocation?, timeZone: TimeZone,
                               reported: [SunEvent: Date] = [:]) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return triggers.compactMap { trigger -> Date? in
            switch trigger {
            case .sun(let event, let offset):
                return location.flatMap {
                    nextSun(event, offset: offset, after: now, location: $0, reported: reported[event])
                }
            case .time(let hour, let minute, let second, let weekdays):
                return nextTime(hour: hour, minute: minute, second: second, weekdays: weekdays,
                                after: now, calendar: calendar)
            case .pattern(let hours, let minutes, let seconds):
                return nextPattern(hours: hours, minutes: minutes, seconds: seconds, after: now, calendar: calendar)
            }
        }.min()
    }

    private static func nextSun(_ event: SunEvent, offset: TimeInterval, after now: Date,
                                location: SunLocation, reported: Date?) -> Date? {
        // Yesterday's sunset with a day's offset could still be ahead, and a
        // polar night can skip a day, so look a few days either side.
        let today = (now.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400
        let offsetDays = Int((abs(offset) / 86_400).rounded(.up))
        return (-1 - offsetDays...3 + offsetDays)
            .compactMap { day in
                SolarTimes.time(of: event, onUTCDay: Date(timeIntervalSince1970: today + Double(day) * 86_400),
                                at: location)
            }
            .map { worked in
                guard let reported, abs(worked.timeIntervalSince(reported)) < 600 else { return worked }
                return reported
            }
            .map { $0.addingTimeInterval(offset) }
            .filter { $0 > now }
            .min()
    }

    private static func nextTime(hour: Int, minute: Int, second: Int, weekdays: Set<Int>?,
                                 after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  weekdays?.contains(calendar.component(.weekday, from: day)) ?? true,
                  let run = calendar.date(bySettingHour: hour, minute: minute, second: second, of: day),
                  run > now
            else { continue }
            return run
        }
        return nil
    }

    private static func nextPattern(hours: TimeField, minutes: TimeField, seconds: TimeField,
                                    after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for hour in 0..<24 where hours.matches(hour) {
                guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                      start.addingTimeInterval(3_600) > now
                else { continue }
                for minute in 0..<60 where minutes.matches(minute) {
                    let minuteStart = start.addingTimeInterval(Double(minute) * 60)
                    guard minuteStart.addingTimeInterval(60) > now else { continue }
                    for second in 0..<60 where seconds.matches(second) {
                        let run = minuteStart.addingTimeInterval(Double(second))
                        if run > now { return run }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Showing it

    /// The run as the menu shows it: `5:28 PM` today, `Tomorrow 6:20 AM`,
    /// a weekday within the week (`Mon 6:00 PM`), otherwise a date.
    public static func text(for run: Date, now: Date, calendar: Calendar = .current,
                            locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let time = formatter.string(from: run)

        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: run)).day ?? 0
        switch days {
        case ...0: return time
        case 1: return "Tomorrow \(time)"
        case 2..<7: formatter.setLocalizedDateFormatFromTemplate("EEE")
        default: formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return "\(formatter.string(from: run)) \(time)"
    }
}
