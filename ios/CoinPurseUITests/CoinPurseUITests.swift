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
        newCoin("Picture")
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
        newCoin("Picture")
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Gift card")
        tapPaste()
        XCTAssertTrue(app.buttons["Crop or rotate"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Gift card").waitForExistence(timeout: 15))

        // A quick coin: picture only, so it is named Coin 1. Then toss it.
        UIPasteboard.general.image = Self.sample(color: .systemGreen, label: "Note")
        newCoin("Picture")
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

        // Swipe the card to the second picture (its thumbnail lights up), then
        // tap it: the viewer opens on that picture, with share and crop.
        // On the picture itself, just above the thumbnails (at the largest text
        // sizes the middle of the open coin is its notes).
        let thumbs = app.buttons.matching(identifier: "thumbnail").firstMatch.frame
        let onPicture = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: thumbs.minX + 260, dy: thumbs.minY - 50))
        onPicture.press(forDuration: 0.05, thenDragTo: onPicture.withOffset(CGVector(dx: -220, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
        let thumb2 = app.buttons.matching(identifier: "thumbnail").matching(NSPredicate(format: "label == 'Picture 2'")).firstMatch
        XCTAssertTrue(thumb2.isSelected, "swiping did not move to picture 2")
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
        newCoin("Voice Note")
        XCTAssertTrue(app.staticTexts["liveTranscript"].waitForExistence(timeout: 5))
        snap("12-voice-listening")
        app.buttons["stopRecording"].tap()
        // Done saves it at once, just as it was said; Add details names it.
        nameJustSaved("Groceries")
        XCTAssertTrue(card("Groceries").waitForExistence(timeout: 15))
        XCTAssertEqual(serverCoins()?.first { $0["title"] as? String == "Groceries" }?["notes"] as? String,
                       "Milk, eggs, avocados, coffee and bread", "the voice note was not saved as said")
        tapCard("Groceries")
        XCTAssertTrue(app.descendants(matching: .any)["noteText"].waitForExistence(timeout: 5), "text coin did not open")
        snap("15-voice-open")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Pin your spot from the bottom bar: it finds you straight away.
        newCoin("Typed Note"); pinInEditor()
        XCTAssertTrue(reveal(app.buttons["Move Pin Here"]), "Pin did not find a spot")
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
        cancelSheet()

        // Add a voice note; untitled, so it takes the next number (the seed has a Coin 1).
        newCoin("Voice Note")
        XCTAssertTrue(app.staticTexts["liveTranscript"].waitForExistence(timeout: 5))
        app.buttons["stopRecording"].tap()
        // Done saves it at once.
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
        // 30 + 1 added - 5 deleted, and still 26 after a refresh (the last
        // delete reaches the server once its Undo moment has passed).
        sleep(6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        sleep(3)
        XCTAssertEqual(serverCoinCount(), 26)
        snap("tour-final")
    }

    /// Swipe a coin's bar to the left to delete it, as in Mail: a short swipe
    /// shows Delete and closes again with a tap; Delete then Undo keeps the
    /// coin; a full swipe deletes it on the server once Undo has passed
    /// (TEST_RUNNER_SWIPE=1, seed_design.py).
    @MainActor
    func testSwipeToDelete() throws {
        guard ProcessInfo.processInfo.environment["SWIPE"] == "1" else { throw XCTSkip("Set SWIPE=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        sleep(1)
        let start = serverCoinCount()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let delete = app.buttons["swipeDelete"]
        func swipe(_ name: String, by dx: CGFloat, fast: Bool = false) {
            let f = showCard(name).frame
            let from = origin.withOffset(CGVector(dx: f.maxX - 70, dy: f.midY))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: dx, dy: 0)),
                       withVelocity: fast ? .fast : .slow, thenHoldForDuration: fast ? 0 : 0.1)
            sleep(1)
        }

        // A short swipe: Delete shows; a tap elsewhere closes it and opens nothing.
        swipe("Coffee gift card", by: -120)
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "a short swipe did not show Delete")
        snap("w01-swiped-open")
        tapCard("Parking spot")
        sleep(1)
        XCTAssertFalse(openCoin.exists, "a tap that closes a swiped card opened a coin")
        XCTAssertFalse(delete.exists, "a tap did not close the swiped card")

        // Delete, then Undo: the coin comes back and stays on the server.
        swipe("Coffee gift card", by: -120)
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        // Delete shows in the strip the card uncovered, at its right edge.
        let red = delete.frame
        origin.withOffset(CGVector(dx: red.maxX - 44, dy: red.minY + 31)).tap()
        XCTAssertTrue(card("Coffee gift card").waitForNonExistence(timeout: 5), "Delete did not remove the coin")
        let undo = app.buttons["undoDelete"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no Undo after deleting")
        snap("w02-undo")
        undo.tap()
        XCTAssertTrue(card("Coffee gift card").waitForExistence(timeout: 5), "Undo did not bring the coin back")
        sleep(7)
        XCTAssertEqual(serverCoinCount(), start, "Undo still deleted the coin on the server")

        // A full swipe across deletes without asking; after the Undo moment it
        // is gone from the server too.
        let f = card("Grocery list").frame
        swipe("Grocery list", by: -(f.width - 40), fast: true)
        XCTAssertFalse(app.alerts.firstMatch.exists, "a full swipe asked first")
        XCTAssertTrue(card("Grocery list").waitForNonExistence(timeout: 5), "a full swipe did not delete the coin")
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        sleep(7)
        XCTAssertFalse(undo.exists, "the Undo bar did not go away")
        XCTAssertEqual(serverCoinCount(), start - 1, "the server still has the swiped coin")
        XCTAssertFalse((serverCoins() ?? []).contains { $0["title"] as? String == "Grocery list" })

        // The trash can (it asks first) also offers Undo.
        let email = showCard("Email Jim back").frame
        origin.withOffset(CGVector(dx: email.maxX - 28, dy: email.midY)).tap()
        XCTAssertTrue(app.alerts.buttons["Delete"].waitForExistence(timeout: 5), "the trash can did not ask first")
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(card("Email Jim back").waitForNonExistence(timeout: 5))
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no Undo after the trash can")
        undo.tap()
        XCTAssertTrue(card("Email Jim back").waitForExistence(timeout: 5), "Undo did not bring back the trashed coin")
        sleep(7)
        XCTAssertEqual(serverCoinCount(), start - 1, "Undo after the trash can still deleted the coin")

        // Pulled down, a spinner shows the purse is refreshing.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        // (The spinner itself is checked on film in testDragFilm: the test
        // runner waits for the screen to stop moving before it looks.)
        sleep(2)

        // Swipe to Delete can be turned off in Account, and back on.
        app.buttons["Account"].tap()
        let setting = app.switches["Swipe to Delete"]
        XCTAssertTrue(setting.waitForExistence(timeout: 5), "no Swipe to Delete setting")
        XCTAssertEqual(setting.value as? String, "1", "Swipe to Delete should start on")
        setting.switches.firstMatch.tap()
        XCTAssertEqual(setting.value as? String, "0")
        app.navigationBars["Account"].buttons["Done"].firstMatch.tap()
        sleep(1)
        swipe("Parking spot", by: -120)
        XCTAssertFalse(delete.exists, "swiping still worked with Swipe to Delete off")
        XCTAssertTrue(card("Parking spot").exists)
        app.buttons["Account"].tap()
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        setting.switches.firstMatch.tap()
        app.navigationBars["Account"].buttons["Done"].firstMatch.tap()
        sleep(1)
        swipe("Parking spot", by: -120)
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "swiping did not come back with Swipe to Delete on")
        tapCard("Tailgate tickets")
        sleep(1)

        // Scrolling still works with swiping on the cards.
        XCTAssertTrue(card("Parking spot").isHittable)
        snap("w03-after")
    }

    /// The archive and Hide with Face ID: archive by swipe and from an open
    /// coin, Undo, the archive list, Unarchive, search under In Archive, and a
    /// hidden coin covered until Face ID, each checked on the server
    /// (TEST_RUNNER_ARCHIVE=1, seed_design.py).
    @MainActor
    func testArchiveAndHide() throws {
        guard ProcessInfo.processInfo.environment["ARCHIVE"] == "1" else { throw XCTSkip("Set ARCHIVE=1 to run") }
        app = XCUIApplication()
        // Face ID always says yes here (the simulator has none to check).
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestRevealOK"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        sleep(1)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        func server(_ title: String) -> [String: Any]? { serverCoins()?.first { $0["title"] as? String == title } }
        XCTAssertFalse(app.buttons["archive"].exists, "the Archive button shows with nothing archived")

        // 1. Swipe, then Archive: the coin leaves the purse, with Undo.
        let f = showCard("Coffee gift card").frame
        let from = origin.withOffset(CGVector(dx: f.maxX - 70, dy: f.midY))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -190, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(1)
        let archiveSwipe = app.buttons["swipeArchive"]
        XCTAssertTrue(archiveSwipe.waitForExistence(timeout: 3), "a swipe did not show Archive")
        // Archive sits just left of Delete, in the strip the card uncovered.
        let red = app.buttons["swipeDelete"].frame
        origin.withOffset(CGVector(dx: red.maxX - 88 - 44, dy: red.minY + 31)).tap()
        XCTAssertTrue(card("Coffee gift card").waitForNonExistence(timeout: 5), "Archive did not take the coin out of the purse")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Archived'")).firstMatch.waitForExistence(timeout: 3),
                      "no Archived note with Undo")
        snap("a01-archived")
        sleep(3)
        XCTAssertEqual(server("Coffee gift card")?["archived"] as? Bool, true, "the server did not keep it archived")
        XCTAssertNotNil(server("Coffee gift card"), "archiving deleted the coin")

        // 2. From an open coin, Archive; then Undo puts it back.
        tapCard("Email Jim back")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        // The open coin's Archive, in its row of buttons.
        app.buttons["archiveCoin"].tap()
        XCTAssertTrue(card("Email Jim back").waitForNonExistence(timeout: 5))
        app.buttons["undoDelete"].tap()
        XCTAssertTrue(card("Email Jim back").waitForExistence(timeout: 5), "Undo did not bring the coin back")
        sleep(3)
        XCTAssertEqual(server("Email Jim back")?["archived"] as? Bool, false, "Undo left it archived on the server")

        // 3. Search finds archived coins too, under In Archive.
        let search = app.buttons["Search"]
        if search.exists {
            search.tap()
            app.textFields["searchField"].typeText("coffee")
            XCTAssertTrue(app.buttons["archiveMatch"].waitForExistence(timeout: 5), "search did not find the archived coin")
            snap("a02-in-archive")
            app.buttons["Cancel"].firstMatch.tap()
            sleep(1)
        }

        // 4. The archive: view it (it stays archived), then Unarchive it to the top.
        let archiveButton = app.buttons["archive"]
        XCTAssertTrue(archiveButton.waitForExistence(timeout: 5), "no Archive button")
        archiveButton.tap()
        let row = app.buttons["archivedCoin"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the archive is empty")
        snap("a03-archive")
        row.tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5), "an archived coin did not open")
        XCTAssertEqual(openCoin.staticTexts["coinTitle"].label, "Coffee gift card")
        snap("a04-archived-open")
        let unarchive = app.buttons["Unarchive"]
        XCTAssertTrue(unarchive.waitForExistence(timeout: 5))
        sleep(1)
        // At the largest text sizes it is below the screen: scroll the buttons
        // under the card (a drag on the card itself would close it).
        for _ in 0..<5 where !unarchive.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)))
        }
        unarchive.tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5), "Unarchive did not close the coin")
        sleep(1)
        app.navigationBars["Archive"].buttons["Done"].firstMatch.tap()
        XCTAssertTrue(card("Coffee gift card").waitForExistence(timeout: 5), "Unarchive did not put it back in the purse")
        sleep(3)
        XCTAssertEqual(server("Coffee gift card")?["archived"] as? Bool, false)
        XCTAssertEqual(serverFirstTitle(), "Coffee gift card", "an unarchived coin should come back on top")
        XCTAssertFalse(app.buttons["archive"].exists, "the Archive button stayed with nothing archived")

        // 5. Hide with Face ID: the card looks as usual, but opening it asks for
        // Face ID every time (closing it locks it again).
        // One tap on Face ID in the open coin's row.
        tapCard("Tailgate tickets")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        let lock = app.buttons["hideLock"]
        XCTAssertTrue(lock.waitForExistence(timeout: 3), "no Face ID button on the open coin")
        XCTAssertEqual(lock.value as? String, "Off")
        lock.tap()
        XCTAssertEqual(lock.value as? String, "On", "Face ID did not hide the coin")
        snap("a04b-lock-on")
        XCTAssertTrue(openCoin.exists, "hiding the coin you are looking at should not close it")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        sleep(2)
        XCTAssertEqual(server("Tailgate tickets")?["hidden"] as? Bool, true, "the server did not keep it hidden")
        // Closed: locked again at once, its title still showing.
        XCTAssertEqual(card("Tailgate tickets").value as? String, "Hidden", "a closed hidden coin did not lock again")
        snap("a05-hidden")
        tapCard("Tailgate tickets")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5), "a hidden coin did not open after Face ID")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        sleep(1)
        XCTAssertEqual(card("Tailgate tickets").value as? String, "Hidden", "after closing, the next open should ask again")
        // Leaving the app keeps it locked too.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(card("Tailgate tickets").waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertEqual(card("Tailgate tickets").value as? String, "Hidden")

        // Hidden with the editor's switch this time: the card at the bottom
        // still shows its window as usual.
        // (At the largest text sizes the bottom card is not built until scrolled to.)
        // 6. Without Face ID, a hidden coin cannot be deleted: not with its trash
        // can, not with a swipe. (Face ID says no for this launch.)
        app.terminate()
        app.launchArguments = ["-uiTestNoLock", "-uiTestRevealNo"]
        app.launch()
        XCTAssertTrue(showCard("Tailgate tickets").waitForExistence(timeout: 15))
        sleep(2)
        app.buttons["Delete Tailgate tickets"].firstMatch.tap()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "a hidden coin asked to delete without Face ID")
        let hidden = showCard("Tailgate tickets").frame
        let grab = origin.withOffset(CGVector(dx: hidden.maxX - 70, dy: hidden.midY))
        grab.press(forDuration: 0.05, thenDragTo: grab.withOffset(CGVector(dx: -330, dy: 0)),
                   withVelocity: XCUIGestureVelocity.fast, thenHoldForDuration: 0)
        sleep(3)
        XCTAssertTrue(card("Tailgate tickets").exists, "a swipe deleted a hidden coin without Face ID")
        XCTAssertFalse(app.buttons["undoDelete"].exists)
        XCTAssertNotNil(server("Tailgate tickets"), "the hidden coin was deleted on the server")
        snap("a05b-delete-refused")
        app.terminate()
        app.launchArguments = ["-uiTestNoLock", "-uiTestRevealOK"]
        app.launch()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        sleep(1)

        guard card("Return label").waitForExistence(timeout: 3) else { return }
        tapCard("Return label")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        app.buttons["openEditor"].tap()
        let toggle = app.switches["hideToggle"]
        XCTAssertTrue(reveal(toggle), "no Hide with Face ID switch in the editor")
        toggle.switches.firstMatch.tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(card("Return label").waitForExistence(timeout: 10))
        sleep(2)
        snap("a06-hidden-window")
    }

    /// Quick capture: the camera button saves a picture as a coin at once, with
    /// Add details and Undo; the microphone saves a voice note when you tap
    /// Done; New Coin takes a voice note into its notes; each checked on the
    /// server (TEST_RUNNER_QUICK2=1, seed_design.py).
    @MainActor
    func testQuickCapture() throws {
        guard ProcessInfo.processInfo.environment["QUICK2"] == "1" else { throw XCTSkip("Set QUICK2=1 to run") }
        app = XCUIApplication()
        // A ready-made "camera" picture and simulated speech (the simulator has neither).
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestCameraSample",
                                "-uiTestVoiceText", "Grain free salmon, the big blue bag"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        sleep(1)
        let start = serverCoinCount()

        // 1. One tap on the camera: the picture is a coin, opened to look at.
        app.buttons["newPhoto"].tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 15), "the new picture coin did not open")
        snap("q01-opened")
        XCTAssertEqual(serverCoinCount(), start + 1, "the picture was not saved as a coin")
        XCTAssertNotNil(serverCoins()?.first?["imagePath"] as? String, "the new coin has no picture")
        // Full size: tap the name (Coin 3) to change it.
        openCoin.buttons["Picture 1"].firstMatch.tap()
        let viewerTitle = app.buttons["viewerTitle"]
        XCTAssertTrue(viewerTitle.waitForExistence(timeout: 5), "no name to tap in full size")
        viewerTitle.tap()
        rename(to: "Dog food")
        XCTAssertTrue(app.staticTexts["Dog food"].waitForExistence(timeout: 5), "full size still shows the old name")
        app.buttons["Back"].tap()
        sleep(2)
        XCTAssertEqual(serverFirstTitle(), "Dog food")
        // On the open coin too: tap the name.
        openCoin.staticTexts["coinTitle"].tap()
        rename(to: "Dog food bag")
        XCTAssertTrue(openCoin.staticTexts.matching(NSPredicate(format: "label == 'Dog food bag'")).firstMatch
            .waitForExistence(timeout: 5), "the open coin kept the old name")
        sleep(2)
        XCTAssertEqual(serverFirstTitle(), "Dog food bag")
        // No Share for the whole coin; Archive and Face ID are in the row.
        XCTAssertFalse(openCoin.buttons["Share"].exists || app.buttons["Share"].exists, "Share for a whole coin is gone")
        XCTAssertTrue(app.buttons["archiveCoin"].exists && app.buttons["hideLock"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // 2. A bad shot: Delete in the open coin takes it away again.
        app.buttons["newPhoto"].tap()
        XCTAssertTrue(openCoin.waitForExistence(timeout: 15))
        sleep(1)
        app.buttons["Delete"].tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        sleep(8)
        XCTAssertEqual(serverCoinCount(), start + 1, "Delete did not remove the new coin")
        XCTAssertEqual(serverFirstTitle(), "Dog food bag")

        // A pin shares on its own, from the map.
        tapCard("Parking spot")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(1)
        // Swipe the card over to the map (the last page).
        let thumbs = app.buttons.matching(identifier: "thumbnail").firstMatch.frame
        let onPicture = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: thumbs.minX + 260, dy: thumbs.minY - 50))
        onPicture.press(forDuration: 0.05, thenDragTo: onPicture.withOffset(CGVector(dx: -220, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
        XCTAssertTrue(app.buttons["sharePin"].waitForExistence(timeout: 5), "no Share on the pin")
        snap("q03-map")
        // A thumbnail goes back to the picture.
        let thumb1 = app.buttons.matching(identifier: "thumbnail").matching(NSPredicate(format: "label == 'Picture 1'")).firstMatch
        thumb1.tap()
        sleep(1)
        XCTAssertTrue(thumb1.isSelected, "tapping a thumbnail did not show that page")
        let mapThumb = app.buttons.matching(identifier: "thumbnail").matching(NSPredicate(format: "label == 'Map pin'")).firstMatch
        mapThumb.tap()
        sleep(1)
        XCTAssertTrue(mapThumb.isSelected, "tapping the map thumbnail did not show the map")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // 3. One tap on the microphone, talk, Done: saved as said.
        app.buttons["newVoice"].tap()
        XCTAssertTrue(app.staticTexts["liveTranscript"].waitForExistence(timeout: 5))
        app.buttons["stopRecording"].tap()
        XCTAssertTrue(app.buttons["addDetails"].waitForExistence(timeout: 15), "no Saved bar after a voice note")
        sleep(1)
        XCTAssertEqual(serverCoins()?.first?["notes"] as? String, "Grain free salmon, the big blue bag")
        app.buttons["undoSaved"].tap()
        sleep(2)

        // 4. New Coin: a voice note into the notes, then Save.
        app.buttons["newCoin"].tap()
        let dictate = app.buttons["dictate"]
        XCTAssertTrue(reveal(dictate), "no voice note in New Coin")
        dictate.tap()
        XCTAssertTrue(app.staticTexts["liveTranscript"].waitForExistence(timeout: 5))
        app.buttons["stopRecording"].tap()
        let title = app.textFields["titleField"]
        XCTAssertTrue(reveal(title))
        title.tap()
        title.typeText("Pet store")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Pet store").waitForExistence(timeout: 15))
        XCTAssertEqual(serverCoins()?.first { $0["title"] as? String == "Pet store" }?["notes"] as? String,
                       "Grain free salmon, the big blue bag", "the voice note did not go into the notes")
        snap("q02-after")
    }

    /// A plain open and close, twice, to film and check frame by frame
    /// (TEST_RUNNER_OPENCLOSE=1, seed_design.py).
    @MainActor
    func testOpenCloseFilm() throws {
        guard ProcessInfo.processInfo.environment["OPENCLOSE"] == "1" else { throw XCTSkip("Set OPENCLOSE=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        sleep(2)
        for title in ["Parking spot", "Email Jim back"] {
            tapCard(title)
            XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
            sleep(2)
            app.buttons["Done"].tap()
            XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
            sleep(2)
        }
    }

    /// Slow card moves to film and check frame by frame (TEST_RUNNER_DRAGFILM=1, seed_design.py).
    @MainActor
    func testDragFilm() throws {
        guard ProcessInfo.processInfo.environment["DRAGFILM"] == "1" else { throw XCTSkip("Set DRAGFILM=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(card("Parking spot").waitForExistence(timeout: 15))
        sleep(2)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // Lift a low card and carry it slowly up to the second place, then let go.
        let mover = card("Coffee gift card").frame
        let second = card("Tailgate tickets").frame
        origin.withOffset(CGVector(dx: mover.midX, dy: mover.minY + 20))
            .press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: mover.midX, dy: second.minY + 20)),
                   withVelocity: 120, thenHoldForDuration: 0.6)
        sleep(2)
        // Lift one and put it back without moving.
        let held = card("Tailgate tickets").frame
        origin.withOffset(CGVector(dx: held.midX, dy: held.minY + 20)).press(forDuration: 1.5)
        sleep(2)
        // Lift one and carry it down, then let go.
        let top = card("Parking spot").frame
        origin.withOffset(CGVector(dx: top.midX, dy: top.minY + 20))
            .press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: top.midX, dy: top.minY + 200)),
                   withVelocity: 120, thenHoldForDuration: 0.6)
        sleep(2)
        // Open a coin and pull the next card at the bottom up a little, then most of the way.
        tapCard("Parking spot")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        sleep(1)
        let next = app.descendants(matching: .any).matching(identifier: "pileCard").firstMatch
        let nf = next.frame
        let grab = origin.withOffset(CGVector(dx: nf.midX, dy: nf.minY + 20))
        grab.press(forDuration: 0.1, thenDragTo: grab.withOffset(CGVector(dx: 0, dy: -120)), withVelocity: 120, thenHoldForDuration: 0.5)
        sleep(2)
        let next2 = app.descendants(matching: .any).matching(identifier: "pileCard").firstMatch.frame
        let grab2 = origin.withOffset(CGVector(dx: next2.midX, dy: next2.minY + 20))
        grab2.press(forDuration: 0.1, thenDragTo: grab2.withOffset(CGVector(dx: 0, dy: -360)), withVelocity: 160, thenHoldForDuration: 0.3)
        sleep(2)
        // Back to the purse, then pull down to refresh: the spinner shows at the top.
        app.buttons["Done"].tap()
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                   withVelocity: 400, thenHoldForDuration: 1.0)
        sleep(3)
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
            if f.midY > app.buttons["newCoin"].frame.minY - 8 {
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

        // The Rearrange list, from Account: Garage code to the top.
        app.buttons["Account"].tap()
        XCTAssertTrue(app.buttons["Rearrange Coins"].waitForExistence(timeout: 5))
        app.buttons["Rearrange Coins"].tap()
        let row = app.cells.containing(.staticText, identifier: "Garage code").firstMatch
        XCTAssertTrue(reveal(row), "Garage code is not in the Rearrange list")
        let toTop = app.buttons["Move Garage code to the top"]
        XCTAssertTrue(toTop.waitForExistence(timeout: 5), "no Move to Top button")
        toTop.tap()
        sleep(1)
        snap("s02b-rearrange")
        // Done on the Rearrange list, then Done on Account.
        app.navigationBars["Rearrange"].buttons["Done"].tap()
        sleep(1)
        app.navigationBars["Account"].buttons["Done"].firstMatch.tap()
        sleep(2)
        XCTAssertEqual(serverFirstTitle(), "Garage code", "Rearrange did not save the new order")

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
        let bar = app.buttons["newCoin"]
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
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock", "-uiTestLockNow", "-uiTestPin", "38.83395,-104.82135,0938",
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
        newCoin("Picture")
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
        newCoin("Voice Note")
        XCTAssertTrue(app.staticTexts["liveTranscript"].waitForExistence(timeout: 5))
        pause(3)
        app.buttons["stopRecording"].tap()
        pause(1.5)
        nameJustSaved("Dry cleaning")
        XCTAssertTrue(card("Dry cleaning").waitForExistence(timeout: 15))
        pause(2)

        // Pin your spot.
        chapter("pin")
        newCoin("Typed Note"); pinInEditor()
        XCTAssertTrue(reveal(app.buttons["Move Pin Here"]))
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
        openCoin.swipeLeft()
        pause(1.5)
        openCoin.buttons["Picture 2"].firstMatch.tap()
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

        // Toss it: swipe it away, as in Mail.  Changed your mind?  Undo.
        chapter("toss")
        let f = card("Garage code").frame
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.maxX - 70, dy: f.midY))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -120, dy: 0)), withVelocity: 300, thenHoldForDuration: 0.1)
        pause(1.2)
        let red = app.buttons["swipeDelete"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: red.maxX - 44, dy: red.minY + 31)).tap()
        XCTAssertTrue(card("Garage code").waitForNonExistence(timeout: 10))
        pause(2)
        app.buttons["undoDelete"].tap()
        XCTAssertTrue(card("Garage code").waitForExistence(timeout: 5))
        pause(2.5)
        chapter("end")

        // Extra scenes, cut only for the website's story clips.
        // Links in a note are ready to tap.
        chapter("x-taptext")
        tapCard("Email Jim back")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        pause(3)
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        pause(1)
        // The list on the fridge, full size.
        chapter("x-grocery")
        tapCard("Grocery list")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        pause(1.5)
        openCoin.buttons["Picture 1"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
        pause(2.5)
        app.buttons["Back"].tap()
        pause(1)
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        pause(1)
        // Lock with Face ID: turn it on, leave, come back, a glance opens it.
        chapter("x-faceid")
        app.buttons["Account"].tap()
        let lockSwitch = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Lock with'")).firstMatch
        if lockSwitch.waitForExistence(timeout: 5) {
            pause(1)
            lockSwitch.switches.firstMatch.tap()
            pause(1.5)
            app.navigationBars["Account"].buttons["Done"].firstMatch.tap()
            pause(1)
            XCUIDevice.shared.press(.home)
            pause(1.5)
            app.activate()
            pause(1.5)
            // The film script answers the Face ID prompt with a match when it sees this.
            print("FACEID_MATCH_NOW")
            pause(4)
        }
        chapter("x-end")
    }

    /// Every touch on a big purse (150 coins, most with pictures), each result
    /// checked on the screen and on the server (TEST_RUNNER_LARGE=1, seed_big.py).
    @MainActor
    func testLargePurse() throws {
        guard ProcessInfo.processInfo.environment["LARGE"] == "1" else { throw XCTSkip("Set LARGE=1 to run") }
        app = XCUIApplication()
        app.launchArguments += ["-uiTestReset", "-uiTestNoLock"]
        app.launchEnvironment["COINPURSE_BASE_URL"] = Self.baseURL
        app.launch()
        signIn()
        XCTAssertTrue(card("Coin number 150").waitForExistence(timeout: 30))
        sleep(2)
        func titles() -> [String] { (serverCoins() ?? []).compactMap { $0["title"] as? String } }
        func tapAt(_ e: XCUIElement) {
            let f = e.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
        }
        func openTitle() -> String { openCoin.staticTexts["coinTitle"].label }
        func scrollDown(_ n: Int) {
            for _ in 0..<n {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            }
            sleep(1)
        }
        let start = titles()
        XCTAssertEqual(start.count, 150)

        // 1. Pull down to fan the stack, let go: nothing moves for good, taps still land.
        let pullFrom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        pullFrom.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
                       withVelocity: .slow, thenHoldForDuration: 1.0)
        sleep(2)
        XCTAssertEqual(titles(), start, "fanning changed the order")
        tapAt(card("Coin number 149"))
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        XCTAssertEqual(openTitle(), "Coin number 149", "a tap after fanning opened the wrong coin")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // 2. Deep in the stack, every visible card opens itself.
        scrollDown(8)
        let cards = app.descendants(matching: .any).matching(identifier: "stackCard")
        let bar = app.buttons["newCoin"], account = app.buttons["Account"]
        let onScreen = (0..<cards.count).filter { i in
            let c = cards.element(boundBy: i)
            return c.exists && c.frame.minY > account.frame.maxY && c.frame.maxY < bar.frame.minY
        }.count
        var checked = 0
        for i in 0..<cards.count where checked < 6 {
            let c = cards.element(boundBy: i)
            guard c.exists, c.frame.minY > account.frame.maxY, c.frame.maxY < bar.frame.minY else { continue }
            let name = c.label
            tapAt(c)
            XCTAssertTrue(openCoin.waitForExistence(timeout: 5), "\(name) did not open")
            XCTAssertEqual(openTitle(), name, "tapped \(name), another coin opened")
            app.buttons["Done"].tap()
            XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
            sleep(1)
            checked += 1
        }
        // Every card on screen (up to six) opened itself; the largest text fits three.
        XCTAssertEqual(checked, min(onScreen, 6), "not every card on screen was checked")
        XCTAssertGreaterThanOrEqual(checked, 3, "too few cards checked deep in the stack")
        print("LARGE deep cards checked: \(checked)")

        // 3. The coins waiting at the bottom of an open coin are the next ones, in order.
        let deep = cards.allElementsBoundByIndex.first { $0.frame.minY > account.frame.maxY + 40 && $0.frame.maxY < bar.frame.minY }!
        let deepName = deep.label
        tapAt(deep)
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        let order = titles()
        let at = order.firstIndex(of: deepName)!
        let pile = app.descendants(matching: .any).matching(identifier: "pileCard")
        XCTAssertTrue(pile.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(pile.firstMatch.label, order[at + 1], "the first waiting coin is not the next one")
        // A small pull drops back; a tap brings it up; a long pull brings the next.
        let pf = pile.firstMatch.frame
        let grab = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: pf.midX, dy: pf.minY + 20))
        grab.press(forDuration: 0.1, thenDragTo: grab.withOffset(CGVector(dx: 0, dy: -80)), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertEqual(openTitle(), deepName, "a small pull swapped the coin")
        pile.firstMatch.tap()
        sleep(1)
        XCTAssertEqual(openTitle(), order[at + 1], "tapping the waiting coin did not bring it up")
        let pf2 = pile.firstMatch.frame
        let grab2 = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: pf2.midX, dy: pf2.minY + 20))
        grab2.press(forDuration: 0.1, thenDragTo: grab2.withOffset(CGVector(dx: 0, dy: -340)), withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(1)
        XCTAssertEqual(openTitle(), order[at + 2], "pulling the waiting coin up did not bring it up")
        snap("l01-pile")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))
        XCTAssertEqual(titles(), start, "swapping coins changed the order")

        // 4. Touch, hold and drag a card up three places, deep in the stack.
        sleep(1)
        let visible = cards.allElementsBoundByIndex.filter { $0.frame.minY > account.frame.maxY + 8 && $0.frame.maxY < bar.frame.minY - 8 }
        // Three places up; at the largest text only two or three cards show,
        // so it moves to the first of them.
        XCTAssertGreaterThanOrEqual(visible.count, 2)
        let mover = visible.count >= 5 ? visible[4] : visible[visible.count - 1]
        let target = visible.count >= 5 ? visible[1] : visible[0]
        let moverName = mover.label, targetName = target.label
        let mf = mover.frame, tf = target.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: mf.midX, dy: mf.midY))
            .press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: tf.midX, dy: tf.minY + 10)), withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(2)
        XCTAssertFalse(openCoin.exists, "moving a card opened it")
        let afterMove = titles()
        XCTAssertEqual(afterMove.count, 150)
        XCTAssertEqual(afterMove.firstIndex(of: moverName), start.firstIndex(of: targetName), "the card did not land where it was dropped")
        snap("l02-moved")

        // 5. Hold and pull a card up to the title: it opens, and the order stays.
        let opener = cards.allElementsBoundByIndex.first { $0.frame.minY > account.frame.maxY + 120 && $0.frame.maxY < bar.frame.minY }!
        let openerName = opener.label
        let of = opener.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: of.midX, dy: of.midY))
            .press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: of.midX, dy: account.frame.midY)), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5), "pulling a card to the title did not open it")
        XCTAssertEqual(openTitle(), openerName)
        XCTAssertEqual(titles(), afterMove, "opening by pulling up changed the order")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // 6. The Rearrange list with 150 coins: a far-down coin to the top.
        app.buttons["Account"].tap()
        app.buttons["Rearrange Coins"].tap()
        let farName = afterMove[120]
        let farButton = app.buttons["Move \(farName) to the top"]
        // 120 rows down: keep scrolling the list until it comes into view.
        for _ in 0..<80 where !(farButton.exists && farButton.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8))
                .press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)))
        }
        XCTAssertTrue(farButton.isHittable, "\(farName) is not reachable in the Rearrange list")
        farButton.tap()
        sleep(1)
        app.navigationBars["Rearrange"].buttons["Done"].tap()
        sleep(1)
        app.navigationBars["Account"].buttons["Done"].firstMatch.tap()
        sleep(2)
        XCTAssertEqual(titles().first, farName, "Rearrange did not move the coin to the top")

        // 7. The trash can on a card mid-stack: asks, then the coin is gone everywhere.
        scrollDown(4)
        let victim = cards.allElementsBoundByIndex.first { $0.frame.minY > account.frame.maxY + 8 && $0.frame.maxY < bar.frame.minY - 8 }!
        let victimName = victim.label
        let vf = victim.frame
        // The trash can sits in the middle of the strip that shows (31 points down at normal text).
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: vf.maxX - 28, dy: vf.midY)).tap()
        let confirm = app.alerts.buttons["Delete"].exists ? app.alerts.buttons["Delete"] : app.buttons.matching(identifier: "Delete").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the trash can did not ask first")
        confirm.tap()
        XCTAssertTrue(card(victimName).waitForNonExistence(timeout: 10), "\(victimName) is still in the purse")
        // Deleted on the server once the Undo moment passes.
        sleep(7)
        XCTAssertEqual(titles().count, 149, "the server still has the tossed coin")
        XCTAssertFalse(titles().contains(victimName))

        // 8. A new coin while scrolled down: the purse comes back to the top to show it.
        scrollDown(3)
        UIPasteboard.general.image = Self.sample(color: .systemPurple, label: "New")
        newCoin("Picture")
        tapPaste()
        let title = app.textFields["titleField"]
        reveal(title); title.tap()
        title.typeText("Brand new coin")
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Brand new coin").waitForExistence(timeout: 15))
        sleep(2)
        XCTAssertTrue(card("Brand new coin").isHittable, "the new coin is out of view at the top")
        XCTAssertEqual(titles().first, "Brand new coin")
        snap("l03-new-on-top")

        // 9. Search finds one among 150 and opens it.
        app.buttons["Search"].tap()
        app.textFields["searchField"].typeText("number 042")
        XCTAssertTrue(card("Coin number 042").waitForExistence(timeout: 5))
        tapCard("Coin number 042")
        XCTAssertTrue(openCoin.waitForExistence(timeout: 5))
        XCTAssertEqual(openTitle(), "Coin number 042")
        app.buttons["Done"].tap()
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(titles().count, 150)
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
        // Pulled down and held: the stack fans open (seen in screen recordings).
        let pullFrom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        pullFrom.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                       withVelocity: .slow, thenHoldForDuration: 2.5)
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

        tapCard("Tailgate tickets")
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

        tapCard("Email Jim back")
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        sleep(2)
        snap("d07-open-note")
        // Swipe down to put it back.
        open.swipeDown(velocity: .slow)
        sleep(2)
        XCTAssertFalse(open.exists, "swipe down should put the coin back")

        newCoin("Typed Note"); pinInEditor()
        sleep(4)
        snap("d08-pin")
        cancelSheet()
        sleep(1)

        newCoin("Voice Note")
        sleep(2)
        snap("d09-voice")
        cancelSheet()
        sleep(1)

        newCoin("Picture")
        sleep(2)
        snap("d10-new-coin")
        cancelSheet()
        sleep(1)

        app.buttons["Search"].tap()
        app.textFields["searchField"].typeText("code")
        sleep(1)
        snap("d11-search")
        cancelSheet()
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

        // Typed something, then Cancel: it asks before throwing it away, and
        // Keep Editing keeps every word.
        newCoin("Typed Note")
        let draft = app.textFields["titleField"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        sleep(1)
        draft.tap()
        draft.typeText("Draft to throw away")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5), "Cancel threw away typing without asking")
        // iOS 26 shows the question as a small bubble with no Keep Editing
        // button; tapping outside it keeps editing.
        if app.buttons["Keep Editing"].exists {
            app.buttons["Keep Editing"].tap()
        } else {
            // The far right edge is outside the bubble at every text size.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.3)).tap()
        }
        XCTAssertTrue(app.buttons["Discard Changes"].waitForNonExistence(timeout: 3), "the question did not go away")
        XCTAssertEqual(draft.value as? String, "Draft to throw away", "Keep Editing lost the typing")
        app.buttons["Cancel"].tap()
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(draft.waitForNonExistence(timeout: 5), "Discard Changes did not close the editor")
        XCTAssertTrue(app.staticTexts["Your purse is empty"].exists, "a discarded draft was saved")

        // A title and nothing else: the card shows the title big, not a blank.
        newCoin("Picture")
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
        newCoin("Picture")
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
        newCoin("Picture")
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
        newCoin("Picture")
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
        // Removing a picture in the editor waits for Save: Cancel keeps it.
        app.buttons["openEditor"].tap()
        let remove6 = app.buttons["Remove picture 6"]
        XCTAssertTrue(reveal(remove6), "no way to remove a picture in the editor")
        remove6.tap()
        XCTAssertTrue(remove6.waitForNonExistence(timeout: 3), "the removed picture still shows in the editor")
        cancelSheet()
        XCTAssertTrue(app.buttons["Picture 6"].waitForExistence(timeout: 5), "Cancel did not keep the removed picture")
        app.buttons["openEditor"].tap()
        XCTAssertTrue(reveal(remove6))
        remove6.tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Picture 6"].waitForNonExistence(timeout: 15), "Save did not remove the picture")
        XCTAssertTrue(app.buttons["Picture 5"].exists, "Save removed more than one picture")
        app.buttons["Done"].tap()
        XCTAssertTrue(openCoin.waitForNonExistence(timeout: 5))

        // Location turned off: Pin explains how to turn it on, nothing breaks.
        newCoin("Typed Note"); pinInEditor()
        // It shows under the Pin button, which may sit at the bottom of the screen.
        let locationOff = app.staticTexts["Turn on Location for Coin Purse in Settings to drop a pin."]
        XCTAssertTrue(locationOff.waitForExistence(timeout: 5) || reveal(locationOff), "no explanation with Location off")
        snap("e06-location-off")
        cancelSheet()
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
            newCoin("Picture")
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
        cancelSheet()

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
        newCoin("Picture")
        let title = app.textFields["titleField"]
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Ticket")
        tapPaste()
        app.buttons["Save"].tap()
        XCTAssertTrue(card("Ticket").waitForExistence(timeout: 15))
        newCoin("Picture")
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
        newCoin("Picture")
        XCTAssertTrue(reveal(title))
        reveal(title); title.tap()
        title.typeText("Offline coin")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Could not reach Coin Purse'")).firstMatch
            .waitForExistence(timeout: 70), "offline save shows no message")
        snap("o03-offline-save")
        reveal(title)
        XCTAssertEqual(title.value as? String, "Offline coin")
        cancelSheet()

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
        newCoin("Picture")
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
        // One sign-in, reused: signing in for every check runs into the server's rate limit.
        for attempt in 0..<2 {
            if serverToken == nil || attempt > 0 {
                _ = post("/api/auth/request-link", ["email": "review@example.com"])
                guard let auth = post("/api/auth/verify-code", ["email": "review@example.com", "code": "123456"]),
                      let token = (try? JSONSerialization.jsonObject(with: auth) as? [String: Any])?["token"] as? String else { return nil }
                serverToken = token
            }
            var req = URLRequest(url: URL(string: Self.baseURL + "/api/coins")!)
            req.setValue("Bearer \(serverToken ?? "")", forHTTPHeaderField: "Authorization")
            if let data = fetch(req),
               let coins = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["coins"] as? [[String: Any]] {
                return coins
            }
            // The saved sign-in was refused (an account deleted and made again): sign in once more.
        }
        return nil
    }

    private var serverToken: String?

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
        newCoin("Picture")
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
        let barTop = app.buttons["newCoin"].frame.minY
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
        newCoin("Picture")
        sleep(1)
        dump("a-new-coin")
        audit("New coin")
        cancelSheet()
        newCoin("Typed Note"); pinInEditor()
        sleep(3)
        // Keyboard down first (a drag on the form), as when reading it.
        if app.keyboards.count > 0 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
            sleep(1)
        }
        // Back to the top of the form, as it opens (text scrolled under the
        // see-through bar is faded on purpose, and the audit would measure it).
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
        sleep(1)
        snap("a-new-note-pin")
        audit("New note with a pin")
        cancelSheet()
        newCoin("Voice Note")
        sleep(1)
        audit("Voice note")
        app.buttons["stopRecording"].tap()
        // Saved at once: the purse with its Saved bar.
        XCTAssertTrue(app.buttons["addDetails"].waitForExistence(timeout: 15))
        audit("Purse")
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
        if ["Pin your spot", "New coin", "New note with a pin", "Voice note review", "Account"].contains(screen),
           issue.auditType == .dynamicType || issue.auditType == .contrast {
            return "system Form styling (section headers, footers, row buttons) drawn by iOS"
        }
        if issue.auditType == .dynamicType, screen == "Purse" {
            return "cards far down a lazy stack are not built while the audit enlarges text"
        }
        if issue.auditType == .textClipped, screen.hasPrefix("Open coin"), element?.identifier == "pileTitle" {
            return "coins waiting at the bottom show one line of title, like Wallet; full title in the VoiceOver label and when brought up"
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
        showCard(name).tap()
    }

    /// Scrolls the purse until the card is on screen, clear of the New Coin
    /// button and the title, and returns it.
    @MainActor @discardableResult
    private func showCard(_ name: String) -> XCUIElement {
        let c = card(name)
        XCTAssertTrue(c.waitForExistence(timeout: 10), "no card named \(name)")
        let bar = app.buttons["newCoin"]
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
        return c
    }

    /// Taps Cancel; when it asks whether to throw away what was typed (an
    /// editor or a voice note), says yes.
    @MainActor
    private func cancelSheet() {
        app.buttons["Cancel"].tap()
        for name in ["Discard Changes", "Discard Note"] where app.buttons[name].waitForExistence(timeout: 1) {
            app.buttons[name].tap()
            return
        }
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

    /// New Coin, then how to start it: "Picture", "Voice Note" or "Typed Note".
    @MainActor
    private func newCoin(_ kind: String) {
        // The microphone starts a voice note; New Coin starts one from scratch
        // (a picture, a typed note, a pin).
        let button = app.buttons[kind == "Voice Note" ? "newVoice" : "newCoin"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no button for \(kind)")
        // Tapped while the last coin's sheet is still sliding away, iOS drops the
        // tap: try again once the screen has settled.
        for _ in 0..<3 {
            button.tap()
            if app.navigationBars.firstMatch.waitForExistence(timeout: 3) { return }
        }
    }

    /// The name box from tapping a coin's name: type, Save.
    @MainActor
    private func rename(to title: String) {
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "tapping the name did not offer to change it")
        field.tap()
        // A name you gave it starts in the box: clear it first (an empty box
        // reports its hint as the value; deleting there does nothing).
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        field.typeText(title)
        app.alerts.buttons["Save"].tap()
    }

    /// After a voice note is saved in one go: Add details, a title, Save.
    @MainActor
    private func nameJustSaved(_ title: String) {
        let details = app.buttons["addDetails"]
        XCTAssertTrue(details.waitForExistence(timeout: 15), "no Saved bar with Add details")
        details.tap()
        let field = app.textFields["titleField"]
        XCTAssertTrue(reveal(field), "Add details did not open the editor")
        // An automatic name (Coin 3) is only the hint: the box is empty, ready to type.
        XCTAssertEqual(field.value as? String ?? "", field.placeholderValue ?? "", "the automatic name was in the way")
        field.tap()
        field.typeText(title)
        app.buttons["Save"].tap()
    }

    /// In the coin editor: Pin where I am now.
    @MainActor
    private func pinInEditor() {
        let pin = app.buttons["Pin where I am now"]
        XCTAssertTrue(reveal(pin), "no Pin where I am now in the editor")
        pin.tap()
    }

    /// Scrolls a form until the element is on screen. Forms build rows only as
    /// they scroll in, so on a small iPhone or at the largest text sizes a field
    /// further down does not exist until then.
    @MainActor @discardableResult
    private func reveal(_ element: XCUIElement) -> Bool {
        if element.waitForExistence(timeout: 5) && element.isHittable { return true }
        // Down the form first, then back up (the element may be above).
        // Far enough for the longest form (Account at the largest text size).
        for step in 0..<18 {
            let down = step < 9
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
        // On a small iPhone the picture row can sit under the keyboard: scroll the
        // form until it shows (down first, so a drag never pulls the sheet closed).
        XCTAssertTrue(reveal(paste), "no Paste in the editor")
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
