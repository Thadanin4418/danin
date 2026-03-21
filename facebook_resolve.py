#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def bootstrap_import_path() -> None:
    here = Path(__file__).resolve().parent
    for candidate in [here / "pydeps", here, here.parent]:
        value = str(candidate)
        if candidate.exists() and value not in sys.path:
            sys.path.insert(0, value)


bootstrap_import_path()

from facebook_video_downloader import (  # noqa: E402
    DownloadError,
    QUALITY_AUTO,
    VALID_QUALITIES,
    resolve_facebook_download_payload,
)


def main() -> int:
    raw_url = str(sys.argv[1] if len(sys.argv) > 1 else "").strip()
    requested_quality = str(sys.argv[2] if len(sys.argv) > 2 else QUALITY_AUTO).strip().lower()
    quality = requested_quality if requested_quality in VALID_QUALITIES else QUALITY_AUTO

    if not raw_url:
        print("url is required.", file=sys.stderr)
        return 1

    try:
        payload = resolve_facebook_download_payload(raw_url, quality)
    except DownloadError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except Exception as exc:  # pragma: no cover - runtime/environment failures
        print(f"Facebook resolve failed: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
