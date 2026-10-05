// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import HomesteadCore

/// A media player's keys — volume down / mute / up, previous / play-pause /
/// next — as a view-based row so the menu stays open while you use them, which
/// is the whole point: pausing something should not cost you the menu you were
/// in. Each key appears only when the player reports it.
final class TransportRowView: NSView {
    private var muteButton: ClosureButton?
    private var muted = false

    /// Whether a player has any key this row would show.
    static func hasControls(_ state: EntityState?) -> Bool {
        MediaCapabilities.supportsPlayPause(state) || MediaCapabilities.supportsSkip(state)
            || MediaCapabilities.supportsMute(state) || MediaCapabilities.supportsVolumeStep(state)
    }

    init(state: EntityState?, onControl: @escaping (ServiceCall.Transport) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 26))

        var volume: [NSView] = []
        if MediaCapabilities.supportsVolumeStep(state) {
            volume.append(ClosureButton(symbol: "speaker.minus.fill", label: "Volume down") { onControl(.volumeDown) })
        }
        if MediaCapabilities.supportsMute(state) {
            let mute = ClosureButton(symbol: "speaker.slash.fill", label: "Mute")
            mute.onPress = { [weak self] in
                guard let self else { return }
                onControl(.mute(!self.muted))
            }
            muteButton = mute
            volume.append(mute)
        }
        if MediaCapabilities.supportsVolumeStep(state) {
            volume.append(ClosureButton(symbol: "speaker.plus.fill", label: "Volume up") { onControl(.volumeUp) })
        }

        var transport: [NSView] = []
        let skips = MediaCapabilities.supportsSkip(state)
        if skips { transport.append(ClosureButton(symbol: "backward.end.fill", label: "Previous") { onControl(.previous) }) }
        if MediaCapabilities.supportsPlayPause(state) {
            transport.append(ClosureButton(symbol: "playpause.fill", label: "Play/Pause") { onControl(.playPause) })
        }
        if skips { transport.append(ClosureButton(symbol: "forward.end.fill", label: "Next") { onControl(.next) }) }

        // Volume on the left, transport on the right; either alone is centred.
        let groups = [volume, transport].filter { !$0.isEmpty }.map { views -> NSStackView in
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 16
            return stack
        }
        let row = NSStackView(views: groups)
        row.orientation = .horizontal
        row.spacing = 36
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(state: state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: EntityState?) {
        muted = MediaCapabilities.isMuted(state)
        // The key shows what pressing it does, like the Touch Bar's did.
        muteButton?.image = NSImage(systemSymbolName: muted ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                    accessibilityDescription: muted ? "Unmute" : "Mute")
        muteButton?.toolTip = muted ? "Unmute" : "Mute"
    }
}
