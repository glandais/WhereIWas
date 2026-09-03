# App Store screenshots

One directory per display type, then per locale, mirroring the layout `asc screenshots
upload` expects:

```
screenshots/<DISPLAY_TYPE>/<locale>/*.png
```

Both display types below are **required** for submission, because the app ships for
iPhone and iPad (`TARGETED_DEVICE_FAMILY: "1,2"` in `project.yml`). Run
`asc screenshots sizes` to re-check the accepted dimensions.

| Display type | Accepted dimensions (portrait) |
|---|---|
| `IPHONE_65` | 1242×2688, 1284×2778 |
| `IPAD_PRO_3GEN_129` | 2048×2732, 2064×2752 |

Landscape variants of the same sizes are accepted too.

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
