// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// One `call_service` command, built from a row's control and the device's kind.
public struct ServiceCall: Equatable, Sendable {
    public let domain: String
    public let service: String
    /// Usually one entity; a dashboard button may target several, or none.
    public let entityIds: [String]
    public let serviceData: [String: JSONValue]

    public init(domain: String, service: String, entityId: String, serviceData: [String: JSONValue]) {
        self.init(domain: domain, service: service, entityIds: [entityId], serviceData: serviceData)
    }

    public init(domain: String, service: String, entityIds: [String], serviceData: [String: JSONValue]) {
        self.domain = domain
        self.service = service
        self.entityIds = entityIds
        self.serviceData = serviceData
    }

    public var entityId: String { entityIds.first ?? "" }

    public static func toggle(_ device: Device, on: Bool) -> ServiceCall? {
        switch device.kind {
        case .light, .fan, .toggle, .thermostat, .mediaPlayer:
            // A group has no turn_on of its own; the generic one fans out to
            // its members.
            let domain = device.domain == "group" ? "homeassistant" : device.domain
            return ServiceCall(domain: domain, service: on ? "turn_on" : "turn_off",
                               entityId: device.entityId, serviceData: [:])
        case .cover:
            return ServiceCall(domain: "cover", service: on ? "open_cover" : "close_cover",
                               entityId: device.entityId, serviceData: [:])
        case .sensor, .button:
            return nil
        }
    }

    /// Press a button row: the card's own call, or the entity's press.
    public static func press(_ device: Device) -> ServiceCall? {
        if let action = device.action {
            return ServiceCall(domain: action.domain, service: action.service,
                               entityIds: action.entityIds, serviceData: action.data)
        }
        switch device.domain {
        case "button", "input_button":
            return ServiceCall(domain: device.domain, service: "press", entityId: device.entityId, serviceData: [:])
        case "script", "scene":
            return ServiceCall(domain: device.domain, service: "turn_on", entityId: device.entityId, serviceData: [:])
        default:
            return nil
        }
    }

    /// A cover's three buttons.
    public enum CoverMotion: Equatable, Sendable {
        case open, stop, close

        var service: String {
            switch self {
            case .open: return "open_cover"
            case .stop: return "stop_cover"
            case .close: return "close_cover"
            }
        }
    }

    public static func cover(_ device: Device, _ motion: CoverMotion) -> ServiceCall? {
        guard case .cover = device.kind else { return nil }
        return ServiceCall(domain: "cover", service: motion.service, entityId: device.entityId, serviceData: [:])
    }

    /// Set what a thermostat is working towards: one target, or a heat/cool
    /// band. Values are sent as given; `ThermostatTargets` has already snapped
    /// and clamped them.
    public static func setTargets(_ device: Device, _ targets: ThermostatTargets) -> ServiceCall? {
        guard device.kind == .thermostat else { return nil }
        let data: [String: JSONValue]
        switch targets {
        case .single(let value):
            data = ["temperature": .number(value)]
        case .range(let low, let high):
            data = ["target_temp_low": .number(low), "target_temp_high": .number(high)]
        }
        return ServiceCall(domain: device.domain, service: "set_temperature", entityId: device.entityId,
                           serviceData: data)
    }

    public static func setHVACMode(_ device: Device, _ mode: String) -> ServiceCall? {
        guard device.kind == .thermostat, device.domain == "climate" else { return nil }
        return ServiceCall(domain: "climate", service: "set_hvac_mode", entityId: device.entityId,
                           serviceData: ["hvac_mode": .string(mode)])
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
        case .mediaPlayer:
            return ServiceCall(domain: "media_player", service: "volume_set", entityId: device.entityId,
                               serviceData: ["volume_level": .number(min(max(fraction, 0), 1))])
        case .thermostat, .toggle, .sensor, .button:
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

    /// The transport controls a player can offer.
    public enum Transport: Equatable, Sendable {
        case playPause
        case previous
        case next
        case volumeDown
        case volumeUp
        /// Mute, or unmute: the value to set, not a toggle — HA has no toggle.
        case mute(Bool)

        var service: String {
            switch self {
            case .playPause: return "media_play_pause"
            case .previous: return "media_previous_track"
            case .next: return "media_next_track"
            case .volumeDown: return "volume_down"
            case .volumeUp: return "volume_up"
            case .mute: return "volume_mute"
            }
        }

        var data: [String: JSONValue] {
            guard case .mute(let muted) = self else { return [:] }
            return ["is_volume_muted": .bool(muted)]
        }
    }

    public static func transport(_ device: Device, _ control: Transport) -> ServiceCall? {
        guard device.kind == .mediaPlayer else { return nil }
        return ServiceCall(domain: "media_player", service: control.service,
                           entityId: device.entityId, serviceData: control.data)
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
        ]
        switch entityIds.count {
        case 0: break
        case 1: payload["target"] = .object(["entity_id": .string(entityIds[0])])
        default: payload["target"] = .object(["entity_id": .array(entityIds.map { .string($0) })])
        }
        if !serviceData.isEmpty { payload["service_data"] = .object(serviceData) }
        return payload
    }
}
