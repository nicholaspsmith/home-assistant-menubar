// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class HAAuthTests: XCTestCase {
    func testBaseURLNormalisesWhatUsersType() {
        XCTAssertEqual(HAAuth.baseURL(from: " homeassistant.local:8123 ")?.absoluteString, "http://homeassistant.local:8123")
        XCTAssertEqual(HAAuth.baseURL(from: "https://ha.example.com/lovelace/0?x=1")?.absoluteString, "https://ha.example.com")
        XCTAssertEqual(HAAuth.baseURL(from: "wss://ha.example.com/api/websocket")?.absoluteString, "https://ha.example.com")
        XCTAssertNil(HAAuth.baseURL(from: ""))
        XCTAssertNil(HAAuth.baseURL(from: "ftp://ha.example.com"))
    }

    func testAuthorizeURLCarriesTheLoopbackClient() throws {
        let url = HAAuth.authorizeURL(base: URL(string: "http://ha.local:8123")!, state: "abc")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/auth/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "http://127.0.0.1:47815/")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:47815/auth/callback")
        XCTAssertEqual(items["state"], "abc")
    }

    func testCallbackCode() {
        XCTAssertEqual(HAAuth.callbackCode(requestTarget: "/auth/callback?code=c0de&state=s", expectedState: "s"),
                       .success("c0de"))
        XCTAssertEqual(HAAuth.callbackCode(requestTarget: "/auth/callback?code=c0de&state=other", expectedState: "s"),
                       .failure(.stateMismatch))
        XCTAssertEqual(HAAuth.callbackCode(requestTarget: "/auth/callback?error=access_denied&state=s", expectedState: "s"),
                       .failure(.denied("access_denied")))
        XCTAssertNil(HAAuth.callbackCode(requestTarget: "/favicon.ico", expectedState: "s"))
    }

    /// A tab left over from an earlier attempt must not abort the one in
    /// progress; a real answer to this attempt (even a refusal) ends it.
    func testOnlyThisSignInsCallbackEndsIt() {
        XCTAssertFalse(HAAuthError.stateMismatch.endsSignIn)
        XCTAssertTrue(HAAuthError.denied("access_denied").endsSignIn)
    }

    func testTokenRequestsAreFormEncoded() throws {
        let base = URL(string: "http://ha.local:8123")!
        let exchange = HAAuth.codeExchangeRequest(base: base, code: "a+b/c")
        XCTAssertEqual(exchange.url?.absoluteString, "http://ha.local:8123/auth/token")
        XCTAssertEqual(exchange.httpMethod, "POST")
        XCTAssertEqual(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(decoding: try XCTUnwrap(exchange.httpBody), as: UTF8.self)
        XCTAssertEqual(body, "client_id=http://127.0.0.1:47815/&code=a%2Bb/c&grant_type=authorization_code")

        let refresh = String(decoding: try XCTUnwrap(HAAuth.refreshRequest(base: base, refreshToken: "r").httpBody), as: UTF8.self)
        XCTAssertTrue(refresh.contains("grant_type=refresh_token"))
        XCTAssertTrue(refresh.contains("refresh_token=r"))

        XCTAssertEqual(HAAuth.revokeRequest(base: base, refreshToken: "r").url?.absoluteString, "http://ha.local:8123/auth/revoke")
    }

    func testCredentialsFromTokenResponses() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = try HAAuth.credentials(
            fromTokenResponse: Data(#"{"access_token":"A","expires_in":1800,"refresh_token":"R","token_type":"Bearer"}"#.utf8),
            now: now)
        XCTAssertEqual(first, HACredentials(accessToken: "A", refreshToken: "R", expires: Date(timeIntervalSince1970: 2_800)))

        let refreshed = try HAAuth.credentials(
            fromTokenResponse: Data(#"{"access_token":"B","expires_in":1800,"token_type":"Bearer"}"#.utf8),
            now: now, keepingRefreshToken: "R")
        XCTAssertEqual(refreshed.refreshToken, "R")

        XCTAssertThrowsError(try HAAuth.credentials(fromTokenResponse: Data("{}".utf8), now: now))
    }

    func testStoredCredentialsRoundTripAndAcceptLegacyTokens() {
        let signedIn = HACredentials(accessToken: "A", refreshToken: "R", expires: Date(timeIntervalSince1970: 2_800))
        XCTAssertEqual(HACredentials.decode(stored: signedIn.encoded()), signedIn)

        let legacy = HACredentials.decode(stored: "eyJlong.lived.token")
        XCTAssertEqual(legacy, HACredentials(accessToken: "eyJlong.lived.token", refreshToken: nil, expires: nil))
        XCTAssertEqual(legacy.encoded(), "eyJlong.lived.token")
        XCTAssertFalse(legacy.needsRefresh(now: .distantFuture))
    }

    func testRefreshesAMinuteEarly() {
        let credentials = HACredentials(accessToken: "A", refreshToken: "R", expires: Date(timeIntervalSince1970: 1_000))
        XCTAssertFalse(credentials.needsRefresh(now: Date(timeIntervalSince1970: 900)))
        XCTAssertTrue(credentials.needsRefresh(now: Date(timeIntervalSince1970: 950)))
    }
}
