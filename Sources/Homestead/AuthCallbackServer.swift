// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation
import HomesteadCore
import Network

/// Waits on 127.0.0.1 for the browser to come back from Home Assistant's
/// sign-in page with a code. Loopback only: nothing else on the network can
/// reach it, and it stops as soon as one callback arrives.
@MainActor
final class AuthCallbackServer {
    enum Failure: LocalizedError {
        case portBusy
        case timedOut

        var errorDescription: String? {
            switch self {
            case .portBusy: return "Port \(HAAuth.callbackPort) is in use — quit whatever holds it and try again."
            case .timedOut: return "Sign-in timed out."
            }
        }
    }

    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?

    /// Starts listening, calls `ready` once the port is bound (open the browser
    /// then, not before), and returns the code.
    func waitForCode(state: String, ready: @escaping () -> Void, timeoutSeconds: Double = 300) async throws -> String {
        cancel()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                     port: NWEndpoint.Port(rawValue: HAAuth.callbackPort)!)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.portBusy
        }
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: ready()
                    case .failed: self?.finish(.failure(Failure.portBusy))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handle(connection, state: state) }
            }
            listener.start(queue: .main)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(Failure.timedOut))
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func handle(_ connection: NWConnection, state: String) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                // "GET /auth/callback?code=…&state=… HTTP/1.1" — only the target matters.
                let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .split(separator: "\r\n", maxSplits: 1).first ?? ""
                let parts = requestLine.split(separator: " ")
                let target = parts.count >= 2 ? String(parts[1]) : ""

                guard let result = HAAuth.callbackCode(requestTarget: target, expectedState: state) else {
                    return Self.respond(connection, status: "404 Not Found", body: "")
                }
                switch result {
                case .success:
                    Self.respond(connection, status: "200 OK",
                                 body: Self.page("Signed in", "Homestead is connected to Home Assistant. You can close this tab."))
                case .failure(let error) where !error.endsSignIn:
                    // A tab from an earlier attempt: turn it away, keep waiting for this one.
                    return Self.respond(connection, status: "400 Bad Request",
                                        body: Self.page("Out of date", "This login page belongs to an earlier "
                                                        + "sign-in. Use the newest Home Assistant tab, or press "
                                                        + "Reopen Login Page in Homestead."))
                case .failure:
                    Self.respond(connection, status: "400 Bad Request",
                                 body: Self.page("Sign-in failed", "Go back to Homestead and try again."))
                }
                self.finish(result.mapError { $0 as Error })
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(_ title: String, _ message: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <body style="font:16px -apple-system,sans-serif;display:grid;place-items:center;height:90vh;color-scheme:light dark">
        <div style="text-align:center"><h2>\(title)</h2><p>\(message)</p></div>
        """
    }
}
