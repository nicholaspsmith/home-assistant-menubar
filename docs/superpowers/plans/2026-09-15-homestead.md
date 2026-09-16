# Homestead Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Menubarn menu-bar app that lists the Home Assistant account's Lovelace dashboards in a picker and, for the selected dashboard, shows its devices as rows you can toggle, dim, and set fan speed / cover position on.

**Architecture:** Swift package with a pure `HomesteadCore` library (HA WebSocket protocol, dashboard parsing, state store, service calls — all unit-tested, no AppKit) and a thin `Homestead` AppKit executable (status item, `NSMenu` with view-based rows, connection window) built on the shared `StatusItemKit`. One persistent WebSocket to HA carries dashboard config, live entity state, and service calls; the menu and the mascot icon are both projections of one state snapshot.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, `URLSessionWebSocketTask`, `Network.NWPathMonitor`, Security (Keychain), XCTest, StatusItemKit (`../StatusItemKit`, path dependency).

**Spec:** `docs/superpowers/specs/2026-09-12-homestead-design.md`

## Global Constraints

- macOS 13+ (`platforms: [.macOS(.v13)]`), Swift tools 5.9. `SMAppService` requires 13.
- No third-party dependencies. Only `../StatusItemKit` (path dependency) plus Foundation / AppKit / Network / Security.
- `HomesteadCore` must not import AppKit — it is the unit-tested half. Everything AppKit lives in the `Homestead` target.
- Bundle id `com.nicholaspsmith.Homestead`, app name `Homestead.app`, `LSUIElement: true`, `CFBundleIconFile: AppIcon`.
- `os_log` subsystem for every log line: `com.nicholaspsmith.Homestead`.
- The HA long-lived token goes in the login Keychain (service `com.nicholaspsmith.Homestead`), **never** in UserDefaults, never in a log line, and never through an assistant session — Nick pastes it into the secure field himself.
- Build with `scripts/build-app.sh` (wraps `../StatusItemKit/scripts/make-app.sh`); install with `./install.sh`, which symlinks `build/Homestead.app` into `~/Applications`. Never copy the bundle there.
- Every app in the suite runs a `YieldClient` so Barn can reveal its hidden block. Homestead does too.
- Icon glyph images are regenerated with `~/Code/widgets.nicksmith.software/art/glyphs/render-glyphs.sh`. **Never screen-capture the menu bar for this** — capture returns a blank strip on this display.
- Commit messages end with the two attribution lines used in this repo (see the spec commit `996df72` for the exact form).
- Tests run with `swift test`; a single test with `swift test --filter <TestClass>/<testName>`.

---

### Task 1: Package scaffold and the HA WebSocket frame decoder

**Files:**
- Create: `Package.swift`
- Create: `Sources/HomesteadCore/JSONValue.swift`
- Create: `Sources/HomesteadCore/HAMessage.swift`
- Create: `Sources/Homestead/main.swift` (placeholder so the executable target builds)
- Test: `Tests/HomesteadCoreTests/JSONValueTests.swift`
- Test: `Tests/HomesteadCoreTests/HAMessageTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum JSONValue: Codable, Equatable, Sendable` with cases `.string(String)`, `.number(Double)`, `.bool(Bool)`, `.array([JSONValue])`, `.object([String: JSONValue])`, `.null`; accessors `.string: String?`, `.double: Double?`, `.int: Int?`, `.bool: Bool?`, `.array: [JSONValue]?`, `.object: [String: JSONValue]?`; `subscript(_ key: String) -> JSONValue?`; `static func parse(_ data: Data) throws -> JSONValue`; `func encodedData() throws -> Data`.
  - `struct HAError: Equatable, Sendable { let code: String; let message: String }`
  - `enum HAMessage: Equatable, Sendable` with cases `.authRequired`, `.authOK`, `.authInvalid(message: String)`, `.result(id: Int, success: Bool, result: JSONValue?, error: HAError?)`, `.event(id: Int, event: JSONValue)`, `.pong(id: Int)`, `.unknown(type: String)`; `static func decode(_ text: String) throws -> HAMessage`.

- [ ] **Step 1: Create the package skeleton**

`Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Homestead",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Homestead", targets: ["Homestead"]),
        .library(name: "HomesteadCore", targets: ["HomesteadCore"]),
    ],
    dependencies: [
        .package(path: "../StatusItemKit"),
    ],
    targets: [
        .target(name: "HomesteadCore"),
        .executableTarget(
            name: "Homestead",
            dependencies: [
                "HomesteadCore",
                .product(name: "StatusItemKit", package: "StatusItemKit"),
            ]
        ),
        .testTarget(name: "HomesteadCoreTests", dependencies: ["HomesteadCore"]),
    ]
)
```

`Sources/Homestead/main.swift` (replaced in Task 6):

```swift
import AppKit

// Placeholder: the real app is assembled in Task 6.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
```

- [ ] **Step 2: Write the failing JSONValue test**

`Tests/HomesteadCoreTests/JSONValueTests.swift`:

```swift
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
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter JSONValueTests`
Expected: FAIL — `cannot find 'JSONValue' in scope`.

- [ ] **Step 4: Implement JSONValue**

`Sources/HomesteadCore/JSONValue.swift`:

```swift
import Foundation

/// A parsed JSON tree. Home Assistant's dashboard configs and entity
/// attributes are free-form, so the whole payload is modelled rather than
/// typed per card: the parser walks structure, not schemas.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var string: String? { if case .string(let v) = self { return v } else { return nil } }
    public var double: Double? { if case .number(let v) = self { return v } else { return nil } }
    public var bool: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { return v } else { return nil } }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v } else { return nil } }

    /// Whole numbers only — a fractional value is not an int, so callers do not
    /// silently truncate an attribute like `percentage_step: 33.3`.
    public var int: Int? {
        guard let double, double == double.rounded(), double.magnitude < Double(Int.max) else { return nil }
        return Int(double)
    }

    public subscript(key: String) -> JSONValue? { object?[key] }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encodedData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter JSONValueTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Write the failing HAMessage test**

`Tests/HomesteadCoreTests/HAMessageTests.swift`:

```swift
import XCTest
@testable import HomesteadCore

final class HAMessageTests: XCTestCase {
    func testDecodesAuthHandshakeFrames() throws {
        XCTAssertEqual(try HAMessage.decode(#"{"type":"auth_required","ha_version":"2026.9.1"}"#), .authRequired)
        XCTAssertEqual(try HAMessage.decode(#"{"type":"auth_ok","ha_version":"2026.9.1"}"#), .authOK)
        XCTAssertEqual(
            try HAMessage.decode(#"{"type":"auth_invalid","message":"Invalid access token"}"#),
            .authInvalid(message: "Invalid access token")
        )
    }

    func testDecodesSuccessfulResult() throws {
        let frame = #"{"id":3,"type":"result","success":true,"result":[{"title":"My Home"}]}"#
        guard case .result(let id, let success, let result, let error) = try HAMessage.decode(frame) else {
            return XCTFail("expected a result frame")
        }
        XCTAssertEqual(id, 3)
        XCTAssertTrue(success)
        XCTAssertNil(error)
        XCTAssertEqual(result?.array?.first?["title"]?.string, "My Home")
    }

    func testDecodesErrorResult() throws {
        let frame = #"{"id":4,"type":"result","success":false,"error":{"code":"config_not_found","message":"nope"}}"#
        guard case .result(_, let success, _, let error) = try HAMessage.decode(frame) else {
            return XCTFail("expected a result frame")
        }
        XCTAssertFalse(success)
        XCTAssertEqual(error, HAError(code: "config_not_found", message: "nope"))
    }

    func testDecodesResultWithNullPayload() throws {
        // call_service replies carry `"result": null`; that must not read as an error.
        guard case .result(_, let success, let result, _) = try HAMessage.decode(#"{"id":9,"type":"result","success":true,"result":null}"#) else {
            return XCTFail("expected a result frame")
        }
        XCTAssertTrue(success)
        XCTAssertEqual(result, .null)
    }

    func testDecodesEvent() throws {
        let frame = #"{"id":5,"type":"event","event":{"a":{"light.desk":{"s":"on"}}}}"#
        guard case .event(let id, let event) = try HAMessage.decode(frame) else {
            return XCTFail("expected an event frame")
        }
        XCTAssertEqual(id, 5)
        XCTAssertEqual(event["a"]?["light.desk"]?["s"]?.string, "on")
    }

    func testUnknownTypeIsReportedNotThrown() throws {
        XCTAssertEqual(try HAMessage.decode(#"{"type":"pong","id":2}"#), .pong(id: 2))
        XCTAssertEqual(try HAMessage.decode(#"{"type":"future_thing"}"#), .unknown(type: "future_thing"))
    }

    func testMalformedFrameThrows() {
        XCTAssertThrowsError(try HAMessage.decode("not json"))
    }
}
```

- [ ] **Step 7: Run it to verify it fails**

Run: `swift test --filter HAMessageTests`
Expected: FAIL — `cannot find 'HAMessage' in scope`.

- [ ] **Step 8: Implement HAMessage**

`Sources/HomesteadCore/HAMessage.swift`:

```swift
import Foundation

/// An error Home Assistant returned for a command.
public struct HAError: Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A frame received on the Home Assistant WebSocket API.
///
/// Unknown types decode to `.unknown` rather than throwing: HA adds frame
/// types between releases, and an unrecognised one is not a reason to tear
/// down a working connection.
public enum HAMessage: Equatable, Sendable {
    case authRequired
    case authOK
    case authInvalid(message: String)
    case result(id: Int, success: Bool, result: JSONValue?, error: HAError?)
    case event(id: Int, event: JSONValue)
    case pong(id: Int)
    case unknown(type: String)

    public enum DecodeFailure: Error, Equatable {
        case notAnObject
        case missingType
    }

    public static func decode(_ text: String) throws -> HAMessage {
        let value = try JSONValue.parse(Data(text.utf8))
        guard value.object != nil else { throw DecodeFailure.notAnObject }
        guard let type = value["type"]?.string else { throw DecodeFailure.missingType }

        switch type {
        case "auth_required":
            return .authRequired
        case "auth_ok":
            return .authOK
        case "auth_invalid":
            return .authInvalid(message: value["message"]?.string ?? "")
        case "result":
            let error = value["error"].flatMap { payload -> HAError? in
                guard let code = payload["code"]?.string else { return nil }
                return HAError(code: code, message: payload["message"]?.string ?? "")
            }
            return .result(
                id: value["id"]?.int ?? 0,
                success: value["success"]?.bool ?? false,
                result: value["result"],
                error: error
            )
        case "event":
            return .event(id: value["id"]?.int ?? 0, event: value["event"] ?? .null)
        case "pong":
            return .pong(id: value["id"]?.int ?? 0)
        default:
            return .unknown(type: type)
        }
    }
}
```

- [ ] **Step 9: Run the full suite**

Run: `swift test`
Expected: PASS (10 tests, 0 failures).

- [ ] **Step 10: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: package scaffold and HA WebSocket frame decoding"
```

---

### Task 2: Dashboard listing and the dashboard-config parser

**Files:**
- Create: `Sources/HomesteadCore/DashboardListing.swift`
- Create: `Sources/HomesteadCore/DashboardParser.swift`
- Test: `Tests/HomesteadCoreTests/DashboardListingTests.swift`
- Test: `Tests/HomesteadCoreTests/DashboardParserTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (Task 1).
- Produces:
  - `struct DashboardListing: Equatable, Sendable { let urlPath: String?; let title: String }` — `urlPath == nil` is the built-in Overview; `static func list(from result: JSONValue) -> [DashboardListing]`.
  - `struct DeviceRef: Equatable, Sendable { let entityId: String; let nameOverride: String?; let header: String }`
  - `enum DashboardParser { static func references(in config: JSONValue) -> [DeviceRef] }` — dashboard order, deduped, first occurrence wins.

- [ ] **Step 1: Write the failing dashboard-listing test**

`Tests/HomesteadCoreTests/DashboardListingTests.swift`:

```swift
import XCTest
@testable import HomesteadCore

final class DashboardListingTests: XCTestCase {
    func testOverviewIsPrependedAndUserDashboardsFollowInOrder() throws {
        let result = try JSONValue.parse(Data(#"""
        [{"id":"my_home","url_path":"my-home","title":"My Home","mode":"storage"},
         {"id":"garden","url_path":"garden","title":"Garden","mode":"yaml"}]
        """#.utf8))

        let listings = DashboardListing.list(from: result)

        XCTAssertEqual(listings, [
            DashboardListing(urlPath: nil, title: "Overview"),
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: "garden", title: "Garden"),
        ])
    }

    func testEntriesWithoutTitleOrURLPathAreSkipped() throws {
        let result = try JSONValue.parse(Data(#"""
        [{"id":"broken","mode":"storage"},
         {"id":"ok","url_path":"ok","title":"OK"},
         {"id":"untitled","url_path":"untitled"}]
        """#.utf8))

        XCTAssertEqual(DashboardListing.list(from: result).map(\.title), ["Overview", "OK"])
    }

    func testNonArrayResultStillYieldsOverview() {
        XCTAssertEqual(DashboardListing.list(from: .null), [DashboardListing(urlPath: nil, title: "Overview")])
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter DashboardListingTests`
Expected: FAIL — `cannot find 'DashboardListing' in scope`.

- [ ] **Step 3: Implement DashboardListing**

`Sources/HomesteadCore/DashboardListing.swift`:

```swift
import Foundation

/// One entry in the menu's dashboard picker.
public struct DashboardListing: Equatable, Sendable {
    /// `nil` is the built-in Overview, which `lovelace/dashboards/list` never
    /// returns and whose config is requested with no `url_path`.
    public let urlPath: String?
    public let title: String

    public init(urlPath: String?, title: String) {
        self.urlPath = urlPath
        self.title = title
    }

    public static let overview = DashboardListing(urlPath: nil, title: "Overview")

    /// Build the picker's list from a `lovelace/dashboards/list` result.
    public static func list(from result: JSONValue) -> [DashboardListing] {
        let user = (result.array ?? []).compactMap { entry -> DashboardListing? in
            guard let urlPath = entry["url_path"]?.string,
                  let title = entry["title"]?.string, !title.isEmpty
            else { return nil }
            return DashboardListing(urlPath: urlPath, title: title)
        }
        return [.overview] + user
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter DashboardListingTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Write the failing parser test**

`Tests/HomesteadCoreTests/DashboardParserTests.swift`:

```swift
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
```

- [ ] **Step 6: Run it to verify it fails**

Run: `swift test --filter DashboardParserTests`
Expected: FAIL — `cannot find 'DashboardParser' in scope`.

- [ ] **Step 7: Implement the parser**

`Sources/HomesteadCore/DashboardParser.swift`:

```swift
import Foundation

/// One entity as a dashboard refers to it, before state is known.
public struct DeviceRef: Equatable, Sendable {
    public let entityId: String
    /// The card's `name:` override, if it set one.
    public let nameOverride: String?
    /// Nearest enclosing title — card, then section, then view.
    public let header: String

    public init(entityId: String, nameOverride: String?, header: String) {
        self.entityId = entityId
        self.nameOverride = nameOverride
        self.header = header
    }
}

/// Walks a `lovelace/config` payload and pulls out the entities it displays.
///
/// The walk is structural, not card-type-aware: it collects `entity` and
/// `entities` wherever they appear and recurses through nested containers, so
/// custom cards and card types added after this was written still work. The
/// cost is that keys which name an entity *without* displaying it — a
/// conditional's `conditions`, a tap action's target — have to be skipped
/// explicitly.
public enum DashboardParser {
    private static let fallbackHeader = "Devices"

    /// Keys that reference entities for reasons other than display.
    private static let skippedKeys: Set<String> = [
        "conditions", "visibility", "filter",
        "tap_action", "hold_action", "double_tap_action",
        "icon_tap_action", "entity_id",
    ]

    /// Containers recursed in a fixed order, so output order is deterministic
    /// and matches what the dashboard shows.
    private static let containerKeys = ["sections", "cards", "card", "badges", "elements", "features", "chips"]

    public static func references(in config: JSONValue) -> [DeviceRef] {
        var found: [DeviceRef] = []
        var seen: Set<String> = []

        func append(entityId: String, nameOverride: String?, header: String) {
            guard entityId.contains("."), seen.insert(entityId).inserted else { return }
            found.append(DeviceRef(entityId: entityId, nameOverride: nameOverride, header: header))
        }

        func walk(_ node: JSONValue, header: String) {
            switch node {
            case .array(let elements):
                for element in elements { walk(element, header: header) }

            case .object(let fields):
                let header = fields["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? header

                if let entityId = fields["entity"]?.string {
                    append(entityId: entityId, nameOverride: fields["name"]?.string, header: header)
                }

                for element in fields["entities"]?.array ?? [] {
                    if let entityId = element.string {
                        append(entityId: entityId, nameOverride: nil, header: header)
                    } else if let entityId = element["entity"]?.string {
                        append(entityId: entityId, nameOverride: element["name"]?.string, header: header)
                    } else {
                        walk(element, header: header)   // nested group rows
                    }
                }

                for key in containerKeys {
                    if let child = fields[key] { walk(child, header: header) }
                }
                for key in fields.keys.sorted()
                where !containerKeys.contains(key) && !skippedKeys.contains(key)
                    && key != "entity" && key != "entities" && key != "name" && key != "title" {
                    walk(fields[key]!, header: header)
                }

            default:
                break
            }
        }

        for view in config["views"]?.array ?? [] {
            walk(view, header: view["title"]?.string ?? fallbackHeader)
        }
        return found
    }
}
```

- [ ] **Step 8: Run the full suite**

Run: `swift test`
Expected: PASS (all tests, including 10 new parser/listing tests).

- [ ] **Step 9: Commit**

```bash
git add Sources/HomesteadCore/DashboardListing.swift Sources/HomesteadCore/DashboardParser.swift Tests
git commit -m "feat: parse dashboard listings and dashboard configs"
```

---

### Task 3: Entity state and the `subscribe_entities` diff store

**Files:**
- Create: `Sources/HomesteadCore/EntityState.swift`
- Create: `Sources/HomesteadCore/StateStore.swift`
- Test: `Tests/HomesteadCoreTests/StateStoreTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (Task 1).
- Produces:
  - `struct EntityState: Equatable, Sendable { var state: String; var attributes: [String: JSONValue] }` with `var friendlyName: String?`, `var isAvailable: Bool`, `var isOn: Bool`, `var unit: String?`.
  - `struct StateStore: Sendable { private(set) var states: [String: EntityState]; init(); mutating func apply(_ event: JSONValue) -> Set<String>; mutating func reset(); subscript(entityId: String) -> EntityState? }`.

- [ ] **Step 1: Write the failing test**

`Tests/HomesteadCoreTests/StateStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter StateStoreTests`
Expected: FAIL — `cannot find 'StateStore' in scope`.

- [ ] **Step 3: Implement EntityState and StateStore**

`Sources/HomesteadCore/EntityState.swift`:

```swift
import Foundation

/// One entity's current state as the menu needs it.
public struct EntityState: Equatable, Sendable {
    public var state: String
    public var attributes: [String: JSONValue]

    public init(state: String, attributes: [String: JSONValue] = [:]) {
        self.state = state
        self.attributes = attributes
    }

    public var friendlyName: String? { attributes["friendly_name"]?.string }
    public var unit: String? { attributes["unit_of_measurement"]?.string }

    /// `unavailable` and `unknown` are HA's two "no reading" states; rows for
    /// them are shown but disabled rather than hidden, so a device that drops
    /// off the network does not silently vanish from the menu.
    public var isAvailable: Bool { state != "unavailable" && state != "unknown" }

    /// Covers report travel states; treat anything but fully closed as open, so
    /// the switch reflects where the cover is heading.
    public var isOn: Bool {
        switch state {
        case "on", "open", "opening", "closing": return true
        default: return false
        }
    }
}
```

`Sources/HomesteadCore/StateStore.swift`:

```swift
import Foundation

/// Applies `subscribe_entities` events. That subscription sends a compressed
/// form — `a` adds, `c` changes (with `+` set and `-` unset), `r` removes —
/// rather than whole states, so the store has to merge rather than replace.
public struct StateStore: Sendable {
    public private(set) var states: [String: EntityState] = [:]

    public init() {}

    public subscript(entityId: String) -> EntityState? { states[entityId] }

    public mutating func reset() { states.removeAll() }

    /// - Returns: the entity ids this event touched, so only those rows redraw.
    @discardableResult
    public mutating func apply(_ event: JSONValue) -> Set<String> {
        var changed: Set<String> = []

        for (entityId, payload) in event["a"]?.object ?? [:] {
            states[entityId] = EntityState(
                state: payload["s"]?.string ?? "unknown",
                attributes: payload["a"]?.object ?? [:]
            )
            changed.insert(entityId)
        }

        for (entityId, payload) in event["c"]?.object ?? [:] {
            guard var existing = states[entityId] else { continue }
            if let added = payload["+"] {
                if let state = added["s"]?.string { existing.state = state }
                for (key, value) in added["a"]?.object ?? [:] { existing.attributes[key] = value }
            }
            for removed in payload["-"]?["a"]?.array ?? [] {
                if let key = removed.string { existing.attributes.removeValue(forKey: key) }
            }
            states[entityId] = existing
            changed.insert(entityId)
        }

        for removed in event["r"]?.array ?? [] {
            guard let entityId = removed.string, states.removeValue(forKey: entityId) != nil else { continue }
            changed.insert(entityId)
        }

        return changed
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter StateStoreTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/HomesteadCore/EntityState.swift Sources/HomesteadCore/StateStore.swift Tests/HomesteadCoreTests/StateStoreTests.swift
git commit -m "feat: entity state and compressed state diffs"
```

---

### Task 4: Devices, level math, and service calls

**Files:**
- Create: `Sources/HomesteadCore/Device.swift`
- Create: `Sources/HomesteadCore/LevelMath.swift`
- Create: `Sources/HomesteadCore/ServiceCall.swift`
- Test: `Tests/HomesteadCoreTests/DeviceCatalogTests.swift`
- Test: `Tests/HomesteadCoreTests/LevelMathTests.swift`
- Test: `Tests/HomesteadCoreTests/ServiceCallTests.swift`

**Interfaces:**
- Consumes: `DeviceRef` (Task 2), `EntityState` / `StateStore` (Task 3), `JSONValue` (Task 1).
- Produces:
  - `enum DeviceKind: Equatable, Sendable { case light, fan, toggle, cover(positionable: Bool), sensor }` with `var hasSlider: Bool`, `var hasSwitch: Bool`.
  - `struct Device: Equatable, Sendable { let entityId: String; let displayName: String; let kind: DeviceKind }` with `var domain: String`.
  - `struct DeviceGroup: Equatable, Sendable { let title: String; let devices: [Device] }`.
  - `enum DeviceCatalog { static func build(refs: [DeviceRef], states: [String: EntityState], showSensors: Bool) -> [DeviceGroup] }`.
  - `enum LevelMath { static func fraction(brightness: JSONValue?) -> Double; static func brightnessPct(from fraction: Double) -> Int; static func fanPercentage(from fraction: Double, step: Double?) -> Int; static func coverPosition(from fraction: Double) -> Int; static func fraction(percentage: JSONValue?) -> Double }`.
  - `struct ServiceCall: Equatable, Sendable { let domain: String; let service: String; let entityId: String; let serviceData: [String: JSONValue] }` with `static func toggle(_ device: Device, on: Bool) -> ServiceCall` and `static func setLevel(_ device: Device, fraction: Double, state: EntityState?) -> ServiceCall?`.

- [ ] **Step 1: Write the failing level-math test**

`Tests/HomesteadCoreTests/LevelMathTests.swift`:

```swift
import XCTest
@testable import HomesteadCore

final class LevelMathTests: XCTestCase {
    func testBrightnessAttributeConvertsToFraction() {
        XCTAssertEqual(LevelMath.fraction(brightness: .number(255)), 1.0, accuracy: 0.001)
        XCTAssertEqual(LevelMath.fraction(brightness: .number(128)), 0.502, accuracy: 0.001)
        XCTAssertEqual(LevelMath.fraction(brightness: nil), 0)
        XCTAssertEqual(LevelMath.fraction(brightness: .null), 0)
    }

    func testBrightnessPercentNeverReachesZero() {
        // 0% would be turn_off in disguise; the switch owns off, the slider does not.
        XCTAssertEqual(LevelMath.brightnessPct(from: 0), 1)
        XCTAssertEqual(LevelMath.brightnessPct(from: 0.004), 1)
        XCTAssertEqual(LevelMath.brightnessPct(from: 0.5), 50)
        XCTAssertEqual(LevelMath.brightnessPct(from: 1), 100)
        XCTAssertEqual(LevelMath.brightnessPct(from: 2), 100)
    }

    func testFanPercentageSnapsToTheDeviceStep() {
        // A three-speed fan has step 33.333…; anything else is rejected by HA.
        XCTAssertEqual(LevelMath.fanPercentage(from: 0.4, step: 100.0 / 3.0), 33)
        XCTAssertEqual(LevelMath.fanPercentage(from: 0.6, step: 100.0 / 3.0), 67)
        XCTAssertEqual(LevelMath.fanPercentage(from: 0.9, step: 100.0 / 3.0), 100)
        XCTAssertEqual(LevelMath.fanPercentage(from: 0.42, step: nil), 42)
        XCTAssertEqual(LevelMath.fanPercentage(from: 0.42, step: 0), 42)
    }

    func testCoverPositionSpansTheFullRange() {
        XCTAssertEqual(LevelMath.coverPosition(from: 0), 0)
        XCTAssertEqual(LevelMath.coverPosition(from: 0.5), 50)
        XCTAssertEqual(LevelMath.coverPosition(from: 1), 100)
    }

    func testPercentageAttributeConvertsToFraction() {
        XCTAssertEqual(LevelMath.fraction(percentage: .number(67)), 0.67, accuracy: 0.001)
        XCTAssertEqual(LevelMath.fraction(percentage: nil), 0)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter LevelMathTests`
Expected: FAIL — `cannot find 'LevelMath' in scope`.

- [ ] **Step 3: Implement LevelMath**

`Sources/HomesteadCore/LevelMath.swift`:

```swift
import Foundation

/// Conversions between the slider's 0…1 and the units each HA domain speaks.
public enum LevelMath {
    /// `light.brightness` is 0…255.
    public static func fraction(brightness: JSONValue?) -> Double {
        guard let raw = brightness?.double else { return 0 }
        return min(max(raw / 255, 0), 1)
    }

    /// `fan.percentage` and `cover.current_position` are already 0…100.
    public static func fraction(percentage: JSONValue?) -> Double {
        guard let raw = percentage?.double else { return 0 }
        return min(max(raw / 100, 0), 1)
    }

    /// Lights take `brightness_pct` 1…100. Zero is deliberately unreachable:
    /// `turn_on` at 0% turns the light off, which would leave the row's switch
    /// on and the light dark.
    public static func brightnessPct(from fraction: Double) -> Int {
        Int(min(max(fraction, 0), 1) * 100).clamped(to: 1...100)
    }

    /// Fans accept only multiples of `percentage_step`; a three-speed fan has a
    /// step of 33.33…, and an unsnapped 40% is rejected outright.
    public static func fanPercentage(from fraction: Double, step: Double?) -> Int {
        let pct = min(max(fraction, 0), 1) * 100
        guard let step, step > 0, step < 100 else { return Int(pct.rounded()).clamped(to: 0...100) }
        return Int((pct / step).rounded() * step).clamped(to: 0...100)
    }

    public static func coverPosition(from fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded()).clamped(to: 0...100)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter LevelMathTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Write the failing device-catalog test**

`Tests/HomesteadCoreTests/DeviceCatalogTests.swift`:

```swift
import XCTest
@testable import HomesteadCore

final class DeviceCatalogTests: XCTestCase {
    private let refs = [
        DeviceRef(entityId: "light.ceiling", nameOverride: nil, header: "Living Room"),
        DeviceRef(entityId: "fan.ceiling", nameOverride: "Fan", header: "Living Room"),
        DeviceRef(entityId: "switch.heater", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "input_boolean.guest", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "cover.garage", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "cover.blind", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "sensor.temperature", nameOverride: nil, header: "Office"),
        DeviceRef(entityId: "media_player.tv", nameOverride: nil, header: "Office"),
    ]

    private let states: [String: EntityState] = [
        "light.ceiling": EntityState(state: "on", attributes: ["friendly_name": .string("Ceiling Lights")]),
        "fan.ceiling": EntityState(state: "on", attributes: ["friendly_name": .string("Ceiling Fan")]),
        "switch.heater": EntityState(state: "off", attributes: ["friendly_name": .string("Space Heater")]),
        "input_boolean.guest": EntityState(state: "off"),
        "cover.garage": EntityState(state: "closed", attributes: ["supported_features": .number(15)]),
        "cover.blind": EntityState(state: "closed", attributes: ["supported_features": .number(3)]),
        "sensor.temperature": EntityState(state: "21.5", attributes: ["unit_of_measurement": .string("°C")]),
        "media_player.tv": EntityState(state: "playing"),
    ]

    func testGroupsPreserveDashboardOrderAndHeaders() {
        let groups = DeviceCatalog.build(refs: refs, states: states, showSensors: false)

        XCTAssertEqual(groups.map(\.title), ["Living Room", "Office"])
        XCTAssertEqual(groups[0].devices.map(\.entityId), ["light.ceiling", "fan.ceiling"])
        XCTAssertEqual(groups[1].devices.map(\.entityId),
                       ["switch.heater", "input_boolean.guest", "cover.garage", "cover.blind"])
    }

    func testKindsComeFromTheDomain() {
        let devices = DeviceCatalog.build(refs: refs, states: states, showSensors: false).flatMap(\.devices)
        let byId = Dictionary(uniqueKeysWithValues: devices.map { ($0.entityId, $0.kind) })

        XCTAssertEqual(byId["light.ceiling"], .light)
        XCTAssertEqual(byId["fan.ceiling"], .fan)
        XCTAssertEqual(byId["switch.heater"], .toggle)
        XCTAssertEqual(byId["input_boolean.guest"], .toggle)
        XCTAssertEqual(byId["cover.garage"], .cover(positionable: true))    // supported_features 15 has SET_POSITION
        XCTAssertEqual(byId["cover.blind"], .cover(positionable: false))    // 3 is open+close only
    }

    func testUnsupportedDomainsAreDropped() {
        let ids = DeviceCatalog.build(refs: refs, states: states, showSensors: true).flatMap(\.devices).map(\.entityId)
        XCTAssertFalse(ids.contains("media_player.tv"))
    }

    func testSensorsAppearOnlyWhenEnabled() {
        let without = DeviceCatalog.build(refs: refs, states: states, showSensors: false).flatMap(\.devices)
        XCTAssertFalse(without.contains { $0.kind == .sensor })

        let with = DeviceCatalog.build(refs: refs, states: states, showSensors: true).flatMap(\.devices)
        XCTAssertEqual(with.first { $0.kind == .sensor }?.entityId, "sensor.temperature")
    }

    func testDisplayNamePrefersOverrideThenFriendlyNameThenEntityId() {
        let devices = DeviceCatalog.build(refs: refs, states: states, showSensors: false).flatMap(\.devices)
        let byId = Dictionary(uniqueKeysWithValues: devices.map { ($0.entityId, $0.displayName) })

        XCTAssertEqual(byId["fan.ceiling"], "Fan")                   // card override wins
        XCTAssertEqual(byId["light.ceiling"], "Ceiling Lights")      // friendly_name
        XCTAssertEqual(byId["input_boolean.guest"], "input_boolean.guest")
    }

    func testEntitiesWithNoStateYetStillGetRows() {
        let groups = DeviceCatalog.build(
            refs: [DeviceRef(entityId: "light.new", nameOverride: nil, header: "Hall")],
            states: [:],
            showSensors: false
        )
        XCTAssertEqual(groups.first?.devices.first?.kind, .light)
    }
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `swift test --filter DeviceCatalogTests`
Expected: FAIL — `cannot find 'DeviceCatalog' in scope`.

- [ ] **Step 7: Implement Device, DeviceGroup and DeviceCatalog**

`Sources/HomesteadCore/Device.swift`:

```swift
import Foundation

/// What controls a row shows, derived from the entity's domain.
public enum DeviceKind: Equatable, Sendable {
    case light
    case fan
    case toggle
    /// `positionable` means the cover reports SET_POSITION, so it gets a slider.
    case cover(positionable: Bool)
    case sensor

    public var hasSwitch: Bool { self != .sensor }

    public var hasSlider: Bool {
        switch self {
        case .light, .fan: return true
        case .cover(let positionable): return positionable
        case .toggle, .sensor: return false
        }
    }
}

public struct Device: Equatable, Sendable {
    public let entityId: String
    public let displayName: String
    public let kind: DeviceKind

    public init(entityId: String, displayName: String, kind: DeviceKind) {
        self.entityId = entityId
        self.displayName = displayName
        self.kind = kind
    }

    public var domain: String { String(entityId.prefix(while: { $0 != "." })) }
}

/// A run of devices under one card/section/view title.
public struct DeviceGroup: Equatable, Sendable {
    public let title: String
    public let devices: [Device]

    public init(title: String, devices: [Device]) {
        self.title = title
        self.devices = devices
    }
}

public enum DeviceCatalog {
    /// HA's `CoverEntityFeature.SET_POSITION`.
    private static let coverSetPosition = 4

    public static func build(refs: [DeviceRef], states: [String: EntityState], showSensors: Bool) -> [DeviceGroup] {
        var groups: [DeviceGroup] = []

        for ref in refs {
            let state = states[ref.entityId]
            guard let kind = kind(for: ref.entityId, state: state) else { continue }
            if kind == .sensor && !showSensors { continue }

            let device = Device(
                entityId: ref.entityId,
                displayName: ref.nameOverride ?? state?.friendlyName ?? ref.entityId,
                kind: kind
            )

            if let last = groups.last, last.title == ref.header {
                groups[groups.count - 1] = DeviceGroup(title: last.title, devices: last.devices + [device])
            } else {
                groups.append(DeviceGroup(title: ref.header, devices: [device]))
            }
        }

        return groups
    }

    private static func kind(for entityId: String, state: EntityState?) -> DeviceKind? {
        switch String(entityId.prefix(while: { $0 != "." })) {
        case "light": return .light
        case "fan": return .fan
        case "switch", "input_boolean": return .toggle
        case "cover":
            let features = state?.attributes["supported_features"]?.int ?? 0
            return .cover(positionable: features & coverSetPosition != 0)
        case "sensor", "binary_sensor": return .sensor
        default: return nil
        }
    }
}
```

- [ ] **Step 8: Run it to verify it passes**

Run: `swift test --filter DeviceCatalogTests`
Expected: PASS (6 tests).

- [ ] **Step 9: Write the failing service-call test**

`Tests/HomesteadCoreTests/ServiceCallTests.swift`:

```swift
import XCTest
@testable import HomesteadCore

final class ServiceCallTests: XCTestCase {
    private let light = Device(entityId: "light.desk", displayName: "Desk", kind: .light)
    private let fan = Device(entityId: "fan.office", displayName: "Fan", kind: .fan)
    private let heater = Device(entityId: "switch.heater", displayName: "Heater", kind: .toggle)
    private let garage = Device(entityId: "cover.garage", displayName: "Garage", kind: .cover(positionable: true))
    private let blind = Device(entityId: "cover.blind", displayName: "Blind", kind: .cover(positionable: false))
    private let sensor = Device(entityId: "sensor.temp", displayName: "Temp", kind: .sensor)

    func testToggleUsesTheDomainsOwnServices() {
        XCTAssertEqual(ServiceCall.toggle(light, on: true),
                       ServiceCall(domain: "light", service: "turn_on", entityId: "light.desk", serviceData: [:]))
        XCTAssertEqual(ServiceCall.toggle(heater, on: false),
                       ServiceCall(domain: "switch", service: "turn_off", entityId: "switch.heater", serviceData: [:]))
        XCTAssertEqual(ServiceCall.toggle(garage, on: true),
                       ServiceCall(domain: "cover", service: "open_cover", entityId: "cover.garage", serviceData: [:]))
        XCTAssertEqual(ServiceCall.toggle(blind, on: false),
                       ServiceCall(domain: "cover", service: "close_cover", entityId: "cover.blind", serviceData: [:]))
    }

    func testLightLevelSendsBrightnessPercent() {
        let call = ServiceCall.setLevel(light, fraction: 0.5, state: nil)
        XCTAssertEqual(call, ServiceCall(domain: "light", service: "turn_on", entityId: "light.desk",
                                         serviceData: ["brightness_pct": .number(50)]))
    }

    func testFanLevelSnapsToPercentageStep() {
        let state = EntityState(state: "on", attributes: ["percentage_step": .number(100.0 / 3.0)])
        let call = ServiceCall.setLevel(fan, fraction: 0.6, state: state)
        XCTAssertEqual(call, ServiceCall(domain: "fan", service: "set_percentage", entityId: "fan.office",
                                         serviceData: ["percentage": .number(67)]))
    }

    func testCoverLevelSetsPosition() {
        let call = ServiceCall.setLevel(garage, fraction: 0.25, state: nil)
        XCTAssertEqual(call, ServiceCall(domain: "cover", service: "set_cover_position", entityId: "cover.garage",
                                         serviceData: ["position": .number(25)]))
    }

    func testKindsWithoutASliderHaveNoLevelCall() {
        XCTAssertNil(ServiceCall.setLevel(heater, fraction: 0.5, state: nil))
        XCTAssertNil(ServiceCall.setLevel(blind, fraction: 0.5, state: nil))
        XCTAssertNil(ServiceCall.setLevel(sensor, fraction: 0.5, state: nil))
        XCTAssertNil(ServiceCall.toggle(sensor, on: true))
    }

    func testCommandPayloadMatchesTheWebSocketAPI() {
        let payload = ServiceCall.toggle(light, on: true)!.commandPayload
        XCTAssertEqual(payload["type"], .string("call_service"))
        XCTAssertEqual(payload["domain"], .string("light"))
        XCTAssertEqual(payload["service"], .string("turn_on"))
        XCTAssertEqual(payload["target"], .object(["entity_id": .string("light.desk")]))
        XCTAssertNil(payload["service_data"])   // omitted when empty

        let dimmed = ServiceCall.setLevel(light, fraction: 0.4, state: nil)!.commandPayload
        XCTAssertEqual(dimmed["service_data"], .object(["brightness_pct": .number(40)]))
    }
}
```

Note: `toggle` returns an optional in this test, so its signature is
`static func toggle(_ device: Device, on: Bool) -> ServiceCall?` — a sensor has
nothing to call.

- [ ] **Step 10: Run it to verify it fails**

Run: `swift test --filter ServiceCallTests`
Expected: FAIL — `cannot find 'ServiceCall' in scope`.

- [ ] **Step 11: Implement ServiceCall**

`Sources/HomesteadCore/ServiceCall.swift`:

```swift
import Foundation

/// One `call_service` command, built from a row's control and the device's kind.
public struct ServiceCall: Equatable, Sendable {
    public let domain: String
    public let service: String
    public let entityId: String
    public let serviceData: [String: JSONValue]

    public init(domain: String, service: String, entityId: String, serviceData: [String: JSONValue]) {
        self.domain = domain
        self.service = service
        self.entityId = entityId
        self.serviceData = serviceData
    }

    public static func toggle(_ device: Device, on: Bool) -> ServiceCall? {
        switch device.kind {
        case .light, .fan, .toggle:
            return ServiceCall(domain: device.domain, service: on ? "turn_on" : "turn_off",
                               entityId: device.entityId, serviceData: [:])
        case .cover:
            return ServiceCall(domain: "cover", service: on ? "open_cover" : "close_cover",
                               entityId: device.entityId, serviceData: [:])
        case .sensor:
            return nil
        }
    }

    /// - Parameter state: the device's current state, for attributes the call
    ///   depends on (a fan's `percentage_step`). Nil is safe; the call then
    ///   uses the domain's default granularity.
    public static func setLevel(_ device: Device, fraction: Double, state: EntityState?) -> ServiceCall? {
        switch device.kind {
        case .light:
            return ServiceCall(domain: "light", service: "turn_on", entityId: device.entityId,
                               serviceData: ["brightness_pct": .number(Double(LevelMath.brightnessPct(from: fraction)))])
        case .fan:
            let step = state?.attributes["percentage_step"]?.double
            return ServiceCall(domain: "fan", service: "set_percentage", entityId: device.entityId,
                               serviceData: ["percentage": .number(Double(LevelMath.fanPercentage(from: fraction, step: step)))])
        case .cover(let positionable):
            guard positionable else { return nil }
            return ServiceCall(domain: "cover", service: "set_cover_position", entityId: device.entityId,
                               serviceData: ["position": .number(Double(LevelMath.coverPosition(from: fraction)))])
        case .toggle, .sensor:
            return nil
        }
    }

    /// The WebSocket command body, without the `id` the client assigns.
    public var commandPayload: [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "type": .string("call_service"),
            "domain": .string(domain),
            "service": .string(service),
            "target": .object(["entity_id": .string(entityId)]),
        ]
        if !serviceData.isEmpty { payload["service_data"] = .object(serviceData) }
        return payload
    }
}
```

- [ ] **Step 12: Run the full suite**

Run: `swift test`
Expected: PASS (all tests).

- [ ] **Step 13: Commit**

```bash
git add Sources/HomesteadCore Tests/HomesteadCoreTests
git commit -m "feat: device kinds, level math, and service calls"
```

---

### Task 5: The WebSocket client

**Files:**
- Create: `Sources/HomesteadCore/HAURL.swift`
- Create: `Sources/HomesteadCore/HATransport.swift`
- Create: `Sources/HomesteadCore/HAClient.swift`
- Create: `Sources/HomesteadCore/ReconnectPolicy.swift`
- Test: `Tests/HomesteadCoreTests/HAURLTests.swift`
- Test: `Tests/HomesteadCoreTests/HAClientTests.swift`
- Test: `Tests/HomesteadCoreTests/ReconnectPolicyTests.swift`

**Interfaces:**
- Consumes: `HAMessage`, `JSONValue` (Task 1), `ServiceCall` (Task 4).
- Produces:
  - `enum HAURL { static func websocketURL(from text: String) -> URL? }`.
  - `protocol HATransport: AnyObject, Sendable { func connect(to url: URL) async throws; func send(_ text: String) async throws; func receive() async throws -> String; func close() }`, plus `final class URLSessionTransport: HATransport`.
  - `enum HAClientError: Error, Equatable { case authInvalid(String); case command(HAError); case closed; case notConnected }`.
  - `actor HAClient` with `init(transport: HATransport)`, `func connect(url: URL, token: String) async throws`, `func send(_ payload: [String: JSONValue]) async throws -> JSONValue`, `func subscribe(_ payload: [String: JSONValue], onEvent: @escaping @Sendable (JSONValue) -> Void) async throws -> Int`, `func unsubscribe(_ subscriptionId: Int) async`, `func disconnect()`, `var onClose: (@Sendable (String) -> Void)?` set via `func setOnClose(_:)`.
  - `enum ReconnectPolicy { static func delay(attempt: Int) -> TimeInterval }`.

- [ ] **Step 1: Write the failing URL test**

`Tests/HomesteadCoreTests/HAURLTests.swift`:

```swift
import XCTest
@testable import HomesteadCore

final class HAURLTests: XCTestCase {
    func testHTTPBecomesWS() {
        XCTAssertEqual(HAURL.websocketURL(from: "http://homeassistant.local:8123")?.absoluteString,
                       "ws://homeassistant.local:8123/api/websocket")
    }

    func testHTTPSBecomesWSS() {
        XCTAssertEqual(HAURL.websocketURL(from: "https://ha.example.com")?.absoluteString,
                       "wss://ha.example.com/api/websocket")
    }

    func testBareHostDefaultsToHTTPAndTrailingSlashesAreIgnored() {
        XCTAssertEqual(HAURL.websocketURL(from: "homeassistant.local:8123")?.absoluteString,
                       "ws://homeassistant.local:8123/api/websocket")
        XCTAssertEqual(HAURL.websocketURL(from: "  http://ha.local:8123/  ")?.absoluteString,
                       "ws://ha.local:8123/api/websocket")
    }

    func testAlreadyWebSocketURLsPassThrough() {
        XCTAssertEqual(HAURL.websocketURL(from: "ws://ha.local:8123/api/websocket")?.absoluteString,
                       "ws://ha.local:8123/api/websocket")
    }

    func testEmptyOrHostlessInputIsRejected() {
        XCTAssertNil(HAURL.websocketURL(from: ""))
        XCTAssertNil(HAURL.websocketURL(from: "   "))
        XCTAssertNil(HAURL.websocketURL(from: "http://"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter HAURLTests`
Expected: FAIL — `cannot find 'HAURL' in scope`.

- [ ] **Step 3: Implement HAURL**

`Sources/HomesteadCore/HAURL.swift`:

```swift
import Foundation

/// Turns what someone types in the Connection window into the WebSocket URL.
public enum HAURL {
    public static func websocketURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty else {
            return nil
        }

        switch components.scheme {
        case "https", "wss": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        components.path = "/api/websocket"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter HAURLTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Write the failing reconnect-policy test**

`Tests/HomesteadCoreTests/ReconnectPolicyTests.swift`:

```swift
import XCTest
@testable import HomesteadCore

final class ReconnectPolicyTests: XCTestCase {
    func testBackoffDoublesThenHoldsAtThirtySeconds() {
        XCTAssertEqual([0, 1, 2, 3, 4, 5, 6, 20].map(ReconnectPolicy.delay(attempt:)),
                       [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testNegativeAttemptIsTreatedAsTheFirst() {
        XCTAssertEqual(ReconnectPolicy.delay(attempt: -3), 1)
    }
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `swift test --filter ReconnectPolicyTests`
Expected: FAIL — `cannot find 'ReconnectPolicy' in scope`.

- [ ] **Step 7: Implement ReconnectPolicy**

`Sources/HomesteadCore/ReconnectPolicy.swift`:

```swift
import Foundation

/// How long to wait before retry number `attempt` (0-based). Doubling from one
/// second, capped at thirty: a Mullvad connection can hide the server for
/// hours, and polling it every second for that long is pure noise.
public enum ReconnectPolicy {
    public static let maximumDelay: TimeInterval = 30

    public static func delay(attempt: Int) -> TimeInterval {
        let clamped = max(attempt, 0)
        guard clamped < 6 else { return maximumDelay }
        return min(pow(2, Double(clamped)), maximumDelay)
    }
}
```

- [ ] **Step 8: Run it to verify it passes**

Run: `swift test --filter ReconnectPolicyTests`
Expected: PASS (2 tests).

- [ ] **Step 9: Write the failing client test**

`Tests/HomesteadCoreTests/HAClientTests.swift`:

```swift
import XCTest
@testable import HomesteadCore

/// A scripted transport: the test queues the frames the "server" sends and
/// inspects what the client sent.
private final class FakeTransport: HATransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private(set) var sent: [String] = []
    private(set) var isClosed = false

    /// Frames the server sends unprompted (the auth handshake).
    init(initial: [String] = []) { inbound = initial }

    /// Called by the test to push a frame to the client.
    func push(_ text: String) {
        lock.lock()
        if waiters.isEmpty {
            inbound.append(text)
            lock.unlock()
        } else {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: text)
        }
    }

    /// The last command the client sent, decoded.
    func lastSent() throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        return try JSONValue.parse(Data(sent[sent.count - 1].utf8))
    }

    func connect(to url: URL) async throws {}

    func send(_ text: String) async throws {
        lock.lock(); sent.append(text); lock.unlock()
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if inbound.isEmpty {
                waiters.append(continuation)
                lock.unlock()
            } else {
                let next = inbound.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
            }
        }
    }

    func close() {
        lock.lock(); isClosed = true; lock.unlock()
    }
}

final class HAClientTests: XCTestCase {
    private let url = URL(string: "ws://ha.local:8123/api/websocket")!

    func testConnectSendsTheTokenAfterAuthRequired() async throws {
        let transport = FakeTransport(initial: [#"{"type":"auth_required"}"#, #"{"type":"auth_ok"}"#])
        let client = HAClient(transport: transport)

        try await client.connect(url: url, token: "secret-token")

        let auth = try JSONValue.parse(Data(transport.sent[0].utf8))
        XCTAssertEqual(auth["type"]?.string, "auth")
        XCTAssertEqual(auth["access_token"]?.string, "secret-token")
    }

    func testConnectThrowsOnAuthInvalid() async throws {
        let transport = FakeTransport(initial: [
            #"{"type":"auth_required"}"#,
            #"{"type":"auth_invalid","message":"Invalid access token"}"#,
        ])
        let client = HAClient(transport: transport)

        do {
            try await client.connect(url: url, token: "wrong")
            XCTFail("expected authInvalid")
        } catch {
            XCTAssertEqual(error as? HAClientError, .authInvalid("Invalid access token"))
        }
    }

    func testSendCorrelatesRepliesByIdOutOfOrder() async throws {
        let transport = FakeTransport(initial: [#"{"type":"auth_required"}"#, #"{"type":"auth_ok"}"#])
        let client = HAClient(transport: transport)
        try await client.connect(url: url, token: "t")

        async let first = client.send(["type": .string("lovelace/dashboards/list")])
        async let second = client.send(["type": .string("lovelace/config")])

        // Reply to the second command first; each caller must still get its own.
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.push(#"{"id":2,"type":"result","success":true,"result":{"views":[]}}"#)
        transport.push(#"{"id":1,"type":"result","success":true,"result":[{"title":"My Home"}]}"#)

        let listResult = try await first
        let configResult = try await second
        XCTAssertEqual(listResult.array?.first?["title"]?.string, "My Home")
        XCTAssertNotNil(configResult["views"])
    }

    func testFailedCommandThrowsTheServersError() async throws {
        let transport = FakeTransport(initial: [#"{"type":"auth_required"}"#, #"{"type":"auth_ok"}"#])
        let client = HAClient(transport: transport)
        try await client.connect(url: url, token: "t")

        async let reply = client.send(["type": .string("lovelace/config")])
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.push(#"{"id":1,"type":"result","success":false,"error":{"code":"config_not_found","message":"no"}}"#)

        do {
            _ = try await reply
            XCTFail("expected a command error")
        } catch {
            XCTAssertEqual(error as? HAClientError, .command(HAError(code: "config_not_found", message: "no")))
        }
    }

    func testSubscriptionDeliversEveryEventForItsId() async throws {
        let transport = FakeTransport(initial: [#"{"type":"auth_required"}"#, #"{"type":"auth_ok"}"#])
        let client = HAClient(transport: transport)
        try await client.connect(url: url, token: "t")

        let received = Received()
        async let subscriptionId = client.subscribe(
            ["type": .string("subscribe_entities"), "entity_ids": .array([.string("light.desk")])],
            onEvent: { received.append($0) }
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.push(#"{"id":1,"type":"result","success":true,"result":null}"#)
        _ = try await subscriptionId

        transport.push(#"{"id":1,"type":"event","event":{"a":{"light.desk":{"s":"on"}}}}"#)
        transport.push(#"{"id":1,"type":"event","event":{"c":{"light.desk":{"+":{"s":"off"}}}}}"#)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(received.values.count, 2)
        XCTAssertEqual(received.values[0]["a"]?["light.desk"]?["s"]?.string, "on")
        XCTAssertEqual(received.values[1]["c"]?["light.desk"]?["+"]?["s"]?.string, "off")
    }

    func testDisconnectClosesTheTransport() async throws {
        let transport = FakeTransport(initial: [#"{"type":"auth_required"}"#, #"{"type":"auth_ok"}"#])
        let client = HAClient(transport: transport)
        try await client.connect(url: url, token: "t")

        await client.disconnect()
        XCTAssertTrue(transport.isClosed)
    }
}

/// Thread-safe collector for events delivered on the client's reader task.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [JSONValue] = []

    var values: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ value: JSONValue) {
        lock.lock(); storage.append(value); lock.unlock()
    }
}
```

- [ ] **Step 10: Run it to verify it fails**

Run: `swift test --filter HAClientTests`
Expected: FAIL — `cannot find 'HAClient' in scope`.

- [ ] **Step 11: Implement the transport and the client**

`Sources/HomesteadCore/HATransport.swift`:

```swift
import Foundation

/// The byte pipe under `HAClient`. Injected so the protocol logic can be
/// tested against scripted frames instead of a live Home Assistant.
public protocol HATransport: AnyObject, Sendable {
    func connect(to url: URL) async throws
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

public final class URLSessionTransport: HATransport, @unchecked Sendable {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(to url: URL) async throws {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
    }

    public func send(_ text: String) async throws {
        guard let task else { throw HAClientError.notConnected }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        guard let task else { throw HAClientError.notConnected }
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
```

`Sources/HomesteadCore/HAClient.swift`:

```swift
import Foundation

public enum HAClientError: Error, Equatable {
    case authInvalid(String)
    case command(HAError)
    case closed
    case notConnected
}

/// Speaks the Home Assistant WebSocket API: one auth handshake, then commands
/// correlated by id and subscriptions that keep delivering events under the id
/// they were created with.
public actor HAClient {
    private let transport: HATransport
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var subscriptions: [Int: @Sendable (JSONValue) -> Void] = [:]
    private var readerTask: Task<Void, Never>?
    private var onClose: (@Sendable (String) -> Void)?

    public init(transport: HATransport) {
        self.transport = transport
    }

    /// Called when the socket drops for any reason other than `disconnect()`.
    public func setOnClose(_ handler: @escaping @Sendable (String) -> Void) {
        onClose = handler
    }

    public func connect(url: URL, token: String) async throws {
        try await transport.connect(to: url)

        // The handshake is read inline: no reader task runs yet, so these three
        // frames cannot race with command replies.
        while true {
            let message = try HAMessage.decode(try await transport.receive())
            switch message {
            case .authRequired:
                try await transport.send(String(decoding: try JSONValue.object([
                    "type": .string("auth"),
                    "access_token": .string(token),
                ]).encodedData(), as: UTF8.self))
            case .authOK:
                startReader()
                return
            case .authInvalid(let reason):
                transport.close()
                throw HAClientError.authInvalid(reason)
            default:
                continue
            }
        }
    }

    public func disconnect() {
        readerTask?.cancel()
        readerTask = nil
        onClose = nil
        failAllPending(with: HAClientError.closed)
        subscriptions.removeAll()
        transport.close()
    }

    /// Send a command and wait for its `result`.
    @discardableResult
    public func send(_ payload: [String: JSONValue]) async throws -> JSONValue {
        let id = claimId()
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await write(payload, id: id)
                } catch {
                    resume(id: id, with: .failure(error))
                }
            }
        }
    }

    /// Subscribe; `onEvent` runs for every event frame carrying this id.
    /// - Returns: the subscription id, for `unsubscribe`.
    @discardableResult
    public func subscribe(_ payload: [String: JSONValue],
                          onEvent: @escaping @Sendable (JSONValue) -> Void) async throws -> Int {
        let id = claimId()
        subscriptions[id] = onEvent
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                pending[id] = continuation
                Task {
                    do {
                        try await write(payload, id: id)
                    } catch {
                        resume(id: id, with: .failure(error))
                    }
                }
            }
        } catch {
            subscriptions.removeValue(forKey: id)
            throw error
        }
        return id
    }

    public func unsubscribe(_ subscriptionId: Int) async {
        subscriptions.removeValue(forKey: subscriptionId)
        _ = try? await send([
            "type": .string("unsubscribe_events"),
            "subscription": .number(Double(subscriptionId)),
        ])
    }

    // MARK: - Internals

    private func claimId() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    private func write(_ payload: [String: JSONValue], id: Int) async throws {
        var body = payload
        body["id"] = .number(Double(id))
        let text = String(decoding: try JSONValue.object(body).encodedData(), as: UTF8.self)
        try await transport.send(text)
    }

    private func startReader() {
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let text = try await self.transport.receive()
                    await self.handle(text)
                } catch {
                    await self.handleClose(reason: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = try? HAMessage.decode(text) else { return }
        switch message {
        case .result(let id, let success, let result, let error):
            if success {
                resume(id: id, with: .success(result ?? .null))
            } else {
                resume(id: id, with: .failure(HAClientError.command(error ?? HAError(code: "unknown", message: ""))))
            }
        case .event(let id, let event):
            subscriptions[id]?(event)
        default:
            break
        }
    }

    private func handleClose(reason: String) {
        failAllPending(with: HAClientError.closed)
        subscriptions.removeAll()
        let handler = onClose
        handler?(reason)
    }

    private func resume(id: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failAllPending(with error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }
}
```

- [ ] **Step 12: Run the client tests**

Run: `swift test --filter HAClientTests`
Expected: PASS (6 tests). If a test hangs, the reader task is not routing by id — check `handle(_:)` before changing the test.

- [ ] **Step 13: Run the full suite**

Run: `swift test`
Expected: PASS (all tests).

- [ ] **Step 14: Commit**

```bash
git add Sources/HomesteadCore Tests/HomesteadCoreTests
git commit -m "feat: Home Assistant WebSocket client with reconnect policy"
```

---

### Task 6: App scaffold — status item, settings, unconfigured menu, build scripts

**Files:**
- Create: `Sources/HomesteadCore/Settings.swift`
- Create: `Sources/Homestead/main.swift` (replaces the Task 1 placeholder)
- Create: `Resources/Info.plist`
- Create: `scripts/build-app.sh`
- Create: `install.sh`
- Test: `Tests/HomesteadCoreTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `DashboardListing` (Task 2), StatusItemKit's `StatusItemController`, `YieldClient`, `LoginItem`, `MeterAppearance`, `AppearanceMenu`.
- Produces:
  - `final class Settings` with `init(defaults: UserDefaults = .standard)`, `var haURL: String?`, `var selectedDashboardPath: String?` (empty string = Overview, `nil` = never chosen), `var showSensors: Bool`, and `func defaultDashboard(from listings: [DashboardListing]) -> DashboardListing?`.
  - `final class App: NSObject, NSApplicationDelegate` in `main.swift` — the app delegate later tasks extend.

- [ ] **Step 1: Write the failing settings test**

`Tests/HomesteadCoreTests/SettingsTests.swift`:

```swift
import XCTest
@testable import HomesteadCore

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.nicholaspsmith.Homestead.tests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testShowSensorsDefaultsToOff() {
        XCTAssertFalse(Settings(defaults: defaults).showSensors)
    }

    func testValuesRoundTrip() {
        let settings = Settings(defaults: defaults)
        settings.haURL = "http://homeassistant.local:8123"
        settings.selectedDashboardPath = "my-home"
        settings.showSensors = true

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.haURL, "http://homeassistant.local:8123")
        XCTAssertEqual(reloaded.selectedDashboardPath, "my-home")
        XCTAssertTrue(reloaded.showSensors)
    }

    func testEmptyURLReadsAsUnconfigured() {
        let settings = Settings(defaults: defaults)
        settings.haURL = "   "
        XCTAssertNil(Settings(defaults: defaults).haURL)
    }

    func testDefaultDashboardPrefersMyHomeWhenNothingChosen() {
        let listings = [
            DashboardListing(urlPath: nil, title: "Overview"),
            DashboardListing(urlPath: "garden", title: "Garden"),
            DashboardListing(urlPath: "my-home", title: "My Home"),
        ]
        XCTAssertEqual(Settings(defaults: defaults).defaultDashboard(from: listings)?.urlPath, "my-home")
    }

    func testDefaultDashboardFallsBackToTheFirstListing() {
        let listings = [
            DashboardListing(urlPath: nil, title: "Overview"),
            DashboardListing(urlPath: "garden", title: "Garden"),
        ]
        XCTAssertEqual(Settings(defaults: defaults).defaultDashboard(from: listings)?.title, "Overview")
    }

    func testRememberedDashboardWinsOverMyHome() {
        let settings = Settings(defaults: defaults)
        settings.selectedDashboardPath = "garden"
        let listings = [
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: "garden", title: "Garden"),
        ]
        XCTAssertEqual(settings.defaultDashboard(from: listings)?.urlPath, "garden")
    }

    func testRememberedDashboardThatNoLongerExistsFallsBack() {
        let settings = Settings(defaults: defaults)
        settings.selectedDashboardPath = "deleted"
        let listings = [DashboardListing(urlPath: "my-home", title: "My Home")]
        XCTAssertEqual(settings.defaultDashboard(from: listings)?.urlPath, "my-home")
    }

    func testOverviewIsRememberedAsTheEmptyPath() {
        let settings = Settings(defaults: defaults)
        settings.selectedDashboardPath = ""
        let listings = [
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: nil, title: "Overview"),
        ]
        XCTAssertEqual(settings.defaultDashboard(from: listings)?.title, "Overview")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter SettingsTests`
Expected: FAIL — `cannot find 'Settings' in scope`.

- [ ] **Step 3: Implement Settings**

`Sources/HomesteadCore/Settings.swift`:

```swift
import Foundation

/// Everything the app remembers except the token, which lives in the Keychain.
public final class Settings {
    public enum Key {
        public static let haURL = "HAURL"
        public static let selectedDashboard = "SelectedDashboard"
        public static let showSensors = "ShowSensors"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The server address as typed. Nil when unset or blank — both mean
    /// "unconfigured", so the menu has one case to handle, not two.
    public var haURL: String? {
        get {
            let stored = defaults.string(forKey: Key.haURL)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty ?? true) ? nil : stored
        }
        set { defaults.set(newValue, forKey: Key.haURL) }
    }

    /// The remembered dashboard: a `url_path`, or `""` for the built-in
    /// Overview (whose path is nil), or nil when nothing has been chosen yet.
    public var selectedDashboardPath: String? {
        get { defaults.string(forKey: Key.selectedDashboard) }
        set { defaults.set(newValue, forKey: Key.selectedDashboard) }
    }

    public var showSensors: Bool {
        get { defaults.bool(forKey: Key.showSensors) }
        set { defaults.set(newValue, forKey: Key.showSensors) }
    }

    /// Which dashboard to open with: the remembered one if it still exists,
    /// else "My Home", else whatever is first.
    public func defaultDashboard(from listings: [DashboardListing]) -> DashboardListing? {
        if let remembered = selectedDashboardPath,
           let match = listings.first(where: { ($0.urlPath ?? "") == remembered }) {
            return match
        }
        return listings.first { $0.title == "My Home" } ?? listings.first
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter SettingsTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Write the app scaffold**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Homestead</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.nicholaspsmith.Homestead</string>
	<key>CFBundleName</key>
	<string>Homestead</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
```

`Sources/Homestead/main.swift`:

```swift
import AppKit
import HomesteadCore
import StatusItemKit
import os

let log = Logger(subsystem: "com.nicholaspsmith.Homestead", category: "app")

/// Homestead — Home Assistant devices in the menu bar. The dropdown's first row
/// picks a dashboard; the rest of it is that dashboard's devices.
@MainActor
final class App: NSObject, NSApplicationDelegate {
    private var status: StatusItemController!
    /// Steps this icon aside while Barn reveals its hidden block.
    private var yieldClient: YieldClient!
    let settings = Settings()
    /// The house is the default icon; Dot is the fallback for anyone who wants
    /// a plain status light. Neither varies with a fraction, so the
    /// proportional meters are not offered.
    private let appearance = MeterAppearance(defaultStyle: .character)
    private var appearanceMenu: AppearanceMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController(
            // Nothing is polled: state arrives on the socket. The timer is the
            // fallback that redraws the icon if a push is ever missed.
            pollInterval: 60,
            onPoll: { [weak self] in self?.refreshIcon() },
            onBuildMenu: { [weak self] menu in self?.buildMenu(menu) },
            autosaveName: "Homestead"
        )
        status.start()
        yieldClient = YieldClient(item: status)
        yieldClient.start()

        appearanceMenu = AppearanceMenu(appearance: appearance,
                                        styles: [.character, .dot],
                                        characterTitle: "House",
                                        onChange: { [weak self] in self?.refreshIcon() })
        refreshIcon()
    }

    // MARK: - Menu

    private func buildMenu(_ menu: NSMenu) {
        if settings.haURL == nil {
            let connect = NSMenuItem(title: "Connect to Home Assistant…",
                                     action: #selector(openConnection), keyEquivalent: "")
            connect.target = self
            menu.addItem(connect)
            menu.addItem(.separator())
        }
        addSettingsItems(to: menu)
    }

    func addSettingsItems(to menu: NSMenu) {
        let sensors = NSMenuItem(title: "Show Sensors", action: #selector(toggleSensors), keyEquivalent: "")
        sensors.target = self
        sensors.state = settings.showSensors ? .on : .off
        menu.addItem(sensors)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(appearanceMenu.menuItem())

        let connection = NSMenuItem(title: "Connection…", action: #selector(openConnection), keyEquivalent: "")
        connection.target = self
        menu.addItem(connection)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Homestead",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleSensors() {
        settings.showSensors.toggle()
    }

    @objc private func toggleLogin() {
        LoginItem.toggle()
    }

    /// Replaced in Task 7, once the Connection window exists.
    @objc func openConnection() {
        log.info("Connection window requested")
    }

    // MARK: - Icon

    /// Replaced in Task 10 by the house glyph.
    func refreshIcon() {
        status.setIcon(appearance.image(fraction: 0))
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

`scripts/build-app.sh`:

```bash
#!/bin/bash
# Build Homestead.app via the shared StatusItemKit bundler.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../StatusItemKit/scripts/make-app.sh Homestead "Homestead"
```

`install.sh`:

```bash
#!/usr/bin/env bash
# Build Homestead.app and symlink it into ~/Applications (rebuilds propagate;
# SMAppService accepts a symlink there for Start-at-Login).
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Homestead.app"

"$SRC_DIR/scripts/build-app.sh"

mkdir -p "$HOME/Applications"
ln -sfn "$SRC_DIR/build/$APP_NAME" "$HOME/Applications/$APP_NAME"
echo "Linked $HOME/Applications/$APP_NAME -> $SRC_DIR/build/$APP_NAME"

open "$HOME/Applications/$APP_NAME"

cat <<'EOF'

Homestead is now running in the menu bar.

First-run setup
  1. In Home Assistant: your profile ▸ Security ▸ Long-lived access tokens ▸
     "Create token". Copy it.
  2. Click the Homestead icon ▸ Connect to Home Assistant…
  3. Enter the server URL (e.g. http://homeassistant.local:8123), paste the
     token, press Test, then Save.
  4. Optional: menu ▸ Start at Login.

The token is stored in your login Keychain, never on disk in plain text.
EOF
```

- [ ] **Step 6: Make the scripts executable and build**

```bash
chmod +x scripts/build-app.sh install.sh
swift build
```

Expected: builds with no errors.

- [ ] **Step 7: Verify the app runs and shows an unconfigured menu**

```bash
./scripts/build-app.sh
open build/Homestead.app
```

Expected: an icon appears in the menu bar; clicking it shows "Connect to Home
Assistant…", Show Sensors, Start at Login, Icon ▸, Connection…, Quit Homestead.
Quit it from the menu before continuing.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Resources install.sh scripts Sources Tests
git commit -m "feat: app scaffold, settings, and build scripts"
```

---

### Task 7: Keychain storage and the Connection window

**Files:**
- Create: `Sources/Homestead/Keychain.swift`
- Create: `Sources/Homestead/ConnectionWindow.swift`
- Modify: `Sources/Homestead/main.swift` (replace `openConnection`)

**Interfaces:**
- Consumes: `Settings` (Task 6), `HAURL`, `HAClient`, `URLSessionTransport`, `HAClientError` (Task 5).
- Produces:
  - `enum Keychain { static func token() -> String?; static func setToken(_ token: String) throws; static func deleteToken() }` — service `com.nicholaspsmith.Homestead`, account `ha-token`.
  - `final class ConnectionWindowController: NSWindowController` with `init(settings: Settings, onSaved: @escaping () -> Void)` and `func show()`.

- [ ] **Step 1: Implement the Keychain wrapper**

`Sources/Homestead/Keychain.swift`:

```swift
import Foundation
import Security

/// The long-lived access token, in the login Keychain. Never UserDefaults: a
/// defaults plist is world-readable to anything running as this user, and the
/// token is full API access to the house.
enum Keychain {
    static let service = "com.nicholaspsmith.Homestead"
    static let account = "ha-token"

    enum Failure: Error {
        case status(OSStatus)
    }

    static func token() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    static func setToken(_ token: String) throws {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery()
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.status(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    static func deleteToken() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
```

- [ ] **Step 2: Implement the Connection window**

`Sources/Homestead/ConnectionWindow.swift`:

```swift
import AppKit
import HomesteadCore

/// URL + token, with a Test button that runs the real auth handshake — the
/// only way to tell a wrong token from an unreachable server before saving.
final class ConnectionWindowController: NSWindowController, NSWindowDelegate {
    private let settings: Settings
    private let onSaved: () -> Void

    private let urlField = NSTextField(string: "")
    private let tokenField = NSSecureTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(settings: Settings, onSaved: @escaping () -> Void) {
        self.settings = settings
        self.onSaved = onSaved

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Home Assistant Connection"
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        urlField.stringValue = settings.haURL ?? ""
        tokenField.stringValue = Keychain.token() ?? ""
        statusLabel.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let urlLabel = NSTextField(labelWithString: "Server URL")
        let tokenLabel = NSTextField(labelWithString: "Access Token")
        urlField.placeholderString = "http://homeassistant.local:8123"
        tokenField.placeholderString = "Long-lived access token"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let hint = NSTextField(wrappingLabelWithString:
            "Home Assistant ▸ your profile ▸ Security ▸ Long-lived access tokens ▸ Create token.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        testButton.target = self
        testButton.action = #selector(test)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"

        for view in [urlLabel, urlField, tokenLabel, tokenField, hint, statusLabel, testButton, saveButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            urlLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            urlLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            urlLabel.widthAnchor.constraint(equalToConstant: 100),
            urlField.leadingAnchor.constraint(equalTo: urlLabel.trailingAnchor, constant: 10),
            urlField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            urlField.centerYAnchor.constraint(equalTo: urlLabel.centerYAnchor),

            tokenLabel.leadingAnchor.constraint(equalTo: urlLabel.leadingAnchor),
            tokenLabel.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 14),
            tokenLabel.widthAnchor.constraint(equalTo: urlLabel.widthAnchor),
            tokenField.leadingAnchor.constraint(equalTo: urlField.leadingAnchor),
            tokenField.trailingAnchor.constraint(equalTo: urlField.trailingAnchor),
            tokenField.centerYAnchor.constraint(equalTo: tokenLabel.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: tokenField.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: tokenField.trailingAnchor),
            hint.topAnchor.constraint(equalTo: tokenField.bottomAnchor, constant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: testButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),

            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            testButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            testButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
    }

    @objc private func test() {
        guard let url = HAURL.websocketURL(from: urlField.stringValue) else {
            return report("Enter a server URL, e.g. http://homeassistant.local:8123", ok: false)
        }
        let token = tokenField.stringValue
        guard !token.isEmpty else { return report("Paste an access token.", ok: false) }

        testButton.isEnabled = false
        report("Connecting…", ok: true)

        Task { @MainActor in
            let client = HAClient(transport: URLSessionTransport())
            do {
                try await client.connect(url: url, token: token)
                await client.disconnect()
                report("Connected.", ok: true)
            } catch HAClientError.authInvalid {
                report("Token rejected.", ok: false)
            } catch {
                report("Unreachable: \(error.localizedDescription)", ok: false)
            }
            testButton.isEnabled = true
        }
    }

    @objc private func save() {
        guard HAURL.websocketURL(from: urlField.stringValue) != nil else {
            return report("Enter a server URL, e.g. http://homeassistant.local:8123", ok: false)
        }
        settings.haURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Keychain.setToken(tokenField.stringValue)
        } catch {
            return report("Could not save the token to the Keychain.", ok: false)
        }
        onSaved()
        window?.close()
    }

    private func report(_ message: String, ok: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = ok ? .secondaryLabelColor : .systemRed
    }
}
```

- [ ] **Step 3: Wire the window into the app delegate**

In `Sources/Homestead/main.swift`, add a stored property beside `appearanceMenu`:

```swift
    private var connectionWindow: ConnectionWindowController?
```

and replace the placeholder `openConnection` with:

```swift
    @objc func openConnection() {
        if connectionWindow == nil {
            connectionWindow = ConnectionWindowController(settings: settings) { [weak self] in
                self?.connectionSaved()
            }
        }
        connectionWindow?.show()
    }

    /// Replaced in Task 8, where saving reconnects the client.
    func connectionSaved() {
        log.info("connection settings saved")
    }
```

- [ ] **Step 4: Build and verify the window**

```bash
swift build && ./scripts/build-app.sh && open build/Homestead.app
```

Expected: menu ▸ "Connect to Home Assistant…" opens a window with URL, token,
Test, Save. Enter the real URL and paste a token; **Test** reports "Connected."
Deliberately mistype the token and confirm it reports "Token rejected." Save
with the correct values, then check the token landed in the Keychain and the URL
did not land in defaults:

```bash
security find-generic-password -s com.nicholaspsmith.Homestead -a ha-token >/dev/null && echo "token stored"
defaults read com.nicholaspsmith.Homestead
```

Expected: "token stored", and the defaults dump shows `HAURL` but **no token**.
Quit the app from its menu.

- [ ] **Step 5: Commit**

```bash
git add Sources/Homestead
git commit -m "feat: keychain-backed token and connection window"
```

---

### Task 8: AppModel — connect, load, subscribe, reconnect

**Files:**
- Create: `Sources/Homestead/AppModel.swift`
- Modify: `Sources/Homestead/main.swift` (own an `AppModel`, react to its changes)

**Interfaces:**
- Consumes: `HAClient`, `URLSessionTransport`, `HAClientError`, `ReconnectPolicy`, `HAURL` (Task 5); `DashboardListing`, `DashboardParser` (Task 2); `StateStore` (Task 3); `DeviceCatalog`, `ServiceCall` (Task 4); `Settings` (Task 6); `Keychain` (Task 7).
- Produces:
  - `enum ConnectionState: Equatable { case unconfigured, connecting, connected, unreachable(String), authFailed }`
  - `struct Snapshot { let connection: ConnectionState; let dashboards: [DashboardListing]; let selected: DashboardListing?; let groups: [DeviceGroup]; let states: [String: EntityState] }`
  - `@MainActor final class AppModel` with `init(settings: Settings)`, `private(set) var snapshot: Snapshot`, `var onSnapshotChange: ((Snapshot) -> Void)?`, `var onEntitiesChanged: ((Set<String>) -> Void)?`, `func start()`, `func reloadConfiguration()`, `func retryNow()`, `func select(dashboard: DashboardListing)`, `func setShowSensors(_ on: Bool)`, `func toggle(_ device: Device, on: Bool)`, `func setLevel(_ device: Device, fraction: Double)`, `func state(for entityId: String) -> EntityState?`.

- [ ] **Step 1: Implement AppModel**

`Sources/Homestead/AppModel.swift`:

```swift
import AppKit
import HomesteadCore
import Network
import os

enum ConnectionState: Equatable {
    case unconfigured
    case connecting
    case connected
    case unreachable(String)
    case authFailed
}

/// Everything the menu and the icon draw from.
struct Snapshot {
    var connection: ConnectionState = .unconfigured
    var dashboards: [DashboardListing] = []
    var selected: DashboardListing?
    var groups: [DeviceGroup] = []
    var states: [String: EntityState] = [:]

    var lightsOn: Int {
        groups.flatMap(\.devices)
            .filter { $0.kind == .light }
            .filter { states[$0.entityId]?.isOn == true }
            .count
    }

    var anyFanOn: Bool {
        groups.flatMap(\.devices)
            .contains { $0.kind == .fan && states[$0.entityId]?.isOn == true }
    }
}

/// Owns the connection and the state behind the menu: connect, list
/// dashboards, load the selected one's config, subscribe to exactly its
/// entities, and keep all of that current across drops.
@MainActor
final class AppModel {
    private let settings: Settings
    private let log = Logger(subsystem: "com.nicholaspsmith.Homestead", category: "model")

    private var client: HAClient?
    private var store = StateStore()
    private var refs: [DeviceRef] = []
    private var subscriptionId: Int?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// Per-entity in-flight level call, so a drag sends one call at a time.
    private var levelInFlight: Set<String> = []
    private var levelQueued: [String: Double] = [:]

    private(set) var snapshot = Snapshot()
    var onSnapshotChange: ((Snapshot) -> Void)?
    var onEntitiesChanged: ((Set<String>) -> Void)?

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        startPathMonitor()
        reloadConfiguration()
    }

    /// Called at launch and whenever the Connection window saves.
    func reloadConfiguration() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        Task { await teardown() }

        guard let urlText = settings.haURL, let url = HAURL.websocketURL(from: urlText),
              let token = Keychain.token()
        else {
            update { $0.connection = .unconfigured }
            return
        }
        connect(url: url, token: token)
    }

    func retryNow() {
        reconnectAttempt = 0
        reloadConfiguration()
    }

    func select(dashboard: DashboardListing) {
        settings.selectedDashboardPath = dashboard.urlPath ?? ""
        update { $0.selected = dashboard }
        Task { await loadDashboardLoggingErrors(dashboard) }
    }

    func setShowSensors(_ on: Bool) {
        settings.showSensors = on
        rebuildGroups()
    }

    func state(for entityId: String) -> EntityState? { store[entityId] }

    // MARK: - Actions

    func toggle(_ device: Device, on: Bool) {
        guard let call = ServiceCall.toggle(device, on: on) else { return }
        Task { await perform(call, revertEntity: device.entityId) }
    }

    /// Slider drags fire continuously; at most one call per entity is in flight
    /// and only the newest value waits behind it, so a drag cannot queue fifty
    /// stale commands.
    func setLevel(_ device: Device, fraction: Double) {
        guard ServiceCall.setLevel(device, fraction: fraction, state: store[device.entityId]) != nil else { return }
        if levelInFlight.contains(device.entityId) {
            levelQueued[device.entityId] = fraction
            return
        }
        levelInFlight.insert(device.entityId)
        Task { await sendLevel(device, fraction: fraction) }
    }

    private func sendLevel(_ device: Device, fraction: Double) async {
        defer {
            if let next = levelQueued.removeValue(forKey: device.entityId) {
                Task { await sendLevel(device, fraction: next) }
            } else {
                levelInFlight.remove(device.entityId)
            }
        }
        guard let call = ServiceCall.setLevel(device, fraction: fraction, state: store[device.entityId]) else { return }
        await perform(call, revertEntity: nil)
    }

    private func perform(_ call: ServiceCall, revertEntity: String?) async {
        guard let client else { return }
        do {
            _ = try await client.send(call.commandPayload)
        } catch {
            log.error("\(call.domain).\(call.service) failed: \(String(describing: error), privacy: .public)")
            // Optimistic UI: put the row back the way HA still has it.
            if let revertEntity { onEntitiesChanged?([revertEntity]) }
        }
    }

    // MARK: - Connection

    private func connect(url: URL, token: String) {
        update { $0.connection = .connecting }
        let client = HAClient(transport: URLSessionTransport())
        self.client = client

        Task {
            do {
                try await client.connect(url: url, token: token)
                await client.setOnClose { [weak self] reason in
                    Task { @MainActor in self?.handleDrop(reason: reason) }
                }
                reconnectAttempt = 0
                update { $0.connection = .connected }
                try await loadDashboards()
            } catch HAClientError.authInvalid {
                update { $0.connection = .authFailed }
            } catch {
                handleDrop(reason: error.localizedDescription)
            }
        }
    }

    private func loadDashboards() async throws {
        guard let client else { return }
        let result = try await client.send(["type": .string("lovelace/dashboards/list")])
        var listings = DashboardListing.list(from: result)
        guard var chosen = settings.defaultDashboard(from: listings) else { return }

        // A dashboard whose config cannot be read is not pickable; drop it and
        // fall through to the next candidate.
        while true {
            do {
                try await loadDashboard(chosen)
                break
            } catch {
                listings.removeAll { $0.urlPath == chosen.urlPath }
                update { $0.dashboards = listings }
                guard let next = listings.first else { return }
                chosen = next
            }
        }
        update {
            $0.dashboards = listings
            $0.selected = chosen
        }
    }

    /// Picker changes have nowhere to report a failure, so they log it instead.
    private func loadDashboardLoggingErrors(_ dashboard: DashboardListing) async {
        do {
            try await loadDashboard(dashboard)
        } catch {
            log.error("dashboard \(dashboard.title, privacy: .public) failed to load")
        }
    }

    private func loadDashboard(_ dashboard: DashboardListing) async throws {
        guard let client else { return }
        var payload: [String: JSONValue] = ["type": .string("lovelace/config")]
        if let urlPath = dashboard.urlPath { payload["url_path"] = .string(urlPath) }

        let config = try await client.send(payload)
        refs = DashboardParser.references(in: config)

        if let existing = subscriptionId {
            await client.unsubscribe(existing)
            subscriptionId = nil
        }
        store.reset()

        let ids = refs.map(\.entityId)
        guard !ids.isEmpty else {
            update { $0.groups = [] }
            return
        }
        subscriptionId = try await client.subscribe([
            "type": .string("subscribe_entities"),
            "entity_ids": .array(ids.map { .string($0) }),
        ], onEvent: { [weak self] event in
            Task { @MainActor in self?.applyEvent(event) }
        })
    }

    private func applyEvent(_ event: JSONValue) {
        let changed = store.apply(event)
        guard !changed.isEmpty else { return }
        snapshot.states = store.states

        // A kind can change with state (a cover that reports SET_POSITION only
        // once it is known), and names arrive with the first snapshot, so the
        // first event after a load rebuilds rather than patches.
        if snapshot.groups.isEmpty {
            rebuildGroups()
        } else {
            onEntitiesChanged?(changed)
        }
    }

    private func rebuildGroups() {
        snapshot.states = store.states
        snapshot.groups = DeviceCatalog.build(refs: refs, states: store.states, showSensors: settings.showSensors)
        onSnapshotChange?(snapshot)
    }

    private func handleDrop(reason: String) {
        client = nil
        subscriptionId = nil
        update { $0.connection = .unreachable(reason) }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delay = ReconnectPolicy.delay(attempt: reconnectAttempt)
        reconnectAttempt += 1
        log.info("reconnecting in \(delay, privacy: .public)s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.reconnectTask = nil
                self.reloadConfiguration()
            }
        }
    }

    /// Mullvad connecting or disconnecting kills or restores the Tailscale
    /// route to HA. Waiting out the backoff after a network change wastes up to
    /// thirty seconds when the server is already reachable again.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self else { return }
                if case .unreachable = self.snapshot.connection { self.retryNow() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.nicholaspsmith.Homestead.path"))
        pathMonitor = monitor
    }

    private func teardown() async {
        if let client { await client.disconnect() }
        client = nil
        subscriptionId = nil
        store.reset()
    }

    private func update(_ change: (inout Snapshot) -> Void) {
        change(&snapshot)
        onSnapshotChange?(snapshot)
    }
}
```

- [ ] **Step 2: Own the model in the app delegate**

In `Sources/Homestead/main.swift`, add beside the other properties:

```swift
    private(set) var model: AppModel!
```

At the end of `applicationDidFinishLaunching`, before `refreshIcon()`:

```swift
        model = AppModel(settings: settings)
        model.onSnapshotChange = { [weak self] _ in self?.refreshIcon() }
        model.start()
```

Replace `connectionSaved()` with:

```swift
    func connectionSaved() {
        model.reloadConfiguration()
    }
```

and make the sensors toggle go through the model:

```swift
    @objc private func toggleSensors() {
        model.setShowSensors(!settings.showSensors)
    }
```

- [ ] **Step 3: Build and verify the connection lifecycle**

```bash
swift build && ./scripts/build-app.sh && open build/Homestead.app
```

Then watch the log while the app runs:

```bash
log stream --predicate 'subsystem == "com.nicholaspsmith.Homestead"' --style compact
```

Expected: no error lines at launch with HA reachable. Connect Mullvad (which
kills the Tailscale route) and confirm a "reconnecting in Ns" line appears with
the delay doubling; disconnect Mullvad and confirm it reconnects within a couple
of seconds rather than waiting out the full backoff. Quit the app.

- [ ] **Step 4: Commit**

```bash
git add Sources/Homestead
git commit -m "feat: connection lifecycle, dashboard loading, and live state"
```

---

### Task 9: The menu — picker, device rows, sliders

**Files:**
- Create: `Sources/Homestead/DeviceRowView.swift`
- Create: `Sources/Homestead/LevelSliderView.swift`
- Create: `Sources/Homestead/MenuController.swift`
- Modify: `Sources/Homestead/main.swift` (delegate menu building to `MenuController`)

**Interfaces:**
- Consumes: `AppModel`, `Snapshot`, `ConnectionState` (Task 8); `Device`, `DeviceGroup`, `DeviceKind`, `LevelMath` (Task 4); `EntityState` (Task 3); `DashboardListing` (Task 2); `MenuBuilder` (StatusItemKit).
- Produces:
  - `final class DeviceRowView: NSView` — `init(device: Device, state: EntityState?, onToggle: @escaping (Bool) -> Void)`, `func update(state: EntityState?)`, `var switchIsOn: Bool`.
  - `final class LevelSliderView: NSView` — `init(kind: DeviceKind, fraction: Double, onChange: @escaping (Double) -> Void)`, `func update(fraction: Double)`.
  - `final class MenuController` — `init(model: AppModel, addSettingsItems: @escaping (NSMenu) -> Void)`, `func build(_ menu: NSMenu)`, `func apply(entities: Set<String>)`, `func rebuildIfOpen()`.

- [ ] **Step 1: Implement the row and slider views**

`Sources/Homestead/DeviceRowView.swift`:

```swift
import AppKit
import HomesteadCore

/// One device: name, its current value, and a switch. Lives in an NSMenuItem's
/// view, which is what lets a toggle act without dismissing the menu.
final class DeviceRowView: NSView {
    static let width: CGFloat = 280

    private let device: Device
    private let nameLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private let onToggle: (Bool) -> Void

    var switchIsOn: Bool { toggle.state == .on }

    init(device: Device, state: EntityState?, onToggle: @escaping (Bool) -> Void) {
        self.device = device
        self.onToggle = onToggle
        nameLabel = NSTextField(labelWithString: device.displayName)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 26))

        nameLabel.font = .menuFont(ofSize: 0)
        nameLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(flipped)
        toggle.isHidden = !device.kind.hasSwitch

        for view in [nameLabel, valueLabel, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.trailingAnchor.constraint(
                equalTo: device.kind.hasSwitch ? toggle.leadingAnchor : trailingAnchor,
                constant: device.kind.hasSwitch ? -8 : -14),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
        ])

        update(state: state)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: EntityState?) {
        let available = state?.isAvailable ?? false
        toggle.isEnabled = available
        toggle.state = (state?.isOn ?? false) ? .on : .off
        nameLabel.textColor = available ? .labelColor : .tertiaryLabelColor
        valueLabel.stringValue = available ? Self.valueText(device: device, state: state) : "Unavailable"
    }

    static func valueText(device: Device, state: EntityState?) -> String {
        guard let state else { return "" }
        switch device.kind {
        case .light:
            guard state.isOn else { return "" }
            return "\(LevelMath.brightnessPct(from: LevelMath.fraction(brightness: state.attributes["brightness"])))%"
        case .fan:
            guard state.isOn else { return "" }
            return "\(Int((LevelMath.fraction(percentage: state.attributes["percentage"]) * 100).rounded()))%"
        case .cover(let positionable):
            let name = state.state.prefix(1).uppercased() + state.state.dropFirst()
            guard positionable, let position = state.attributes["current_position"]?.int else { return name }
            return "\(name) · \(position)%"
        case .toggle:
            return ""
        case .sensor:
            let unit = state.unit.map { " \($0)" } ?? ""
            switch state.state {
            case "on": return "On"
            case "off": return "Off"
            default: return state.state + unit
            }
        }
    }

    @objc private func flipped() {
        onToggle(toggle.state == .on)
    }
}
```

`Sources/Homestead/LevelSliderView.swift`:

```swift
import AppKit
import HomesteadCore

/// The slider that appears under a device while it is on. Modelled on
/// KeyLight's backlight slider: continuous, and deaf to external updates while
/// it is being dragged.
final class LevelSliderView: NSView {
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let onChange: (Double) -> Void

    init(kind: DeviceKind, fraction: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 24))

        slider.isContinuous = true
        slider.controlSize = .small
        slider.doubleValue = fraction
        slider.target = self
        slider.action = #selector(slid)

        let (lowName, highName) = Self.symbols(for: kind)
        let low = NSImageView(image: NSImage(systemSymbolName: lowName, accessibilityDescription: nil) ?? NSImage())
        let high = NSImageView(image: NSImage(systemSymbolName: highName, accessibilityDescription: nil) ?? NSImage())
        low.contentTintColor = .secondaryLabelColor
        high.contentTintColor = .secondaryLabelColor

        for view in [low, high, slider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            low.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            low.centerYAnchor.constraint(equalTo: centerYAnchor),
            low.widthAnchor.constraint(equalToConstant: 14),
            high.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            high.centerYAnchor.constraint(equalTo: centerYAnchor),
            high.widthAnchor.constraint(equalToConstant: 14),
            slider.leadingAnchor.constraint(equalTo: low.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: high.leadingAnchor, constant: -6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reflect a change made elsewhere — unless this slider is the thing being
    /// changed, in which case the drag wins.
    func update(fraction: Double) {
        guard !slider.isHighlighted else { return }
        slider.doubleValue = fraction
    }

    private static func symbols(for kind: DeviceKind) -> (String, String) {
        switch kind {
        case .fan: return ("wind", "fanblades")
        case .cover: return ("blinds.horizontal.closed", "blinds.horizontal.open")
        default: return ("light.min", "light.max")
        }
    }

    @objc private func slid() {
        onChange(slider.doubleValue)
    }
}
```

- [ ] **Step 2: Implement MenuController**

`Sources/Homestead/MenuController.swift`:

```swift
import AppKit
import HomesteadCore

/// Builds the dropdown and keeps it honest while it is open. Rows are
/// view-based so toggling and dragging do not dismiss the menu; each device's
/// slider is a second item created up front and hidden until the device is on
/// (verified: an open NSMenu re-lays out when an item's `isHidden` changes).
///
/// `@MainActor` because it reads `AppModel`, which is main-actor isolated — and
/// because everything here is AppKit anyway.
@MainActor
final class MenuController: NSObject {
    private let model: AppModel
    private let addSettingsItems: (NSMenu) -> Void

    private weak var menu: NSMenu?
    private var rows: [String: (item: NSMenuItem, view: DeviceRowView)] = [:]
    private var sliders: [String: (item: NSMenuItem, view: LevelSliderView)] = [:]
    private var devices: [String: Device] = [:]
    private var picker: NSPopUpButton?

    init(model: AppModel, addSettingsItems: @escaping (NSMenu) -> Void) {
        self.model = model
        self.addSettingsItems = addSettingsItems
        super.init()
    }

    // MARK: - Building

    func build(_ menu: NSMenu) {
        self.menu = menu
        rows.removeAll()
        sliders.removeAll()
        devices.removeAll()
        picker = nil

        let snapshot = model.snapshot

        if snapshot.connection == .unconfigured {
            let connect = NSMenuItem(title: "Connect to Home Assistant…", action: nil, keyEquivalent: "")
            connect.target = self
            connect.action = #selector(openConnection)
            menu.addItem(connect)
            menu.addItem(.separator())
            addSettingsItems(menu)
            return
        }

        addPicker(to: menu, snapshot: snapshot)
        addStatusRow(to: menu, snapshot: snapshot)

        if snapshot.groups.isEmpty, snapshot.connection == .connected {
            let empty = NSMenuItem(title: "No controllable devices on this dashboard",
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for group in snapshot.groups {
            let header = NSMenuItem(title: group.title.uppercased(), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for device in group.devices {
                devices[device.entityId] = device
                let state = snapshot.states[device.entityId]

                let rowItem = NSMenuItem()
                let rowView = DeviceRowView(device: device, state: state) { [weak self] on in
                    self?.toggled(device, on: on)
                }
                rowItem.view = rowView
                menu.addItem(rowItem)
                rows[device.entityId] = (rowItem, rowView)

                guard device.kind.hasSlider else { continue }
                let sliderItem = NSMenuItem()
                let sliderView = LevelSliderView(kind: device.kind, fraction: Self.fraction(device: device, state: state)) { [weak self] value in
                    self?.model.setLevel(device, fraction: value)
                }
                sliderItem.view = sliderView
                sliderItem.isHidden = !(state?.isOn ?? false)
                menu.addItem(sliderItem)
                sliders[device.entityId] = (sliderItem, sliderView)
            }
        }

        menu.addItem(.separator())
        addSettingsItems(menu)
    }

    private func addPicker(to menu: NSMenu, snapshot: Snapshot) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 30))
        let button = NSPopUpButton(frame: NSRect(x: 12, y: 3, width: DeviceRowView.width - 24, height: 24))
        button.addItems(withTitles: snapshot.dashboards.map(\.title))
        if let selected = snapshot.selected,
           let index = snapshot.dashboards.firstIndex(where: { $0.urlPath == selected.urlPath }) {
            button.selectItem(at: index)
        }
        button.target = self
        button.action = #selector(dashboardChanged)
        button.isEnabled = !snapshot.dashboards.isEmpty
        container.addSubview(button)

        let item = NSMenuItem()
        item.view = container
        menu.addItem(item)
        picker = button
    }

    private func addStatusRow(to menu: NSMenu, snapshot: Snapshot) {
        let text: String?
        switch snapshot.connection {
        case .connected, .unconfigured: text = nil
        case .connecting: text = "Connecting…"
        case .unreachable: text = "Can't reach Home Assistant — retrying"
        case .authFailed: text = "Token rejected — open Connection…"
        }
        guard let text else { return }

        let item = NSMenuItem()
        item.view = MenuBuilderStatusView(text: text)
        item.isEnabled = false
        menu.addItem(item)

        if case .unreachable = snapshot.connection {
            let retry = NSMenuItem(title: "Retry Now", action: #selector(retry), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        menu.addItem(.separator())
    }

    // MARK: - Live updates

    /// Patch only the rows whose entities changed; rebuilding the whole menu
    /// under the cursor would fight whatever the user is doing in it.
    func apply(entities: Set<String>) {
        for entityId in entities {
            guard let device = devices[entityId] else { continue }
            let state = model.state(for: entityId)
            rows[entityId]?.view.update(state: state)

            guard let slider = sliders[entityId] else { continue }
            slider.item.isHidden = !(state?.isOn ?? false)
            slider.view.update(fraction: Self.fraction(device: device, state: state))
        }
    }

    /// The dashboard changed, or sensors were switched on: rebuild in place if
    /// the menu is on screen.
    func rebuildIfOpen() {
        guard let menu, menu.highlightedItem != nil || !menu.items.isEmpty else { return }
        menu.removeAllItems()
        build(menu)
    }

    private static func fraction(device: Device, state: EntityState?) -> Double {
        guard let state else { return 0 }
        switch device.kind {
        case .light: return LevelMath.fraction(brightness: state.attributes["brightness"])
        case .fan: return LevelMath.fraction(percentage: state.attributes["percentage"])
        case .cover: return LevelMath.fraction(percentage: state.attributes["current_position"])
        case .toggle, .sensor: return 0
        }
    }

    // MARK: - Actions

    private func toggled(_ device: Device, on: Bool) {
        model.toggle(device, on: on)
        // Show the slider immediately; the confirming state event follows.
        sliders[device.entityId]?.item.isHidden = !on
    }

    @objc private func dashboardChanged() {
        guard let index = picker?.indexOfSelectedItem,
              model.snapshot.dashboards.indices.contains(index) else { return }
        model.select(dashboard: model.snapshot.dashboards[index])
    }

    @objc private func retry() {
        model.retryNow()
    }

    @objc private func openConnection() {
        NSApp.sendAction(#selector(App.openConnection), to: nil, from: nil)
    }
}

/// A plain text row. NSMenu reserves trailing space for the keyboard-shortcut
/// column on title-based items, which makes a status line look off-centre; a
/// view escapes that.
private final class MenuBuilderStatusView: NSView {
    init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: DeviceRowView.width, height: 22))
        let label = NSTextField(labelWithString: text)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 3, width: DeviceRowView.width - 28, height: 16)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
```

- [ ] **Step 3: Hand menu building to MenuController**

In `Sources/Homestead/main.swift`:

- add `private var menuController: MenuController!` beside the other properties;
- create it right after `model` is built, before `model.start()`:

```swift
        menuController = MenuController(model: model, addSettingsItems: { [weak self] menu in
            self?.addSettingsItems(to: menu)
        })
        model.onSnapshotChange = { [weak self] _ in
            self?.refreshIcon()
            self?.menuController.rebuildIfOpen()
        }
        model.onEntitiesChanged = { [weak self] entities in
            self?.menuController.apply(entities: entities)
        }
```

- replace the body of `buildMenu(_:)` with:

```swift
    private func buildMenu(_ menu: NSMenu) {
        menuController.build(menu)
    }
```

- make `openConnection` non-private (`@objc func openConnection()`) so
  `NSApp.sendAction` can reach it, and make the sensors toggle rebuild:

```swift
    @objc private func toggleSensors() {
        model.setShowSensors(!settings.showSensors)
        menuController.rebuildIfOpen()
    }
```

- [ ] **Step 4: Build and verify the menu against real HA**

```bash
swift build && ./scripts/build-app.sh && open build/Homestead.app
```

Verify, in order:
1. The picker shows every dashboard and opens on "My Home".
2. A light's switch turns it on; the slider appears beneath it without the menu closing; dragging the slider dims the light.
3. Turning the light off hides the slider again.
4. Changing the same light from the Home Assistant web UI, with the menu open, moves the row's switch and value.
5. Switching the picker to another dashboard swaps the rows in place.
6. Show Sensors adds read-only sensor rows; unchecking removes them.
7. Connect Mullvad: the status row reads "Can't reach Home Assistant — retrying" and rows grey out. Disconnect: it recovers.

- [ ] **Step 5: Commit**

```bash
git add Sources/Homestead
git commit -m "feat: dashboard picker, device rows, and level sliders"
```

---

### Task 10: The house glyph

**Files:**
- Modify: `~/Code/StatusItemKit/Sources/StatusItemKit/CharacterIcon.swift` (separate repo, separate commit)
- Create: `Sources/Homestead/HouseIcon.swift`
- Modify: `Sources/Homestead/main.swift` (`refreshIcon`)
- Create: `Resources/bundle/AppIcon.icns`
- Create: `docs/menubar-icon.png` (generated)

**Interfaces:**
- Consumes: `Snapshot` (Task 8), `MeterAppearance`, `MeterIcon`, `MeterStyle` (StatusItemKit).
- Produces: `public static func house(lightsOn: Int, fanOn: Bool, reachable: Bool, configured: Bool) -> NSImage` on `CharacterIcon`; `enum HouseIcon { static func image(snapshot: Snapshot, appearance: MeterAppearance) -> NSImage }`.

- [ ] **Step 1: Add the house to CharacterIcon**

In `~/Code/StatusItemKit/Sources/StatusItemKit/CharacterIcon.swift`, append inside the enum:

```swift
    /// Homestead's house: the windows are the lights, the right one gets a fan
    /// when one is running. Deliberately chimney-free — a chimney reads as
    /// heating, which this app does not control.
    public static func house(lightsOn: Int, fanOn: Bool, reachable: Bool, configured: Bool) -> NSImage {
        canvas(width: 22, height: 22) { ctx in
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: 2, y: 11))
            outline.line(to: NSPoint(x: 11, y: 19.5))
            outline.line(to: NSPoint(x: 20, y: 11))
            outline.line(to: NSPoint(x: 17.5, y: 11))
            outline.line(to: NSPoint(x: 17.5, y: 2.5))
            outline.line(to: NSPoint(x: 4.5, y: 2.5))
            outline.line(to: NSPoint(x: 4.5, y: 11))
            outline.close()
            outline.lineWidth = 1.6
            outline.lineJoinStyle = .round

            let lit = NSColor(red: 1, green: 0.82, blue: 0.34, alpha: 1)
            let dark = NSColor(white: 0.32, alpha: 1)

            if !configured {
                NSColor(white: 0.45, alpha: 1).set()
            } else if !reachable {
                NSColor(white: 0.45, alpha: 1).set()
                outline.setLineDash([2, 1.6], count: 2, phase: 0)
            } else {
                body.set()
            }
            outline.stroke()

            // Door, so the silhouette reads as a house at 22pt.
            let door = NSBezierPath(rect: NSRect(x: 9.6, y: 2.5, width: 2.8, height: 4.2))
            door.fill()

            let showLights = configured && reachable
            let leftLit = showLights && lightsOn >= 1
            let rightLit = showLights && lightsOn >= 2
            let left = NSRect(x: 6.2, y: 7.4, width: 3.4, height: 3.4)
            let right = NSRect(x: 12.4, y: 7.4, width: 3.4, height: 3.4)

            (leftLit ? lit : dark).set()
            NSBezierPath(rect: left).fill()
            (rightLit ? lit : dark).set()
            NSBezierPath(rect: right).fill()

            guard showLights, fanOn else { return }
            // Three blades in the right window, contrasting with whatever is behind them.
            (rightLit ? dark : lit).set()
            let centre = NSPoint(x: right.midX, y: right.midY)
            for index in 0..<3 {
                let angle = Double(index) * 2 * Double.pi / 3
                let blade = NSBezierPath()
                blade.move(to: centre)
                blade.line(to: NSPoint(x: centre.x + cos(angle) * 1.7, y: centre.y + sin(angle) * 1.7))
                blade.line(to: NSPoint(x: centre.x + cos(angle + 0.7) * 1.5, y: centre.y + sin(angle + 0.7) * 1.5))
                blade.close()
                blade.fill()
            }
        }
    }
```

- [ ] **Step 2: Build StatusItemKit and commit it there**

```bash
cd ~/Code/StatusItemKit && swift build && swift test
git add Sources/StatusItemKit/CharacterIcon.swift
git commit -m "feat: house character icon for Homestead"
cd ~/Code/home-assistant-menubar
```

Expected: StatusItemKit builds and its existing tests still pass.

- [ ] **Step 3: Wire the icon into Homestead**

`Sources/Homestead/HouseIcon.swift`:

```swift
import AppKit
import HomesteadCore
import StatusItemKit

/// Chooses the status glyph for a snapshot: the house mascot, or the plain dot
/// if Icon ▸ Dot is selected.
enum HouseIcon {
    static func image(snapshot: Snapshot, appearance: MeterAppearance) -> NSImage {
        let configured = snapshot.connection != .unconfigured
        let reachable = snapshot.connection == .connected

        guard appearance.style == .character else {
            return MeterIcon.image(style: appearance.style, fraction: reachable ? 1 : 0, color: color(for: snapshot))
        }
        return CharacterIcon.house(
            lightsOn: snapshot.lightsOn,
            fanOn: snapshot.anyFanOn,
            reachable: reachable,
            configured: configured
        )
    }

    private static func color(for snapshot: Snapshot) -> NSColor {
        switch snapshot.connection {
        case .connected: return .systemGreen
        case .connecting: return .systemOrange
        case .unreachable, .authFailed: return .systemRed
        case .unconfigured: return .systemGray
        }
    }
}
```

In `Sources/Homestead/main.swift`, replace `refreshIcon`:

```swift
    func refreshIcon() {
        status.setIcon(HouseIcon.image(snapshot: model?.snapshot ?? Snapshot(), appearance: appearance))
    }
```

The Icon submenu needs no change: Task 6 already built it with
`styles: [.character, .dot], characterTitle: "House"`, and `AppearanceMenu`
only records the choice — drawing is `HouseIcon`'s job.

- [ ] **Step 4: Build and check every icon state**

```bash
swift build && ./scripts/build-app.sh && open build/Homestead.app
```

Expected, in the menu bar: both windows lit with two or more lights on, one
window lit with exactly one, both dark with none; a fan glyph in the right
window while a fan runs; a dashed grey house while Mullvad blocks HA. Icon ▸
Dot switches to the plain dot and back.

- [ ] **Step 5: Generate the mascot artwork**

Draw the house mascot for the app icon in the same style as the other Menubarn
mascots, save it as `Resources/bundle/AppIcon.icns`, then regenerate the glyph
strips:

```bash
~/Code/widgets.nicksmith.software/art/glyphs/render-glyphs.sh
```

Expected: `docs/menubar-icon.png` exists in this repo and the site's strips
include the house. **Do not screen-capture the menu bar for this** — capture
returns a blank strip on this display.

- [ ] **Step 6: Commit**

```bash
git add Sources/Homestead Resources/bundle/AppIcon.icns docs/menubar-icon.png
git commit -m "feat: house status glyph and app icon"
```

---

### Task 11: README, docs, and final verification

**Files:**
- Create: `README.md`
- Create: `docs/mascot.png`
- Modify: `~/Code/PROJECTS.md` (description for this repo)

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Write the README**

`README.md`, following the house style of the other Menubarn repos:

- mascot image at the top (`docs/mascot.png`), centred, with the "Part of the
  [Menubarn](https://widgets.nicksmith.software) widget library" line;
- one-paragraph description;
- a **Why not a SwiftBar plugin?** section — the honest reasons for this app:
  a persistent WebSocket that pushes state (a plugin re-runs a script on a
  timer and would have to poll the REST API), view-based menu rows with real
  switches and sliders that act without dismissing the menu, and a Keychain
  token rather than a token in a shell script;
- **Install**: `./install.sh`, then the first-run steps (create a long-lived
  access token in HA, Connect to Home Assistant…, Test, Save);
- **Using it**: the dashboard picker, rows, sliders, Show Sensors, Icon ▸,
  Start at Login;
- **What it reads**: the dashboards' own configs, so what appears in the menu is
  whatever the dashboard shows — lights, switches, fans, covers, and optionally
  sensors;
- **Troubleshooting**: unreachable while Mullvad is connected (Tailscale route);
  "Token rejected" after revoking a token; a dashboard that vanished from the
  picker (its config could not be read);
- **Development**: `swift test`, `./scripts/build-app.sh`, the
  `docs/superpowers/specs` + `plans` pointers.

- [ ] **Step 2: Run the whole test suite and a clean build**

```bash
swift test && ./scripts/build-app.sh
```

Expected: all tests pass; `build/Homestead.app` is produced and signed with the
stable identity ("Signed with stable identity …" — not ad-hoc).

- [ ] **Step 3: Verify the menu bar is healthy**

```bash
~/Code/menubar-barn/scripts/verify-menubar.sh
```

Expected: Homestead's item is listed, nothing is reported stranded, and only one
menu-bar manager is running.

- [ ] **Step 4: Install and enable Start at Login**

```bash
./install.sh
```

Then menu ▸ Start at Login, and confirm it sticks:

```bash
ls -l ~/Applications/Homestead.app
```

Expected: a symlink into this repo's `build/`.

- [ ] **Step 5: Add the repo description**

Add a line for `home-assistant-menubar` to `~/Code/PROJECTS.md` describing
Homestead in one sentence, so `projects` carries it between machines.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/mascot.png
git commit -m "docs: README and mascot"
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: architecture and
module split (Tasks 1, 6); HA client incl. handshake, id correlation,
subscriptions, backoff, `NWPathMonitor` (Tasks 5, 8); dashboard listing and
parsing rules incl. dedupe, headers, name overrides, skipped action/condition
keys (Task 2); state store and compressed diffs (Task 3); device kinds, unit
math, service calls incl. coalesced drags (Tasks 4, 8); menu layout, picker,
status row, rows, on-only sliders, empty dashboard, unavailable entities,
settings items (Task 9); Connection window, Keychain, first run (Task 7); the
house icon without a chimney and with a fan in the window (Task 10); testing
strategy (the test files in Tasks 1–6) and docs (Task 11).

**Borrowed interfaces, checked against the installed StatusItemKit
(2026-09-15).** `AppearanceMenu.init(appearance:styles:characterTitle:colorItems:onChange:)`,
`MeterAppearance.init(defaults:defaultStyle:defaultColor:)`,
`MeterIcon.image(style:fraction:color:)`, `MeterStyle.character`,
`StatusItemController.init(pollInterval:onPoll:onBuildMenu:autosaveName:onPrimaryClick:)`,
`YieldClient(item:)`, and `LoginItem.isEnabled` / `.toggle()` are all spelled
here as they exist there. Monitor Lizard uses the same `AppearanceMenu` shape,
so that call is copied from working code rather than inferred.
