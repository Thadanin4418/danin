#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from facebook_video_downloader import (
    DownloadError as FacebookDownloadError,
    QUALITY_AUTO,
    build_output_path,
    choose_candidates_from_url_info,
    extract_facebook_url_info,
    extract_supported_facebook_url,
    metadata_from_url_info,
    normalize_supported_facebook_url,
    status_print,
    try_download_candidates,
)
from sora_downloader import download_sora_id, extract_sora_ids


SORA_URL_RE = re.compile(r"https?://sora\.chatgpt\.com/p/(s_[A-Za-z0-9_-]{8,})", re.IGNORECASE)
SORA_ID_RE = re.compile(r"\b(s_[A-Za-z0-9_-]{8,})\b", re.IGNORECASE)


@dataclass(frozen=True)
class DownloadEntry:
    kind: str
    value: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download mixed Sora and Facebook links into separate folders."
    )
    parser.add_argument("target_dir", help="Folder where downloaded videos will be saved.")
    parser.add_argument("items", nargs="+", help="Sora IDs/links or Facebook reel/video URLs.")
    return parser.parse_args()


def resolve_facebook_url(value: str) -> str | None:
    normalized = normalize_supported_facebook_url(value)
    if normalized:
        return normalized
    return extract_supported_facebook_url(value)


def resolve_sora_id(value: str) -> str | None:
    raw = str(value).strip()
    if not raw:
        return None

    url_match = SORA_URL_RE.search(raw)
    if url_match:
        return url_match.group(1)

    id_match = SORA_ID_RE.search(raw)
    if id_match:
        return id_match.group(1)

    extracted = extract_sora_ids(raw)
    return extracted[0] if extracted else None


def build_entries(items: list[str]) -> list[DownloadEntry]:
    entries: list[DownloadEntry] = []
    seen: set[str] = set()

    for raw in items:
        value = str(raw).strip()
        if not value:
            continue

        facebook_url = resolve_facebook_url(value)
        if facebook_url:
            key = f"facebook:{facebook_url.lower()}"
            if key not in seen:
                seen.add(key)
                entries.append(DownloadEntry(kind="facebook", value=facebook_url))
            continue

        sora_id = resolve_sora_id(value)
        if sora_id:
            key = f"sora:{sora_id.lower()}"
            if key not in seen:
                seen.add(key)
                entries.append(DownloadEntry(kind="sora", value=sora_id))

    return entries


def facebook_target_dir(base_target_dir: Path) -> Path:
    if base_target_dir.name.lower() == "facebook":
        return base_target_dir
    return base_target_dir.parent / "facebook"


def download_facebook_url(url: str, target_dir: Path) -> Path:
    target_dir.mkdir(parents=True, exist_ok=True)
    status_print(f"[facebook] Resolving page URL: {url}")
    status_print(f"[facebook] Saving into folder: {target_dir}")
    info = extract_facebook_url_info(url)
    candidates = choose_candidates_from_url_info(info, QUALITY_AUTO)
    metadata = metadata_from_url_info(info)

    for candidate in candidates:
        output_path = build_output_path(
            metadata=metadata,
            candidate=candidate,
            output_dir=target_dir,
            explicit_filename=None,
        )
        if output_path.exists():
            status_print(f"[facebook] Skip existing: {output_path}")
            return output_path

    return try_download_candidates(
        candidates,
        output_dir=target_dir,
        filename=None,
        timeout=180,
        force=False,
        skip_expiry_check=False,
        metadata=metadata,
    )


def main() -> int:
    args = parse_args()
    target_dir = Path(args.target_dir).expanduser()
    facebook_dir = facebook_target_dir(target_dir)
    entries = build_entries(args.items)
    if not entries:
        status_print("[post] FAILED: No valid Sora or Facebook links found.")
        return 1

    status_print(f"[post] Queueing {len(entries)} item(s).")
    failures: list[tuple[DownloadEntry, str]] = []

    for index, entry in enumerate(entries, start=1):
        status_print(f"[post] Starting {index}/{len(entries)}: {entry.kind} {entry.value}")
        try:
            if entry.kind == "sora":
                download_sora_id(entry.value, target_dir)
            elif entry.kind == "facebook":
                download_facebook_url(entry.value, facebook_dir)
            else:  # pragma: no cover - defensive fallback
                raise RuntimeError(f"Unsupported entry kind: {entry.kind}")

            status_print(f"[post] OK {entry.kind} {entry.value}")
        except FacebookDownloadError as exc:
            status_print(f"[post] FAILED {entry.kind} {entry.value}: {exc}")
            failures.append((entry, str(exc)))
        except Exception as exc:  # pragma: no cover - local tool/runtime issues
            status_print(f"[post] FAILED {entry.kind} {entry.value}: {exc}")
            failures.append((entry, str(exc)))

    if failures:
        status_print(f"[post] Complete with failures: {len(failures)}/{len(entries)} failed.")
        return 1

    status_print("[post] Complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
