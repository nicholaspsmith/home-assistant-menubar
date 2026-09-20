// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// One entity as a dashboard refers to it, before state is known.
public struct DeviceRef: Equatable, Sendable {
    public let entityId: String
    /// The card's `name:` override, if it set one.
    public let nameOverride: String?
    /// Nearest enclosing title — card, then section, then view.
    public let header: String

    public init(entityId: String, nameOverride: String?, header: String) {
        self.entityId = entityId
        self.nameOverride = nameOverride
        self.header = header
    }
}

/// Walks a `lovelace/config` payload and pulls out the entities it displays.
///
/// The walk is structural, not card-type-aware: it collects `entity` and
/// `entities` wherever they appear and recurses through nested containers, so
/// custom cards and card types added after this was written still work. The
/// cost is that keys which name an entity *without* displaying it — a
/// conditional's `conditions`, a tap action's target — have to be skipped
/// explicitly.
public enum DashboardParser {
    private static let fallbackHeader = "Devices"

    /// Keys that reference entities for reasons other than display.
    private static let skippedKeys: Set<String> = [
        "conditions", "visibility", "filter",
        "tap_action", "hold_action", "double_tap_action",
        "icon_tap_action", "entity_id",
    ]

    /// How deep the walk will follow nested cards. Lovelace nests freely and
    /// nothing stops a config — broken, generated or hostile — from nesting
    /// thousands deep, which is a stack overflow rather than an error. No real
    /// dashboard is anywhere near this.
    private static let maximumDepth = 64

    /// Containers recursed in a fixed order, so output order is deterministic
    /// and matches what the dashboard shows.
    private static let containerKeys = ["sections", "cards", "card", "badges", "elements", "features", "chips"]

    public static func references(in config: JSONValue) -> [DeviceRef] {
        var found: [DeviceRef] = []
        var seen: Set<String> = []

        func append(entityId: String, nameOverride: String?, header: String) {
            guard entityId.contains("."), seen.insert(entityId).inserted else { return }
            found.append(DeviceRef(entityId: entityId, nameOverride: nameOverride, header: header))
        }

        func walk(_ node: JSONValue, header: String, depth: Int = 0) {
            guard depth < maximumDepth else { return }
            switch node {
            case .array(let elements):
                for element in elements { walk(element, header: header, depth: depth + 1) }

            case .object(let fields):
                let header = fields["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? header

                if let entityId = fields["entity"]?.string {
                    append(entityId: entityId, nameOverride: fields["name"]?.string, header: header)
                }

                for element in fields["entities"]?.array ?? [] {
                    if let entityId = element.string {
                        append(entityId: entityId, nameOverride: nil, header: header)
                    } else if let entityId = element["entity"]?.string {
                        append(entityId: entityId, nameOverride: element["name"]?.string, header: header)
                    } else {
                        walk(element, header: header, depth: depth + 1)   // nested group rows
                    }
                }

                for key in containerKeys {
                    if let child = fields[key] { walk(child, header: header, depth: depth + 1) }
                }
                for key in fields.keys.sorted()
                where !containerKeys.contains(key) && !skippedKeys.contains(key)
                    && key != "entity" && key != "entities" && key != "name" && key != "title" {
                    walk(fields[key]!, header: header, depth: depth + 1)
                }

            default:
                break
            }
        }

        for view in config["views"]?.array ?? [] {
            walk(view, header: view["title"]?.string ?? fallbackHeader)
        }
        return found
    }
}
