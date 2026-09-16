import XCTest
@testable import HomesteadCore

final class DashboardListingTests: XCTestCase {
    func testListsUserDashboardsInOrder() throws {
        let result = try JSONValue.parse(Data(#"""
        [{"id":"my_home","url_path":"my-home","title":"My Home","mode":"storage"},
         {"id":"garden","url_path":"garden","title":"Garden","mode":"yaml"}]
        """#.utf8))

        XCTAssertEqual(DashboardListing.list(from: result), [
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: "garden", title: "Garden"),
        ])
    }

    func testBuiltInOverviewIsNotAdded() throws {
        // HA's auto-generated Overview usually has no stored config, so it would
        // only ever be a dead entry in the picker.
        let result = try JSONValue.parse(Data(#"[{"url_path":"garden","title":"Garden"}]"#.utf8))
        XCTAssertEqual(DashboardListing.list(from: result).map(\.title), ["Garden"])
    }

    func testEntriesWithoutTitleOrURLPathAreSkipped() throws {
        let result = try JSONValue.parse(Data(#"""
        [{"id":"broken","mode":"storage"},
         {"id":"ok","url_path":"ok","title":"OK"},
         {"id":"untitled","url_path":"untitled"}]
        """#.utf8))

        XCTAssertEqual(DashboardListing.list(from: result).map(\.title), ["OK"])
    }

    func testDuplicateTitlesAreDisambiguatedByURLPath() throws {
        // Two dashboards can share a title; the picker has to tell them apart.
        let result = try JSONValue.parse(Data(#"""
        [{"url_path":"hot-tub","title":"Hot Tub"},
         {"url_path":"spa","title":"Hot Tub"},
         {"url_path":"studio","title":"Studio"}]
        """#.utf8))

        XCTAssertEqual(DashboardListing.list(from: result).map(\.title),
                       ["Hot Tub (hot-tub)", "Hot Tub (spa)", "Studio"])
    }

    func testDisambiguationKeepsTheURLPathIntact() throws {
        let result = try JSONValue.parse(Data(#"""
        [{"url_path":"hot-tub","title":"Hot Tub"},{"url_path":"spa","title":"Hot Tub"}]
        """#.utf8))

        XCTAssertEqual(DashboardListing.list(from: result).map(\.urlPath), ["hot-tub", "spa"])
    }

    func testNonArrayResultYieldsNothing() {
        XCTAssertEqual(DashboardListing.list(from: .null), [])
    }
}
