# App Store screenshots

One directory per display type, then per locale, mirroring the layout `asc screenshots
upload` expects:

```
screenshots/<DISPLAY_TYPE>/<locale>/*.png
```

The app is iPhone-only (`TARGETED_DEVICE_FAMILY: "1"` in `project.yml`), so
`IPHONE_65` is the only display type submission requires. Run
`asc screenshots sizes` to re-check the accepted dimensions.

| Display type | Accepted dimensions (portrait) |
|---|---|
| `IPHONE_65` | 1242×2688, 1284×2778 |

A Pro Max capture is always larger than the accepted sizes and has to be resized
to 1284×2778 before upload — 1290×2796 on an iPhone 15 to 16 Pro Max, 1320×2868 on
the iPhone 17 Pro Max that `scripts/sim-config.sh` pins. The aspect ratio differs
from 1284×2778 by well under a percent, so the downscale is invisible;
`scripts/screenshots.sh` refuses a capture more than 2% off, which is what a
non-iPhone would produce.

Landscape variants of the same sizes are accepted too.

`STATUS.md` tracks which screenshots are final and which are placeholders waiting
to be retaken. Keep it current when you replace one.

## Automated capture

`./scripts/screenshots.sh` produces the whole set — five screens × two locales
— from mocked data, and leaves the files here ready to upload. Uploading stays
manual.

```bash
./scripts/screenshots.sh              # en-US and fr-FR
./scripts/screenshots.sh fr-FR        # one locale
SCREENSHOT_DEVICE="iPhone 17 Pro" ./scripts/screenshots.sh
SCREENSHOT_TIME="9:41" ./scripts/screenshots.sh    # pin the status-bar clock
```

How it works:

- The app is built in the **`Screenshots`** configuration (see `project.yml`),
  which defines the `SCREENSHOTS` compilation condition. Everything the mode
  needs — `ScreenshotMode`, `DemoTrackingController`, the launch-argument hooks
  in the UI — lives under `#if SCREENSHOTS` and is absent from the archived
  Release binary. Check with:
  `xcodebuild -target WhereIWas -configuration Release -showBuildSettings | grep SWIFT_ACTIVE`
- Each screenshot is one launch:
  `simctl launch … -screenshotMode YES -screenshotScreen map -AppleLanguages "(fr)" -AppleLocale fr_FR`.
  `-screenshotScreen` takes `status`, `map`, `export`, `settings` or `audit`
  (the audit trail opens itself from Settings). No taps, so nothing depends on
  a tab label that differs between locales.
- With `screenshotMode` on, `AppDelegate` skips `AppEnvironment.bootstrap`:
  no `CLLocationManager`, no permission prompts, no BGTask, no on-disk store.
  The UI runs entirely on `DemoTrackingController`.
- Captures come out at the simulator's native size and are scaled to
  1284×2778 and flattened (see below) into `IPHONE_65/<locale>/`. The raw
  files stay in `screenshots/raw/` (gitignored).

**Run it during the day.** The demo dataset spans about 92 minutes ending
"now", and the Map screen shows one day at a time, so before ~01:40 the track
is squeezed into the few minutes elapsed since midnight and session durations
read wrong. The script warns when that happens.

To change what the shots show — the track, the phase, the audit events, the
session list — edit `WhereIWas/App/DemoTrackingController.swift`; it is the
single source of the mocked data.

## No alpha channel

App Store Connect rejects any screenshot carrying an alpha channel
(`IMAGE_ALPHA_NOT_ALLOWED`). iPhone screenshots have one: the rounded screen
corners are transparent. Flatten before uploading — on black, since the app is
dark:

```bash
python3 -c "
from PIL import Image; import pathlib
for p in pathlib.Path('screenshots/IPHONE_65/en-US').glob('*.png'):
    im = Image.open(p)
    if 'A' in im.getbands():
        bg = Image.new('RGB', im.size, (0, 0, 0))
        bg.paste(im, mask=im.getchannel('A'))
        bg.save(p, 'PNG', optimize=True)
"
```

Note that `asc screenshots validate` does **not** catch this — it checks
dimensions only, and reported all five as ready. The failure surfaces during
upload, and the rejected asset stays in the set as `FAILED`; delete it with
`asc screenshots delete --id <id>` before retrying.

## Workflow

```bash
# validate the files before uploading
asc screenshots validate --path "./screenshots/IPHONE_65/en-US" --device-type "IPHONE_65"

# upload for one version localization
asc screenshots upload \
  --version-localization "VERSION_LOCALIZATION_ID" \
  --path "./screenshots/IPHONE_65/en-US" \
  --device-type "IPHONE_65"
```

Get the version-localization IDs with:

```bash
asc localizations list --version-id "VERSION_ID"
```
