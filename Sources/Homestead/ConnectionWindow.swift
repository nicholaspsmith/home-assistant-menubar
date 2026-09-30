// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore
import Network

/// Server address plus "Sign In with Browser": Home Assistant's own login page
/// does the authentication and hands back tokens, so nothing is pasted here.
/// Servers that announce themselves over Bonjour fill the address list.
@MainActor
final class ConnectionWindowController: NSWindowController, NSWindowDelegate {
    private let settings: Settings
    private let onSaved: () -> Void

    private let urlField = NSComboBox()
    private let statusLabel = NSTextField(labelWithString: "")
    private let signInButton = NSButton(title: "Sign In with Browser", target: nil, action: nil)
    private let signOutButton = NSButton(title: "Sign Out", target: nil, action: nil)
    private let callbackServer = AuthCallbackServer()
    private var browser: NWBrowser?
    private var signIn: Task<Void, Never>?
    /// The login page of the sign-in that is waiting, so it can be reopened
    /// with the same `state` instead of starting over and orphaning the tab.
    private var pendingAuthorizeURL: URL?

    init(settings: Settings, onSaved: @escaping () -> Void) {
        self.settings = settings
        self.onSaved = onSaved

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Home Assistant Connection"
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        urlField.stringValue = settings.haURL ?? ""
        signOutButton.isHidden = true
        if pendingAuthorizeURL != nil {
            report("Waiting for the browser…", ok: true)
        }
        Task { @MainActor in
            let signedIn = await TokenStore.loadInBackground() != nil
            signOutButton.isHidden = !signedIn
            if pendingAuthorizeURL == nil { report(signedIn ? "Signed in." : "", ok: true) }
        }
        startBrowsing()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// A sign-in in progress outlives the window: the user is in the browser,
    /// and closing this should not turn the tab's redirect into a dead port.
    /// It ends on its own when the tab comes back or the listener times out.
    func windowWillClose(_ notification: Notification) {
        browser?.cancel()
        browser = nil
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let urlLabel = NSTextField(labelWithString: "Server")
        urlField.placeholderString = "http://homeassistant.local:8123"
        urlField.completes = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let hint = NSTextField(wrappingLabelWithString:
            "Opens Home Assistant's login page in your browser. An http:// address is "
            + "unencrypted — fine on your own LAN or over Tailscale, not over the open internet.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        signInButton.target = self
        signInButton.action = #selector(startSignIn)
        signInButton.keyEquivalent = "\r"
        signOutButton.target = self
        signOutButton.action = #selector(signOut)

        for view in [urlLabel, urlField, hint, statusLabel, signOutButton, signInButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            urlLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            urlLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            urlLabel.widthAnchor.constraint(equalToConstant: 50),
            urlField.leadingAnchor.constraint(equalTo: urlLabel.trailingAnchor, constant: 10),
            urlField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            urlField.centerYAnchor.constraint(equalTo: urlLabel.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: urlField.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: urlField.trailingAnchor),
            hint.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: signOutButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: signInButton.centerYAnchor),

            signInButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            signInButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            signOutButton.trailingAnchor.constraint(equalTo: signInButton.leadingAnchor, constant: -10),
            signOutButton.centerYAnchor.constraint(equalTo: signInButton.centerYAnchor),
        ])
    }

    // MARK: - Sign in

    @objc private func startSignIn() {
        guard let base = HAAuth.baseURL(from: urlField.stringValue) else {
            return report("Enter the server address, e.g. http://homeassistant.local:8123", ok: false)
        }
        let state = UUID().uuidString
        let authorizeURL = HAAuth.authorizeURL(base: base, state: state)
        if let pending = pendingAuthorizeURL {
            // Same server: the tab was lost or closed, so show the same page again.
            if HAAuth.baseURL(from: pending.absoluteString) == base {
                NSWorkspace.shared.open(pending)
                return
            }
            signIn?.cancel()
        }
        pendingAuthorizeURL = authorizeURL
        signInButton.title = "Reopen Login Page"
        report("Waiting for the browser…", ok: true)

        signIn = Task { @MainActor in
            // A superseded attempt (a different server) must not reset the new one.
            @MainActor func settle() {
                guard pendingAuthorizeURL == authorizeURL else { return }
                pendingAuthorizeURL = nil
                signInButton.title = "Sign In with Browser"
            }
            defer { settle() }
            do {
                let code = try await callbackServer.waitForCode(state: state) {
                    NSWorkspace.shared.open(authorizeURL)
                }
                settle()
                report("Signing in…", ok: true)
                let data = try await HAAuth.send(HAAuth.codeExchangeRequest(base: base, code: code))
                let credentials = try HAAuth.credentials(fromTokenResponse: data, now: Date())
                let encoded = credentials.encoded()
                try await Task.detached { try TokenStore.setToken(encoded) }.value
                settings.haURL = base.absoluteString
                NSApp.activate(ignoringOtherApps: true)
                onSaved()
                window?.close()
            } catch is CancellationError {
                report("", ok: true)
            } catch HAAuthError.rejected {
                report("Home Assistant refused the sign-in. Try again.", ok: false)
            } catch let error as HAAuthError {
                report("Sign-in failed (\(error)).", ok: false)
            } catch {
                report(error.localizedDescription, ok: false)
            }
        }
    }

    @objc private func signOut() {
        signOutButton.isHidden = true
        Task { @MainActor in
            let stored = await TokenStore.loadInBackground().map(HACredentials.decode(stored:))
            if let refresh = stored?.refreshToken, let base = settings.haURL.flatMap(HAAuth.baseURL(from:)) {
                // Best effort: the token is gone from this Mac either way.
                Task { _ = try? await HAAuth.send(HAAuth.revokeRequest(base: base, refreshToken: refresh)) }
            }
            await Task.detached { TokenStore.deleteToken() }.value
            report("Signed out.", ok: true)
            onSaved()
        }
    }

    // MARK: - Discovery

    /// Home Assistant's zeroconf record carries its own URLs in the TXT record.
    private func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_home-assistant._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let urls: [String] = results.compactMap { result in
                guard case .bonjour(let txt) = result.metadata else { return nil }
                return [txt["internal_url"], txt["base_url"]].compactMap { $0 }.first { !$0.isEmpty }
            }
            Task { @MainActor in self?.offer(urls) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func offer(_ urls: [String]) {
        let unique = Array(Set(urls)).sorted()
        urlField.removeAllItems()
        urlField.addItems(withObjectValues: unique)
        if urlField.stringValue.isEmpty, let first = unique.first {
            urlField.stringValue = first
        }
    }

    private func report(_ message: String, ok: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = ok ? .secondaryLabelColor : .systemRed
    }
}
