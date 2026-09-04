# App Store screenshots — ledger

Working record for the second pass on the store screenshots: which screens go up, what the demo
dataset has to show for each, and how the flat captures become marketing cards. Decisions are
recorded as they are made; open questions are listed at the end and removed once answered.

`screenshots/README.md` describes what the pipeline does today.

## Where things stand (2026-09-04, fourth entry)

Card 5 was reframed and the whole set re-rendered. Two changes:

- **`ExportView` scrolls to the session list in screenshot mode.** The old capture opened on the
  format picker and its grey help text, which is what made the card read like a settings page (the
  first-set finding below). The capture now shows the prepared file and six sessions across three
  days, and `05-export-card.html` crops **x 45..1275, y 772..2590** out of it at 0.85× — the share
  row, the file name, the size, the footer and all six session rows with their sample counts,
  distances and durations. The old window (`y 895..1800`, aimed at the format card) pointed at
  nothing after the scroll.
- The window is measured from the **bottom** of the capture, not the top. Bottom-anchored content
  means the session card lands at the same pixel row in all nine locales (y 2574; 2558 in en-US)
  with a 197px row pitch, while everything above it drifts by up to 60px — three-line format
  descriptions in ja/pl/cs, a three-line footer in German and Polish. A top-measured window would
  have to absorb that drift twice. `screenshots/README.md` § Framing notes carries the details.

The capture step also grew a guard: five captures in a locale must be five distinct files. It exists
because a `./scripts/xcb.sh test` run concurrent with a capture installed the Debug app over the
Screenshots one (same bundle identifier, the test host), which silently produced forty-five copies
of the permission-denied Status screen from a script that reported success.

Card 5's headline now auto-fits in three locales (German 9.80vw, Dutch and Polish 10.55vw) where it
did not before — a consequence of the smaller copy budget the taller card needs. German is a
line-breaking result, not a budget one: more budget would not buy the size back, a shorter headline
would.

## Where things stand (2026-09-04, third entry)

Everything except the upload (D15) is done. The nine-locale set of framed cards is on disk in
`screenshots/IPHONE_65/` and passes the dimension, alpha, size and `asc screenshots validate`
checks. What exists:

- `scripts/generate-tracks.swift` — a one-off, run by hand on this machine, asks **MKDirections**
  for the nine city routes and writes `WhereIWas/App/DemoTracks.swift`. It needs a run loop for
  the completion handler (a bare semaphore wait deadlocks) and rate-limits its legs; `--osrm`
  switches the whole run to the public OSRM server if Apple ever throttles.
- `WhereIWas/App/DemoTracks.swift` — the nine tracks, 77–155 points each, three segments apiece.
- `DemoTrackingController` rebuilt on them: three days, two scenarios, two clocks.
- `scripts/screenshots.sh` — five cards, `-screenshotScenario`, locales read from `knownRegions`,
  flat captures in `screenshots/flat/` (gitignored) for Koubou to frame.
- `WhereIWasTests/DemoTracksTests.swift` — the D12 guard.
- `screenshots/koubou/` — `config.yaml`, five templates, `koubou-strings.xcstrings` with ten
  strings in nine languages (D1/D13/D14). Renders are gitignored.
- `screenshots/assemble.sh` — flattens Koubou's `out/<locale>/<device>/` into
  `screenshots/IPHONE_65/<locale>/`, deletes what the new render does not replace, and fails on a
  wrong size, an alpha channel, a zero-byte or an outlier-small card.

Still to do: the upload (D15).

**One deviation worth knowing.** The templates auto-fit the headline per locale, with a 9vw floor
under the Koubou skill's 10vw minimum for this canvas. Card 1 is the only place it bites: German
and Polish sit on the floor (9.0vw, three lines) and Czech at 9.15vw, all readable. Shortening
those three headlines would buy the size back.

## Findings from the first set (what the decisions answer)

- **Map** is the weakest card: the drive is a near-straight line, and the set was captured at
  01:45, so the day-view span reads 00:13–01:45 — the trap the README warns about.
- **Status** is the only screen that shows what the app is about (phase, tuned GPS profile,
  detected activity, fresh fix). It should lead.
- **Audit trail** is the most differentiating screen ("Fix rejected: poorAccuracy", `probing →
  moving`) and belongs ahead of Export.
- **Export** works but the long file name and the grey help text make it read like a settings
  page. The session list, which is the interesting part, is below the fold.
- **Settings** does not sell in fifth position. Candidate to drop, or to reduce to a zoomed
  Permissions block on a card.

## Decisions

All decided on 2026-09-04.

| # | Decision |
|---|----------|
| D1 | Screenshots become framed marketing cards (device frame + headline), rendered by Koubou at `iPhone6_5`, not flat captures |
| D2 | Five cards, in this order: Status/Moving → Status/Stationary → Map → Audit trail → Export |
| D3 | Settings leaves the set. No closing card |
| D4 | The demo controller grows a `-screenshotScenario` launch argument next to `-screenshotScreen`, all under `#if SCREENSHOTS` |
| D5 | One city per App Store locale: Boston (en-US), Paris, Berlin, Madrid, Rome, Tokyo, Amsterdam, Warsaw, Prague. The track is a street-following polyline precomputed once and committed as a `Screenshots`-only resource; the controller picks it from the launch locale's region |
| D6 | Tracks come from **MapKit Directions**, generated by a one-off script on this machine, never computed at capture time. Captures stay deterministic and offline |
| D7 | The route is a station-to-scene run with one or two stops, between public places over public roads — no identifiable address |
| D8 | Route length 5–10 km everywhere, shorter in Tokyo where the tiles are dense |
| D9 | Second Status card shows `stationary` ("Stationary (coarse)", no active profile, older last fix) — the battery argument |
| D10 | Units follow the locale, as the app does on first launch: miles for en-US, metric elsewhere |
| D11 | Time anchoring: Map and Export use a fixed daytime window so capture time no longer matters; Status keeps "now" so its "11 sec. ago" stays true |
| D12 | A test asserts every locale in `knownRegions` has a track fixture, so a tenth market cannot silently fall back to Paris |
| D13 | Headlines are localized through Koubou's xcstrings extraction, one set of nine translations, no per-locale templates |
| D14 | Koubou sources (templates, `config.yaml`) live in `screenshots/koubou/`; renders are gitignored |
| D15 | Upload: all nine locales in one go, replacing the five hand-taken `en-US` shots on the store |

## Card plan

| Slide | Screen | Scenario | Message (draft, English) |
|-------|--------|----------|--------------------------|
| 1 | Status | `moving` — driving, high-confidence activity, fix seconds old | Records in the background. Survives termination and reboot. |
| 2 | Status | `stationary` — "Stationary (coarse)", no active profile, last fix minutes old | GPS only runs while you move. |
| 3 | Map | full day, several stops, walking loop visible, date picker able to step back | Every day of the deployment, on the map. |
| 4 | Audit trail | severity `Info`, so transitions and rejected fixes show without `store.insert` noise | Every fix accepted or rejected, with the reason. |
| 5 | Export | session list scrolled into view, 3–4 sessions over several days, short file name | GPX and JSON, with speed, accuracy, activity and battery. |

Card 5 came out with **six** sessions over three days rather than 3–4, and the file name is still
the long timestamped one — it wraps to two lines and reads fine inside the crop, so it was left
alone. See the fourth entry above for the framing that resulted.

Headlines are placeholders: the Koubou skill wants 2–3 options per slide before layout work.

## Demo dataset — what had to change

**Done**, all five items — see "How the decisions came out" below for where the plan bent.

- **Scenarios.** `status.phase` is hard-coded to `.moving`; a `stationary` state needs its own
  status (no active profile, older last fix, `keepCoarseUpdatesWhileStationary` on so the screen
  says "Stationary (coarse)").
- **Time anchoring.** The dataset is anchored on `ScreenshotMode.clock` = launch time, which is
  right for Status ("11 sec. ago") and wrong for Map (a whole day). Either two anchors, one per
  screen: fixed daytime window for Map and Export, launch time for Status (D11).
- **Multi-day.** Map's date picker and Export's session list need samples across two or three
  days, not just today.
- **Geometry.** Replace the sine-based drive with the per-city polyline; resample it into
  timestamped samples with speed and course so Status, Export and the session summaries stay
  consistent with the map.
- **Per-city fixtures.** One resource per locale (JSON or GeoJSON), a few hundred points each,
  compiled only in the `Screenshots` configuration.

## Koubou — what has to exist

- `screenshots/koubou/` with `config.yaml` and `templates/`
  with at least three distinct layouts, `data-kou-id` annotations on headline, subtitle and
  device.
- Style intake first: icon in `design/appicon`, the app's system palette (light UI, green/blue
  accents, SF Symbols, no illustration).
- Output at `iPhone6_5` (1242×2688), flattened, per locale in the layout `asc screenshots upload`
  reads.

## How the decisions came out

Four of them needed a refinement once they met the code. Recorded here rather than edited into the
table above, so the reasoning survives.

- **D5, the fixture form.** Not a bundle resource: `WhereIWas/App/DemoTracks.swift`, a generated
  Swift file wrapped entirely in `#if SCREENSHOTS`. XcodeGen has no per-configuration source
  filter, so a resource would have shipped in the Release bundle or needed a copy-phase script;
  the compilation condition removes the file outright, and the test target can compile the same
  file (see D12 below). Coordinates are one string literal per city, parsed once — a dictionary of
  thousands of array elements is a type-checker trap.
- **D8, route length.** Two endpoints moved to land inside 5–10 km: Rome's park gate east (the
  original routed 10.65 km) and Prague's west (4.06 km). Tokyo is 4.13 km, its documented
  exception. MKDirections has no waypoint API, so each loop is four pairwise-routed legs, and two
  runs can return different-but-equivalent geometry — the diff is reviewed against the script's
  printed summary, not expected to be empty.
- **D11, time anchoring.** "A fixed daytime window" turned out to need a fixed *day* too: the
  export screen's `today` scope is bounded by `now`, so a fixed morning window exported nothing
  when captured at 02:00. So Map opens on **yesterday** in screenshot mode and Export selects
  **All**; the two complete days sit at fixed local hours (yesterday 08:12–10:05, the day before
  14:20–16:40), and only today's in-progress drive — the one Status reports on — is tied to the
  capture instant. That drive lasts what its geometry takes at driving speed (7–16 min), not the
  35 min first sketched: stretching it would have put a wrong speed on every sample.
- **D12, the fixture test.** `DemoTracks.swift` is added to the *test target's* sources with
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG SCREENSHOTS`, since the Debug app compiles nothing
  from it and there is no duplicate symbol. The test checks the nine languages, three segments,
  both modes, 3–12 km of driving and coordinate sanity. The guard against a *tenth* market is in
  `scripts/screenshots.sh`, which reads `knownRegions` from `project.yml` and fails hard on a
  language it cannot map to an App Store Connect locale.

## D16 — the status-bar clock (2026-09-04)

The clock read the same in all nine locales, because the status bar is drawn by the **system** and
`-AppleLanguages "(ja)"` relanguages only the app. Two findings:

- `simctl status_bar override --time` is not the lever. It parses the value and renders it with a
  format of its own — "9:41" came out "09:41" even under an en-US system.
- Leaving `--time` out entirely keeps the real clock, which the system draws in the system locale.

So the script now moves the simulator's own locale with each capture (global domain plus a
SpringBoard restart, restored on exit — the simulator is shared) and overrides only the battery
and the signal. The result is en-US "6:18", fr/de/it/nl/pl "06:18", es/ja/cs without the leading
zero, which is what CLDR says.

The hour stays the host's current one rather than a pinned 9:41: the Status card prints its last
fix as both "13 sec. ago" and an absolute time read off `ScreenshotMode.clock`, so a pinned clock
would contradict the screen underneath it. Making 9:41 work would mean injecting a fake "now" into
the app — `Formatting.relative(_:to:)` takes a `now` it currently ignores — which is shipping code
changed for a screenshot. Not worth it.

## Open questions

None. Next step: the upload (D15) — nine locales, five cards each, from
`screenshots/IPHONE_65/`.
