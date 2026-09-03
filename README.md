# WhereIWas

An iPhone location logger built for long shifts: the GPS receiver runs only
while you actually move, the track survives termination and reboot, and every
point is exportable as GPX or JSON. Nothing leaves the device.

App Store name: **WhereIWas GPS Logger** — iOS 17+.

- Website: <https://glandais.github.io/WhereIWas/>
- Support: <https://glandais.github.io/WhereIWas/support/>
- Privacy: <https://glandais.github.io/WhereIWas/privacy/>

## Repository layout

```
WhereIWas/       app sources (App, Domain, Persistence, Location, Motion, Coordinator, UI)
WhereIWasTests/  Swift Testing suites
docs/            the website, served by GitHub Pages from main
metadata/        canonical App Store metadata (en-US, fr-FR), applied with the asc CLI
screenshots/     App Store screenshots, one folder per display type and locale
project.yml      XcodeGen project definition — the source of truth, not the .pbxproj
```

`ARCHITECTURE.md` describes the design: the pure motion-detection state machine,
the GPS profile table, the sample filter, the SwiftData schema and the
background relaunch contract. `CLAUDE.md` covers build and release workflow.

## Build

```bash
xcodegen generate
./scripts/xcb.sh test
```

`scripts/xcb.sh` wraps `xcodebuild` and pins it to the single simulator the
project uses (`scripts/sim-config.sh`), so a build never boots a device of its
own choosing. See the `Simulator` section of `CLAUDE.md`.

`WhereIWas.xcodeproj` is generated and not committed. Background behaviour
(relaunch after termination, reboot, visits, motion activity) can only be
tested on a device — see `ARCHITECTURE.md` §7.

## Licence

Not yet decided. All rights reserved for now.
