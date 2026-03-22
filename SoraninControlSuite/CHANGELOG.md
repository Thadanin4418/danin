# Changelog

## 2026-03-22

### Added

- Added `Control Mac` Facebook posting popup flow in the iPhone `soranin` app.
- Added Mac-side Facebook control endpoints in `scripts/reels_dashboard_server.py`.
- Added auto-start for the local control server inside the Mac `Soranin.app`.
- Added the browser extension source into this repo under `extension/`.
- Added full `soranin-ios/soranin/` source files into Git tracking.
- Added `scripts/soranin_paths.py` to centralize runtime path resolution.

### Changed

- Updated `ReelsNativeApp/App.swift` to load runtime paths from bundled config and environment overrides.
- Updated `ReelsNativeApp/build_native_app.sh` to emit `runtime_paths.json` during Mac app build.
- Updated Facebook upload scripts to use shared path helpers instead of fixed `/Users/nin/Downloads/...` paths.
- Updated `README.md` with setup instructions, environment overrides, and repo layout guidance.
- Updated root GitHub repo layout so the legacy project stays at repo root and `SoraninControlSuite/` remains separate.

### Fixed

- Fixed `.gitignore` so `soranin-ios/soranin/` source files are no longer ignored by mistake.
- Fixed path handling so the suite is easier to move to another folder or another Mac.
- Fixed GitHub organization so both the old project and new Soranin suite can live in the same repository without overwriting each other.
