# WhereIWas

iOS 17+ app (SwiftUI, SwiftData, Swift 6 strict concurrency) that records the GPS history of a
first responder over multi-day deployments: **reliably** (survives termination, reboot and going
offline), **accurately** (filtered samples carrying full metadata) and **without draining the
battery** (GPS only runs while the device is actually moving). Single app target plus a Swift
Testing target.

## Architecture

`ARCHITECTURE.md` is authoritative and describes the module map, the pure motion-detection state
machine, the GPS profile table, the sample filter, the SwiftData schema and the background /
relaunch contract. Read it before touching `Domain/`, `Coordinator/` or `Location/`.

The invariant it exists to protect: `Domain/` is pure Swift (no CoreLocation, CoreMotion or
SwiftData import), every module boundary is a protocol in `Domain/Interfaces.swift` plus
`Sendable` value types, and SwiftData `@Model` classes never leave `Persistence/`.

## Build

```bash
./scripts/xcb.sh build              # WhereIWas scheme, Debug
./scripts/xcb.sh test               # + WhereIWasTests
./scripts/xcb.sh strings            # build, then sync the string catalog
./scripts/xcb.sh -- <args...>       # raw xcodebuild, destination still pinned
```

`WHEREIWAS_SCHEME` picks another scheme of the same project — in practice
`WhereIWas-Screenshots`, the only way to compile the `#if SCREENSHOTS` code.

Signing is automatic against team `7Q49262697`. Background behaviour (relaunch after termination,
reboot, visits, CoreMotion activity) cannot be tested in the simulator — see `ARCHITECTURE.md` §7
for the device test plan.

### Simulator

`./scripts/xcb.sh` is the only way to run `xcodebuild` against a simulator. It pins
`-destination` (by UDID) to the single device the project uses and `-derivedDataPath` to
`.build/DerivedData`. Never write a `-destination` by hand, and never use
`generic/platform=iOS Simulator`: it builds without booting anything, so the next command that
*does* need a device picks one on its own. `scripts/guard-simulator.py` (a `PreToolUse` hook from
`.claude/settings.json`) refuses any Bash command that would drive another simulator.

The device is `iPhone 17 Pro Max`, declared once in `scripts/sim-config.sh`. It is not an
arbitrary pick: nothing resizes a capture any more — `scripts/screenshots.sh` only checks its
shape and flattens alpha — so the device has to be the one Koubou frames.
`screenshots/koubou/config.yaml` pins the "iPhone 17 Pro Max" frame, and the cards it renders are
the 1242×2688 IPHONE_65 assets App Store Connect wants. Any other device would mean keeping a
second simulator around.

**Never run `./scripts/xcb.sh test` while a capture run is in flight.** The test host is the Debug
app under the same bundle id, so installing it replaces the Screenshots build mid-run and the
captures come back identical — which is exactly what the guard added in `e29a6e0` now refuses.

`WHEREIWAS_SIM_DEVICE` overrides the device and `WHEREIWAS_DERIVED_DATA` the build directory. The
hook reads `sim-config.sh` from its own process, so it only sees the variable when it is exported
in the session environment — not when it is prefixed onto a single command.

### Screenshot configuration

`project.yml` declares a **`Screenshots`** configuration (a Debug clone plus the `SCREENSHOTS`
compilation condition) and a `WhereIWas-Screenshots` scheme. Everything the App Store capture mode
needs — `App/ScreenshotMode.swift`, `App/DemoTrackingController.swift` and a few `#if SCREENSHOTS`
blocks in the app and UI — is compiled only there, so none of it reaches the archived binary.
Verify with:

```bash
xcodebuild -project WhereIWas.xcodeproj -target WhereIWas -configuration Release \
  -showBuildSettings | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS   # must be empty
```

`./scripts/screenshots.sh` drives it — see `screenshots/README.md`.

### Project generation (XcodeGen)

`WhereIWas.xcodeproj` is **generated** from `project.yml` and gitignored — `project.yml` is the
source of truth. After adding, removing or moving files, or changing build settings, run
`xcodegen generate`. The `WhereIWas` target sources the whole `WhereIWas/` folder, so new files
are picked up automatically.

Three things that bite:

- `WhereIWas/Info.plist` exists on disk but is generated from the `info.properties` block and
  overwritten on every `xcodegen generate` — never edit it by hand.
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` are the single place to bump a
  version, but only because `info.properties` maps `CFBundleShortVersionString` and
  `CFBundleVersion` onto them with `$(...)`. Without those two entries XcodeGen writes its own
  defaults (`1.0` / `1`) and the build number silently ignores `project.yml`.
- Keep the BGTask identifier in `project.yml` and `MaintenanceScheduler.taskIdentifier` in sync,
  or the task never runs.

## Localization

The app ships in **nine languages** — English (source), French, German, Spanish, Italian, Japanese,
Dutch, Polish and Czech — through two string catalogs under `WhereIWas/Resources/`:
`Localizable.xcstrings` (UI) and `InfoPlist.xcstrings` (the three permission prompts).
`knownRegions` in `project.yml` lists them.

Those are **short language codes** (`de`, `es`, `nl`), not region ones: `de` covers de-AT and de-CH,
`es` covers es-MX and es-419, and none of these markets needs a variant of its own. App Store
Connect is a separate namespace with its own codes for the same languages — `de-DE`, `es-ES`,
`nl-NL`, and `it` / `ja` / `pl` / `cs` bare — and those are what `metadata/` and the screenshot
directories are named after.

The permission prompts' English text lives in **two** places and must be edited in both:
`project.yml` (which writes the keys into the generated `Info.plist`) and the `en` unit of the
catalog. iOS resolves `en.lproj/InfoPlist.strings` first, so the catalog is what an English user
reads. Dropping the `en` unit is not the fix either — `xcstringstool` then emits the key itself as
the value and the prompt reads "NSMotionUsageDescription".

Rules when adding UI strings:

- `Text("…")`, `Label("…")`, `Section("…")` literals are localized automatically. A `String`
  variable passed to `Text`/`Label` is **not** — build it with `String(localized:)` at the source,
  or use `Text(verbatim:)` when the value is data (coordinates, an error, an audit payload).
- Technical identifiers stay English on purpose: `GPSProfile.label` and `AuditSeverity.label` are
  persisted in samples, written to the exports and asserted on in tests. The UI shows the localized
  `displayName` counterparts in `UI/Formatting.swift`. `AuditCategory` has no `label` — the
  exporter writes its `rawValue`.
- `StateTransitionRecord.reason` is persisted machine text and stays English on disk; the Status
  screen runs it through `Formatting.transitionReason`, which translates the known vocabulary and
  passes anything else through.
- **The audit trail persists no prose at all.** An `AuditEvent` is a stable code (`fix.rejected`)
  plus `arguments` holding what its sentence needs, formatted locale-independently
  (`["poorAccuracy", "88.0"]`); the store and both exports write exactly that. Adding an audit
  event therefore means adding a case to `Formatting.auditSummary` — `AuditSummaryTests` fails on a
  code with no sentence. Never reconstruct an English phrase to parse it back.
- **Keys are dotted names, never the English sentence** (`status.lastFix.title`, `auth.location.always`).
  English lives in the `en` unit of the catalog like any other language. A sentence used as a key
  turns every rewording into a diff of the key set across nine languages.
- Do **not** reuse a key across two subjects. French agrees adjectives with the subject, so
  `Denied` shared by the location and motion rows cannot be right in both — hence the
  `auth.location.*` / `auth.motion.*` and `precise.on` / `precise.off` splits. Same for a noun and
  a verb that spell the same in English (`common.export` the screen vs `audit.export.action` the
  button). Slavic languages make this sharper still, not milder.
- Give every `%lld` key plural variations in **every** locale, English included — without an `en`
  unit the singular falls back to the key and prints "1 days". The categories are the language's,
  not English's: `other` alone in Japanese, `one`/`few`/`many`/`other` in Polish and Czech.
- Anything naming an iOS control the user is told to go tap ("Always", "Precise Location",
  "Motion & Fitness", "Settings") must match what iOS itself displays in that language, word for
  word. A close synonym turns an instruction into a wrong one.
- Short keys (`phase.*`, `activity.*`, `common.*`, `auth.*`, tab titles, `LabeledContent` labels)
  share a line with a value. German, Polish and Czech truncate there long before French does; keep
  them near the English length rather than translating literally.
- Coordinates go through `Formatting.coordinate`, which pins `en_US_POSIX` so the decimal
  separator never collides with the field separator.
- Distances, speeds, altitudes and accuracies follow `TrackingSettings.unitSystem`, not the locale:
  `Formatting` holds the choice in a static the UI pushes to (`RootView` at launch and on change,
  the Settings picker in its binding setter). Samples stay in meters and m/s everywhere else.

`xcodebuild` compiles the catalogs but never writes new keys back. After adding strings, run
`./scripts/xcb.sh strings`, then fill the `en` unit of every new key (the key is never the English
text) and the eight other units. `extractionState: stale` entries are dead keys — delete them.
Check the result in the simulator:

```bash
xcrun simctl launch "$(source scripts/sim-config.sh && sim_udid)" \
  io.github.glandais.whereiwas -AppleLanguages "(de)" -AppleLocale de_DE
```

`xcb.sh strings` exists because `xcstringstool sync` has two ways of quietly destroying the
catalog, both of which it handles:

- **It syncs the catalog under its own name and path.** `xcstringstool` matches the file to the
  extracted table by name, so a copy resolves no source and **every** key comes back `stale` —
  following "stale means dead, delete it" then empties the catalog. A
  `Localizable-copy.xcstrings` next to the original is enough to trigger it.
- **It passes every `.stringsdata` file**, not the first one a `find … | head -1` returns. A key
  defined only in files that slice did not compile looks like it has left the code, so the sync
  marks it `stale` and the next cleanup deletes a live string.

`extractionState: extracted_with_value` marks a key whose name is not the English text. It is
annotation only — the `localizations` are untouched and the app is unaffected — so the rule is
simply to keep the catalog in the shape `xcstringstool` itself emits and let the sync be
idempotent, which it is: a second run changes nothing.

Do not try to normalise those states by hand, in either direction. The sync writes one on a key
*it* adds, and puts it straight back if you delete it; it strips them from keys that already had
one. So a catalog where the old keys carry no state and the ones added by the last sync do is the
stable shape, not an inconsistency to clean up — two structurally identical keys (same
`String(localized:defaultValue:)`, no comment, `en` equal to the default) legitimately differ here
by nothing but their age.

To audit the catalog without trusting the tool, diff the keys directly: the `.stringsdata` files
are plain JSON with a `tables.Localizable[].key` array, so their union must equal the set of keys
in `Localizable.xcstrings`.

## Release

App Store Connect app ID **`6808349924`** — App Store name `WhereIWas GPS Logger` (the bare
`WhereIWas` is reserved by another developer; the home-screen name stays `WhereIWas` via
`CFBundleDisplayName`), bundle `io.github.glandais.whereiwas`, primary locale `en-US`, also
`fr-FR`, `de-DE`, `es-ES`, `it`, `ja`, `nl-NL`, `pl` and `cs`.

Adding a locale takes **two** `apply` runs, and the first one reports failures. Creating an
`app-info` localization makes App Store Connect create the matching version localization on its own,
so the version half of the same plan comes back `Entity with locale: X already exists. Try
updating.` Re-plan and apply again: the second pass sees them and updates. Seven failures on the
first run of a new locale are expected, not a broken plan.

Canonical metadata lives under `./metadata/`, one file per scope and locale
(`app-info/<locale>.json`, `version/<version>/<locale>.json`). `asc metadata` does **not** cover the
App Review notes, so those have their own canonical copy in `metadata/review-notes.md`, pushed with
`asc review details-update`; it has to stay true to the code, since a reviewer reads it with the app
open in front of them. Use the `asc` CLI; the
plan/approve/apply cycle is deliberate — never `apply` without reading the plan first:

```bash
asc metadata pull     --app 6808349924 --version "1.0.0" --dir "./metadata"
asc metadata validate --dir "./metadata"
asc metadata plan     --app 6808349924 --version "1.0.0" --dir "./metadata"
asc metadata approve  --review-dir ".asc/metadata/review" --all
asc metadata apply    --app 6808349924 --version "1.0.0" --dir "./metadata" \
                      --review-dir ".asc/metadata/review" --confirm
```

Screenshots take three steps — `./scripts/screenshots.sh` captures the raw screens,
`kou generate` (the external Koubou CLI) frames them, and `./screenshots/assemble.sh` collects and
validates the 1242×2688 cards under `screenshots/IPHONE_65/`. See `screenshots/README.md`. Archive and
export with `ExportOptions.plist` (`app-store-connect`, team `7Q49262697`). `.asc/` holds local
`asc` state and is gitignored.

`WhereIWas/Resources/PrivacyInfo.xcprivacy` declares no tracking, no collected data, and the one
required-reason API the app touches (`UserDefaults`, `CA92.1`). Without it Apple returns
ITMS-91053 on every upload. Re-check it whenever a dependency is added — there are none today — or
when a new required-reason API is used. `metadata/app-privacy.md` covers the nutrition labels.

The website under `docs/` is **English only, deliberately**: the app and the store listing ship in
nine languages, the three site pages do not. Revisit if a non-English market ever justifies
translating a privacy policy.

### Still to do before a first submission

- **Attach a build.** The only blocking check left: archive, upload to TestFlight and select the
  build on version 1.0.0.
- App Store Regulations and Permits: checked by hand (asc reports NOT_CHECKED, it is website-only).

Everything else is done: icon, privacy manifest, all nine locales of `metadata/` applied, the three
metadata URLs resolving (GitHub Pages under `docs/`), App Privacy published as Data Not Collected,
age rating, categories, content rights, availability, free price schedule, review details with the
guideline 2.5.4 background-location rationale. Mac Apple Silicon and Vision Pro distribution are
unchecked, since CoreMotion, background location, significant changes and visits do nothing there.

### Gotchas worth remembering

- **`privacy.publish_state.unverified` is reported on every run** and is noise: the public API
  cannot read the publish state. Confirmed published two ways — `asc web privacy pull` returns
  `published: true`, and the ASC page shows the Publish button gone.
- **`asc validate` misses things.** It reported a clean bill while the app had no price schedule at
  all, which blocks submission just as hard as a missing build. Open Pricing and Availability in
  the browser before believing a green report — that is also where Mac Apple Silicon and Vision Pro
  distribution are silently opted in by default.
- **Mainland China is deliberately excluded.** Apple requires an ICP filing (备案) from the MIIT,
  which needs a Chinese business entity or a local hosting partner. 174 territories, with
  `availableInNewTerritories` true — so re-check this if Apple ever restructures territories.

## Known constraints

- Background tracking requires **Always** location authorization; When-In-Use stops recording as
  soon as the app is suspended.
- Nothing is recorded between a reboot and the first device unlock — no API changes that.
- A user force-quit stops all background delivery until the app is opened again. Expected iOS
  behaviour, surfaced in the Status screen.
- `BGProcessingTask` (purge) may never run under Low Power Mode or with Background App Refresh off;
  purge also runs at launch and from Settings.
- Motion permission denied degrades the strategy to GPS + significant change: tracking still works,
  battery suffers.
- The blue location indicator is **expected** while STATIONARY: `keepCoarseUpdatesWhileStationary`
  keeps `startUpdatingLocation` running, so the Status screen says "Stationary (coarse)" rather
  than "GPS off". `showsLocationIndicator` (Settings, on by default) hides it, but only in that
  case — the `CLBackgroundActivitySession` held during PROBING/MOVING always shows it.
- The audit trail is opt-in and off by default; it turns over much faster than the samples and has
  its own retention (`auditRetentionDays`, 7 days).
- Simulator: no background relaunch, no CoreMotion activity, no visits.
