// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class LockSelectTests: XCTestCase {
    private let lock = Device(entityId: "lock.front_door_deadbolt", displayName: "Lock", kind: .lock)
    private let autoLockTime = Device(entityId: "input_select.front_door_auto_lock_time", displayName: "Lock after",
                                      kind: .select)
    private let volume = Device(entityId: "select.front_door_deadbolt_sound_volume", displayName: "Volume",
                                kind: .select)

    func testLocksAndSelectsGetTheirOwnKinds() {
        let refs = ["lock.front_door_deadbolt", "input_select.front_door_auto_lock_time",
                    "select.front_door_deadbolt_sound_volume"]
            .map { DeviceRef(entityId: $0, nameOverride: nil, header: "Front Door") }
        let devices = DeviceCatalog.build(refs: refs, states: [:], showSensors: false).flatMap(\.devices)
        XCTAssertEqual(devices.map(\.kind), [.lock, .select, .select])
        // Neither is switched: a lock gets one button, a select its options.
        XCTAssertFalse(DeviceKind.lock.hasSwitch)
        XCTAssertFalse(DeviceKind.select.hasSwitch)
        XCTAssertNil(ServiceCall.toggle(devices[0], on: true))
    }

    func testLockStateIsWordedLikeHomeAssistant() {
        let words = ["locked", "unlocked", "locking", "unlocking", "jammed", "open", "opening", "unavailable"]
            .map { LockControl.text(EntityState(state: $0)) }
        XCTAssertEqual(words, ["Locked", "Unlocked", "Locking", "Unlocking", "Jammed", "Open", "Opening", "Unavailable"])
    }

    func testAPressDoesTheOppositeOfTheLocksState() {
        XCTAssertEqual(LockControl.action(for: EntityState(state: "locked")), .unlock)
        XCTAssertEqual(LockControl.action(for: EntityState(state: "locking")), .unlock)
        for state in ["unlocked", "open", "jammed", "unknown"] {
            XCTAssertEqual(LockControl.action(for: EntityState(state: state)), .lock, state)
        }

        XCTAssertEqual(ServiceCall.lock(lock, LockControl.action(for: EntityState(state: "locked"))),
                       ServiceCall(domain: "lock", service: "unlock", entityId: "lock.front_door_deadbolt",
                                   serviceData: [:]))
        XCTAssertEqual(ServiceCall.lock(lock, LockControl.action(for: EntityState(state: "unlocked"))),
                       ServiceCall(domain: "lock", service: "lock", entityId: "lock.front_door_deadbolt",
                                   serviceData: [:]))
        // Only a lock is locked.
        XCTAssertNil(ServiceCall.lock(volume, .lock))
    }

    func testOnlyUnlockAsksFirst() {
        XCTAssertTrue(LockControl.Action.unlock.needsConfirmation)
        XCTAssertFalse(LockControl.Action.lock.needsConfirmation)
        XCTAssertEqual(LockControl.Action.unlock.title, "Unlock")
        XCTAssertEqual(LockControl.Action.lock.title, "Lock")
    }

    func testTheButtonIsOffWhileTheLockMovesOrIsGone() {
        for state in ["locking", "unlocking", "opening", "unavailable"] {
            XCTAssertFalse(LockControl.isEnabled(EntityState(state: state)), state)
        }
        XCTAssertFalse(LockControl.isEnabled(nil))
        for state in ["locked", "unlocked", "jammed", "open", "unknown"] {
            XCTAssertTrue(LockControl.isEnabled(EntityState(state: state)), state)
        }
    }

    func testChoosingAnOptionCallsTheDomainsSelectOption() {
        XCTAssertEqual(ServiceCall.selectOption(autoLockTime, "5m"),
                       ServiceCall(domain: "input_select", service: "select_option",
                                   entityId: "input_select.front_door_auto_lock_time",
                                   serviceData: ["option": .string("5m")]))
        XCTAssertEqual(ServiceCall.selectOption(volume, "low")?.domain, "select")
        XCTAssertNil(ServiceCall.selectOption(lock, "5m"))
    }

    func testSelectOptionsComeFromTheEntity() {
        let state = EntityState(state: "10m", attributes: [
            "options": .array(["30s", "2m", "5m", "10m"].map { .string($0) }),
        ])
        XCTAssertEqual(SelectOptions.options(of: state), ["30s", "2m", "5m", "10m"])
        XCTAssertTrue(SelectOptions.canChoose(state))
        // A scene select never yet set is `unknown`, and choosing is how it stops.
        XCTAssertTrue(SelectOptions.canChoose(EntityState(state: "unknown", attributes: state.attributes)))
        XCTAssertFalse(SelectOptions.canChoose(EntityState(state: "unavailable", attributes: state.attributes)))
        XCTAssertFalse(SelectOptions.canChoose(EntityState(state: "10m")))
    }
}
