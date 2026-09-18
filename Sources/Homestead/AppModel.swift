import AppKit
import HomesteadCore
import Network
import os

enum ConnectionState: Equatable {
    case unconfigured
    case connecting
    case connected
    case unreachable(String)
    case authFailed
}

/// Everything the menu and the icon draw from.
struct Snapshot {
    var connection: ConnectionState = .unconfigured
    var dashboards: [DashboardListing] = []
    var selected: DashboardListing?
    var groups: [DeviceGroup] = []
    var states: [String: EntityState] = [:]
    /// How this Home Assistant writes temperatures, from its own config.
    var temperatureUnit: String = "°"

    var lightsOn: Int {
        groups.flatMap(\.devices)
            .filter { $0.kind == .light }
            .filter { states[$0.entityId]?.isOn == true }
            .count
    }

    var anyFanOn: Bool {
        groups.flatMap(\.devices)
            .contains { $0.kind == .fan && states[$0.entityId]?.isOn == true }
    }
}

/// Owns the connection and the state behind the menu: connect, list
/// dashboards, load the selected one's config, subscribe to exactly its
/// entities, and keep all of that current across drops.
@MainActor
final class AppModel {
    private let settings: Settings
    private let log = Logger(subsystem: "com.nicholaspsmith.Homestead", category: "model")

    private var client: HAClient?
    private var store = StateStore()
    private var refs: [DeviceRef] = []
    private var subscriptionId: Int?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// Every dashboard Home Assistant reports, before the visibility filter —
    /// the Dashboards window needs the full list to tick from.
    private(set) var allDashboards: [DashboardListing] = []
    /// Per-entity in-flight level call, so a drag sends one call at a time.
    private var levelInFlight: Set<String> = []
    private var levelQueued: [String: Double] = [:]
    private var colorQueued: [String: (red: Int, green: Int, blue: Int)] = [:]
    private var warmthQueued: [String: Double] = [:]
    /// Set while a dashboard's first state snapshot is outstanding. Until it
    /// lands, the rows on screen belong to the *previous* dashboard, so its
    /// entities must rebuild the menu rather than be patched into rows that do
    /// not exist.
    private var awaitingFirstSnapshot = false

    private(set) var snapshot = Snapshot()
    var onSnapshotChange: ((Snapshot) -> Void)?
    var onEntitiesChanged: ((Set<String>) -> Void)?

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        startPathMonitor()
        reloadConfiguration()
    }

    /// Called at launch and whenever the Connection window saves.
    func reloadConfiguration() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        let old = client
        client = nil
        subscriptionId = nil
        store.reset()
        Task { await old?.disconnect() }

        guard let urlText = settings.haURL, let url = HAURL.websocketURL(from: urlText),
              let token = TokenStore.token()
        else {
            update { $0.connection = .unconfigured }
            return
        }
        connect(url: url, token: token)
    }

    func retryNow() {
        reconnectAttempt = 0
        reloadConfiguration()
    }

    func select(dashboard: DashboardListing) {
        settings.selectedDashboardPath = dashboard.urlPath ?? ""
        update { $0.selected = dashboard }
        Task { await loadDashboardLoggingErrors(dashboard) }
    }

    /// The Dashboards window changed which dashboards are offered.
    func refreshVisibleDashboards() {
        let listings = settings.visible(from: allDashboards)
        let selected = listings.contains { $0.urlPath == snapshot.selected?.urlPath }
            ? snapshot.selected
            : settings.defaultDashboard(from: listings)
        update {
            $0.dashboards = listings
            $0.selected = selected
        }
        // Hiding the dashboard you were on moves you to another one.
        if let selected, selected.urlPath != snapshot.selected?.urlPath || snapshot.groups.isEmpty {
            Task { await loadDashboardLoggingErrors(selected) }
        }
    }

    func setShowSensors(_ on: Bool) {
        settings.showSensors = on
        rebuildGroups()
    }

    func state(for entityId: String) -> EntityState? { store[entityId] }

    // MARK: - Actions

    func toggle(_ device: Device, on: Bool) {
        guard let call = ServiceCall.toggle(device, on: on) else { return }
        Task { await perform(call, revertEntity: device.entityId) }
    }

    /// Slider drags fire continuously; at most one call per entity is in flight
    /// and only the newest value waits behind it, so a drag cannot queue fifty
    /// stale commands.
    func setLevel(_ device: Device, fraction: Double) {
        guard ServiceCall.setLevel(device, fraction: fraction, state: store[device.entityId]) != nil else { return }
        if levelInFlight.contains(device.entityId) {
            levelQueued[device.entityId] = fraction
            return
        }
        levelInFlight.insert(device.entityId)
        Task { await sendLevel(device, fraction: fraction) }
    }

    private func sendLevel(_ device: Device, fraction: Double) async {
        defer {
            if let next = levelQueued.removeValue(forKey: device.entityId) {
                Task { await sendLevel(device, fraction: next) }
            } else {
                levelInFlight.remove(device.entityId)
            }
        }
        guard let call = ServiceCall.setLevel(device, fraction: fraction, state: store[device.entityId]) else { return }
        await perform(call, revertEntity: nil)
    }

    /// The colour panel fires continuously while the wheel is dragged, so this
    /// shares the level path's one-in-flight-plus-latest coalescing: the bulb
    /// cannot keep up with every intermediate colour, and stale ones arriving
    /// late would fight the final choice.
    func setColor(_ device: Device, red: Int, green: Int, blue: Int) {
        guard ServiceCall.setColor(device, red: red, green: green, blue: blue) != nil else { return }
        let key = "color:" + device.entityId
        if levelInFlight.contains(key) {
            colorQueued[device.entityId] = (red, green, blue)
            return
        }
        levelInFlight.insert(key)
        Task { await sendColor(device, red: red, green: green, blue: blue) }
    }

    private func sendColor(_ device: Device, red: Int, green: Int, blue: Int) async {
        defer {
            if let next = colorQueued.removeValue(forKey: device.entityId) {
                Task { await sendColor(device, red: next.red, green: next.green, blue: next.blue) }
            } else {
                levelInFlight.remove("color:" + device.entityId)
            }
        }
        guard let call = ServiceCall.setColor(device, red: red, green: green, blue: blue) else { return }
        await perform(call, revertEntity: nil)
    }

    /// Transport is a single tap, not a drag: no coalescing to do.
    func transport(_ device: Device, _ control: ServiceCall.Transport) {
        guard let call = ServiceCall.transport(device, control) else { return }
        Task { await perform(call, revertEntity: nil) }
    }

    /// Warmth, driven from a slider, so coalesced like the others.
    func setColorTemperature(_ device: Device, fraction: Double) {
        let kelvin = ColorTemperatureRange(state: store[device.entityId]).kelvin(at: fraction)
        guard ServiceCall.setColorTemperature(device, kelvin: kelvin) != nil else { return }
        let key = "warmth:" + device.entityId
        if levelInFlight.contains(key) {
            warmthQueued[device.entityId] = fraction
            return
        }
        levelInFlight.insert(key)
        Task { await sendWarmth(device, fraction: fraction) }
    }

    private func sendWarmth(_ device: Device, fraction: Double) async {
        defer {
            if let next = warmthQueued.removeValue(forKey: device.entityId) {
                Task { await sendWarmth(device, fraction: next) }
            } else {
                levelInFlight.remove("warmth:" + device.entityId)
            }
        }
        let kelvin = ColorTemperatureRange(state: store[device.entityId]).kelvin(at: fraction)
        guard let call = ServiceCall.setColorTemperature(device, kelvin: kelvin) else { return }
        await perform(call, revertEntity: nil)
    }

    private func perform(_ call: ServiceCall, revertEntity: String?) async {
        guard let client else { return }
        do {
            _ = try await client.send(call.commandPayload)
        } catch {
            log.error("\(call.domain, privacy: .public).\(call.service, privacy: .public) failed: \(String(describing: error), privacy: .public) on \(call.entityId, privacy: .private)")
            // Optimistic UI: put the row back the way HA still has it.
            if let revertEntity { onEntitiesChanged?([revertEntity]) }
        }
    }

    // MARK: - Connection

    private func connect(url: URL, token: String) {
        update { $0.connection = .connecting }
        let client = HAClient(transport: URLSessionTransport())
        self.client = client

        Task {
            do {
                try await client.connect(url: url, token: token)
                await client.setOnClose { [weak self] reason in
                    Task { @MainActor in self?.handleDrop(reason: reason) }
                }
                reconnectAttempt = 0
                update { $0.connection = .connected }
                await loadTemperatureUnit()
                try await loadDashboards()
            } catch HAClientError.authInvalid {
                update { $0.connection = .authFailed }
            } catch {
                handleDrop(reason: error.localizedDescription)
            }
        }
    }

    /// A climate entity carries no unit of its own — the house has one.
    private func loadTemperatureUnit() async {
        guard let client,
              let config = try? await client.send(["type": .string("get_config")]),
              let unit = config["unit_system"]?["temperature"]?.string
        else { return }
        update { $0.temperatureUnit = unit }
    }

    private func loadDashboards() async throws {
        guard let client else { return }
        let result = try await client.send(["type": .string("lovelace/dashboards/list")])
        let all = DashboardListing.list(from: result)
        allDashboards = all
        // Dashboard titles and entity ids name someone's home. They stay
        // private in the log (visible with `log --info` on this machine, not
        // baked into sysdiagnose bundles); only counts are public.
        log.info("dashboards: \(all.count, privacy: .public) — \(all.map(\.title).joined(separator: ", "), privacy: .private)")
        var listings = settings.visible(from: all)
        guard var chosen = settings.defaultDashboard(from: listings) else { return }

        // A dashboard whose config cannot be read is not pickable; drop it and
        // fall through to the next candidate.
        while true {
            do {
                try await loadDashboard(chosen)
                break
            } catch {
                log.info("dropping unreadable dashboard \(chosen.title, privacy: .private)")
                listings.removeAll { $0.urlPath == chosen.urlPath }
                update { $0.dashboards = listings }
                guard let next = listings.first else { return }
                chosen = next
            }
        }
        log.info("selected dashboard: \(chosen.title, privacy: .private)")
        update {
            $0.dashboards = listings
            $0.selected = chosen
        }
    }

    /// Picker changes have nowhere to report a failure, so they log it instead.
    private func loadDashboardLoggingErrors(_ dashboard: DashboardListing) async {
        do {
            try await loadDashboard(dashboard)
        } catch {
            log.error("dashboard \(dashboard.title, privacy: .private) failed to load")
        }
    }

    private func loadDashboard(_ dashboard: DashboardListing) async throws {
        guard let client else { return }
        var payload: [String: JSONValue] = ["type": .string("lovelace/config")]
        if let urlPath = dashboard.urlPath { payload["url_path"] = .string(urlPath) }

        let config = try await client.send(payload)
        refs = DashboardParser.references(in: config)
        awaitingFirstSnapshot = true

        if let existing = subscriptionId {
            await client.unsubscribe(existing)
            subscriptionId = nil
        }
        store.reset()

        let ids = refs.map(\.entityId)
        guard !ids.isEmpty else {
            update { $0.groups = [] }
            return
        }
        subscriptionId = try await client.subscribe([
            "type": .string("subscribe_entities"),
            "entity_ids": .array(ids.map { .string($0) }),
        ], onEvent: { [weak self] event in
            Task { @MainActor in self?.applyEvent(event) }
        })
    }

    private func applyEvent(_ event: JSONValue) {
        let changed = store.apply(event)
        guard !changed.isEmpty else { return }
        snapshot.states = store.states

        // A kind can change with state (a cover only reports SET_POSITION once
        // it is known), and names arrive with the first snapshot, so the first
        // event after a load rebuilds rather than patches.
        if awaitingFirstSnapshot || snapshot.groups.isEmpty {
            awaitingFirstSnapshot = false
            rebuildGroups()
        } else {
            onEntitiesChanged?(changed)
        }
    }

    private func rebuildGroups() {
        snapshot.states = store.states
        snapshot.groups = DeviceCatalog.build(refs: refs, states: store.states, showSensors: settings.showSensors)
        let shown = snapshot.groups.flatMap(\.devices)
        let shownIds = Set(shown.map(\.entityId))
        let skipped = refs.map(\.entityId).filter { !shownIds.contains($0) }
        let rowSummary = shown.map { "\($0.entityId)=\($0.kind)" }.joined(separator: ", ")
        log.info("rows: \(shown.count, privacy: .public) shown, \(skipped.count, privacy: .public) skipped — \(rowSummary, privacy: .private) | \(skipped.joined(separator: ", "), privacy: .private)")
        onSnapshotChange?(snapshot)
    }

    private func handleDrop(reason: String) {
        client = nil
        subscriptionId = nil
        update { $0.connection = .unreachable(reason) }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delay = ReconnectPolicy.delay(attempt: reconnectAttempt)
        reconnectAttempt += 1
        log.info("reconnecting in \(delay, privacy: .public)s")
        let attempt = reconnectAttempt
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            // reloadConfiguration resets the counter, so carry it across a
            // genuine retry: otherwise every failure waits only one second.
            self.reloadConfiguration()
            self.reconnectAttempt = attempt
        }
    }

    /// Mullvad connecting or disconnecting kills or restores the Tailscale
    /// route to HA. Waiting out the backoff after a network change wastes up to
    /// thirty seconds when the server is already reachable again.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self else { return }
                if case .unreachable = self.snapshot.connection { self.retryNow() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.nicholaspsmith.Homestead.path"))
        pathMonitor = monitor
    }

    private func update(_ change: (inout Snapshot) -> Void) {
        change(&snapshot)
        onSnapshotChange?(snapshot)
    }
}
