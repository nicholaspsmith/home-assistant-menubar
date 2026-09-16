import AppKit
import HomesteadCore

/// URL + token, with a Test button that runs the real auth handshake — the
/// only way to tell a wrong token from an unreachable server before saving.
@MainActor
final class ConnectionWindowController: NSWindowController, NSWindowDelegate {
    private let settings: Settings
    private let onSaved: () -> Void

    private let urlField = NSTextField(string: "")
    private let tokenField = NSSecureTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(settings: Settings, onSaved: @escaping () -> Void) {
        self.settings = settings
        self.onSaved = onSaved

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
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
        tokenField.stringValue = Keychain.token() ?? ""
        statusLabel.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let urlLabel = NSTextField(labelWithString: "Server URL")
        let tokenLabel = NSTextField(labelWithString: "Access Token")
        urlField.placeholderString = "http://homeassistant.local:8123"
        tokenField.placeholderString = "Long-lived access token"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let hint = NSTextField(wrappingLabelWithString:
            "Home Assistant ▸ your profile ▸ Security ▸ Long-lived access tokens ▸ Create token.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        testButton.target = self
        testButton.action = #selector(test)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"

        for view in [urlLabel, urlField, tokenLabel, tokenField, hint, statusLabel, testButton, saveButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            urlLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            urlLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            urlLabel.widthAnchor.constraint(equalToConstant: 100),
            urlField.leadingAnchor.constraint(equalTo: urlLabel.trailingAnchor, constant: 10),
            urlField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            urlField.centerYAnchor.constraint(equalTo: urlLabel.centerYAnchor),

            tokenLabel.leadingAnchor.constraint(equalTo: urlLabel.leadingAnchor),
            tokenLabel.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 14),
            tokenLabel.widthAnchor.constraint(equalTo: urlLabel.widthAnchor),
            tokenField.leadingAnchor.constraint(equalTo: urlField.leadingAnchor),
            tokenField.trailingAnchor.constraint(equalTo: urlField.trailingAnchor),
            tokenField.centerYAnchor.constraint(equalTo: tokenLabel.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: tokenField.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: tokenField.trailingAnchor),
            hint.topAnchor.constraint(equalTo: tokenField.bottomAnchor, constant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: testButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),

            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            testButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            testButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
    }

    @objc private func test() {
        guard let url = HAURL.websocketURL(from: urlField.stringValue) else {
            return report("Enter a server URL, e.g. http://homeassistant.local:8123", ok: false)
        }
        let token = tokenField.stringValue
        guard !token.isEmpty else { return report("Paste an access token.", ok: false) }

        testButton.isEnabled = false
        report("Connecting…", ok: true)

        Task { @MainActor in
            let client = HAClient(transport: URLSessionTransport())
            do {
                try await client.connect(url: url, token: token)
                await client.disconnect()
                report("Connected.", ok: true)
            } catch HAClientError.authInvalid {
                report("Token rejected.", ok: false)
            } catch {
                report("Unreachable: \(error.localizedDescription)", ok: false)
            }
            testButton.isEnabled = true
        }
    }

    @objc private func save() {
        guard HAURL.websocketURL(from: urlField.stringValue) != nil else {
            return report("Enter a server URL, e.g. http://homeassistant.local:8123", ok: false)
        }
        settings.haURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Keychain.setToken(tokenField.stringValue)
        } catch {
            return report("Could not save the token to the Keychain.", ok: false)
        }
        onSaved()
        window?.close()
    }

    private func report(_ message: String, ok: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = ok ? .secondaryLabelColor : .systemRed
    }
}
