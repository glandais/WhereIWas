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

A capture from any Pro Max since the iPhone 15 comes out at 1290×2796 and has to be
resized to 1284×2778 before upload.

Landscape variants of the same sizes are accepted too.

`STATUS.md` tracks which screenshots are final and which are placeholders waiting
to be retaken. Keep it current when you replace one.

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
