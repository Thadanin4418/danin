# Release Template

## Release Name

- Version: `vX.Y.Z`
- Date: `YYYY-MM-DD`

## Summary

One short paragraph that explains what changed in this release.

## Highlights

- Highlight 1
- Highlight 2
- Highlight 3

## Included Areas

- `soranin-ios/`
- `ReelsNativeApp/`
- `scripts/`
- `extension/`

## Main Changes

### Added

- Item

### Changed

- Item

### Fixed

- Item

## Important Notes

- Note about build output, paths, or migration
- Note about compatibility or required setup

## Recommended Entry Points

- `ReelsNativeApp/App.swift`
- `ReelsNativeApp/build_native_app.sh`
- `scripts/reels_dashboard_server.py`
- `soranin-ios/soranin/ContentView.swift`
- `soranin-ios/soranin/SoraDownloadViewModel.swift`

## Verification

- `python3 -m py_compile scripts/*.py`
- `./ReelsNativeApp/build_native_app.sh`
- `xcodebuild -project soranin-ios/soranin.xcodeproj -scheme soranin -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

## Links

- GitHub repo:
- Release zip:
- Changelog:
- Release notes:
