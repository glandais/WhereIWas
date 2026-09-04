# App Store screenshots

Two halves. `./scripts/screenshots.sh` produces the **flat captures** — five cards × nine locales,
from mocked data, no device and no manual navigation — and Koubou frames each one into the
**marketing card** that actually goes on the store (LEDGER D1). Uploading stays manual.

```bash
./scripts/screenshots.sh              # every locale the app ships in
./scripts/screenshots.sh fr-FR        # one locale
WHEREIWAS_SIM_DEVICE="iPhone 17 Pro" ./scripts/screenshots.sh
SCREENSHOT_TIME="9:41" ./scripts/screenshots.sh    # pin the status-bar clock
```

Captures land in `screenshots/flat/<locale>/*.png` (gitignored: they are regenerated material, not
an asset). Koubou's framed output goes to `screenshots/IPHONE_65/<locale>/`, the layout
`asc screenshots upload` expects, and that is what is committed. Both are numbered because assets
upload in filename order: `01-status-moving`, `02-status-stationary`, `03-map`, `04-audit-trail`,
`05-export`. Status leads twice — it is the only screen that says what the app *is*, and its two
scenarios make the two opposite arguments (it records while you move; it lets GPS go while you do
not). Settings left the set (LEDGER D2/D3).

The app is iPhone-only (`TARGETED_DEVICE_FAMILY: "1"`), so `IPHONE_65` is the only display type
submission requires — 1242×2688 or 1284×2778 portrait (`asc screenshots sizes` re-checks). The
capture step no longer resizes anything, since Koubou scales the capture itself when it composites
the frame; what it still checks is that the capture came out phone-shaped at all, refusing anything
more than 2% off the pinned Pro Max's ratio — which is what a capture from another simulator would
be.

## How it works

- The app is built in the **`Screenshots`** configuration (see `project.yml`), which defines the
  `SCREENSHOTS` compilation condition. Everything the mode needs — `ScreenshotMode`,
  `DemoTrackingController`, the launch-argument hooks in the UI — lives under `#if SCREENSHOTS` and
  is absent from the archived Release binary. Check with:
  `xcodebuild -target WhereIWas -configuration Release -showBuildSettings | grep SWIFT_ACTIVE`
- Each screenshot is one launch:
  `simctl launch … -screenshotMode YES -screenshotScreen map -screenshotScenario moving -AppleLanguages "(fr)" -AppleLocale fr_FR`.
  `-screenshotScreen` takes `status`, `map`, `export`, `settings` or `audit` (the audit trail opens
  itself from Settings); `-screenshotScenario` takes `moving` or `stationary` and picks which story
  the dataset tells. No taps, so nothing depends on a tab label that differs between locales.
- With `screenshotMode` on, `AppDelegate` skips `AppEnvironment.bootstrap`: no `CLLocationManager`,
  no permission prompts, no BGTask, no on-disk store. The UI runs entirely on
  `DemoTrackingController`.

To change what the shots show — the phase, the audit events, the session list, how the track is
resampled into fixes — edit `WhereIWas/App/DemoTrackingController.swift`, the single source of the
mocked data. The geometry itself is in `WhereIWas/App/DemoTracks.swift`, one street-following
polyline per language, generated once by `scripts/generate-tracks.swift` from MapKit Directions and
committed (LEDGER D5/D6): captures stay deterministic and need no network. Each track is a walking
loop, a drive across town and a walk at the far end, between public places over public roads — no
identifiable address.

## The two clocks

The dataset is anchored twice, on purpose (LEDGER D11), and it is worth knowing which screen reads
which:

- **Status, the transitions list and the audit trail** are anchored on launch time, so "11 sec. ago"
  is true whenever the capture runs. Which is also why the script pins the status bar to the host's
  own hour rather than a fixed one.
- **Map and Export** sit on fixed daytime windows on *past* days — yesterday 08:12→10:05, the day
  before 14:20→16:40 — so a capture at 01:45 shows the same complete day as one at noon. The map
  opens on yesterday for the same reason: today holds only the drive still in progress, the one
  Status reports on. There is no longer a right or wrong hour to run this.

## One trap left

**No alpha channel.** App Store Connect rejects any screenshot carrying one
(`IMAGE_ALPHA_NOT_ALLOWED`) — iPhone screenshots have one, since the rounded screen corners are
transparent. The capture script flattens on black — before Koubou, so neither the framing step nor
an upload has to think about it — but `asc screenshots validate` does **not** catch it: it
checks dimensions only, and reported all five as ready. The failure surfaces during upload, and the
rejected asset stays in the set as `FAILED`; delete it with `asc screenshots delete --id <id>`
before retrying.

Locales are named by their **App Store Connect** code, not the app's language code, because the
directory name is what `asc screenshots upload` reads: `de-DE`, `es-ES`, `it`, `ja`, `nl-NL`, `pl`,
`cs` — where the bundle carries `de`, `es`, `nl`. The script reads the languages from
`project.yml`'s `knownRegions` and maps each through `asc_locale_for`, which *fails* on a language
it does not know rather than guessing: that is what stops a tenth market from silently landing in
another market's directory (LEDGER D12). `apple_locale_for` maps the other way, store code onto the
`-AppleLocale` the simulator wants (`it` → `it_IT`, `ja` → `ja_JP`, …), so dates and numbers come
out of the market the screenshot is for. Units follow that locale too — miles in `en-US`, metric
elsewhere — because `TrackingSettings.unitSystem` defaults to the device's.

`WhereIWasTests/DemoTracksTests.swift` asserts that every language in `knownRegions` has a track
fixture of its own. Its copy of that list is hand-kept, like the script's mapping; between the two
of them a language added to `project.yml` and nowhere else fails loudly.

German, Polish and Czech are the layouts worth looking at before uploading: compound words are long
and unbreakable, and the single-line rows (`LabeledContent`, tab titles, picker segments) are where
they truncate. Japanese is the safe one — it compresses.

The audit trail's `message` and `name` fields staying English in the `fr-FR` shots is *not* a bug:
audit payloads are machine text written to the exports, not localized strings (same rule as
`StateTransitionRecord.reason`).

## Uploading

```bash
asc screenshots validate --path "./screenshots/IPHONE_65/en-US" --device-type "IPHONE_65"

asc localizations list --version-id "VERSION_ID"     # get the version-localization IDs

asc screenshots upload \
  --version-localization "VERSION_LOCALIZATION_ID" \
  --path "./screenshots/IPHONE_65/en-US" \
  --device-type "IPHONE_65"
```

Current state: the five hand-taken shots uploaded to app 6808349924, version 1.0.0, `en-US` are
still what the store serves (delivery state COMPLETE). The local files have since been regenerated
and no longer match; the eight other locales have never been uploaded, and ASC does not inherit
screenshots from the primary locale — each one needs its own upload.
