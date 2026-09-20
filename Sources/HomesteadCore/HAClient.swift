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
}

/// Speaks the Home Assistant WebSocket API: one auth handshake, then commands
/// correlated by id and subscriptions that keep delivering events under the id
/// they were created with.
public actor HAClient {
    private let transport: HATransport
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var subscriptions: [Int: @Sendable (JSONValue) -> Void] = [:]
    private var readerTask: Task<Void, Never>?
    private var onClose: (@Sendable (String) -> Void)?

    public init(transport: HATransport) {
        self.transport = transport
    }

    /// Called when the socket drops for any reason other than `disconnect()`.
    public func setOnClose(_ handler: @escaping @Sendable (String) -> Void) {
        onClose = handler
    }

    public func connect(url: URL, token: String) async throws {
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
        do {
            var body = payload
            body["id"] = .number(Double(id))
            let text = String(decoding: try JSONValue.object(body).encodedData(), as: UTF8.self)
            try await transport.send(text)
        } catch {
            resume(id: id, with: .failure(error))
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
                    await self.handleClose(reason: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = try? HAMessage.decode(text) else { return }
        switch message {
        case .result(let id, let success, let result, let error):
            if success {
                resume(id: id, with: .success(result ?? .null))
            } else {
                resume(id: id, with: .failure(HAClientError.command(error ?? HAError(code: "unknown", message: ""))))
            }
        case .event(let id, let event):
            subscriptions[id]?(event)
        default:
            break
        }
    }

    private func handleClose(reason: String) {
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
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }
}
