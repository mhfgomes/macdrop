import XCTest

final class MacDropUITests: XCTestCase {
    func testApplicationLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-MacDropUITesting", "1"]
        app.launch()

        let becameReady = app.wait(for: .runningForeground, timeout: 10)
            || app.wait(for: .runningBackground, timeout: 10)
        XCTAssertTrue(becameReady, "MacDrop failed to reach a running state")

        // Menu bar extra content should be reachable for a smoke interaction.
        let menuBarItem = app.menuBars.statusItems.firstMatch
        if menuBarItem.waitForExistence(timeout: 5) {
            menuBarItem.click()
            let openButton = app.buttons["Open MacDrop"]
            XCTAssertTrue(
                openButton.waitForExistence(timeout: 5) || app.staticTexts["MacDrop"].waitForExistence(timeout: 5),
                "Menu bar UI did not expose MacDrop controls"
            )
        } else {
            // Accessory apps may not always expose status items to XCTest; require
            // at least one MacDrop-titled window or static text as a fallback smoke check.
            let hasUI = app.windows["MacDrop"].waitForExistence(timeout: 5)
                || app.staticTexts["MacDrop"].waitForExistence(timeout: 5)
            XCTAssertTrue(hasUI, "MacDrop launched without a discoverable menu bar or main UI")
        }
    }
}
