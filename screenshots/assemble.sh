#!/usr/bin/env bash
#
# Stage 3 of the screenshot pipeline: turn Koubou's renders into the set
# `asc screenshots upload` reads.
#
#   1. ./scripts/screenshots.sh                     -> screenshots/flat/<locale>/NN-*.png
#   2. kou generate screenshots/koubou/config.yaml  -> screenshots/koubou/out/<locale>/<device>/NN-*.png
#   3. ./screenshots/assemble.sh                    -> screenshots/IPHONE_65/<locale>/NN-*.png
#
# Koubou writes one directory level App Store Connect knows nothing about (the
# device frame name), so this flattens it away, deletes whatever an earlier
# naming scheme left in the destination, and refuses to leave a set on disk that
# the upload would reject.
#
# Checks, all fatal:
#   - exactly 1242x2688 (IPHONE_65 portrait)
#   - no alpha channel — ASC answers IMAGE_ALPHA_NOT_ALLOWED and
#     `asc screenshots validate` does NOT catch it (see screenshots/README.md)
#   - non-empty, and not far smaller than the same card in the other locales:
#     a blank or half-painted render is small, not missing
#   - `asc screenshots validate` per locale on top, when asc is on PATH
#
# Usage: ./screenshots/assemble.sh [--keep-stale] [--no-validate]
#
# Written for the /bin/bash 3.2 that ships with macOS: no mapfile, no
# associative arrays. The per-file checks live in the embedded Python.

set -euo pipefail

cd "$(dirname "$0")/.."

SRC="screenshots/koubou/out"
DST="screenshots/IPHONE_65"
DEVICE_TYPE="IPHONE_65"

keep_stale=0
run_validate=1
for arg in "$@"; do
  case "$arg" in
    --keep-stale)  keep_stale=1 ;;
    --no-validate) run_validate=0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

[ -d "$SRC" ] || { red "no renders in $SRC — run: kou generate screenshots/koubou/config.yaml"; exit 1; }

locales=$(find "$SRC" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
[ -n "$locales" ] || { red "no locale directories under $SRC"; exit 1; }

bold "Assembling: $(echo "$locales" | tr '\n' ' ')"

copied=0
for loc in $locales; do
  # out/<locale>/<device>/NN-*.png — exactly one device directory expected.
  ndev=$(find "$SRC/$loc" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  if [ "$ndev" != "1" ]; then
    red "FAIL $loc: expected one device directory under $SRC/$loc, found $ndev"
    exit 1
  fi
  devdir=$(find "$SRC/$loc" -mindepth 1 -maxdepth 1 -type d)

  npng=$(find "$devdir" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')
  [ "$npng" != "0" ] || { red "FAIL $loc: no PNGs in $devdir"; exit 1; }

  mkdir -p "$DST/$loc"

  # Anything the new render does not replace is a leftover from an older naming
  # scheme; left in place it would upload alongside the new set.
  if [ "$keep_stale" -eq 0 ]; then
    for existing in "$DST/$loc"/*.png; do
      [ -e "$existing" ] || continue
      base=$(basename "$existing")
      if [ ! -e "$devdir/$base" ]; then
        rm "$existing"
        echo "  removed stale $DST/$loc/$base"
      fi
    done
  fi

  for src in "$devdir"/*.png; do
    cp "$src" "$DST/$loc/$(basename "$src")"
    copied=$((copied + 1))
  done
done

bold "Copied $copied files into $DST/"

# ---------------------------------------------------------------- checks
python3 - "$DST" <<'PY' || exit 1
import os, subprocess, sys, statistics

dst = sys.argv[1]
EXPECT = (1242, 2688)
FLOOR = 0.50   # of the median byte size of the same card across locales

files = []
for loc in sorted(os.listdir(dst)):
    d = os.path.join(dst, loc)
    if not os.path.isdir(d):
        continue
    for name in sorted(os.listdir(d)):
        if name.endswith(".png"):
            files.append((loc, name, os.path.join(d, name)))

if not files:
    print("FAIL: nothing to check in", dst)
    sys.exit(1)

by_slide = {}
for _, name, path in files:
    by_slide.setdefault(name, []).append(os.path.getsize(path))
median = {k: statistics.median(v) for k, v in by_slide.items()}

fail = []
for loc, name, path in files:
    out = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", path],
        capture_output=True, text=True).stdout
    got = {}
    for line in out.splitlines():
        if ":" in line:
            k, _, v = line.strip().partition(":")
            got[k.strip()] = v.strip()
    w, h = got.get("pixelWidth"), got.get("pixelHeight")
    if (w, h) != (str(EXPECT[0]), str(EXPECT[1])):
        fail.append(f"{loc}/{name}: {w}x{h}, expected {EXPECT[0]}x{EXPECT[1]}")
    if got.get("hasAlpha") != "no":
        fail.append(f"{loc}/{name}: alpha channel present (ASC: IMAGE_ALPHA_NOT_ALLOWED)")
    size = os.path.getsize(path)
    if size == 0:
        fail.append(f"{loc}/{name}: zero bytes")
    elif size < FLOOR * median[name]:
        fail.append(f"{loc}/{name}: {size} B, under {FLOOR:.0%} of the "
                    f"{int(median[name])} B median for {name}")

print(f"Checked {len(files)} files across {len(set(f[0] for f in files))} locales, "
      f"{len(by_slide)} cards each")
for f in fail:
    print("FAIL " + f)
sys.exit(1 if fail else 0)
PY

if [ "$run_validate" -eq 1 ]; then
  if command -v asc >/dev/null 2>&1; then
    for loc in $locales; do
      echo "asc screenshots validate — $loc"
      asc screenshots validate --path "./$DST/$loc" --device-type "$DEVICE_TYPE"
    done
  else
    echo "asc not on PATH — skipped the per-locale validate"
  fi
fi

bold "OK — $DST/ is ready to upload"
