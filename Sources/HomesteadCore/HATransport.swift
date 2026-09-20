// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// The byte pipe under `HAClient`. Injected so the protocol logic can be
/// tested against scripted frames instead of a live Home Assistant.
public protocol HATransport: AnyObject, Sendable {
    func connect(to url: URL) async throws
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

public final class URLSessionTransport: HATransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private var current: URLSessionWebSocketTask? {
        lock.lock(); defer { lock.unlock() }
        return task
    }

    public func connect(to url: URL) async throws {
        let task = session.webSocketTask(with: url)
        lock.lock(); self.task = task; lock.unlock()
        task.resume()
    }

    public func send(_ text: String) async throws {
        guard let task = current else { throw HAClientError.notConnected }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        guard let task = current else { throw HAClientError.notConnected }
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func close() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
    }
}
