import XCTest
@testable import HomesteadCore

/// A scripted transport: the test queues the frames the "server" sends and
/// inspects what the client sent.
private final class FakeTransport: HATransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var sentFrames: [String] = []
    private var closed = false

    /// - Parameter initial: frames the server sends unprompted (the handshake).
    init(initial: [String] = []) { inbound = initial }

    var sent: [String] {
        lock.lock(); defer { lock.unlock() }
        return sentFrames
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// Called by the test to push a frame to the client.
    func push(_ text: String) {
        lock.lock()
        if waiters.isEmpty {
            inbound.append(text)
            lock.unlock()
        } else {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: text)
        }
    }

    func connect(to url: URL) async throws {}

    func send(_ text: String) async throws {
        lock.lock(); sentFrames.append(text); lock.unlock()
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if inbound.isEmpty {
                waiters.append(continuation)
                lock.unlock()
            } else {
                let next = inbound.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
            }
        }
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
    }
}

/// Thread-safe collector for events delivered on the client's reader task.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [JSONValue] = []

    var values: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ value: JSONValue) {
        lock.lock(); storage.append(value); lock.unlock()
    }
}

final class HAClientTests: XCTestCase {
    private let url = URL(string: "ws://ha.local:8123/api/websocket")!

    func testConnectSendsTheTokenAfterAuthRequired() async throws {
        let transport = FakeTransport(initial: [#"{"type":"auth_required"}"#, #"{"type":"auth_ok"}"#])
        let client = HAClient(transport: transport)

        try await client.connect(url: url, token: "secret-token")

        let auth = try JSONValue.parse(Data(transport.sent[0].utf8))
        XCTAssertEqual(auth["type"]?.string, "auth")
        XCTAssertEqual(auth["access_token"]?.string, "secret-token")
    }

    func testConnectThrowsOnAuthInvalid() async throws {
        let transport = FakeTransport(initial: [
            #"{"type":"auth_required"}"#,
            #"{"type":"auth_invalid","message":"Invalid access token"}"#,
        ])
        let client = HAClient(transport: transport)

        do {
            try await client.connect(url: url, token: "wrong")
            XCTFail("expected authInvalid")
        } catch {
            XCTAssertEqual(error as? HAClientError, .authInvalid("Invalid access token"))
        }
    }

    func testSendCorrelatesRepliesByIdOutOfOrder() async throws {
        let transport = FakeTransport(initial: [#"{"type":"auth_required"}"#, #"{"type":"auth_ok"}"#])
        let client = HAClient(transport: transport)
        try await client.connect(url: url, token: "t")

        async let first = client.send(["type": .string("lovelace/dashboards/list")])
        async let second = client.send(["type": .string("lovelace/config")])

        // Which command claims which id is up to whoever enters the actor
        // first, so read the ids off the wire rather than assuming them.
        try await Task.sleep(nanoseconds: 100_000_000)
        var idsByType: [String: Int] = [:]
        for frame in transport.sent.dropFirst() {   // dropFirst: the auth frame
            let parsed = try JSONValue.parse(Data(frame.utf8))
            if let type = parsed["type"]?.string, let id = parsed["id"]?.int { idsByType[type] = id }
        }
        let listId = try XCTUnwrap(idsByType["lovelace/dashboards/list"])
        let configId = try XCTUnwrap(idsByType["lovelace/config"])

        // Reply to the config command first; each caller must still get its own.
        transport.push(#"{"id":\#(configId),"type":"result","success":true,"result":{"views":[]}}"#)
        transport.push(#"{"id":\#(listId),"type":"result","success":true,"result":[{"title":"My Home"}]}"#)

        let listResult = try await first
        let configResult = try await second
        XCTAssertEqual(listResult.array?.first?["title"]?.string, "My Home")
        XCTAssertNotNil(configResult["views"])
    }

    func testFailedCommandThrowsTheServersError() async throws {
        let transport = FakeTransport(initial: [#"{"type":"auth_required"}"#, #"{"type":"auth_ok"}"#])
        let client = HAClient(transport: transport)
        try await client.connect(url: url, token: "t")

        async let reply = client.send(["type": .string("lovelace/config")])
        try await Task.sleep(nanoseconds: 100_000_000)
        transport.push(#"{"id":1,"type":"result","success":false,"error":{"code":"config_not_found","message":"no"}}"#)

        do {
            _ = try await reply
            XCTFail("expected a command error")
        } catch {
            XCTAssertEqual(error as? HAClientError, .command(HAError(code: "config_not_found", message: "no")))
        }
    }

    func testSubscriptionDeliversEveryEventForItsId() async throws {
        let transport = FakeTransport(initial: [#"{"type":"auth_required"}"#, #"{"type":"auth_ok"}"#])
        let client = HAClient(transport: transport)
        try await client.connect(url: url, token: "t")

        let received = Received()
        async let subscriptionId = client.subscribe(
            ["type": .string("subscribe_entities"), "entity_ids": .array([.string("light.desk")])],
            onEvent: { received.append($0) }
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        transport.push(#"{"id":1,"type":"result","success":true,"result":null}"#)
        _ = try await subscriptionId

        transport.push(#"{"id":1,"type":"event","event":{"a":{"light.desk":{"s":"on"}}}}"#)
        transport.push(#"{"id":1,"type":"event","event":{"c":{"light.desk":{"+":{"s":"off"}}}}}"#)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(received.values.count, 2)
        XCTAssertEqual(received.values[0]["a"]?["light.desk"]?["s"]?.string, "on")
        XCTAssertEqual(received.values[1]["c"]?["light.desk"]?["+"]?["s"]?.string, "off")
    }

    func testDisconnectClosesTheTransport() async throws {
        let transport = FakeTransport(initial: [#"{"type":"auth_required"}"#, #"{"type":"auth_ok"}"#])
        let client = HAClient(transport: transport)
        try await client.connect(url: url, token: "t")

        await client.disconnect()
        XCTAssertTrue(transport.isClosed)
    }
}
