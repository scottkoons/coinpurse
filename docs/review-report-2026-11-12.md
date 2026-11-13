# Coin Purse review before the App Store (2026-11-12)

A full review of the iPhone app, its Share extension and its UI tests, with every finding checked against the code before anything was changed.  Every change was built, then tested with the UI test suites on the simulators.

## Summary

The app was in good shape: no crash showed up in any review or test run, and no Coin Purse crash report was written all night.  The review found three things that would have hurt at review or in use, and fixed them:

1. **Save Image could crash the app.**  Sharing a picture offers Save Image, and the app had no photo library permission text, so that tap closed the app.
2. **The Face ID lock could be skipped.**  On a cold launch, if the app became active before the purse finished loading, the lock was cleared and the purse opened unlocked.
3. **Quick actions ran behind the lock.**  Voice Note from the Home Screen started the microphone (and Take Picture the camera) before Face ID.

Many smaller fixes follow below.  No design, wording or behavior that you chose was changed, except where noted.

## Fixed in the app

**App Store and privacy**
- Photo library add permission text, for Save Image in the share sheet.
- A privacy manifest for the Share extension (it shares code that reads file dates).
- The speech permission text now says Apple may process speech when the iPhone cannot (the privacy policy already said so).
- The Face ID permission text now mentions hidden coins, not only the lock.
- Maps of spots no coin is pinned to any more are removed at launch (they showed where a deleted pin was, with its coordinates in the file name).

**Face ID lock**
- The lock stays on while the purse loads at launch.
- Face ID asks by itself once each time the lock engages; after Cancel, the lock screen's button asks, so the prompt never keeps coming back.
- Quick actions wait until the purse is unlocked, then run.
- VoiceOver stays on the lock screen and cannot read the purse underneath.

**Keeping coins safe**
- One damaged entry in the purse file no longer empties the whole purse: every coin that can still be read stays, and a copy of the damaged file is kept.  The repair happens only once that copy is safely written.
- A delete made just before leaving the app gets time to finish.
- A refresh that ran during a delete can no longer bring the coin back for a moment.
- A purse that could not be read at launch no longer costs the Archive its order.
- Share to Coin Purse: a failed save no longer leaves an empty coin behind, and New Coin or Add to a Coin cannot be switched once some pictures went in.

**Share to Coin Purse**
- Pictures and PDFs are read from their files instead of loaded whole into memory, so a very large photo cannot push the extension past iOS's memory limit.
- Text shared as UTF-16 is accepted (before, it was dropped).

**The purse**
- A lifted card whose coin leaves the purse is put down (before, the purse could stop scrolling until the app was restarted).
- An interrupted hold (a call, a system sheet) puts the card down and never opens the coin.
- The "N earlier" marker counts correctly after the stack is layered again (after a move or an unarchive it could vanish while coins were rolled away above).
- Search works when the purse is empty and only archived coins match.
- VoiceOver: Move Up and Move Down use the coin's place in the whole purse (not in the search results), and an untitled coin is read as "Untitled".
- A photo from the camera that cannot be made into a picture now says so instead of vanishing.
- Rearrange drops a coin that is deleted or archived while it is open, instead of showing a blank row.
- Swipe labels (Archive, Delete) shrink to fit at large text sizes instead of being cut off.

**The Archive and full screen**
- A row moved by its handle is put down when iOS cancels the touch, instead of staying invisible.
- An archived coin deleted from full screen closes its page instead of leaving a blank one.
- Full screen closes when its pictures are gone.  VoiceOver reads each picture ("Picture 2 of 3") and the escape gesture closes it.
- The picture cache is limited by memory (about 150 MB) and decodes pictures off the main thread.

**Voice notes and the editor**
- Words being dictated are not lost to a swipe down or Cancel without asking.

**Largest text sizes**
- **Paste did nothing.**  The picture buttons' symbols grew with the text size while their circles did not, and iOS will not draw or run a Paste control it cannot show whole.  The symbols now keep their size, and at the accessibility text sizes Paste is a whole row (Apple's Paste control with its own name), so a tap anywhere on it, or VoiceOver's, pastes.  This is the one visible change: at those sizes only, Paste is a gray capsule row.

**Swift 6:** three concurrency warnings fixed; the app builds with no warnings in Debug and Release.

## Dead and orphaned code removed

A script listed every function, type and property in the app and counted its uses.  Nothing in the app was unused; the only single-use names are system entry points (delegates, App Intents).  Removed:

- The full-screen viewer's text page and "No picture yet" page, which it could only reach if every picture vanished while it was open (it now closes instead).
- `testMapsDirections`, a one-off screenshot probe no runner used.
- Test-only store code (`keepPicture`, `add`) is now compiled only into debug builds; `renameFolder` no longer returns a list nobody read.
- A duplicate accessibility modifier on the Archive drag handle.

## Test results

Gates as in `docs/overnight-test-loop.md`.

| Gate | Result |
|---|---|
| 1. Build | Debug and Release (device) build with no errors and no warnings |
| 2. iPhone 17 Pro | All 21 suites pass in light and in dark |
| 3. iPhone SE | All 21 pass in light; in dark, 20 of 21 on the last full run, the 21st passing on two reruns (flaky, below) |
| 4. iPhone 17, largest text | 16 of 20 pass (9 of 20 passed before tonight) |
| 5. Accessibility audit | Passes on the iPhone 17 Pro and the SE |
| 6. Crashes | No Coin Purse crash reports |

**Flaky:**
- `testArchiveAndHide` failed once on the SE (dark) and passed on both reruns.  The test looked for a card while the "N earlier" marker was missing, which is now fixed in the app.
- `testArchiveFolders` failed once in four SE (dark) runs: right after a coin was archived from its open card, an invisible copy of that card stayed in the screen's element tree for more than five seconds, though the screenshot showed it gone (`/tmp/coinpurse-tests/r10-se-dark/testArchiveFolders/failure.png` and `failure.txt`).  It looks like a card caught in its fade-out in the lazy stack.  VoiceOver might briefly find it.  Not fixed: the cause is not certain, and the fade is part of the closing animation.

**Test fixes** (no check was weakened):
- On the SE, the coin's menu opened over the folder it was being dragged to; the test now uses the drag handle when that happens.  This failed before tonight too.
- At the largest text sizes, card taps were 10 points above the New Coin button, which takes touches a little beyond its edge; cards are now brought well clear first.
- At the largest text sizes, a card in the middle of the purse is found a step at a time.

## Needs Scott

1. **Dragging needs the list to scroll at the largest text sizes.**  At the biggest accessibility sizes the Archive rows (and the purse cards) are so tall that two of them may not fit on screen together, and neither list scrolls by itself while you drag, so a coin cannot be dragged straight from the bottom to the top.  It can still be moved in steps, and VoiceOver has Move Up and Move Down.  The four remaining largest-text test failures are this.  Auto-scroll while dragging near the top or bottom edge would fix it; it is a small feature, so it was left for you to decide.
2. **The test server exception ships in the release build.**  `NSAllowsLocalNetworking` (for the debug-only test server) is in the release Info.plist too.  App Review allows it and the app makes no network calls, so it is harmless; removing it would need a separate plist for debug builds.
3. **An animation never settles while a coin's menu is open in the Archive.**  The UI tests wait 60 seconds for the app to go idle each time (on every device, before tonight too).  Nothing visible is wrong; it only makes those tests slow.
4. **App Store Connect:** the privacy answers in `docs/app-store-listing.md` still hold (Data Not Collected).
