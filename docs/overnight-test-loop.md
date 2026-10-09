# Overnight test loop for Coin Purse

Copy everything below the line into a Claude Code session in this project, with the model set to Sonnet.  Change the stop time if you want.

---

You are running an unattended overnight test loop for Coin Purse, a SwiftUI iPhone app in `ios/` with a Node test server in `test/` and API code in `api/`.  Keep testing until **6:00 AM Mountain Time**, then stop and write the report.  Nobody is watching, so never wait for an answer; log anything you would ask about.

## Setup (once)

1. Work in `/Users/scottkoons/Developer/coinpurse`.  Create and switch to a branch named `overnight-YYYY-MM-DD` (today's date) from `main`.  All commits go on that branch.
2. Keep the Mac awake for the night: start `caffeinate -dims` in the background.
3. Read `scripts/ios-test/run.sh`.  It runs the UI test suites on one simulator against a fresh local test server and prints one PASS or FAIL line per suite.  Screenshots and full logs go to `/tmp/coinpurse-tests/...`.
4. Use these simulators (already created): `iPhone 17 Pro` with PORT 3000, `Coin Purse SE` (the small iPhone SE) with PORT 3001, and `iPhone 17` with PORT 3002.  Give each its own `DERIVED` build folder.  You may run two simulators at the same time, each with its own PORT and DERIVED.  If you edit code while a run is going, run that simulator from a separate git worktree so the run does not pick up half-finished edits.
5. Note the newest file in `~/Library/Logs/DiagnosticReports/` whose name starts with `CoinPurse`, so you can tell which crash reports are new.

## The gates (every one must pass)

- **Gate 1, server:** `npm test` passes all tests, 5 runs in a row.
- **Gate 2, iPhone 17 Pro:** every suite passes in light and in dark (`APPEARANCE=light` and `APPEARANCE=dark`).
- **Gate 3, iPhone SE:** every suite passes in light and in dark.
- **Gate 4, largest text:** every suite passes on `iPhone 17` with `TEXT=accessibility-extra-extra-extra-large` (the script skips the accessibility audit at that size, on purpose).
- **Gate 5, accessibility:** `testAccessibilityAudit` passes on both the iPhone 17 Pro and the SE.
- **Gate 6, crashes:** no new Coin Purse crash reports, except the known one below.

## The loop

Repeat until the stop time:

1. Run Gate 1, then Gates 2 to 5, spreading the simulators so two run at once.
2. When a suite fails, rerun only that suite up to two more times.
   - If it passes on a rerun, mark it **flaky** in the log with the failure message and the screenshot path, then move on.
   - If it fails every time, investigate: read the failure message, the `failure.png` screenshot and `failure.txt` (the screen's element tree) in that suite's output folder, and the relevant test and app code.
3. After each full pass of all gates, check for new crash reports (Gate 6).  For each new one, record the crashing thread's top frames.
4. Start the next pass.  Vary it: switch which simulator runs which gate, and alternate light and dark first.

## What you may fix, and how

Fix a problem only when you are confident of the cause and the fix is small and clearly safe.  Otherwise, log it and leave it.

- **Test problems** (timing, scrolling, a tap aimed at the wrong spot, a stale identifier): fix the test in `ios/CoinPurseUITests/CoinPurseUITests.swift`.  Never weaken a check just to make it pass.  A check exists to catch a real problem; keep that purpose.
- **Clear app bugs** with an obvious, small fix (a crash with a clear stack, text cut off, a button covered by something): fix the app code.  Keep the existing style: plain comments explaining why, SwiftUI, no new libraries.
- **Do not change** the design or how things behave on purpose.  This includes the Wallet-style purse (the next coins waiting at the bottom to peek and bring up, touch and hold to lift and peek, drag to move, pull to the title to open, pull down to fan), the three buttons at the bottom of the purse (the microphone, New Coin and the camera), the camera saving a coin at once and opening it, the microphone saving a coin at once with Add details and Undo, the open coin's row of buttons (Add Pin, Open, Archive, Face ID, Delete), tapping a coin's name to rename it, sharing one picture from full size or a pin from the map, swipe a coin to the left to delete it with Undo, colors, wording, and the website.  If one of these looks wrong, log it with a screenshot path for Scott to decide.
- After any fix: build, rerun the suites that touch that code on two simulators, then commit with a clear message ending in `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.  If the fix makes anything else fail, revert it and log the problem instead.

## Never do these

- Do not push, merge into `main`, or deploy anything.  `main` deploys to the live server automatically.
- Do not touch the live server, the website files, Vercel, GitHub settings, or anything that needs an Apple account login.
- Do not install anything on Scott's real iPhone or use the real microphone.
- Do not delete crash reports, simulators, or other people's files.  Leave the simulators in light mode at normal text size when you finish.

## Known, not bugs

- **Simulator microphone:** the app can close inside Apple's audio code (`AudioToolboxCore _ReportRPCTimeout`, from `SpeechEngine.start`) when the simulator uses the real microphone.  The tests use simulated speech, so this should not happen; if it does, log it and do not try to fix it.
- **Stuck test runner:** rarely, the test runner stalls with both the app and the runner idle.  If a suite runs longer than 20 minutes, stop it (kill that `xcodebuild`) and rerun it.
- **Photos app first launch:** the Photos share test handles "What's New"; a new Photos screen may still need a test fix.

## The report

At the stop time, write `docs/overnight-report-YYYY-MM-DD.md` and commit it on the branch.  Write plainly, with no contractions, two spaces after each sentence, and no dashes used as punctuation.  Include:

1. **Summary:** how many full passes ran, and whether every gate passed on the last pass.
2. **Gate table:** for each gate, passes and failures across the night.
3. **Flaky tests:** each one with the failure message, how often, and a screenshot path.
4. **Fixed:** each fix with what was wrong, what changed, and the commit.
5. **Needs Scott:** problems you did not fix, design questions, and anything that looked wrong, each with a screenshot path.
6. **Crashes:** any new crash reports, with the top frames.

Then stop.
