// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class ScriptFieldsTests: XCTestCase {
    /// A `get_services` reply as Home Assistant sends it, trimmed: the
    /// guest script's fields, declared name, password, area — not alphabetical.
    private let frame = #"""
    {"id":7,"type":"result","success":true,"result":{
      "light":{"turn_on":{"fields":{"brightness":{"selector":{"number":{}}}}}},
      "script":{
        "add_guest":{"name":"Add guest","fields":{
          "name":{"name":"Name","description":"Who is staying","required":true,
                  "selector":{"text":{"multiline":false,"multiple":false}}},
          "password":{"name":"Wi-Fi password","description":"Shared with the guest","required":true,
                 "selector":{"text":{"type":"password","multiline":false}}},
          "area":{"name":"Area","required":true,"default":"Everywhere",
                  "selector":{"select":{"options":["Everywhere","Kitchen","Office","Garden"]}}}
        },"response":{"optional":true}},
        "end_party":{"name":"End party","fields":{}},
        "fade":{"fields":{
          "level":{"selector":{"number":{"min":0,"max":100}},"default":40},
          "quiet":{"name":"Quiet \"mode\"","selector":{"boolean":{}},"default":true},
          "room":{"selector":{"select":{"options":[{"value":"lr","label":"Living room"},{"value":"br","label":"Bedroom"}]}}},
          "target":{"selector":{"entity":{"domain":"light"}}}
        }}
      }}}
    """#

    func testScriptsWithFieldsAreReadInDeclaredOrder() {
        let scripts = ScriptFields.parse(servicesFrame: frame)

        XCTAssertEqual(Set(scripts.keys), ["add_guest", "fade"])   // no fields, no form
        let add = scripts["add_guest"] ?? []
        XCTAssertEqual(add.map(\.key), ["name", "password", "area"])
        XCTAssertEqual(add.map(\.name), ["Name", "Wi-Fi password", "Area"])
        XCTAssertEqual(add[0].description, "Who is staying")
        XCTAssertEqual(add[0].control, .text(secure: false))
        XCTAssertEqual(add[1].control, .text(secure: true))
        XCTAssertEqual(add[2].control, .select(["Everywhere", "Kitchen", "Office", "Garden"]
            .map { ScriptField.Option(value: $0, label: $0) }))
        XCTAssertEqual(add[2].defaultValue, .string("Everywhere"))
        XCTAssertTrue(add.allSatisfy(\.required))
    }

    func testEachSelectorGetsItsControl() {
        let fade = ScriptFields.parse(servicesFrame: frame)["fade"] ?? []
        XCTAssertEqual(fade.map(\.key), ["level", "quiet", "room", "target"])
        XCTAssertEqual(fade[0].control, .number(min: 0, max: 100))
        XCTAssertEqual(fade[0].placeholder, "0–100")
        XCTAssertEqual(fade[1].control, .boolean)
        XCTAssertEqual(fade[1].name, "Quiet \"mode\"")
        XCTAssertEqual(fade[2].control, .select([ScriptField.Option(value: "lr", label: "Living room"),
                                                 ScriptField.Option(value: "br", label: "Bedroom")]))
        XCTAssertEqual(fade[3].control, .text(secure: false))   // no control of its own: plain text
        XCTAssertEqual(fade[3].name, "target")                  // no name: the key
        XCTAssertFalse(fade[3].required)
    }

    func testFieldsFallBackToAlphabeticalWithoutTheText() throws {
        let result = try XCTUnwrap(JSONValue.parse(Data(frame.utf8))["result"])
        XCTAssertEqual(ScriptFields.parse(services: result)["add_guest"]?.map(\.key), ["area", "name", "password"])
    }

    func testDefaultsPrefillTheForm() {
        let fade = ScriptFields.parse(servicesFrame: frame)["fade"] ?? []
        let values = ScriptForm.initialValues(fade)
        XCTAssertEqual(values["level"], .text("40"))
        XCTAssertEqual(values["quiet"], .bool(true))
        XCTAssertEqual(values["room"], .text(""))

        let add = ScriptFields.parse(servicesFrame: frame)["add_guest"] ?? []
        XCTAssertEqual(ScriptForm.initialValues(add), ["name": .text(""), "password": .text(""), "area": .text("Everywhere")])
    }

    func testRunWaitsForEveryRequiredField() {
        let add = ScriptFields.parse(servicesFrame: frame)["add_guest"] ?? []
        var values = ScriptForm.initialValues(add)
        XCTAssertNil(ScriptForm.serviceData(fields: add, values: values))
        values["name"] = .text("Sam")
        values["password"] = .text("   ")
        XCTAssertNil(ScriptForm.serviceData(fields: add, values: values))   // blank is empty
        values["password"] = .text("1234")
        XCTAssertEqual(ScriptForm.serviceData(fields: add, values: values),
                       ["name": .string("Sam"), "password": .string("1234"), "area": .string("Everywhere")])
    }

    func testServiceDataTypesNumbersAndSwitches() {
        let fade = ScriptFields.parse(servicesFrame: frame)["fade"] ?? []
        var values = ScriptForm.initialValues(fade)
        values["level"] = .text("75")
        values["quiet"] = .bool(false)
        values["room"] = .text("br")
        // The empty optional entity field is left out, for the script's own default.
        XCTAssertEqual(ScriptForm.serviceData(fields: fade, values: values),
                       ["level": .number(75), "quiet": .bool(false), "room": .string("br")])

        values["level"] = .text("150")
        XCTAssertNil(ScriptForm.serviceData(fields: fade, values: values))   // over max
        values["level"] = .text("lots")
        XCTAssertNil(ScriptForm.serviceData(fields: fade, values: values))   // not a number
        values["level"] = .text("")
        XCTAssertEqual(ScriptForm.serviceData(fields: fade, values: values)?["level"], nil)
    }

    func testRunningAScriptCallsItsOwnService() {
        let call = ServiceCall.runScript(objectId: "add_guest", data: ["name": .string("Sam")])
        XCTAssertEqual(call.commandPayload, [
            "type": .string("call_service"),
            "domain": .string("script"),
            "service": .string("add_guest"),
            "service_data": .object(["name": .string("Sam")]),
        ])
    }

    func testKeyOrderSurvivesEscapesAndNesting() {
        let text = #"{"result":{"script":{"a\"b":{"x":[{"fields":1}],"fields":{"zé":{"k":"}"},"y":null,"b":[1,{"c":2}]}}}}}"#
        XCTAssertEqual(JSONKeyOrder.scriptFieldOrder(inServicesFrame: text), ["a\"b": ["zé", "y", "b"]])
        XCTAssertEqual(JSONKeyOrder.scriptFieldOrder(inServicesFrame: #"{"result":{"script":{"a":{"fields":{"#), [:])
    }
}
