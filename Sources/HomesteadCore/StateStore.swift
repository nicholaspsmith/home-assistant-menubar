// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// Applies `subscribe_entities` events. That subscription sends a compressed
/// form — `a` adds, `c` changes (with `+` set and `-` unset), `r` removes —
/// rather than whole states, so the store has to merge rather than replace.
public struct StateStore: Sendable {
    public private(set) var states: [String: EntityState] = [:]

    public init() {}

    public subscript(entityId: String) -> EntityState? { states[entityId] }

    public mutating func reset() { states.removeAll() }

    /// - Returns: the entity ids this event touched, so only those rows redraw.
    @discardableResult
    public mutating func apply(_ event: JSONValue) -> Set<String> {
        var changed: Set<String> = []

        for (entityId, payload) in event["a"]?.object ?? [:] {
            states[entityId] = EntityState(
                state: payload["s"]?.string ?? "unknown",
                attributes: payload["a"]?.object ?? [:]
            )
            changed.insert(entityId)
        }

        for (entityId, payload) in event["c"]?.object ?? [:] {
            guard var existing = states[entityId] else { continue }
            if let added = payload["+"] {
                if let state = added["s"]?.string { existing.state = state }
                for (key, value) in added["a"]?.object ?? [:] { existing.attributes[key] = value }
            }
            for removed in payload["-"]?["a"]?.array ?? [] {
                if let key = removed.string { existing.attributes.removeValue(forKey: key) }
            }
            states[entityId] = existing
            changed.insert(entityId)
        }

        for removed in event["r"]?.array ?? [] {
            guard let entityId = removed.string, states.removeValue(forKey: entityId) != nil else { continue }
            changed.insert(entityId)
        }

        return changed
    }
}
