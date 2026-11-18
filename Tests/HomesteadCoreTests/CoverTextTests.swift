// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class CoverTextTests: XCTestCase {
    private func cover(_ state: String, position: Double? = nil) -> EntityState {
        EntityState(state: state, attributes: position.map { ["current_position": .number($0)] } ?? [:])
    }

    func testAShadeAtEitherEndIsJustItsState() {
        XCTAssertEqual(CoverText.text(cover("open", position: 100), positionable: true), "Open")
        XCTAssertEqual(CoverText.text(cover("closed", position: 0), positionable: true), "Closed")
    }

    func testAShadePartWayDownSaysHowFarItIsClosed() {
        // HA's 75 is three quarters open: a quarter of the way down.
        XCTAssertEqual(CoverText.text(cover("open", position: 75), positionable: true), "25% closed")
    }

    func testAShutShadeBeingDraggedOpenShowsWhereItWillStop() {
        // The slider's preview changes the position only; the state is still
        // "closed" until the shade moves.
        XCTAssertEqual(CoverText.text(cover("closed", position: 60), positionable: true), "40% closed")
    }

    func testAMovingShadeKeepsItsDirectionBesideTheBarsPercentage() {
        XCTAssertEqual(CoverText.text(cover("closing", position: 60), positionable: true), "Closing · 40%")
        XCTAssertEqual(CoverText.text(cover("opening", position: 10), positionable: true), "Opening · 90%")
    }

    func testACoverWithoutAPositionIsJustItsState() {
        XCTAssertEqual(CoverText.text(cover("open", position: 50), positionable: false), "Open")
        XCTAssertEqual(CoverText.text(cover("opening"), positionable: true), "Opening")
        XCTAssertEqual(CoverText.text(cover("unknown", position: 50), positionable: true), "Unknown")
    }
}
