# WhereIWas

An iPhone location logger built for long shifts: the GPS receiver runs only
while you actually move, the track survives termination and reboot, and every
point is exportable as GPX or JSON. Nothing leaves the device.

Shipped in nine languages: English, French, German, Spanish, Italian, Japanese,
Dutch, Polish and Czech.

App Store name: **WhereIWas: Location Timeline** (localized per market) — iOS 17+.

- App Store: <https://apps.apple.com/app/id6808349924>
- Website: <https://glandais.github.io/WhereIWas/>
- Support: <https://glandais.github.io/WhereIWas/support/>
- Privacy: <https://glandais.github.io/WhereIWas/privacy/>
- Tip jar: <https://ko-fi.com/gabylandais>

## Repository layout

```
WhereIWas/       app sources (App, Domain, Persistence, Location, Motion, Coordinator, UI, Resources)
WhereIWasTests/  Swift Testing suites
scripts/         build, simulator and screenshot tooling (xcb.sh is the only way in)
docs/            the website, served by GitHub Pages from main
design/          icon and site design sources
metadata/        canonical App Store metadata, ten store locales, applied with the asc CLI
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

`WhereIWas.xcodeproj` is generated and gitignored. See `CLAUDE.md` for the
full build, simulator and release workflow.

## Licence

Not yet decided. All rights reserved for now.
