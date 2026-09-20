// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// A parsed JSON tree. Home Assistant's dashboard configs and entity
/// attributes are free-form, so the whole payload is modelled rather than
/// typed per card: the parser walks structure, not schemas.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var string: String? { if case .string(let v) = self { return v } else { return nil } }
    public var double: Double? { if case .number(let v) = self { return v } else { return nil } }
    public var bool: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { return v } else { return nil } }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v } else { return nil } }

    /// Whole numbers only — a fractional value is not an int, so callers do not
    /// silently truncate an attribute like `percentage_step: 33.3`.
    public var int: Int? {
        guard let double, double == double.rounded(), double.magnitude < Double(Int.max) else { return nil }
        return Int(double)
    }

    public subscript(key: String) -> JSONValue? { object?[key] }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encodedData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
