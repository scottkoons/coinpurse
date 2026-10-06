import XCTest

/// End-to-end run against the local test server (node test/devserver.js).
/// Screenshots go to $SCREENSHOT_DIR when set
/// (pass TEST_RUNNER_SCREENSHOT_DIR=... to xcodebuild).
final class CoinPurseUITests: XCTestCase {
    private var app: XCUIApplication!
    private var shot = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // UI tests run on the main thread.
        MainActor.assumeIsolated {
            if let run = testRun, run.failureCount > 0, app != nil { dump("failure") }
        }
    }

    @MainActor
    func testFullFlow() throws {
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestShowCamera", "-uiTestVoiceText", "Milk, eggs, avocados, coffee and bread"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = ProcessInfo.processInfo.environment["BASE_URL"] ?? "http://localhost:3000"
        app.launch()

        // Sign in with the local server's reviewer account.
        let email = app.textFields["you@example.com"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("review@example.com")
        app.buttons["Email me a code"].tap()
        let code = app.textFields["6-digit code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        code.typeText("123456")
        XCTAssertTrue(app.staticTexts["Purse is empty"].waitForExistence(timeout: 10))
        snap("1-empty")

        // First coin: paste a picture with one tap.
        UIPasteboard.general.image = Self.sample(color: .systemTeal, label: "QR 1")
        app.buttons["addCoin"].tap()
        let title = app.textFields["titleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        snap("2a-editor-empty")
        title.tap()
        title.typeText("Conference badge")
        let notes = app.textFields["Notes"].exists ? app.textFields["Notes"] : app.textViews["Notes"]
        if notes.exists {
            notes.tap()
            notes.typeText("Questions: hello@example.com or https://coinpurse.yetignome.com/support")
        }
        tapPaste()
        XCTAssertTrue(app.buttons["Crop or rotate"].waitForExistence(timeout: 5), "pasted picture did not appear")
        snap("2-editor-pasted")

        // Add an extra picture through "+" (Paste again).
        UIPasteboard.general.image = Self.sample(color: .systemPink, label: "Back")
        let addPicture = app.buttons["Add picture"].firstMatch
        if !addPicture.waitForExistence(timeout: 2) { app.swipeUp() }
        addPicture.tap()
        tapPaste()
        snap("2b-editor-extras")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.otherElements["frontCard"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["2 pictures · Tap to open"].waitForExistence(timeout: 5))
        snap("3-one-coin")

        // Second coin.
        UIPasteboard.general.image = Self.sample(color: .systemOrange, label: "Haircut")
        app.buttons["addCoin"].tap()
        if !title.waitForExistence(timeout: 5) {
            dump("tree-add-coin")
            XCTFail("editor did not open")
        }
        title.tap()
        title.typeText("Haircut card")
        tapPaste()
        XCTAssertTrue(app.buttons["Crop or rotate"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Haircut card"].waitForExistence(timeout: 15))
        snap("4-two-coins")

        // A quick coin: picture only, no title, is named Coin 1.
        UIPasteboard.general.image = Self.sample(color: .systemGreen, label: "Note")
        app.buttons["addCoin"].tap()
        XCTAssertTrue(app.staticTexts["Leave the title blank and it is saved as Coin 1."].waitForExistence(timeout: 5))
        tapPaste()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Coin 1"].waitForExistence(timeout: 15))
        snap("4b-quick-coin")
        app.buttons["Delete Coin 1"].firstMatch.tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Coin 1"].waitForNonExistence(timeout: 10))

        // The new coin is open at the top. Swipe sideways to flip to the other one.
        let card = app.otherElements["frontCard"]
        let badgeHint = card.staticTexts["2 pictures · Tap to open"]
        let singleHint = card.staticTexts["Tap to open full screen"]
        XCTAssertTrue(singleHint.exists, "new coin should be open at the top")
        card.swipeLeft(velocity: .fast)
        XCTAssertTrue(badgeHint.waitForExistence(timeout: 3), "swipe did not flip")
        snap("5-flipped")
        card.swipeRight(velocity: .fast)
        XCTAssertTrue(singleHint.waitForExistence(timeout: 3), "swipe right did not flip back")
        card.swipeLeft(velocity: .fast)
        XCTAssertTrue(badgeHint.waitForExistence(timeout: 3))

        // Open the coin with two pictures.
        badgeHint.tap()
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 5))
        snap("6-viewer")
        // Typed notes show in the viewer with tappable links.
        XCTAssertTrue(app.links["hello@example.com"].waitForExistence(timeout: 5), "email in notes is not a link")
        XCTAssertTrue(app.links["https://coinpurse.yetignome.com/support"].exists, "web address in notes is not a link")
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 5))

        // Share one picture: the share sheet opens.
        app.buttons["Share"].tap()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10) || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 2))
        snap("7-share")
        app.swipeDown(velocity: .fast)
        sleep(1)
        if app.buttons["Close"].exists { app.buttons["Close"].tap() }

        // Crop: open and apply.
        XCTAssertTrue(app.buttons["Crop"].waitForExistence(timeout: 5))
        app.buttons["Crop"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        snap("8-crop")
        app.buttons["Rotate right"].tap()
        app.buttons["Done"].tap()
        sleep(2)

        app.buttons["Back"].tap()

        // Open the coin without notes and tap the empty space above its picture.
        card.swipeRight(velocity: .fast)
        let singleHint2 = card.staticTexts["Tap to open full screen"]
        XCTAssertTrue(singleHint2.waitForExistence(timeout: 3))
        singleHint2.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["Back"].waitForNonExistence(timeout: 5), "tap outside did not close")
        snap("8b-closed-by-tap")

        // Delete the haircut coin with its trash can.
        app.buttons["Delete Haircut card"].firstMatch.tap()
        XCTAssertTrue(app.alerts["Are you sure you want to delete?"].waitForExistence(timeout: 5))
        snap("9-delete-confirm")
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Haircut card"].waitForNonExistence(timeout: 10))

        // Voice note: say a quick list, and it is saved as a text coin.
        app.buttons["voiceNote"].tap()
        XCTAssertTrue(app.staticTexts["liveTranscript"].waitForExistence(timeout: 5))
        snap("12-voice-listening")
        app.buttons["Done"].tap()
        let voiceText = app.descendants(matching: .any)["voiceText"]
        XCTAssertTrue(voiceText.waitForExistence(timeout: 5))
        // Saved just as it was said.
        XCTAssertEqual(voiceText.value as? String, "Milk, eggs, avocados, coffee and bread")
        snap("13-voice-review")
        let voiceTitle = app.textFields["voiceTitle"]
        voiceTitle.tap()
        voiceTitle.typeText("Groceries")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 15))
        snap("14-voice-coin")
        app.otherElements["frontCard"].staticTexts["Tap to open"].tap()
        let noteText = app.descendants(matching: .any)["noteText"]
        XCTAssertTrue(noteText.waitForExistence(timeout: 5), "text coin did not open")
        snap("15-voice-viewer")
        app.buttons["Back"].tap()

        // Delete the account.
        app.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["Delete Account"].waitForExistence(timeout: 5))
        snap("10-account")
        app.buttons["Delete Account"].tap()
        app.alerts.buttons["Delete Account"].tap()
        XCTAssertTrue(app.textFields["you@example.com"].waitForExistence(timeout: 15))
        snap("11-deleted")
    }

    /// A full purse, put through its paces. Run only on request
    /// (TEST_RUNNER_TOUR=1) against a local server already filled with coins
    /// for review@example.com.
    @MainActor
    func testFullPurse() throws {
        guard ProcessInfo.processInfo.environment["TOUR"] == "1" else { throw XCTSkip("Set TOUR=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestVoiceText", "Remind me to call the vet about Rosie"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
        app.launch()
        let email = app.textFields["you@example.com"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("review@example.com")
        app.buttons["Email me a code"].tap()
        let code = app.textFields["6-digit code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        code.typeText("123456")
        let card = app.otherElements["frontCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        sleep(3)

        // 1. What a long purse looks like, top to bottom.
        snap("tour-0-top")
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        for i in 1...7 {
            low.press(forDuration: 0.05, thenDragTo: high)
            sleep(1)
            snap("tour-\(i)")
        }
        for _ in 1...8 { high.press(forDuration: 0.05, thenDragTo: low) }
        sleep(1)

        // 2. Flip through every coin sideways; each swipe opens the next one.
        XCTAssertTrue(card.isHittable, "the open coin should be on screen at the top")
        var seen: [String] = [frontTitle()]
        let started = Date()
        for _ in 1..<30 {
            card.swipeLeft(velocity: .fast)
            usleep(500_000)
            seen.append(frontTitle())
        }
        let flipSeconds = Date().timeIntervalSince(started)
        XCTAssertEqual(Set(seen).count, 30, "flipping did not visit all 30 coins: \(seen)")
        print("TOUR flips: 29 in \(String(format: "%.1f", flipSeconds)) s")
        snap("tour-flipped-to-last")

        // Tapping a strip opens that coin at the top.
        let strip = app.otherElements.matching(identifier: "strip")
            .containing(NSPredicate(format: "label == 'Dentist'")).firstMatch
        XCTAssertTrue(strip.exists)
        for _ in 1...6 where !strip.isHittable { low.press(forDuration: 0.05, thenDragTo: high) }
        strip.tap()
        sleep(1)
        XCTAssertEqual(frontTitle(), "Dentist")
        XCTAssertTrue(card.isHittable, "tapping a strip should scroll back to the open coin")

        // Search by a word in the notes.
        app.buttons["Search"].tap()
        app.textFields["searchField"].typeText("slots")
        XCTAssertTrue(app.staticTexts["Parking B3"].waitForExistence(timeout: 3))
        snap("tour-search")
        app.staticTexts["Parking B3"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        XCTAssertEqual(frontTitle(), "Parking B3")

        // 3. Add a picture coin; it goes to the front.
        UIPasteboard.general.image = Self.sample(color: .systemIndigo, label: "New")
        app.buttons["addCoin"].tap()
        let title = app.textFields["titleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Stress test coin")
        tapPaste()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Stress test coin"].waitForExistence(timeout: 15))
        XCTAssertEqual(frontTitle(), "Stress test coin")

        // 4. Add a voice note; untitled, so it takes the next number (the
        // seeded purse already has a Coin 1).
        app.buttons["voiceNote"].tap()
        XCTAssertTrue(app.staticTexts["liveTranscript"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Coin 2"].waitForExistence(timeout: 15))
        XCTAssertEqual(frontTitle(), "Coin 2")
        snap("tour-8-after-adding")

        // 5. Open the voice note, then edit its title.
        app.otherElements["frontCard"].staticTexts["Tap to open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["noteText"].waitForExistence(timeout: 5))
        app.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        title.typeText("Call the vet")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Call the vet"].waitForExistence(timeout: 10))
        app.buttons["Back"].tap()

        // 6. Delete five coins from the front, one after another.
        for _ in 0..<5 {
            let doomed = frontTitle()
            card.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch.tap()
            XCTAssertTrue(app.alerts.buttons["Delete"].waitForExistence(timeout: 5))
            app.alerts.buttons["Delete"].tap()
            XCTAssertTrue(app.staticTexts[doomed].waitForNonExistence(timeout: 10), "\(doomed) was not deleted")
        }
        snap("tour-9-after-deleting")

        // 7. Pull to refresh keeps the same purse: 30 + 2 added - 5 deleted.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        sleep(3)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'of 27 · Swipe sideways to flip'")).firstMatch
            .waitForExistence(timeout: 5), "expected 27 coins after refresh")
        snap("tour-10-final")
    }

    @MainActor
    private func frontTitle() -> String {
        app.otherElements["frontCard"].staticTexts["coinTitle"].firstMatch.label
    }

    // MARK: Helpers

    @MainActor
    private func tapPaste() {
        let paste = app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        // The first paste in a fresh simulator can still ask; allow it.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        // iOS shows a "pasted from" banner over the top bar for a moment.
        sleep(3)
    }

    @MainActor
    private func dump(_ name: String) {
        snap(name)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.debugDescription.write(toFile: dir + "/\(name).txt", atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private static func sample(color: UIColor, label: String) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor.white.setFill()
            for i in 0..<5 { for j in 0..<5 where (i + j) % 2 == 0 {
                ctx.fill(CGRect(x: 100 + i * 80, y: 200 + j * 80, width: 70, height: 70))
            } }
            (label as NSString).draw(at: CGPoint(x: 100, y: 80), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.white,
            ])
            // Text for Live Text to find: a web address and an email address.
            ("coinpurse.yetignome.com\nhello@example.com" as NSString).draw(at: CGPoint(x: 40, y: 640), withAttributes: [
                .font: UIFont.systemFont(ofSize: 38, weight: .semibold), .foregroundColor: UIColor.black,
            ])
        }
    }
}
