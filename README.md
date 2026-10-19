# Coin Purse

An iPhone app for the little things you need to show quickly: the QR code for the conference, the barcode on a gift card, the row you parked in.  Snap it, find it, toss it.

Everything is kept on the iPhone.  There is no account, no sign-in and no server, and the whole app works with no internet.  Coins are included in the iPhone's iCloud Backup.

## What is here

- `ios/`: the SwiftUI app, its Share extension (Share to Coin Purse) and its UI tests.
  - `ios/Shared/LocalStore.swift` keeps the purse: coins in one small JSON file and each picture or video as a file beside it, in the app group `group.com.yetignome.coinpurse` shared with the Share extension.
- `index.html`, `support.html`, `privacy.html`: the website at https://coinpurse.yetignome.com, hosted on Vercel (static files only).
- `test/devserver.js`: a small local server used only by the UI tests.  Seed scripts give it sample coins, a debug build started with `-uiTestReset` copies them onto the phone, and the app sends back a copy of what it saved for the tests to check.
- `scripts/ios-test/`: the UI test runner (`run.sh`) and the seed scripts.

## Running the UI tests

```bash
scripts/ios-test/run.sh
```

Name suites to run only those (for example `scripts/ios-test/run.sh testFullFlow testOffline`).  `DEVICE`, `APPEARANCE`, `TEXT` and `PORT` choose the simulator and its settings.

## Looking at the website locally

```bash
node test/devserver.js
```

Then open http://localhost:3000.
