#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urljoin, urlparse


CHUNK_SIZE = 1024 * 512
DEFAULT_TIMEOUT = 180
QUALITY_AUTO = "auto"
QUALITY_HIGH = "high"
QUALITY_LOW = "low"
VALID_QUALITIES = {QUALITY_AUTO, QUALITY_HIGH, QUALITY_LOW}
URL_CANDIDATE_RE = re.compile(r"(?P<url>(?:https?://)?(?:[\w-]+\.)?(?:facebook\.com|fb\.watch)/[^\s<>'\"]+)", re.IGNORECASE)
TRAILING_URL_PUNCTUATION = ".,;:!?)\\]}>\"'"
SHARE_PATH_RE = re.compile(r"^/share/(?:r|v)/([^/?#]+)", re.IGNORECASE)


class DownloadError(RuntimeError):
    pass


@dataclass(frozen=True)
class VideoCandidate:
    quality: str
    url: str
    size: int | None
    size_human: str | None
    mime_type: str | None
    expires_at: datetime | None


@dataclass(frozen=True)
class SourceMetadata:
    title: str | None
    video_id: str | None


def status_print(message: str) -> None:
    print(message, flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download a Facebook video from a JSON payload that includes dl_urls.low/high."
    )
    parser.add_argument(
        "source",
        nargs="?",
        help="Path to a JSON file or a raw JSON string. Reads stdin when omitted.",
    )
    parser.add_argument(
        "--quality",
        default=QUALITY_AUTO,
        choices=sorted(VALID_QUALITIES),
        help="Preferred quality to download.",
    )
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Folder where the downloaded video will be saved.",
    )
    parser.add_argument(
        "--filename",
        help="Optional output filename. Defaults to title or id plus quality.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help="HTTP timeout in seconds.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite the output file if it already exists.",
    )
    parser.add_argument(
        "--skip-expiry-check",
        action="store_true",
        help="Attempt the download even when the signed URL looks expired.",
    )
    return parser.parse_args()


def read_source_text(source: str | None) -> str:
    if source:
        source_path = Path(source).expanduser()
        if source_path.is_file():
            return source_path.read_text(encoding="utf-8")
        return source

    raw = sys.stdin.read()
    if raw.strip():
        return raw
    raise DownloadError("No JSON input provided.")


def is_probably_url(value: str) -> bool:
    parsed = urlparse(value.strip())
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def _strip_url_punctuation(value: str) -> str:
    return value.rstrip(TRAILING_URL_PUNCTUATION)


def _follow_facebook_redirect(url: str) -> str | None:
    class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    opener = urllib.request.build_opener(_NoRedirectHandler)
    headers = {
        "User-Agent": "Mozilla/5.0",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    }
    current = url

    for method in ("HEAD", "GET"):
        for _ in range(5):
            request = urllib.request.Request(current, headers=headers, method=method)
            try:
                with opener.open(request, timeout=30) as response:
                    final_url = _strip_url_punctuation(response.geturl().strip())
                    return final_url or None
            except urllib.error.HTTPError as exc:
                if exc.code not in {301, 302, 303, 307, 308}:
                    break
                location = exc.headers.get("Location") or exc.headers.get("location")
                if not isinstance(location, str) or not location.strip():
                    break
                next_url = _strip_url_punctuation(urljoin(current, location.strip()))
                if "facebook.com/watch" in next_url or "/reel/" in next_url or "/share/" in next_url:
                    return next_url
                if not next_url or next_url.lower() == current.lower():
                    break
                current = next_url
            except Exception:
                break
        current = url
    return None


def normalize_supported_facebook_url(value: str) -> str | None:
    raw = _strip_url_punctuation(value.strip())
    if not raw:
        return None
    if "://" not in raw:
        raw = f"https://{raw}"

    parsed = urlparse(raw)
    host = (parsed.netloc or "").lower()
    path = parsed.path or ""

    if host == "fb.watch" or host.endswith(".fb.watch"):
        redirected = _follow_facebook_redirect(raw)
        if redirected and redirected.lower() != raw.lower():
            normalized_redirect = normalize_supported_facebook_url(redirected)
            if normalized_redirect:
                return normalized_redirect
        return raw

    if not (host == "facebook.com" or host.endswith(".facebook.com")):
        return None

    reel_match = re.search(r"/reel/(\d+)", path)
    if reel_match:
        return f"https://www.facebook.com/reel/{reel_match.group(1)}"

    if path.startswith("/watch"):
        video_id = (parse_qs(parsed.query).get("v") or [None])[0]
        if isinstance(video_id, str) and video_id.isdigit():
            return f"https://www.facebook.com/watch/?v={video_id}"

    if "/videos/" in path:
        ids = re.findall(r"/(\d{6,})(?:/|$)", path)
        if ids:
            return f"https://www.facebook.com/watch/?v={ids[-1]}"

    share_match = SHARE_PATH_RE.search(path)
    if share_match:
        share_path = share_match.group(0).rstrip("/")
        redirected = _follow_facebook_redirect(raw)
        if redirected and redirected.lower() != raw.lower():
            normalized_redirect = normalize_supported_facebook_url(redirected)
            if normalized_redirect:
                return normalized_redirect
        return f"https://www.facebook.com{share_path}"

    return None


def extract_supported_facebook_url(text: str) -> str | None:
    for match in URL_CANDIDATE_RE.finditer(text):
        candidate = normalize_supported_facebook_url(match.group("url"))
        if candidate:
            return candidate
    return None


def load_source(source: str | None) -> tuple[str, dict[str, object] | str]:
    raw = read_source_text(source).strip()
    if raw.startswith("{"):
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise DownloadError(
                "Input is not valid JSON. "
                f"JSON error: {exc}"
            ) from exc
        if not isinstance(payload, dict):
            raise DownloadError("Expected a JSON object.")
        return "json", payload

    normalized_url = normalize_supported_facebook_url(raw) if is_probably_url(raw) else extract_supported_facebook_url(raw)
    if normalized_url:
        return "url", normalized_url

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise DownloadError(
            "Input is neither a valid URL nor valid JSON. "
            f"JSON error: {exc}"
        ) from exc
    if not isinstance(payload, dict):
        raise DownloadError("Expected a JSON object.")
    return "json", payload


def sanitize_filename(value: str) -> str:
    cleaned = re.sub(r'[\\/:*?"<>|]+', "_", value)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" ._")
    return cleaned or "facebook_video"


def parse_hex_expiry(url: str) -> datetime | None:
    query = parse_qs(urlparse(url).query)
    raw_value = (query.get("oe") or [None])[0]
    if not raw_value:
        return None
    try:
        timestamp = int(raw_value, 16)
    except ValueError:
        return None
    return datetime.fromtimestamp(timestamp, tz=timezone.utc)


def build_candidate(payload: dict[str, object], quality: str) -> VideoCandidate | None:
    dl_urls = payload.get("dl_urls")
    if not isinstance(dl_urls, dict):
        return None

    url = dl_urls.get(quality)
    if not isinstance(url, str) or not url.strip():
        return None

    meta = dl_urls.get(f"{quality}Data")
    meta_dict = meta if isinstance(meta, dict) else {}

    size: int | None = None
    raw_size = meta_dict.get("size")
    if isinstance(raw_size, str) and raw_size.isdigit():
        size = int(raw_size)
    elif isinstance(raw_size, int):
        size = raw_size

    size_human = meta_dict.get("sizeHuman")
    mime_type = meta_dict.get("type")

    return VideoCandidate(
        quality=quality,
        url=url.strip(),
        size=size,
        size_human=size_human if isinstance(size_human, str) else None,
        mime_type=mime_type if isinstance(mime_type, str) else None,
        expires_at=parse_hex_expiry(url),
    )


def preferred_quality_order(preferred_quality: str) -> list[str]:
    if preferred_quality == QUALITY_HIGH:
        return [QUALITY_HIGH]
    if preferred_quality == QUALITY_LOW:
        return [QUALITY_LOW]
    return [QUALITY_HIGH, QUALITY_LOW]


def choose_candidates(payload: dict[str, object], preferred_quality: str) -> list[VideoCandidate]:
    candidates: list[VideoCandidate] = []
    seen_urls: set[str] = set()

    for quality in preferred_quality_order(preferred_quality):
        candidate = build_candidate(payload, quality)
        if candidate is None:
            continue
        if candidate.url in seen_urls:
            continue
        seen_urls.add(candidate.url)
        candidates.append(candidate)

    if not candidates:
        raise DownloadError("No downloadable Facebook URL found in dl_urls.low or dl_urls.high.")
    return candidates


def format_bytes(size: int | None) -> str | None:
    if size is None:
        return None
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(size)
    unit = units[0]
    for unit in units:
        if value < 1024 or unit == units[-1]:
            break
        value /= 1024
    if unit == "B":
        return f"{int(value)} {unit}"
    return f"{value:.2f} {unit}"


def load_ytdlp_module():
    try:
        import yt_dlp  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on local environment
        raise DownloadError(
            "yt-dlp is required to resolve Facebook page URLs. "
            "Install it with `python3 -m pip install --user yt-dlp`."
        ) from exc
    return yt_dlp


def extract_facebook_url_info(url: str) -> dict[str, object]:
    yt_dlp = load_ytdlp_module()
    options = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
    }
    try:
        with yt_dlp.YoutubeDL(options) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception as exc:
        raise DownloadError(f"Could not resolve Facebook URL: {exc}") from exc
    if not isinstance(info, dict):
        raise DownloadError("yt-dlp did not return video metadata.")
    return info


def build_candidate_from_format(fmt: dict[str, object], fallback_quality: str) -> VideoCandidate | None:
    raw_url = fmt.get("url")
    if not isinstance(raw_url, str) or not raw_url.strip():
        return None

    format_id = str(fmt.get("format_id") or "").strip().lower()
    quality = fallback_quality
    if format_id == "hd":
        quality = QUALITY_HIGH
    elif format_id == "sd":
        quality = QUALITY_LOW

    size: int | None = None
    raw_size = fmt.get("filesize")
    raw_size_approx = fmt.get("filesize_approx")
    if isinstance(raw_size, int):
        size = raw_size
    elif isinstance(raw_size_approx, int):
        size = raw_size_approx

    ext = fmt.get("ext")
    mime_type = None
    if isinstance(ext, str) and ext:
        mime_type = f"video/{ext}"

    return VideoCandidate(
        quality=quality,
        url=raw_url.strip(),
        size=size,
        size_human=format_bytes(size),
        mime_type=mime_type,
        expires_at=parse_hex_expiry(raw_url),
    )


def choose_candidates_from_url_info(info: dict[str, object], preferred_quality: str) -> list[VideoCandidate]:
    formats = info.get("formats")
    if not isinstance(formats, list):
        raise DownloadError("yt-dlp metadata did not include any formats.")

    exact_formats: dict[str, dict[str, object]] = {}
    progressive_candidates: list[dict[str, object]] = []

    for entry in formats:
        if not isinstance(entry, dict):
            continue
        raw_url = entry.get("url")
        if not isinstance(raw_url, str) or not raw_url.startswith("http"):
            continue

        format_id = str(entry.get("format_id") or "").strip().lower()
        if format_id in {"hd", "sd"}:
            exact_formats[format_id] = entry
            continue

        vcodec = str(entry.get("vcodec") or "").strip().lower()
        acodec = str(entry.get("acodec") or "").strip().lower()
        if vcodec and vcodec != "none" and acodec and acodec != "none":
            progressive_candidates.append(entry)

    candidates: list[VideoCandidate] = []
    seen_urls: set[str] = set()

    for quality_name in preferred_quality_order(preferred_quality):
        format_id = "hd" if quality_name == QUALITY_HIGH else "sd"
        entry = exact_formats.get(format_id)
        if entry is not None:
            candidate = build_candidate_from_format(entry, quality_name)
            if candidate is not None:
                if candidate.url not in seen_urls:
                    seen_urls.add(candidate.url)
                    candidates.append(candidate)

    if candidates:
        return candidates

    if progressive_candidates:
        reverse = preferred_quality != QUALITY_LOW
        progressive_candidates.sort(
            key=lambda item: int(item.get("height") or 0),
            reverse=reverse,
        )
        for entry in progressive_candidates:
            candidate = build_candidate_from_format(
                entry,
                preferred_quality if preferred_quality != QUALITY_AUTO else QUALITY_HIGH,
            )
            if candidate is None:
                continue
            if candidate.url in seen_urls:
                continue
            seen_urls.add(candidate.url)
            candidates.append(candidate)
        if candidates:
            return candidates

    raise DownloadError("No downloadable progressive Facebook format was found for this URL.")


def build_output_path(
    metadata: SourceMetadata,
    candidate: VideoCandidate,
    output_dir: Path,
    explicit_filename: str | None,
) -> Path:
    if explicit_filename:
        filename = explicit_filename
    else:
        base_name = ""
        if metadata.title and metadata.title.strip():
            base_name = metadata.title
        elif metadata.video_id and metadata.video_id.strip():
            base_name = metadata.video_id
        else:
            base_name = "facebook_video"
        filename = f"{sanitize_filename(base_name)}_{candidate.quality}.mp4"

    output_path = output_dir / filename
    if output_path.suffix.lower() != ".mp4":
        output_path = output_path.with_suffix(".mp4")
    return output_path


def ensure_not_expired(candidate: VideoCandidate, skip_check: bool) -> None:
    if skip_check or candidate.expires_at is None:
        return
    now = datetime.now(timezone.utc)
    if candidate.expires_at <= now:
        raise DownloadError(
            "Facebook CDN URL is expired. "
            f"Quality `{candidate.quality}` expired at {candidate.expires_at.isoformat()}."
        )


def download_file(url: str, output_path: Path, timeout: int, force: bool) -> Path:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = output_path.with_suffix(output_path.suffix + ".download")

    if output_path.exists() and not force:
        raise DownloadError(f"Output already exists: {output_path}")

    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0",
            "Accept": "*/*",
        },
        method="GET",
    )

    written = 0
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            content_type = (response.headers.get("Content-Type") or "").lower()
            status_code = getattr(response, "status", None)
            if status_code and int(status_code) >= 400:
                raise DownloadError(f"HTTP {status_code}")
            if content_type and "video" not in content_type and "octet-stream" not in content_type:
                preview = response.read(200).decode("utf-8", "replace")
                raise DownloadError(f"Unexpected content-type `{content_type}`: {preview}")

            with temp_path.open("wb") as handle:
                while True:
                    chunk = response.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    handle.write(chunk)
                    written += len(chunk)
    except urllib.error.HTTPError as exc:
        temp_path.unlink(missing_ok=True)
        raise DownloadError(f"HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        temp_path.unlink(missing_ok=True)
        raise DownloadError(f"Network error: {exc.reason}") from exc
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise

    if written <= 0:
        temp_path.unlink(missing_ok=True)
        raise DownloadError("Downloaded 0 bytes.")

    temp_path.replace(output_path)
    return output_path


def metadata_from_payload(payload: dict[str, object]) -> SourceMetadata:
    raw_title = payload.get("title")
    raw_id = payload.get("id")
    return SourceMetadata(
        title=raw_title if isinstance(raw_title, str) else None,
        video_id=raw_id if isinstance(raw_id, str) else None,
    )


def metadata_from_url_info(info: dict[str, object]) -> SourceMetadata:
    raw_title = info.get("title")
    raw_id = info.get("id")
    return SourceMetadata(
        title=raw_title if isinstance(raw_title, str) else None,
        video_id=raw_id if isinstance(raw_id, str) else None,
    )


def resolve_facebook_download(
    value: str,
    preferred_quality: str = QUALITY_AUTO,
) -> tuple[str, SourceMetadata, list[VideoCandidate]]:
    normalized_url = normalize_supported_facebook_url(value) or extract_supported_facebook_url(value)
    if not normalized_url:
        raise DownloadError("No supported Facebook reel/video URL was found.")

    info = extract_facebook_url_info(normalized_url)
    candidates = choose_candidates_from_url_info(info, preferred_quality)
    metadata = metadata_from_url_info(info)
    return normalized_url, metadata, candidates


def serialize_candidate(candidate: VideoCandidate) -> dict[str, object]:
    return {
        "quality": candidate.quality,
        "url": candidate.url,
        "size": candidate.size,
        "size_human": candidate.size_human,
        "mime_type": candidate.mime_type,
        "expires_at": candidate.expires_at.isoformat() if candidate.expires_at else None,
    }


def serialize_metadata(metadata: SourceMetadata) -> dict[str, object]:
    return {
        "title": metadata.title,
        "video_id": metadata.video_id,
    }


def resolve_facebook_download_payload(
    value: str,
    preferred_quality: str = QUALITY_AUTO,
) -> dict[str, object]:
    normalized_url, metadata, candidates = resolve_facebook_download(value, preferred_quality)
    preferred_candidate = candidates[0] if candidates else None
    preferred_filename = None
    if preferred_candidate is not None:
        preferred_filename = build_output_path(
            metadata=metadata,
            candidate=preferred_candidate,
            output_dir=Path("."),
            explicit_filename=None,
        ).name

    return {
        "normalized_url": normalized_url,
        "metadata": serialize_metadata(metadata),
        "preferred_filename": preferred_filename,
        "candidates": [serialize_candidate(candidate) for candidate in candidates],
    }


def try_download_candidates(
    candidates: list[VideoCandidate],
    output_dir: Path,
    filename: str | None,
    timeout: int,
    force: bool,
    skip_expiry_check: bool,
    metadata: SourceMetadata,
) -> Path:
    errors: list[str] = []

    for index, candidate in enumerate(candidates, start=1):
        output_path = build_output_path(metadata, candidate, output_dir, filename)
        status_print(f"[facebook] Selected quality: {candidate.quality}")
        status_print(f"[facebook] Output: {output_path}")
        if candidate.size_human:
            status_print(f"[facebook] Reported size: {candidate.size_human}")
        elif candidate.size is not None:
            status_print(f"[facebook] Reported size: {candidate.size} bytes")
        if candidate.expires_at is not None:
            status_print(f"[facebook] URL expires at: {candidate.expires_at.isoformat()}")

        try:
            ensure_not_expired(candidate, skip_expiry_check)
            return download_file(candidate.url, output_path, timeout=timeout, force=force)
        except DownloadError as exc:
            errors.append(f"{candidate.quality}: {exc}")
            if index < len(candidates):
                status_print(
                    f"[facebook] {candidate.quality} unavailable ({exc}). Trying next quality..."
                )
                continue
            raise DownloadError("; ".join(errors)) from exc

    raise DownloadError("No downloadable Facebook video candidate was available.")


def main() -> int:
    args = parse_args()

    try:
        source_kind, source_value = load_source(args.source)
        if source_kind == "json":
            payload = source_value if isinstance(source_value, dict) else {}
            status_value = payload.get("status")
            if status_value not in (None, 200):
                status_print(f"[warn] Payload status is {status_value}, not 200.")
            candidates = choose_candidates(payload, args.quality)
            metadata = metadata_from_payload(payload)
        else:
            page_url = str(source_value)
            status_print(f"[facebook] Resolving page URL: {page_url}")
            info = extract_facebook_url_info(page_url)
            candidates = choose_candidates_from_url_info(info, args.quality)
            metadata = metadata_from_url_info(info)

        output_dir = Path(args.output_dir).expanduser()
        downloaded = try_download_candidates(
            candidates,
            output_dir=output_dir,
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
