// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class JSONValueTests: XCTestCase {
    func testParsesNestedObject() throws {
        let json = #"{"a": {"b": [1, "two", true, null]}, "n": 3.5}"#
        let value = try JSONValue.parse(Data(json.utf8))

        XCTAssertEqual(value["n"]?.double, 3.5)
        XCTAssertEqual(value["a"]?["b"]?.array?.count, 4)
        XCTAssertEqual(value["a"]?["b"]?.array?[0].int, 1)
        XCTAssertEqual(value["a"]?["b"]?.array?[1].string, "two")
        XCTAssertEqual(value["a"]?["b"]?.array?[2].bool, true)
        XCTAssertEqual(value["a"]?["b"]?.array?[3], .null)
    }

    func testAccessorsReturnNilForWrongType() throws {
        let value = try JSONValue.parse(Data(#"{"s": "x"}"#.utf8))
        XCTAssertNil(value["s"]?.double)
        XCTAssertNil(value["s"]?.array)
        XCTAssertNil(value["missing"])
    }

    func testIntRejectsFractionalNumbers() throws {
        let value = try JSONValue.parse(Data(#"{"a": 2.5, "b": 4}"#.utf8))
        XCTAssertNil(value["a"]?.int)
        XCTAssertEqual(value["b"]?.int, 4)
    }

    func testRoundTripsThroughEncoding() throws {
        let original = JSONValue.object([
            "id": .number(7),
            "type": .string("call_service"),
            "data": .object(["brightness_pct": .number(40)]),
            "flag": .bool(false),
            "none": .null,
        ])
        let decoded = try JSONValue.parse(original.encodedData())
        XCTAssertEqual(decoded, original)
    }
}
