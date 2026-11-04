// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class GroupHeadingTests: XCTestCase {
    private let light = Device(entityId: "light.a", displayName: "A", kind: .light)
    private let lock = Device(entityId: "lock.door", displayName: "Door", kind: .lock)

    private func group(_ title: String, view: Int = 0, viewTitle: String = "Home", headed: Bool = true,
                       lock: Device? = nil) -> DeviceGroup {
        DeviceGroup(title: title, devices: [light], headingLock: lock, headed: headed, view: view, viewTitle: viewTitle)
    }

    func testSectionsOnTheFirstViewFold() {
        let groups = [group("Kitchen"), group("Living Room"), group("Hall")]
        for g in groups {
            XCTAssertEqual(GroupHeading.style(for: g, in: groups), .folding, g.title)
        }
    }

    func testViewNameStandingInIsAPlainHeading() {
        // Cards before the first heading sit under the view's name, in grey.
        let groups = [group("Home", headed: false), group("Kitchen")]
        XCTAssertEqual(GroupHeading.style(for: groups[0], in: groups), .plain)
        XCTAssertEqual(GroupHeading.style(for: groups[1], in: groups), .folding)
    }

    func testADashboardWithNoSectionsHasNoHeading() {
        let groups = [group("Home", headed: false)]
        XCTAssertEqual(GroupHeading.style(for: groups[0], in: groups), .none)
    }

    func testLoneSectionOnALaterViewHasNoHeadingOfItsOwn() {
        // "Patio" view, one "Patio" section: the view's row is its fold.
        let groups = [group("Kitchen"), group("Patio", view: 1, viewTitle: "Patio")]
        XCTAssertEqual(GroupHeading.style(for: groups[1], in: groups), .none)
    }

    func testTheOnlySectionOfADashboardDoesNotFold() {
        // A "Thermostat" dashboard with one "Thermostat" section: its rows
        // show straight away, under the dashboard's name.
        let groups = [group("Thermostat", viewTitle: "Thermostat")]
        XCTAssertEqual(GroupHeading.style(for: groups[0], in: groups), .none)
    }

    func testTheOnlySectionOfTheFirstViewDoesNotFoldWhenLaterViewsExist() {
        let groups = [group("Hot Tub"), group("Pump", view: 1, viewTitle: "Pump"), group("Heater", view: 1, viewTitle: "Pump")]
        XCTAssertEqual(GroupHeading.style(for: groups[0], in: groups), .none)
    }

    func testSeveralSectionsOnALaterViewEachFold() {
        let groups = [group("Kitchen"),
                      group("Front", view: 1, viewTitle: "Doors"), group("Back", view: 1, viewTitle: "Doors")]
        XCTAssertEqual(GroupHeading.style(for: groups[1], in: groups), .folding)
        XCTAssertEqual(GroupHeading.style(for: groups[2], in: groups), .folding)
    }

    func testLoneSectionWithAPadlockKeepsAPlainHeading() {
        // The padlock lives on the heading, so the heading stays — but it
        // does not fold, since there is nothing else to pick from.
        let groups = [group("Kitchen"), group("Garage", view: 1, viewTitle: "Garage", lock: lock)]
        XCTAssertEqual(GroupHeading.style(for: groups[1], in: groups), .plain)
        let alone = [group("Garage", viewTitle: "Garage", lock: lock)]
        XCTAssertEqual(GroupHeading.style(for: alone[0], in: alone), .plain)
    }

    func testFoldKeyTellsSameTitlesOnDifferentViewsApart() {
        XCTAssertNotEqual(group("Patio").foldKey, group("Patio", view: 1).foldKey)
        XCTAssertEqual(group("Patio", view: 1).foldKey, group("Patio", view: 1).foldKey)
    }
}
