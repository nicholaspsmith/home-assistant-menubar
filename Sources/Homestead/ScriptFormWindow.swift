// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore

/// The Run form of a script that asks for input: one control per field, then
/// Cancel and Run. A window because a menu cannot take typing.
///
/// What is typed here can be a door code, so it lives only in the controls:
/// it is never logged, and closing the window — after a run, on Cancel, or
/// with the close button — empties the fields and lets the window go.
@MainActor
final class ScriptFormWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// The script, `add_guest` for `script.add_guest`.
    let objectId: String
    private let fields: [ScriptField]
    private let onRun: ([String: JSONValue]) async throws -> Void
    private let onClose: (ScriptFormWindowController) -> Void

    /// Each field's control, by field key.
    private var inputs: [String: NSControl] = [:]
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var running: Task<Void, Never>?
    private var closed = false

    private static let width: CGFloat = 360

    init(objectId: String, title: String, fields: [ScriptField],
         onRun: @escaping ([String: JSONValue]) async throws -> Void,
         onClose: @escaping (ScriptFormWindowController) -> Void) {
        self.objectId = objectId
        self.fields = fields
        self.onRun = onRun
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width + 40, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let first = fields.first.flatMap({ inputs[$0.key] }) { window?.makeFirstResponder(first) }
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        running?.cancel()
        running = nil
        for input in inputs.values {
            if let text = input as? NSTextField { text.stringValue = "" }
        }
        inputs.removeAll()
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        onClose(self)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let values = ScriptForm.initialValues(fields)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        for field in fields {
            stack.addArrangedSubview(row(for: field, value: values[field.key]))
        }

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        statusLabel.preferredMaxLayoutWidth = Self.width
        stack.addArrangedSubview(statusLabel)

        runButton.target = self
        runButton.action = #selector(run)
        runButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, runButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        stack.addArrangedSubview(buttons)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        for view in stack.arrangedSubviews where view !== buttons {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refresh()
    }

    /// One field: its name, the control, and its description underneath. A
    /// switch is a checkbox titled with the name instead.
    private func row(for field: ScriptField, value: ScriptFormValue?) -> NSView {
        let control: NSControl
        var label: NSTextField?
        switch field.control {
        case .boolean:
            let box = NSButton(checkboxWithTitle: field.name, target: self, action: #selector(changed))
            if case .bool(let on)? = value { box.state = on ? .on : .off }
            control = box
        case .select(let options):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            let current: String
            if case .text(let text)? = value { current = text } else { current = "" }
            // Nothing chosen yet is a choice of its own, so a required field
            // with no default has to be picked rather than defaulting to
            // whatever happens to be first.
            if !options.contains(where: { $0.value == current }) {
                let blank = NSMenuItem(title: "Choose…", action: nil, keyEquivalent: "")
                blank.representedObject = ""
                popup.menu?.addItem(blank)
            }
            for option in options {
                let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
                item.representedObject = option.value
                popup.menu?.addItem(item)
            }
            popup.selectItem(at: max(popup.indexOfItem(withRepresentedObject: current), 0))
            popup.target = self
            popup.action = #selector(changed)
            control = popup
            label = Self.nameLabel(field)
        case .text, .number:
            // A password field shows dots and keeps its text off the
            // pasteboard.
            let text = field.control == .text(secure: true) ? NSSecureTextField() : NSTextField()
            if case .text(let typed)? = value { text.stringValue = typed }
            text.placeholderString = field.placeholder
            text.delegate = self
            control = text
            label = Self.nameLabel(field)
        }
        inputs[field.key] = control

        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        if let label { group.addArrangedSubview(label) }
        group.addArrangedSubview(control)
        if !(control is NSButton) || control is NSPopUpButton {
            control.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        if let description = field.description {
            let note = NSTextField(wrappingLabelWithString: description)
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = Self.width
            group.addArrangedSubview(note)
        }
        return group
    }

    private static func nameLabel(_ field: ScriptField) -> NSTextField {
        let label = NSTextField(labelWithString: field.required ? field.name : "\(field.name) (optional)")
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        return label
    }

    // MARK: - Running

    /// What the controls hold now.
    private func values() -> [String: ScriptFormValue] {
        var values: [String: ScriptFormValue] = [:]
        for (key, control) in inputs {
            if let popup = control as? NSPopUpButton {
                values[key] = .text(popup.selectedItem?.representedObject as? String ?? "")
            } else if let box = control as? NSButton {
                values[key] = .bool(box.state == .on)
            } else if let text = control as? NSTextField {
                values[key] = .text(text.stringValue)
            }
        }
        return values
    }

    /// Run is on only once every required field is filled and every number
    /// is one, and not while a run is waiting on Home Assistant.
    private func refresh() {
        runButton.isEnabled = running == nil && ScriptForm.serviceData(fields: fields, values: values()) != nil
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    @objc private func changed() { refresh() }

    @objc private func run() {
        guard running == nil, let data = ScriptForm.serviceData(fields: fields, values: values()) else { return }
        report("Running…", error: false)
        inputs.values.forEach { $0.isEnabled = false }
        running = Task { [weak self] in
            do {
                try await self?.onRun(data)
                guard let self, !self.closed else { return }
                self.running = nil
                self.window?.close()
            } catch {
                guard let self, !self.closed else { return }
                self.running = nil
                self.inputs.values.forEach { $0.isEnabled = true }
                self.report(Self.message(for: error), error: true)
                self.refresh()
            }
        }
        refresh()
    }

    @objc private func cancel() {
        window?.close()
    }

    private func report(_ message: String, error: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = message.isEmpty
    }

    private static func message(for error: Error) -> String {
        switch error as? HAClientError {
        case .command(let failure)?:
            return failure.message.isEmpty ? "Home Assistant refused it (\(failure.code))." : failure.message
        case .notConnected?, .closed?:
            return "Not connected to Home Assistant."
        default:
            return error.localizedDescription
        }
    }
}
