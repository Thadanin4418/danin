#!/usr/bin/env python3
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import re
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path


API_BASE = "https://soravdl.com/api/proxy/video/"
MATCH_RE = re.compile(
    r"https?://sora\.chatgpt\.com/p/(s_[A-Za-z0-9_-]{8,})(?:[/?#][^\s]*)?|\b(s_[A-Za-z0-9_-]{8,})\b"
)
CHUNK_SIZE = 1024 * 512
MAX_PARALLEL_DOWNLOADS = 4


def status_print(message: str) -> None:
    print(message, flush=True)


def extract_all_sora_ids(text: str) -> list[str]:
    found: list[str] = []
    for match in MATCH_RE.finditer(text):
        sora_id = match.group(1) or match.group(2)
        if sora_id:
            found.append(sora_id)
    return found


def extract_sora_ids(text: str) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()

    for sora_id in extract_all_sora_ids(text):
        if sora_id not in seen:
            seen.add(sora_id)
            found.append(sora_id)

    return found


def normalize_sora_input(text: str) -> tuple[str, int]:
    all_ids = extract_all_sora_ids(text)
    unique_ids = extract_sora_ids(text)
    duplicate_count = max(0, len(all_ids) - len(unique_ids))
    return "\n".join(unique_ids), duplicate_count


def merge_sora_inputs(existing_text: str, incoming_text: str) -> tuple[str, list[str], list[str]]:
    existing_ids = extract_sora_ids(existing_text)
    incoming_ids = extract_sora_ids(incoming_text)
    merged = list(existing_ids)
    seen = set(existing_ids)
    added: list[str] = []
    duplicates: list[str] = []
    for sora_id in incoming_ids:
        if sora_id in seen:
            duplicates.append(sora_id)
            continue
        seen.add(sora_id)
        merged.append(sora_id)
        added.append(sora_id)
    return "\n".join(merged), added, duplicates


def _looks_like_error_snippet(payload: bytes) -> bool:
    sample = payload.lstrip()[:32]
    return sample.startswith(b"{") or sample.startswith(b"<") or sample.startswith(b"[")


def download_sora_id(
    sora_id: str,
    target_dir: Path,
    timeout: int = 180,
    progress_callback=None,
) -> Path:
    target_dir.mkdir(parents=True, exist_ok=True)
    output_path = target_dir / f"{sora_id}.mp4"
    temp_path = target_dir / f"{sora_id}.download"
    if output_path.exists():
        status_print(f"[download] Skip existing: {output_path.name}")
        return output_path

    request = urllib.request.Request(
        API_BASE + sora_id,
        headers={
            "User-Agent": "Mozilla/5.0",
            "Accept": "*/*",
        },
        method="GET",
    )

    status_print(f"[download] Requesting {sora_id}")
    written = 0
    last_percent = -1
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            content_type = (response.headers.get("Content-Type") or "").lower()
            total_bytes_raw = response.headers.get("Content-Length") or ""
            total_bytes = int(total_bytes_raw) if total_bytes_raw.isdigit() else None
            first_chunk = response.read(CHUNK_SIZE)
            if not first_chunk:
                raise RuntimeError("empty response")
            if ("json" in content_type or "html" in content_type or "text/" in content_type) and _looks_like_error_snippet(first_chunk):
                snippet = first_chunk[:200].decode("utf-8", "replace")
                raise RuntimeError(f"unexpected response: {snippet}")

            with temp_path.open("wb") as handle:
                handle.write(first_chunk)
                written += len(first_chunk)
                if total_bytes:
                    percent = min(100, int((written * 100) / total_bytes))
                    last_percent = percent
                    if progress_callback is not None:
                        progress_callback(sora_id, percent, written, total_bytes)
                    status_print(f"[download] Progress {sora_id} {percent}%")
                while True:
                    chunk = response.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    handle.write(chunk)
                    written += len(chunk)
                    if total_bytes:
                        percent = min(100, int((written * 100) / total_bytes))
                        if percent != last_percent:
                            last_percent = percent
                            if progress_callback is not None:
                                progress_callback(sora_id, percent, written, total_bytes)
                            status_print(f"[download] Progress {sora_id} {percent}%")
    except urllib.error.HTTPError as exc:
        temp_path.unlink(missing_ok=True)
        raise RuntimeError(f"HTTP {exc.code}") from exc
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise

    if written == 0:
        temp_path.unlink(missing_ok=True)
        raise RuntimeError("downloaded 0 bytes")

    if progress_callback is not None:
        progress_callback(sora_id, 100, written, written)
    temp_path.replace(output_path)
    status_print(f"[download] Saved {output_path.name} ({written} bytes)")
    return output_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Download Sora videos from SoraVDL proxy using Sora IDs.")
    parser.add_argument("target_dir", help="Folder to save downloaded videos.")
    parser.add_argument("items", nargs="+", help="Sora IDs or full sora.chatgpt.com URLs.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    target_dir = Path(args.target_dir).expanduser()
    ids = extract_sora_ids("\n".join(args.items))
    if not ids:
        status_print("[download] No valid Sora IDs found.")
        return 1

    parallel_count = max(1, min(MAX_PARALLEL_DOWNLOADS, len(ids)))
    status_print(f"[download] Queueing {len(ids)} item(s) with {parallel_count} parallel download(s).")

    def run_single(index: int, sora_id: str) -> tuple[str, str | None]:
        status_print(f"[download] Starting {index}/{len(ids)}: {sora_id}")
        try:
            download_sora_id(sora_id, target_dir)
            return sora_id, None
        except Exception as exc:
            status_print(f"[download] FAILED {sora_id}: {exc}")
            return sora_id, str(exc)

    failures: list[tuple[str, str]] = []
    with ThreadPoolExecutor(max_workers=parallel_count) as executor:
        futures = {
            executor.submit(run_single, index, sora_id): sora_id
            for index, sora_id in enumerate(ids, start=1)
        }
        for future in as_completed(futures):
            sora_id = futures[future]
            try:
                completed_id, error_message = future.result()
            except Exception as exc:  # pragma: no cover - defensive fallback
                failures.append((sora_id, str(exc)))
                status_print(f"[download] FAILED {sora_id}: {exc}")
                continue
            if error_message:
                failures.append((completed_id, error_message))

    if failures:
        status_print(f"[download] Complete with failures: {len(failures)}/{len(ids)} failed.")
        return 1
    status_print("[download] Complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
