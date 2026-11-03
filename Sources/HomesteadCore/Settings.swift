// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// Everything the app remembers except the token, which lives in the Keychain.
public final class Settings {
    public enum Key {
        public static let haURL = "HAURL"
        public static let selectedDashboard = "SelectedDashboard"
        public static let showSensors = "ShowSensors"
        public static let visibleDashboards = "VisibleDashboards"
        public static let dashboardOrder = "DashboardOrder"
        public static let weatherEntity = "WeatherEntity"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The server address as typed. Nil when unset or blank — both mean
    /// "unconfigured", so the menu has one case to handle, not two.
    public var haURL: String? {
        get {
            let stored = defaults.string(forKey: Key.haURL)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty ?? true) ? nil : stored
        }
        set { defaults.set(newValue, forKey: Key.haURL) }
    }

    /// The remembered dashboard: a `url_path`, or `""` for the built-in
    /// Overview (whose path is nil), or nil when nothing has been chosen yet.
    public var selectedDashboardPath: String? {
        get { defaults.string(forKey: Key.selectedDashboard) }
        set { defaults.set(newValue, forKey: Key.selectedDashboard) }
    }

    /// Which weather entity the icon follows: nil to pick one automatically,
    /// empty for no weather at all.
    public var weatherEntity: String? {
        get { defaults.string(forKey: Key.weatherEntity) }
        set { defaults.set(newValue, forKey: Key.weatherEntity) }
    }

    public var showSensors: Bool {
        get { defaults.bool(forKey: Key.showSensors) }
        set { defaults.set(newValue, forKey: Key.showSensors) }
    }

    /// The `url_path`s of the dashboards the picker offers. Empty means all of
    /// them: a fresh install has chosen nothing, and so does someone who
    /// unticks everything — in both cases an empty picker would be worse than a
    /// long one.
    public var visibleDashboardPaths: [String] {
        get { defaults.stringArray(forKey: Key.visibleDashboards) ?? [] }
        set { defaults.set(newValue, forKey: Key.visibleDashboards) }
    }

    /// The `url_path`s in the order the rows were dragged into; empty until
    /// they are (and again after Sort Alphabetically). Paths missing from it —
    /// a dashboard added in Home Assistant since — go after the arranged ones,
    /// alphabetically.
    public var dashboardOrder: [String] {
        get { defaults.stringArray(forKey: Key.dashboardOrder) ?? [] }
        set { defaults.set(newValue, forKey: Key.dashboardOrder) }
    }

    /// Every dashboard, in the chosen order: what the Dashboards window lists.
    /// The arranged ones first, in their dragged order; the rest after them,
    /// alphabetically by title ("Dashboard 2" before "Dashboard 10"), so with
    /// nothing arranged the whole list is alphabetical.
    public func ordered(_ listings: [DashboardListing]) -> [DashboardListing] {
        let rank = Dictionary(dashboardOrder.enumerated().map { ($0.element, $0.offset) },
                              uniquingKeysWith: { first, _ in first })
        return listings.enumerated().sorted { left, right in
            let leftRank = rank[left.element.urlPath ?? ""]
            let rightRank = rank[right.element.urlPath ?? ""]
            switch (leftRank, rightRank) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                switch Self.compareTitles(left.element.title, right.element.title) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                // Same title either way: keep Home Assistant's order.
                case .orderedSame: return left.offset < right.offset
                }
            }
        }.map(\.element)
    }

    /// Alphabetical the way Finder sorts names: case-insensitive, numbers by
    /// value.
    static func compareTitles(_ a: String, _ b: String) -> ComparisonResult {
        a.localizedStandardCompare(b)
    }

    /// The dashboards to offer in the menu: the ticked ones, in the chosen
    /// order.
    public func visible(from listings: [DashboardListing]) -> [DashboardListing] {
        let chosen = Set(visibleDashboardPaths)
        let ordered = ordered(listings)
        guard !chosen.isEmpty else { return ordered }
        let filtered = ordered.filter { chosen.contains($0.urlPath ?? "") }
        return filtered.isEmpty ? ordered : DashboardListing.disambiguated(filtered)
    }

    /// Which dashboard to open with: the remembered one if it still exists,
    /// else "My Home", else whatever is first.
    public func defaultDashboard(from listings: [DashboardListing]) -> DashboardListing? {
        if let remembered = selectedDashboardPath,
           let match = listings.first(where: { ($0.urlPath ?? "") == remembered }) {
            return match
        }
        return listings.first { $0.title == "My Home" } ?? listings.first
    }
}
