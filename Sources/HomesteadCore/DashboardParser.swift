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
    /// Nearest enclosing title — card, heading card, section, then view.
    public let header: String
    /// The card's `icon:`, an `mdi:` name.
    public let icon: String?
    /// Set when the card is a button: tapping it calls this rather than
    /// toggling `entityId`, which is then only the entity it acts on.
    public let action: CardAction?
    /// The grid or horizontal stack the card sits in, so buttons laid out
    /// together on the dashboard stay together — and in the same shape — in
    /// the menu.
    public let layout: ButtonLayout?

    public init(entityId: String, nameOverride: String?, header: String,
                icon: String? = nil, action: CardAction? = nil, layout: ButtonLayout? = nil) {
        self.entityId = entityId
        self.nameOverride = nameOverride
        self.header = header
        self.icon = icon
        self.action = action
        self.layout = layout
    }
}

/// One grid card on the dashboard: which one, and how many columns it has.
public struct ButtonLayout: Equatable, Sendable {
    public let id: Int
    public let columns: Int

    public init(id: Int, columns: Int) {
        self.id = id
        self.columns = columns
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

    /// A subtitle heading longer than this is a description ("Read from iLO
    /// over IPMI — updates every 5 min"), not the name of what follows.
    private static let maximumSubtitleHeaderLength = 24

    private static let buttonDomains: Set<String> = ["button", "input_button", "script", "scene"]

    public static func references(in config: JSONValue) -> [DeviceRef] {
        var found: [DeviceRef] = []
        var seen: Set<String> = []
        var layouts = 0

        func append(_ ref: DeviceRef) {
            guard ref.entityId.contains(".") else { return }
            // An entity is listed once however many cards show it; a button is
            // listed once per distinct call, so fifteen remote keys on one
            // remote entity stay fifteen buttons.
            let key = ref.action.map { "action:" + $0.signature } ?? ref.entityId
            guard seen.insert(key).inserted else { return }
            found.append(ref)
        }

        /// A card or an `entities` row: either a button (it calls a service
        /// when tapped) or the entity it names.
        func appendCard(_ fields: [String: JSONValue], header: String, layout: ButtonLayout?) {
            let entity = fields["entity"]?.string
            if let action = CardAction.parse(fields["tap_action"], cardEntity: entity),
               !action.isOwnToggle(of: entity) {
                let target = action.entityIds.first ?? entity ?? "action:\(action.domain).\(action.service)"
                append(DeviceRef(entityId: target, nameOverride: fields["name"]?.string, header: header,
                                 icon: fields["icon"]?.string, action: action, layout: layout))
            } else if let entity {
                // Only buttons are laid out in grids; everything else is a row.
                let pressable = buttonDomains.contains(String(entity.prefix(while: { $0 != "." })))
                append(DeviceRef(entityId: entity, nameOverride: fields["name"]?.string, header: header,
                                 icon: fields["icon"]?.string, layout: pressable ? layout : nil))
            }
        }

        /// The header a `heading` card gives the cards after it, if any.
        func heading(_ node: JSONValue) -> String? {
            guard node["type"]?.string == "heading",
                  let text = node["heading"]?.string, !text.isEmpty else { return nil }
            if node["heading_style"]?.string == "subtitle", text.count > maximumSubtitleHeaderLength { return nil }
            return text
        }

        func walk(_ node: JSONValue, header: String, layout: ButtonLayout? = nil, depth: Int = 0) {
            guard depth < maximumDepth else { return }
            switch node {
            case .array(let elements):
                // A heading card titles the cards that follow it in the same
                // list, the way the dashboard draws it.
                var header = header
                for element in elements {
                    if let text = heading(element) { header = text }
                    walk(element, header: header, layout: layout, depth: depth + 1)
                }

            case .object(let fields):
                let header = fields["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? header

                appendCard(fields, header: header, layout: layout)

                // A grid card (or a section, which is one) or a horizontal
                // stack starts a new layout for the cards inside it. HA's grid
                // card defaults to three columns; a stack is one row.
                var layout = layout
                if let cards = fields["cards"]?.array {
                    switch fields["type"]?.string {
                    case "grid":
                        layouts += 1
                        layout = ButtonLayout(id: layouts, columns: fields["columns"]?.int ?? 3)
                    case "horizontal-stack":
                        layouts += 1
                        layout = ButtonLayout(id: layouts, columns: max(cards.count, 1))
                    default:
                        break
                    }
                }

                for element in fields["entities"]?.array ?? [] {
                    if let entityId = element.string {
                        append(DeviceRef(entityId: entityId, nameOverride: nil, header: header))
                    } else if let row = element.object, row["entity"] != nil || row["tap_action"] != nil {
                        appendCard(row, header: header, layout: nil)
                    } else {
                        walk(element, header: header, layout: layout, depth: depth + 1)   // nested group rows
                    }
                }

                for key in containerKeys {
                    if let child = fields[key] { walk(child, header: header, layout: layout, depth: depth + 1) }
                }
                for key in fields.keys.sorted()
                where !containerKeys.contains(key) && !skippedKeys.contains(key)
                    && key != "entity" && key != "entities" && key != "name" && key != "title" {
                    walk(fields[key]!, header: header, layout: layout, depth: depth + 1)
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
