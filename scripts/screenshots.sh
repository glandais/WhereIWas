#!/usr/bin/env bash
#
# App Store screenshots, both locales, from mocked data.
#
# Builds the app in the `Screenshots` configuration (see `project.yml`), then
# launches it once per screen and per locale with the launch arguments read by
# `ScreenshotMode`. One launch per screenshot means no taps: nothing depends on
# a tab label, which differs between English and French.
#
# Output: screenshots/IPHONE_65/<locale>/NN-name.png, resized to an accepted
# dimension and flattened (App Store Connect rejects an alpha channel).
# Uploading stays manual — see screenshots/README.md.
#
# Usage: ./scripts/screenshots.sh [locale ...]      (default: en-US fr-FR)

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="io.github.glandais.whereiwas"
DEVICE_NAME="${SCREENSHOT_DEVICE:-iPhone 17 Pro Max}"
DERIVED="${SCREENSHOT_DERIVED_DATA:-.build/DerivedData}"
RAW_DIR="screenshots/raw"
OUT_ROOT="screenshots/IPHONE_65"
# An accepted IPHONE_65 portrait size (`asc screenshots sizes`); every current
# Pro Max simulator captures larger than this and has to be scaled down.
WIDTH=1284
HEIGHT=2778

# screen argument -> output file name, in upload order (files upload
# alphabetically, hence the numbering).
SCREENS=(
  "map:01-map"
  "status:02-status"
  "audit:03-audit-trail"
  "export:04-export"
  "settings:05-settings"
)

locales=("$@")
if [ ${#locales[@]} -eq 0 ]; then locales=(en-US fr-FR); fi

# The demo dataset spans about 92 minutes ending "now" and must fit inside
# today, or the map (which shows one day at a time) would only get its tail.
# Run before ~01:40 and it is squeezed into what little of the day has
# elapsed, which prints implausible session durations.
if [ "$(date +%H%M)" -lt 0140 ]; then
  echo "⚠️  It is $(date +%H:%M): the demo track will be compressed into the few" >&2
  echo "   minutes elapsed today, and session durations will look wrong." >&2
  echo "   Run again later in the day for shots worth uploading." >&2
fi

UDID=$(xcrun simctl list devices available -j \
  | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next(v['udid'] for r in d for v in d[r] if v['name']=='${DEVICE_NAME}'))")
echo "▸ simulator ${DEVICE_NAME} (${UDID})"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "▸ building (Screenshots configuration)"
xcodebuild -project WhereIWas.xcodeproj \
  -scheme WhereIWas-Screenshots \
  -configuration Screenshots \
  -destination "platform=iOS Simulator,id=${UDID}" \
  -derivedDataPath "$DERIVED" \
  build >/dev/null

APP="${DERIVED}/Build/Products/Screenshots-iphonesimulator/WhereIWas.app"
xcrun simctl install "$UDID" "$APP"

# A clean status bar: full battery, full signal, and the host's current time
# so it agrees with the in-app timestamps (the demo dataset is anchored on the
# real clock). Set SCREENSHOT_TIME to pin it, e.g. the classic "9:41".
# simctl rejects an hour of 0, and the midnight hour is warned against above.
STATUS_TIME="${SCREENSHOT_TIME:-$(date +%-H:%M)}"
case "$STATUS_TIME" in 0:*) STATUS_TIME="9:41" ;; esac
xcrun simctl status_bar "$UDID" override \
  --time "$STATUS_TIME" --batteryLevel 100 --batteryState discharging \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3
trap 'xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true' EXIT

for locale in "${locales[@]}"; do
  lang="${locale%%-*}"
  apple_locale="${locale/-/_}"
  mkdir -p "$RAW_DIR/$locale" "$OUT_ROOT/$locale"
  echo "▸ $locale"

  for entry in "${SCREENS[@]}"; do
    screen="${entry%%:*}"
    name="${entry##*:}"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" \
      -screenshotMode YES \
      -screenshotScreen "$screen" \
      -AppleLanguages "($lang)" \
      -AppleLocale "$apple_locale" >/dev/null
    # Let the map camera settle and the export file be written.
    sleep 6
    xcrun simctl io "$UDID" screenshot --type=png "$RAW_DIR/$locale/$name.png" >/dev/null 2>&1
    echo "   · $name"
  done
done

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "▸ resizing to ${WIDTH}x${HEIGHT} and dropping the alpha channel"
python3 - "$RAW_DIR" "$OUT_ROOT" "$WIDTH" "$HEIGHT" "${locales[@]}" <<'PY'
import sys, pathlib
from PIL import Image

raw, out, width, height = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
for locale in sys.argv[5:]:
    for src in sorted(pathlib.Path(raw, locale).glob("*.png")):
        im = Image.open(src)
        if "A" in im.getbands():
            # App Store Connect answers IMAGE_ALPHA_NOT_ALLOWED otherwise, and
            # `asc screenshots validate` does not catch it. Black, since the
            # rounded corners sit on a dark app.
            bg = Image.new("RGB", im.size, (0, 0, 0))
            bg.paste(im, mask=im.getchannel("A"))
            im = bg
        else:
            im = im.convert("RGB")
        im = im.resize((width, height), Image.LANCZOS)
        dst = pathlib.Path(out, locale, src.name)
        im.save(dst, "PNG", optimize=True)
        print(f"   · {dst}")
PY

echo "▸ done. Validate before uploading:"
for locale in "${locales[@]}"; do
  echo "   asc screenshots validate --path \"./$OUT_ROOT/$locale\" --device-type \"IPHONE_65\""
done
