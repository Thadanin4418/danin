# Release Notes

## Soranin Control Suite
## 2026-03-22

This release packages the current Mac, iPhone, script, and extension work into one Git-backed suite.

### Highlights

- iPhone `Control Mac` can send Facebook post jobs to the Mac controller.
- Mac `Soranin.app` can auto-start the local controller server.
- GitHub now contains both:
  - the existing root project
  - the new `SoraninControlSuite/` folder
- The suite now supports environment-based path overrides, making it easier to move or reuse on another machine.

### Included in this release

- `soranin-ios/`
- `ReelsNativeApp/`
- `scripts/`
- `extension/`

### Recommended entry points

- Mac app source: `ReelsNativeApp/App.swift`
- Mac build script: `ReelsNativeApp/build_native_app.sh`
- iPhone control popup: `soranin-ios/soranin/ContentView.swift`
- iPhone Mac-control networking: `soranin-ios/soranin/SoraDownloadViewModel.swift`
- Local controller server: `scripts/reels_dashboard_server.py`

### Notes

- Build output still defaults to `~/Desktop/Soranin.app`.
- Runtime state still defaults to `~/.soranin/`.
- If a sibling `Soranin/` folder exists, the suite prefers it as the package root.

### Next useful steps

- Add a `CHANGELOG` entry for each new release.
- Continue reducing remaining legacy assumptions in app copy and docs.
- Prepare a tagged GitHub release if you want downloadable release history online.
