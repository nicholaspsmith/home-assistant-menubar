import XCTest
@testable import HomesteadCore

final class HAURLTests: XCTestCase {
    func testHTTPBecomesWS() {
        XCTAssertEqual(HAURL.websocketURL(from: "http://homeassistant.local:8123")?.absoluteString,
                       "ws://homeassistant.local:8123/api/websocket")
    }

    func testHTTPSBecomesWSS() {
        XCTAssertEqual(HAURL.websocketURL(from: "https://ha.example.com")?.absoluteString,
                       "wss://ha.example.com/api/websocket")
    }

    func testBareHostDefaultsToHTTPAndTrailingSlashesAreIgnored() {
        XCTAssertEqual(HAURL.websocketURL(from: "homeassistant.local:8123")?.absoluteString,
                       "ws://homeassistant.local:8123/api/websocket")
        XCTAssertEqual(HAURL.websocketURL(from: "  http://ha.local:8123/  ")?.absoluteString,
                       "ws://ha.local:8123/api/websocket")
    }

    func testAlreadyWebSocketURLsPassThrough() {
        XCTAssertEqual(HAURL.websocketURL(from: "ws://ha.local:8123/api/websocket")?.absoluteString,
                       "ws://ha.local:8123/api/websocket")
    }

    func testEmptyOrHostlessInputIsRejected() {
        XCTAssertNil(HAURL.websocketURL(from: ""))
        XCTAssertNil(HAURL.websocketURL(from: "   "))
        XCTAssertNil(HAURL.websocketURL(from: "http://"))
    }
}
