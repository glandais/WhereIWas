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

Screenshots live under `./screenshots/<DISPLAY_TYPE>/<locale>/` — see
`screenshots/README.md` for the workflow and `screenshots/STATUS.md` for which
shots are final and which are placeholders. The app is iPhone-only (`TARGETED_DEVICE_FAMILY` is `"1"`), so
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

- Two of the five screenshots are placeholders (map and status) — see
  `screenshots/STATUS.md` for what each one is waiting for
- Publish the App Privacy nutrition labels. The declaration is written and versioned
  at `metadata/app-privacy.json` (empty `dataUsages` = Data Not Collected, with the
  reasoning inline); it still has to be applied and published, which needs a web
  session: `asc web privacy plan|apply|publish --app 6808349924 --file metadata/app-privacy.json`
- Category, age rating and territory availability are unset

Done: app icon; both locales of `metadata/` applied and verified against ASC; the three `metadata/` URLs now resolve (GitHub Pages under `docs/`);
TestFlight Test Information, What to Test and the Beta App Review notes (which spell out
the background-location use case and the Always authorization flow for guideline 2.5.4).

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
