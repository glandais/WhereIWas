# App Store screenshots

Three stages, two of them scripted:

```bash
./scripts/screenshots.sh                              # 1. capture  -> screenshots/flat/<locale>/
kou generate screenshots/koubou/config.yaml           # 2. frame    -> screenshots/koubou/out/<locale>/<device>/
./screenshots/assemble.sh                             # 3. assemble -> screenshots/IPHONE_65/<locale>/
```

**1. Capture.** `./scripts/screenshots.sh` produces the **flat captures** — five screens × nine
locales, from mocked data, no device frame and no manual navigation.

```bash
./scripts/screenshots.sh              # every locale the app ships in
./scripts/screenshots.sh fr-FR        # one locale
WHEREIWAS_SIM_DEVICE="iPhone 17 Pro" ./scripts/screenshots.sh
SCREENSHOT_TIME="9:41" ./scripts/screenshots.sh    # pin the status-bar clock
```

They land in `screenshots/flat/<locale>/*.png` (gitignored: regenerated material, not an asset).

**Nothing else may drive the simulator while this runs.** The script installs the `Screenshots`
build, but anything that installs over `io.github.glandais.whereiwas` mid-run wins — and
`./scripts/xcb.sh test` does exactly that, since the test host is the Debug app under the same
bundle identifier. The Debug app has no `ScreenshotMode`, so it ignores `-screenshotScreen` and
lands on the default tab every time: forty-five captures of the same permission-denied Status
screen, from a script that reported success. That is why the script now checks that the five
captures in a locale are five distinct files and fails if any two share an md5.

**2. Frame.** Koubou turns each flat capture into the **marketing card** that goes on the store
(LEDGER D1): device frame, headline, subtitle, brand field. Sources live in `screenshots/koubou/`
and are committed — `config.yaml`, `templates/` (five layouts) and `koubou-strings.xcstrings`, the
ten headline/subtitle strings in nine languages (D13). Renders are gitignored. Koubou resolves
`../flat/01-status-moving.png` per locale by convention (`flat/<language>/01-status-moving.png`),
so the config names each capture once.

A full run takes about two minutes for all nine locales. `kou generate` has no locale flag, so to
iterate on a template against one language, copy the config to `screenshots/koubou/x.local.yaml`
(gitignored) and trim its `localization.languages` list — or use `kou live <config>` for a preview
that reloads as you edit.

**3. Assemble.** Koubou writes `out/<locale>/<device frame name>/NN-*.png`; App Store Connect wants
`screenshots/IPHONE_65/<locale>/NN-*.png`. `./screenshots/assemble.sh` flattens that extra level,
deletes anything in the destination the new render does not replace (the naming changed once
already — `01-map…05-settings` became `01-status-moving…05-export`, and stale files would have
uploaded alongside the new ones), and then refuses to leave a set on disk the upload would reject:
1242×2688 exactly, no alpha channel, non-empty, and not far smaller than the same card in the other
locales. It finishes with `asc screenshots validate` per locale. `--keep-stale` skips the deletion,
`--no-validate` the asc pass.

`screenshots/IPHONE_65/` is what is committed. Cards are numbered because assets upload in filename
order: `01-status-moving`, `02-status-stationary`, `03-map`, `04-audit-trail`, `05-export`. Status
leads twice — it is the only screen that says what the app *is*, and its two scenarios make the two
opposite arguments (it records while you move; it lets GPS go while you do not). Settings left the
set (LEDGER D2/D3).

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
before retrying. `./screenshots/assemble.sh` is the check that does catch it, on all forty-five
files, before anything is uploaded.

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

## Framing notes

Five layouts, one per card, no two alike. Two of them (`04-audit-band`, `05-export-card`) carry no
device frame: inside one, the audit rows and the export session list render at 0.61× and stop being
readable, so those templates crop a documented window out of the capture instead — the audit band at
1.07×, the export card at 0.85×. Each template's header records its window in source pixels.

Card 5's window is measured from the **bottom** of the capture, and that is the whole trick.
`ExportView` scrolls the session list into view in screenshot mode, so the content is
bottom-anchored: the session card ends at y 2574 in eight locales and 2558 in en-US, and its six
rows keep a 197px pitch in all nine. Everything that moves is *above* it — the format description is
three lines in ja/pl/cs against two elsewhere, and the "files are written to…" footer takes a third
line in German and Polish — which shifts the prepared-file card up by as much as 60px. So the crop's
bottom edge is pinned (16px under the card, 28px clear of the tab bar) and its top edge is
deliberately loose, landing in row whitespace in every language: under the share-row divider in
en/de/es/fr/it/nl, under the "Prepare GPX file" row in ja/pl/cs. A window measured from the top
would have to absorb that drift twice over. The card shows the prepared file (share row, name,
size), the footer, and all six sessions across three days with their sample counts, distances and
durations — which is what the screen actually sells; the format picker above it is a settings row
and stays out of frame.

One template set serves nine languages, so each copy block declares the share of canvas height it
owns (`data-fit-budget`) and a short inline script steps the headline down until it fits, then the
subtitle. English never moves. The floor is 9vw, under the 10vw the Koubou skill asks for on this
canvas class — a deliberate escape hatch, chosen over letting a German or Polish headline collide
with the device. Where it bites: card 1 (German and Polish on the 9vw floor, Czech 9.15), card 2
(German 10.25, Spanish and French 10.55, Italian 10.85) and card 5 (German 9.80, Dutch and Polish
10.55). All still large and legible. Card 5's German is a line-breaking result rather than a budget
one — "Sie entscheiden, wann Ihre Daten das iPhone verlassen" wants four lines until 9.80vw and
three from there down, so a larger budget would not buy the size back; shortening the headline
would. Cards 3 and 4 render at their template's full size in every locale.

## Uploading

```bash
asc localizations list --version-id "VERSION_ID"     # get the version-localization IDs

asc screenshots upload \
  --version-localization "VERSION_LOCALIZATION_ID" \
  --path "./screenshots/IPHONE_65/en-US" \
  --device-type "IPHONE_65"
```

Repeat per locale — ASC does not inherit screenshots from the primary locale, so all nine need
their own upload (LEDGER D15). `assemble.sh` has already run `asc screenshots validate` on each
directory, so there is no need to run it again by hand.

Current state: the five hand-taken shots uploaded to app 6808349924, version 1.0.0, `en-US` are
still what the store serves (delivery state COMPLETE). They are a different set under different
names; the forty-five framed cards on disk replace them and none of the nine locales has been
uploaded yet.
