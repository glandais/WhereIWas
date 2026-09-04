---
name: i18n
description: Read and write every translation of WhereIWas through i18n/translations.json, the single source of truth aggregating the three string catalogs and the App Store metadata in nine languages. Use when adding, changing, reviewing, auditing or translating a user-visible string, a permission prompt, a screenshot headline or a store listing — and before hand-editing any .xcstrings or metadata/*.json.
---

# Translations

**`i18n/translations.json` is the source of truth.** Everything the user can read, in nine
languages, lives in that one file; the catalogs and the metadata files are generated from it.
Edit the JSON, run `import`, commit both sides.

```bash
./scripts/i18n.py export    # sources  -> i18n/translations.json
./scripts/i18n.py import    # JSON     -> sources
./scripts/i18n.py check     # round trip is byte-exact, mirrors agree
```

The mapping is bijective, and `check` proves it on every run: an `import` straight after an
`export` rewrites all 21 generated files byte for byte, key order, plural variations,
substitutions, comments, extraction states and formatting included. If `check` ever fails, the
JSON and the sources have diverged — resolve it before doing anything else, because the next
`import` silently wins.

| Generated file | Contents | Locale codes |
|---|---|---|
| `WhereIWas/Resources/Localizable.xcstrings` | the app UI, 284 keys | `fr`, `de`, `nl`, … |
| `WhereIWas/Resources/InfoPlist.xcstrings` | the three permission prompts | `fr`, `de`, `nl`, … |
| `screenshots/koubou/koubou-strings.xcstrings` | the five screenshot cards, 10 lines | `fr-FR`, `de-DE`, … |
| `metadata/app-info/<locale>.json` | store name, subtitle, privacy URL | `fr-FR`, `de-DE`, … |
| `metadata/version/1.0.0/<locale>.json` | description, keywords, promotional text | `fr-FR`, `de-DE`, … |

The two namespaces are real, not an inconsistency: the app uses short language codes, App Store
Connect has its own codes for the same nine languages. `localeMap` in the JSON maps one onto the
other. Never normalise them — it would break the bijection and the upload.

## The loop

A new UI string enters through the **code**, not through the JSON: `xcstringstool` is what
discovers `String(localized:)` call sites, and it only writes into `Localizable.xcstrings`.

```bash
# 1. add Text("status.lastFix.title") … in the code
./scripts/xcb.sh strings     # extracts the new keys into Localizable.xcstrings
./scripts/i18n.py export     # pulls them into i18n/translations.json
# 2. fill the `en` unit and the eight others in i18n/translations.json
./scripts/i18n.py import
./scripts/xcb.sh build       # or test
```

Everything else — the permission prompts, the Koubou headlines, the store metadata — has no
extraction step: those three catalogs are `manual`, so a key is born in the JSON and `import`
creates it. `import` is authoritative for the **key set** too: a key deleted from the JSON
disappears from the catalog, which is exactly how a `stale` key is retired, and also how a live
string gets destroyed. Delete only what `xcb.sh strings` marked stale.

**Do not hand-edit a generated file.** The edit survives until the next `import`, which is the
worst possible failure mode: it works when you test it and is gone when someone else runs the
pipeline. If you already did, run `export` immediately to capture it, then `check`.

## Shape of an entry

The common case is a bare string, so a diff of a translation pass reads as prose:

```jsonc
"accuracy.best": { "translations": { "fr": "Maximale", "ja": "最高" } }
```

It grows only where the language needs it:

```jsonc
// plural variations — the categories are the target language's, not English's
"audit.count.events": { "translations": { "pl": { "variations": { "plural": {
  "one": "%lld zdarzenie audytu", "few": "…", "many": "…", "other": "…" } } } } },

// substitutions — two counts in one sentence, each pluralised on its own
"audit.list.counts": { "translations": { "fr": {
  "value": "%#@shown@ · %#@stored@",
  "substitutions": { "shown": { "argNum": 1, "formatSpecifier": "lld",
    "variations": { "plural": { "one": "%arg affiché", "other": "%arg affichés" } } } } } } },

// a unit whose state is not `translated` keeps it explicit
"…": { "extractionState": "extracted_with_value",
       "translations": { "en": { "value": "skipped", "state": "new" } } }
```

`extractionState` and a `state` other than `translated` are `xcstringstool` bookkeeping. Copy
them around, never normalise them by hand — CLAUDE.md explains why the catalog legitimately mixes
keys that carry a state with keys that do not.

## sourceMirrors — the English texts that live twice

Two English strings exist outside a catalog, and `import` **checks** them rather than writing
them (it exits 1 on a divergence, and never edits YAML):

- `project.yml` holds the three `NS*UsageDescription` prompts, which XcodeGen writes into the
  generated `Info.plist`. iOS reads the catalog's `en` unit instead, so the two must agree —
  a mismatch is invisible until a reviewer reads one and a user sees the other.
- `screenshots/koubou/config.yaml` holds each card's `headline` and `subtitle`, and those values
  **are** the keys of the Koubou catalog. Rewording a headline therefore means editing the YAML
  *and* renaming the key in the JSON, in the same commit; `check` catches half a rename.

Edit either file by hand, then `export` to bring the mirror back in step.

## Rules that outlive this file

CLAUDE.md § Localization is authoritative on *what* to write: dotted keys rather than English
sentences, no key shared between two subjects, plural variations in every locale including
English, iOS control names matching what iOS itself displays word for word, short keys kept near
the English length because German and Czech truncate first, and the audit trail persisting codes
plus arguments rather than prose. Read it before writing a string; this skill only covers the
plumbing.

## After a change

- **App strings** — `./scripts/xcb.sh build`, then read a screen in a long language:
  `xcrun simctl launch "$(source scripts/sim-config.sh && sim_udid)" io.github.glandais.whereiwas -AppleLanguages "(de)" -AppleLocale de_DE`
- **Audit vocabulary** — `AuditSummaryTests` fails on an event code with no sentence; run
  `./scripts/xcb.sh test`.
- **Screenshot headlines** — the cards have to be reframed and re-uploaded: see the
  `screenshots-release` skill. Changing a card's copy alone skips the capture stage.
- **Store metadata** — `asc metadata validate --dir ./metadata`, then the plan/approve/apply
  cycle in CLAUDE.md § Release. `asc` reads `metadata/`, never the JSON, so `import` first.

## Auditing without trusting the tooling

The `.stringsdata` files under `.build/DerivedData` are plain JSON with a
`tables.Localizable[].key` array; their union must equal the key set of the `Localizable` table
in the JSON. That is the check that catches a key which left the code without leaving the
catalog — `xcstringstool sync` is the thing being audited, so do not audit it with itself.
