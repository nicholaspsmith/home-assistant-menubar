import Foundation

/// Everything the app remembers except the token, which lives in the Keychain.
public final class Settings {
    public enum Key {
        public static let haURL = "HAURL"
        public static let selectedDashboard = "SelectedDashboard"
        public static let showSensors = "ShowSensors"
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

    public var showSensors: Bool {
        get { defaults.bool(forKey: Key.showSensors) }
        set { defaults.set(newValue, forKey: Key.showSensors) }
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
