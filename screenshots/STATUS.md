# Screenshot status

What is on the store right now, what is a placeholder, and what each placeholder
is waiting for. Update this file whenever a screenshot is replaced.

Last reviewed: 3 September 2026.
Uploaded to App Store Connect (app 6808349924, version 1.0.0, en-US): all five,
delivery state COMPLETE.

## IPHONE_65 · en-US

| # | File | State | Notes |
|---|---|---|---|
| 1 | `01-map.png` | **placeholder** | The track is 4 points, 0 m, over 25 seconds — there is nothing to look at, and the summary bar says so. Also shows a real street name (Allée de l'Éloquence), which puts a real address on the App Store. |
| 2 | `02-status.png` | **placeholder** | Taken while stationary, so it reads `Stationary` / `GPS off` — the screen demonstrates nothing. Half the screen is empty, and the shot was taken mid-scroll (a clipped `When … 11 sec ago` row at the bottom). |
| 3 | `03-audit-trail.png` | good | Five events, legible, showing motion events, an accepted fix and the trail being switched on. This is the differentiator, no competitor shows it. Only weakness: `5 shown · 5 stored`, a trail that was just enabled. |
| 4 | `04-export.png` | good | Formats, ranges, a prepared JSON file with its size, and a session row. Reads well. The session says `14 samples · 0 m`, which is thin but not distracting. |
| 5 | `05-settings.png` | good | The tunable thresholds, the sample filter and its explanation. Makes the point that the app is adjustable. Minor: taken mid-scroll, so the top and bottom rows are blurred in transition. |

## What the placeholders need

Both need **one day of real recording with varied movement** — walking and
driving — before they are worth retaking:

- **`01-map.png`**: a day with a real track, framed with *Fit track*, showing a
  believable distance and span. Record it somewhere neutral: the map and the
  `Position` field on the Status screen both expose real coordinates, and a
  normal day would publish home and work.
- **`02-status.png`**: taken **while actually moving**, so it shows phase
  `Moving`, a populated `GPS profile` (e.g. `fitness · Best · 10 m`), a detected
  `Activity` with its confidence, and a recent `Last fix`. Scroll to the top
  first so no row is clipped.

Worth reconsidering once both are retaken: the current order follows the app's
tabs, but the first screenshot is the one most people see, and today it is the
weakest of the five.

## fr-FR

Empty. The app UI is English-only (no String Catalog yet), so French screenshots
would show English screens. Either localize the app first, or upload the en-US
set for fr-FR as well — Apple allows it, but it is visibly a compromise.

## Checking before upload

```bash
asc screenshots validate --path "./screenshots/IPHONE_65/en-US" --device-type "IPHONE_65"
```

Files upload in filename order, which is why they are numbered.
