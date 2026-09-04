---
name: screenshots-release
description: Regenerate and upload the App Store screenshots of WhereIWas — capture the five cards in nine locales, frame them with Koubou, assemble and validate the IPHONE_65 set, then replace what the store serves with asc. Use when asked to redo, refresh, reframe or upload the screenshots, or when a UI or copy change made a card wrong.
---

# The App Store screenshots

App `6808349924`, version `1.0.0`, display type `IPHONE_65` (1242×2688 portrait, the only size
an iPhone-only submission needs). Nine App Store locales: `en-US`, `fr-FR`, `de-DE`, `es-ES`,
`it`, `ja`, `nl-NL`, `pl`, `cs` — a different namespace from the app's language codes, which is
why `screenshots.sh` maps one onto the other.

Five cards, in upload order (files upload alphabetically, hence the numbering):

| # | File | Screen | Argument |
|---|------|--------|----------|
| 1 | `01-status-moving` | Status, `moving` | it records while you are not looking |
| 2 | `02-status-stationary` | Status, `stationary` | GPS sleeps, so does the battery drain |
| 3 | `03-map` | Map, yesterday | a whole day, street by street |
| 4 | `04-audit-trail` | Audit trail | every fix, accepted or rejected, with the reason |
| 5 | `05-export` | Export, scrolled to sessions | the data is yours to take |

`screenshots/LEDGER.md` records why the set looks like this; `screenshots/README.md` documents the
pipeline. Read the ledger before changing a card's meaning, the README before changing a template.

## Work out how much has to be redone

The three stages are independent, and each one costs more than the one after it. Start at the
lowest stage that covers the change — redoing everything for a headline typo wastes fifteen
minutes and rewrites 45 tracked PNGs for nothing.

| What changed | Re-capture | Re-frame | Re-upload |
|---|---|---|---|
| App UI, demo dataset, a localized app string | yes | yes | yes |
| Headline or subtitle copy, a template, a crop window | no | yes | yes |
| Nothing — the store lost or rejected an asset | no | no | yes |

"App UI" includes anything **visible** on one of the five screens. A string removed below the fold
changes nothing: check the flat capture before assuming. Only the affected cards need redoing, but
`scripts/screenshots.sh` captures all five per locale, so the unit of re-capture is a locale.

**The data on the cards is hand-written, and the compiler will not tell you it has drifted.**
`WhereIWas/App/DemoTrackingController.swift` builds the audit events, the transitions and the
session summaries as literals — an `AuditEvent` whose `name`, `message` and `details` were typed to
match what the coordinator emitted at the time. Change the shape of the audit log, the vocabulary
of a message, or the set of details, and that file still compiles and still renders: it just shows
a screen the app no longer produces. Re-read it against the real producers
(`Coordinator/TrackingCoordinator.swift`, `Location/LocationEngine.swift`,
`Domain/AuditEvent.swift`) whenever one of them moves, and fix the demo data *before* capturing.
The tests do not cover this — `DemoTracksTests` checks the track fixtures, nothing checks the
audit fixtures.

## 1. Capture — `screenshots/flat/`

```bash
./scripts/screenshots.sh                 # all nine locales, ~15 min
./scripts/screenshots.sh de-DE ja        # just these
```

It builds the `Screenshots` configuration, installs it on the pinned simulator, and launches it
once per card with `-screenshotScreen` and `-screenshotScenario`. No taps, so nothing depends on a
tab label. Output is the full-resolution alpha-flattened capture in `screenshots/flat/<locale>/`,
which is gitignored: it is raw material, not an asset.

**Nothing else may drive the simulator while this runs.** In particular `./scripts/xcb.sh test`:
its test host is the Debug app under the same bundle identifier, so it installs straight over the
Screenshots build, and the Debug app has no `ScreenshotMode` — it ignores the launch arguments and
lands on the default tab every time. That produced 45 identical permission-denied Status screens
once, and the script reported success. It now refuses a locale whose captures are not five
distinct images, which is the only cheap way to catch it.

Run it in the background and wait on the process rather than blocking a tool call for 15 minutes:

```bash
nohup ./scripts/screenshots.sh > /tmp/capture.log 2>&1 &
while pgrep -f screenshots.sh >/dev/null; do sleep 15; done
```

## 2. Frame — Koubou

```bash
kou generate screenshots/koubou/config.yaml        # all nine locales, ~2 min
```

Sources are `screenshots/koubou/`: `config.yaml`, five templates, and `koubou-strings.xcstrings`
holding one set of nine translations (LEDGER D13 — one template set, never a template per
language). Renders land in `out/`, gitignored.

- **Headline and subtitle copy lives in the string catalog**, not in the templates. Translate
  against the market's own approved listing in `metadata/version/1.0.0/<locale>.json`, not from
  the English: the cards and the description should use the same words for the same claim.
- **`kou generate` has no locale flag.** To iterate on one language, copy the config to
  `screenshots/koubou/<name>.local.yaml` (gitignored) with a trimmed `languages` list.
- **`--output json` is not machine-parseable**: log lines precede the JSON. Read `out/` and the
  `*.layout.json` sidecars instead.
- **Japanese line breaks are hand-placed.** The templates set `word-break: keep-all` and each
  Japanese string carries U+200B zero-width spaces at its phrase boundaries — otherwise Chromium
  breaks between any two characters and tears particles off their nouns. They are invisible in an
  editor: `grep -c $'​' screenshots/koubou/koubou-strings.xcstrings` must find ten, one per
  string. Editing a Japanese string means re-placing them.

## 3. Assemble — `screenshots/IPHONE_65/`

```bash
./screenshots/assemble.sh                 # [--keep-stale] [--no-validate]
```

Flattens away the device-frame directory Koubou adds, removes what an earlier naming scheme left
behind, and refuses to leave a set on disk the upload would reject: exactly 1242×2688, no alpha
channel, non-empty, and no card far smaller than the same card in the other locales — a blank
render is small, not missing. `asc screenshots validate` runs on top, per locale.

**`asc screenshots validate` checks dimensions and nothing else.** It reported a clean bill on a
set carrying an alpha channel, which the upload then rejected with `IMAGE_ALPHA_NOT_ALLOWED`, and
the rejected asset stayed in the set as `FAILED`. The alpha check in `assemble.sh` is the one that
matters.

## 4. Look at them

The checks above prove the files are uploadable, not that they are right. Nothing in the pipeline
can tell a correct card from a card of the wrong screen — that failure looked exactly like success.

Read at least these as images before uploading:

- **de-DE** — the language that truncates first; the headline auto-fit floor is 9vw and three
  cards sit near it.
- **ja** — check every line breaks at a phrase boundary, and that nothing runs off the canvas:
  `keep-all` makes an over-wide phrase unbreakable, and it will overflow rather than shrink.
- **pl** or **cs** — long compounds, and the locales whose export screen has an extra footer line.
- The card you actually changed, in every locale, if it was a crop.

## 5. Upload

Screenshots hang off a **version localization**, one per locale. App Store Connect does **not**
inherit them from the primary locale: each of the nine needs its own upload.

```bash
asc versions list --app 6808349924 --output table                      # the version id
asc localizations list --version "VERSION_ID" --output table           # confirm nine locales
asc screenshots list --version "VERSION_ID" --locale en-US --output json
```

The list JSON is `{versionLocalizationId, sets: [{set, screenshots: [...]}]}` — the screenshots are
nested under a set per display type, not at the top level. That is where the version-localization
id for the upload comes from.

**Delete what the new set does not replace, first.** An upload adds assets; it does not reconcile
names. When the file names changed, the old ones stay and the listing serves both:

```bash
asc screenshots delete --id "SCREENSHOT_ID" --confirm
```

Then upload each locale. Nine locales take well over ten minutes — background it:

```bash
asc screenshots upload --version-localization "VERSION_LOCALIZATION_ID" \
  --path "./screenshots/IPHONE_65/<locale>" --device-type "IPHONE_65"
```

Read the result back rather than trusting the exit code: every asset must be `COMPLETE`, and the
five file names must be the five expected ones.

Deleting live assets and uploading are outward-facing. Check what state the version is in before
touching anything — `PREPARE_FOR_SUBMISSION` means nothing is public yet; a version in review or
released is a different conversation, and belongs to the user.

## 6. Record it

`screenshots/IPHONE_65/` is committed — it is the record of what the store was given. Commit it
with whatever produced it (templates, copy, capture-script change) and say in the body what
changed and why. Update `screenshots/LEDGER.md`: it carries the decisions and their open
questions, and a card that has just gone stale belongs there.

Never `git add -A`. The working tree usually holds work in progress that is not yours.

## Traps

- **`asc` prints raw JSON by default**, and a screenshot list is thousands of tokens. Pass
  `--output table`, or pipe through `python3 -c` / `jq`.
- **`--version-id` is deprecated** on the localization commands; `--version` takes the same id.
- **The status-bar clock is drawn by the system, not the app.** `-AppleLanguages` relanguages the
  app only, so the capture script moves the simulator's own locale per locale and restores it on
  exit. Do not add `--time` back to `status_bar override`: it renders with a format of its own and
  printed "09:41" under an en-US system. See LEDGER D16.
- **A card can be truthful when captured and false a week later.** The audit trail's rows, the
  Status counters, any string that moves above the fold — a UI change is a screenshot change.
  `git log --oneline <last screenshot commit>..HEAD -- WhereIWas/UI WhereIWas/Resources` is the
  cheap check.
- **`WHEREIWAS_SCHEME=WhereIWas-Screenshots ./scripts/xcb.sh -- -configuration Screenshots build`**
  is how to compile the `#if SCREENSHOTS` code by hand; `xcodebuild` refuses `-scheme` twice, so
  the wrapper takes it from the environment.
