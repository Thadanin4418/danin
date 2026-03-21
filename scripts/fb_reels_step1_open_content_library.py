#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


DEFAULT_PACKAGE = Path("/Users/nin/Downloads/Soranin/64_Reels_Package")
TARGET_URL = "https://web.facebook.com/professional_dashboard/content/content_library"
VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".avi", ".mkv"}
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Step 1 for Facebook Reels upload: reuse the already-open Chrome and open Content Library."
    )
    parser.add_argument(
        "package_dir",
        nargs="?",
        default=str(DEFAULT_PACKAGE),
        help="Path to the numbered Reels package folder.",
    )
    parser.add_argument(
        "--url",
        default=TARGET_URL,
        help="Target Facebook URL to open in the existing Chrome session.",
    )
    parser.add_argument(
        "--reuse-active-tab",
        action="store_true",
        help="Navigate the active tab instead of opening a new tab in the current Chrome window.",
    )
    return parser.parse_args()


def pick_first_file(folder: Path, allowed_extensions: set[str]) -> Path | None:
    candidates = [
        path
        for path in sorted(folder.iterdir())
        if path.is_file() and path.suffix.lower() in allowed_extensions
    ]
    return candidates[0] if candidates else None


def resolve_assets(package_dir: Path) -> dict[str, str | None]:
    video_path = package_dir / "edited_reel_9x16_hd_0.90x_15s.mp4"
    if not video_path.exists():
        video_path = pick_first_file(package_dir, VIDEO_EXTENSIONS)

    thumbnail_path = package_dir / "thumbnail_1080x1920.jpg"
    if not thumbnail_path.exists():
        thumbnail_path = pick_first_file(package_dir, IMAGE_EXTENSIONS)

    title_path = package_dir / "copy_title.html"
    if not title_path.exists():
        title_path = None

    return {
        "package_dir": str(package_dir),
        "video_path": str(video_path) if video_path else None,
        "thumbnail_path": str(thumbnail_path) if thumbnail_path else None,
        "title_path": str(title_path) if title_path else None,
    }


def ensure_package_dir(package_dir: Path) -> dict[str, str | None]:
    if not package_dir.exists():
        raise SystemExit(f"Package folder not found: {package_dir}")
    if not package_dir.is_dir():
        raise SystemExit(f"Package path is not a folder: {package_dir}")

    assets = resolve_assets(package_dir)
    if not assets["video_path"]:
        raise SystemExit(f"No video file found in: {package_dir}")
    return assets


def chrome_is_running() -> bool:
    result = subprocess.run(
        ["osascript", "-e", 'tell application "Google Chrome" to running'],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0 and result.stdout.strip().lower() == "true"


def open_url_in_existing_chrome(url: str, reuse_active_tab: bool) -> None:
    if not chrome_is_running():
        raise SystemExit("Google Chrome is not open. Please open your existing Chrome first.")

    mode = "reuse" if reuse_active_tab else "new_tab"
    script = f"""
on run argv
    set targetUrl to item 1 of argv
    set openMode to item 2 of argv
    tell application "Google Chrome"
        if not running then error "Google Chrome is not open."
        activate
        if (count of windows) is 0 then error "Google Chrome has no open windows."
        set targetWindow to front window
        if openMode is "reuse" then
            set URL of active tab of targetWindow to targetUrl
        else
            tell targetWindow
                set newTab to make new tab at end of tabs with properties {{URL:targetUrl}}
                set active tab index to (count of tabs)
            end tell
        end if
    end tell
end run
"""
    result = subprocess.run(
        ["osascript", "-", url, mode],
        input=script,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "Unknown AppleScript error"
        raise SystemExit(f"Could not control Google Chrome: {message}")


def main() -> int:
    args = parse_args()
    package_dir = Path(args.package_dir).expanduser()
    assets = ensure_package_dir(package_dir)
    open_url_in_existing_chrome(args.url, reuse_active_tab=args.reuse_active_tab)

    summary = {
        "status": "ok",
        "opened_url": args.url,
        "chrome_mode": "reuse_active_tab" if args.reuse_active_tab else "new_tab_in_existing_window",
        **assets,
    }
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
