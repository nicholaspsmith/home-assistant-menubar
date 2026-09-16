import XCTest
@testable import HomesteadCore

final class HAMessageTests: XCTestCase {
    func testDecodesAuthHandshakeFrames() throws {
        XCTAssertEqual(try HAMessage.decode(#"{"type":"auth_required","ha_version":"2026.9.1"}"#), .authRequired)
        XCTAssertEqual(try HAMessage.decode(#"{"type":"auth_ok","ha_version":"2026.9.1"}"#), .authOK)
        XCTAssertEqual(
            try HAMessage.decode(#"{"type":"auth_invalid","message":"Invalid access token"}"#),
            .authInvalid(message: "Invalid access token")
        )
    }

    func testDecodesSuccessfulResult() throws {
        let frame = #"{"id":3,"type":"result","success":true,"result":[{"title":"My Home"}]}"#
        guard case .result(let id, let success, let result, let error) = try HAMessage.decode(frame) else {
            return XCTFail("expected a result frame")
        }
        XCTAssertEqual(id, 3)
        XCTAssertTrue(success)
        XCTAssertNil(error)
        XCTAssertEqual(result?.array?.first?["title"]?.string, "My Home")
    }

    func testDecodesErrorResult() throws {
        let frame = #"{"id":4,"type":"result","success":false,"error":{"code":"config_not_found","message":"nope"}}"#
        guard case .result(_, let success, _, let error) = try HAMessage.decode(frame) else {
            return XCTFail("expected a result frame")
        }
        XCTAssertFalse(success)
        XCTAssertEqual(error, HAError(code: "config_not_found", message: "nope"))
    }

    func testDecodesResultWithNullPayload() throws {
        // call_service replies carry `"result": null`; that must not read as an error.
        guard case .result(_, let success, let result, _) = try HAMessage.decode(#"{"id":9,"type":"result","success":true,"result":null}"#) else {
            return XCTFail("expected a result frame")
        }
        XCTAssertTrue(success)
        XCTAssertEqual(result, .null)
    }

    func testDecodesEvent() throws {
        let frame = #"{"id":5,"type":"event","event":{"a":{"light.desk":{"s":"on"}}}}"#
        guard case .event(let id, let event) = try HAMessage.decode(frame) else {
            return XCTFail("expected an event frame")
        }
        XCTAssertEqual(id, 5)
        XCTAssertEqual(event["a"]?["light.desk"]?["s"]?.string, "on")
    }

    func testUnknownTypeIsReportedNotThrown() throws {
        XCTAssertEqual(try HAMessage.decode(#"{"type":"pong","id":2}"#), .pong(id: 2))
        XCTAssertEqual(try HAMessage.decode(#"{"type":"future_thing"}"#), .unknown(type: "future_thing"))
    }

    func testMalformedFrameThrows() {
        XCTAssertThrowsError(try HAMessage.decode("not json"))
    }
}
