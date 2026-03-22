# danin

This repository now contains two active code areas:

## 1. Existing root tools

The original project remains at the repository root and still works as before.

Main files:

- `server.mjs`
- `admin.mjs`
- `manager-panel.html`
- `buy-panel.html`
- `facebook_video_downloader.py`
- `facebook_short_url_resolve.py`

Legacy documentation is still available in:

- `README.txt`

## 2. SoraninControlSuite

The newer Soranin control stack is kept in its own folder so it does not break the existing root project.

Folder:

- `SoraninControlSuite/`

Inside it:

- `SoraninControlSuite/soranin-ios/`
  - iOS app source
- `SoraninControlSuite/ReelsNativeApp/`
  - native macOS app source
- `SoraninControlSuite/scripts/`
  - Facebook upload automation and controller scripts
- `SoraninControlSuite/extension/`
  - browser extension source

## Quick start

If you want the older server/downloader project, stay at the repository root.

If you want the newer Soranin app and Mac/iOS control tools, go into:

- `SoraninControlSuite/`

Then see:

- `SoraninControlSuite/README.md`
