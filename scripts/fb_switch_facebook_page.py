#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path


STEP3_SCRIPT = Path("/Users/nin/Downloads/fb_reels_step3_upload_video_and_next.py")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Switch the active Facebook profile/page from the top-right switcher menu in Chrome."
    )
    parser.add_argument("page_name", help="Facebook page/profile name to switch to.")
    parser.add_argument("--timeout", type=float, default=20.0, help="Timeout in seconds for UI transitions.")
    parser.add_argument(
        "--search-wait",
        type=float,
        default=2.5,
        help="Seconds to wait after typing into Search profiles and Pages before clicking the page result.",
    )
    parser.add_argument(
        "--settle-wait",
        type=float,
        default=3.5,
        help="Seconds to wait after clicking the page name before reopening Content Library.",
    )
    return parser.parse_args()


def load_step3_module():
    if not STEP3_SCRIPT.exists():
        raise RuntimeError(f"Missing dependency script: {STEP3_SCRIPT}")
    spec = importlib.util.spec_from_file_location("fb_step3_switch_page", STEP3_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    args = parse_args()
    step3 = load_step3_module()
    step3.activate_chrome()
    current_url = step3.activate_exact_content_library_page()
    step3.switch_facebook_page_via_profiles_menu(
        args.page_name,
        args.timeout,
        search_wait_seconds=args.search_wait,
        settle_seconds=args.settle_wait,
    )
    current_url = step3.activate_exact_content_library_page()
    print(
        json.dumps(
            {
                "status": "ok",
                "step": "switch_page",
                "page_name": args.page_name,
                "search_wait_seconds": args.search_wait,
                "settle_wait_seconds": args.settle_wait,
                "content_library_url": current_url,
            },
            indent=2,
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
