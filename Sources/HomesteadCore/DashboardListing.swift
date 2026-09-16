import Foundation

/// One entry in the menu's dashboard picker.
public struct DashboardListing: Equatable, Sendable {
    /// The dashboard's `url_path`, which is also its identity everywhere else.
    public let urlPath: String?
    /// What the picker shows — the dashboard's title, suffixed with its
    /// url_path when another dashboard shares that title.
    public let title: String

    public init(urlPath: String?, title: String) {
        self.urlPath = urlPath
        self.title = title
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

        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.title, default: 0] += 1 }

        return entries.map { entry in
            let title = (counts[entry.title] ?? 0) > 1 ? "\(entry.title) (\(entry.path))" : entry.title
            return DashboardListing(urlPath: entry.path, title: title)
        }
    }
}
