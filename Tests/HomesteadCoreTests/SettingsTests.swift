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
