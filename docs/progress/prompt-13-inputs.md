# Prompt 13 inputs (owner decisions, 14 Nov 2026)

Build into Prompt 13 (TestFlight prep), see docs/DECISIONS.md "Location tracking on iPhone":
1. Replace the paid tracker with a `GeolocatorTracker` implementing `LocationTracker`
   (AppleSettings: bestForNavigation, automotiveNavigation, distanceFilter 15,
   pauseLocationUpdatesAutomatically false, allowBackgroundLocationUpdates true,
   showBackgroundLocationIndicator true). Keep the paid one in code but not wired, or remove
   the dependency if it blocks the iOS release build without a licence.
2. Driver location gate: full-screen blocking sheet before starting a run (service on,
   permission whileInUse/always, accuracy precise, notifications allowed); steps + Open Settings;
   re-check on app resume. Banner for other parents. Widget + golden tests AR/EN.
3. Mid-run monitoring: service status stream + permission/accuracy re-check on resume.
4. Server: no point for 2 min during an active run → FCM to driver + existing parents alert.
   Functions tests.
5. Info.plist: UIBackgroundModes location; localized NSLocationWhenInUseUsageDescription
   (InfoPlist.strings ar/en) via tool/patch_native.py.
6. Run screen hint: "Keep the app open, you can lock the phone." (one line, AR/EN).
7. docs/app-review-notes.md: background location explanation + recording steps for owner.
