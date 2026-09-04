# WhereIWas

An iPhone location logger built for long shifts: the GPS receiver runs only
while you actually move, the track survives termination and reboot, and every
point is exportable as GPX or JSON. Nothing leaves the device.

Shipped in nine languages: English, French, German, Spanish, Italian, Japanese,
Dutch, Polish and Czech.

App Store name: **WhereIWas GPS Logger** — iOS 17+.

- Website: <https://glandais.github.io/WhereIWas/>
- Support: <https://glandais.github.io/WhereIWas/support/>
- Privacy: <https://glandais.github.io/WhereIWas/privacy/>

## Repository layout

```
WhereIWas/       app sources (App, Domain, Persistence, Location, Motion, Coordinator, UI, Resources)
WhereIWasTests/  Swift Testing suites
scripts/         build, simulator and screenshot tooling (xcb.sh is the only way in)
docs/            the website, served by GitHub Pages from main
design/          icon and site design sources
metadata/        canonical App Store metadata, nine locales, applied with the asc CLI
screenshots/     App Store screenshots and the pipeline that builds them
project.yml      XcodeGen project definition — the source of truth, not the .pbxproj
```

`ARCHITECTURE.md` describes the design; `CLAUDE.md` covers the build and release
workflow.

## Build

```bash
xcodegen generate
./scripts/xcb.sh test
```

`scripts/xcb.sh` wraps `xcodebuild` and pins it to the single simulator the
project uses, so a build never boots a device of its own choosing.
`WhereIWas.xcodeproj` is generated and not committed. Background behaviour
(relaunch after termination, reboot, visits, motion activity) can only be tested
on a device — see `ARCHITECTURE.md` §7.

## Licence

Not yet decided. All rights reserved for now.
