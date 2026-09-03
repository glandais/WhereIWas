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
