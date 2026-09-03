# WhereIWas

## Project overview

iOS 17+ app (SwiftUI, SwiftData, Swift 6 strict concurrency) that records the best possible
GPS history of a first responder over multi-day deployments: **reliably** (survives
termination, reboot and going offline), **accurately** (filtered samples carrying full
metadata) and **without draining the battery** (GPS only runs while the device is actually
moving). Single app target plus a Swift Testing target.

## Architecture

`ARCHITECTURE.md` is the reference and stays authoritative — module map, the pure
motion-detection state machine, the GPS profile table, the sample filter, the SwiftData
schema, the background/relaunch contract and the file-ownership rules for parallel agents
all live there. Read it before touching `Domain/`, `Coordinator/` or `Location/`.

Short version:

```
App/          WhereIWasApp (@main), AppDelegate (launch re-arming), AppEnvironment (composition root)
Domain/       pure Swift, no CoreLocation/CoreMotion/SwiftData imports — state machine, filter, profiles
Persistence/  @Model types, LocationStore (@ModelActor), GPX/JSON/audit exporters
Location/     LocationEngine (@MainActor, owns CLLocationManager)
Motion/       MotionMonitor (@MainActor, CMMotionActivityManager + CMPedometer)
Coordinator/  TrackingCoordinator (@MainActor @Observable) — runs the state machine, executes effects
UI/           RootView, StatusView, MapView, SettingsView, ExportView, AuditLogView
```

Every module boundary is a protocol in `Domain/Interfaces.swift` plus `Sendable` value
types. SwiftData `@Model` classes never leave `Persistence/`.

## Build

Open `WhereIWas.xcodeproj` in Xcode and build the `WhereIWas` scheme (it also runs
`WhereIWasTests`). Signing is automatic against team `7Q49262697`. Background behaviour
(relaunch after termination, reboot, visits, CoreMotion activity) **cannot** be tested in
the simulator — see `ARCHITECTURE.md` §7 for the device test plan.

```bash
xcodebuild -project WhereIWas.xcodeproj -scheme WhereIWas \
  -destination 'generic/platform=iOS Simulator' build
```

### Screenshot configuration

Besides `Debug` and `Release`, `project.yml` declares a **`Screenshots`**
configuration (a Debug clone plus the `SCREENSHOTS` compilation condition) and
a `WhereIWas-Screenshots` scheme. Everything the App Store capture mode needs —
`App/ScreenshotMode.swift`, `App/DemoTrackingController.swift` and a handful of
short `#if SCREENSHOTS` blocks in `AppDelegate`, `WhereIWasApp`, `SettingsView`,
`MapView` and `ExportView` — is compiled only there, so none of it reaches the
archived binary. Verify with:

```bash
xcodebuild -project WhereIWas.xcodeproj -target WhereIWas -configuration Release \
  -showBuildSettings | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS   # must be empty
```

`./scripts/screenshots.sh` drives it — see `screenshots/README.md`.

### Project generation (XcodeGen)

`WhereIWas.xcodeproj` is **generated** from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — treat `project.yml` as the source of
truth, not the `.pbxproj`, which is gitignored. After adding, removing or moving files, or
changing build settings, regenerate with:

```bash
xcodegen generate      # reads project.yml, rewrites WhereIWas.xcodeproj
```

Notes:
- The `WhereIWas` target sources the whole `WhereIWas/` folder, so **new files are picked
  up automatically** on regenerate — no manual project edits. `.DS_Store` is excluded.
- `WhereIWasTests` is a hosted unit-test target (`TEST_HOST` on the app), so it sees the
  whole app module.
- `WhereIWas/Info.plist` exists on disk but is **generated** by XcodeGen from the
  `info.properties` block in `project.yml` and is overwritten on every `xcodegen generate`
  — never edit it by hand, edit `project.yml`. The background modes, the three usage
  descriptions and `BGTaskSchedulerPermittedIdentifiers` all live in that block. Keep the
  BGTask identifier in `project.yml` and `MaintenanceScheduler.taskIdentifier` in sync, or
  the task never runs.
- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are set in `project.yml` and are the
  single place to bump a version. `info.properties` maps `CFBundleShortVersionString` and
  `CFBundleVersion` onto them with `$(...)`; without those two entries XcodeGen writes its
  own defaults (`1.0` / `1`) and the build number silently ignores `project.yml`.

## Localization

The app ships in **English (source) and French**. Two string catalogs under
`WhereIWas/Resources/` hold everything user-facing:

- `Localizable.xcstrings` — the UI strings
- `InfoPlist.xcstrings` — the three permission prompts. Their English text
  lives in **two** places and must be edited in both: `project.yml` (which
  writes the required keys into the generated `Info.plist`) and the `en` unit
  of the catalog. iOS resolves `en.lproj/InfoPlist.strings` first, so the
  catalog is what an English user actually reads and `project.yml` alone has
  no effect on the prompt; dropping the `en` unit is not the fix either —
  `xcstringstool` then emits the key itself as the value and the prompt reads
  "NSMotionUsageDescription".

`knownRegions` in `project.yml` lists the locales. Rules when adding UI strings:

- `Text("…")`, `Label("…")`, `Section("…")` literals are localized automatically.
- A `String` variable passed to `Text`/`Label` is **not** — build it with
  `String(localized:)` at the source, or use `Text(verbatim:)` when the value is
  data (coordinates, an error, an audit payload) that must not be translated.
- Technical identifiers stay English on purpose: `GPSProfile.label` and
  `AuditSeverity.label` are persisted in samples, written to the exports and
  asserted on in tests. The UI shows the localized `displayName` counterparts
  defined in `UI/Formatting.swift`. `AuditCategory` has no `label` — the
  exporter writes its `rawValue` and the UI uses `displayName`.
- `StateTransitionRecord.reason` is persisted machine text, so it stays English
  on disk; the Status screen runs it through `Formatting.transitionReason`,
  which translates the known vocabulary and passes anything else through.
- Do **not** reuse a key across two subjects. French agrees adjectives with the
  subject, so `Denied` shared by the location and motion rows cannot be right
  in both — hence the `auth.location.*` / `auth.motion.*` and `precise.on` /
  `precise.off` splits. Same for a noun and a verb that happen to spell the
  same in English (`Export` the screen vs `audit.export.action` the button).
- Give every `%lld` key plural variations in **both** locales, English included
  — without an `en` unit the singular falls back to the key and prints
  "1 days".
- Coordinates go through `Formatting.coordinate`, which pins `en_US_POSIX` so
  the decimal separator never collides with the field separator.

`xcodebuild` compiles the catalogs but never writes new keys back into them.
After adding strings, extract them by hand:

```bash
xcodebuild -project WhereIWas.xcodeproj -scheme WhereIWas \
  -destination 'generic/platform=iOS Simulator' build
DD=$(find ~/Library/Developer/Xcode/DerivedData/WhereIWas-*/Build/Intermediates.noindex/\
WhereIWas.build/Debug-iphonesimulator/WhereIWas.build/Objects-normal -name '*.stringsdata' | head -1 | xargs dirname)
xcrun xcstringstool sync WhereIWas/Resources/Localizable.xcstrings --stringsdata $DD/*.stringsdata
```

then fill the `fr` unit of every new key (and the `en` unit too, for keys
whose name is not the English text, such as `auth.*` and `reason.*`) (`extractionState: stale` entries are
dead keys — delete them). Check the result in the simulator with
`xcrun simctl launch booted io.github.glandais.whereiwas -AppleLanguages "(fr)" -AppleLocale fr_FR`.

Two traps in that `sync`:

- **Run it on the catalog in place**, never on a copy outside the repo. Given a
  copy, `xcstringstool` resolves no source and marks **every** key `stale` —
  following the "stale means dead, delete it" rule then empties the catalog.
- `head -1` picks one architecture slice. That is enough to find new keys, but
  keys defined only in files the other slice compiled lose their
  `extractionState`, which shows up as a large no-op diff. Pass every slice
  (`$DD/../*/*.stringsdata`) to avoid the churn.

To audit the catalog without trusting the tool, diff the keys directly — the
`.stringsdata` files are plain JSON with a `tables.Localizable[].key` array, so
their union must equal the set of keys in `Localizable.xcstrings`: anything
extra in the code is an unextracted string, anything extra in the catalog is a
dead key.

## Release

App Store Connect app ID **`6808349924`** — App Store name `WhereIWas GPS Logger`
(the bare `WhereIWas` is reserved by another developer; the home-screen name stays
`WhereIWas` via `CFBundleDisplayName`), bundle `io.github.glandais.whereiwas`, primary
locale `en-US`, also localized in `fr-FR`.

Canonical metadata lives under `./metadata/`, one file per scope and locale:

```
metadata/app-info/<locale>.json          name, subtitle, privacyPolicyUrl
metadata/version/<version>/<locale>.json description, keywords, promotionalText,
                                         marketingUrl, supportUrl, whatsNew
```

Use the `asc` CLI. The plan/approve/apply cycle is deliberate — never `apply` without
reading the plan first:

```bash
asc metadata pull     --app 6808349924 --version "1.0.0" --dir "./metadata"
asc metadata validate --dir "./metadata"
asc metadata plan     --app 6808349924 --version "1.0.0" --dir "./metadata"
asc metadata approve  --review-dir ".asc/metadata/review" --all
asc metadata apply    --app 6808349924 --version "1.0.0" --dir "./metadata" \
                      --review-dir ".asc/metadata/review" --confirm
```

Screenshots live under `./screenshots/<DISPLAY_TYPE>/<locale>/` and are
**generated**: `./scripts/screenshots.sh` builds the `Screenshots`
configuration and captures all five screens in `en-US` and `fr-FR` from mocked
data, no device and no manual navigation. Run it during the day (the demo track
spans 92 minutes ending "now"; just after midnight it gets compressed). Edit
`WhereIWas/App/DemoTrackingController.swift` to change what the shots show. See
`screenshots/README.md` for the workflow and `screenshots/STATUS.md` for the
current state. Uploading stays manual. The app is iPhone-only (`TARGETED_DEVICE_FAMILY` is `"1"`), so
`IPHONE_65` is the only required display type.

Archive and export for the App Store with `ExportOptions.plist`
(`app-store-connect`, team `7Q49262697`).

`.asc/` holds local `asc` state (review plans, failure reports) and is gitignored.

### Privacy manifest

`WhereIWas/Resources/PrivacyInfo.xcprivacy` declares no tracking, no collected data,
and the one required-reason API the app touches: `UserDefaults` (`CA92.1`, app's own
data). Without it Apple returns ITMS-91053 on every upload. Re-check it whenever a
dependency is added — there are none today — or when a new required-reason API is
used. `fileSizeKey` in `ExportView` is not one of them.

### Still to do before a first submission

- **Attach a build.** The only blocking check left: archive, upload to TestFlight and
  select the build on version 1.0.0. `asc validate` reports 1 error, 1 warning, 1 info.
- Re-upload the screenshots: all ten (five screens × `en-US`/`fr-FR`) are now
  generated locally and no longer match what the store serves. ASC does not
  inherit screenshots from the primary locale, so `fr-FR` needs its own upload.
- App Store Regulations and Permits: checked by hand (asc reports it NOT_CHECKED, it is
  website-only). Vietnam gaming licence and regulated medical devices do not apply.
  Encryption is already declared through `ITSAppUsesNonExemptEncryption: false`. DSA
  status is "non-trader", which is right for a free app with no monetisation — revisit
  it if the app is ever monetised.

Done: app icon; privacy manifest; both locales of `metadata/` applied and verified
against ASC; the three `metadata/` URLs now resolve (GitHub Pages under `docs/`);
five IPHONE_65 screenshots uploaded (COMPLETE); App Privacy published as
Data Not Collected; age rating (all NONE/false); categories NAVIGATION / UTILITIES;
content rights DOES_NOT_USE_THIRD_PARTY_CONTENT; availability on 175 territories with
availableInNewTerritories; mainland China removed for want of an ICP filing (174
territories); price set to free (isFree, base territory USA); Mac Apple
Silicon and Vision Pro distribution unchecked, since CoreMotion, background location,
significant changes and visits do nothing on those platforms; App Store review details
with the guideline 2.5.4 background-location rationale.

### One check that stays noisy

`privacy.publish_state.unverified` is reported on every run: the public API cannot read
the publish state. Confirmed published two ways — `asc web privacy pull` returns
`published: true`, and the ASC page shows "Published … by Gabriel Landais" with the
Publish button gone. Ignore it.

### Mainland China

CHN is deliberately excluded. Apple requires an ICP filing (备案) from the Chinese MIIT
for any app distributed in mainland China, which needs a Chinese business entity or a
local hosting partner. Without it the app cannot ship there, so asking App Review to
approve that distribution only risks a round trip. Note that `availableInNewTerritories`
is true, so re-check this if Apple ever restructures territories.

### What asc validate does not check

It reported a clean bill while the app had **no price schedule at all**, which blocks
submission just as hard as a missing build. Open Pricing and Availability in the browser
before believing a green report. The same page is where Mac Apple Silicon and Vision Pro
distribution are silently opted in by default.

## Known constraints

- Background tracking requires **Always** location authorization; When-In-Use stops
  recording as soon as the app is suspended.
- Nothing is recorded between a reboot and the first device unlock — no API changes that.
- A user force-quit (swipe up in the app switcher) stops all background delivery until the
  app is opened again. Expected iOS behaviour, surfaced in the Status screen.
- `BGProcessingTask` (purge) may never run under Low Power Mode or with Background App
  Refresh off; purge also runs at launch and from Settings.
- Motion permission denied degrades the strategy to GPS + significant change: tracking
  still works, battery suffers.
- The audit trail is opt-in and off by default; it turns over much faster than the samples
  and has its own retention (`auditRetentionDays`, 7 days).
- Simulator: no background relaunch, no CoreMotion activity, no visits.
