// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// Turns what someone types in the Connection window into the WebSocket URL.
public enum HAURL {
    public static func websocketURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty else {
            return nil
        }

        // A bare host, or an explicit http://, becomes ws:// — unencrypted.
        // That matters more here than in most clients: the long-lived token is
        // the first frame sent on the socket, so anyone on the path sees it.
        // The Connection window says so; this function does not guess for you.
        switch components.scheme {
        case "https", "wss": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        components.path = "/api/websocket"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
