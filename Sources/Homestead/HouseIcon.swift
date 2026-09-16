import AppKit
import HomesteadCore
import StatusItemKit

/// Chooses the status glyph for a snapshot: the house mascot, or the plain dot
/// if Icon ▸ Dot is selected.
enum HouseIcon {
    static func image(snapshot: Snapshot, appearance: MeterAppearance) -> NSImage {
        let configured = snapshot.connection != .unconfigured
        let reachable = snapshot.connection == .connected

        guard appearance.style == .character else {
            return MeterIcon.image(style: appearance.style,
                                   fraction: reachable ? 1 : 0,
                                   color: color(for: snapshot))
        }
        return CharacterIcon.house(
            lightsOn: snapshot.lightsOn,
            fanOn: snapshot.anyFanOn,
            reachable: reachable,
            configured: configured
        )
    }

    private static func color(for snapshot: Snapshot) -> NSColor {
        switch snapshot.connection {
        case .connected: return .systemGreen
        case .connecting: return .systemOrange
        case .unreachable, .authFailed: return .systemRed
        case .unconfigured: return .systemGray
        }
    }
}
