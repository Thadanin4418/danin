# Soranin Control Suite

Clean Git repo for the current `soranin` iOS app, the Mac `Soranin.app` source, and the Facebook/Mac control scripts.

## Included

- `soranin-ios/`
- `ReelsNativeApp/`
- `scripts/`
- `extension/`
- `CHANGELOG.md`
- `RELEASE_NOTES.md`
- `RELEASE_TEMPLATE.md`
- `START_CONTROL_MAC.command`
- `IOS_MAC_CONTROL.md`

## Current purpose

- iPhone `Control Mac` popup can send Facebook post jobs to the Mac control server
- `Scan Mac` works on the same Wi-Fi, and `Tailscale URL` can be used for remote control from another network
- Mac `Soranin.app` can build and run the Facebook runner
- Mac app now starts the local control server automatically

## Important note

This repo is a clean source snapshot of the live setup.

The runtime is now more flexible than before:

- scripts resolve paths from the repo location
- the Mac app bundles runtime path hints during build
- Facebook/data folders can be overridden with environment variables
- legacy fallback still works for the old Downloads-based layout

That means this repo is much easier to move than before, but you should still rebuild the Mac app after moving the repo to a different machine or folder.

## Main files

- `ReelsNativeApp/App.swift`
- `ReelsNativeApp/build_native_app.sh`
- `soranin-ios/soranin/ContentView.swift`
- `soranin-ios/soranin/SoraDownloadViewModel.swift`
- `scripts/reels_dashboard_server.py`
- `scripts/fb_reels_batch_upload.py`
- `scripts/publish_github_release.py`
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
- if Mac and iPhone are on the same Wi-Fi, tap `Scan Mac`
- if you are on a different Wi-Fi or cellular, paste the `Tailscale URL` from `Soranin.app`
- or set `Server URL` to your Mac address manually
- example:
  - `http://192.168.1.8:8765`
- choose:
  - `Chrome Name`
  - `Page`
  - `Folders`
- run:
  - `Preflight`
  - or `Run Facebook Post`

### 5. Simplest launcher

For the cleanest Mac + iPhone control flow, use:

```bash
./START_CONTROL_MAC.command
```

More details:

- `IOS_MAC_CONTROL.md`

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

Default behavior:

- the Mac app build goes to `~/Desktop/Soranin.app`
- runtime state defaults to `~/.soranin/`
- package folders prefer a sibling `Soranin/` folder if it exists
- otherwise package folders fall back to `~/.soranin/Soranin`

## Environment overrides

You can change the default locations without editing the code:

- `SORANIN_CONTROL_SUITE_DIR`
  - override the repo root used by the scripts/app
- `SORANIN_SCRIPTS_DIR`
  - override the scripts folder path
- `SORANIN_PACKAGES_ROOT`
  - override the Facebook/Sora package folder root
- `SORANIN_ROOT_DIR`
  - same purpose as `SORANIN_PACKAGES_ROOT`
- `SORANIN_RUNTIME_DIR`
  - override runtime state storage such as history and controller state
- `SORANIN_API_KEYS_FILE`
  - override where API keys are stored
- `SORANIN_APP_DIR`
  - override where `Soranin.app` is built

Example:

```bash
export SORANIN_CONTROL_SUITE_DIR="$HOME/Work/SoraninControlSuite"
export SORANIN_PACKAGES_ROOT="$HOME/Work/SoraninData"
export SORANIN_RUNTIME_DIR="$HOME/.soranin"
```

This repo is good for:

- Git backup
- GitHub sync
- source editing
- moving between machines with lighter reconfiguration

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
- `scripts/publish_github_release.py`
  - builds a release zip, pushes a tag, and publishes a GitHub release
