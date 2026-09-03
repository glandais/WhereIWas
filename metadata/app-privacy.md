# App Privacy declaration

`app-privacy.json` is the canonical nutrition-label declaration for
`io.github.glandais.whereiwas`. An empty `dataUsages` array declares **Data Not
Collected** across every category. The file has to stay schema-clean (`asc web
privacy` rejects unknown keys, including comments), so the reasoning lives here.

## Why "not collected"

Apple's definition, from the App Store Connect questionnaire: collecting means
transferring data off a device so that you or a third party can access it for
longer than needed to service the request in real time.

The app reads precise location, motion activity and battery state, filters them
and writes them to a local SwiftData database. Nothing is transferred:

- no networking code in the target — no `URLSession`, no sockets;
- no account, no server, no analytics, no advertising;
- no third-party SDK, and no package dependencies at all in `project.yml`;
- `requiresNetworkConnectivity = false` on the background maintenance task.

Exports are started by the user, to a destination the user picks in the share
sheet. That is a user action, not developer collection. Apple Maps tiles on the
Map screen are drawn by MapKit, a system framework: Apple learns which area is
displayed, which the privacy policy states plainly, but that is not developer
collection either.

## When this must be revisited

`ARCHITECTURE.md` reserves `pendingUpload(limit:)` and `markUploaded(sequences:)`
for a future upload layer. **The day that layer ships, this declaration becomes
false.** Precise location would then be collected, and Apple can pull an app
whose labels no longer match. Re-do the questionnaire before shipping any
version that transmits samples — same for adding analytics, a crash reporter, or
any SDK.

## Applying

```bash
asc web privacy plan    --app 6808349924 --file metadata/app-privacy.json
asc web privacy apply   --app 6808349924 --file metadata/app-privacy.json --allow-deletes --confirm
asc web privacy publish --app 6808349924 --confirm
```

These need a web session (`asc web auth login`), not the API key.
