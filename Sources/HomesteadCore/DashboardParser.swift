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
    /// The `horizontal-stack` an entity row sits in, so rows the dashboard
    /// puts side by side share one line in the menu.
    public let stack: Int?
    /// When the card shows: its own `visibility`, plus that of any section,
    /// stack or `conditional` card around it.
    public let visibility: [VisibilityCondition]
    /// Set for a `gauge` card: the entity is drawn as an arc meter.
    public let gauge: GaugeSpec?
    /// Whether `header` comes from a heading card or a card or section title
    /// — a heading on screen the gauge can sit in — rather than the view's
    /// name standing in.
    public let headed: Bool
    /// Which view of the dashboard the card is on, and that view's title.
    public let view: Int
    public let viewTitle: String

    public init(entityId: String, nameOverride: String?, header: String,
                icon: String? = nil, action: CardAction? = nil, layout: ButtonLayout? = nil,
                stack: Int? = nil, visibility: [VisibilityCondition] = [], gauge: GaugeSpec? = nil,
                headed: Bool = false, view: Int = 0, viewTitle: String = "") {
        self.entityId = entityId
        self.nameOverride = nameOverride
        self.header = header
        self.icon = icon
        self.action = action
        self.layout = layout
        self.stack = stack
        self.visibility = visibility
        self.gauge = gauge
        self.headed = headed
        self.view = view
        self.viewTitle = viewTitle
    }

    /// Every entity a visibility condition reads, for the state subscription.
    public var conditionEntityIds: Set<String> {
        visibility.reduce(into: []) { $0.formUnion($1.entityIds) }
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

    /// What the walk carries down into nested cards.
    private struct Context {
        var header: String
        var headed = false
        var layout: ButtonLayout?
        var stack: Int?
        var conditions: [VisibilityCondition] = []
    }

    public static func references(in config: JSONValue) -> [DeviceRef] {
        var found: [DeviceRef] = []
        var seen: Set<String> = []
        var layouts = 0
        var view = 0
        var viewTitle = ""

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
        func appendCard(_ fields: [String: JSONValue], _ context: Context) {
            let entity = fields["entity"]?.string
            if let action = CardAction.parse(fields["tap_action"], cardEntity: entity),
               !action.isOwnToggle(of: entity) {
                let target = action.entityIds.first ?? entity ?? "action:\(action.domain).\(action.service)"
                append(DeviceRef(entityId: target, nameOverride: fields["name"]?.string, header: context.header,
                                 icon: fields["icon"]?.string, action: action, layout: context.layout,
                                 visibility: context.conditions, headed: context.headed,
                                 view: view, viewTitle: viewTitle))
            } else if let entity {
                // Buttons are laid out in grids; other rows only share a line
                // when a horizontal stack puts them side by side.
                let pressable = buttonDomains.contains(String(entity.prefix(while: { $0 != "." })))
                let gauge = fields["type"]?.string == "gauge" ? GaugeSpec(card: .object(fields)) : nil
                append(DeviceRef(entityId: entity, nameOverride: fields["name"]?.string, header: context.header,
                                 icon: fields["icon"]?.string, layout: pressable ? context.layout : nil,
                                 stack: pressable || gauge != nil ? nil : context.stack,
                                 visibility: context.conditions, gauge: gauge, headed: context.headed,
                                 view: view, viewTitle: viewTitle))
            }
        }

        /// The header a `heading` card gives the cards after it, if any.
        func heading(_ node: JSONValue) -> String? {
            guard node["type"]?.string == "heading",
                  let text = node["heading"]?.string, !text.isEmpty else { return nil }
            if node["heading_style"]?.string == "subtitle", text.count > maximumSubtitleHeaderLength { return nil }
            return text
        }

        func walk(_ node: JSONValue, _ context: Context, depth: Int = 0) {
            guard depth < maximumDepth else { return }
            switch node {
            case .array(let elements):
                // A heading card titles the cards that follow it in the same
                // list, the way the dashboard draws it.
                var context = context
                for element in elements {
                    if let text = heading(element) {
                        context.header = text
                        context.headed = true
                    }
                    walk(element, context, depth: depth + 1)
                }

            case .object(let fields):
                var context = context
                // The view's own title (depth 0) is only the fallback header,
                // not a heading on screen.
                if depth > 0, let title = fields["title"]?.string, !title.isEmpty {
                    context.header = title
                    context.headed = true
                }
                // A card is shown only while its own conditions and those of
                // everything around it hold. A `conditional` card's
                // `conditions` govern the card inside it.
                context.conditions += VisibilityCondition.list(from: fields["visibility"])
                if fields["type"]?.string == "conditional" {
                    context.conditions += VisibilityCondition.list(from: fields["conditions"])
                }

                appendCard(fields, context)

                // A grid card (or a section, which is one) or a horizontal
                // stack starts a new layout for the cards inside it. HA's grid
                // card defaults to three columns; a stack is one row.
                if let cards = fields["cards"]?.array {
                    switch fields["type"]?.string {
                    case "grid":
                        layouts += 1
                        context.layout = ButtonLayout(id: layouts, columns: fields["columns"]?.int ?? 3)
                        context.stack = nil
                    case "horizontal-stack":
                        layouts += 1
                        context.layout = ButtonLayout(id: layouts, columns: max(cards.count, 1))
                        context.stack = layouts
                    case "vertical-stack":
                        context.stack = nil
                    default:
                        break
                    }
                }

                var rowContext = context
                rowContext.layout = nil
                rowContext.stack = nil
                for element in fields["entities"]?.array ?? [] {
                    if let entityId = element.string {
                        append(DeviceRef(entityId: entityId, nameOverride: nil, header: context.header,
                                         visibility: context.conditions, headed: context.headed,
                                         view: view, viewTitle: viewTitle))
                    } else if let row = element.object, row["entity"] != nil || row["tap_action"] != nil {
                        appendCard(row, rowContext)
                    } else {
                        walk(element, context, depth: depth + 1)   // nested group rows
                    }
                }

                for key in containerKeys {
                    if let child = fields[key] { walk(child, context, depth: depth + 1) }
                }
                for key in fields.keys.sorted()
                where !containerKeys.contains(key) && !skippedKeys.contains(key)
                    && key != "entity" && key != "entities" && key != "name" && key != "title" {
                    walk(fields[key]!, context, depth: depth + 1)
                }

            default:
                break
            }
        }

        for (index, config) in (config["views"]?.array ?? []).enumerated() {
            view = index
            viewTitle = config["title"]?.string ?? fallbackHeader
            walk(config, Context(header: viewTitle))
        }
        return found
    }
}
