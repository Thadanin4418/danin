#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path

from soranin_paths import DEFAULT_FACEBOOK_PACKAGE, script_path


STEP3_SCRIPT = script_path("fb_reels_step3_upload_video_and_next.py")
DEFAULT_PACKAGE = DEFAULT_FACEBOOK_PACKAGE
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Step 4 for Facebook Reels upload: edit/upload thumbnail and save it."
    )
    parser.add_argument(
        "package_dir",
        nargs="?",
        default=str(DEFAULT_PACKAGE),
        help="Path to the numbered Reels package folder.",
    )
    parser.add_argument("--timeout", type=float, default=20.0, help="Timeout in seconds for UI transitions.")
    parser.add_argument(
        "--save-wait",
        type=float,
        default=8.0,
        help="Seconds to wait after uploading the thumbnail before clicking Save.",
    )
    return parser.parse_args()


def load_step3_module():
    if not STEP3_SCRIPT.exists():
        raise RuntimeError(f"Missing dependency script: {STEP3_SCRIPT}")
    spec = importlib.util.spec_from_file_location("fb_step3", STEP3_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def pick_first_file(folder: Path, allowed_extensions: set[str]) -> Path | None:
    candidates = [
        path
        for path in sorted(folder.iterdir())
        if path.is_file() and path.suffix.lower() in allowed_extensions
    ]
    return candidates[0] if candidates else None


def resolve_thumbnail(package_dir: Path) -> Path:
    for preferred_name in ("thumbnail_1080x1920.jpg", "Reels64.jpg"):
        candidate = package_dir / preferred_name
        if candidate.exists():
            return candidate

    candidate = pick_first_file(package_dir, IMAGE_EXTENSIONS)
    if candidate:
        return candidate
    raise SystemExit(f"No thumbnail image found in: {package_dir}")


def ensure_edit_thumbnail_page(step3, timeout_seconds: float) -> None:
    text = step3.tab_js("document.body ? document.body.innerText.slice(0, 20000) : ''")
    if "Edit thumbnail" in text and "Upload your own thumbnail" in text:
        return

    if "Reel settings" in text:
        click_attempts = [
            ("Edit thumbnail", True),
            ("thumbnail", True),
            ("Edit", False),
        ]
        for label, contains in click_attempts:
            try:
                clicked = step3.click_exact(label, contains=contains)
                if not clicked:
                    step3.real_click_label(label, contains=contains)
                else:
                    time.sleep(0.15)
                step3.wait_for_text(["Edit thumbnail", "Upload your own thumbnail"], 3.0)
                return
            except Exception:
                continue

    raise RuntimeError("Current Facebook page is not on Reel settings or Edit thumbnail.")


def main() -> int:
    args = parse_args()
    package_dir = Path(args.package_dir).expanduser()
    thumbnail_path = resolve_thumbnail(package_dir)
    step3 = load_step3_module()

    step3.activate_chrome()
    ensure_edit_thumbnail_page(step3, args.timeout)

    step3.pause_media()

    clicked = step3.click_exact("Upload")
    time.sleep(0.18)
    if not clicked or not step3.file_dialog_open():
        step3.real_click_label("Upload")
    step3.wait_for_file_dialog(5.0)
    step3.choose_file_via_favorites(thumbnail_path)

    time.sleep(args.save_wait)
    if not step3.click_exact("Save"):
        step3.real_click_label("Save")

    step3.wait_for_text(["Reel settings", "Post"], args.timeout)
    step3.pause_media()

    print(
        json.dumps(
            {
                "status": "ok",
                "step": "step4",
                "thumbnail_path": str(thumbnail_path),
                "page": "reel_settings",
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
