# Soranin Control Suite

Clean Git repo for the current `soranin` iOS app, the Mac `Soranin.app` source, and the Facebook/Mac control scripts.

## Included

- `soranin-ios/`
- `ReelsNativeApp/`
- `scripts/`

## Current purpose

- iPhone `Control Mac` popup can send Facebook post jobs to the Mac control server
- Mac `Soranin.app` can build and run the Facebook runner
- Mac app now starts the local control server automatically

## Important note

This repo is a clean source snapshot of the live setup.

Some runtime paths in the code still point to the current live machine layout under:

- `/Users/nin/Downloads/...`
- `/Users/nin/Desktop/Soranin.app`

That means this repo is ready for Git/history/backup now, but if you move it to another machine or another folder, the hardcoded paths should be normalized next.

## Main files

- `ReelsNativeApp/App.swift`
- `ReelsNativeApp/build_native_app.sh`
- `soranin-ios/soranin/ContentView.swift`
- `soranin-ios/soranin/SoraDownloadViewModel.swift`
- `scripts/reels_dashboard_server.py`
- `scripts/fb_reels_batch_upload.py`

## Quick build

### iOS

```bash
xcodebuild -project soranin-ios/soranin.xcodeproj -scheme soranin -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

### Mac app

```bash
./ReelsNativeApp/build_native_app.sh
```

### Mac control server

```bash
python3 scripts/reels_dashboard_server.py
```
