#!/bin/zsh
# Records the website film on the iPhone 17 Pro simulator (light mode, 9:41),
# with the demo test driving the app.  Then run cut.py to make the film and clips.
#   scripts/website-film/record.sh
R=${0:A:h:h:h}
OUT=/tmp/coinpurse-film; rm -rf $OUT; mkdir -p $OUT
U=$(xcrun simctl list devices available | grep -F "iPhone 17 Pro (" | head -1 | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot $U 2>/dev/null
xcrun simctl ui $U appearance light
xcrun simctl ui $U content_size large
xcrun simctl status_bar $U override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl location $U set 38.8318,-104.8262
# Face ID enrolled; the film answers each prompt with a match.
xcrun simctl spawn $U notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
xcrun simctl spawn $U notifyutil -p com.apple.BiometricKit.enrollmentChanged
# The badge photo for "Share from any app" (the newest photo in Photos).
xcrun simctl addmedia $U $R/img/conference-badge.jpg
cd $R
lsof -ti tcp:3003 -sTCP:LISTEN | xargs kill 2>/dev/null; sleep 1
(PORT=3003 nohup node ./test/devserver.js > $OUT/server.log 2>&1 &); sleep 2
BASE=http://localhost:3003 python3 scripts/website-film/seed_demo.py > $OUT/seed.log
cd ios
xcodebuild build-for-testing -project CoinPurse.xcodeproj -scheme CoinPurse -destination "id=$U" -derivedDataPath /tmp/coinpurse-film-build > $OUT/build.log 2>&1 || { echo BUILD FAILED; exit 1; }
xcrun simctl io $U recordVideo --codec=h264 --force $OUT/raw.mp4 > $OUT/rec.log 2>&1 &
REC=$!
# The film's clock starts when the simulator says it is recording.
for i in {1..100}; do grep -q "Recording started" $OUT/rec.log 2>/dev/null && break; sleep 0.05; done
python3 -c 'import time;print(time.time())' > $OUT/rec_start.txt
sleep 1
# Each FACEID_MATCH_NOW in the test's output gets one Face ID match.
( answered=0
  for i in {1..1200}; do
    n=$(grep -c FACEID_MATCH_NOW $OUT/test.log 2>/dev/null); n=${n:-0}
    if [ "$n" -gt "$answered" ]; then sleep 1; xcrun simctl spawn $U notifyutil -p com.apple.BiometricKit_Sim.pearl.match; answered=$n; fi
    sleep 0.5
  done ) &
WATCH=$!
env TEST_RUNNER_DEMO=1 TEST_RUNNER_DEMO_IMG=$R/img TEST_RUNNER_BASE_URL=http://localhost:3003 TEST_RUNNER_SCREENSHOT_DIR=$OUT \
  xcodebuild test-without-building -project CoinPurse.xcodeproj -scheme CoinPurse -destination "id=$U" -derivedDataPath /tmp/coinpurse-film-build \
  -only-testing:CoinPurseUITests/CoinPurseUITests/testDemoFilm > $OUT/test.log 2>&1
kill -INT $REC; kill $WATCH 2>/dev/null; sleep 3
lsof -ti tcp:3003 -sTCP:LISTEN | xargs kill 2>/dev/null
grep -E 'CHAPTER' $OUT/test.log | grep -v 'func\|print' | awk '{print $2, $3}' | sort -u -k2 -n > $OUT/chapters.txt
ffmpeg -v error -y -i $OUT/raw.mp4 -vf fps=30 -c:v libx264 -crf 18 -pix_fmt yuv420p $OUT/cfr.mp4
if grep -qE 'TEST (EXECUTE )?SUCCEEDED' $OUT/test.log; then echo PASS; else echo FAIL; grep -E 'error:' $OUT/test.log | head -3; fi
cat $OUT/chapters.txt
