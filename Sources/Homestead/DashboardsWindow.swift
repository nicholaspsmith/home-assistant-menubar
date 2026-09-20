// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore

/// Ticks which dashboards the picker offers, and in what order. Home Assistant
/// happily holds dozens; a menu is not the place to scroll through all of them,
/// and which few matter — and which comes first — is a question only the person
/// using it can answer.
///
/// A table rather than a stack of checkboxes, because rows have to be
/// draggable. Changes apply as they are made: there is nothing here worth a
/// Save button, and a cancelled dialog would only raise the question of what
/// "cancel" undoes.
@MainActor
final class DashboardsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// The drag payload is the row index; the list is small and never reordered
    /// from outside this window, so there is nothing to gain from an identifier.
    private static let rowType = NSPasteboard.PasteboardType("com.nicholaspsmith.Homestead.dashboardRow")

    private let settings: Settings
    private let onChange: () -> Void
    private let table = NSTableView()
    private var dashboards: [DashboardListing] = []

    init(settings: Settings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dashboards"
        window.minSize = NSSize(width: 300, height: 240)
        super.init(window: window)
        window.center()
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(dashboards all: [DashboardListing]) {
        dashboards = settings.ordered(all)
        table.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let caption = NSTextField(wrappingLabelWithString:
            "Tick the dashboards to show in the menu, and drag to reorder them. "
            + "With none ticked, all of them are shown.")
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dashboard"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.style = .inset
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType])
        table.draggingDestinationFeedbackStyle = .gap

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table

        for view in [caption, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            // Nothing inside has an intrinsic width, so the window needs a size
            // of its own to keep. minSize only limits dragging, not layout.
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
    }

    // MARK: - Rows

    func numberOfRows(in tableView: NSTableView) -> Int { dashboards.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let dashboard = dashboards[row]
        let box = NSButton(checkboxWithTitle: dashboard.title, target: self, action: #selector(toggled(_:)))
        box.state = settings.visibleDashboardPaths.contains(dashboard.urlPath ?? "") ? .on : .off
        box.tag = row
        box.lineBreakMode = .byTruncatingTail
        return box
    }

    @objc private func toggled(_ sender: NSButton) {
        guard dashboards.indices.contains(sender.tag) else { return }
        let path = dashboards[sender.tag].urlPath ?? ""
        var chosen = settings.visibleDashboardPaths
        if sender.state == .on {
            if !chosen.contains(path) { chosen.append(path) }
        } else {
            chosen.removeAll { $0 == path }
        }
        settings.visibleDashboardPaths = chosen
        onChange()
    }

    // MARK: - Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Only between rows: dropping *on* a row would mean nesting, which this
        // list has no concept of.
        dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let from = Int(text), dashboards.indices.contains(from)
        else { return false }

        let moved = dashboards.remove(at: from)
        // Removing the row first shifts every later index down by one.
        let destination = from < row ? row - 1 : row
        dashboards.insert(moved, at: min(max(destination, 0), dashboards.count))

        settings.dashboardOrder = dashboards.map { $0.urlPath ?? "" }
        table.reloadData()
        onChange()
        return true
    }
}
