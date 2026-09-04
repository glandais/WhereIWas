---
name: testflight-release
description: Cut a new TestFlight build of WhereIWas — pick the build number, archive, export, upload, write the What to Test notes from the commits since the previous build, and hand it to the Internal group. Use when asked for a new TestFlight build, a new beta, or "bump and upload".
---

# A new TestFlight build

App `6808349924`, bundle `io.github.glandais.whereiwas`, team `7Q49262697`, marketing
version `1.0.0`. One TestFlight group: **Internal** (`e757ca90-ec55-4ea3-8559-3c3b59c7a982`).
Test-note locales: **en-US** and **fr-FR** — both are filled, never just English.

The whole point of a build is the diff since the previous one. Work out that diff *first*:
it decides whether the build is worth cutting, and it is what the testers are asked to
exercise.

## 1. Find the previous build and what changed since

```bash
asc builds list --app 6808349924 --limit 5 --output table     # highest version = previous build
git log --oneline -20                                          # find "Bump to build N for TestFlight"
git log --oneline <bump-commit>..HEAD --stat
```

The bump commit touches `project.yml` alone and is the marker for "what shipped in build N".
There are no git tags in this repo — do not look for one.

Sort the commits into what a tester can actually see:

- `WhereIWas/**` outside `#if SCREENSHOTS` → in the build, tell the testers.
- `#if SCREENSHOTS` blocks, `App/ScreenshotMode.swift`, `App/DemoTracks*.swift`,
  `screenshots/**`, `scripts/**` → compiled only in the `Screenshots` configuration,
  **invisible** in the uploaded binary. Never list them in the notes.
- `metadata/**`, `docs/**`, `*.md` → store or documentation, not the build.

Check each touched file with `git show <sha> -- <file> | grep -n SCREENSHOTS`; a change in
`UI/` is not automatically shipped.

Also check whether a crash from the previous build is being fixed:

```bash
asc testflight crashes list --app 6808349924 --output table
```

If nothing shipped-visible changed, say so and stop — a build that only moves the
screenshot pipeline is not worth a tester's download.

## 2. Bump

`CURRENT_PROJECT_VERSION` in `project.yml` is the single source of truth (`info.properties`
maps `CFBundleVersion` onto it). Confirm the remote-safe number first, then edit:

```bash
asc builds next-build-number --app 6808349924 --platform IOS
# then, in project.yml:  CURRENT_PROJECT_VERSION: "<N+1>"
xcodegen generate
```

`WhereIWas.xcodeproj` is generated and gitignored, so the bump is nothing without
`xcodegen generate`. Do not use `asc xcode version edit`: it writes the generated project,
which the next `xcodegen generate` throws away.

## 3. Test, then archive

```bash
./scripts/xcb.sh test
```

Never hand-write a `-destination` for the simulator — `scripts/guard-simulator.py` blocks it.
The device archive is a different matter: it needs `generic/platform=iOS`, which boots
nothing and is allowed.

```bash
xcodebuild -project WhereIWas.xcodeproj -scheme WhereIWas -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/WhereIWas.xcarchive \
  -derivedDataPath .build/DerivedData -allowProvisioningUpdates archive
```

The scheme must be `WhereIWas`, never `WhereIWas-Screenshots`: the latter compiles the demo
controller and the `SCREENSHOTS` condition into the binary. Sanity-check the archive:

```bash
/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' \
  build/WhereIWas.xcarchive/Info.plist
```

## 4. Export and upload

```bash
xcodebuild -exportArchive -archivePath build/WhereIWas.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates

asc builds upload --app 6808349924 --ipa build/export/WhereIWas.ipa --wait
```

`ExportOptions.plist` at the repo root is the checked-in one (`app-store-connect`, team
`7Q49262697`). `build/` is gitignored, so nothing here pollutes the tree.

Processing takes a few minutes. `--wait` covers it; otherwise poll until
`processingState` is `VALID`:

```bash
asc builds list --app 6808349924 --limit 3 --output table
```

## 5. What to Test, in both locales

Write them from the shipped-visible diff of step 1, in the shape build 5 established:

> Build N — one sentence on why this build exists.
> New since build N-1: • … • …
> Worth exercising: • … • …
> Still worth exercising: • Grant Always location and Motion & Fitness • Start tracking,
> lock the phone, walk or drive • Check Map and Status afterwards • Export GPX and JSON
> Known: nothing is recorded between a reboot and the first unlock, and force-quitting stops
> background delivery until the app is reopened.

The "Still worth exercising" and "Known" blocks carry over from build to build — they are
what the app always needs tested and the two behaviours no build will fix.

```bash
asc builds test-notes create --build-id "BUILD_ID" --locale en-US --whats-new "…"
asc builds test-notes create --build-id "BUILD_ID" --locale fr-FR --whats-new "…"
```

`create` fails with an already-exists error when the locale is present; use `update` with the
same selector. Read them back with
`asc builds test-notes list --build-id "BUILD_ID" --output table`.

## 6. Distribute

Nothing to do. **Internal** is an internal group with auto-distribution: a processed build
lands in it on its own and the testers are notified (`Auto Notify: true`).
`asc builds add-groups` on it fails with *"Cannot add internal group to a build"* — that
error means the build is already there, not that something went wrong. Confirm with:

```bash
asc testflight distribution view --build-id "BUILD_ID" --output table
```

`Internal State: IN_BETA_TESTING` is the build being testable. `External State:
READY_FOR_BETA_SUBMISSION` only says no external group has asked for a beta review, which
this app does not use.

## 7. Record it

Commit the bump on its own — `project.yml` and nothing else — with the reason in the body:

```
Bump to build N for TestFlight

<why this build exists, in a sentence or two>
```

Never `git add -A`: the working tree usually holds work in progress that is not yours.

## Traps

- **`asc` prints raw JSON by default** and a build list is thousands of tokens. Always pass
  `--output table`, or pipe through `jq`.
- **A green `./scripts/xcb.sh test` proves little here.** The simulator has no pedometer, no
  CoreMotion activity, no visits and no background relaunch — the exact paths that crashed
  build 5. Device testing is what TestFlight is for.
- **`usesNonExemptEncryption`** is answered by `ITSAppUsesNonExemptEncryption` in
  `project.yml`; a build that lacks it sits in "Missing Compliance" and never reaches a tester.
- A build stays testable for 90 days; `asc builds list` shows `expirationDate`.
