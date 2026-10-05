// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// A service call a dashboard card makes when it is tapped — a remote's Back
/// key, a TV's "switch to YouTube", a button entity's press.
///
/// A card like that is a button, not the entity it names: the Studio TV
/// dashboard is fifteen tiles that all name `remote.smart_tv_pro` and each send
/// a different command. Showing the entity would give one switch that turns
/// the remote on and off.
public struct CardAction: Equatable, Sendable {
    public let domain: String
    public let service: String
    public let entityIds: [String]
    public let data: [String: JSONValue]
    /// Set when the card asks before acting (`confirmation:`); the text to ask.
    public let confirmation: String?

    public init(domain: String, service: String, entityIds: [String],
                data: [String: JSONValue] = [:], confirmation: String? = nil) {
        self.domain = domain
        self.service = service
        self.entityIds = entityIds
        self.data = data
        self.confirmation = confirmation
    }

    /// Reads a `tap_action`. Only actions that call a service become buttons:
    /// `toggle` and `more-info` are what the row's own controls already do,
    /// and `navigate`/`url` lead somewhere a menu cannot follow.
    ///
    /// - Parameter cardEntity: the card's `entity`, which an action with no
    ///   target of its own acts on.
    public static func parse(_ action: JSONValue?, cardEntity: String?) -> CardAction? {
        guard let action, let kind = action["action"]?.string else { return nil }
        // `call-service`/`service`/`service_data` are the pre-2024.8 spellings.
        let name: String?
        switch kind {
        case "perform-action": name = action["perform_action"]?.string ?? action["service"]?.string
        case "call-service": name = action["service"]?.string ?? action["perform_action"]?.string
        default: return nil
        }
        guard let name, let dot = name.firstIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return nil }

        var data = (action["data"] ?? action["service_data"])?.object ?? [:]
        var targets = entityIds(in: action["target"]?["entity_id"])
        if targets.isEmpty, let inData = data["entity_id"] {
            targets = entityIds(in: inData)
        }
        data["entity_id"] = nil
        if targets.isEmpty, let cardEntity, action["target"] == nil { targets = [cardEntity] }

        let confirmation: String?
        switch action["confirmation"] {
        case .bool(true)?: confirmation = "Are you sure?"
        case .object(let fields)?: confirmation = fields["text"]?.string ?? "Are you sure?"
        default: confirmation = nil
        }

        return CardAction(domain: String(name[..<dot]), service: String(name[name.index(after: dot)...]),
                          entityIds: targets, data: data, confirmation: confirmation)
    }

    /// Whether this is just the entity's own on/off — a TV tile whose tap
    /// toggles the TV. The entity's row already has that switch, so the card is
    /// shown as the entity rather than as a second, redundant button.
    public func isOwnToggle(of entityId: String?) -> Bool {
        guard let entityId, entityIds == [entityId], data.isEmpty,
              domain == String(entityId.prefix(while: { $0 != "." })) || domain == "homeassistant"
        else { return false }
        return ["toggle", "turn_on", "turn_off"].contains(service)
    }

    /// Identity for de-duplication: the same call from two cards is one button.
    var signature: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = (try? encoder.encode(JSONValue.object(data))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return "\(domain).\(service)|\(entityIds.joined(separator: ","))|\(encoded)"
    }

    private static func entityIds(in value: JSONValue?) -> [String] {
        switch value {
        case .string(let id)?: return id.contains(".") ? [id] : []
        case .array(let ids)?: return ids.compactMap(\.string).filter { $0.contains(".") }
        default: return []
        }
    }
}
