// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// One of a card's `visibility` conditions (or a `conditional` card's
/// `conditions`), checked against live state so a row comes and goes the way
/// the card does on the dashboard.
///
/// Conditions this does not understand — `screen`, `user`, `location` — are
/// treated as met. A menu has no screen size or signed-in person to test them
/// against, and showing a card the dashboard might hide is the safer mistake
/// than hiding one it shows.
public indirect enum VisibilityCondition: Equatable, Sendable {
    /// `state` or `state_not`, each one value or a list.
    case state(entity: String, oneOf: [String], noneOf: [String])
    /// Strictly above and/or below a number or another entity's state.
    case numericState(entity: String, above: Bound?, below: Bound?)
    case and([VisibilityCondition])
    case or([VisibilityCondition])
    case not([VisibilityCondition])
    case unsupported

    /// A numeric threshold: a number, or the entity whose state is one.
    public enum Bound: Equatable, Sendable {
        case number(Double)
        case entity(String)
    }

    /// Reads a list of conditions. Anything that is not a list reads as none.
    public static func list(from json: JSONValue?) -> [VisibilityCondition] {
        (json?.array ?? []).map(parse)
    }

    static func parse(_ json: JSONValue) -> VisibilityCondition {
        let entity = json["entity"]?.string
        // A `conditional` card's older form has no `condition` key: an entity
        // with `state` or `state_not` is a state condition.
        let kind = json["condition"]?.string ?? (entity != nil ? "state" : "")
        switch kind {
        case "state":
            guard let entity, json["state"] != nil || json["state_not"] != nil else { return .unsupported }
            return .state(entity: entity, oneOf: strings(json["state"]), noneOf: strings(json["state_not"]))
        case "numeric_state":
            guard let entity else { return .unsupported }
            return .numericState(entity: entity, above: bound(json["above"]), below: bound(json["below"]))
        case "and": return .and(list(from: json["conditions"]))
        case "or": return .or(list(from: json["conditions"]))
        case "not": return .not(list(from: json["conditions"]))
        default: return .unsupported
        }
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        switch value {
        case .array(let values)?: return values.compactMap { ScriptField.text(of: $0) }
        case let value?: return ScriptField.text(of: value).map { [$0] } ?? []
        case nil: return []
        }
    }

    private static func bound(_ value: JSONValue?) -> Bound? {
        switch value {
        case .number(let number)?: return .number(number)
        case .string(let text)?:
            if let number = Double(text) { return .number(number) }
            return text.contains(".") ? .entity(text) : nil
        default: return nil
        }
    }

    /// Whether the condition holds. An entity Home Assistant has not
    /// reported counts as `unavailable`, as the dashboard treats it.
    public func isMet(_ state: (String) -> EntityState?) -> Bool {
        switch self {
        case .state(let entity, let oneOf, let noneOf):
            let current = state(entity)?.state ?? "unavailable"
            if !oneOf.isEmpty, !oneOf.contains(current) { return false }
            return !noneOf.contains(current)
        case .numericState(let entity, let above, let below):
            guard let value = state(entity).flatMap({ Double($0.state) }) else { return false }
            func number(_ bound: Bound) -> Double? {
                switch bound {
                case .number(let number): return number
                case .entity(let id): return state(id).flatMap { Double($0.state) }
                }
            }
            if let above, let limit = number(above), !(value > limit) { return false }
            if let below, let limit = number(below), !(value < limit) { return false }
            return true
        case .and(let conditions): return Self.allMet(conditions, state)
        case .or(let conditions): return conditions.isEmpty || conditions.contains { $0.isMet(state) }
        case .not(let conditions): return !Self.allMet(conditions, state)
        case .unsupported: return true
        }
    }

    /// Every condition holds; no conditions is always shown.
    public static func allMet(_ conditions: [VisibilityCondition], _ state: (String) -> EntityState?) -> Bool {
        conditions.allSatisfy { $0.isMet(state) }
    }

    /// The entities whose state can change the answer, so the menu knows
    /// which updates to re-check a row on.
    public var entityIds: Set<String> {
        switch self {
        case .state(let entity, _, _): return [entity]
        case .numericState(let entity, let above, let below):
            var ids: Set<String> = [entity]
            for case .entity(let id)? in [above, below] { ids.insert(id) }
            return ids
        case .and(let conditions), .or(let conditions), .not(let conditions):
            return conditions.reduce(into: []) { $0.formUnion($1.entityIds) }
        case .unsupported: return []
        }
    }
}
