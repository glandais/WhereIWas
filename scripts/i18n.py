#!/usr/bin/env python3
"""Aggregate every translation of the project into a single JSON file, and put it back.

    scripts/i18n.py export [-o i18n/translations.json]   # sources -> one JSON
    scripts/i18n.py import [-i i18n/translations.json]   # one JSON -> sources
    scripts/i18n.py check                                # round trip is byte-exact

What it covers, in nine languages each:

  * `WhereIWas/Resources/Localizable.xcstrings`  — the app UI
  * `WhereIWas/Resources/InfoPlist.xcstrings`    — the three permission prompts
  * `screenshots/koubou/koubou-strings.xcstrings`— the App Store screenshot cards
  * `metadata/app-info/<locale>.json`            — store name, subtitle, URLs
  * `metadata/version/<version>/<locale>.json`   — description, keywords, …

The mapping is bijective: `import` right after `export` rewrites every one of
those files byte for byte, so the JSON can be edited (or handed to a translator)
and pushed back without losing plural variations, substitutions, comments,
extraction states, unit states, key order or file formatting.

Two English texts are duplicated outside a catalog — the permission prompts in
`project.yml`, and the screenshot headlines in `screenshots/koubou/config.yaml`,
whose values are the keys of the Koubou catalog. They are exported under
`sourceMirrors`; `import` checks them and reports a divergence rather than
editing YAML.

Deliberately out of scope, being English-only by design: `metadata/review-notes.md`,
`metadata/app-privacy.md`, `metadata/app-privacy.json` (no prose) and the `docs/`
website.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "WhereIWas" / "Resources"

CATALOGS = {
    "Localizable": RESOURCES / "Localizable.xcstrings",
    "InfoPlist": RESOURCES / "InfoPlist.xcstrings",
    "Koubou": ROOT / "screenshots" / "koubou" / "koubou-strings.xcstrings",
}
PROJECT_YML = ROOT / "project.yml"
KOUBOU_CONFIG = ROOT / "screenshots" / "koubou" / "config.yaml"
METADATA = ROOT / "metadata"
DEFAULT_JSON = ROOT / "i18n" / "translations.json"

# The catalogs use short language codes; App Store Connect has its own namespace
# for the same nine languages, and that is what metadata/ and screenshots/ use.
LOCALE_MAP = {"en": "en-US", "fr": "fr-FR", "de": "de-DE", "es": "es-ES",
              "it": "it", "ja": "ja", "nl": "nl-NL", "pl": "pl", "cs": "cs"}

# ---------------------------------------------------------------- catalog i/o

def catalog_style(path: Path) -> tuple[str, str]:
    """Sniff how this catalog is already written, so a rewrite is a no-op.

    Xcode emits `"key" : value`; a file written by another tool may use the
    compact `"key": value`. Keep whichever the file on disk uses, and its
    trailing newline (or lack of one)."""
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    colon = " : " if '" : ' in text else ": "
    return colon, "\n" if text.endswith("\n") else ""


def dump_catalog(data: dict, style: tuple[str, str]) -> str:
    colon, tail = style
    return json.dumps(data, indent=2, sort_keys=True,
                      ensure_ascii=False, separators=(",", colon)) + tail

# ------------------------------------------------------- unit encode / decode
# A "unit node" is anything holding stringUnit / variations / substitutions:
# a localization, a variation case, or the body of a substitution.

def encode_unit(node: dict) -> object:
    out: dict = {}
    unit = node.get("stringUnit")
    if unit is not None:
        out["value"] = unit["value"]
        if unit.get("state") != "translated":
            out["state"] = unit.get("state")
    if "variations" in node:
        out["variations"] = {
            kind: {case: encode_unit(body) for case, body in cases.items()}
            for kind, cases in node["variations"].items()
        }
    if "substitutions" in node:
        subs = {}
        for name, sub in node["substitutions"].items():
            body = encode_unit({k: v for k, v in sub.items()
                                if k in ("stringUnit", "variations", "substitutions")})
            if not isinstance(body, dict):
                body = {"value": body}
            entry = {k: v for k, v in sub.items()
                     if k not in ("stringUnit", "variations", "substitutions")}
            entry.update(body)
            subs[name] = entry
        out["substitutions"] = subs
    # the common case — a plain translated string — stays a bare string
    if list(out) == ["value"]:
        return out["value"]
    return out


def decode_unit(node: object) -> dict:
    if isinstance(node, str):
        return {"stringUnit": {"state": "translated", "value": node}}
    out: dict = {}
    if "value" in node:
        out["stringUnit"] = {"state": node.get("state", "translated"),
                             "value": node["value"]}
    if "variations" in node:
        out["variations"] = {
            kind: {case: decode_unit(body) for case, body in cases.items()}
            for kind, cases in node["variations"].items()
        }
    if "substitutions" in node:
        subs = {}
        for name, entry in node["substitutions"].items():
            body = decode_unit({k: v for k, v in entry.items()
                                if k in ("value", "state", "variations", "substitutions")})
            meta = {k: v for k, v in entry.items()
                    if k not in ("value", "state", "variations", "substitutions")}
            subs[name] = {**meta, **body}
        out["substitutions"] = subs
    return out


def encode_catalog(path: Path) -> dict:
    cat = json.loads(path.read_text(encoding="utf-8"))
    keys = {}
    for key, entry in cat["strings"].items():
        out = {}
        if "comment" in entry:
            out["comment"] = entry["comment"]
        if "extractionState" in entry:
            out["extractionState"] = entry["extractionState"]
        out["translations"] = {lang: encode_unit(loc)
                               for lang, loc in entry.get("localizations", {}).items()}
        keys[key] = out
    return {"path": str(path.relative_to(ROOT)),
            "sourceLanguage": cat.get("sourceLanguage", "en"),
            "version": cat.get("version", "1.0"),
            "keys": keys}


def decode_catalog(table: dict) -> dict:
    strings = {}
    for key, entry in table["keys"].items():
        out = {}
        if "comment" in entry:
            out["comment"] = entry["comment"]
        if "extractionState" in entry:
            out["extractionState"] = entry["extractionState"]
        out["localizations"] = {lang: decode_unit(node)
                                for lang, node in entry["translations"].items()}
        strings[key] = out
    return {"sourceLanguage": table["sourceLanguage"],
            "strings": strings,
            "version": table["version"]}

# ------------------------------------------------------------------- metadata

def metadata_files() -> list[Path]:
    files = sorted((METADATA / "app-info").glob("*.json"))
    for version_dir in sorted((METADATA / "version").iterdir()):
        if version_dir.is_dir():
            files += sorted(version_dir.glob("*.json"))
    return files


def encode_metadata() -> dict:
    """One entry per canonical metadata file, key order and all."""
    scopes: dict = {}
    for path in metadata_files():
        rel = path.relative_to(METADATA)
        scope = "app-info" if rel.parts[0] == "app-info" else f"version/{rel.parts[1]}"
        scopes.setdefault(scope, {})[path.stem] = json.loads(
            path.read_text(encoding="utf-8"))
    return {"path": str(METADATA.relative_to(ROOT)), "scopes": scopes}


def dump_metadata_file(payload: dict) -> str:
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def metadata_targets(meta: dict) -> list[tuple[Path, str]]:
    out = []
    for scope, locales in meta["scopes"].items():
        for locale, payload in locales.items():
            out.append((METADATA / scope / f"{locale}.json",
                        dump_metadata_file(payload)))
    return out

# --------------------------------------------------------------- source mirrors

PROMPT_RE = re.compile(r'^\s{8}(NS\w*UsageDescription)\s*:\s*"(.*)"\s*$')


def read_project_prompts() -> dict:
    prompts = {}
    for line in PROJECT_YML.read_text(encoding="utf-8").splitlines():
        m = PROMPT_RE.match(line)
        if m:
            prompts[m.group(1)] = m.group(2)
    return prompts


def read_koubou_variables() -> dict:
    import yaml
    config = yaml.safe_load(KOUBOU_CONFIG.read_text(encoding="utf-8"))
    return {card: dict(spec.get("variables", {}))
            for card, spec in config.get("screenshots", {}).items()}


def encode_mirrors() -> dict:
    return {
        "note": "English text duplicated outside a catalog. `import` checks these "
                "and never edits the YAML; fix a divergence by hand.",
        "project.yml": {
            "note": "XcodeGen writes these into the generated Info.plist, but iOS "
                    "reads InfoPlist.xcstrings' `en` unit — keep both in step.",
            "strings": read_project_prompts(),
        },
        "screenshots/koubou/config.yaml": {
            "note": "Each value is a key of the Koubou catalog.",
            "cards": read_koubou_variables(),
        },
    }


def check_mirrors(data: dict) -> bool:
    ok = True
    mirrors = data.get("sourceMirrors", {})
    for key, value in mirrors.get("project.yml", {}).get("strings", {}).items():
        if read_project_prompts().get(key) != value:
            print(f"warning: {key} differs from project.yml — edit it by hand",
                  file=sys.stderr)
            ok = False
    catalog_keys = set(data["tables"]["Koubou"]["keys"])
    for card, variables in mirrors.get("screenshots/koubou/config.yaml",
                                       {}).get("cards", {}).items():
        for name, value in variables.items():
            if value != read_koubou_variables().get(card, {}).get(name):
                print(f"warning: {card}.{name} differs from config.yaml",
                      file=sys.stderr)
                ok = False
            elif value not in catalog_keys:
                print(f"warning: {card}.{name} is not a key of the Koubou catalog",
                      file=sys.stderr)
                ok = False
    return ok

# ------------------------------------------------------------------ commands

def build_export() -> dict:
    tables = {name: encode_catalog(path) for name, path in CATALOGS.items()}
    seen = {lang for t in tables.values()
            for k in t["keys"].values() for lang in k["translations"]}
    languages = {
        "catalog": sorted(seen & set(LOCALE_MAP)),
        "appStoreConnect": sorted(seen & set(LOCALE_MAP.values())),
    }
    return {
        "generatedBy": "scripts/i18n.py export",
        "languages": languages,
        "localeMap": LOCALE_MAP,
        "sourceMirrors": encode_mirrors(),
        "tables": tables,
        "metadata": encode_metadata(),
    }


def cmd_export(args) -> int:
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    data = build_export()
    out.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    keys = sum(len(t["keys"]) for t in data["tables"].values())
    units = sum(len(k["translations"])
                for t in data["tables"].values() for k in t["keys"].values())
    fields = sum(len(p) for s in data["metadata"]["scopes"].values()
                 for p in s.values())
    print(f"{out.relative_to(ROOT)}: {keys} catalog keys, {units} localizations, "
          f"{fields} metadata fields, "
          f"{len(data['languages']['catalog'])} languages")
    return 0


def cmd_import(args) -> int:
    data = json.loads(Path(args.input).read_text(encoding="utf-8"))
    for name, table in data["tables"].items():
        path = ROOT / table["path"]
        path.write_text(dump_catalog(decode_catalog(table), catalog_style(path)),
                        encoding="utf-8")
        print(f"wrote {table['path']} ({len(table['keys'])} keys)")
    for path, text in metadata_targets(data["metadata"]):
        path.write_text(text, encoding="utf-8")
    print(f"wrote {len(metadata_targets(data['metadata']))} files "
          f"under {data['metadata']['path']}/")
    return 0 if check_mirrors(data) else 1


def cmd_check(args) -> int:
    data = build_export()
    ok = check_mirrors(data)
    for name, table in data["tables"].items():
        path = ROOT / table["path"]
        after = dump_catalog(decode_catalog(table), catalog_style(path))
        if path.read_text(encoding="utf-8") == after:
            print(f"{table['path']}: byte-identical round trip")
        else:
            ok = False
            print(f"{table['path']}: MISMATCH", file=sys.stderr)
    bad = [p for p, text in metadata_targets(data["metadata"])
           if p.read_text(encoding="utf-8") != text]
    if bad:
        ok = False
        for p in bad:
            print(f"{p.relative_to(ROOT)}: MISMATCH", file=sys.stderr)
    else:
        print(f"metadata/: byte-identical round trip "
              f"({len(metadata_targets(data['metadata']))} files)")
    return 0 if ok else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export"); e.add_argument("-o", "--output", default=str(DEFAULT_JSON)); e.set_defaults(func=cmd_export)
    i = sub.add_parser("import"); i.add_argument("-i", "--input", default=str(DEFAULT_JSON)); i.set_defaults(func=cmd_import)
    c = sub.add_parser("check"); c.set_defaults(func=cmd_check)
    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
