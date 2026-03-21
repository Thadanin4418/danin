#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import time
from pathlib import Path


STEP3_SCRIPT = Path("/Users/nin/Downloads/fb_reels_step3_upload_video_and_next.py")
DEFAULT_PACKAGE = Path("/Users/nin/Downloads/Soranin/64_Reels_Package")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Step 5 for Facebook Reels upload: read the title from copy_title.html and paste it into the reel description field."
    )
    parser.add_argument(
        "package_dir",
        nargs="?",
        default=str(DEFAULT_PACKAGE),
        help="Path to the numbered Reels package folder.",
    )
    parser.add_argument("--timeout", type=float, default=14.0, help="Timeout in seconds for UI checks.")
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


def reel_title_click_point(step3) -> tuple[float, float]:
    expression = """(() => {
  const box = document.querySelector('[role="textbox"][contenteditable="true"]');
  if (!box) return JSON.stringify({ found: false });
  const r = box.getBoundingClientRect();
  const x = r.left + Math.min(40, r.width / 4);
  const y = r.top + Math.min(24, r.height / 2);
  const scale = window.outerWidth / window.innerWidth;
  const xOffset = (window.outerWidth - (window.innerWidth * scale)) / 2;
  const yOffset = (window.outerHeight - (window.innerHeight * scale));
  return JSON.stringify({
    found: true,
    clickX: window.screenX + xOffset + (x * scale),
    clickY: window.screenY + yOffset + (y * scale)
  });
})()"""
    payload = json.loads(step3.tab_js(expression))
    if not payload.get("found"):
        raise RuntimeError("Reel title textbox not found.")
    return float(payload["clickX"]), float(payload["clickY"])


def set_reel_title(step3, title: str) -> bool:
    x, y = reel_title_click_point(step3)
    step3.click_screen_point(x, y)
    time.sleep(0.12)
    subprocess.run(["pbcopy"], input=title, text=True, check=True)
    applescript = """
tell application "System Events"
  tell process "Google Chrome"
    keystroke "a" using {command down}
    delay 0.15
    key code 51
    delay 0.15
    click menu item "Paste" of menu 1 of menu bar item "Edit" of menu bar 1
  end tell
end tell
"""
    subprocess.run(["osascript", "-"], input=applescript, text=True, check=True)
    time.sleep(0.45)
    return current_reel_title(step3) == title


def current_reel_title(step3) -> str:
    expression = r"""(() => {
  const box = document.querySelector('[role="textbox"][contenteditable="true"]');
  if (!box) return '';
  return (box.innerText || box.textContent || '').trim();
})()"""
    return step3.tab_js(expression).strip()


def main() -> int:
    args = parse_args()
    package_dir = Path(args.package_dir).expanduser()
    title_path = package_dir / "copy_title.html"
    if not title_path.exists():
        raise SystemExit(f"Title HTML not found: {title_path}")

    step3 = load_step3_module()
    title = step3.extract_title(title_path)
    if not title:
        raise SystemExit(f"Could not extract title from: {title_path}")

    step3.activate_chrome()
    step3.activate_content_library_tab()
    step3.wait_for_text(["Reel settings", "Describe your reel..."], args.timeout)

    if not set_reel_title(step3, title):
        raise RuntimeError("Could not set the reel title text.")

    applied = current_reel_title(step3)
    if applied != title:
        raise RuntimeError("Title field did not keep the expected text.")

    print(
        json.dumps(
            {
                "status": "ok",
                "step": "step5",
                "title_path": str(title_path),
                "title": title,
            },
            indent=2,
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
