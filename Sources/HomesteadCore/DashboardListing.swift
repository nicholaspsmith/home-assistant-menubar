// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// One entry in the menu's dashboard picker.
public struct DashboardListing: Equatable, Sendable {
    /// The dashboard's `url_path`, which is also its identity everywhere else.
    public let urlPath: String?
    /// What the picker shows — the dashboard's title, suffixed with its
    /// url_path when another dashboard shares that title.
    public let title: String
    /// The title as Home Assistant has it, before any suffix.
    public let name: String

    public init(urlPath: String?, title: String, name: String? = nil) {
        self.urlPath = urlPath
        self.title = title
        self.name = name ?? title
    }

    /// Build the picker's list from a `lovelace/dashboards/list` result.
    ///
    /// Home Assistant's built-in Overview is deliberately absent: it is not in
    /// this result, and it is usually auto-generated with no stored config, so
    /// asking for one gets `config_not_found` and the entry is dead weight.
    public static func list(from result: JSONValue) -> [DashboardListing] {
        let entries = (result.array ?? []).compactMap { entry -> (path: String, title: String)? in
            guard let urlPath = entry["url_path"]?.string,
                  let title = entry["title"]?.string, !title.isEmpty
            else { return nil }
            return (urlPath, title)
        }

        return disambiguated(entries.map { DashboardListing(urlPath: $0.path, title: $0.title) })
    }

    /// Suffix the url_path onto titles that clash *within this list*. A
    /// hidden dashboard that shares a title should not put "(hot-tub)" after
    /// the one the menu does show.
    public static func disambiguated(_ listings: [DashboardListing]) -> [DashboardListing] {
        var counts: [String: Int] = [:]
        for listing in listings { counts[listing.name, default: 0] += 1 }
        return listings.map { listing in
            let clashes = (counts[listing.name] ?? 0) > 1
            let title = clashes ? "\(listing.name) (\(listing.urlPath ?? ""))" : listing.name
            return DashboardListing(urlPath: listing.urlPath, title: title, name: listing.name)
        }
    }
}
