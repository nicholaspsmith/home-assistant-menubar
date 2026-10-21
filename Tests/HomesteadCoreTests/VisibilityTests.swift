// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class VisibilityTests: XCTestCase {
    private let states: [String: EntityState] = [
        "input_boolean.porch_light": EntityState(state: "on"),
        "input_select.house_mode": EntityState(state: "away"),
        "sensor.outdoor_temperature": EntityState(state: "18.5"),
        "input_number.comfort": EntityState(state: "20"),
    ]

    private func conditions(_ json: String) throws -> [VisibilityCondition] {
        VisibilityCondition.list(from: try JSONValue.parse(Data(json.utf8)))
    }

    private func shows(_ json: String) throws -> Bool {
        VisibilityCondition.allMet(try conditions(json)) { self.states[$0] }
    }

    func testStateMatchesOneValueOrAList() throws {
        XCTAssertTrue(try shows(#"[{"condition":"state","entity":"input_boolean.porch_light","state":"on"}]"#))
        XCTAssertFalse(try shows(#"[{"condition":"state","entity":"input_boolean.porch_light","state":"off"}]"#))
        XCTAssertTrue(try shows(#"[{"condition":"state","entity":"input_select.house_mode","state":["home","away"]}]"#))
        XCTAssertFalse(try shows(#"[{"condition":"state","entity":"input_select.house_mode","state":["home","night"]}]"#))
    }

    func testStateNotExcludesOneValueOrAList() throws {
        XCTAssertFalse(try shows(#"[{"condition":"state","entity":"input_boolean.porch_light","state_not":"on"}]"#))
        XCTAssertTrue(try shows(#"[{"condition":"state","entity":"input_select.house_mode","state_not":["home","night"]}]"#))
        XCTAssertFalse(try shows(#"[{"condition":"state","entity":"input_select.house_mode","state_not":["away"]}]"#))
    }

    func testAnUnreportedEntityCountsAsUnavailable() throws {
        XCTAssertFalse(try shows(#"[{"condition":"state","entity":"switch.missing","state":"on"}]"#))
        XCTAssertTrue(try shows(#"[{"condition":"state","entity":"switch.missing","state":"unavailable"}]"#))
    }

    func testNumericStateIsStrictlyAboveAndBelow() throws {
        let entity = #""condition":"numeric_state","entity":"sensor.outdoor_temperature""#
        XCTAssertTrue(try shows("[{\(entity),\"above\":18}]"))
        XCTAssertFalse(try shows("[{\(entity),\"above\":18.5}]"))
        XCTAssertTrue(try shows("[{\(entity),\"below\":19,\"above\":\"10\"}]"))
        XCTAssertFalse(try shows("[{\(entity),\"below\":18}]"))
        // A bound may be another entity's state.
        XCTAssertTrue(try shows("[{\(entity),\"below\":\"input_number.comfort\"}]"))
        // A state that is not a number never passes.
        XCTAssertFalse(try shows(#"[{"condition":"numeric_state","entity":"input_select.house_mode","above":0}]"#))
    }

    func testEveryConditionMustHold() throws {
        XCTAssertFalse(try shows(#"""
        [{"condition":"state","entity":"input_boolean.porch_light","state":"on"},
         {"condition":"state","entity":"input_select.house_mode","state":"home"}]
        """#))
        XCTAssertTrue(try shows(#"""
        [{"condition":"or","conditions":[{"condition":"state","entity":"input_select.house_mode","state":"home"},
                                         {"condition":"state","entity":"input_boolean.porch_light","state":"on"}]},
         {"condition":"not","conditions":[{"condition":"state","entity":"input_select.house_mode","state":"home"}]}]
        """#))
    }

    func testConditionsThatCannotBeCheckedFailOpen() throws {
        XCTAssertTrue(try shows(#"[{"condition":"screen","media_query":"(min-width: 1024px)"}]"#))
        XCTAssertTrue(try shows(#"[{"condition":"user","users":["abc"]}]"#))
        XCTAssertTrue(try shows(#"[{"condition":"state","entity":"input_boolean.porch_light"}]"#))   // nothing to compare
        XCTAssertTrue(try shows("[]"))
    }

    func testEntitiesTheConditionsReadAreListed() throws {
        let read = try conditions(#"""
        [{"condition":"numeric_state","entity":"sensor.outdoor_temperature","below":"input_number.comfort"},
         {"condition":"or","conditions":[{"condition":"state","entity":"input_boolean.porch_light","state":"on"}]}]
        """#).reduce(into: Set<String>()) { $0.formUnion($1.entityIds) }
        XCTAssertEqual(read, ["sensor.outdoor_temperature", "input_number.comfort", "input_boolean.porch_light"])
    }
}
