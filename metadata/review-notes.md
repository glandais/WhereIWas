# App Review notes (version 1.0.0)

Canonical copy of the App Review Information → Notes field. `asc metadata` does not manage review
details, so this file is the source and gets pushed by hand:

```bash
asc review details-for-version --version-id "<VERSION_ID>"        # read, and get the detail id
asc review details-update --id "<DETAIL_ID>" --notes "$(cat metadata/review-notes.md | sed -n '/^---$/,$p' | tail -n +2)"
```

Keep it true to the code. The 2.5.4 paragraph describes what the app actually does with the
background location indicator, and a reviewer who opens Settings will see the switch it mentions.

---

WhereIWas is an offline location logger. It records a GPS history on the device and never sends it anywhere.

WHY BACKGROUND LOCATION (guideline 2.5.4)
The entire purpose of the app is to keep an unbroken record of where the user has been across a long shift or a multi-day trip, with the screen off and the app in the background. This cannot work with When-In-Use: iOS stops delivering updates as soon as the app is suspended. The app therefore requests Always authorization and holds a CLBackgroundActivitySession for as long as the GPS receiver is running, so the blue indicator is visible for every second of actual recording.

To keep the battery cost down, GPS is not left running. The app listens to CoreMotion activity, significant location changes and visits, all of which are low power, and turns the receiver on only once there is evidence of movement, then off again after two minutes of stillness. The Status screen shows what is running at any moment.

ABOUT THE "SHOW LOCATION INDICATOR" SETTING
While the app is stationary the GPS receiver is off and no track is being written. It keeps a 3 km-accuracy update stream open, which costs almost no power and is what lets iOS keep the process alive between movements; the only points stored in that state are the occasional coarse ones — a significant change or a visit, kilometres apart — recorded with their source, so they are distinguishable from GPS fixes in the export. That stream also lights the blue indicator while no track is being recorded. Settings therefore has a "Show location indicator" switch, on by default. Turning it off clears showsBackgroundLocationIndicator, which in practice only affects that idle case. It cannot hide recording: the CLBackgroundActivitySession held while the receiver is on shows the indicator whatever the switch says, and the Status screen names which of the two situations the app is in — "Stationary (coarse)" when it is only keeping the process alive, or the GPS profile in force when it is recording.

HOW TO TEST
1. No account is needed. Open the app, allow location (choose Always when iOS offers it) and allow Motion & Fitness.
2. Turn on "Record my location" on the Status screen.
3. Walk or drive for a few minutes. The Status screen moves to Moving and shows the GPS profile in force; the Map tab draws the track.
4. Optional: turn on the audit trail in Settings to see every decision the app made, including why individual fixes were rejected.
Please note that CoreMotion activity, background relaunch and visits do not work in the Simulator. A physical device is needed to observe the battery-saving behaviour.

PRIVACY
No account, no server, no analytics, no advertising, no third-party SDKs. The app contains no networking code. Location history is stored in a local database and leaves the device only when the user exports it themselves as GPX or JSON through the share sheet. The Map screen draws Apple Maps tiles via MapKit, a system framework, which is the only third party involved.
