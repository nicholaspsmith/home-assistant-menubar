// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore
import StatusItemKit
import SwiftUI

/// Homestead's Preferences window (menu ▸ Preferences…, ⌘,), on
/// StatusItemKit's shared `PreferencesPane`. It replaced the Settings and
/// Icon submenus: Start at Login, Show Sensors, the dashboards, the menu-bar
/// icon and the weather it shows, and the Home Assistant connection. Same
/// defaults keys as before; the token is never read here.
@MainActor
final class PreferencesModel: ObservableObject {
    /// Which weather entity the house follows: `Settings.weatherEntity`'s nil,
    /// "" and id, as something a Picker can tag.
    enum WeatherChoice: Hashable {
        case automatic
        case none
        case entity(String)

        init(stored: String?) {
            switch stored {
            case nil: self = .automatic
            case ""?: self = .none
            case let id?: self = .entity(id)
            }
        }

        var stored: String? {
            switch self {
            case .automatic: return nil
            case .none: return ""
            case .entity(let id): return id
            }
        }
    }

    struct WeatherOption: Hashable {
        let id: String
        let name: String
    }

    @Published var iconStyle: MeterStyle {
        didSet {
            guard iconStyle != oldValue else { return }
            actions.setIconStyle(iconStyle)
        }
    }
    @Published var showSensors: Bool {
        didSet {
            guard showSensors != oldValue else { return }
            actions.setShowSensors(showSensors)
        }
    }
    @Published var weather: WeatherChoice {
        didSet {
            guard weather != oldValue else { return }
            actions.setWeather(weather.stored)
        }
    }
    @Published private(set) var weatherOptions: [WeatherOption] = []
    /// The entity Automatic picks, for its label.
    @Published private(set) var automaticWeatherName: String?
    @Published private(set) var houseTile = NSImage()
    @Published private(set) var dotTile = NSImage()
    @Published private(set) var server: String?
    @Published private(set) var status = ""
    @Published private(set) var hasDashboards = false

    struct Actions {
        var snapshot: () -> Snapshot
        var hasDashboards: () -> Bool
        var setIconStyle: (MeterStyle) -> Void
        var setShowSensors: (Bool) -> Void
        var setWeather: (String?) -> Void
        var openDashboards: () -> Void
        var openConnection: () -> Void
    }

    private let settings: HomesteadCore.Settings
    private let appearance: MeterAppearance
    private let actions: Actions

    init(settings: HomesteadCore.Settings, appearance: MeterAppearance, actions: Actions) {
        self.settings = settings
        self.appearance = appearance
        self.actions = actions
        iconStyle = appearance.style
        showSensors = settings.showSensors
        weather = WeatherChoice(stored: settings.weatherEntity)
        refresh()
    }

    /// Re-reads everything the menu or Home Assistant may have changed: run as
    /// the window opens, and while it is open whenever the snapshot changes.
    func refresh() {
        let snapshot = actions.snapshot()
        if iconStyle != appearance.style { iconStyle = appearance.style }
        if showSensors != settings.showSensors { showSensors = settings.showSensors }
        let stored = WeatherChoice(stored: settings.weatherEntity)
        if weather != stored { weather = stored }

        let options = snapshot.weatherEntities.map { WeatherOption(id: $0.id, name: $0.name) }
        if weatherOptions != options { weatherOptions = options }
        let automatic = WeatherReport.automaticEntity(from: options.map(\.id))
            .flatMap { id in options.first { $0.id == id }?.name }
        if automaticWeatherName != automatic { automaticWeatherName = automatic }

        houseTile = HouseIcon.image(snapshot: snapshot, style: .character)
        dotTile = HouseIcon.image(snapshot: snapshot, style: .dot)

        let url = settings.haURL
        if server != url { server = url }
        let text = Self.statusText(snapshot.connection)
        if status != text { status = text }
        let dashboards = actions.hasDashboards()
        if hasDashboards != dashboards { hasDashboards = dashboards }
    }

    func openDashboards() { actions.openDashboards() }
    func openConnection() { actions.openConnection() }

    static func statusText(_ connection: ConnectionState) -> String {
        switch connection {
        case .unconfigured: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .unreachable: return "Can't reach Home Assistant"
        case .authFailed: return "Signed out"
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        PreferencesForm {
            Section("General") {
                StartAtLoginToggle()
            }

            Section {
                Toggle("Show Sensors", isOn: $model.showSensors)
                LabeledContent("Dashboards") {
                    Button("Dashboards…") { model.openDashboards() }
                        .disabled(!model.hasDashboards)
                }
            } header: {
                Text("Menu")
            } footer: {
                PreferencesNote("Sensors are read-only rows: temperatures, doors, batteries. Dashboards… chooses "
                    + "which dashboards the menu's picker offers and their order (alphabetical until you drag one).")
            }

            Section {
                IconTilePicker([
                    .init(id: MeterStyle.character, title: "House", image: model.houseTile),
                    .init(id: MeterStyle.dot, title: "Dot", image: model.dotTile),
                ], selection: $model.iconStyle)
                if !model.weatherOptions.isEmpty {
                    Picker("Weather", selection: $model.weather) {
                        Text(model.automaticWeatherName.map { "Automatic (\($0))" } ?? "Automatic")
                            .tag(PreferencesModel.WeatherChoice.automatic)
                        Divider()
                        ForEach(model.weatherOptions, id: \.id) { option in
                            Text(option.name).tag(PreferencesModel.WeatherChoice.entity(option.id))
                        }
                        Divider()
                        Text("None").tag(PreferencesModel.WeatherChoice.none)
                    }
                    .disabled(model.iconStyle != .character)
                }
            } header: {
                Text("Menu Bar Icon")
            } footer: {
                PreferencesNote("Gertie's windows light up with the lights that are on, and the weather "
                    + "outside comes from the chosen weather entity. The dot is green while Home Assistant answers.")
            }

            Section {
                LabeledContent("Server", value: model.server ?? "Not set")
                LabeledContent("Status", value: model.status)
                LabeledContent("Connection") {
                    Button("Connection…") { model.openConnection() }
                }
            } header: {
                Text("Home Assistant")
            } footer: {
                PreferencesNote("Connection… changes the server, signs in again or signs out.")
            }
        }
    }
}
