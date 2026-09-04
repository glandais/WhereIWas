#!/usr/bin/env bash
#
# The only way to run xcodebuild against a simulator in this repo.
#
# It pins the destination to the one simulator declared in `sim-config.sh` and
# a repo-local DerivedData, so no build ever boots a device of its own choosing
# — see the `Simulator` section of `CLAUDE.md`. `scripts/guard-simulator.py`
# enforces it for agents.
#
# Usage:
#   ./scripts/xcb.sh build            build the WhereIWas scheme (Debug)
#   ./scripts/xcb.sh test             build and run WhereIWasTests
#   ./scripts/xcb.sh strings          build, then sync the string catalog
#   ./scripts/xcb.sh -- <args...>     raw xcodebuild, destination still pinned
#
# Extra arguments after the subcommand are passed through to xcodebuild.
#
# WHEREIWAS_SCHEME picks another scheme of the same project — in practice
# `WhereIWas-Screenshots`, the only way to compile the `#if SCREENSHOTS` code.
# It is an environment variable rather than a passed-through `-scheme` because
# xcodebuild refuses the option twice, and the point of this script is that the
# pinned destination cannot be argued with.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sim-config.sh

PROJECT="WhereIWas.xcodeproj"
SCHEME="${WHEREIWAS_SCHEME:-WhereIWas}"
CATALOG="WhereIWas/Resources/Localizable.xcstrings"

command="${1:-build}"
shift || true

UDID=$(sim_udid)
DEST=$(sim_dest "$UDID")

xcb() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DEST" -derivedDataPath "$DERIVED_DATA" "$@"
}

case "$command" in
  build)
    echo "▸ build on ${SIM_DEVICE} (${UDID})"
    xcb build "$@"
    ;;

  test)
    echo "▸ test on ${SIM_DEVICE} (${UDID})"
    sim_boot "$UDID"
    xcb test "$@"
    ;;

  strings)
    # Replaces the hand-run extraction `CLAUDE.md` used to document, and closes
    # its two traps: the catalog is synced in place (a copy outside the repo
    # resolves no source and marks every key stale), and *every* architecture
    # slice is passed, not the first one `head -1` happened to pick — leaving
    # the others out strips their extractionState and produces a large no-op
    # diff.
    echo "▸ build on ${SIM_DEVICE} (${UDID})"
    xcb build "$@" >/dev/null
    objects="${DERIVED_DATA}/Build/Intermediates.noindex/WhereIWas.build/Debug-iphonesimulator/WhereIWas.build/Objects-normal"
    slices=("$objects"/*/*.stringsdata)
    if [ ! -e "${slices[0]}" ]; then
      echo "xcb: no .stringsdata under ${objects}" >&2
      exit 1
    fi
    echo "▸ syncing ${CATALOG} from ${#slices[@]} stringsdata file(s)"
    xcrun xcstringstool sync "$CATALOG" --stringsdata "${slices[@]}"
    echo "▸ done. Fill the en unit and the eight other units of any new key;"
    echo "  extractionState: stale means a dead key."
    ;;

  --)
    xcb "$@"
    ;;

  *)
    echo "xcb: unknown command '${command}'" >&2
    sed -n '/^# Usage:/,/^# Extra/p' "$0" | sed 's/^#\{1,\} \{0,1\}//' >&2
    exit 1
    ;;
esac
