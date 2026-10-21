// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import HomesteadCore

final class MenuLayoutTests: XCTestCase {
    /// Two views. The first has a section per door: a heading, the lock, a
    /// battery gauge, then a toggle and a select side by side, the select
    /// shown only while the toggle is on. The second is a page of extras.
    private let config = #"""
    {"views":[
      {"title":"Doors","sections":[
        {"type":"grid","cards":[
          {"type":"heading","heading":"Back Door"},
          {"type":"tile","entity":"lock.back_door"},
          {"type":"gauge","entity":"sensor.back_door_battery","severity":{"green":60,"yellow":30,"red":10}},
          {"type":"horizontal-stack","cards":[
            {"type":"tile","entity":"input_boolean.porch_light","name":"Porch light"},
            {"type":"tile","entity":"input_select.house_mode","name":"Mode",
             "visibility":[{"condition":"state","entity":"input_boolean.porch_light","state":"on"}]}
          ]}
        ]},
        {"type":"grid","cards":[
          {"type":"gauge","entity":"sensor.shed_battery"}
        ]}
      ]},
      {"title":"Extras","cards":[
        {"type":"entities","title":"Garden","entities":["switch.sprinkler"]}
      ]}
    ]}
    """#

    private func groups() throws -> [DeviceGroup] {
        let refs = DashboardParser.references(in: try JSONValue.parse(Data(config.utf8)))
        return DeviceCatalog.build(refs: refs, states: [:], showSensors: false)
    }

    func testAGaugeUnderAHeadingSitsInTheHeading() throws {
        let doors = try XCTUnwrap(groups().first)
        XCTAssertEqual(doors.title, "Back Door")
        XCTAssertEqual(doors.headingGauge?.entityId, "sensor.back_door_battery")
        XCTAssertEqual(doors.headingGauge?.kind, .gauge)
        XCTAssertEqual(doors.headingGauge?.gauge, GaugeSpec(green: 60, yellow: 30, red: 10))
        XCTAssertFalse(doors.devices.contains { $0.kind == .gauge })
    }

    func testAGaugeWithoutAHeadingIsARowEvenWithSensorsHidden() throws {
        // The section has no heading, so its header is the view's name.
        let shed = try XCTUnwrap(groups().first { $0.devices.contains { $0.entityId == "sensor.shed_battery" } })
        XCTAssertNil(shed.headingGauge)
        XCTAssertEqual(shed.devices.map(\.kind), [.gauge])
    }

    func testPlacementDecision() {
        let gauge = GaugeSpec()
        func ref(headed: Bool, gauge: GaugeSpec?) -> DeviceRef {
            DeviceRef(entityId: "sensor.x", nameOverride: nil, header: "H", gauge: gauge, headed: headed)
        }
        XCTAssertTrue(GaugePlacement.inHeading(ref(headed: true, gauge: gauge), groupHasGauge: false))
        XCTAssertFalse(GaugePlacement.inHeading(ref(headed: true, gauge: gauge), groupHasGauge: true))
        XCTAssertFalse(GaugePlacement.inHeading(ref(headed: false, gauge: gauge), groupHasGauge: false))
        XCTAssertFalse(GaugePlacement.inHeading(ref(headed: true, gauge: nil), groupHasGauge: false))
    }

    func testAHorizontalStackOfRowsSharesALine() throws {
        let doors = try XCTUnwrap(groups().first)
        let runs = MenuLayout.runs(doors.devices)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first, .row(doors.devices[0]))
        guard case .line(let line)? = runs.last else { return XCTFail("expected a shared line") }
        XCTAssertEqual(line.map(\.entityId), ["input_boolean.porch_light", "input_select.house_mode"])
    }

    func testOnlyCompactRowsShareALineAndButtonsStillMakeGrids() {
        let stack = 7
        let toggle = Device(entityId: "switch.a", displayName: "A", kind: .toggle, stack: stack)
        let light = Device(entityId: "light.b", displayName: "B", kind: .light, stack: stack)
        let lock = Device(entityId: "lock.c", displayName: "C", kind: .lock, stack: stack)
        // A light brings sliders underneath, so it breaks the line; a lone
        // compact row left over is just a row.
        XCTAssertEqual(MenuLayout.runs([toggle, light, lock]), [.row(toggle), .row(light), .row(lock)])

        let layout = ButtonLayout(id: 1, columns: 2)
        let up = Device(entityId: "button.up", displayName: "Up", kind: .button, layout: layout)
        let down = Device(entityId: "button.down", displayName: "Down", kind: .button, layout: layout)
        XCTAssertEqual(MenuLayout.runs([up, down]), [.buttonGrid([up, down])])
        // A button that must stand alone (a script with a form) breaks the grid.
        XCTAssertEqual(MenuLayout.runs([up, down]) { $0.entityId == "button.down" }, [.row(up), .row(down)])
    }

    func testVisibilityIsCarriedOnTheRef() throws {
        let doors = try XCTUnwrap(groups().first)
        let mode = try XCTUnwrap(doors.devices.first { $0.entityId == "input_select.house_mode" })
        XCTAssertEqual(mode.visibility, [.state(entity: "input_boolean.porch_light", oneOf: ["on"], noneOf: [])])
        XCTAssertTrue(doors.devices.first { $0.entityId == "input_boolean.porch_light" }?.visibility.isEmpty ?? false)
        // The condition's entity is a row here, but it does not have to be.
        let refs = DashboardParser.references(in: try JSONValue.parse(Data(config.utf8)))
        XCTAssertEqual(refs.reduce(into: Set<String>()) { $0.formUnion($1.conditionEntityIds) },
                       ["input_boolean.porch_light"])
    }

    func testAConditionalCardsConditionsGovernItsCard() throws {
        let refs = DashboardParser.references(in: try JSONValue.parse(Data(#"""
        {"views":[{"cards":[{"type":"conditional",
          "conditions":[{"condition":"state","entity":"input_select.house_mode","state_not":"away"}],
          "card":{"type":"tile","entity":"switch.sprinkler"}}]}]}
        """#.utf8)))
        XCTAssertEqual(refs.map(\.entityId), ["switch.sprinkler"])
        XCTAssertEqual(refs.first?.visibility, [.state(entity: "input_select.house_mode", oneOf: [], noneOf: ["away"])])
    }

    func testLaterViewsAreTheirOwnGroups() throws {
        let groups = try groups()
        XCTAssertEqual(groups.map(\.view), [0, 0, 1])
        XCTAssertEqual(groups.last?.viewTitle, "Extras")
        XCTAssertEqual(groups.last?.title, "Garden")
    }
}
