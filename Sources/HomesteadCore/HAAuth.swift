// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

public enum HAAuthError: Error, Equatable {
    /// The callback's `state` is not the one this sign-in sent: another page
    /// (or a stale tab) hit the callback, so its code must not be trusted.
    case stateMismatch
    /// The browser came back without a code — the user cancelled, or HA said no.
    case denied(String)
    /// HA refused the code or the refresh token (revoked, expired, wrong app).
    case rejected
    case badResponse

    /// Whether a callback carrying this error answers the sign-in that is
    /// waiting. A mismatched `state` belongs to some other attempt (a tab left
    /// open from an earlier try), so the waiting one keeps waiting.
    public var endsSignIn: Bool { self != .stateMismatch }
}

/// Home Assistant's own sign-in: the browser logs in on HA's page and hands a
/// one-time code back to Homestead, which trades it for a 30-minute access
/// token and a refresh token that lasts until it is revoked.
///
/// HA names an app by a URL — its client_id — and redirects only to that same
/// host unless it can fetch a page from the client_id declaring others. A
/// loopback client_id needs nothing hosted anywhere. The refresh token is bound
/// to the client_id, so the port is fixed rather than picked per sign-in: a
/// different port would be a different app, and every refresh would fail.
public enum HAAuth {
    public static let callbackPort: UInt16 = 47815
    public static let clientID = "http://127.0.0.1:47815/"
    public static let callbackPath = "/auth/callback"
    public static let redirectURI = "http://127.0.0.1:47815/auth/callback"

    /// The http(s) root of the server, from whatever the user typed.
    public static func baseURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty
        else { return nil }
        switch components.scheme {
        case "https", "wss": components.scheme = "https"
        case "http", "ws": components.scheme = "http"
        default: return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func authorizeURL(base: URL, state: String) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("auth/authorize"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The code from the callback's request target (`/auth/callback?code=…&state=…`).
    /// Returns nil for any other path, so a favicon request is not a failure.
    public static func callbackCode(requestTarget: String, expectedState: String) -> Result<String, HAAuthError>? {
        guard let components = URLComponents(string: requestTarget),
              components.path == callbackPath
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard value("state") == expectedState else { return .failure(.stateMismatch) }
        guard let code = value("code"), !code.isEmpty else {
            return .failure(.denied(value("error") ?? "no code"))
        }
        return .success(code)
    }

    public static func codeExchangeRequest(base: URL, code: String) -> URLRequest {
        tokenRequest(base: base, form: [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
        ])
    }

    public static func refreshRequest(base: URL, refreshToken: String) -> URLRequest {
        tokenRequest(base: base, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    /// Signing out revokes the refresh token so it stops working on the server
    /// too, not just on this Mac.
    public static func revokeRequest(base: URL, refreshToken: String) -> URLRequest {
        var request = tokenRequest(base: base, form: ["token": refreshToken])
        request.url = base.appendingPathComponent("auth/revoke")
        return request
    }

    /// Credentials from a `/auth/token` reply. A refresh reply carries no new
    /// refresh token, so the one it was made with is kept.
    public static func credentials(fromTokenResponse data: Data, now: Date,
                                   keepingRefreshToken previous: String? = nil) throws -> HACredentials {
        struct Reply: Decodable {
            let access_token: String
            let expires_in: Double?
            let refresh_token: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), !reply.access_token.isEmpty else {
            throw HAAuthError.badResponse
        }
        return HACredentials(
            accessToken: reply.access_token,
            refreshToken: reply.refresh_token ?? previous,
            expires: reply.expires_in.map { now.addingTimeInterval($0) }
        )
    }

    /// Runs a token-endpoint request. HA answers a bad code or a revoked refresh
    /// token with 400 (`invalid_grant`) — that is a sign-out, not a network error.
    public static func send(_ request: URLRequest, session: URLSession = .shared) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 400, 401, 403: throw HAAuthError.rejected
        default: throw HAAuthError.badResponse
        }
    }

    private static func tokenRequest(base: URL, form: [String: String]) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves `+` alone, which a form body reads as a space.
        let body = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        request.httpBody = Data(body.utf8)
        return request
    }
}

/// What the Keychain holds. A browser sign-in stores the access token with its
/// expiry and the refresh token; a long-lived token from an older version is
/// stored bare and still works, as an access token that never expires.
public struct HACredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expires: Date?

    public init(accessToken: String, refreshToken: String?, expires: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expires = expires
    }

    /// Refresh a minute early so a token is never sent seconds before it lapses.
    public func needsRefresh(now: Date) -> Bool {
        guard refreshToken != nil, let expires else { return false }
        return expires.timeIntervalSince(now) < 60
    }

    public static func decode(stored: String) -> HACredentials {
        if stored.hasPrefix("{"),
           let decoded = try? JSONDecoder.credentials.decode(HACredentials.self, from: Data(stored.utf8)) {
            return decoded
        }
        return HACredentials(accessToken: stored, refreshToken: nil, expires: nil)
    }

    public func encoded() -> String {
        guard refreshToken != nil || expires != nil,
              let data = try? JSONEncoder.credentials.encode(self)
        else { return accessToken }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension JSONDecoder {
    static let credentials: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

private extension JSONEncoder {
    static let credentials: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
}
