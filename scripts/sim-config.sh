#!/usr/bin/env bash
#
# The one simulator this project uses, and nothing else.
#
# This Mac has limited resources, and the repo used to name three different
# destinations (`README.md`, `CLAUDE.md` and `scripts/screenshots.sh` each had
# their own), so a build could boot a device nobody asked for. Everything now
# resolves the destination here.
#
# `iPhone 17 Pro Max` is not an arbitrary pick: nothing resizes a capture any
# more (`scripts/screenshots.sh` only checks its shape and flattens alpha), so
# the device has to be the one Koubou frames — `screenshots/koubou/config.yaml`
# pins the "iPhone 17 Pro Max" frame, and the framed cards it renders are the
# 1242x2688 IPHONE_65 assets App Store Connect wants. Any other device would
# mean keeping two simulators around.
#
# Sourced, never executed:  source "$(dirname "$0")/sim-config.sh"

SIM_DEVICE="${WHEREIWAS_SIM_DEVICE:-iPhone 17 Pro Max}"
DERIVED_DATA="${WHEREIWAS_DERIVED_DATA:-.build/DerivedData}"

# Echoes the UDID of $SIM_DEVICE, or explains what is available and fails.
sim_udid() {
  local udid
  udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
for runtime in devices:
    for device in devices[runtime]:
        if device["name"] == name:
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
' "$SIM_DEVICE") || {
    echo "sim-config: no available simulator named '${SIM_DEVICE}'." >&2
    echo "Available devices:" >&2
    xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in devices:
    for device in devices[runtime]:
        print("  " + device["name"])
' >&2
    echo "Create it in Xcode, or override with WHEREIWAS_SIM_DEVICE." >&2
    return 1
  }
  echo "$udid"
}

# Boots $SIM_DEVICE if needed and waits for it. Idempotent.
sim_boot() {
  local udid="${1:-}"
  if [ -z "$udid" ]; then udid=$(sim_udid) || return 1; fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
}

# The only -destination any xcodebuild invocation in this repo may use.
sim_dest() {
  local udid="${1:-}"
  if [ -z "$udid" ]; then udid=$(sim_udid) || return 1; fi
  echo "platform=iOS Simulator,id=${udid}"
}
