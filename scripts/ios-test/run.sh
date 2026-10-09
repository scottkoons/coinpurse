#!/bin/zsh
# Runs Coin Purse UI test suites on one simulator against a fresh local test
# server, and prints one PASS or FAIL line per suite.
#
# Usage: scripts/ios-test/run.sh [suite ...]
#   No suites: runs every suite in SUITES below.
# Settings (environment variables):
#   DEVICE      simulator name or UDID          (default "iPhone 17 Pro")
#   APPEARANCE  light | dark                    (default light)
#   TEXT        large | accessibility-extra-extra-extra-large (default large)
#   PORT        local test server port          (default 3000; use a different one per simulator)
#   OUT         folder for screenshots and logs (default /tmp/coinpurse-tests/<device>-<appearance>-<text>)
#   DERIVED     Xcode build folder              (default /tmp/coinpurse-tests/build-<port>)
#
# Run two simulators at once by giving each its own PORT and DERIVED, and a
# separate copy of the repo (git worktree) if you are also editing code.
R=${0:A:h:h:h}
DEVICE=${DEVICE:-"iPhone 17 Pro"}
APPEARANCE=${APPEARANCE:-light}
TEXT=${TEXT:-large}
PORT=${PORT:-3000}
DERIVED=${DERIVED:-/tmp/coinpurse-tests/build-$PORT}
OUT=${OUT:-/tmp/coinpurse-tests/${DEVICE// /-}-$APPEARANCE-$TEXT}
UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 | grep -oE '[0-9A-F-]{36}')
[ -z "$UDID" ] && UDID=$DEVICE

# name : env flag : seed script ("" for none)
SUITES=(
  "testFullFlow:X=1:"
  "testEdgeCases:TEST_RUNNER_EDGE=1:"
  "testOffline:TEST_RUNNER_OFFLINE=1:"
  "testFullPurse:TEST_RUNNER_TOUR=1:seed.py"
  "testDesignTour:TEST_RUNNER_DESIGN=1:seed_design.py"
  "testShareToCoinPurse:TEST_RUNNER_SHARE=1:"
  "testShareFromPhotos:TEST_RUNNER_PHOTOS=1:"
  "testQuickActions:TEST_RUNNER_QUICK=1:"
  "testBigPurse:TEST_RUNNER_BIG=1:seed_big.py"
  "testLargePurse:TEST_RUNNER_LARGE=1:seed_big.py"
  "testComesBackFresh:TEST_RUNNER_RETURN=1:"
  "testTapAccuracy:TEST_RUNNER_TAP=1:seed.py"
  "testStress:TEST_RUNNER_STRESS=1:seed_design.py"
  "testSwipeToDelete:TEST_RUNNER_SWIPE=1:seed_design.py"
  "testArchiveAndHide:TEST_RUNNER_ARCHIVE=1:seed_design.py"
  "testQuickCapture:TEST_RUNNER_QUICK2=1:seed_design.py"
  "testDragFilm:TEST_RUNNER_DRAGFILM=1:seed_design.py"
  "testAccessibilityAudit:TEST_RUNNER_AUDIT=1:seed_design.py"
)
WANT=("$@")

xcrun simctl boot $UDID 2>/dev/null
xcrun simctl ui $UDID appearance $APPEARANCE
xcrun simctl ui $UDID content_size $TEXT
mkdir -p $OUT
echo "=== $(date +%H:%M) device=$DEVICE appearance=$APPEARANCE text=$TEXT"

for entry in $SUITES; do
  name=${entry%%:*}; rest=${entry#*:}; flag=${rest%%:*}; seed=${rest#*:}
  if (( ${#WANT} )) && [[ ${WANT[(Ie)$name]} -eq 0 ]]; then continue; fi
  # The audit enlarges text by itself; at the largest size it is not meaningful.
  if [[ $name == testAccessibilityAudit && $TEXT != large ]]; then continue; fi
  # A fresh server (in-memory store) for every suite.
  lsof -ti tcp:$PORT -sTCP:LISTEN | xargs kill 2>/dev/null; sleep 1
  (cd $R && PORT=$PORT nohup node ./test/devserver.js > $OUT/server-$PORT.log 2>&1 &); sleep 2
  curl -s -X POST localhost:$PORT/api/auth/request-link -H 'content-type: application/json' -d '{"email":"review@example.com"}' >/dev/null
  [ -n "$seed" ] && (cd $R && BASE=http://localhost:$PORT python3 scripts/ios-test/$seed >/dev/null)
  mkdir -p $OUT/$name
  log=$OUT/$name/xcodebuild.log
  (cd $R/ios && env $flag TEST_RUNNER_BASE_URL=http://localhost:$PORT TEST_RUNNER_SCREENSHOT_DIR=$OUT/$name \
    xcodebuild test -project CoinPurse.xcodeproj -scheme CoinPurse -destination "id=$UDID" -derivedDataPath $DERIVED \
    -only-testing:CoinPurseUITests/CoinPurseUITests/$name > $log 2>&1)
  if grep -q 'TEST SUCCEEDED' $log; then echo "PASS $name"; else echo "FAIL $name"; grep -E 'error:' $log | head -3; fi
done
lsof -ti tcp:$PORT -sTCP:LISTEN | xargs kill 2>/dev/null
xcrun simctl ui $UDID content_size large
echo "=== done $(date +%H:%M)"
