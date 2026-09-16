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
