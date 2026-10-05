import XCTest

/// Drives the CoinPurse website in the Simulator's Safari with real touches.
/// Skipped unless RUN_SAFARI_TESTS=1 (pass TEST_RUNNER_RUN_SAFARI_TESTS=1).
final class SafariWebTests: XCTestCase {
    private var shotIndex = 0

    func testViewerSwipeAndTapOutside() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_SAFARI_TESTS"] == "1")
        let base = ProcessInfo.processInfo.environment["BASE_URL"] ?? "http://localhost:3000"
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        safari.launch()
        XCUIDevice.shared.system.open(URL(string: base + "/?t=\(Int(Date().timeIntervalSince1970))")!)

        // Sign in unless Safari is still signed in from an earlier run.
        let email = safari.webViews.textFields.firstMatch
        if email.waitForExistence(timeout: 8) {
            email.tap()
            email.typeText("review@example.com\n")
            let code = safari.webViews.textFields["6-digit code"]
            XCTAssertTrue(code.waitForExistence(timeout: 10))
            code.tap()
            code.typeText("123456\n")
        }
        sleep(3)
        snap(safari, "web-1-purse")

        // Open the coin.
        let hint = safari.webViews.staticTexts["2 images"].firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 10))
        hint.tap()
        sleep(2)
        snap(safari, "web-2-viewer")

        let web = safari.webViews.firstMatch
        // Swipe left on the middle of the photo.
        let mid = web.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let left = web.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        mid.press(forDuration: 0.05, thenDragTo: left)
        sleep(2)
        snap(safari, "web-3-after-swipe")

        // Tap the black band above the photo.
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)).tap()
        sleep(2)
        snap(safari, "web-4-after-tap-band")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.debugDescription.write(toFile: dir + "/\(name).txt", atomically: true, encoding: .utf8)
        }
    }
}
