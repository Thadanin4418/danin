#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from facebook_video_downloader import (
    DownloadError,
    QUALITY_AUTO,
    QUALITY_HIGH,
    QUALITY_LOW,
    choose_candidates_from_url_info,
    extract_supported_facebook_url,
    extract_facebook_url_info,
    normalize_supported_facebook_url,
    metadata_from_url_info,
    status_print,
    try_download_candidates,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Paste a Facebook reel/video URL and download it. HD first, SD fallback."
    )
    parser.add_argument("url", nargs="?", help="Facebook reel/video URL.")
    parser.add_argument(
        "--quality",
        default=QUALITY_AUTO,
        choices=[QUALITY_AUTO, QUALITY_HIGH, QUALITY_LOW],
        help="Preferred quality. `auto` tries HD first, then SD.",
    )
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Folder where the downloaded file will be saved.",
    )
    parser.add_argument("--filename", help="Optional output filename.")
    parser.add_argument("--timeout", type=int, default=180, help="HTTP timeout in seconds.")
    parser.add_argument("--force", action="store_true", help="Overwrite existing output.")
    parser.add_argument(
        "--skip-expiry-check",
        action="store_true",
        help="Attempt download even when Facebook URL looks expired.",
    )
    return parser.parse_args()


def resolve_url(value: str | None) -> str:
    if value and value.strip():
        raw = value.strip()
    elif sys.stdin.isatty():
        raw = input("Facebook URL: ").strip()
    else:
        raw = sys.stdin.read().strip()

    if not raw:
        raise DownloadError("No Facebook URL provided.")

    normalized = normalize_supported_facebook_url(raw)
    if normalized:
        return normalized

    extracted = extract_supported_facebook_url(raw)
    if extracted:
        status_print(f"[facebook] Using supported URL: {extracted}")
        return extracted

    raise DownloadError("Please provide a supported Facebook reel/video URL.")


def main() -> int:
    args = parse_args()
    try:
        url = resolve_url(args.url)
        status_print(f"[facebook] Resolving page URL: {url}")
        info = extract_facebook_url_info(url)
        candidates = choose_candidates_from_url_info(info, args.quality)
        metadata = metadata_from_url_info(info)
        downloaded = try_download_candidates(
            candidates,
            output_dir=Path(args.output_dir).expanduser(),
            filename=args.filename,
            timeout=args.timeout,
            force=args.force,
            skip_expiry_check=args.skip_expiry_check,
            metadata=metadata,
        )
        status_print(f"[facebook] Saved: {downloaded}")
        return 0
    except DownloadError as exc:
        status_print(f"[facebook] FAILED: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
