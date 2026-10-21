// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class LockSelectTests: XCTestCase {
    private let lock = Device(entityId: "lock.back_door", displayName: "Lock", kind: .lock)
    private let houseMode = Device(entityId: "input_select.house_mode", displayName: "House mode",
                                      kind: .select)
    private let volume = Device(entityId: "select.speaker_volume", displayName: "Volume",
                                kind: .select)

    func testLocksAndSelectsGetTheirOwnKinds() {
        let refs = ["lock.back_door", "input_select.house_mode",
                    "select.speaker_volume"]
            .map { DeviceRef(entityId: $0, nameOverride: nil, header: "Back Door") }
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
                       ServiceCall(domain: "lock", service: "unlock", entityId: "lock.back_door",
                                   serviceData: [:]))
        XCTAssertEqual(ServiceCall.lock(lock, LockControl.action(for: EntityState(state: "unlocked"))),
                       ServiceCall(domain: "lock", service: "lock", entityId: "lock.back_door",
                                   serviceData: [:]))
        // Only a lock is locked.
        XCTAssertNil(ServiceCall.lock(volume, .lock))
    }

    func testLockAndUnlockActOnTheFirstPress() {
        // One press, one call, either way: no confirming second press.
        XCTAssertEqual(ServiceCall.lockPress(lock, state: EntityState(state: "locked")),
                       ServiceCall(domain: "lock", service: "unlock", entityId: "lock.back_door", serviceData: [:]))
        XCTAssertEqual(ServiceCall.lockPress(lock, state: EntityState(state: "unlocked")),
                       ServiceCall(domain: "lock", service: "lock", entityId: "lock.back_door", serviceData: [:]))
        XCTAssertNil(ServiceCall.lockPress(lock, state: EntityState(state: "unlocking")))
        // A lock's row is the entity, not a card button carrying a confirmation.
        let row = DeviceCatalog.build(refs: [DeviceRef(entityId: "lock.back_door", nameOverride: nil, header: "Doors")],
                                      states: [:], showSensors: false).first?.devices.first
        XCTAssertEqual(row?.kind, .lock)
        XCTAssertNil(row?.action?.confirmation)
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
        XCTAssertEqual(ServiceCall.selectOption(houseMode, "Away"),
                       ServiceCall(domain: "input_select", service: "select_option",
                                   entityId: "input_select.house_mode",
                                   serviceData: ["option": .string("Away")]))
        XCTAssertEqual(ServiceCall.selectOption(volume, "low")?.domain, "select")
        XCTAssertNil(ServiceCall.selectOption(lock, "Away"))
    }

    func testSelectOptionsComeFromTheEntity() {
        let state = EntityState(state: "Night", attributes: [
            "options": .array(["Home", "Away", "Night", "Vacation"].map { .string($0) }),
        ])
        XCTAssertEqual(SelectOptions.options(of: state), ["Home", "Away", "Night", "Vacation"])
        XCTAssertTrue(SelectOptions.canChoose(state))
        // A scene select never yet set is `unknown`, and choosing is how it stops.
        XCTAssertTrue(SelectOptions.canChoose(EntityState(state: "unknown", attributes: state.attributes)))
        XCTAssertFalse(SelectOptions.canChoose(EntityState(state: "unavailable", attributes: state.attributes)))
        XCTAssertFalse(SelectOptions.canChoose(EntityState(state: "Night")))
    }
}
