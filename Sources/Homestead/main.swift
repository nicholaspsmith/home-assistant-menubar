// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore
import StatusItemKit
import os

let log = Logger(subsystem: "com.nicholaspsmith.Homestead", category: "app")

/// Homestead — Home Assistant devices in the menu bar. The dropdown's first row
/// picks a dashboard; the rest of it is that dashboard's devices.
@MainActor
final class App: NSObject, NSApplicationDelegate {
    private var status: StatusItemController!
    /// Steps this icon aside while Barn reveals its hidden block.
    private var yieldClient: YieldClient!
    let settings = Settings()
    /// The house is the default icon; Dot is the fallback for anyone who wants
    /// a plain status light. Neither varies with a fraction, so the
    /// proportional meters are not offered.
    private let appearance = MeterAppearance(defaultStyle: .character)
    private var appearanceMenu: AppearanceMenu!
    private var connectionWindow: ConnectionWindowController?
    private var dashboardsWindow: DashboardsWindowController?
    private(set) var model: AppModel!
    private var menuController: MenuController!
    /// Gertie's once-a-minute welcome, in her turn with the other Menumon
    /// mascots: the front door swings open a crack and shuts.
    private var minuteCue: MinuteCue!
    private var door: CGFloat = 0
    private lazy var welcome = IconAnimation(duration: CharacterIcon.houseDoorDuration, frame: { [weak self] t in
        self?.door = CGFloat(t / CharacterIcon.houseDoorDuration)
        self?.refreshIcon()
    }, completion: { [weak self] in
        self?.door = 0
        self?.refreshIcon()
    })

    /// The weather's own motion, continuous while it shows: sun gleaming,
    /// clouds drifting, rain falling. The phase steps at the weather's frame
    /// rate and the icon is redrawn only when it steps — never the menu.
    private var weatherPhase: CGFloat = 0
    private var weatherTimer: Timer?
    private var weatherRate: Double = 0
    private var weatherFrame = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window opens: it is what makes ⌘V work in them.
        MainMenu.install()

        status = StatusItemController(
            // Nothing is polled: state arrives on the socket. The timer is the
            // fallback that redraws the icon if a push is ever missed.
            pollInterval: 60,
            onPoll: { [weak self] in self?.refreshIcon() },
            onBuildMenu: { [weak self] menu in self?.buildMenu(menu) },
            autosaveName: "Homestead"
        )
        status.start()
        yieldClient = YieldClient(item: status)
        yieldClient.start()

        appearanceMenu = AppearanceMenu(appearance: appearance,
                                        styles: [.character, .dot],
                                        characterTitle: "House",
                                        onChange: { [weak self] in
                                            self?.refreshIcon()
                                            self?.updateWeatherMotion()
                                        })

        // Keychain migrations run with the first token read, off the main
        // thread (TokenStore.loadInBackground): they can wait on a prompt.

        model = AppModel(settings: settings)
        menuController = MenuController(
            model: model,
            addFooter: { [weak self] menu in self?.addFooter(to: menu) },
            onOpenConnection: { [weak self] in self?.openConnection() }
        )
        model.onSnapshotChange = { [weak self] _ in
            self?.refreshIcon()
            self?.updateWeatherMotion()
            self?.menuController.rebuildIfOpen()
        }
        model.onWeatherChange = { [weak self] in
            self?.refreshIcon()
            self?.updateWeatherMotion()
        }
        model.onEntitiesChanged = { [weak self] entities in
            self?.menuController.apply(entities: entities)
        }
        status.onMenuDidClose = { [weak self] in self?.menuController.menuClosed() }
        model.start()
        refreshIcon()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWeatherMotion() }
        }
        updateWeatherMotion()

        minuteCue = MinuteCue { [weak self] in
            guard let self, let snapshot = self.model?.snapshot,
                  HouseIcon.welcomes(snapshot: snapshot, appearance: self.appearance) else { return }
            self.welcome.start()
        }
        minuteCue.start()
    }

    // MARK: - Menu

    private func buildMenu(_ menu: NSMenu) {
        menuController.build(menu)
    }

    /// The foot of the menu: Settings ▸ (this app's preferences, then the
    /// shared Icon ▸, Start at Login and Version), then Quit.
    func addFooter(to menu: NSMenu) {
        SettingsMenu.addFooter(to: menu, appName: "Homestead", items: { submenu in
            addSettingsItems(to: submenu)
        }, appearance: appearanceMenu, startAtLogin: true)
    }

    /// Homestead's own settings, top of the Settings submenu.
    private func addSettingsItems(to menu: NSMenu) {
        let sensors = NSMenuItem(title: "Show Sensors", action: #selector(toggleSensors), keyEquivalent: "")
        sensors.target = self
        sensors.state = settings.showSensors ? .on : .off
        menu.addItem(sensors)

        if let weather = weatherMenuItem() { menu.addItem(weather) }

        menu.addItem(.separator())

        let dashboards = NSMenuItem(title: "Dashboards…", action: #selector(openDashboards), keyEquivalent: "")
        dashboards.target = self
        dashboards.isEnabled = !model.allDashboards.isEmpty
        menu.addItem(dashboards)

        // Signed out, the menu leads with Connect to Home Assistant… instead.
        if MenuController.showsConnectionItem(model.snapshot.connection) {
            let connection = NSMenuItem(title: "Connection…", action: #selector(openConnection), keyEquivalent: "")
            connection.target = self
            menu.addItem(connection)
        }
    }

    /// Weather ▸ Automatic, each weather entity, None. Absent when Home
    /// Assistant has no weather entity at all.
    private func weatherMenuItem() -> NSMenuItem? {
        let snapshot = model.snapshot
        guard !snapshot.weatherEntities.isEmpty else { return nil }
        let submenu = NSMenu()
        let chosen = settings.weatherEntity

        let automaticName = WeatherReport.automaticEntity(from: snapshot.weatherEntities.map(\.id))
            .flatMap { id in snapshot.weatherEntities.first { $0.id == id }?.name }
        let automatic = NSMenuItem(title: automaticName.map { "Automatic (\($0))" } ?? "Automatic",
                                   action: #selector(chooseWeather(_:)), keyEquivalent: "")
        automatic.state = chosen == nil ? .on : .off
        submenu.addItem(automatic)
        submenu.addItem(.separator())
        for entity in snapshot.weatherEntities {
            let item = NSMenuItem(title: entity.name, action: #selector(chooseWeather(_:)), keyEquivalent: "")
            item.representedObject = entity.id
            item.state = chosen == entity.id ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let none = NSMenuItem(title: "None", action: #selector(chooseWeather(_:)), keyEquivalent: "")
        none.representedObject = ""
        none.state = chosen == "" ? .on : .off
        submenu.addItem(none)
        for item in submenu.items { item.target = self }

        let item = NSMenuItem(title: "Weather", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func chooseWeather(_ sender: NSMenuItem) {
        model.setWeatherEntity(sender.representedObject as? String)
    }

    @objc private func toggleSensors() {
        model.setShowSensors(!settings.showSensors)
        menuController.rebuildIfOpen()
    }

    @objc func openConnection() {
        if connectionWindow == nil {
            connectionWindow = ConnectionWindowController(settings: settings) { [weak self] in
                self?.connectionSaved()
            }
        }
        connectionWindow?.show()
    }

    func connectionSaved() {
        model.reloadConfiguration()
    }

    @objc func openDashboards() {
        if dashboardsWindow == nil {
            dashboardsWindow = DashboardsWindowController(settings: settings) { [weak self] in
                self?.model.refreshVisibleDashboards()
            }
        }
        dashboardsWindow?.show(dashboards: model.allDashboards)
    }

    // MARK: - Icon

    func refreshIcon() {
        let snapshot = model?.snapshot ?? Snapshot()
        status.setIcon(HouseIcon.image(snapshot: snapshot, appearance: appearance, door: door,
                                       weatherPhase: weatherPhase))
        let tip = HouseIcon.toolTip(snapshot: snapshot)
        if status.button?.toolTip != tip { status.button?.toolTip = tip }
    }

    /// Starts, retimes or stops the weather's motion: it runs only while the
    /// house icon shows weather from a reachable Home Assistant, and never
    /// under Reduce Motion, where the sky holds still.
    private func updateWeatherMotion() {
        let snapshot = model?.snapshot ?? Snapshot()
        let weather = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : HouseIcon.movingWeather(snapshot: snapshot, appearance: appearance)
        guard let weather else {
            weatherTimer?.invalidate()
            weatherTimer = nil
            weatherFrame = -1
            if weatherPhase != 0 {
                weatherPhase = 0
                refreshIcon()
            }
            return
        }
        let rate = CharacterIcon.houseWeatherFrameRate(weather)
        guard weatherTimer == nil || rate != weatherRate else { return }
        weatherTimer?.invalidate()
        weatherRate = rate
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.weatherTick() }
        }
        timer.tolerance = 0.2 / rate
        RunLoop.main.add(timer, forMode: .common)
        weatherTimer = timer
        weatherTick()
    }

    /// One step of the weather's loop, from the clock, so a late tick catches
    /// up rather than slowing the sky. Redraws only when the frame changes.
    private func weatherTick() {
        let frames = Int((weatherRate * CharacterIcon.houseWeatherLoopDuration).rounded())
        guard frames > 0 else { return }
        let frame = Int((Date().timeIntervalSinceReferenceDate * weatherRate).rounded(.down)) % frames
        guard frame != weatherFrame else { return }
        weatherFrame = frame
        weatherPhase = CGFloat(frame) / CGFloat(frames)
        refreshIcon()
    }
}

// Handle `--login on|off|status` and exit before any UI exists. Start at Login is
// SMAppService.mainApp, which can only register the calling process's own bundle,
// so this is the only way an installer or script can turn it on.
LoginCLI.runIfRequested()

// Top-level code is nonisolated, but this runs on the main thread by
// definition, which is what lets the whole app be `@MainActor`.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `delegate` stays alive for the process: run() never returns.
    app.run()
}
