import XCTest

final class SonivoLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchesMainNavigationAndMyWave() {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["sonivo.root.tabs"].waitForExistence(timeout: 10),
            "The main tab navigation should be visible after launch."
        )
        XCTAssertTrue(
            app.staticTexts["sonivo.my-wave.title"].waitForExistence(timeout: 10),
            "The My Wave hero should be visible on the default tab."
        )
    }
}