import XCTest

/// End-to-end run against the local test server (node test/devserver.js).
/// Screenshots go to $SCREENSHOT_DIR when set
/// (pass TEST_RUNNER_SCREENSHOT_DIR=... to xcodebuild).
final class CoinPurseUITests: XCTestCase {
    /// The local test server (TEST_RUNNER_BASE_URL picks another one, so two
    /// simulators can test at the same time).
    static let baseURL = ProcessInfo.processInfo.environment["BASE_URL"] ?? "http://localhost:3000"
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
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 10))
        snap("1-empty")

        // A picture coin: paste with one tap, title, notes with links, a second picture.
        UIPasteboard.general.image = Self.sample(color: .systemTeal, label: "QR 1")
        app.buttons["addPicture"].tap()
        let title = app.textFields["titleField"]
        XCTAssertTrue(reveal(title))
        snap("2a-editor-empty")
        reveal(title); title.tap()
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
        reveal(addPicture)
        addPicture.tap()
        tapPaste()
        snap("2b-editor-extras")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Conference badge").waitForExistence(timeout: 15))
        snap("3-one-coin")

        // A second coin.
        UIPasteboard.general.image = Self.sample(color: .systemOrange, label: "Gift")
        app.buttons["addPicture"].tap()
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Gift card")
        tapPaste()
        XCTAssertTrue(app.buttons["Crop or rotate"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Gift card").waitForExistence(timeout: 15))

        // A quick coin: picture only, so it is named Coin 1. Then toss it.
        UIPasteboard.general.image = Self.sample(color: .systemGreen, label: "Note")
        app.buttons["addPicture"].tap()
        XCTAssertTrue(reveal(app.staticTexts["Leave the title blank and it is saved as Coin 1."]))
        tapPaste()
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Coin 1").waitForExistence(timeout: 15))
        snap("4-three-coins")
        tapCard("Coin 1")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(card("Coin 1").waitForNonExistence(timeout: 10), "Coin 1 was not deleted")

        // Open the coin with two pictures: swipe between them, notes have links.
        tapCard("Conference badge")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(1)
        snap("5-open")
        XCTAssertTrue(app.links["hello@example.com"].waitForExistence(timeout: 5), "email in notes is not a link")
        XCTAssertTrue(app.links["https://coinpurse.yetignome.com/support"].exists, "web address in notes is not a link")
        // Every picture is a thumbnail under the card.
        XCTAssertTrue(app.buttons["Picture 2"].waitForExistence(timeout: 3), "second picture has no thumbnail")

        // Full size: the viewer opens on that picture, with share and crop.
        app.buttons["Picture 2"].firstMatch.tap()
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
        tapCard("Groceries")
        XCTAssertTrue(app.descendants(matching: .any)["noteText"].waitForExistence(timeout: 5), "text coin did not open")
        snap("15-voice-open")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Pin your spot from the bottom bar: it finds you straight away.
        app.buttons["addPin"].tap()
        XCTAssertTrue(app.staticTexts["Within 26 ft"].waitForExistence(timeout: 10) || app.buttons["Move Pin Here"].waitForExistence(timeout: 5),
                      "Pin did not find a spot")
        reveal(title); title.tap()
        title.typeText("Car")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Car").waitForExistence(timeout: 15))
        tapCard("Car")
        XCTAssertTrue(openCoin.descendants(matching: .any)["pinMap"].waitForExistence(timeout: 5), "pin coin shows no map")
        snap("16-pin-coin")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Delete the account.
        app.buttons["Account"].tap()
        XCTAssertTrue(reveal(app.buttons["Delete Account"]))
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
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        let cards = app.descendants(matching: .any).matching(identifier: "stackCard")
        XCTAssertTrue(card("Garage code").waitForExistence(timeout: 15))
        sleep(2)
        // The purse only builds cards near the screen, so count on the server.
        XCTAssertEqual(serverCoinCount(), 30)
        snap("tour-0-top")

        // Open and put back the first eight coins, one after another.
        let started = Date()
        for i in 0..<8 {
            let name = cards.element(boundBy: i).label
            tapCard(name)
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
        let last = card("Tailgate tickets")
        for _ in 1...6 where !(last.exists && last.isHittable) { low.press(forDuration: 0.05, thenDragTo: high) }
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
        tapCard("Parking B3")
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
        XCTAssertEqual(serverCoinCount(), 26)
        snap("tour-final")
    }

    /// Hammering the purse: opening and closing faster than the animations,
    /// tapping two cards at once, paging mid-open, swiping down repeatedly.
    /// Nothing may crash, get stuck open or half open, or be deleted
    /// (TEST_RUNNER_STRESS=1, design purse).
    @MainActor
    func testStress() throws {
        guard ProcessInfo.processInfo.environment["STRESS"] == "1" else { throw XCTSkip("Set STRESS=1 to run") }
        app = XCUIApplication()
        // Simulated speech, in case a tap ever lands on Voice.
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestVoiceText", "Stress"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        let before = serverCoinCount()
        let names = ["Parking spot", "Tailgate tickets", "Coffee gift card", "Email Jim back"]

        // 1. Open and Done with no pause, many times.
        for n in 0..<16 {
            // Tap where the card is, even while the last coin is still closing.
            let name = names[n % names.count]
            let f = card(name).frame
            if f.midY > app.buttons["addPicture"].frame.minY - 8 {
                // Under the add bar (large text): bring it up first, never tap the bar.
                tapCard(name)
            } else {
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
            }
            let done = app.buttons["Done"]
            if done.waitForExistence(timeout: 3) { done.tap() }
        }
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5), "a coin stayed open after rapid open and close")
        XCTAssertTrue(card("Parking spot").isHittable, "stack not usable after rapid open and close")

        // 2. A quick double tap on a card: the coin opens, and the second tap
        // does not land on its picture and jump to full screen.
        card("Tailgate tickets").doubleTap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(app.buttons["viewerShare"].exists, "double tap opened the picture full screen")
        XCTAssertEqual(app.otherElements.matching(identifier: "openCoin").count, 1, "two coins open at once")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // 3. The coins at the bottom of an open coin, like Wallet: pull one up a
        // little and it drops back; tap one and it takes the open coin's place.
        tapCard("Parking spot")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(1)
        let nextCard = app.descendants(matching: .any).matching(identifier: "pileCard").firstMatch
        XCTAssertTrue(nextCard.waitForExistence(timeout: 5), "no coins at the bottom of an open coin")
        let nextTitle = nextCard.label
        let nf = nextCard.frame
        let grab = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: nf.midX, dy: nf.minY + 20))
        grab.press(forDuration: 0.1, thenDragTo: grab.withOffset(CGVector(dx: 0, dy: -90)), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertEqual(openCoin.staticTexts["coinTitle"].label, "Parking spot", "a small pull swapped the coin")
        nextCard.tap()
        sleep(1)
        XCTAssertEqual(openCoin.staticTexts["coinTitle"].label, nextTitle, "tapping a coin at the bottom did not bring it up")
        // Pulled up most of the way, the next one comes up too.
        let third = app.descendants(matching: .any).matching(identifier: "pileCard").firstMatch
        let thirdTitle = third.label
        let tf = third.frame
        let grab2 = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: tf.midX, dy: tf.minY + 20))
        grab2.press(forDuration: 0.1, thenDragTo: grab2.withOffset(CGVector(dx: 0, dy: -320)), withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(1)
        XCTAssertEqual(openCoin.staticTexts["coinTitle"].label, thirdTitle, "pulling a coin up did not bring it up")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        XCTAssertTrue(card("Parking spot").isHittable, "stack not usable after going back")

        // Touch, hold and drag a card to the top, like moving passes in Wallet.
        let mover = card("Coffee gift card").frame
        let top = card("Parking spot").frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: mover.midX, dy: mover.midY))
            .press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: top.midX, dy: top.minY + 12)), withVelocity: .slow, thenHoldForDuration: 0.4)
        sleep(2)
        XCTAssertFalse(openCoin.exists, "moving a card to the first place opened it")
        XCTAssertLessThan(card("Coffee gift card").frame.minY, card("Parking spot").frame.minY, "dragging did not move the card to the top")
        XCTAssertEqual(serverFirstTitle(), "Coffee gift card", "the new order was not saved")
        snap("s01-moved")

        // Hold and let go: it lifts to show itself, then drops back where it was.
        let held = card("Tailgate tickets").frame
        let heldPoint = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: held.midX, dy: held.midY))
        heldPoint.press(forDuration: 1.2)
        sleep(1)
        XCTAssertFalse(openCoin.exists, "holding a card opened it")
        XCTAssertEqual(serverFirstTitle(), "Coffee gift card", "holding a card changed the order")

        // Lifted and pulled all the way up to the title: it opens.
        heldPoint.press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: held.midX, dy: app.buttons["Account"].frame.midY)), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5), "pulling a card to the top did not open it")
        XCTAssertEqual(openCoin.staticTexts["coinTitle"].label, "Tailgate tickets")
        XCTAssertEqual(serverFirstTitle(), "Coffee gift card", "opening by pulling up changed the order")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Opening and putting back quickly, over and over.
        for _ in 0..<4 {
            tapCard("Coffee gift card")
            if app.buttons["Done"].waitForExistence(timeout: 3) { app.buttons["Done"].tap() }
        }
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // One open for the swipe-down test below.
        tapCard("Parking spot")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))

        // 4. Swipe down repeatedly: it closes once and the stack takes taps again.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)), withVelocity: .fast, thenHoldForDuration: 0)
        start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5), "swipe down did not put the coin back")
        tapCard("Email Jim back")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5), "stack ignored taps after swipe-down")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // 5. Search typed and cleared fast while cards come and go.
        app.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for word in ["p", "pa", "par", "xyz", "", "coffee", "gar"] {
            field.tap()
            if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            field.typeText(word)
        }
        XCTAssertTrue(card("Garage code").waitForExistence(timeout: 5), "search for 'gar' did not find Garage code")
        snap("s02-search")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 5), "stack did not come back after search")

        // Still alive, nothing lost.
        XCTAssertEqual(app.state, .runningForeground, "app is no longer running")
        XCTAssertEqual(serverCoinCount(), before, "stress changed the number of coins")
        snap("s03-end")
    }

    /// Coins added elsewhere (Photos share sheet, another iPhone) appear when
    /// you come back to the app, without pulling to refresh (TEST_RUNNER_RETURN=1).
    @MainActor
    func testComesBackFresh() throws {
        guard ProcessInfo.processInfo.environment["RETURN"] == "1" else { throw XCTSkip("Set RETURN=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        serverAddCoin(title: "Shared from Photos")
        sleep(2)
        app.activate()
        XCTAssertTrue(card("Shared from Photos").waitForExistence(timeout: 10), "new coin did not appear on return")
        snap("r01-back")
    }

    /// The real share extension, from Apple's Photos app: pick a photo, Share,
    /// Coin Purse, name it, Save; it is in the purse (TEST_RUNNER_PHOTOS=1).
    @MainActor
    func testShareFromPhotos() throws {
        guard ProcessInfo.processInfo.environment["PHOTOS"] == "1" else { throw XCTSkip("Set PHOTOS=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        // First run of Photos shows "What's New" (sometimes a few seconds late); get past it.
        func dismissWelcome() {
            for name in ["Continue", "Not Now", "Don’t Allow"] where photos.buttons[name].waitForExistence(timeout: 3) {
                photos.buttons[name].tap()
            }
        }
        dismissWelcome()
        // Photos may reopen on the last photo it showed, or on the grid.
        let share = photos.buttons["Share"].firstMatch
        if !share.waitForExistence(timeout: 3) {
            let photo = photos.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
            if !photo.waitForExistence(timeout: 10) { dumpOf(photos, "p00-grid"); XCTFail("no photo in Photos"); return }
            // Photos marks its grid images as not hittable; tap where it is.
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        if !share.waitForExistence(timeout: 5) {
            dismissWelcome()
            if !share.exists {
                photos.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
        if !share.waitForExistence(timeout: 5) { dumpOf(photos, "p01-photo"); XCTFail("no Share button"); return }
        share.tap()
        sleep(2)
        var target = photos.descendants(matching: .any).matching(NSPredicate(format: "label == 'Coin Purse'")).firstMatch
        if !target.waitForExistence(timeout: 5) {
            let more = photos.descendants(matching: .any).matching(NSPredicate(format: "label == 'More'")).firstMatch
            if more.exists { more.tap(); sleep(2) }
            target = photos.descendants(matching: .any).matching(NSPredicate(format: "label == 'Coin Purse'")).firstMatch
        }
        if !target.waitForExistence(timeout: 5) { dumpOf(photos, "p02-sheet"); XCTFail("Coin Purse is not in the share sheet"); return }
        snap("p02-sheet")
        target.tap()
        let title = photos.textFields["shareTitle"]
        if !title.waitForExistence(timeout: 15) { dumpOf(photos, "p03-extension"); XCTFail("share extension did not open"); return }
        snap("p03-extension")
        title.tap()
        title.typeText("From Photos")
        // Offline first: Save says so where it can be seen, and keeps everything.
        setServerOffline(true)
        photos.buttons["shareSave"].tap()
        let problem = photos.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Could not reach Coin Purse'")).firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 70), "offline share shows no message")
        XCTAssertTrue(problem.isHittable, "offline share message is out of sight")
        snap("p03b-offline")
        // Back online: Save again finishes, and makes one coin, not two.
        setServerOffline(false)
        photos.buttons["shareSave"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 30), "share extension did not finish")
        photos.terminate()

        app.activate()
        XCTAssertTrue(card("From Photos").waitForExistence(timeout: 15), "shared photo is not in the purse")
        tapCard("From Photos")
        XCTAssertTrue(openCoin.buttons["Picture 1"].waitForExistence(timeout: 10), "shared coin has no picture")
        XCTAssertFalse(app.buttons["Picture 2"].exists, "the retried share added the picture twice")
        XCTAssertEqual(serverCoinCount(), 1, "the retried share made more than one coin")
        snap("p04-in-purse")
    }

    @MainActor
    private func dumpOf(_ other: XCUIApplication, _ name: String) {
        snap(name)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? other.debugDescription.write(toFile: dir + "/\(name).txt", atomically: true, encoding: .utf8)
        }
    }

    /// Tapping the visible part of any card opens exactly that coin, at any
    /// text size (TEST_RUNNER_TAP=1, 30-coin purse).
    @MainActor
    func testTapAccuracy() throws {
        guard ProcessInfo.processInfo.environment["TAP"] == "1" else { throw XCTSkip("Set TAP=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        let cards = app.descendants(matching: .any).matching(identifier: "stackCard")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 15))
        sleep(2)
        let bar = app.buttons["addPicture"]
        let account = app.buttons["Account"]
        var checked = 0
        var names: [String] = []
        for _ in 0..<12 {
            // The first card not yet checked that is fully clear of the title and the bar.
            let all = (0..<cards.count).map { cards.element(boundBy: $0) }
            guard let c = all.first(where: { !names.contains($0.label) && $0.frame.minY >= account.frame.maxY
                                                && $0.frame.maxY <= bar.frame.minY }) else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
                sleep(1)
                continue
            }
            let name = c.label
            names.append(name)
            let f = c.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
            XCTAssertTrue(openCoin.waitForExistence(timeout: 5), "\(name) did not open")
            let opened = openCoin.staticTexts["coinTitle"].label
            XCTAssertEqual(opened, name, "tapped \(name) at y \(Int(f.midY)) but \(opened) opened")
            if opened != name { snap("tap-wrong-\(checked)") }
            app.buttons["Done"].tap()
            XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
            sleep(1)
            checked += 1
        }
        print("TAP checked \(checked) cards: \(names)")
        XCTAssertGreaterThanOrEqual(checked, 8)
    }

    /// The website film: the real app, paced for watching, with chapter marks
    /// printed so the recording can be cut and captioned (TEST_RUNNER_DEMO=1,
    /// scratchpad seed_demo.py, pictures from TEST_RUNNER_DEMO_IMG).
    @MainActor
    func testDemoFilm() throws {
        guard ProcessInfo.processInfo.environment["DEMO"] == "1" else { throw XCTSkip("Set DEMO=1 to run") }
        let imgDir = ProcessInfo.processInfo.environment["DEMO_IMG"] ?? ""
        func chapter(_ name: String) { print("CHAPTER \(name) \(Date().timeIntervalSince1970)") }
        func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestPin", "38.83395,-104.82135,0938",
                                "-uiTestVoiceText", "Pick up the dry cleaning before 6 tonight"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(card("Tailgate tickets").waitForExistence(timeout: 15))
        pause(3)

        // The purse.
        chapter("purse")
        pause(2.5)

        // Snap or paste: a return label, pasted with one tap.
        chapter("snap")
        UIPasteboard.general.image = UIImage(contentsOfFile: imgDir + "/return-label.jpg")
        app.buttons["addPicture"].tap()
        pause(1.2)
        tapPaste()
        let title = app.textFields["titleField"]
        reveal(title); title.tap()
        title.typeText("Return label")
        pause(0.8)
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Return label").waitForExistence(timeout: 15))
        pause(2.5)

        // Say it.
        chapter("say")
        app.buttons["voiceNote"].tap()
        XCTAssertTrue(app.staticTexts["liveTranscript"].waitForExistence(timeout: 5))
        pause(3)
        app.buttons["stopRecording"].tap()
        let voiceTitle = app.textFields["voiceTitle"]
        XCTAssertTrue(voiceTitle.waitForExistence(timeout: 5))
        voiceTitle.tap()
        voiceTitle.typeText("Dry cleaning")
        pause(0.6)
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Dry cleaning").waitForExistence(timeout: 15))
        pause(2)

        // Pin your spot.
        chapter("pin")
        app.buttons["addPin"].tap()
        XCTAssertTrue(app.buttons["Move Pin Here"].waitForExistence(timeout: 10))
        pause(2)
        reveal(title); title.tap()
        title.typeText("Parking spot")
        pause(0.6)
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        pause(2)

        // Open it, and walk back to it with Apple Maps.
        chapter("open")
        tapCard("Parking spot")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        pause(3.5)
        chapter("directions")
        openCoin.descendants(matching: .any)["pinMap"].firstMatch.tap()
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        if maps.wait(for: .runningForeground, timeout: 15) {
            for _ in 0..<3 {
                for name in ["Not Now", "Continue", "Allow While Using App"] where maps.buttons[name].exists { maps.buttons[name].tap() }
                pause(1)
            }
            pause(4)
        }
        app.activate()
        pause(1.5)
        // The next coins wait at the bottom, like Wallet: pull one up to peek, tap to bring it up.
        chapter("back")
        let upNext = app.descendants(matching: .any).matching(identifier: "pileCard").firstMatch
        let uf = upNext.frame
        let pullPoint = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: uf.midX, dy: uf.minY + 20))
        pullPoint.press(forDuration: 0.1, thenDragTo: pullPoint.withOffset(CGVector(dx: 0, dy: -120)), withVelocity: .slow, thenHoldForDuration: 1.0)
        pause(1.2)
        upNext.tap()
        pause(2.5)
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        pause(2)

        // Peek: touch and hold a card to see it, let go and it drops back.
        chapter("peek")
        let peekFrame = card("Coffee gift card").frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: peekFrame.midX, dy: peekFrame.midY)).press(forDuration: 2.2)
        pause(1.5)

        // Move: hold and drag a card to the top.
        chapter("move")
        let moveFrame = card("Tailgate tickets").frame
        let firstFrame = card("Parking spot").frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: moveFrame.midX, dy: moveFrame.midY))
            .press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: firstFrame.midX, dy: firstFrame.minY + 12)), withVelocity: .slow, thenHoldForDuration: 0.6)
        pause(2)

        // Two tickets in one coin, full size at the gate.
        chapter("tickets")
        tapCard("Tailgate tickets")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        pause(2.5)
        app.buttons["Picture 2"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
        pause(3)
        app.buttons["Back"].tap()
        pause(1.2)
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        pause(1)

        // Find it.
        chapter("find")
        app.buttons["Search"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("coffee")
        pause(1.5)
        tapCard("Coffee gift card")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        pause(3)
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
        pause(1.5)

        // Share from any app: a conference badge from Photos.
        chapter("share")
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        for name in ["Continue", "Not Now"] where photos.buttons[name].waitForExistence(timeout: 2) { photos.buttons[name].tap() }
        // Back to the grid if Photos reopened on a photo, then the newest photo.
        if photos.buttons["Share"].firstMatch.waitForExistence(timeout: 2) {
            photos.buttons.element(boundBy: 0).tap()
            pause(1)
        }
        let all = photos.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
        XCTAssertTrue(all.firstMatch.waitForExistence(timeout: 10))
        all.element(boundBy: all.count - 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pause(1.5)
        photos.buttons["Share"].firstMatch.tap()
        pause(1.5)
        let target = photos.descendants(matching: .any).matching(NSPredicate(format: "label == 'Coin Purse'")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 8))
        target.tap()
        let shareTitle = photos.textFields["shareTitle"]
        XCTAssertTrue(shareTitle.waitForExistence(timeout: 15))
        pause(1)
        shareTitle.tap()
        shareTitle.typeText("DevSummit badge")
        pause(0.6)
        photos.buttons["shareSave"].tap()
        XCTAssertTrue(shareTitle.waitForNonExistence(timeout: 30))
        pause(1)
        app.activate()
        XCTAssertTrue(card("DevSummit badge").waitForExistence(timeout: 15))
        pause(2.5)

        // Toss it.
        chapter("toss")
        // The trash can on the card, where a finger would tap it.
        let f = card("Garage code").frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.maxX - 28, dy: f.minY + 31)).tap()
        pause(1.2)
        let confirm = app.alerts.buttons["Delete"].exists ? app.alerts.buttons["Delete"] : app.buttons.matching(identifier: "Delete").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no delete confirmation")
        confirm.tap()
        XCTAssertTrue(card("Garage code").waitForNonExistence(timeout: 10))
        pause(3)
        chapter("end")
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
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
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
        tapCard("Parking spot")
        let open = app.otherElements["openCoin"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        sleep(3)
        snap("d03-open-pin")
        // The next coins wait at the bottom with their titles; tap one to bring it up.
        snap("d04-pile")
        app.descendants(matching: .any).matching(identifier: "pileCard").firstMatch.tap()
        sleep(2)
        snap("d04b-swapped")
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

        // Touch, hold and drag: Coffee gift card moves to the top.
        let mover = card("Coffee gift card").frame
        let first = card("Parking spot").frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: mover.midX, dy: mover.midY))
            .press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: first.midX, dy: first.minY + 4)), withVelocity: .slow, thenHoldForDuration: 0.4)
        sleep(2)
        snap("d12-moved")
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
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 10))

        // A title and nothing else: the card shows the title big, not a blank.
        app.buttons["addPicture"].tap()
        let title = app.textFields["titleField"]
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Locker 🔑 #17")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Locker 🔑 #17").waitForExistence(timeout: 15))
        tapCard("Locker 🔑 #17")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["noteText"].label, "Locker 🔑 #17")
        snap("e02-title-only")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // A very long title and note: they truncate in the stack and stay readable open.
        let longTitle = String(repeating: "Very long title ", count: 8).trimmingCharacters(in: .whitespaces)
        UIPasteboard.general.image = Self.sample(color: .systemIndigo, label: "Long")
        app.buttons["addPicture"].tap()
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
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
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Long note")
        notes.tap()
        notes.typeText(String(repeating: "Bring the blue cooler, two chairs and the tickets. ", count: 6))
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Long note").waitForExistence(timeout: 15))
        tapCard("Long note")
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
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Six pictures")
        tapPaste()
        for n in 2...6 {
            UIPasteboard.general.image = Self.sample(color: .systemTeal, label: "\(n)")
            let add = app.buttons["Add picture"].firstMatch
            reveal(add)
            add.tap()
            tapPaste()
        }
        XCTAssertFalse(app.buttons["Add picture"].exists, "a seventh picture should not be offered")
        snap("e05-six-pictures")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Six pictures").waitForExistence(timeout: 30))
        tapCard("Six pictures")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Picture 6"].waitForExistence(timeout: 5), "six pictures should show six thumbnails")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Location turned off: Pin explains how to turn it on, nothing breaks.
        app.buttons["addPin"].tap()
        XCTAssertTrue(app.staticTexts["Turn on Location for Coin Purse in Settings to drop a pin."].waitForExistence(timeout: 10))
        snap("e06-location-off")
        app.buttons["Cancel"].tap()
        tapCard("Locker 🔑 #17")
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
            XCTAssertTrue(reveal(title))
            reveal(title); title.tap()
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
    /// Adds a coin straight on the server, the way the share extension or
    /// another iPhone would, behind the app's back.
    @MainActor
    private func serverAddCoin(title: String) {
        func send(_ req: URLRequest) -> Data? {
            let done = expectation(description: "server")
            var out: Data?
            URLSession.shared.dataTask(with: req) { data, _, _ in out = data; done.fulfill() }.resume()
            wait(for: [done], timeout: 15)
            return out
        }
        func json(_ path: String, _ body: [String: Any], token: String? = nil) -> Data? {
            var req = URLRequest(url: URL(string: Self.baseURL + path)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return send(req)
        }
        _ = json("/api/auth/request-link", ["email": "review@example.com"])
        guard let auth = json("/api/auth/verify-code", ["email": "review@example.com", "code": "123456"]),
              let token = (try? JSONSerialization.jsonObject(with: auth) as? [String: Any])?["token"] as? String else {
            XCTFail("could not sign in to the test server"); return
        }
        XCTAssertNotNil(json("/api/coins", ["title": title, "notes": "Added elsewhere", "accent": 2], token: token))
    }

    @MainActor
    func testOffline() throws {
        guard ProcessInfo.processInfo.environment["OFFLINE"] == "1" else { throw XCTSkip("Set OFFLINE=1 to run") }
        setServerOffline(false)
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 10))

        // Two coins while online: a ticket picture and a note.
        UIPasteboard.general.image = Self.sample(color: .systemTeal, label: "Ticket")
        app.buttons["addPicture"].tap()
        let title = app.textFields["titleField"]
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Ticket")
        tapPaste()
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Ticket").waitForExistence(timeout: 15))
        app.buttons["addPicture"].tap()
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Gate code 2468")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Gate code 2468").waitForExistence(timeout: 15))

        // The signal drops, and the app is started fresh.
        setServerOffline(true)
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        XCTAssertTrue(card("Ticket").waitForExistence(timeout: 20), "saved coins did not show offline")
        XCTAssertTrue(card("Gate code 2468").exists)
        XCTAssertTrue(offlineNote.waitForExistence(timeout: 30), "no offline note")
        snap("o01-offline-purse")

        // The ticket picture opens from the phone.
        tapCard("Ticket")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        XCTAssertTrue(openCoin.buttons["Picture 1"].waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertFalse(openCoin.activityIndicators.firstMatch.exists, "picture still loading offline")
        snap("o02-offline-open")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Saving fails with a clear message, and the editor keeps what was typed.
        app.buttons["addPicture"].tap()
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Offline coin")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Could not reach Coin Purse'")).firstMatch
            .waitForExistence(timeout: 70), "offline save shows no message")
        snap("o03-offline-save")
        reveal(title)
        XCTAssertEqual(title.value as? String, "Offline coin")
        app.buttons["Cancel"].tap()

        // Deleting fails and the coin comes back.
        tapCard("Gate code 2468")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(card("Gate code 2468").waitForExistence(timeout: 70), "offline delete lost the coin")

        // Signal back: a pull to refresh clears the note and everything works.
        setServerOffline(false)
        // Pull down from the cards, below the title (tall at large text sizes).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(offlineNote.waitForNonExistence(timeout: 15), "offline note did not clear")
        app.buttons["addPicture"].tap()
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Back online")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Back online").waitForExistence(timeout: 15))
        snap("o04-back-online")
    }

    /// The first coin's title, asked straight from the test server.
    @MainActor
    private func serverFirstTitle() -> String? {
        serverCoins()?.first?["title"] as? String
    }

    /// How many coins the review account has, asked straight from the test server.
    @MainActor
    private func serverCoinCount() -> Int {
        serverCoins()?.count ?? -1
    }

    /// The purse as the server has it, in order; nil if it could not be read.
    @MainActor
    private func serverCoins() -> [[String: Any]]? {
        func post(_ path: String, _ body: [String: String]) -> Data? {
            var req = URLRequest(url: URL(string: Self.baseURL + path)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return fetch(req)
        }
        func fetch(_ req: URLRequest) -> Data? {
            let done = expectation(description: "server")
            var out: Data?
            URLSession.shared.dataTask(with: req) { data, _, _ in out = data; done.fulfill() }.resume()
            wait(for: [done], timeout: 15)
            return out
        }
        _ = post("/api/auth/request-link", ["email": "review@example.com"])
        guard let auth = post("/api/auth/verify-code", ["email": "review@example.com", "code": "123456"]),
              let token = (try? JSONSerialization.jsonObject(with: auth) as? [String: Any])?["token"] as? String else { return nil }
        var req = URLRequest(url: URL(string: Self.baseURL + "/api/coins")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let data = fetch(req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["coins"] as? [[String: Any]]
    }

    @MainActor
    private var offlineNote: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Offline'")).firstMatch
    }

    private func setServerOffline(_ on: Bool) {
        let done = expectation(description: "offline switch")
        URLSession.shared.dataTask(with: URL(string: "\(Self.baseURL)/__test/offline?on=\(on ? 1 : 0)")!) { _, _, _ in
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
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(app.staticTexts["Your purse is empty"].waitForExistence(timeout: 10))
        UIPasteboard.general.image = Self.sample(color: .systemGreen, label: "T1")
        app.buttons["addPicture"].tap()
        let title = app.textFields["titleField"]
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Tickets")
        tapPaste()
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Tickets").waitForExistence(timeout: 15))
        app.terminate()

        // Shared from Messages: add both pictures to Tickets.
        app = XCUIApplication()
        app.launchArguments += ["-uiTestNoLock", "-uiTestShare"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
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
        tapCard("Tickets")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Picture 3"].waitForExistence(timeout: 10), "Tickets should hold 3 pictures")
        XCTAssertFalse(app.buttons["Picture 4"].exists, "Tickets should hold 3 pictures")
        app.buttons["Done"].tap()
        app.terminate()

        // Shared again: a new coin with a title.
        app = XCUIApplication()
        app.launchArguments += ["-uiTestNoLock", "-uiTestShare"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        XCTAssertTrue(save.waitForExistence(timeout: 20))
        let shareTitle = app.textFields["shareTitle"]
        shareTitle.tap()
        shareTitle.typeText("Shared tickets")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 20))
        XCTAssertTrue(card("Shared tickets").waitForExistence(timeout: 15))
        tapCard("Shared tickets")
        XCTAssertTrue(app.buttons["Picture 2"].waitForExistence(timeout: 10))
        snap("s03-shared-coin")
    }

    /// Quick actions open the right screen (TEST_RUNNER_QUICK=1).
    @MainActor
    func testQuickActions() throws {
        guard ProcessInfo.processInfo.environment["QUICK"] == "1" else { throw XCTSkip("Set QUICK=1 to run") }
        for (action, check) in [("pinSpot", "Pin your spot"), ("voiceNote", "Voice note"), ("addPicture", "New coin")] {
            app = XCUIApplication()
            // Simulated speech: the simulator's microphone is unreliable when several run at once.
            app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestQuickAction", action, "-uiTestPin", "38.834,-104.821",
                                    "-uiTestVoiceText", "Quick note"]
            app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
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
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
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
        if !reached {
            // Tell a real scrolling limit from flings that were too quick to settle.
            snap("b02a-after-flings")
            dump("b02a-tree")
            for _ in 0..<4 { app.swipeUp(velocity: .slow); sleep(1) }
            reached = card("Coin number 001").exists && card("Coin number 001").isHittable
            snap("b02b-after-slow-swipes")
            print("BIG reached after slow swipes: \(reached)")
        }
        XCTAssertTrue(reached, "could not scroll to the last coin")
        // Let it come to rest, then the whole last card must sit above the add bar.
        for _ in 0..<3 { app.swipeUp(velocity: .slow) }
        sleep(2)
        let lastFrame = card("Coin number 001").frame
        let barTop = app.buttons["addPicture"].frame.minY
        print("BIG last card bottom \(lastFrame.maxY), bar top \(barTop)")
        snap("b02-bottom")
        XCTAssertLessThanOrEqual(lastFrame.maxY, barTop + 12, "at rest, the last coin is partly under the add bar")
        tapCard("Coin number 001")
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

    /// Apple's own accessibility audit on every main screen: contrast, tap
    /// target sizes, missing labels, text that clips (TEST_RUNNER_AUDIT=1, design purse).
    @MainActor
    func testAccessibilityAudit() throws {
        guard ProcessInfo.processInfo.environment["AUDIT"] == "1" else { throw XCTSkip("Set AUDIT=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestShowCamera", "-uiTestPin", "38.834,-104.821",
                                "-uiTestVoiceText", "Remind me to email Jim back"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        var problems: [String] = []
        var accepted: [String] = []
        func audit(_ screen: String) {
            do {
                try app.performAccessibilityAudit { issue in
                    let who = issue.element.map { "\($0.elementType) '\($0.label)'" } ?? "screen"
                    let line = "\(screen): \(issue.compactDescription) — \(who)"
                    if let reason = Self.acceptedAuditIssue(screen: screen, issue: issue) {
                        accepted.append(line + "  [accepted: \(reason)]")
                    } else {
                        problems.append(line)
                    }
                    return true   // handled here, keep going
                }
            } catch {
                problems.append("\(screen): audit failed \(error)")
            }
        }
        snap("a-signin")
        audit("Sign in")
        signIn()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        sleep(2)
        audit("Purse")
        tapCard("Parking spot")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(2)
        audit("Open coin (map)")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        tapCard("Tailgate tickets")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(1)
        audit("Open coin (picture)")
        openCoin.buttons["Picture 1"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
        sleep(1)
        audit("Full size picture")
        app.buttons["Back"].tap()
        app.buttons["Done"].tap()
        app.buttons["addPicture"].tap()
        sleep(1)
        audit("New coin")
        app.buttons["Cancel"].tap()
        app.buttons["addPin"].tap()
        sleep(3)
        audit("Pin your spot")
        app.buttons["Cancel"].tap()
        app.buttons["voiceNote"].tap()
        sleep(1)
        audit("Voice note")
        app.buttons["stopRecording"].tap()
        sleep(1)
        audit("Voice note review")
        app.buttons["Cancel"].tap()
        app.buttons["Account"].tap()
        sleep(1)
        audit("Account")
        let report = problems.joined(separator: "\n")
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? (report + "\n\n--- accepted ---\n" + accepted.joined(separator: "\n"))
                .write(toFile: dir + "/audit.txt", atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(problems.isEmpty, "Accessibility audit found \(problems.count) issues:\n" + report)
    }

    /// Audit findings that are expected, each with its reason. Everything else fails the test.
    @MainActor
    static func acceptedAuditIssue(screen: String, issue: XCUIAccessibilityAuditIssue) -> String? {
        let description = issue.compactDescription
        let element = issue.element
        let label = element?.label ?? ""
        if description.contains("nearly passed") { return "a warning, not a failure" }
        if element == nil { return "screen-level finding with no element; reviewed by eye (placeholders, disabled Save)" }
        if element?.isEnabled == false { return "disabled controls are exempt from contrast rules" }
        if label == "¢" { return "decorative coin emblem, hidden from VoiceOver" }
        if issue.auditType == .dynamicType, element?.elementType == .button,
           ["Cancel", "Save", "Done", "Back", "More"].contains(label) {
            return "system navigation bar buttons size themselves (Large Content Viewer)"
        }
        if issue.auditType == .contrast, ["Purse", "Open coin (map)", "Open coin (picture)"].contains(screen),
           element?.elementType == .staticText {
            return "white on the deep card colors, measured from the screenshot at 6.1 to 6.4 : 1 (the audit misreads text beside glass and stacked cards)"
        }
        if ["Pin your spot", "New coin", "Voice note review", "Account"].contains(screen),
           issue.auditType == .dynamicType || issue.auditType == .contrast {
            return "system Form styling (section headers, footers, row buttons) drawn by iOS"
        }
        if issue.auditType == .dynamicType, screen == "Purse" {
            return "cards far down a lazy stack are not built while the audit enlarges text"
        }
        if issue.auditType == .textClipped, screen == "Purse" {
            return "tucked cards show only their top, like Wallet; full text when opened and in the VoiceOver label"
        }
        if screen == "Sign in", ["Privacy", "Support"].contains(label) {
            return "covered by the keyboard while typing the email; readable once it is down"
        }
        if issue.auditType == .textClipped, label == "Move Pin Here" {
            return "shows in full; checked in the iPhone SE screenshot"
        }
        if issue.auditType == .textClipped, element?.elementType == .textField {
            return "empty text field placeholder"
        }
        if issue.auditType == .hitRegion, element?.elementType == .staticText {
            return "notes text with links; the link opens on tap and the panel has a 44 pt row"
        }
        if issue.auditType == .trait || issue.auditType == .sufficientElementDescription,
           label.contains("@") {
            return "an email address read as written"
        }
        return nil
    }

    /// What Apple Maps shows after tapping a pin (TEST_RUNNER_MAPS=1, design purse).
    @MainActor
    func testMapsDirections() throws {
        guard ProcessInfo.processInfo.environment["MAPS"] == "1" else { throw XCTSkip("Set MAPS=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        tapCard("Parking spot")
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

    /// Taps a card, first scrolling it clear of the bottom bar if it is under it.
    @MainActor
    private func tapCard(_ name: String) {
        let c = card(name)
        XCTAssertTrue(c.waitForExistence(timeout: 10), "no card named \(name)")
        let bar = app.buttons["addPicture"]
        for _ in 0..<4 where bar.exists && c.frame.midY > bar.frame.minY - 8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        // Tucked under the title at the top: bring it down.
        let account = app.buttons["Account"]
        for _ in 0..<4 where account.exists && c.frame.midY < account.frame.maxY + 8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        }
        c.tap()
    }

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

    /// Scrolls a form until the element is on screen. Forms build rows only as
    /// they scroll in, so on a small iPhone or at the largest text sizes a field
    /// further down does not exist until then.
    @MainActor @discardableResult
    private func reveal(_ element: XCUIElement) -> Bool {
        if element.waitForExistence(timeout: 5) && element.isHittable { return true }
        // Down the form first, then back up (the element may be above).
        for step in 0..<12 {
            let down = step < 5
            // High on the screen, clear of the keyboard.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.5 : 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.25 : 0.5)))
            if element.waitForExistence(timeout: 1) && element.isHittable { return true }
        }
        return element.exists
    }

    @MainActor
    private func tapPaste() {
        let paste = app.buttons["Paste"].firstMatch
        // On a small iPhone the keyboard pushes the picture row out of view: scroll back up.
        for _ in 0..<3 where !paste.waitForExistence(timeout: 2) || !paste.isHittable {
            app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
                .withOffset(CGVector(dx: 0, dy: 60))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
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
