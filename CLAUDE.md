# WhereIWas

iOS 17+ app (SwiftUI, SwiftData, Swift 6 strict concurrency) that records the GPS history of a
first responder over multi-day deployments: **reliably** (survives termination, reboot and going
offline), **accurately** (filtered samples carrying full metadata) and **without draining the
battery** (GPS only runs while the device is actually moving). Single app target plus a Swift
Testing target.

## Architecture

`ARCHITECTURE.md` is authoritative and describes the module map, the pure motion-detection state
machine, the GPS profile table, the sample filter, the SwiftData schema and the background /
relaunch contract. Read it before touching `Domain/`, `Coordinator/` or `Location/`. The invariant
it protects: `Domain/` is pure Swift (no CoreLocation, CoreMotion or SwiftData import), every
module boundary is a protocol in `Domain/Interfaces.swift` plus `Sendable` value types, and
SwiftData `@Model` classes never leave `Persistence/`.

## Build

```bash
./scripts/xcb.sh build              # WhereIWas scheme, Debug
./scripts/xcb.sh test               # + WhereIWasTests
./scripts/xcb.sh strings            # build, then sync the string catalog
./scripts/xcb.sh -- <args...>       # raw xcodebuild, destination still pinned
```

`WHEREIWAS_SCHEME` picks another scheme of the same project — in practice `WhereIWas-Screenshots`,
the only way to compile the `#if SCREENSHOTS` code. Signing is automatic against team
`7Q49262697`. Background behaviour (relaunch after termination, reboot, visits, CoreMotion
activity) cannot be tested in the simulator — see `ARCHITECTURE.md` §7 for the device test plan.

### Simulator

`./scripts/xcb.sh` is the only way to run `xcodebuild` against a simulator. It pins
`-destination` (by UDID) to the single device the project uses and `-derivedDataPath` to
`.build/DerivedData`. Never write a `-destination` by hand, and never use
`generic/platform=iOS Simulator`: it builds without booting anything, so the next command that
*does* need a device picks one on its own. `scripts/guard-simulator.py` (a `PreToolUse` hook from
`.claude/settings.json`) refuses any Bash command that would drive another simulator.

The device is `iPhone 17 Pro Max`, declared once in `scripts/sim-config.sh`. Not arbitrary:
`scripts/screenshots.sh` checks shape only, no resizing, so it must match the frame
`screenshots/koubou/config.yaml` pins ("iPhone 17 Pro Max"), whose cards are the 1242×2688
IPHONE_65 assets App Store Connect wants.

**Never run `./scripts/xcb.sh test` while a capture run is in flight.** The test host is the Debug
app under the same bundle id, so installing it replaces the Screenshots build mid-run and the
captures come back identical — the guard added in `e29a6e0` refuses this.

`WHEREIWAS_SIM_DEVICE` overrides the device, `WHEREIWAS_DERIVED_DATA` the build directory — the
hook only sees them when exported in the session environment, not prefixed onto a single command.

### Screenshot configuration

`project.yml` declares a **`Screenshots`** configuration (a Debug clone plus the `SCREENSHOTS`
compilation condition) and a `WhereIWas-Screenshots` scheme; `App/ScreenshotMode.swift`,
`App/DemoTrackingController.swift` and a few `#if SCREENSHOTS` blocks compile only there, so none
reaches the archived binary. Verify with:

```bash
xcodebuild -project WhereIWas.xcodeproj -target WhereIWas -configuration Release \
  -showBuildSettings | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS   # must be empty
```

`./scripts/screenshots.sh` drives it — see `screenshots/README.md`.

### Project generation (XcodeGen)

`WhereIWas.xcodeproj` is **generated** from `project.yml` and gitignored — `project.yml` is the
source of truth. After adding, removing or moving files, or changing build settings, run
`xcodegen generate` (the `WhereIWas` target sources the whole `WhereIWas/` folder, so new files are
picked up automatically). Three things that bite:

- `WhereIWas/Info.plist` exists on disk but is generated from the `info.properties` block and
  overwritten on every `xcodegen generate` — never edit it by hand.
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` are the single place to bump a
  version: `info.properties` maps `CFBundleShortVersionString` and `CFBundleVersion` onto them
  with `$(...)`. Without those two entries XcodeGen writes its own defaults (`1.0` / `1`) and the
  build number silently ignores `project.yml`.
- Keep the BGTask identifier in `project.yml` and `MaintenanceScheduler.taskIdentifier` in sync,
  or the task never runs.

## Localization

The app ships in **nine languages** — English (source), French, German, Spanish, Italian, Japanese,
Dutch, Polish and Czech — through two string catalogs under `WhereIWas/Resources/`:
`Localizable.xcstrings` (UI) and `InfoPlist.xcstrings` (the three permission prompts).
`knownRegions` in `project.yml` lists them.

Those are **short language codes** (`de`, `es`, `nl`), not region ones — `de` covers de-AT/de-CH,
`es` covers es-MX/es-419. App Store Connect uses its own codes for the same languages — `de-DE`,
`es-ES`, `nl-NL`, and `it`/`ja`/`pl`/`cs` bare — which name `metadata/` and the screenshot
directories.

The store has a **tenth locale, `es-MX`, that the app does not**: store metadata only. Latin
American storefronts read es-MX (without it they fall back to the English listing), and the US
storefront indexes its keywords too. Its text is es-ES with the Spain-only words swapped
(coche → auto, coste → costo) and keywords of its own; the bundle's `es` already covers the app.
There is no `screenshots/IPHONE_65/es-MX`: the es-ES set is uploaded to it (see the
`screenshots-release` skill).

**`i18n/translations.json` is the source of truth for every translation**; the catalogs are
generated from it. It aggregates the two catalogs above, the screenshot catalog
(`screenshots/koubou/koubou-strings.xcstrings`) and the store metadata under `metadata/` (20 files,
ten store locales) through `scripts/i18n.py export` / `import`, a byte-exact round trip
(`scripts/i18n.py check` proves it). **Never hand-edit a generated file** — the edit survives until
the next `import`, then is gone.

The permission prompts' English text lives in **two** places, edit both: `project.yml` (writes the
keys into the generated `Info.plist`) and the `en` unit of the catalog. iOS resolves
`en.lproj/InfoPlist.strings` first, so the catalog is what an English user reads;
`scripts/i18n.py` flags a divergence when only one moved. Don't drop the `en` unit either —
`xcstringstool` then emits the key itself as the value ("NSMotionUsageDescription").

Rules when adding UI strings:

- `Text("…")`, `Label("…")`, `Section("…")` literals localize automatically. A `String` variable
  passed to `Text`/`Label` does **not** — build it with `String(localized:)` at the source, or use
  `Text(verbatim:)` when the value is data (coordinates, an error, an audit payload).
- Technical identifiers stay English on purpose: `GPSProfile.label`, `AuditSeverity.label` and
  `StateTransitionRecord.reason` are persisted machine text (samples/exports/tests) — the UI shows
  localized counterparts via `UI/Formatting.swift` (`displayName`, `transitionReason`).
  `AuditCategory` has no `label`; the exporter writes its `rawValue`.
- **The audit trail persists no prose.** An `AuditEvent` is a stable code (`fix.rejected`) plus
  `arguments` holding what its sentence needs, formatted locale-independently
  (`["poorAccuracy", "88.0"]`). Adding an audit event means adding a case to
  `Formatting.auditSummary` — `AuditSummaryTests` fails on a code with no sentence. Never
  reconstruct an English phrase to parse it back.
- **Keys are dotted names, never the English sentence** (`status.lastFix.title`,
  `auth.location.always`) — a sentence-as-key turns every rewording into a nine-language key diff.
- **Never reuse a key across two subjects** — e.g. French agrees adjectives with the subject, so
  `Denied` can't be shared by the location and motion rows (`auth.location.*` / `auth.motion.*`,
  `precise.on` / `precise.off`), and a noun/verb pair spelled alike in English needs separate keys
  too (`common.export` the screen vs `audit.export.action` the button). Slavic languages make this
  sharper, not milder.
- Give every `%lld` key plural variations in **every** locale, English included — without an `en`
  unit the singular falls back to the key and prints "1 days". Categories are the language's, not
  English's: `other` alone in Japanese, `one`/`few`/`many`/`other` in Polish and Czech.
- Anything naming an iOS control the user is told to tap ("Always", "Precise Location",
  "Motion & Fitness", "Settings") must match what iOS displays word for word.
- Short keys (`phase.*`, `activity.*`, `common.*`, `auth.*`, tab titles, `LabeledContent` labels)
  share a line with a value — German, Polish and Czech truncate long before French, so keep them
  near English length rather than translating literally.
- Coordinates go through `Formatting.coordinate` (pins `en_US_POSIX`, so the decimal separator
  never collides with the field separator).
- Distances, speeds, altitudes and accuracies follow `TrackingSettings.unitSystem`, not the locale:
  `Formatting` holds the choice in a static the UI pushes to (`RootView` at launch and on change,
  the Settings picker's binding setter). Samples stay in meters and m/s everywhere else.

`xcodebuild` compiles the catalogs but never writes new keys back, so a new key enters through the
code: `xcstringstool` discovers call sites and writes only into `Localizable.xcstrings`. Run
`./scripts/xcb.sh strings`, then `./scripts/i18n.py export` to pull new keys into
`i18n/translations.json`, fill in the `en` unit of each (never the English text) and the eight
others, then `./scripts/i18n.py import` to write the catalog back. `extractionState: stale` entries
are dead keys — delete them; `import` is authoritative for the key set, so a key dropped from the
JSON disappears from the catalog (retires a stale key, but also destroys a live one by mistake).
Check the result in the simulator:

```bash
xcrun simctl launch "$(source scripts/sim-config.sh && sim_udid)" \
  io.github.glandais.whereiwas -AppleLanguages "(de)" -AppleLocale de_DE
```

`xcb.sh strings` exists because `xcstringstool sync` has two ways of quietly destroying the
catalog, both handled by it:

- **Syncing the catalog under its own name/path.** A copy resolves no source, so **every** key
  comes back `stale` and deleting stale keys then empties the catalog — a
  `Localizable-copy.xcstrings` next to the original is enough to trigger it.
- **Passing every `.stringsdata` file**, not just the first one `find … | head -1` returns. A key
  defined only in files that slice missed looks like it left the code, gets marked `stale`, and the
  next cleanup deletes a live string.

`extractionState: extracted_with_value` marks a key whose name isn't the English text — annotation
only, `localizations` untouched. **Don't hand-normalise these states**: the sync writes one on a
key it adds and restores it if deleted, and strips it from keys that already had one, so old keys
with no state next to freshly-synced keys with one is the stable shape, not an inconsistency.

To audit the catalog without trusting the tool, diff keys directly: the `.stringsdata` files are
plain JSON with a `tables.Localizable[].key` array, and their union must equal the key set in
`Localizable.xcstrings`.

## Release

App Store Connect app ID **`6808349924`** — App Store name `WhereIWas: Location Timeline` in
English, localized per market in `metadata/app-info/` (bare `WhereIWas` is reserved by another
developer; home-screen name stays `WhereIWas` via `CFBundleDisplayName`), bundle
`io.github.glandais.whereiwas`, primary locale `en-US`, also `fr-FR`, `de-DE`, `es-ES`, `es-MX`,
`it`, `ja`, `nl-NL`, `pl` and `cs`.

**The listing targets the general public** — location timeline, travel log, trip history — not
first responders, since September 2026. Name, subtitle and keywords are one indexed pool: never
repeat a word across them, keep keywords comma-separated with no spaces and near 100 characters,
and don't name another company's product (guideline 2.3.7).

Adding a locale takes **two** `apply` runs: creating an `app-info` localization makes App Store
Connect auto-create the matching version localization, so the version half of the same plan comes
back `Entity with locale: X already exists. Try updating.` on the first run. Re-plan and apply
again — the second pass updates them. Failures on a new locale's first run are expected.

Canonical metadata lives under `./metadata/`, one file per scope and locale
(`app-info/<locale>.json`, `version/<version>/<locale>.json`), generated from
`i18n/translations.json` like the catalogs: run `scripts/i18n.py import` before `asc` reads a
wording change, and `scripts/i18n.py export` after any `asc metadata pull` (writes those files
straight from the store) or the next `import` reverts the pull. `asc metadata` does **not** cover
App Review notes — those live in `metadata/review-notes.md`, pushed with `asc review
details-update`; keep it true to the code, a reviewer reads it with the app open. Never `apply`
without reading the plan first:

```bash
asc metadata pull     --app 6808349924 --version "1.0.0" --dir "./metadata"
asc metadata validate --dir "./metadata"
asc metadata plan     --app 6808349924 --version "1.0.0" --dir "./metadata"
asc metadata approve  --review-dir ".asc/metadata/review" --all
asc metadata apply    --app 6808349924 --version "1.0.0" --dir "./metadata" \
                      --review-dir ".asc/metadata/review" --confirm
```

Screenshots take three steps — `./scripts/screenshots.sh` captures the raw screens, `kou generate`
(the external Koubou CLI) frames them, `./screenshots/assemble.sh` collects and validates the
1242×2688 cards under `screenshots/IPHONE_65/` (see `screenshots/README.md`). Archive and export
with `ExportOptions.plist` (`app-store-connect`, team `7Q49262697`). `.asc/` holds local `asc`
state and is gitignored.

`WhereIWas/Resources/PrivacyInfo.xcprivacy` declares no tracking, no collected data, and the one
required-reason API touched (`UserDefaults`, `CA92.1`) — without it Apple returns ITMS-91053 on
every upload. Re-check when a dependency is added (none today) or a new required-reason API is
used. `metadata/app-privacy.md` covers the nutrition labels.

The website under `docs/` is **English only, deliberately** — app and store listing ship in nine
languages, the three site pages don't. Revisit if a non-English market justifies translating a
privacy policy.

### First submission

Version 1.0.0 with build 21 was submitted for review on 2026-09-18 and **rejected on 2026-09-22
under guideline 5.1.1(iv)**: the custom message before the location and Motion & Fitness prompts
ended in a "Grant permissions" button (Apple wants "Continue" / "Next"). Build 23 answers it with a
strict 5.1.1 pass — a neutral "Setup" section whose cards each trigger only their own prompt and
end in "Continue", no badge for a permission never asked for, a privacy policy link in Settings →
About (5.1.1(i) wants it *inside* the app, not only in the listing) — and was resubmitted the same
day (`WAITING_FOR_REVIEW`). Keep new permission copy descriptive, never "Grant"/"Allow", in all
nine languages. App Store Regulations and Permits were checked by hand (asc reports NOT_CHECKED,
website-only).

Done before it: icon, privacy manifest, all ten locales of `metadata/` applied, the three
metadata URLs resolving (GitHub Pages under `docs/`), App Privacy published as Data Not Collected,
age rating, categories, content rights, availability, free price schedule, review details with the
guideline 2.5.4 background-location rationale. Mac Apple Silicon / Vision Pro distribution stay
unchecked — CoreMotion, background location, significant changes and visits do nothing there.

### Held back for 1.0.1

The Ko-fi tip link (`https://ko-fi.com/gabylandais`) is live on the site but **not in the app**:
the Settings → About row (`settings.about.tip`) was committed as `423d181` and reverted by
`fa2657f` for the resubmission — `git show 423d181 | git apply` brings it back (it conflicts
trivially with the Privacy Policy row next to it). Kept out of 1.0.0 because a donation link to the developer can be rejected under guideline 3.1.1 (Apple wants
tips as in-app purchases; Apple Pay is for physical goods and approved nonprofits). **Bring it up
at the next release request.** Before shipping it: re-read 3.1.1 / 3.1.3, check whether the
Settings store card shows the About section (recapture if so), and mention the link in
`metadata/review-notes.md`. If Apple refuses, drop the row and the key, or move to a StoreKit tip.

### Gotchas worth remembering

- **Resubmitting after a rejection** reuses the open review submission (`UNRESOLVED_ISSUES`), like
  the website's Resubmit button: `asc versions attach-build`, then mark the rejected item resolved
  (`asc review items update --id <item> --resolved true`), then `asc review submissions-submit`.
  Skipping the middle step fails with "Version is not ready to be submitted yet". Read the
  rejection with `asc web review show` (needs a web session, 2FA); the e-mail carries no reason.
  Reply in the Resolution Center **before** resubmitting: sent right after the resubmission,
  `asc web review reply` got a 409 `STATE_ERROR` and left an unsent draft (cause unconfirmed —
  most likely the thread closing once the submission is `WAITING_FOR_REVIEW`).

- **`privacy.publish_state.unverified` is reported on every run** — noise, the public API can't
  read the publish state. Confirmed published two ways: `asc web privacy pull` returns
  `published: true`, and the ASC page's Publish button is gone.
- **`asc validate` misses things** — it gave a clean bill with no price schedule at all, which
  blocks submission as hard as a missing build. Check Pricing and Availability in the browser
  before trusting a green report — also where Mac Apple Silicon / Vision Pro distribution default
  to silently opted in.
- **Mainland China is deliberately excluded** — Apple requires an ICP filing (备案) from the MIIT,
  needing a Chinese entity or local hosting partner. 174 territories, `availableInNewTerritories`
  true — re-check if Apple restructures territories.

## Known constraints

- Background tracking requires **Always** location authorization. With When-In-Use the held
  `CLBackgroundActivitySession` keeps recording while the process lives, but a background
  termination or a reboot ends it for good: relaunch by significant change / visits needs Always.
- Nothing is recorded between a reboot and the first device unlock — no API changes that.
- A user force-quit stops all background delivery until the app is opened again. Expected iOS
  behaviour, surfaced in the Status screen.
- `BGProcessingTask` (purge) may never run under Low Power Mode or with Background App Refresh off;
  purge also runs at launch and from Settings.
- Motion permission denied degrades the strategy to GPS + significant change: tracking still works,
  battery suffers.
- The blue location indicator is **expected for as long as tracking is on**, STATIONARY included:
  the `CLBackgroundActivitySession` is held from `rearmAfterLaunch()` to `stopAll()` and always
  shows it, and `showsBackgroundLocationIndicator` is forced true — hiding it is a documented way
  for iOS to suspend the app. No setting for it: the `showsLocationIndicator` toggle was removed.
  `Formatting` still translates the old `indicator.shown`/`hidden`/`forced` codes for trails written
  before the removal (seven-day retention window).
- The audit trail is opt-in and off by default; it turns over much faster than the samples and has
  its own retention (`auditRetentionDays`, 7 days).
- Simulator: no background relaunch, no CoreMotion activity, no visits.
