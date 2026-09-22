# App Review notes (version 1.0.0)

Canonical copy of the App Review Information → Notes field. `asc metadata` does not manage review
details, so this file is the source and gets pushed by hand:

```bash
asc review details-for-version --version-id "<VERSION_ID>"        # read, and get the detail id
asc review details-update --id "<DETAIL_ID>" --notes "$(cat metadata/review-notes.md | sed -n '/^---$/,$p' | tail -n +2)"
```

Keep it true to the code. The 2.5.4 paragraph describes what the app actually does with the
background location indicator, and a reviewer reads it with the app open.

---

WhereIWas is an offline location logger. It records a GPS history on the device and never sends it anywhere.

WHY BACKGROUND LOCATION (guideline 2.5.4)
The entire purpose of the app is to keep an unbroken record of where the user has been across a long day, a trip or several days away, with the screen off and the app in the background. When-In-Use is not enough: a CLBackgroundActivitySession can only be started while the app is in the foreground, so once iOS terminates the app in the background (memory pressure) or the device restarts, only significant location changes and visits can bring it back, and relaunching an app for those events requires Always authorization. With When-In-Use the record would stop for good at the first termination, until the user reopens the app. The app therefore asks for Always. For as long as tracking is on, it holds a CLBackgroundActivitySession and keeps showsBackgroundLocationIndicator set, so the blue location indicator is visible the whole time, including while the GPS receiver is off between movements. There is no setting to hide it.

To keep the battery cost down, GPS is not left running. The app listens to CoreMotion activity, significant location changes and visits, all of which are low power, and turns the receiver on only once there is evidence of movement. After two minutes of stillness it keeps a rationed receiver (50 m distance filter) for up to five more minutes, to catch a quick departure, then switches it off; while stationary no location updates run at all, and the next movement, significant change or visit brings the receiver back. The Status screen shows what is running at any moment.

PERMISSIONS (guideline 5.1.1)
Opening the app shows no permission prompt. On a fresh install the Status screen has a "Setup" section with two cards, "Location access" and "Motion activity", each explaining what the permission is for and ending in a single "Continue" button. Each button triggers only its own system prompt. Both are optional: declining keeps the Map, Export and Settings screens usable, the app never asks again, and a card then offers "Open Settings". Turning on "Record my location" before answering shows the location and Motion & Fitness prompts at that moment, since recording needs both. Settings → Permissions shows the same state and a "Continue" row; Settings → About links to the website, the support page, the privacy policy, the source code on GitHub, the App Store review page and the developer's other apps; each row only opens the URL in Safari or the App Store, the app itself makes no request.

HOW TO TEST
1. No account is needed. On the Status screen, tap Continue on the "Location access" card and allow location (choose Always when iOS offers it), then tap Continue on the "Motion activity" card and allow Motion & Fitness.
2. Turn on "Record my location" on the Status screen.
3. Walk or drive for a few minutes. The Status screen moves to Moving and shows the GPS profile in force; the Map tab draws the track.
4. Optional: turn on the audit trail in Settings to see every decision the app made, including why individual fixes were rejected.
Please note that CoreMotion activity, background relaunch and visits do not work in the Simulator. A physical device is needed to observe the battery-saving behaviour.

PRIVACY
No account, no server, no analytics, no advertising, no third-party SDKs. The app contains no networking code. Location history is stored in a local database and leaves the device only when the user exports it themselves as GPX or JSON through the share sheet. The Map screen draws Apple Maps tiles via MapKit, a system framework, which is the only third party involved.

IN-APP PURCHASES
Settings → About → Support the developer offers three optional consumable tips (io.github.glandais.whereiwas.tip.small, .medium, .large). They unlock no content or feature; the app just says thank you. There is no external tip or donation link in the app.
