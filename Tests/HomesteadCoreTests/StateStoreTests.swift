// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class StateStoreTests: XCTestCase {
    private func event(_ json: String) throws -> JSONValue {
        try JSONValue.parse(Data(json.utf8))
    }

    func testAddEventSeedsStatesAndAttributes() throws {
        var store = StateStore()
        let changed = store.apply(try event(#"""
        {"a":{"light.desk":{"s":"on","a":{"friendly_name":"Desk Lamp","brightness":128}},
              "fan.office":{"s":"off","a":{"friendly_name":"Office Fan","percentage":0}}}}
        """#))

        XCTAssertEqual(changed, ["light.desk", "fan.office"])
        XCTAssertEqual(store["light.desk"]?.state, "on")
        XCTAssertEqual(store["light.desk"]?.friendlyName, "Desk Lamp")
        XCTAssertEqual(store["light.desk"]?.attributes["brightness"]?.double, 128)
        XCTAssertTrue(store["light.desk"]?.isOn == true)
        XCTAssertFalse(store["fan.office"]?.isOn == true)
    }

    func testChangeEventUpdatesStateAndMergesAttributes() throws {
        var store = StateStore()
        _ = store.apply(try event(#"{"a":{"light.desk":{"s":"off","a":{"friendly_name":"Desk Lamp"}}}}"#))

        let changed = store.apply(try event(#"{"c":{"light.desk":{"+":{"s":"on","a":{"brightness":200}}}}}"#))

        XCTAssertEqual(changed, ["light.desk"])
        XCTAssertEqual(store["light.desk"]?.state, "on")
        XCTAssertEqual(store["light.desk"]?.friendlyName, "Desk Lamp")   // untouched attribute survives
        XCTAssertEqual(store["light.desk"]?.attributes["brightness"]?.double, 200)
    }

    func testChangeEventRemovesListedAttributes() throws {
        var store = StateStore()
        _ = store.apply(try event(#"{"a":{"light.desk":{"s":"on","a":{"brightness":200,"friendly_name":"Desk"}}}}"#))

        _ = store.apply(try event(#"{"c":{"light.desk":{"+":{"s":"off"},"-":{"a":["brightness"]}}}}"#))

        XCTAssertEqual(store["light.desk"]?.state, "off")
        XCTAssertNil(store["light.desk"]?.attributes["brightness"])
        XCTAssertEqual(store["light.desk"]?.friendlyName, "Desk")
    }

    func testRemoveEventDropsEntities() throws {
        var store = StateStore()
        _ = store.apply(try event(#"{"a":{"light.desk":{"s":"on"},"light.hall":{"s":"on"}}}"#))

        let changed = store.apply(try event(#"{"r":["light.hall"]}"#))

        XCTAssertEqual(changed, ["light.hall"])
        XCTAssertNil(store["light.hall"])
        XCTAssertNotNil(store["light.desk"])
    }

    func testChangeForUnknownEntityIsIgnored() throws {
        var store = StateStore()
        XCTAssertEqual(store.apply(try event(#"{"c":{"light.ghost":{"+":{"s":"on"}}}}"#)), [])
        XCTAssertNil(store["light.ghost"])
    }

    func testAvailabilityAndOpenCoversCountAsOn() throws {
        var store = StateStore()
        _ = store.apply(try event(#"""
        {"a":{"cover.garage":{"s":"opening"},"cover.blind":{"s":"closed"},
              "light.dead":{"s":"unavailable"},"sensor.new":{"s":"unknown"}}}
        """#))

        XCTAssertTrue(store["cover.garage"]?.isOn == true)
        XCTAssertFalse(store["cover.blind"]?.isOn == true)
        XCTAssertFalse(store["light.dead"]?.isAvailable == true)
        XCTAssertFalse(store["sensor.new"]?.isAvailable == true)
    }
}
