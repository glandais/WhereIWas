# App Store screenshots

Three stages, two of them scripted:

```bash
./scripts/screenshots.sh                              # 1. capture  -> screenshots/flat/<locale>/
kou generate screenshots/koubou/config.yaml           # 2. frame    -> screenshots/koubou/out/<locale>/<device>/
./screenshots/assemble.sh                             # 3. assemble -> screenshots/IPHONE_65/<locale>/
```

**1. Capture.** `./scripts/screenshots.sh` produces the **flat captures** — five screens × nine
locales, from mocked data, no device frame and no manual navigation. They land in
`screenshots/flat/<locale>/*.png` (gitignored).

```bash
./scripts/screenshots.sh              # every locale the app ships in
./scripts/screenshots.sh fr-FR        # one locale
WHEREIWAS_SIM_DEVICE="iPhone 17 Pro" ./scripts/screenshots.sh
SCREENSHOT_TIME="9:41" ./scripts/screenshots.sh    # pin the status-bar clock
```

**Nothing else may drive the simulator while this runs**: `./scripts/xcb.sh test` installs the
Debug app over the same bundle identifier mid-run, and the Debug app has no `ScreenshotMode`, so it
lands on the default tab every time. The script checks that the five captures in a locale are five
distinct files (fails on a shared md5) to catch that.

**2. Frame.** Koubou turns each flat capture into the **marketing card** that goes on the store:
device frame, headline, subtitle, brand field. Sources live in `screenshots/koubou/` and are
committed — `config.yaml`, `templates/` (five layouts) and `koubou-strings.xcstrings` (the ten
headline/subtitle strings in nine languages, D13). Renders are gitignored. Koubou resolves
`../flat/01-map.png` per locale by convention, so the config names each capture once.

`kou generate` has no locale flag: to iterate on one language, copy the config to
`screenshots/koubou/x.local.yaml` (gitignored) and trim its `localization.languages` list, or use
`kou live <config>` for a preview that reloads as you edit.

**3. Assemble.** Koubou writes `out/<locale>/<device frame name>/NN-*.png`; App Store Connect wants
`screenshots/IPHONE_65/<locale>/NN-*.png`. `./screenshots/assemble.sh` flattens that extra level,
deletes anything in the destination the new render does not replace (stale files from an old
naming would otherwise upload alongside the new ones), and refuses to leave a set on disk the
upload would reject: 1242×2688 exactly, no alpha channel, non-empty, and not far smaller than the
same card in the other locales. It finishes with `asc screenshots validate` per locale.
`--keep-stale` skips the deletion, `--no-validate` the asc pass.

`screenshots/IPHONE_65/` is what is committed, numbered because assets upload in filename order:
`01-map`, `02-status-moving`, `03-status-stationary`, `04-export`, `05-audit-trail`. The map leads
because the first three cards show in search results and the listing sells a location timeline; the
two Status cards cover the moving and stationary scenarios; the audit trail, the most technical
card, closes. Settings left the set.

The app is iPhone-only (`TARGETED_DEVICE_FAMILY: "1"`), so `IPHONE_65` is the only display type
submission requires — 1242×2688 or 1284×2778 portrait (`asc screenshots sizes` re-checks). Koubou
scales the capture itself when compositing the frame, so the capture step no longer resizes
anything; it still checks the capture came out phone-shaped, refusing anything more than 2% off the
pinned Pro Max's ratio.

## How it works

- The app is built in the **`Screenshots`** configuration (see `project.yml`), which defines the
  `SCREENSHOTS` compilation condition. Everything the mode needs — `ScreenshotMode`,
  `DemoTrackingController`, the launch-argument hooks — lives under `#if SCREENSHOTS` and is absent
  from the archived Release binary. Check with:
  `xcodebuild -target WhereIWas -configuration Release -showBuildSettings | grep SWIFT_ACTIVE`
- Each screenshot is one launch:
  `simctl launch … -screenshotMode YES -screenshotScreen map -screenshotScenario moving -AppleLanguages "(fr)" -AppleLocale fr_FR`.
  `-screenshotScreen` takes `status`, `map`, `export`, `settings` or `audit` (the audit trail opens
  from Settings); `-screenshotScenario` takes `moving` or `stationary`. No taps, so nothing depends
  on a tab label that differs between locales.
- With `screenshotMode` on, `AppDelegate` skips `AppEnvironment.bootstrap`: no `CLLocationManager`,
  permission prompts, BGTask or on-disk store — the UI runs entirely on `DemoTrackingController`.

To change what the shots show — the phase, the audit events, the session list, how the track is
resampled into fixes — edit `WhereIWas/App/DemoTrackingController.swift`, the single source of the
mocked data. The geometry is in `WhereIWas/App/DemoTracks.swift`, one street-following polyline per
language, generated once by `scripts/generate-tracks.swift` from MapKit Directions and committed:
captures stay deterministic and need no network. Each track is a walking loop, a drive across town
and a walk at the far end, between public places over public roads — no identifiable address.

`generate-tracks.swift` needs a run loop around the MapKit Directions completion handler (a bare
semaphore wait deadlocks) and rate-limits its legs; pass `--osrm` to route against the public OSRM
server instead if Apple ever throttles requests. MKDirections has no waypoint API, so each city loop
is stitched from four pairwise-routed legs, and re-running the script can return
different-but-equivalent geometry for the same city — review the diff against the printed summary
rather than expecting it to be empty. Route length must land inside 5–10 km: Rome's and Prague's
endpoints were deliberately moved to fit that range, and Tokyo is a documented exception at about
4.13 km because its tiles are dense.

## The two clocks

The dataset is anchored twice, on purpose:

- **Status, the transitions list and the audit trail** are anchored on launch time, so "11 sec.
  ago" stays true whenever the capture runs — which is why the script pins the status bar to the
  host's own hour rather than a fixed one.
- **Map and Export** sit on fixed daytime windows on *past* days — yesterday 08:12→10:05, the day
  before 14:20→16:40 — so a capture at any hour shows the same complete day. The map opens on
  yesterday because today holds only the drive still in progress, the one Status reports on.

## One trap left

**No alpha channel.** App Store Connect rejects any screenshot carrying one
(`IMAGE_ALPHA_NOT_ALLOWED`) — iPhone screenshots have one, since the rounded screen corners are
transparent. The capture script flattens on black, before Koubou, so neither framing nor upload has
to think about it — but `asc screenshots validate` does **not** catch it, checking dimensions only.
The failure surfaces during upload, and the rejected asset stays in the set as `FAILED`; delete it
with `asc screenshots delete --id <id>` before retrying. `./screenshots/assemble.sh` is the check
that does catch it, on all forty-five files, before anything is uploaded.

Locales are named by their **App Store Connect** code, not the app's language code, since that is
what `asc screenshots upload` reads: `de-DE`, `es-ES`, `it`, `ja`, `nl-NL`, `pl`, `cs` — where the
bundle carries `de`, `es`, `nl`. The script maps each `project.yml` `knownRegions` language through
`asc_locale_for`, which *fails* on a language it does not know rather than guessing — stopping a
tenth market from silently landing in another market's directory. `apple_locale_for` maps the other
way, store code onto the `-AppleLocale` the simulator wants (`it` → `it_IT`, `ja` → `ja_JP`, …), so
dates, numbers and units (miles in `en-US`, metric elsewhere, per `TrackingSettings.unitSystem`)
come out of the right market. `WhereIWasTests/DemoTracksTests.swift` asserts every `knownRegions`
language has a track fixture; its list is hand-kept like the script's mapping, so a language added
only to `project.yml` fails loudly.

German, Polish and Czech are the layouts worth checking before uploading — compound words are long
and unbreakable, and single-line rows (`LabeledContent`, tab titles, picker segments) truncate
there first; Japanese compresses and is safe. The audit trail's `message` and `name` fields staying
English in the `fr-FR` shots is *not* a bug: audit payloads are machine text written to the
exports, not localized strings (same rule as `StateTransitionRecord.reason`).

## Framing notes

Five layouts, one per card, no two alike. `04-export-card` and `05-audit-band` carry no device
frame — at 0.61× the audit rows and export session list become unreadable inside one, so those
templates crop a documented window out of the capture instead (audit band at 1.07×, export card at
0.85×; each template's header records its window in source pixels).

Card 4's window is measured from the **bottom**, because `ExportView` bottom-anchors the session
list in screenshot mode: the session card ends at y 2574 (2558 in en-US) with a 197px row pitch in
all nine locales. The crop's bottom edge is pinned (16px under the card, 28px clear of the tab bar)
while its top edge is deliberately loose, landing in row whitespace so it absorbs the drift from
longer format-description and footer text in ja/pl/cs/de. The card shows the prepared file, the
footer and all six sessions; the format picker above stays out of frame.

### Japanese line breaks — an invisible convention

Chromium breaks Japanese between any two characters, tearing particles off the nouns they govern
(`一日の軌跡` once split mid-word). This renderer has no `word-break: auto-phrase`, so break points
are named by hand instead: templates set `word-break: keep-all`, and each Japanese string in
`koubou-strings.xcstrings` carries a **U+200B zero-width space** at each phrase boundary — the only
places a line may end. Latin text is unaffected.

**Editing a Japanese string means re-placing its U+200B** — invisible in every editor, so
`grep -c $'​'` on the catalog is how to see them. The auto-fit script also treats
`scrollWidth > clientWidth` as "over" alongside its height test, since a phrase with nowhere to
break can otherwise run off the canvas edge unnoticed.

Each copy block declares the share of canvas height it owns (`data-fit-budget`); a short inline
script steps the headline down until it fits, then the subtitle. English never moves, and the floor
is 9vw — below the 10vw the Koubou skill asks for on this canvas class, a deliberate escape hatch
against a German or Polish headline colliding with the device. Where it bites: the two
Status cards (2 and 3) and the export card (4), in German, Polish and Czech first. Sizes were
measured per locale for the September 2026 copy and are not recorded here — re-read the renders
after any copy change instead. A line-breaking result is not a budget one: a headline that wants
one more line at a given size gains nothing from a larger budget, only from shorter words.

French puts a space before `:` `;` `?` `!` — make it a no-break space (U+00A0) in the catalog, or the
punctuation can wrap onto a line of its own.

## Uploading

```bash
asc localizations list --version-id "VERSION_ID"     # get the version-localization IDs

asc screenshots upload \
  --version-localization "VERSION_LOCALIZATION_ID" \
  --path "./screenshots/IPHONE_65/en-US" \
  --device-type "IPHONE_65"
```

Repeat per locale — ASC does not inherit screenshots from the primary locale, so all nine need
their own upload. `assemble.sh` has already run `asc screenshots validate` on each directory, so
there is no need to run it again by hand.

Current state: the five hand-taken shots uploaded to app 6808349924, version 1.0.0, `en-US` are
still what the store serves (delivery state COMPLETE) — a different set under different names; the
forty-five framed cards on disk replace them and none of the nine locales has been uploaded yet.
