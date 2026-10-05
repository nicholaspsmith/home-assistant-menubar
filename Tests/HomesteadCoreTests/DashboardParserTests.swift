// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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

    func testDeeplyNestedConfigIsRefusedRatherThanCrashing() {
        // Lovelace nests cards inside cards without limit. Foundation's decoder
        // stops first — it refuses JSON past its own nesting limit — so a config
        // like this never reaches the parser, and the client reports a failed
        // command instead of dying.
        var json = #"{"type":"tile","entity":"light.deep"}"#
        for _ in 0..<600 { json = #"{"type":"vertical-stack","cards":["# + json + #"]}"# }
        let wrapped = #"{"views":[{"cards":["# + json + #"]}]}"#
        XCTAssertThrowsError(try JSONValue.parse(Data(wrapped.utf8)))
    }

    func testTheWalkIsBoundedEvenIfATreeGetsPastTheDecoder() {
        // Belt and braces: a tree built in memory skips the decoder's limit
        // entirely, and the walk must still return rather than run out of stack.
        var node = JSONValue.object(["type": .string("tile"), "entity": .string("light.deep")])
        for _ in 0..<5_000 {
            node = .object(["type": .string("vertical-stack"), "cards": .array([node])])
        }
        let config = JSONValue.object(["views": .array([.object(["cards": .array([node])])])])
        XCTAssertTrue(DashboardParser.references(in: config).isEmpty)
    }

    func testNestingWithinTheLimitStillResolves() throws {
        var json = #"{"type":"tile","entity":"light.deep"}"#
        for _ in 0..<20 { json = #"{"type":"vertical-stack","cards":["# + json + #"]}"# }
        let wrapped = #"{"views":[{"title":"Home","cards":["# + json + #"]}]}"#
        let refs = DashboardParser.references(in: try JSONValue.parse(Data(wrapped.utf8)))
        XCTAssertEqual(refs.map { $0.entityId }, ["light.deep"])
    }

    func testEmptyConfigYieldsNothing() throws {
        XCTAssertEqual(try parse(#"{"views":[]}"#), [])
        XCTAssertEqual(try parse(#"{}"#), [])
    }

    // MARK: - Buttons

    /// The Studio TV dashboard: every key is a tile on the one remote entity,
    /// each sending its own command. They used to collapse into a single row —
    /// the first, "Back" — showing the remote's on/off switch.
    func testRemoteKeyTilesOnOneEntityAreSeparateButtons() throws {
        let refs = try parse(#"""
        {"views":[{"title":"Studio TV","sections":[{"type":"grid","cards":[
            {"type":"heading","heading":"Remote","heading_style":"subtitle"},
            {"type":"grid","columns":3,"cards":[
                {"type":"tile","entity":"remote.tv","name":"Back","icon":"mdi:arrow-left",
                 "tap_action":{"action":"perform-action","perform_action":"remote.send_command",
                               "target":{"entity_id":"remote.tv"},"data":{"command":"BACK"}}},
                {"type":"tile","entity":"remote.tv","name":"Up","icon":"mdi:chevron-up",
                 "tap_action":{"action":"perform-action","perform_action":"remote.send_command",
                               "target":{"entity_id":"remote.tv"},"data":{"command":"DPAD_UP"}}}
            ]}
        ]}]}]}
        """#)

        XCTAssertEqual(refs.map(\.nameOverride), ["Back", "Up"])
        XCTAssertEqual(refs.map(\.header), ["Remote", "Remote"])
        XCTAssertEqual(refs.map(\.icon), ["mdi:arrow-left", "mdi:chevron-up"])
        XCTAssertEqual(refs[0].action, CardAction(domain: "remote", service: "send_command",
                                                  entityIds: ["remote.tv"], data: ["command": .string("BACK")]))

        let devices = DeviceCatalog.build(refs: refs, states: [:], showSensors: false).flatMap(\.devices)
        XCTAssertEqual(devices.map(\.kind), [.button, .button])
        XCTAssertEqual(ServiceCall.press(devices[1]),
                       ServiceCall(domain: "remote", service: "send_command", entityId: "remote.tv",
                                   serviceData: ["command": .string("DPAD_UP")]))
    }

    /// The Master dashboard's remote is `button` cards with no `entity` at all —
    /// only a target in the action. They used to vanish.
    func testButtonCardsWithoutAnEntityUseTheirTarget() throws {
        let refs = try parse(#"""
        {"views":[{"title":"Master","cards":[
            {"type":"button","name":"Down","icon":"mdi:volume-minus",
             "tap_action":{"action":"perform-action","perform_action":"media_player.volume_down",
                           "target":{"entity_id":"media_player.roku"}}}
        ]}]}
        """#)
        XCTAssertEqual(refs.map(\.entityId), ["media_player.roku"])
        XCTAssertEqual(refs.first?.action?.service, "volume_down")
    }

    func testAnEntitysOwnToggleIsTheEntityNotAButton() throws {
        let refs = try parse(#"""
        {"views":[{"title":"Master","cards":[
            {"type":"tile","entity":"media_player.xbox","name":"Xbox",
             "tap_action":{"action":"perform-action","perform_action":"media_player.toggle",
                           "target":{"entity_id":"media_player.xbox"}}},
            {"type":"tile","entity":"light.lamp","tap_action":{"action":"more-info"}}
        ]}]}
        """#)
        XCTAssertEqual(refs.map(\.entityId), ["media_player.xbox", "light.lamp"])
        XCTAssertEqual(refs.map(\.action), [nil, nil])
    }

    func testConfirmationAndLegacyCallServiceAreRead() throws {
        let refs = try parse(#"""
        {"views":[{"title":"Hot Tub","cards":[
            {"type":"tile","entity":"button.restart","tap_action":{"action":"perform-action",
             "perform_action":"button.press","target":{"entity_id":"button.restart"},
             "confirmation":{"text":"Restart the spa controller?"}}},
            {"type":"button","name":"Movie","tap_action":{"action":"call-service","service":"script.turn_on",
             "service_data":{"entity_id":"script.movie"}}}
        ]}]}
        """#)
        XCTAssertEqual(refs[0].action?.confirmation, "Restart the spa controller?")
        XCTAssertEqual(refs[1].action, CardAction(domain: "script", service: "turn_on", entityIds: ["script.movie"]))
    }

    // MARK: - Headings

    func testHeadingCardsTitleTheCardsAfterThem() throws {
        let refs = try parse(#"""
        {"views":[{"title":"My Home","sections":[{"type":"grid","cards":[
            {"type":"heading","heading":"Kitchen"},
            {"type":"tile","entity":"light.kitchen"},
            {"type":"heading","heading":"Read from iLO over IPMI — updates every 5 min","heading_style":"subtitle"},
            {"type":"tile","entity":"light.counter"},
            {"type":"heading","heading":"Hall","heading_style":"subtitle"},
            {"type":"tile","entity":"light.hall"}
        ]}, {"type":"grid","cards":[{"type":"tile","entity":"fan.patio"}]}]}]}
        """#)
        // A long subtitle is a description, not a name; the next section
        // starts again from the view's title.
        XCTAssertEqual(refs.map(\.header), ["Kitchen", "Kitchen", "Hall", "My Home"])
    }
}
