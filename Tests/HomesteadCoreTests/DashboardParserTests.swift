import XCTest
@testable import HomesteadCore

final class DashboardParserTests: XCTestCase {
    private func parse(_ json: String) throws -> [DeviceRef] {
        DashboardParser.references(in: try JSONValue.parse(Data(json.utf8)))
    }

    func testEntitiesCardYieldsRowsInOrderUnderTheCardTitle() throws {
        let refs = try parse(#"""
        {"views":[{"title":"Home","cards":[
            {"type":"entities","title":"Living Room","entities":[
                "light.ceiling",
                {"entity":"fan.ceiling","name":"Fan"},
                {"type":"divider"}
            ]}
        ]}]}
        """#)

        XCTAssertEqual(refs, [
            DeviceRef(entityId: "light.ceiling", nameOverride: nil, header: "Living Room"),
            DeviceRef(entityId: "fan.ceiling", nameOverride: "Fan", header: "Living Room"),
        ])
    }

    func testTileCardUsesItsEntityAndNearestTitle() throws {
        let refs = try parse(#"""
        {"views":[{"title":"Home","cards":[{"type":"tile","entity":"switch.heater","name":"Heater"}]}]}
        """#)

        XCTAssertEqual(refs, [DeviceRef(entityId: "switch.heater", nameOverride: "Heater", header: "Home")])
    }

    func testFallsBackToDevicesWhenNothingIsTitled() throws {
        let refs = try parse(#"{"views":[{"cards":[{"type":"tile","entity":"light.hall"}]}]}"#)
        XCTAssertEqual(refs, [DeviceRef(entityId: "light.hall", nameOverride: nil, header: "Devices")])
    }

    func testRecursesThroughStacksAndGrids() throws {
        let refs = try parse(#"""
        {"views":[{"title":"Home","cards":[
            {"type":"vertical-stack","cards":[
                {"type":"horizontal-stack","cards":[
                    {"type":"tile","entity":"light.a"},
                    {"type":"grid","cards":[{"type":"tile","entity":"light.b"}]}
                ]}
            ]}
        ]}]}
        """#)

        XCTAssertEqual(refs.map(\.entityId), ["light.a", "light.b"])
        XCTAssertEqual(refs.map(\.header), ["Home", "Home"])
    }

    func testSectionsViewUsesSectionTitles() throws {
        let refs = try parse(#"""
        {"views":[{"type":"sections","title":"Home","sections":[
            {"type":"grid","title":"Office","cards":[{"type":"tile","entity":"light.desk"}]},
            {"type":"grid","cards":[{"type":"tile","entity":"light.spare"}]}
        ]}]}
        """#)

        XCTAssertEqual(refs, [
            DeviceRef(entityId: "light.desk", nameOverride: nil, header: "Office"),
            DeviceRef(entityId: "light.spare", nameOverride: nil, header: "Home"),
        ])
    }

    func testConditionalCardContributesItsCardButNotItsConditions() throws {
        let refs = try parse(#"""
        {"views":[{"title":"Home","cards":[
            {"type":"conditional",
             "conditions":[{"entity":"binary_sensor.someone_home","state":"on"}],
             "card":{"type":"tile","entity":"light.porch"}}
        ]}]}
        """#)

        XCTAssertEqual(refs.map(\.entityId), ["light.porch"])
    }

    func testActionTargetsAreNotTreatedAsRows() throws {
        let refs = try parse(#"""
        {"views":[{"title":"Home","cards":[
            {"type":"tile","entity":"light.a",
             "tap_action":{"action":"toggle","entity":"script.party"},
             "hold_action":{"action":"more-info","entity":"light.b"}}
        ]}]}
        """#)

        XCTAssertEqual(refs.map(\.entityId), ["light.a"])
    }

    func testDuplicatesKeepTheFirstOccurrence() throws {
        let refs = try parse(#"""
        {"views":[
            {"title":"Home","cards":[{"type":"tile","entity":"light.a","name":"First"}]},
            {"title":"Elsewhere","cards":[{"type":"tile","entity":"light.a","name":"Second"}]}
        ]}
        """#)

        XCTAssertEqual(refs, [DeviceRef(entityId: "light.a", nameOverride: "First", header: "Home")])
    }

    func testMultipleViewsFlattenInViewOrder() throws {
        let refs = try parse(#"""
        {"views":[
            {"title":"Downstairs","cards":[{"type":"tile","entity":"light.a"}]},
            {"title":"Upstairs","cards":[{"type":"tile","entity":"light.b"}]}
        ]}
        """#)

        XCTAssertEqual(refs.map(\.header), ["Downstairs", "Upstairs"])
    }

    func testEmptyConfigYieldsNothing() throws {
        XCTAssertEqual(try parse(#"{"views":[]}"#), [])
        XCTAssertEqual(try parse(#"{}"#), [])
    }
}
