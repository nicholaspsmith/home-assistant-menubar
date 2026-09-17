import Foundation

/// One `call_service` command, built from a row's control and the device's kind.
public struct ServiceCall: Equatable, Sendable {
    public let domain: String
    public let service: String
    public let entityId: String
    public let serviceData: [String: JSONValue]

    public init(domain: String, service: String, entityId: String, serviceData: [String: JSONValue]) {
        self.domain = domain
        self.service = service
        self.entityId = entityId
        self.serviceData = serviceData
    }

    public static func toggle(_ device: Device, on: Bool) -> ServiceCall? {
        switch device.kind {
        case .light, .fan, .toggle, .thermostat:
            return ServiceCall(domain: device.domain, service: on ? "turn_on" : "turn_off",
                               entityId: device.entityId, serviceData: [:])
        case .cover:
            return ServiceCall(domain: "cover", service: on ? "open_cover" : "close_cover",
                               entityId: device.entityId, serviceData: [:])
        case .sensor:
            return nil
        }
    }

    /// - Parameter state: the device's current state, for attributes the call
    ///   depends on (a fan's `percentage_step`). Nil is safe; the call then
    ///   uses the domain's default granularity.
    public static func setLevel(_ device: Device, fraction: Double, state: EntityState?) -> ServiceCall? {
        switch device.kind {
        case .light:
            return ServiceCall(domain: "light", service: "turn_on", entityId: device.entityId,
                               serviceData: ["brightness_pct": .number(Double(LevelMath.brightnessPct(from: fraction)))])
        case .fan:
            let step = state?.attributes["percentage_step"]?.double
            return ServiceCall(domain: "fan", service: "set_percentage", entityId: device.entityId,
                               serviceData: ["percentage": .number(Double(LevelMath.fanPercentage(from: fraction, step: step)))])
        case .cover(let positionable):
            guard positionable else { return nil }
            return ServiceCall(domain: "cover", service: "set_cover_position", entityId: device.entityId,
                               serviceData: ["position": .number(Double(LevelMath.coverPosition(from: fraction)))])
        case .thermostat:
            // climate and water_heater take the same call under their own names.
            let range = TemperatureRange(state: state)
            return ServiceCall(domain: device.domain, service: "set_temperature", entityId: device.entityId,
                               serviceData: ["temperature": .number(range.temperature(at: fraction))])
        case .toggle, .sensor:
            return nil
        }
    }

    /// Set a light's colour. Only lights have one; everything else returns nil
    /// rather than sending a call Home Assistant would reject.
    public static func setColor(_ device: Device, red: Int, green: Int, blue: Int) -> ServiceCall? {
        guard device.kind == .light else { return nil }
        let channels = [red, green, blue].map { JSONValue.number(Double($0.clamped(to: 0...255))) }
        return ServiceCall(domain: "light", service: "turn_on", entityId: device.entityId,
                           serviceData: ["rgb_color": .array(channels)])
    }

    /// Move a light along the warm-to-daylight white scale. Kelvin, not mireds:
    /// Home Assistant accepts both, and kelvin is the one that reads the same
    /// way round as the slider.
    public static func setColorTemperature(_ device: Device, kelvin: Double) -> ServiceCall? {
        guard device.kind == .light else { return nil }
        return ServiceCall(domain: "light", service: "turn_on", entityId: device.entityId,
                           serviceData: ["color_temp_kelvin": .number(kelvin.rounded())])
    }

    /// The WebSocket command body, without the `id` the client assigns.
    public var commandPayload: [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "type": .string("call_service"),
            "domain": .string(domain),
            "service": .string(service),
            "target": .object(["entity_id": .string(entityId)]),
        ]
        if !serviceData.isEmpty { payload["service_data"] = .object(serviceData) }
        return payload
    }
}
