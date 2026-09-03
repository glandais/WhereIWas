#!/usr/bin/env python3
"""PreToolUse hook: refuse a Bash command that would drive another simulator.

This Mac has limited resources and cannot afford several booted simulators. The
convention lives in `CLAUDE.md`, but a convention is only a request — this is
what makes it hold. Reads the tool call as JSON on stdin; exit 2 blocks the call
and hands stderr back to the agent, exit 0 lets it through.

The device itself is never defined here: it comes from `scripts/sim-config.sh`,
so the guard and the scripts can never disagree.

Wired from `.claude/settings.json` as a `PreToolUse` hook on `Bash`.
"""

import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# `xcrun xcodebuild …` is the same call as `xcodebuild …`.
SEPARATORS = re.compile(r"(?:&&|\|\||[;&|\n])")
HEREDOC = re.compile(r"<<-?\s*[\"']?(\w+)[\"']?")
READ_ONLY = ("-showBuildSettings", "-showdestinations", "-list", "archive")


def sim_config():
    """(device, udid) from sim-config.sh; udid is "" if it cannot be resolved."""
    script = 'source "$1/scripts/sim-config.sh"; echo "$SIM_DEVICE"; sim_udid'
    out = subprocess.run(["bash", "-c", script, "_", REPO],
                         capture_output=True, text=True)
    lines = out.stdout.splitlines()
    return (lines[0] if lines else ""), (lines[1] if len(lines) > 1 else "")


def strip_heredocs(text):
    """Drop heredoc bodies: they are data, not commands.

    Writing *about* xcodebuild — in a markdown file, a comment, this very
    script — must not trip the guard.
    """
    kept, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        kept.append(line)
        match = HEREDOC.search(line)
        if match:
            tag = match.group(1)
            i += 1
            while i < len(lines) and lines[i].strip() != tag:
                i += 1
        i += 1
    return "\n".join(kept)


def invocations(text, name):
    """Command segments whose first word is `name`, optionally via xcrun."""
    for segment in SEPARATORS.split(text):
        words = segment.split()
        if words and words[0] == "xcrun":
            words = words[1:]
        if words and words[0].rsplit("/", 1)[-1] == name:
            yield " ".join(words)


def refuse(device, why):
    print(f"Blocked: this project uses one simulator only — {device}.", file=sys.stderr)
    print(f"\n{why}\n", file=sys.stderr)
    print("Use the wrapper instead, which pins the destination and DerivedData:",
          file=sys.stderr)
    print("  ./scripts/xcb.sh build | test | strings", file=sys.stderr)
    print("  ./scripts/xcb.sh -- <raw xcodebuild args>", file=sys.stderr)
    print("See the Simulator section of CLAUDE.md.", file=sys.stderr)
    sys.exit(2)


def main():
    try:
        command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    except Exception:
        return  # A hook that cannot read its input must not block the session.
    if not command:
        return

    # The scripts are the sanctioned path; whatever they run is already pinned.
    if "scripts/xcb.sh" in command or "scripts/screenshots.sh" in command:
        return
    # Nothing else can boot a simulator, so skip the simctl round-trip.
    if "xcodebuild" not in command and "simctl" not in command:
        return

    device, udid = sim_config()
    if not device:
        return

    def pinned(segment):
        return device in segment or (bool(udid) and udid in segment)

    body = strip_heredocs(command)

    for call in invocations(body, "xcodebuild"):
        if any(flag in call for flag in READ_ONLY):
            continue  # Read-only queries and archives never boot a simulator.
        if "generic/platform=iOS Simulator" in call:
            refuse(device, "'generic/platform=iOS Simulator' leaves the device unpinned.")
        if "generic/platform=iOS" in call:
            continue  # A real device: nothing to boot.
        if "-destination" not in call:
            refuse(device, "This xcodebuild call has no -destination, "
                           "so Xcode picks a device on its own.")
        if "platform=iOS Simulator" in call and not pinned(call):
            refuse(device, f"Its -destination names a simulator other than {device}.")

    for call in invocations(body, "simctl"):
        words = call.split()
        if len(words) > 1 and words[1] in ("boot", "bootstatus") and not pinned(call):
            refuse(device, f"It boots a simulator other than {device}.")


main()
