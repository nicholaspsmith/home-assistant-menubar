import Foundation

/// One entry in the menu's dashboard picker.
public struct DashboardListing: Equatable, Sendable {
    /// `nil` is the built-in Overview, which `lovelace/dashboards/list` never
    /// returns and whose config is requested with no `url_path`.
    public let urlPath: String?
    public let title: String

    public init(urlPath: String?, title: String) {
        self.urlPath = urlPath
        self.title = title
    }

    public static let overview = DashboardListing(urlPath: nil, title: "Overview")

    /// Build the picker's list from a `lovelace/dashboards/list` result.
    public static func list(from result: JSONValue) -> [DashboardListing] {
        let user = (result.array ?? []).compactMap { entry -> DashboardListing? in
            guard let urlPath = entry["url_path"]?.string,
                  let title = entry["title"]?.string, !title.isEmpty
            else { return nil }
            return DashboardListing(urlPath: urlPath, title: title)
        }
        return [.overview] + user
    }
}
