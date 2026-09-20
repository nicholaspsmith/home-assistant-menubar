// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// What a particular media player can do, read from `supported_features`.
///
/// The spread here is wide — a TV, a receiver and a speaker share a domain and
/// almost nothing else — so every control is offered only when the entity says
/// it exists. Asking a TV to skip tracks is not a harmless no-op; it is a
/// button that does nothing.
public enum MediaCapabilities {
    /// `MediaPlayerEntityFeature`, the bits this app uses.
    private static let pause = 1
    private static let volumeSet = 4
    private static let previousTrack = 16
    private static let nextTrack = 32
    private static let play = 16384

    private static func features(_ state: EntityState?) -> Int {
        state?.attributes["supported_features"]?.int ?? 0
    }

    public static func supportsVolume(_ state: EntityState?) -> Bool {
        features(state) & volumeSet != 0
    }

    public static func supportsPlayPause(_ state: EntityState?) -> Bool {
        features(state) & (pause | play) != 0
    }

    public static func supportsSkip(_ state: EntityState?) -> Bool {
        features(state) & (previousTrack | nextTrack) != 0
    }

    /// The player's current volume, 0…1.
    public static func volume(of state: EntityState?) -> Double? {
        state?.attributes["volume_level"]?.double
    }

    /// What the row says: what is playing, or what it is showing, or its state.
    public static func text(state: EntityState?) -> String {
        guard let state else { return "" }
        let what = state.attributes["media_title"]?.string ?? state.attributes["source"]?.string
        switch state.state {
        case "playing": return what ?? "Playing"
        case "paused": return what.map { "Paused · \($0)" } ?? "Paused"
        case "buffering": return what.map { "Buffering · \($0)" } ?? "Buffering"
        default:
            guard let what, state.isOn else {
                return state.state.prefix(1).uppercased() + state.state.dropFirst()
            }
            return what
        }
    }
}
