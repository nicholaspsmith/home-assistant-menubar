// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

public enum HAClientError: Error, Equatable {
    case authInvalid(String)
    case command(HAError)
    case closed
    case notConnected
    case timedOut
}

/// Speaks the Home Assistant WebSocket API: one auth handshake, then commands
/// correlated by id and subscriptions that keep delivering events under the id
/// they were created with.
///
/// A dead socket does not always say so: after a VPN takes away the local
/// address, `URLSessionWebSocketTask.receive()` can stay blocked forever while
/// writes fail. So a refused write closes the connection too, and a heartbeat
/// ping that goes unanswered closes a socket that has gone quiet.
public actor HAClient {
    private let transport: HATransport
    private let heartbeatInterval: TimeInterval
    private let pongTimeout: TimeInterval
    private let handshakeTimeout: TimeInterval
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var subscriptions: [Int: @Sendable (JSONValue) -> Void] = [:]
    /// Commands whose caller wants the reply frame as text (`sendForFrameText`).
    private var textReplies: Set<Int> = []
    private var readerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var handshakeTimedOut = false
    private var onClose: (@Sendable (String) -> Void)?

    public init(transport: HATransport,
                heartbeatInterval: TimeInterval = 30,
                pongTimeout: TimeInterval = 10,
                handshakeTimeout: TimeInterval = 15) {
        self.transport = transport
        self.heartbeatInterval = heartbeatInterval
        self.pongTimeout = pongTimeout
        self.handshakeTimeout = handshakeTimeout
    }

    /// Called when the socket drops for any reason other than `disconnect()`.
    public func setOnClose(_ handler: @escaping @Sendable (String) -> Void) {
        onClose = handler
    }

    public func connect(url: URL, token: String) async throws {
        // A server that accepts the socket and then says nothing would leave
        // the menu on Connecting… for good; closing the transport unblocks
        // the receive below.
        handshakeTimedOut = false
        let watchdog = Task { [weak self, handshakeTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(handshakeTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.timeOutHandshake()
        }
        defer { watchdog.cancel() }
        do {
            try await handshake(url: url, token: token)
        } catch where handshakeTimedOut {
            throw HAClientError.timedOut
        }
    }

    private func timeOutHandshake() {
        handshakeTimedOut = true
        transport.close()
    }

    private func handshake(url: URL, token: String) async throws {
        try await transport.connect(to: url)

        // The handshake is read inline: no reader task runs yet, so these
        // frames cannot race with command replies.
        while true {
            let message = try HAMessage.decode(try await transport.receive())
            switch message {
            case .authRequired:
                let frame = JSONValue.object([
                    "type": .string("auth"),
                    "access_token": .string(token),
                ])
                try await transport.send(String(decoding: try frame.encodedData(), as: UTF8.self))
            case .authOK:
                startReader()
                startHeartbeat()
                return
            case .authInvalid(let reason):
                transport.close()
                throw HAClientError.authInvalid(reason)
            default:
                continue
            }
        }
    }

    public func disconnect() {
        readerTask?.cancel()
        readerTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        onClose = nil
        failAllPending(with: HAClientError.closed)
        subscriptions.removeAll()
        transport.close()
    }

    /// Send a command and wait for its `result`.
    @discardableResult
    public func send(_ payload: [String: JSONValue]) async throws -> JSONValue {
        let id = claimId()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { await self.write(payload, id: id) }
        }
    }

    /// Send a command and get its whole `result` frame back as text, for a
    /// reply whose key order matters: `JSONValue` keeps objects as
    /// dictionaries, which lose it.
    public func sendForFrameText(_ payload: [String: JSONValue]) async throws -> String {
        let id = claimId()
        textReplies.insert(id)
        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            pending[id] = continuation
            Task { await self.write(payload, id: id) }
        }
        return reply.string ?? ""
    }

    /// Subscribe; `onEvent` runs for every event frame carrying this id.
    /// - Returns: the subscription id, for `unsubscribe`.
    @discardableResult
    public func subscribe(_ payload: [String: JSONValue],
                          onEvent: @escaping @Sendable (JSONValue) -> Void) async throws -> Int {
        let id = claimId()
        subscriptions[id] = onEvent
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                pending[id] = continuation
                Task { await self.write(payload, id: id) }
            }
        } catch {
            subscriptions.removeValue(forKey: id)
            throw error
        }
        return id
    }

    /// Ping Home Assistant. No pong within `timeout` (the heartbeat's own
    /// timeout by default) closes the connection and reports it through
    /// `onClose`, so the caller reconnects.
    /// - Returns: whether the pong came back.
    @discardableResult
    public func checkAlive(timeout: TimeInterval? = nil) async -> Bool {
        guard readerTask != nil else { return false }
        let id = claimId()
        let watchdog = Task { [weak self, wait = timeout ?? pongTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.drop(reason: "Home Assistant stopped answering")
        }
        defer { watchdog.cancel() }
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                pending[id] = continuation
                Task { await self.write(["type": .string("ping")], id: id) }
            }
            return true
        } catch {
            return false
        }
    }

    public func unsubscribe(_ subscriptionId: Int) async {
        subscriptions.removeValue(forKey: subscriptionId)
        _ = try? await send([
            "type": .string("unsubscribe_events"),
            "subscription": .number(Double(subscriptionId)),
        ])
    }

    // MARK: - Internals

    private func claimId() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    /// Writes the command, failing its waiter if the socket refuses it.
    private func write(_ payload: [String: JSONValue], id: Int) async {
        let text: String
        do {
            var body = payload
            body["id"] = .number(Double(id))
            text = String(decoding: try JSONValue.object(body).encodedData(), as: UTF8.self)
        } catch {
            textReplies.remove(id)
            resume(id: id, with: .failure(error))
            return
        }
        do {
            try await transport.send(text)
        } catch {
            // The socket refused the frame, so it is dead whether or not
            // receive() has noticed.
            textReplies.remove(id)
            resume(id: id, with: .failure(error))
            drop(reason: error.localizedDescription)
        }
    }

    private func startReader() {
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let text = try await self.transport.receive()
                    await self.handle(text)
                } catch {
                    await self.drop(reason: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self, heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard await self.checkAlive() else { return }
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = try? HAMessage.decode(text) else { return }
        switch message {
        case .result(let id, let success, let result, let error):
            let wantsText = textReplies.remove(id) != nil
            if success {
                resume(id: id, with: .success(wantsText ? .string(text) : result ?? .null))
            } else {
                resume(id: id, with: .failure(HAClientError.command(error ?? HAError(code: "unknown", message: ""))))
            }
        case .event(let id, let event):
            subscriptions[id]?(event)
        case .pong(let id):
            resume(id: id, with: .success(.null))
        default:
            break
        }
    }

    /// Closes a live connection once, however many paths notice it died.
    /// After `disconnect()` the reader is gone, so this does nothing.
    private func drop(reason: String) {
        guard readerTask != nil else { return }
        readerTask?.cancel()
        readerTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        transport.close()
        failAllPending(with: HAClientError.closed)
        subscriptions.removeAll()
        onClose?(reason)
    }

    private func resume(id: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failAllPending(with error: Error) {
        let waiting = pending
        pending.removeAll()
        textReplies.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }
}
