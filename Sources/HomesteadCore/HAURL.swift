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
