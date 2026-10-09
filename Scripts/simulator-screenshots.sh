#!/usr/bin/env bash
# Builds Demo.xcodeproj for an iOS Simulator, installs it, launches it once
# per scenario (-scenario <name>), checks the process is still running with
# a numeric PID after the scenario has played (it did not crash), and saves
# real screenshots to Demo/Screenshots/.
# Runs on the GitHub-hosted macOS runner (see .github/workflows/simulator.yml).
set -euo pipefail

RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
BUNDLE_ID="com.rajatlakhina.FeedReadinessDemo"
OUT="Demo/Screenshots"
mkdir -p "$OUT"

# Pick an iPhone simulator whose runtime matches the iOS Simulator SDK of the
# selected Xcode (runner images carry several runtimes; one newer than the
# SDK cannot be a build destination). Never a hard-coded device name.
SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)
echo "iOS Simulator SDK $SDK_VERSION"
UDID=$(xcrun simctl list devices available -j | SDK_VERSION="$SDK_VERSION" python3 -c '
import json, os, sys
sdk = os.environ["SDK_VERSION"]
major_minor = "-".join(sdk.split(".")[:2])
devices = json.load(sys.stdin)["devices"]
def pick(match):
    for runtime, items in sorted(devices.items(), reverse=True):
        if "iOS" not in runtime or not match(runtime):
            continue
        for d in items:
            if d["name"].startswith("iPhone") and "Max" not in d["name"] and "Plus" not in d["name"]:
                print(d["udid"]); sys.exit(0)
pick(lambda r: r.endswith("iOS-" + major_minor))
pick(lambda r: r.split("iOS-")[-1].split("-")[0] == sdk.split(".")[0])
sys.exit(1)')
echo "Using simulator $UDID"

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b

xcodebuild -project Demo.xcodeproj -scheme Demo -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

APP="build/Build/Products/Debug-iphonesimulator/Demo.app"
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 || true

# True only when launchctl lists the app's job *with a numeric PID*. A job
# that crashed can stay listed with PID "-", so matching the label alone is
# not proof the process is alive.
alive () {
  xcrun simctl spawn "$UDID" launchctl list > "$RUNNER_TEMP/processes.txt"
  awk -v id="$BUNDLE_ID" 'index($3, id) && $1 ~ /^[0-9]+$/ { found = 1 } END { exit !found }' "$RUNNER_TEMP/processes.txt"
}

shoot () {
  local name="$1"; local settle="$2"; shift 2
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@"
  local up=0
  for _ in $(seq 1 60); do
    if alive; then up=1; break; fi
    sleep 1
  done
  [ "$up" = 1 ] || { echo "app never started: $name"; exit 1; }
  # Let the launch scenario play out (swipes, condition changes, settling).
  sleep "$settle"
  alive || { echo "app is not running after its scenario: $name"; exit 1; }
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png"
}

shoot 1-steady-wifi 10
shoot 2-fling 12 -scenario fling
shoot 3-thermal-critical 10 -scenario hot
shoot 4-offline-from-cache 10 -scenario offline
shoot 5-learned-skipper 20 -scenario skipper
shoot 6-cellular-low-power 10 -scenario cellular-low-power
ls -la "$OUT"
