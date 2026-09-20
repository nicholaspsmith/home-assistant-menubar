// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class MediaPlayerTests: XCTestCase {
    private let tv = Device(entityId: "media_player.smart_tv_pro", displayName: "Studio TV", kind: .mediaPlayer)
    private let remote = Device(entityId: "remote.smart_tv_pro", displayName: "TV Remote", kind: .toggle)

    /// PAUSE 1 · VOLUME_SET 4 · PREVIOUS 16 · NEXT 32 · TURN_ON 128 · TURN_OFF 256 · PLAY 16384
    private func player(_ state: String, features: Int, volume: Double? = nil,
                        title: String? = nil, source: String? = nil) -> EntityState {
        var attributes: [String: JSONValue] = ["supported_features": .number(Double(features))]
        if let volume { attributes["volume_level"] = .number(volume) }
        if let title { attributes["media_title"] = .string(title) }
        if let source { attributes["source"] = .string(source) }
        return EntityState(state: state, attributes: attributes)
    }

    // MARK: - Kinds

    func testMediaPlayersAndRemotesBecomeRows() {
        let refs = [
            DeviceRef(entityId: "media_player.smart_tv_pro", nameOverride: nil, header: "Studio TV"),
            DeviceRef(entityId: "remote.smart_tv_pro", nameOverride: nil, header: "Studio TV"),
        ]
        let devices = DeviceCatalog.build(refs: refs, states: [:], showSensors: false).flatMap(\.devices)
        XCTAssertEqual(devices.map(\.kind), [.mediaPlayer, .toggle])
    }

    func testPlayingAndPausedCountAsOnStandbyDoesNot() {
        XCTAssertTrue(player("playing", features: 0).isOn)
        XCTAssertTrue(player("paused", features: 0).isOn)
        XCTAssertTrue(player("idle", features: 0).isOn)
        XCTAssertFalse(player("standby", features: 0).isOn)
        XCTAssertFalse(player("off", features: 0).isOn)
    }

    // MARK: - Capabilities

    func testCapabilitiesComeFromSupportedFeatures() {
        let full = player("playing", features: 1 | 4 | 16 | 32 | 128 | 256 | 16384)
        XCTAssertTrue(MediaCapabilities.supportsVolume(full))
        XCTAssertTrue(MediaCapabilities.supportsPlayPause(full))
        XCTAssertTrue(MediaCapabilities.supportsSkip(full))

        let dumbSpeaker = player("playing", features: 4)
        XCTAssertTrue(MediaCapabilities.supportsVolume(dumbSpeaker))
        XCTAssertFalse(MediaCapabilities.supportsPlayPause(dumbSpeaker))
        XCTAssertFalse(MediaCapabilities.supportsSkip(dumbSpeaker))

        XCTAssertFalse(MediaCapabilities.supportsVolume(nil))
    }

    func testVolumeFractionIsTheReportedLevel() {
        XCTAssertEqual(MediaCapabilities.volume(of: player("playing", features: 4, volume: 0.35)), 0.35)
        XCTAssertNil(MediaCapabilities.volume(of: player("playing", features: 4)))
    }

    // MARK: - Text

    func testRowTextPrefersWhatIsPlaying() {
        XCTAssertEqual(MediaCapabilities.text(state: player("playing", features: 0, title: "Vertigo")), "Vertigo")
        XCTAssertEqual(MediaCapabilities.text(state: player("paused", features: 0, title: "Vertigo")), "Paused · Vertigo")
        XCTAssertEqual(MediaCapabilities.text(state: player("playing", features: 0, source: "HDMI 1")), "HDMI 1")
        XCTAssertEqual(MediaCapabilities.text(state: player("on", features: 0)), "On")
        XCTAssertEqual(MediaCapabilities.text(state: player("standby", features: 0)), "Standby")
        XCTAssertEqual(MediaCapabilities.text(state: nil), "")
    }

    // MARK: - Calls

    func testPowerUsesTheMediaPlayerDomain() {
        XCTAssertEqual(ServiceCall.toggle(tv, on: true),
                       ServiceCall(domain: "media_player", service: "turn_on",
                                   entityId: "media_player.smart_tv_pro", serviceData: [:]))
        XCTAssertEqual(ServiceCall.toggle(remote, on: false),
                       ServiceCall(domain: "remote", service: "turn_off",
                                   entityId: "remote.smart_tv_pro", serviceData: [:]))
    }

    func testVolumeIsSetAsAFraction() {
        XCTAssertEqual(ServiceCall.setLevel(tv, fraction: 0.4, state: nil),
                       ServiceCall(domain: "media_player", service: "volume_set",
                                   entityId: "media_player.smart_tv_pro",
                                   serviceData: ["volume_level": .number(0.4)]))
    }

    func testTransportCallsMatchHomeAssistantsServices() {
        XCTAssertEqual(ServiceCall.transport(tv, .playPause)?.service, "media_play_pause")
        XCTAssertEqual(ServiceCall.transport(tv, .previous)?.service, "media_previous_track")
        XCTAssertEqual(ServiceCall.transport(tv, .next)?.service, "media_next_track")
        XCTAssertEqual(ServiceCall.transport(tv, .playPause)?.domain, "media_player")
        XCTAssertNil(ServiceCall.transport(remote, .playPause))
    }
}
