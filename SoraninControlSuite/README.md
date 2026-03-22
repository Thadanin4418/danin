# Soranin Control Suite

Clean Git repo for the current `soranin` iOS app, the Mac `Soranin.app` source, and the Facebook/Mac control scripts.

## Included

- `soranin-ios/`
- `ReelsNativeApp/`
- `scripts/`
- `extension/`

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
- `extension/manifest.json`

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

## Recommended setup

### 1. Build the Mac app

From `SoraninControlSuite/`:

```bash
./ReelsNativeApp/build_native_app.sh
```

This builds:

- `/Users/nin/Desktop/Soranin.app`

### 2. Open the Mac app

Open:

- `/Users/nin/Desktop/Soranin.app`

The Mac app now auto-starts the local Facebook control server for the `Facebook Runner` flow.

Default local server:

- `http://127.0.0.1:8765`

Health check:

- `http://127.0.0.1:8765/status`

### 3. Build the iPhone app

Open:

- `soranin-ios/soranin.xcodeproj`

Then run the `soranin` scheme on your iPhone or simulator.

### 4. Use Control Mac on iPhone

Inside the iPhone app:

- tap `Control Mac`
- set `Server URL` to your Mac address
- example:
  - `http://192.168.1.8:8765`
- choose:
  - `Chrome Name`
  - `Page`
  - `Folders`
- run:
  - `Preflight`
  - or `Run Facebook Post`

## Main workflow

### Mac side

- `Soranin.app` opens and manages the Facebook runner
- Chrome automation runs on the Mac
- the local controller server receives jobs from iPhone

### iPhone side

- the `Control Mac` popup sends commands to the Mac
- you can trigger Facebook posting remotely
- the popup can load Mac profiles before sending a job

## Important runtime paths

Right now some parts still use live-machine paths such as:

- `/Users/nin/Downloads/reels_dashboard_server.py`
- `/Users/nin/Desktop/Soranin.app`
- `/Users/nin/Downloads/ReelsNativeApp/App.swift`

So the current repo is good for:

- Git backup
- GitHub sync
- source editing

But if you move this repo to another Mac or another folder, those paths should be updated next.

## Useful files

- `ReelsNativeApp/App.swift`
  - Mac app UI and auto-start server logic
- `scripts/reels_dashboard_server.py`
  - local HTTP controller used by the iPhone app
- `scripts/fb_reels_batch_upload.py`
  - batch Facebook upload runner
- `scripts/fb_reels_step3_upload_video_and_next.py`
  - upload flow and page-switch logic
- `scripts/fb_reels_step6_schedule_or_post.py`
  - schedule/post logic
- `soranin-ios/soranin/ContentView.swift`
  - iPhone `Control Mac` popup UI
- `soranin-ios/soranin/SoraDownloadViewModel.swift`
  - iPhone networking for Mac control
