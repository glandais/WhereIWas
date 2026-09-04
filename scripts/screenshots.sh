#!/usr/bin/env bash
#
# App Store screenshot *material*, every locale, from mocked data.
#
# Builds the app in the `Screenshots` configuration (see `project.yml`), then
# launches it once per card and per locale with the launch arguments read by
# `ScreenshotMode`. One launch per screenshot means no taps: nothing depends
# on a tab label, which differs between languages.
#
# Output: screenshots/flat/<locale>/NN-name.png — the full-resolution,
# alpha-flattened simulator capture. These are no longer the uploaded assets:
# Koubou frames each one into a marketing card (device frame + headline) at
# the size App Store Connect wants, written to screenshots/IPHONE_65/. See
# screenshots/README.md and the `koubou` skill for that half of the pipeline.
#
# Locales are read from `project.yml`'s `knownRegions` — the app's language
# codes — and mapped onto the *App Store Connect* locale a screenshot upload
# is filed under, which is a different namespace (`nl` the language vs.
# `nl-NL` the store market). `apple_locale_for` maps the other direction, ASC
# locale to the `-AppleLocale` the simulator wants.
#
# Usage: ./scripts/screenshots.sh [locale ...]      (default: every language
#                                                     in project.yml's
#                                                     knownRegions)

set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/sim-config.sh

BUNDLE_ID="io.github.glandais.whereiwas"
OUT_ROOT="screenshots/flat"

# card argument -> scenario -> output file name, in upload order (files
# upload alphabetically, hence the numbering). Status is split into its two
# scenarios; the rest only ever need `moving`, which is also the scenario
# that gives the map and export screens their busiest-looking data.
CARDS=(
  "status:moving:01-status-moving"
  "status:stationary:02-status-stationary"
  "map:moving:03-map"
  "audit:moving:04-audit-trail"
  "export:moving:05-export"
)

# `knownRegions` in project.yml is the single source of truth for which
# languages the app ships in (see CLAUDE.md, Localization); reading it here
# instead of hard-coding a list means a tenth language added there is picked
# up automatically rather than silently skipped. (`mapfile` would be neater
# but this machine's /bin/bash is the stock 3.2, which lacks it.)
LANGS=()
while IFS= read -r lang; do
  LANGS+=("$lang")
done < <(awk '
  /^  knownRegions:/ { f=1; next }
  f && /^    - / { sub(/^    - /, ""); print; next }
  f { exit }
' project.yml)

# App language code (project.yml's knownRegions) -> App Store Connect locale
# directory name. These are two different namespaces for the same nine
# markets: the bundle ships short language codes because none of them needs a
# region variant (`de` covers de-AT and de-CH too), but ASC files screenshots
# under its own per-market codes. Falling back to a guess here is exactly how
# a tenth market would silently land in Paris's directory (LEDGER D12), so an
# unmapped language is a hard failure, not a default.
asc_locale_for() {
  case "$1" in
    en) echo "en-US" ;;
    fr) echo "fr-FR" ;;
    de) echo "de-DE" ;;
    es) echo "es-ES" ;;
    nl) echo "nl-NL" ;;
    it) echo "it" ;;
    ja) echo "ja" ;;
    pl) echo "pl" ;;
    cs) echo "cs" ;;
    *)
      echo "✖ '$1' is in project.yml's knownRegions but has no App Store" >&2
      echo "  Connect locale mapping in asc_locale_for() — add one." >&2
      exit 1
      ;;
  esac
}

# App Store locale -> the `-AppleLocale` the simulator wants. The store drops
# the region on the locales that have a single market (`it`, `ja`, `pl`, `cs`);
# iOS still wants a full identifier, or dates and numbers fall back to a
# default region that is not the one the screenshot is for.
apple_locale_for() {
  case "$1" in
    it) echo "it_IT" ;;
    ja) echo "ja_JP" ;;
    pl) echo "pl_PL" ;;
    cs) echo "cs_CZ" ;;
    *)  echo "${1/-/_}" ;;
  esac
}

if [ "$#" -gt 0 ]; then
  locales=("$@")
else
  locales=()
  for lang in "${LANGS[@]}"; do
    locales+=("$(asc_locale_for "$lang")")
  done
fi

UDID=$(sim_udid)
echo "▸ simulator ${SIM_DEVICE} (${UDID})"
sim_boot "$UDID"

echo "▸ building (Screenshots configuration)"
xcodebuild -project WhereIWas.xcodeproj \
  -scheme WhereIWas-Screenshots \
  -configuration Screenshots \
  -destination "$(sim_dest "$UDID")" \
  -derivedDataPath "$DERIVED_DATA" \
  build >/dev/null

APP="${DERIVED_DATA}/Build/Products/Screenshots-iphonesimulator/WhereIWas.app"
xcrun simctl install "$UDID" "$APP"

# The status bar is drawn by the *system*, and the system is not what the
# launch arguments relanguage: `-AppleLanguages "(ja)"` reaches the app only,
# so the clock kept coming out in whatever language the simulator itself was
# in — nine identical bars over nine translated screens.
#
# Two things had to change for that. The simulator's own locale now moves with
# the capture — writing the global domain and restarting SpringBoard is what
# does it — and it is restored on exit, since this simulator is shared with
# every other build in the repo. And `status_bar override` is asked for a clean
# battery and a full signal but *not* for a time: `--time` renders with a
# format of its own (it printed "09:41" under an en-US system, which is wrong
# there), while the untouched clock is drawn by the system and therefore obeys
# the locale — en-US "6:18", fr "06:18", es/ja/cs without the leading zero,
# which is what CLDR actually says.
#
# The hour itself stays the host's current one, deliberately: the Status card
# prints the last fix as both "13 sec. ago" and an absolute time read off
# `ScreenshotMode.clock`, so a pinned 9:41 would contradict the screen right
# below it. Only Status depends on the host clock — D11 moved Map and Export
# onto fixed windows on past days. SCREENSHOT_TIME pins the hour anyway when a
# specific one is wanted, at the cost of that locale-correct formatting.
SYSTEM_LANGUAGES_BEFORE="$(xcrun simctl spawn "$UDID" defaults read -g AppleLanguages 2>/dev/null | tr -d ' \n"()' || true)"
SYSTEM_LOCALE_BEFORE="$(xcrun simctl spawn "$UDID" defaults read -g AppleLocale 2>/dev/null || true)"

# Puts the simulator's *system* into `$1` (a language tag) / `$2` (a locale
# identifier) and restarts SpringBoard so the change is picked up.
set_system_locale() {
  xcrun simctl spawn "$UDID" defaults write -g AppleLanguages -array "$1" >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" defaults write -g AppleLocale -string "$2" >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl stop com.apple.SpringBoard >/dev/null 2>&1 || true
  sleep 6
}

restore_simulator() {
  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
  if [ -n "$SYSTEM_LANGUAGES_BEFORE" ] && [ -n "$SYSTEM_LOCALE_BEFORE" ]; then
    set_system_locale "$SYSTEM_LANGUAGES_BEFORE" "$SYSTEM_LOCALE_BEFORE"
  fi
}

trap restore_simulator EXIT

for locale in "${locales[@]}"; do
  lang="${locale%%-*}"
  apple_locale="$(apple_locale_for "$locale")"
  mkdir -p "$OUT_ROOT/$locale"
  echo "▸ $locale"

  # The system locale moves with the capture so the status-bar clock is in the
  # language of the screen under it; the override is re-applied afterwards
  # because restarting SpringBoard drops it.
  set_system_locale "${apple_locale/_/-}" "$apple_locale"
  time_override=()
  [ -n "${SCREENSHOT_TIME:-}" ] && time_override=(--time "$SCREENSHOT_TIME")
  xcrun simctl status_bar "$UDID" override "${time_override[@]+"${time_override[@]}"}" \
    --batteryLevel 100 --batteryState discharging \
    --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3

  for entry in "${CARDS[@]}"; do
    screen="${entry%%:*}"
    rest="${entry#*:}"
    scenario="${rest%%:*}"
    name="${rest##*:}"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" \
      -screenshotMode YES \
      -screenshotScreen "$screen" \
      -screenshotScenario "$scenario" \
      -AppleLanguages "($lang)" \
      -AppleLocale "$apple_locale" >/dev/null
    # Let the map camera settle and the export file be written.
    sleep 6
    xcrun simctl io "$UDID" screenshot --type=png "$OUT_ROOT/$locale/$name.png" >/dev/null 2>&1
    echo "   · $name"
  done
done

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "▸ flattening alpha to black"
python3 - "$OUT_ROOT" "${locales[@]}" <<'PY'
import sys, pathlib
from PIL import Image

out = sys.argv[1]
# A simulator capture is a straight screen grab, so its aspect ratio is
# whatever the booted device is; the whole point of pinning the device (see
# CLAUDE.md, Simulator) is that it always comes out iPhone-shaped. This is
# not a resize step any more — Koubou takes the capture at native resolution
# and does its own scaling when it frames the card — but a capture from the
# wrong simulator would still be the wrong shape for a phone frame, so the
# check stays as a guard against that ever silently happening again.
TARGET_RATIO = 1290 / 2796  # iPhone 17 Pro Max, the pinned device
TOLERANCE = 0.02
for locale in sys.argv[2:]:
    for src in sorted(pathlib.Path(out, locale).glob("*.png")):
        im = Image.open(src)
        skew = abs((im.width / im.height) / TARGET_RATIO - 1)
        if skew > TOLERANCE:
            sys.exit(f"{src} is {im.width}x{im.height}, {skew:.0%} off an "
                     f"iPhone Pro Max's aspect ratio: WHEREIWAS_SIM_DEVICE "
                     f"must stay an iPhone Pro Max.")
        if "A" in im.getbands():
            # Koubou's frame templates composite onto an opaque capture;
            # an alpha channel here is also what App Store Connect answers
            # IMAGE_ALPHA_NOT_ALLOWED to further downstream, so flattening
            # now means neither Koubou nor an eventual upload has to think
            # about it again. Black, since the rounded corners sit on a dark
            # simulator chrome, not the app's own background.
            bg = Image.new("RGB", im.size, (0, 0, 0))
            bg.paste(im, mask=im.getchannel("A"))
            im = bg
        else:
            im = im.convert("RGB")
        im.save(src, "PNG", optimize=True)
        print(f"   · {src}")
PY

echo "▸ done: $OUT_ROOT/<locale>/NN-*.png, ${#CARDS[@]} cards × ${#locales[@]} locales."
echo "▸ next: frame these into marketing cards with Koubou (see the koubou skill"
echo "   and screenshots/LEDGER.md D1/D14), output to screenshots/IPHONE_65/<locale>/."
