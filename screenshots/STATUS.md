# Screenshot status

What is on the store right now, what is a placeholder, and what each placeholder
is waiting for. Update this file whenever a screenshot is replaced.

Last reviewed: 4 September 2026.
Uploaded to App Store Connect (app 6808349924, version 1.0.0, en-US): the five
hand-taken shots described below, delivery state COMPLETE. The local files have
since been **regenerated** by `./scripts/screenshots.sh` and no longer match
what the store serves — re-upload once you are happy with them.

## How they are produced now

`./scripts/screenshots.sh` builds the app in the `Screenshots` configuration
and captures all five screens in both locales from `DemoTrackingController`'s
mocked data. See `README.md` for the mechanics. This replaced the manual
device captures, which is what unblocked the two placeholders and the empty
`fr-FR` set.

## IPHONE_65 · en-US and fr-FR

| # | File | State | Notes |
|---|---|---|---|
| 1 | `01-map.png` | generated | A walking loop then a ~10 km drive, framed with *Fit track*. Fictional coordinates around Place de la République, so no real address is published. |
| 2 | `02-status.png` | generated | Phase `Moving`, GPS profile `Driving · Best for navigation · 50 m`, activity `Driving (high)`, a fix from two seconds ago. This is what the old placeholder was waiting for. |
| 3 | `03-audit-trail.png` | generated | Ten events across several categories and severities, including an accepted fix with its validation checks and a rejected one. Still the differentiator no competitor shows. |
| 4 | `04-export.png` | generated | Formats, ranges, a prepared GPX with its real size, and the session list. |
| 5 | `05-settings.png` | generated | Permissions all granted, the motion-detection tunables and their explanation. |

## Known limitations

- **Run the script during the day.** The demo track spans ~92 minutes ending
  "now" and the Map screen shows a single day, so a run just after midnight
  compresses it and prints implausible session durations. The script warns.
- The audit trail's `message` and `name` fields stay English in the `fr-FR`
  shots. That is the app's design — audit payloads are machine text written to
  the exports, not localized strings (same rule as
  `StateTransitionRecord.reason`) — not a capture bug.
- The order still follows the app's tabs. The map is first because it is the
  one most people see; worth revisiting once there is store data to judge it.

## Checking before upload

```bash
asc screenshots validate --path "./screenshots/IPHONE_65/en-US" --device-type "IPHONE_65"
asc screenshots validate --path "./screenshots/IPHONE_65/fr-FR" --device-type "IPHONE_65"
```

`validate` only checks dimensions; the script already flattens the alpha
channel, which is the failure it cannot see (see `README.md`).

Files upload in filename order, which is why they are numbered.
