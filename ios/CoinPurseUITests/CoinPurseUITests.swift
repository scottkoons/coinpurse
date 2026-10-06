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
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestShowCamera",
                                "-uiTestPin", "38.83402,-104.82151",
                                "-uiTestVoiceText", "Milk, eggs, avocados, coffee and bread"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = ProcessInfo.processInfo.environment["BASE_URL"] ?? "http://localhost:3000"
        app.launch()
        signIn()
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 10))
        snap("1-empty")

        // A picture coin: paste with one tap, title, notes with links, a second picture.
        UIPasteboard.general.image = Self.sample(color: .systemTeal, label: "QR 1")
        app.buttons["addPicture"].tap()
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
        UIPasteboard.general.image = Self.sample(color: .systemPink, label: "Back")
        let addPicture = app.buttons["Add picture"].firstMatch
        if !addPicture.waitForExistence(timeout: 2) { app.swipeUp() }
        addPicture.tap()
        tapPaste()
        snap("2b-editor-extras")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Conference badge").waitForExistence(timeout: 15))
        snap("3-one-coin")

        // A second coin.
        UIPasteboard.general.image = Self.sample(color: .systemOrange, label: "Gift")
        app.buttons["addPicture"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Gift card")
        tapPaste()
        XCTAssertTrue(app.buttons["Crop or rotate"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Gift card").waitForExistence(timeout: 15))

        // A quick coin: picture only, so it is named Coin 1. Then toss it.
        UIPasteboard.general.image = Self.sample(color: .systemGreen, label: "Note")
        app.buttons["addPicture"].tap()
        XCTAssertTrue(app.staticTexts["Leave the title blank and it is saved as Coin 1."].waitForExistence(timeout: 5))
        tapPaste()
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Coin 1").waitForExistence(timeout: 15))
        snap("4-three-coins")
        card("Coin 1").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(card("Coin 1").waitForNonExistence(timeout: 10), "Coin 1 was not deleted")

        // Open the coin with two pictures: swipe between them, notes have links.
        card("Conference badge").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(1)
        snap("5-open")
        XCTAssertTrue(app.links["hello@example.com"].waitForExistence(timeout: 5), "email in notes is not a link")
        XCTAssertTrue(app.links["https://coinpurse.yetignome.com/support"].exists, "web address in notes is not a link")
        openCoin.swipeLeft()
        XCTAssertTrue(app.descendants(matching: .any)["Page 2 of 2"].waitForExistence(timeout: 3), "swipe did not reach picture 2")

        // Full size: the viewer opens on the same picture, with share and crop.
        openCoin.buttons["Picture 2"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 5))
        snap("6-viewer")
        app.buttons["viewerShare"].tap()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10) || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 2))
        snap("7-share")
        app.swipeDown(velocity: .fast)
        sleep(1)
        if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        XCTAssertTrue(app.buttons["viewerCrop"].waitForExistence(timeout: 5))
        app.buttons["viewerCrop"].tap()
        XCTAssertTrue(app.buttons["cropDone"].waitForExistence(timeout: 5))
        snap("8-crop")
        app.buttons["Rotate right"].tap()
        app.buttons["cropDone"].tap()
        sleep(2)
        app.buttons["Back"].tap()

        // Drop a map pin on this coin, then remove it.
        XCTAssertTrue(app.buttons["Add Pin"].waitForExistence(timeout: 5))
        app.buttons["Add Pin"].tap()
        XCTAssertTrue(app.buttons["Move Pin"].waitForExistence(timeout: 10), "pin was not added")
        XCTAssertTrue(openCoin.descendants(matching: .any)["pinMap"].waitForExistence(timeout: 5))
        snap("8b-pinned")
        app.buttons["Move Pin"].tap()
        app.buttons["Remove Pin"].tap()
        XCTAssertTrue(app.buttons["Add Pin"].waitForExistence(timeout: 10), "pin was not removed")

        // Back into the stack, by swiping the card down.
        openCoin.swipeDown(velocity: .slow)
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5), "swipe down did not close the coin")

        // A voice note, saved just as it was said.
        app.buttons["voiceNote"].tap()
        XCTAssertTrue(app.staticTexts["liveTranscript"].waitForExistence(timeout: 5))
        snap("12-voice-listening")
        app.buttons["stopRecording"].tap()
        let voiceText = app.descendants(matching: .any)["voiceText"]
        XCTAssertTrue(voiceText.waitForExistence(timeout: 5))
        XCTAssertEqual(voiceText.value as? String, "Milk, eggs, avocados, coffee and bread")
        let voiceTitle = app.textFields["voiceTitle"]
        voiceTitle.tap()
        voiceTitle.typeText("Groceries")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Groceries").waitForExistence(timeout: 15))
        card("Groceries").tap()
        XCTAssertTrue(app.descendants(matching: .any)["noteText"].waitForExistence(timeout: 5), "text coin did not open")
        snap("15-voice-open")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Pin your spot from the bottom bar: it finds you straight away.
        app.buttons["addPin"].tap()
        XCTAssertTrue(app.staticTexts["Within 26 ft"].waitForExistence(timeout: 10) || app.buttons["Move Pin Here"].waitForExistence(timeout: 5),
                      "Pin did not find a spot")
        title.tap()
        title.typeText("Car")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Car").waitForExistence(timeout: 15))
        card("Car").tap()
        XCTAssertTrue(openCoin.descendants(matching: .any)["pinMap"].waitForExistence(timeout: 5), "pin coin shows no map")
        snap("16-pin-coin")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Delete the account.
        app.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["Delete Account"].waitForExistence(timeout: 5))
        snap("10-account")
        app.buttons["Delete Account"].tap()
        app.alerts.buttons["Delete Account"].tap()
        XCTAssertTrue(app.textFields["you@example.com"].waitForExistence(timeout: 15))
        snap("11-deleted")
    }

    /// A full purse (30 coins from the scratchpad seed script), put through its
    /// paces. Run only on request (TEST_RUNNER_TOUR=1).
    @MainActor
    func testFullPurse() throws {
        guard ProcessInfo.processInfo.environment["TOUR"] == "1" else { throw XCTSkip("Set TOUR=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestVoiceText", "Remind me to call the vet about Rosie"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
        app.launch()
        signIn()
        let cards = app.descendants(matching: .any).matching(identifier: "stackCard")
        XCTAssertTrue(card("Garage code").waitForExistence(timeout: 15))
        sleep(2)
        XCTAssertEqual(cards.count, 30)
        snap("tour-0-top")

        // Open and put back the first eight coins, one after another.
        let started = Date()
        for i in 0..<8 {
            let c = cards.element(boundBy: i)
            let name = c.label
            c.tap()
            XCTAssertTrue(openCoin.waitForExistence(timeout: 5), "\(name) did not open")
            XCTAssertEqual(openCoin.staticTexts["coinTitle"].label, name, "opened the wrong coin")
            app.buttons["Done"].tap()
            XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        }
        print("TOUR open+close x8: \(String(format: "%.1f", Date().timeIntervalSince(started))) s")

        // Scroll to the bottom: the last coin can be opened too.
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        for i in 1...6 {
            low.press(forDuration: 0.05, thenDragTo: high)
            sleep(1)
            snap("tour-\(i)")
        }
        let last = cards.element(boundBy: 29)
        XCTAssertTrue(last.isHittable, "the last coin should be reachable")
        let lastName = last.label
        last.tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        XCTAssertEqual(openCoin.staticTexts["coinTitle"].label, lastName)
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        for _ in 1...8 { high.press(forDuration: 0.05, thenDragTo: low) }

        // Search by a word in the notes.
        app.buttons["Search"].tap()
        app.textFields["searchField"].typeText("slots")
        XCTAssertTrue(card("Parking B3").waitForExistence(timeout: 3))
        // Two notes mention slots: Parking B3 and the parking voice note.
        XCTAssertEqual(cards.count, 2)
        snap("tour-search")
        card("Parking B3").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Cancel"].tap()

        // Add a voice note; untitled, so it takes the next number (the seed has a Coin 1).
        app.buttons["voiceNote"].tap()
        XCTAssertTrue(app.staticTexts["liveTranscript"].waitForExistence(timeout: 5))
        app.buttons["stopRecording"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Coin 2").waitForExistence(timeout: 15))

        // Delete five coins from the top, one after another.
        for _ in 0..<5 {
            let top = cards.element(boundBy: 0)
            let name = top.label
            top.tap()
            XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
            app.buttons["Delete"].tap()
            app.alerts.buttons["Delete"].tap()
            XCTAssertTrue(card(name).waitForNonExistence(timeout: 10), "\(name) was not deleted")
        }
        // 30 + 1 added - 5 deleted, and still 26 after a refresh.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        sleep(3)
        XCTAssertEqual(cards.count, 26)
        snap("tour-final")
    }

    /// Screenshots of every screen in the design, against a sample purse
    /// (scratchpad seed_design.py). Run only on request (TEST_RUNNER_DESIGN=1).
    @MainActor
    func testDesignTour() throws {
        guard ProcessInfo.processInfo.environment["DESIGN"] == "1" else { throw XCTSkip("Set DESIGN=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestShowCamera",
                                "-uiTestPin", "38.83402,-104.82151",
                                "-uiTestVoiceText", "Remind me to call the vet about Rosie on Thursday"]
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
        XCTAssertTrue(app.buttons["Parking spot"].waitForExistence(timeout: 15))
        sleep(4)
        snap("d01-purse")

        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        low.press(forDuration: 0.05, thenDragTo: high)
        sleep(2)
        snap("d02-purse-scrolled")
        high.press(forDuration: 0.05, thenDragTo: low)
        sleep(1)

        // Open the parking coin: map first.
        app.buttons["Parking spot"].tap()
        let open = app.otherElements["openCoin"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        sleep(3)
        snap("d03-open-pin")
        open.swipeLeft()
        sleep(2)
        snap("d04-open-pin-photo")
        app.buttons["Done"].tap()
        sleep(1)

        app.buttons["Tailgate tickets"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        sleep(2)
        snap("d05-open-tickets")
        open.buttons["Picture 1"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
        sleep(2)
        snap("d06-full-screen")
        app.buttons["Back"].tap()
        sleep(1)
        app.buttons["Done"].tap()
        sleep(1)

        app.buttons["Email Jim back"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        sleep(2)
        snap("d07-open-note")
        // Swipe down to put it back.
        open.swipeDown(velocity: .slow)
        sleep(2)
        XCTAssertFalse(open.exists, "swipe down should put the coin back")

        app.buttons["addPin"].tap()
        sleep(4)
        snap("d08-pin")
        app.buttons["Cancel"].tap()
        sleep(1)

        app.buttons["voiceNote"].tap()
        sleep(2)
        snap("d09-voice")
        app.buttons["Cancel"].tap()
        sleep(1)

        app.buttons["addPicture"].tap()
        sleep(2)
        snap("d10-new-coin")
        app.buttons["Cancel"].tap()
        sleep(1)

        app.buttons["Search"].tap()
        app.textFields["searchField"].typeText("code")
        sleep(1)
        snap("d11-search")
        app.buttons["Cancel"].tap()
        sleep(1)

        app.buttons["Coffee gift card"].press(forDuration: 1.2)
        sleep(2)
        snap("d12-menu")
    }

    /// Edge cases: odd inputs, limits, empty and error states (TEST_RUNNER_EDGE=1).
    @MainActor
    func testEdgeCases() throws {
        guard ProcessInfo.processInfo.environment["EDGE"] == "1" else { throw XCTSkip("Set EDGE=1 to run") }

        // No connection: signing in says so plainly instead of hanging.
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:9"
        app.launch()
        let email = app.textFields["you@example.com"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("review@example.com")
        app.buttons["Email me a code"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Could not reach Coin Purse'")).firstMatch
            .waitForExistence(timeout: 20), "offline sign-in shows no message")
        snap("e01-offline")
        app.terminate()

        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestPinDenied"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
        app.launch()
        signIn()
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 10))

        // A title and nothing else: the card shows the title big, not a blank.
        app.buttons["addPicture"].tap()
        let title = app.textFields["titleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Locker 🔑 #17")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Locker 🔑 #17").waitForExistence(timeout: 15))
        card("Locker 🔑 #17").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["noteText"].label, "Locker 🔑 #17")
        snap("e02-title-only")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // A very long title and note: they truncate in the stack and stay readable open.
        let longTitle = String(repeating: "Very long title ", count: 8).trimmingCharacters(in: .whitespaces)
        UIPasteboard.general.image = Self.sample(color: .systemIndigo, label: "Long")
        app.buttons["addPicture"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(longTitle)
        let notes = app.textFields["Notes"].exists ? app.textFields["Notes"] : app.textViews["Notes"]
        notes.tap()
        notes.typeText(String(repeating: "Gate 4, row K, seat 12. ", count: 12))
        tapPaste()
        app.buttons["Save"].tap()
        XCTAssertTrue(card(longTitle).waitForExistence(timeout: 15))
        snap("e03-long-title-stack")
        card(longTitle).tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(1)
        snap("e04-long-open")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // A long note: dragging inside it scrolls; dragging the title bar closes the coin.
        app.buttons["addPicture"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Long note")
        notes.tap()
        notes.typeText(String(repeating: "Bring the blue cooler, two chairs and the tickets. ", count: 6))
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Long note").waitForExistence(timeout: 15))
        card("Long note").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(1)
        app.descendants(matching: .any)["noteText"].swipeDown()
        sleep(1)
        XCTAssertTrue(openCoin.exists, "scrolling a long note closed the coin")
        openCoin.staticTexts["coinTitle"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5), "dragging the title bar did not close the coin")

        // Six pictures is the most a coin holds: the add button goes away.
        UIPasteboard.general.image = Self.sample(color: .systemTeal, label: "1")
        app.buttons["addPicture"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Six pictures")
        tapPaste()
        for n in 2...6 {
            UIPasteboard.general.image = Self.sample(color: .systemTeal, label: "\(n)")
            let add = app.buttons["Add picture"].firstMatch
            if !add.waitForExistence(timeout: 2) { app.swipeUp() }
            add.tap()
            tapPaste()
        }
        XCTAssertFalse(app.buttons["Add picture"].exists, "a seventh picture should not be offered")
        snap("e05-six-pictures")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Six pictures").waitForExistence(timeout: 30))
        card("Six pictures").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        for _ in 1...5 { openCoin.swipeLeft() }
        XCTAssertTrue(app.descendants(matching: .any)["Page 6 of 6"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Location turned off: Pin explains how to turn it on, nothing breaks.
        app.buttons["addPin"].tap()
        XCTAssertTrue(app.staticTexts["Turn on Location for Coin Purse in Settings to drop a pin."].waitForExistence(timeout: 10))
        snap("e06-location-off")
        app.buttons["Cancel"].tap()
        card("Locker 🔑 #17").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        app.buttons["Add Pin"].tap()
        XCTAssertTrue(app.staticTexts["Turn on Location for Coin Purse in Settings to drop a pin."].waitForExistence(timeout: 5),
                      "Add Pin with location off shows no message")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Search appears once a purse has six coins.
        XCTAssertFalse(app.buttons["Search"].exists, "search should wait for a bigger purse")
        for n in 1...3 {
            app.buttons["addPicture"].tap()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.tap()
            title.typeText("Quick \(n)")
            app.buttons["Save"].tap()
            XCTAssertTrue(card("Quick \(n)").waitForExistence(timeout: 15))
        }
        // Search with nothing found says so.
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 3))
        app.buttons["Search"].tap()
        app.textFields["searchField"].typeText("zzzz")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No Results'")).firstMatch.waitForExistence(timeout: 3))
        snap("e07-no-results")
        app.buttons["Cancel"].tap()

        // Toss every coin: the purse goes back to empty.
        let cards = app.descendants(matching: .any).matching(identifier: "stackCard")
        while cards.count > 0 {
            let top = cards.element(boundBy: 0)
            let name = top.label
            top.tap()
            XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
            app.buttons["Delete"].tap()
            app.alerts.buttons["Delete"].tap()
            XCTAssertTrue(card(name).waitForNonExistence(timeout: 10), "\(name) was not deleted")
        }
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 5))
        snap("e08-empty-again")
    }

    /// No signal: the purse still opens from the copy saved on the phone,
    /// changes fail clearly and nothing is lost (TEST_RUNNER_OFFLINE=1).
    @MainActor
    func testOffline() throws {
        guard ProcessInfo.processInfo.environment["OFFLINE"] == "1" else { throw XCTSkip("Set OFFLINE=1 to run") }
        setServerOffline(false)
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
        app.launch()
        signIn()
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 10))

        // Two coins while online: a ticket picture and a note.
        UIPasteboard.general.image = Self.sample(color: .systemTeal, label: "Ticket")
        app.buttons["addPicture"].tap()
        let title = app.textFields["titleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Ticket")
        tapPaste()
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Ticket").waitForExistence(timeout: 15))
        app.buttons["addPicture"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Gate code 2468")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Gate code 2468").waitForExistence(timeout: 15))

        // The signal drops, and the app is started fresh.
        setServerOffline(true)
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
        app.launch()
        XCTAssertTrue(card("Ticket").waitForExistence(timeout: 20), "saved coins did not show offline")
        XCTAssertTrue(card("Gate code 2468").exists)
        XCTAssertTrue(offlineNote.waitForExistence(timeout: 30), "no offline note")
        snap("o01-offline-purse")

        // The ticket picture opens from the phone.
        card("Ticket").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        XCTAssertTrue(openCoin.buttons["Picture 1"].waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertFalse(openCoin.activityIndicators.firstMatch.exists, "picture still loading offline")
        snap("o02-offline-open")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Saving fails with a clear message, and the editor keeps what was typed.
        app.buttons["addPicture"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Offline coin")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Could not reach Coin Purse'")).firstMatch
            .waitForExistence(timeout: 70), "offline save shows no message")
        XCTAssertEqual(title.value as? String, "Offline coin")
        snap("o03-offline-save")
        app.buttons["Cancel"].tap()

        // Deleting fails and the coin comes back.
        card("Gate code 2468").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(card("Gate code 2468").waitForExistence(timeout: 70), "offline delete lost the coin")

        // Signal back: a pull to refresh clears the note and everything works.
        setServerOffline(false)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(offlineNote.waitForNonExistence(timeout: 15), "offline note did not clear")
        app.buttons["addPicture"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Back online")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Back online").waitForExistence(timeout: 15))
        snap("o04-back-online")
    }

    @MainActor
    private var offlineNote: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Offline'")).firstMatch
    }

    private func setServerOffline(_ on: Bool) {
        let done = expectation(description: "offline switch")
        URLSession.shared.dataTask(with: URL(string: "http://localhost:3000/__test/offline?on=\(on ? 1 : 0)")!) { _, _, _ in
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
    }

    /// Share to Coin Purse: two pictures added to an existing coin, then saved
    /// as a new coin (TEST_RUNNER_SHARE=1). The app shows the same screen the
    /// Share extension uses.
    @MainActor
    func testShareToCoinPurse() throws {
        guard ProcessInfo.processInfo.environment["SHARE"] == "1" else { throw XCTSkip("Set SHARE=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
        app.launch()
        signIn()
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 10))
        UIPasteboard.general.image = Self.sample(color: .systemGreen, label: "T1")
        app.buttons["addPicture"].tap()
        let title = app.textFields["titleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Tickets")
        tapPaste()
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Tickets").waitForExistence(timeout: 15))
        app.terminate()

        // Shared from Messages: add both pictures to Tickets.
        app = XCUIApplication()
        app.launchArguments += ["-uiTestNoLock", "-uiTestShare"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
        app.launch()
        let save = app.buttons["shareSave"]
        XCTAssertTrue(save.waitForExistence(timeout: 20), "share screen did not open")
        XCTAssertTrue(app.staticTexts["2 pictures"].exists)
        snap("s01-share-new")
        app.buttons["Add to a Coin"].tap()
        let tickets = app.collectionViews.buttons.matching(NSPredicate(format: "label == 'Tickets'")).firstMatch
        XCTAssertTrue(tickets.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "Save before choosing a coin")
        tickets.tap()
        XCTAssertTrue(save.isEnabled)
        snap("s02-share-existing")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 20), "share did not finish")
        card("Tickets").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["Page 1 of 3"].waitForExistence(timeout: 10), "Tickets should hold 3 pictures")
        app.buttons["Done"].tap()
        app.terminate()

        // Shared again: a new coin with a title.
        app = XCUIApplication()
        app.launchArguments += ["-uiTestNoLock", "-uiTestShare"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
        app.launch()
        XCTAssertTrue(save.waitForExistence(timeout: 20))
        let shareTitle = app.textFields["shareTitle"]
        shareTitle.tap()
        shareTitle.typeText("Shared tickets")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 20))
        XCTAssertTrue(card("Shared tickets").waitForExistence(timeout: 15))
        card("Shared tickets").tap()
        XCTAssertTrue(app.descendants(matching: .any)["Page 1 of 2"].waitForExistence(timeout: 10))
        snap("s03-shared-coin")
    }

    /// Quick actions open the right screen (TEST_RUNNER_QUICK=1).
    @MainActor
    func testQuickActions() throws {
        guard ProcessInfo.processInfo.environment["QUICK"] == "1" else { throw XCTSkip("Set QUICK=1 to run") }
        for (action, check) in [("pinSpot", "Pin your spot"), ("voiceNote", "Voice note"), ("addPicture", "New coin")] {
            app = XCUIApplication()
            app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestQuickAction", action, "-uiTestPin", "38.834,-104.821"]
            app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
            app.launch()
            signIn()
            XCTAssertTrue(app.staticTexts[check].waitForExistence(timeout: 15), "\(action) did not open \(check)")
            snap("q-\(action)")
            app.terminate()
        }
    }

    /// A very big purse (150 coins, seed_big.py): it opens quickly, scrolls to
    /// the end, and the last coin opens (TEST_RUNNER_BIG=1).
    @MainActor
    func testBigPurse() throws {
        guard ProcessInfo.processInfo.environment["BIG"] == "1" else { throw XCTSkip("Set BIG=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
        app.launch()
        signIn()
        let started = Date()
        XCTAssertTrue(card("Coin number 150").waitForExistence(timeout: 30))
        print("BIG first card after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        snap("b01-top")
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let scrollStart = Date()
        var reached = false
        for _ in 0..<60 {
            low.press(forDuration: 0.02, thenDragTo: high, withVelocity: .fast, thenHoldForDuration: 0)
            if card("Coin number 001").exists && card("Coin number 001").isHittable { reached = true; break }
        }
        print("BIG scrolled to the end in \(String(format: "%.1f", Date().timeIntervalSince(scrollStart))) s")
        XCTAssertTrue(reached, "could not scroll to the last coin")
        snap("b02-bottom")
        card("Coin number 001").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        XCTAssertEqual(openCoin.staticTexts["coinTitle"].label, "Coin number 001")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        // Search across all 150.
        for _ in 0..<60 { high.press(forDuration: 0.02, thenDragTo: low, withVelocity: .fast, thenHoldForDuration: 0) }
        app.buttons["Search"].tap()
        app.textFields["searchField"].typeText("077")
        XCTAssertTrue(card("Coin number 077").waitForExistence(timeout: 5))
        snap("b03-search")
    }

    /// What Apple Maps shows after tapping a pin (TEST_RUNNER_MAPS=1, design purse).
    @MainActor
    func testMapsDirections() throws {
        guard ProcessInfo.processInfo.environment["MAPS"] == "1" else { throw XCTSkip("Set MAPS=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = "http://localhost:3000"
        app.launch()
        signIn()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        card("Parking spot").tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(2)
        openCoin.descendants(matching: .any)["pinMap"].firstMatch.tap()
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 15), "Maps did not open")
        // Get past Maps' own first-launch questions.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<4 {
            if springboard.buttons["Allow While Using App"].waitForExistence(timeout: 3) { springboard.buttons["Allow While Using App"].tap() }
            for name in ["Not Now", "Continue", "Allow While Using App"] where maps.buttons[name].exists { maps.buttons[name].tap() }
            sleep(2)
        }
        sleep(6)
        snap("maps-1")
        sleep(5)
        snap("maps-2")
        try? maps.debugDescription.write(toFile: (ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? "/tmp") + "/maps-tree.txt", atomically: true, encoding: .utf8)
    }

    @MainActor
    private var openCoin: XCUIElement { app.otherElements["openCoin"] }

    @MainActor
    private func card(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "stackCard").matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    @MainActor
    private func signIn() {
        let email = app.textFields["you@example.com"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("review@example.com")
        app.buttons["Email me a code"].tap()
        let code = app.textFields["6-digit code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        code.typeText("123456")
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
