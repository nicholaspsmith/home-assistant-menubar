// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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

    // MARK: - Visible dashboards

    func testAllDashboardsAreVisibleByDefault() {
        let listings = [
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: "garden", title: "Garden"),
        ]
        XCTAssertEqual(Set(Settings(defaults: defaults).visible(from: listings).map(\.urlPath)),
                       ["my-home", "garden"])
    }

    func testOnlyChosenDashboardsAreVisible() {
        let settings = Settings(defaults: defaults)
        settings.visibleDashboardPaths = ["my-home", "spa"]

        let listings = [
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: "garden", title: "Garden"),
            DashboardListing(urlPath: "spa", title: "Hot Tub"),
        ]
        // Nothing arranged: alphabetical, Hot Tub before My Home.
        XCTAssertEqual(settings.visible(from: listings).map(\.urlPath), ["spa", "my-home"])
    }

    func testAHiddenNamesakeDoesNotSuffixTheVisibleDashboard() {
        let settings = Settings(defaults: defaults)
        settings.visibleDashboardPaths = ["hot-tub"]
        let listings = DashboardListing.list(from: .array([
            .object(["url_path": .string("hot-tub"), "title": .string("Hot Tub")]),
            .object(["url_path": .string("spa-old"), "title": .string("Hot Tub")]),
        ]))
        XCTAssertEqual(listings.map(\.title), ["Hot Tub (hot-tub)", "Hot Tub (spa-old)"])
        XCTAssertEqual(settings.visible(from: listings).map(\.title), ["Hot Tub"])
    }

    func testVisibleFollowsTheChosenOrder() {
        // The window lets rows be dragged, so the stored order is a preference,
        // not an accident of how Home Assistant listed them.
        let settings = Settings(defaults: defaults)
        settings.visibleDashboardPaths = ["my-home", "spa"]
        settings.dashboardOrder = ["spa", "my-home", "garden"]

        let listings = [
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: "spa", title: "Hot Tub"),
        ]
        XCTAssertEqual(settings.visible(from: listings).map(\.urlPath), ["spa", "my-home"])
    }

    func testDashboardsMissingFromTheOrderGoAfterItAlphabetically() {
        // A dashboard added in Home Assistant after the rows were arranged
        // slots in among the unarranged ones by name, not at HA's position.
        let settings = Settings(defaults: defaults)
        settings.dashboardOrder = ["spa"]

        let listings = [
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: "garden", title: "Garden"),
            DashboardListing(urlPath: "spa", title: "Hot Tub"),
            DashboardListing(urlPath: "added", title: "Attic"),
        ]
        XCTAssertEqual(settings.visible(from: listings).map(\.urlPath), ["spa", "added", "garden", "my-home"])
    }

    // MARK: - Default order

    func testWithNothingArrangedTheOrderIsAlphabetical() {
        let listings = [
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: "garden", title: "Garden"),
            DashboardListing(urlPath: "spa", title: "Hot Tub"),
        ]
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.ordered(listings).map(\.title), ["Garden", "Hot Tub", "My Home"])
        XCTAssertEqual(settings.visible(from: listings).map(\.title), ["Garden", "Hot Tub", "My Home"])
    }

    func testAlphabeticalIgnoresCaseAndSortsNumbersByValue() {
        let listings = [
            DashboardListing(urlPath: "d10", title: "Dashboard 10"),
            DashboardListing(urlPath: "b", title: "basement"),
            DashboardListing(urlPath: "d2", title: "Dashboard 2"),
            DashboardListing(urlPath: "a", title: "Attic"),
        ]
        XCTAssertEqual(Settings(defaults: defaults).ordered(listings).map(\.title),
                       ["Attic", "basement", "Dashboard 2", "Dashboard 10"])
    }

    func testACustomOrderWinsOverAlphabetical() {
        let settings = Settings(defaults: defaults)
        settings.dashboardOrder = ["my-home", "spa", "garden"]
        let listings = [
            DashboardListing(urlPath: "garden", title: "Garden"),
            DashboardListing(urlPath: "spa", title: "Hot Tub"),
            DashboardListing(urlPath: "my-home", title: "My Home"),
        ]
        XCTAssertEqual(settings.visible(from: listings).map(\.urlPath), ["my-home", "spa", "garden"])
    }

    func testClearingTheOrderGoesBackToAlphabetical() {
        let settings = Settings(defaults: defaults)
        settings.dashboardOrder = ["spa", "my-home", "garden"]
        settings.dashboardOrder = []
        let listings = [
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: "spa", title: "Hot Tub"),
            DashboardListing(urlPath: "garden", title: "Garden"),
        ]
        XCTAssertEqual(Settings(defaults: defaults).ordered(listings).map(\.urlPath), ["garden", "spa", "my-home"])
    }

    func testARepeatedPathInTheStoredOrderDoesNotCrash() {
        let settings = Settings(defaults: defaults)
        settings.dashboardOrder = ["spa", "garden", "spa"]
        let listings = [
            DashboardListing(urlPath: "garden", title: "Garden"),
            DashboardListing(urlPath: "spa", title: "Hot Tub"),
        ]
        XCTAssertEqual(settings.ordered(listings).map(\.urlPath), ["spa", "garden"])
    }

    func testOrderedListsEveryDashboardForTheWindow() {
        let settings = Settings(defaults: defaults)
        settings.dashboardOrder = ["spa", "my-home"]

        let listings = [
            DashboardListing(urlPath: "my-home", title: "My Home"),
            DashboardListing(urlPath: "garden", title: "Garden"),
            DashboardListing(urlPath: "spa", title: "Hot Tub"),
        ]
        XCTAssertEqual(settings.ordered(listings).map(\.urlPath), ["spa", "my-home", "garden"])
    }

    func testDashboardOrderRoundTrips() {
        let settings = Settings(defaults: defaults)
        settings.dashboardOrder = ["b", "a"]
        XCTAssertEqual(Settings(defaults: defaults).dashboardOrder, ["b", "a"])
    }

    func testChoosingNoneShowsEverythingRatherThanAnEmptyMenu() {
        let settings = Settings(defaults: defaults)
        settings.visibleDashboardPaths = []
        let listings = [DashboardListing(urlPath: "my-home", title: "My Home")]
        XCTAssertEqual(settings.visible(from: listings), listings)
    }

    func testChoicesForDashboardsThatNoLongerExistAreIgnored() {
        let settings = Settings(defaults: defaults)
        settings.visibleDashboardPaths = ["deleted", "my-home"]
        let listings = [DashboardListing(urlPath: "my-home", title: "My Home")]
        XCTAssertEqual(settings.visible(from: listings).map(\.urlPath), ["my-home"])
    }

    func testVisibleChoicesRoundTrip() {
        let settings = Settings(defaults: defaults)
        settings.visibleDashboardPaths = ["a", "b"]
        XCTAssertEqual(Settings(defaults: defaults).visibleDashboardPaths, ["a", "b"])
    }
}
