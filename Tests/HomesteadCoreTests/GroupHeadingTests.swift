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
        let groups = [group("Home", headed: false)]
        XCTAssertEqual(GroupHeading.style(for: groups[0], in: groups), .plain)
    }

    func testLoneSectionOnALaterViewHasNoHeadingOfItsOwn() {
        // "Patio" view, one "Patio" section: the view's row is its fold.
        let groups = [group("Kitchen"), group("Patio", view: 1, viewTitle: "Patio")]
        XCTAssertEqual(GroupHeading.style(for: groups[1], in: groups), .none)
    }

    func testSeveralSectionsOnALaterViewEachFold() {
        let groups = [group("Kitchen"),
                      group("Front", view: 1, viewTitle: "Doors"), group("Back", view: 1, viewTitle: "Doors")]
        XCTAssertEqual(GroupHeading.style(for: groups[1], in: groups), .folding)
        XCTAssertEqual(GroupHeading.style(for: groups[2], in: groups), .folding)
    }

    func testLoneSectionWithAPadlockKeepsItsHeading() {
        // The padlock lives on the heading, so the heading must stay.
        let groups = [group("Kitchen"), group("Garage", view: 1, viewTitle: "Garage", lock: lock)]
        XCTAssertEqual(GroupHeading.style(for: groups[1], in: groups), .folding)
    }

    func testFoldKeyTellsSameTitlesOnDifferentViewsApart() {
        XCTAssertNotEqual(group("Patio").foldKey, group("Patio", view: 1).foldKey)
        XCTAssertEqual(group("Patio", view: 1).foldKey, group("Patio", view: 1).foldKey)
    }
}
