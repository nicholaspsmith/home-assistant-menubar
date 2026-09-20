// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// An error Home Assistant returned for a command.
public struct HAError: Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A frame received on the Home Assistant WebSocket API.
///
/// Unknown types decode to `.unknown` rather than throwing: HA adds frame
/// types between releases, and an unrecognised one is not a reason to tear
/// down a working connection.
public enum HAMessage: Equatable, Sendable {
    case authRequired
    case authOK
    case authInvalid(message: String)
    case result(id: Int, success: Bool, result: JSONValue?, error: HAError?)
    case event(id: Int, event: JSONValue)
    case pong(id: Int)
    case unknown(type: String)

    public enum DecodeFailure: Error, Equatable {
        case notAnObject
        case missingType
    }

    public static func decode(_ text: String) throws -> HAMessage {
        let value = try JSONValue.parse(Data(text.utf8))
        guard value.object != nil else { throw DecodeFailure.notAnObject }
        guard let type = value["type"]?.string else { throw DecodeFailure.missingType }

        switch type {
        case "auth_required":
            return .authRequired
        case "auth_ok":
            return .authOK
        case "auth_invalid":
            return .authInvalid(message: value["message"]?.string ?? "")
        case "result":
            let error = value["error"].flatMap { payload -> HAError? in
                guard let code = payload["code"]?.string else { return nil }
                return HAError(code: code, message: payload["message"]?.string ?? "")
            }
            return .result(
                id: value["id"]?.int ?? 0,
                success: value["success"]?.bool ?? false,
                result: value["result"],
                error: error
            )
        case "event":
            return .event(id: value["id"]?.int ?? 0, event: value["event"] ?? .null)
        case "pong":
            return .pong(id: value["id"]?.int ?? 0)
        default:
            return .unknown(type: type)
        }
    }
}
