#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import html
import hmac
import mimetypes
import os
import re
import shlex
import shutil
import subprocess
import threading
import time
import getpass
import socket
from collections import deque
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib import error as urllib_error, request as urllib_request
from urllib.parse import parse_qs, quote, unquote, urlparse

from facebook_video_downloader import (
    DownloadError as FacebookDownloadError,
    QUALITY_AUTO as FACEBOOK_QUALITY_AUTO,
    VALID_QUALITIES as FACEBOOK_VALID_QUALITIES,
    resolve_facebook_download_payload,
)
from soranin_paths import API_KEYS_FILE, CONTROL_RELAY_CONFIG_FILE, ROOT_DIR, script_path


HOST = "0.0.0.0"
PORT = 8765
BATCH_SCRIPT = script_path("fast_reels_batch.py")
DOWNLOADER_SCRIPT = script_path("sora_downloader.py")
FACEBOOK_BATCH_SCRIPT = script_path("fb_reels_batch_upload.py")
FACEBOOK_PREFLIGHT_SCRIPT = script_path("fb_reels_preflight_check.py")
CHROME_LOCAL_STATE = Path.home() / "Library/Application Support/Google/Chrome/Local State"
CHROME_APP = "Google Chrome"
FACEBOOK_CONTENT_LIBRARY_URL = "https://web.facebook.com/professional_dashboard/content/content_library/"
AI_PROVIDER_DEFAULT = "openai"
AI_PROVIDER_OPENAI = "openai"
AI_PROVIDER_GEMINI = "gemini"
VIDEO_ID_PATTERN = re.compile(r"\b(?:s_|gen_)[A-Za-z0-9_-]{8,}\b", re.IGNORECASE)
DEFAULT_CONTROL_RELAY_POLL_SECONDS = 3.0
ALLOWED_SOURCE_VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".avi", ".mkv"}
CONTENT_TYPE_EXTENSION_MAP = {
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "video/x-m4v": ".m4v",
    "video/x-msvideo": ".avi",
    "video/x-matroska": ".mkv",
    "application/octet-stream": ".mp4",
}
FACEBOOK_PROGRESS_PATTERN = re.compile(r"^\[facebook-progress\]\s*(\d{1,3})\|(.*)$")


def current_mac_user_name() -> str:
    value = (os.environ.get("USER") or "").strip()
    if value:
        return value
    try:
        value = getpass.getuser().strip()
    except Exception:
        value = ""
    if value:
        return value
    return Path.home().name


def current_mac_device_name() -> str:
    try:
        proc = subprocess.run(
            ["scutil", "--get", "ComputerName"],
            capture_output=True,
            text=True,
            check=False,
        )
        value = (proc.stdout or "").strip()
        if value:
            return value
    except Exception:
        pass
    value = (socket.gethostname() or "").strip()
    return value or "Mac"


def current_mac_display_name() -> str:
    return f"{current_mac_device_name()} • user {current_mac_user_name()}"


def show_mac_notification(title: str, message: str) -> None:
    safe_title = (title or "Soranin").strip()[:120]
    safe_message = (message or "").strip()[:240]
    if not safe_message:
        safe_message = "Done."

    script = (
        f"display notification {json.dumps(safe_message)} "
        f"with title {json.dumps(safe_title)}"
    )
    try:
        subprocess.Popen(
            ["osascript", "-e", script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def sanitize_alert_text(value: str, fallback: str, limit: int) -> str:
    text = str(value or "").strip()
    if not text:
        text = fallback
    return text[:limit]


def load_control_relay_config() -> dict[str, object]:
    payload: dict[str, object] = {}
    if CONTROL_RELAY_CONFIG_FILE.exists():
        try:
            parsed = json.loads(CONTROL_RELAY_CONFIG_FILE.read_text(encoding="utf-8"))
        except Exception:
            parsed = {}
        if isinstance(parsed, dict):
            payload.update(parsed)

    relay_url = str(os.environ.get("SORANIN_CONTROL_RELAY_URL") or payload.get("relay_url") or "").strip()
    relay_user_name = str(
        os.environ.get("SORANIN_CONTROL_RELAY_USER_NAME")
        or payload.get("relay_user_name")
        or ""
    ).strip()
    relay_mac_name = str(
        os.environ.get("SORANIN_CONTROL_RELAY_MAC_NAME")
        or payload.get("relay_mac_name")
        or ""
    ).strip()
    relay_secret_token = str(
        os.environ.get("SORANIN_CONTROL_RELAY_SECRET_TOKEN")
        or payload.get("relay_secret_token")
        or payload.get("secret_token")
        or ""
    ).strip()
    control_password = str(
        os.environ.get("SORANIN_CONTROL_PASSWORD")
        or payload.get("control_password")
        or payload.get("password")
        or ""
    ).strip()
    poll_seconds_raw = str(os.environ.get("SORANIN_CONTROL_RELAY_POLL_SECONDS") or payload.get("poll_seconds") or "").strip()
    try:
        poll_seconds = float(poll_seconds_raw) if poll_seconds_raw else DEFAULT_CONTROL_RELAY_POLL_SECONDS
    except Exception:
        poll_seconds = DEFAULT_CONTROL_RELAY_POLL_SECONDS
    poll_seconds = max(1.0, poll_seconds)
    return {
        "relay_url": relay_url.rstrip("/"),
        "relay_user_name": relay_user_name,
        "relay_mac_name": relay_mac_name,
        "relay_secret_token": relay_secret_token,
        "control_password": control_password,
        "poll_seconds": poll_seconds,
    }


def control_relay_base_url() -> str:
    return str(load_control_relay_config().get("relay_url") or "").strip()


def control_relay_poll_seconds() -> float:
    try:
        return float(load_control_relay_config().get("poll_seconds") or DEFAULT_CONTROL_RELAY_POLL_SECONDS)
    except Exception:
        return DEFAULT_CONTROL_RELAY_POLL_SECONDS


def normalize_relay_label(value: str, fallback: str) -> str:
    text = re.sub(r"[^A-Za-z0-9._-]+", "-", str(value or "").strip()).strip("-._")
    return text or fallback


def control_relay_user_name() -> str:
    config = load_control_relay_config()
    return normalize_relay_label(str(config.get("relay_user_name") or current_mac_user_name()), "user")


def control_relay_mac_name() -> str:
    config = load_control_relay_config()
    return normalize_relay_label(str(config.get("relay_mac_name") or current_mac_device_name()), "mac")


def control_relay_secret_token() -> str:
    config = load_control_relay_config()
    raw = str(
        os.environ.get("SORANIN_CONTROL_RELAY_SECRET_TOKEN")
        or config.get("relay_secret_token")
        or config.get("secret_token")
        or ""
    ).strip()
    return normalize_relay_label(raw, "")


def control_relay_client_token() -> str:
    secret = control_relay_secret_token()
    if not secret:
        return ""
    return f"{control_relay_user_name()}-{control_relay_mac_name()}-{secret}"


def control_relay_client_base_url() -> str:
    base = control_relay_base_url()
    token = control_relay_client_token()
    if not base or not token:
        return ""
    return f"{base}/client/{quote(token, safe='')}"


def control_password() -> str:
    return str(load_control_relay_config().get("control_password") or "").strip()


def control_password_required() -> bool:
    return bool(control_password())


def relay_provided_control_password(job: dict[str, object]) -> str:
    payload = job.get("payload")
    if isinstance(payload, dict):
        value = str(payload.get("__control_password") or "").strip()
        if value:
            return value
    query = job.get("query")
    if isinstance(query, dict):
        value = str(query.get("__control_password") or "").strip()
        if value:
            return value
    return ""


def relay_control_password_ok(provided_password: str) -> bool:
    expected = control_password()
    if not expected:
        return True
    provided = str(provided_password or "").strip()
    return bool(provided) and hmac.compare_digest(provided, expected)


def relay_password_error_response() -> tuple[int, dict[str, object]]:
    return HTTPStatus.UNAUTHORIZED, {
        "ok": False,
        "message": "Enter the Mac control password to continue.",
        "password_required": True,
    }


def relay_request_json(method: str, url: str, payload: dict[str, object] | None = None, timeout: float = 15.0) -> dict[str, object]:
    data: bytes | None = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib_request.Request(url, data=data, headers=headers, method=method.upper())
    try:
        with urllib_request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
    except urllib_error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {}
        message = str(parsed.get("message") or raw or f"Relay request failed with HTTP {exc.code}.").strip()
        raise RuntimeError(message)
    except urllib_error.URLError as exc:
        raise RuntimeError(str(exc.reason or exc)) from exc

    if not raw.strip():
        return {}
    try:
        parsed = json.loads(raw)
    except Exception as exc:
        raise RuntimeError(f"Relay returned invalid JSON: {raw[:200]}") from exc
    if not isinstance(parsed, dict):
        raise RuntimeError("Relay returned invalid JSON payload.")
    return parsed


def source_videos(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.iterdir()
        if path.is_file() and path.suffix.lower() in ALLOWED_SOURCE_VIDEO_EXTENSIONS and not path.name.startswith(".")
    )


def sanitize_source_video_filename(raw_name: str, content_type: str = "") -> str:
    text = unquote(str(raw_name or "").strip())
    candidate = Path(text).name
    stem = Path(candidate).stem.strip() if candidate else ""
    ext = Path(candidate).suffix.lower() if candidate else ""

    if ext not in ALLOWED_SOURCE_VIDEO_EXTENSIONS:
        ext = CONTENT_TYPE_EXTENSION_MAP.get(content_type.lower().strip(), ".mp4")
    if ext not in ALLOWED_SOURCE_VIDEO_EXTENSIONS:
        ext = ".mp4"

    safe_stem = re.sub(r"[^A-Za-z0-9._ -]+", "_", stem).strip(" ._-")
    if not safe_stem:
        safe_stem = "iphone_source_video"

    return f"{safe_stem}{ext}"


def unique_source_video_target(file_name: str) -> Path:
    target = ROOT_DIR / file_name
    if not target.exists():
        return target

    stem = target.stem
    ext = target.suffix
    counter = 2
    while True:
        candidate = ROOT_DIR / f"{stem}_{counter}{ext}"
        if not candidate.exists():
            return candidate
        counter += 1


def package_dirs(root: Path) -> list[Path]:
    packages = []
    for path in root.iterdir():
        if path.is_dir() and path.name.endswith("_Reels_Package"):
            try:
                int(path.name.split("_", 1)[0])
            except ValueError:
                continue
            packages.append(path)
    return sorted(packages, key=lambda item: int(item.name.split("_", 1)[0]))


def package_path_for_name(package_name: str) -> Path:
    raw = str(package_name or "").strip()
    if not raw or "/" in raw or "\\" in raw or ".." in raw:
        raise ValueError("Invalid package name.")
    path = (ROOT_DIR / raw).resolve()
    try:
        path.relative_to(ROOT_DIR.resolve())
    except Exception as exc:
        raise ValueError("Package path is outside the root folder.") from exc
    return path


def preferred_reels_base_name(package_dir: Path) -> str:
    package_name = package_dir.name
    prefix = package_name.split("_", 1)[0].strip()
    if prefix.isdigit():
        return f"Reels{prefix}"
    return package_dir.stem


def preferred_package_media_path(package_dir: Path, extensions: set[str], preferred_names: list[str]) -> Path | None:
    lowered_exts = {ext.lower().lstrip(".") for ext in extensions}
    for preferred_name in preferred_names:
        candidate = package_dir / preferred_name
        if candidate.exists() and candidate.is_file():
            return candidate

    candidates = [
        path
        for path in package_dir.iterdir()
        if path.is_file() and path.suffix.lower().lstrip(".") in lowered_exts and not path.name.startswith(".")
    ]
    if not candidates:
        return None
    return sorted(candidates)[0]


def load_package_card(package_dir: Path) -> dict[str, object] | None:
    if not package_dir.exists() or not package_dir.is_dir():
        return None

    html_path = package_dir / "copy_title.html"
    base_name = preferred_reels_base_name(package_dir)
    video_path = preferred_package_media_path(
        package_dir,
        {"mp4", "mov", "m4v"},
        [f"{base_name}.mp4", "edited_reel_9x16_hd_0.90x_15s.mp4"],
    )
    thumb_path = preferred_package_media_path(
        package_dir,
        {"jpg", "jpeg", "png"},
        [f"{base_name}.jpg", "thumbnail_1080x1920.jpg"],
    )

    html_text = ""
    try:
        html_text = html_path.read_text(encoding="utf-8")
    except Exception:
        html_text = ""

    source_match = re.search(r'<p class="meta">(.*?)</p>', html_text, re.IGNORECASE | re.DOTALL)
    title_match = re.search(r'<textarea id="titleField" readonly>(.*?)</textarea>', html_text, re.IGNORECASE | re.DOTALL)
    source_name = html.unescape((source_match.group(1) if source_match else "").strip()) or (video_path.name if video_path else package_dir.name)
    title = html.unescape((title_match.group(1) if title_match else "").strip()) or "No title found."

    return {
        "id": package_dir.name,
        "package_name": package_dir.name,
        "source_name": source_name,
        "video_name": video_path.name if video_path else "",
        "title": re.sub(r"\s+", " ", title).strip(),
        "has_thumbnail": bool(thumb_path and thumb_path.exists()),
        "thumbnail_name": thumb_path.name if thumb_path else "",
    }


def load_package_cards() -> list[dict[str, object]]:
    cards: list[dict[str, object]] = []
    for package_dir in reversed(package_dirs(ROOT_DIR)):
        card = load_package_card(package_dir)
        if card:
            cards.append(card)
    return cards


def thumbnail_path_for_package(package_name: str) -> Path | None:
    package_dir = package_path_for_name(package_name)
    if not package_dir.exists() or not package_dir.is_dir():
        return None
    base_name = preferred_reels_base_name(package_dir)
    return preferred_package_media_path(
        package_dir,
        {"jpg", "jpeg", "png"},
        [f"{base_name}.jpg", "thumbnail_1080x1920.jpg"],
    )


def normalize_video_ids(values: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []

    for value in values:
        raw = str(value).strip()
        if not raw:
            continue

        for match in VIDEO_ID_PATTERN.finditer(raw):
            video_id = match.group(0).strip()
            if not video_id:
                continue
            key = video_id.lower()
            if key in seen:
                continue
            seen.add(key)
            ordered.append(video_id)

    return ordered


def extract_video_ids_from_text(raw: str) -> list[str]:
    return normalize_video_ids([raw])


def load_saved_api_keys() -> dict[str, str]:
    if not API_KEYS_FILE.exists():
        return {}
    try:
        payload = json.loads(API_KEYS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}
    if not isinstance(payload, dict):
        return {}
    return {str(key): str(value) for key, value in payload.items() if isinstance(value, str)}


def normalize_provider(value: str | None) -> str:
    normalized = (value or AI_PROVIDER_DEFAULT).strip().lower()
    if normalized in {AI_PROVIDER_OPENAI, AI_PROVIDER_GEMINI}:
        return normalized
    return AI_PROVIDER_DEFAULT


def save_api_keys(
    openai_key: str | None = None,
    gemini_key: str | None = None,
    ai_provider: str | None = None,
) -> None:
    payload = load_saved_api_keys()
    if openai_key is not None:
        payload["OPENAI_API_KEY"] = openai_key
    if gemini_key is not None:
        payload["GEMINI_API_KEY"] = gemini_key
        payload["GOOGLE_API_KEY"] = gemini_key
    if ai_provider is not None:
        payload["AI_PROVIDER"] = normalize_provider(ai_provider)
    API_KEYS_FILE.parent.mkdir(parents=True, exist_ok=True)
    API_KEYS_FILE.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    try:
        API_KEYS_FILE.chmod(0o600)
    except Exception:
        pass


def resolve_api_key(*names: str) -> str | None:
    saved = load_saved_api_keys()
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
        value = saved.get(name)
        if value:
            return value
    return None


def resolve_setting(name: str) -> str | None:
    value = os.environ.get(name)
    if value:
        return value
    return load_saved_api_keys().get(name)


def resolve_ai_provider() -> str:
    return normalize_provider(resolve_setting("AI_PROVIDER"))


def provider_label(provider: str) -> str:
    return "Gemini" if provider == AI_PROVIDER_GEMINI else "OpenAI"


def mask_key(value: str | None) -> str:
    if not value:
        return "Not set"
    if len(value) <= 8:
        return "Saved"
    return f"Saved (...{value[-4:]})"


def normalize_name(value: str | None) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip().casefold()


def parse_folder_names(value: object) -> list[str]:
    if isinstance(value, list):
        raw_parts = [str(item) for item in value]
    else:
        raw_parts = re.split(r"[\s,]+", str(value or ""))
    ordered: list[str] = []
    seen: set[str] = set()
    for raw_part in raw_parts:
        item = raw_part.strip()
        if not item:
            continue
        key = item.casefold()
        if key in seen:
            continue
        seen.add(key)
        ordered.append(item)
    return ordered


def load_chrome_profiles() -> list[dict[str, str]]:
    if not CHROME_LOCAL_STATE.exists():
        return []
    try:
        payload = json.loads(CHROME_LOCAL_STATE.read_text(encoding="utf-8"))
    except Exception:
        return []

    profile_block = payload.get("profile", {}) if isinstance(payload, dict) else {}
    info_cache = profile_block.get("info_cache", {}) if isinstance(profile_block, dict) else {}
    profiles: list[dict[str, str]] = []
    for directory, info in info_cache.items():
        if not isinstance(info, dict):
            continue
        name = str(info.get("name") or directory).strip()
        if not name:
            continue
        profiles.append({"name": name, "directory": str(directory)})
    profiles.sort(key=lambda item: item["name"].casefold())
    return profiles


def find_profile_directory(profile_name: str) -> str | None:
    target = normalize_name(profile_name)
    for item in load_chrome_profiles():
        if normalize_name(item["name"]) == target:
            return item["directory"]
    return None


def load_state_snapshot(state_path: Path) -> dict:
    if not state_path.exists():
        return {}
    try:
        payload = json.loads(state_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def find_profile_state(state_path: Path, profile_name: str, page_name: str) -> dict | None:
    state = load_state_snapshot(state_path)
    profiles = state.get("profiles", {}) if isinstance(state, dict) else {}
    if not isinstance(profiles, dict):
        return None

    target_profile = normalize_name(profile_name)
    target_page = normalize_name(page_name)
    matches: list[dict] = []
    for profile_state in profiles.values():
        if not isinstance(profile_state, dict):
            continue
        if target_profile and normalize_name(profile_state.get("profile_name")) != target_profile:
            continue
        if target_page and normalize_name(profile_state.get("page_name")) != target_page:
            continue
        matches.append(profile_state)
    if not matches:
        return None
    matches.sort(key=lambda item: item.get("recorded_at") or item.get("last_anchor_at") or item.get("next_slot_at") or "")
    return matches[-1]


def format_state_summary(profile_state: dict | None) -> str:
    if not profile_state:
        return "No saved memory for this Chrome + page yet."
    return (
        f"Chrome: {profile_state.get('profile_name') or '-'}\n"
        f"Page: {profile_state.get('page_name') or '-'}\n"
        f"Last Package: {profile_state.get('last_package_name') or '-'}\n"
        f"Last Anchor: {profile_state.get('last_anchor_label_ampm') or '-'}\n"
        f"Next Slot: {profile_state.get('next_slot_label_ampm') or '-'}\n"
        f"Last Action: {profile_state.get('last_action') or '-'}"
    )


def quit_google_chrome() -> None:
    subprocess.run(
        ["osascript", "-e", 'tell application "Google Chrome" to quit'],
        text=True,
        capture_output=True,
        check=False,
    )


def open_chrome_profile(profile_directory: str) -> None:
    subprocess.run(
        [
            "open",
            "-na",
            CHROME_APP,
            "--args",
            f"--profile-directory={profile_directory}",
            FACEBOOK_CONTENT_LIBRARY_URL,
        ],
        text=True,
        capture_output=True,
        check=False,
    )


def build_facebook_post_payload(payload: dict[str, object]) -> tuple[Path, str, str, list[str], int, bool, bool, bool]:
    root = Path(str(payload.get("root") or ROOT_DIR)).expanduser()
    chrome_name = str(payload.get("chrome_name") or "").strip()
    page_name = str(payload.get("page_name") or "").strip()
    packages = parse_folder_names(payload.get("folders") or payload.get("packages") or "")
    interval_raw = str(payload.get("interval_minutes") or "").strip()
    interval = int(interval_raw) if interval_raw.isdigit() and int(interval_raw) > 0 else 30
    close_after_finish = bool(payload.get("close_after_finish", True))
    close_after_each = bool(payload.get("close_after_each", False))
    post_now_advance_slot = bool(payload.get("post_now_advance_slot", False))
    return (
        root,
        chrome_name,
        page_name,
        packages,
        interval,
        close_after_finish,
        close_after_each,
        post_now_advance_slot,
    )


def parse_json_from_output(output: str) -> dict[str, object]:
    text = (output or "").strip()
    if not text:
        return {}
    lines = text.splitlines()
    for start in range(len(lines)):
        candidate = "\n".join(lines[start:]).strip()
        if not candidate.startswith("{"):
            continue
        try:
            parsed = json.loads(candidate)
        except Exception:
            continue
        if isinstance(parsed, dict):
            return parsed
    return {}


def run_facebook_preflight(payload: dict[str, object]) -> dict[str, object]:
    root, chrome_name, page_name, packages, interval, _close_after_finish, _close_after_each, _post_now_advance_slot = (
        build_facebook_post_payload(payload)
    )
    if not chrome_name:
        raise RuntimeError("Chrome Name is required.")
    if not page_name:
        raise RuntimeError("Page is required.")
    if not packages:
        raise RuntimeError("Please enter at least one folder.")

    first_package = root / packages[0]
    if not first_package.exists():
        raise RuntimeError(f"Package folder not found: {first_package}")

    command = [
        "python3",
        str(FACEBOOK_PREFLIGHT_SCRIPT),
        str(first_package),
        "--page-name",
        page_name,
        "--interval-minutes",
        str(interval),
        "--profile-name",
        chrome_name,
    ]
    result = subprocess.run(
        command,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip() or "Facebook preflight failed."
        raise RuntimeError(message)

    parsed = parse_json_from_output(result.stdout or "")
    profile_state = find_profile_state(root / ".fb_reels_publish_state.json", chrome_name, page_name)
    summary = format_state_summary(profile_state)
    decision_preview = parsed.get("decision_preview", {}) if isinstance(parsed, dict) else {}
    action = str(decision_preview.get("action") or "-").strip()
    effective_label = str(decision_preview.get("effective_label") or "-").strip()
    lines = [
        summary,
        f"Decision: {action or '-'}",
        f"Target Time: {effective_label or '-'}",
    ]
    return {
        "ok": True,
        "message": "Facebook preflight finished.",
        "summary": "\n".join(line for line in lines if line),
        "result": parsed,
    }


def build_facebook_post_bootstrap_response(chrome_name: str = "", page_name: str = "") -> dict[str, object]:
    profile_state = find_profile_state(ROOT_DIR / ".fb_reels_publish_state.json", chrome_name, page_name)
    mac_user_name = current_mac_user_name()
    mac_device_name = current_mac_device_name()
    return {
        "ok": True,
        "profiles": [item["name"] for item in load_chrome_profiles()],
        "default_root": str(ROOT_DIR),
        "memory_summary": format_state_summary(profile_state),
        "mac_user_name": mac_user_name,
        "mac_device_name": mac_device_name,
        "mac_display_name": f"{mac_device_name} • user {mac_user_name}",
        "relay_enabled": bool(control_relay_base_url() and control_relay_client_token()),
        "relay_base_url": control_relay_base_url(),
        "relay_client_token": control_relay_client_token(),
        "relay_client_url": control_relay_client_base_url(),
        "relay_user_name": control_relay_user_name(),
        "relay_mac_name": control_relay_mac_name(),
        "password_required": control_password_required(),
    }


class ManagerState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.proc: subprocess.Popen[str] | None = None
        self.remote_running = False
        self.logs: deque[str] = deque(maxlen=500)
        self.alerts: deque[dict[str, object]] = deque(maxlen=32)
        self.next_alert_id = 1
        self.status = "Idle"
        self.detail = "Ready."
        self.progress_percent = 0
        self.progress_label = ""

    def emit_alert(self, title: str, message: str, level: str = "info") -> None:
        safe_title = sanitize_alert_text(title, "Soranin", 120)
        safe_message = sanitize_alert_text(message, "Done.", 240)
        safe_level = sanitize_alert_text(level, "info", 24).lower()
        with self.lock:
            alert = {
                "id": self.next_alert_id,
                "title": safe_title,
                "message": safe_message,
                "level": safe_level,
                "created_at": time.time(),
            }
            self.next_alert_id += 1
            self.alerts.append(alert)

    def append_log(self, line: str) -> None:
        with self.lock:
            self.logs.append(line)
            self._update_status_from_line(line)

    def _update_status_from_line(self, line: str) -> None:
        progress_match = FACEBOOK_PROGRESS_PATTERN.match(line)
        if progress_match:
            try:
                self.progress_percent = max(0, min(100, int(progress_match.group(1))))
            except Exception:
                self.progress_percent = 0
            self.progress_label = progress_match.group(2).strip()
            self.status = "Running"
            if self.progress_label:
                self.detail = self.progress_label
            return
        if line.startswith("Found "):
            self.status = "Running"
            self.detail = line
        elif line.startswith("Starting "):
            self.status = "Running"
            self.detail = line
        elif line.startswith("[") and "]" in line:
            self.status = "Running"
            self.detail = line
        elif line.startswith("Done:"):
            self.status = "Running"
            self.detail = line
        elif line == "Batch complete.":
            self.status = "Done"
            self.detail = line
        elif line == "No new source videos found.":
            self.status = "Idle"
            self.detail = line
        elif line == "DONE":
            self.status = "Done"
            self.detail = "Batch complete."
        elif line == "FAILED":
            self.status = "Failed"
            self.detail = "Batch failed."

    def is_running(self) -> bool:
        with self.lock:
            return self.remote_running or (self.proc is not None and self.proc.poll() is None)

    def start(self) -> tuple[bool, str]:
        with self.lock:
            if self.remote_running:
                return False, "A remote flow is already running."
            if self.proc is not None and self.proc.poll() is None:
                return False, "A batch is already running."

            self.logs.clear()
            self.logs.append("WAIT... Processing videos.")
            self.status = "Running"
            self.detail = "Starting batch..."
            self.progress_percent = 0
            self.progress_label = "Starting batch..."

            command = (
                "source ~/.zshrc >/dev/null 2>&1; "
                f"python3 {shlex.quote(str(BATCH_SCRIPT))} {shlex.quote(str(ROOT_DIR))}"
            )
            self.proc = subprocess.Popen(
                ["/bin/zsh", "-lc", command],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            threading.Thread(target=self._consume_output, daemon=True).start()
        self.emit_alert("Soranin on Mac", "Batch started on this Mac.")
        return True, "Batch started."

    def start_remote(self, video_ids: list[str]) -> tuple[bool, str]:
        normalized = normalize_video_ids(video_ids)
        if not normalized:
            return False, "No valid Sora IDs were provided."

        with self.lock:
            if self.remote_running:
                return False, "A remote flow is already running."
            if self.proc is not None and self.proc.poll() is None:
                return False, "A batch is already running."

            self.remote_running = True
            self.logs.clear()
            self.logs.append(f"[remote] Received {len(normalized)} id(s).")
            self.status = "Running"
            self.detail = f"Preparing remote download ({len(normalized)} item(s))..."
            self.progress_percent = 0
            self.progress_label = self.detail

        self.emit_alert(
            "New URL on Mac",
            f"Received {len(normalized)} link(s) from iPhone. Preparing download...",
        )
        threading.Thread(target=self._run_remote_flow, args=(normalized,), daemon=True).start()
        return True, f"Remote flow started for {len(normalized)} item(s)."

    def start_facebook_post(self, payload: dict[str, object]) -> tuple[bool, str]:
        root, chrome_name, page_name, packages, interval, close_after_finish, close_after_each, post_now_advance_slot = (
            build_facebook_post_payload(payload)
        )

        if not chrome_name:
            return False, "Chrome Name is required."
        if not page_name:
            return False, "Page is required."
        if not packages:
            return False, "Please enter at least one folder."

        profile_directory = find_profile_directory(chrome_name)
        if not profile_directory:
            return False, f"Could not find Chrome profile directory for: {chrome_name}"

        with self.lock:
            if self.remote_running:
                return False, "A remote flow is already running."
            if self.proc is not None and self.proc.poll() is None:
                return False, "A batch is already running."

            self.remote_running = True
            self.logs.clear()
            self.logs.append(f"[facebook-post] Chrome: {chrome_name}")
            self.logs.append(f"[facebook-post] Page: {page_name}")
            self.logs.append(f"[facebook-post] Folders: {' '.join(packages)}")
            self.status = "Running"
            self.detail = f"Preparing Facebook post run ({len(packages)} folder(s))..."
            self.progress_percent = 0
            self.progress_label = self.detail
        self.emit_alert(
            "Facebook post on Mac",
            f"Preparing {len(packages)} folder(s) for page {page_name}.",
        )

        thread = threading.Thread(
            target=self._run_facebook_post_flow,
            args=(
                root,
                chrome_name,
                profile_directory,
                page_name,
                packages,
                interval,
                close_after_finish,
                close_after_each,
                post_now_advance_slot,
            ),
            daemon=True,
        )
        thread.start()
        return True, f"Facebook post run started for {len(packages)} folder(s)."

    def _run_facebook_post_flow(
        self,
        root: Path,
        chrome_name: str,
        profile_directory: str,
        page_name: str,
        packages: list[str],
        interval: int,
        close_after_finish: bool,
        close_after_each: bool,
        post_now_advance_slot: bool,
    ) -> None:
        command = [
            "python3",
            str(FACEBOOK_BATCH_SCRIPT),
            str(root),
            "--packages",
            *packages,
            "--page-name",
            page_name,
            "--interval-minutes",
            str(interval),
        ]
        if close_after_finish:
            command.append("--close-after-finish")
        if close_after_each:
            command.append("--close-after-each")
        if post_now_advance_slot:
            command.append("--post-now-advance-slot")

        try:
            self.append_log("[facebook-post] Quitting Google Chrome before run...")
            quit_google_chrome()
            time.sleep(1.0)
            self.append_log(f"[facebook-post] Opening Chrome profile: {chrome_name}")
            open_chrome_profile(profile_directory)
            time.sleep(10.0)

            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            with self.lock:
                self.remote_running = False
                self.proc = process
                self.status = "Running"
                self.detail = "Facebook post batch running..."
                self.progress_label = self.detail

            if process.stdout is not None:
                for raw_line in process.stdout:
                    line = raw_line.rstrip()
                    if not line:
                        continue
                    self.append_log(line if line.startswith("[") else f"[facebook-post] {line}")

            returncode = process.wait()
            should_emit_done = False
            should_emit_failed = False
            failed_message = ""
            with self.lock:
                if returncode == 0:
                    self.logs.append("DONE")
                    self.status = "Done"
                    self.detail = "Facebook post batch complete."
                    self.progress_percent = 100
                    self.progress_label = "Facebook post batch complete."
                    should_emit_done = True
                else:
                    self.logs.append("FAILED")
                    self.status = "Failed"
                    self.detail = f"Facebook post batch failed (exit {returncode})."
                    self.progress_label = self.detail
                    should_emit_failed = True
                    failed_message = f"Facebook post batch failed with exit code {returncode}."
                self.proc = None
            if should_emit_done:
                self.emit_alert("Facebook post done", "Facebook post batch finished on this Mac.")
            elif should_emit_failed:
                self.emit_alert("Facebook post failed", failed_message, "error")
            return
        except Exception as exc:
            with self.lock:
                self.remote_running = False
                self.proc = None
                self.logs.append(f"[facebook-post] FAILED: {exc}")
                self.logs.append("FAILED")
                self.status = "Failed"
                self.detail = f"Facebook post flow failed: {exc}"
                self.progress_label = self.detail
            self.emit_alert("Facebook post failed", str(exc), "error")
            return

    def _run_remote_flow(self, video_ids: list[str]) -> None:
        command = (
            "source ~/.zshrc >/dev/null 2>&1; "
            f"python3 {shlex.quote(str(DOWNLOADER_SCRIPT))} "
            f"{shlex.quote(str(ROOT_DIR))} "
            + " ".join(shlex.quote(video_id) for video_id in video_ids)
        )

        try:
            self.emit_alert(
                "Running download on Mac",
                f"Downloading {len(video_ids)} item(s) on this Mac now.",
            )
            proc = subprocess.Popen(
                ["/bin/zsh", "-lc", command],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )

            if proc.stdout is not None:
                for raw_line in proc.stdout:
                    line = raw_line.rstrip()
                    if not line:
                        continue
                    if line.startswith("[remote]"):
                        self.append_log(line)
                    else:
                        self.append_log(f"[remote] {line}")

            returncode = proc.wait()
            if returncode != 0:
                with self.lock:
                    self.remote_running = False
                    self.logs.append("FAILED")
                    self.status = "Failed"
                    self.detail = f"Remote download failed (exit {returncode})."
                    self.progress_label = self.detail
                self.emit_alert(
                    "Mac download failed",
                    f"Remote download failed with exit code {returncode}.",
                    "error",
                )
                return

            self.append_log("[remote] Download complete. Starting batch...")
            self.emit_alert(
                "Download done on Mac",
                "Download finished. Starting edit / batch now.",
            )
            with self.lock:
                self.remote_running = False
            ok, message = self.start()
            if not ok:
                with self.lock:
                    self.logs.append(f"[remote] {message}")
                    self.status = "Failed"
                    self.detail = message
                    self.progress_label = self.detail
                self.emit_alert("Mac batch failed", message, "error")
            return
        except Exception as exc:
            with self.lock:
                self.remote_running = False
                self.logs.append(f"[remote] FAILED: {exc}")
                self.logs.append("FAILED")
                self.status = "Failed"
                self.detail = f"Remote flow failed: {exc}"
                self.progress_label = self.detail
            self.emit_alert("Mac remote flow failed", str(exc), "error")
            return

    def _consume_output(self) -> None:
        proc: subprocess.Popen[str] | None
        with self.lock:
            proc = self.proc
        if proc is None:
            return

        if proc.stdout is not None:
            for raw_line in proc.stdout:
                self.append_log(raw_line.rstrip())

        returncode = proc.wait()
        should_emit_done = False
        should_emit_failed = False
        failed_message = ""
        with self.lock:
            if returncode == 0:
                self.logs.append("DONE")
                if self.status == "Running":
                    self.status = "Done"
                    self.detail = "Batch complete."
                self.progress_percent = 100
                self.progress_label = self.detail
                should_emit_done = True
            else:
                self.logs.append("FAILED")
                self.status = "Failed"
                self.detail = f"Exit code {returncode}"
                self.progress_label = self.detail
                should_emit_failed = True
                failed_message = f"Batch failed with exit code {returncode}."
            self.proc = None
        if should_emit_done:
            self.emit_alert("Mac edit done", "Download / edit flow finished on this Mac.")
        elif should_emit_failed:
            self.emit_alert("Mac batch failed", failed_message, "error")

    def snapshot(self) -> dict[str, object]:
        ROOT_DIR.mkdir(parents=True, exist_ok=True)
        sources = source_videos(ROOT_DIR)
        packages = package_dirs(ROOT_DIR)
        openai_key = resolve_api_key("OPENAI_API_KEY")
        gemini_key = resolve_api_key("GEMINI_API_KEY", "GOOGLE_API_KEY")
        provider = resolve_ai_provider()
        mac_user_name = current_mac_user_name()
        mac_device_name = current_mac_device_name()
        mac_display_name = f"{mac_device_name} • user {mac_user_name}"
        with self.lock:
            is_running = self.remote_running or (self.proc is not None and self.proc.poll() is None)
            return {
                "status": self.status,
                "detail": self.detail,
                "progress_percent": self.progress_percent,
                "progress_label": self.progress_label,
                "running": is_running,
                "remote_running": self.remote_running,
                "source_count": len(sources),
                "package_count": len(packages),
                "latest_package": packages[-1].name if packages else "-",
                "logs": list(self.logs),
                "alerts": list(self.alerts),
                "latest_alert": self.alerts[-1] if self.alerts else None,
                "openai_key_status": mask_key(openai_key),
                "gemini_key_status": mask_key(gemini_key),
                "ai_provider": provider,
                "ai_provider_label": provider_label(provider),
                "mac_user_name": mac_user_name,
                "mac_device_name": mac_device_name,
                "mac_display_name": mac_display_name,
                "relay_enabled": bool(control_relay_base_url() and control_relay_client_token()),
                "relay_base_url": control_relay_base_url(),
                "relay_client_token": control_relay_client_token(),
                "relay_client_url": control_relay_client_base_url(),
                "relay_user_name": control_relay_user_name(),
                "relay_mac_name": control_relay_mac_name(),
                "password_required": control_password_required(),
            }


STATE = ManagerState()


def execute_relay_job(job: dict[str, object]) -> tuple[int, dict[str, object]]:
    request_path = str(job.get("request_path") or "").strip()
    payload = job.get("payload")
    if not isinstance(payload, dict):
        payload = {}
    query = job.get("query")
    if not isinstance(query, dict):
        query = {}
    provided_password = relay_provided_control_password(job)

    protected_paths = {
        "/facebook-post-bootstrap",
        "/facebook-packages",
        "/source-video-upload",
        "/facebook-post-preflight",
        "/facebook-post-run",
        "/quit-chrome",
        "/facebook-package-delete",
        "/remote-run",
    }
    if request_path in protected_paths and not relay_control_password_ok(provided_password):
        return relay_password_error_response()

    if request_path == "/facebook-post-bootstrap":
        chrome_name = str(query.get("chrome_name") or "").strip()
        page_name = str(query.get("page_name") or "").strip()
        return HTTPStatus.OK, build_facebook_post_bootstrap_response(chrome_name, page_name)

    if request_path == "/facebook-packages":
        return HTTPStatus.OK, {"ok": True, "packages": load_package_cards()}

    if request_path == "/facebook-package-thumbnail":
        package_name = str(query.get("package_name") or payload.get("package_name") or "").strip()
        try:
            thumbnail_path = thumbnail_path_for_package(package_name)
        except ValueError as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
        if thumbnail_path is None:
            return HTTPStatus.NOT_FOUND, {"ok": False, "message": "Thumbnail not found."}
        mime_type, _encoding = mimetypes.guess_type(thumbnail_path.name)
        mime_type = mime_type or "application/octet-stream"
        return HTTPStatus.OK, {
            "ok": True,
            "file_name": thumbnail_path.name,
            "mime_type": mime_type,
            "data_base64": base64.b64encode(thumbnail_path.read_bytes()).decode("ascii"),
        }

    if request_path == "/source-video-upload":
        file_name = str(payload.get("file_name") or "").strip()
        content_type = str(payload.get("content_type") or "").strip().lower()
        file_data_base64 = str(payload.get("file_data_base64") or "").strip()
        if not file_data_base64:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": "Upload body is empty."}
        try:
            body = base64.b64decode(file_data_base64, validate=True)
        except Exception:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": "Upload body is invalid."}
        target_name = sanitize_source_video_filename(file_name, content_type)
        target_path = unique_source_video_target(target_name)
        try:
            ROOT_DIR.mkdir(parents=True, exist_ok=True)
            target_path.write_bytes(body)
        except Exception as exc:
            return HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "message": str(exc)}
        STATE.emit_alert(
            "New video on Mac",
            f"{target_path.name} was added to Drop Videos.",
        )
        return HTTPStatus.OK, {
            "ok": True,
            "message": f"Saved {target_path.name} to Drop Videos on Mac.",
            "file_name": target_path.name,
            "saved_path": str(target_path),
            "source_count": len(source_videos(ROOT_DIR)),
        }

    if request_path == "/facebook-post-preflight":
        try:
            return HTTPStatus.OK, run_facebook_preflight(payload)
        except Exception as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}

    if request_path == "/facebook-post-run":
        ok, message = STATE.start_facebook_post(payload)
        return (HTTPStatus.OK if ok else HTTPStatus.BAD_REQUEST), {"ok": ok, "message": message}

    if request_path == "/quit-chrome":
        quit_google_chrome()
        return HTTPStatus.OK, {"ok": True, "message": "Google Chrome quit."}

    if request_path == "/facebook-package-delete":
        package_name = str(payload.get("package_name") or "").strip()
        try:
            package_path = package_path_for_name(package_name)
        except ValueError as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
        if not package_path.exists() or not package_path.is_dir():
            return HTTPStatus.NOT_FOUND, {"ok": False, "message": "Package not found."}
        try:
            shutil.rmtree(package_path)
        except Exception as exc:
            return HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "message": str(exc)}
        return HTTPStatus.OK, {
            "ok": True,
            "message": f"Deleted {package_name}.",
            "package_name": package_name,
            "packages": load_package_cards(),
        }

    if request_path == "/remote-run":
        values: list[str] = []
        raw_ids = payload.get("video_ids")
        if isinstance(raw_ids, list):
            values.extend(str(item) for item in raw_ids)
        raw_input = str(payload.get("raw_input") or "").strip()
        if raw_input:
            values.extend(extract_video_ids_from_text(raw_input))
        normalized_ids = normalize_video_ids(values)
        ok, message = STATE.start_remote(normalized_ids)
        status = HTTPStatus.OK if ok else HTTPStatus.BAD_REQUEST
        return status, {"ok": ok, "message": message, "count": len(normalized_ids)}

    return HTTPStatus.NOT_FOUND, {"ok": False, "message": f"Unsupported relay job path: {request_path}"}


def relay_worker_loop(base_url: str, poll_seconds: float) -> None:
    client_base_url = control_relay_client_base_url()
    if not client_base_url:
        return
    while True:
        try:
            relay_request_json(
                "POST",
                f"{client_base_url}/heartbeat",
                {
                    "snapshot": STATE.snapshot(),
                },
                timeout=10.0,
            )
            claimed = relay_request_json("POST", f"{client_base_url}/jobs/claim", {}, timeout=15.0)
            job = claimed.get("job")
            if isinstance(job, dict) and job.get("id"):
                job_id = str(job.get("id"))
                try:
                    response_status, response_body = execute_relay_job(job)
                except Exception as exc:
                    response_status = int(HTTPStatus.INTERNAL_SERVER_ERROR)
                    response_body = {"ok": False, "message": str(exc)}
                relay_request_json(
                    "POST",
                    f"{client_base_url}/jobs/{job_id}/finish",
                    {
                        "response_status": int(response_status),
                        "response_body": response_body,
                    },
                    timeout=30.0,
                )
                continue
        except Exception:
            pass
        time.sleep(max(1.0, poll_seconds))


HTML_PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Reels Manager</title>
  <style>
    :root {
      --card: rgba(255, 250, 244, 0.95);
      --ink: #1c1814;
      --muted: #6c635a;
      --line: #ddd1c1;
      --accent: #c85d21;
      --accent-2: #1a936f;
      --shadow: 0 12px 28px rgba(28, 24, 20, 0.08);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: linear-gradient(180deg, #f8f2ea 0%, #eee0cf 100%);
      color: var(--ink);
    }
    main { max-width: 1080px; margin: 0 auto; padding: 24px; }
    .topbar {
      display: flex;
      justify-content: space-between;
      align-items: end;
      gap: 16px;
      margin-bottom: 16px;
    }
    .topbar-actions {
      display: flex;
      gap: 10px;
      align-items: center;
      flex-wrap: wrap;
    }
    h1 { margin: 0; font-size: 32px; }
    .sub { color: var(--muted); margin-top: 6px; word-break: break-all; }
    .status-badge {
      padding: 10px 14px;
      border-radius: 999px;
      background: #fff;
      border: 1px solid var(--line);
      font-weight: 700;
    }
    .mini-btn {
      border: 1px solid var(--line);
      background: #fff;
      color: var(--ink);
      border-radius: 999px;
      padding: 10px 14px;
      font-size: 13px;
      font-weight: 700;
      cursor: pointer;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 12px;
      margin-bottom: 16px;
    }
    .card {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 16px;
      box-shadow: var(--shadow);
    }
    .label {
      color: var(--muted);
      font-size: 13px;
      margin-bottom: 8px;
    }
    .value { font-size: 22px; font-weight: 700; }
    .provider-value {
      display: flex;
      align-items: center;
      gap: 10px;
      font-size: 18px;
      font-weight: 700;
    }
    .provider-logo {
      width: 34px;
      height: 34px;
      border-radius: 12px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      color: #fff;
      font-size: 15px;
      font-weight: 800;
      letter-spacing: 0.02em;
      flex: 0 0 auto;
    }
    .provider-logo.openai { background: #111; }
    .provider-logo.gemini {
      background: linear-gradient(135deg, #5b8cff 0%, #7a5cff 40%, #00b7c3 100%);
    }
    .controls {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      margin-bottom: 16px;
    }
    button {
      border: 0;
      border-radius: 999px;
      padding: 12px 18px;
      font-size: 15px;
      font-weight: 700;
      cursor: pointer;
    }
    button.primary { background: var(--accent); color: #fff; }
    button.secondary { background: #fff; color: var(--ink); border: 1px solid var(--line); }
    button:disabled { opacity: 0.55; cursor: not-allowed; }
    .detail {
      margin-bottom: 12px;
      color: var(--muted);
      font-weight: 600;
    }
    .modal-backdrop {
      position: fixed;
      inset: 0;
      background: rgba(15, 11, 8, 0.48);
      display: none;
      align-items: center;
      justify-content: center;
      padding: 24px;
    }
    .modal-backdrop.show { display: flex; }
    .modal {
      width: min(760px, 100%);
      background: #fffaf4;
      border: 1px solid var(--line);
      border-radius: 24px;
      box-shadow: 0 24px 70px rgba(28, 24, 20, 0.2);
      padding: 20px;
    }
    .modal-top {
      display: flex;
      justify-content: space-between;
      align-items: start;
      gap: 12px;
      margin-bottom: 12px;
    }
    .modal-title { margin: 0; font-size: 22px; }
    .modal-note { margin: 6px 0 0; color: var(--muted); font-size: 14px; }
    .close-btn {
      border: 1px solid var(--line);
      background: #fff;
      color: var(--ink);
      width: 40px;
      height: 40px;
      border-radius: 999px;
      font-size: 22px;
      line-height: 1;
      padding: 0;
    }
    .provider-options {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 12px;
      margin-bottom: 14px;
    }
    .provider-option input { display: none; }
    .provider-tile {
      display: flex;
      align-items: center;
      gap: 12px;
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 14px;
      background: #fff;
      cursor: pointer;
    }
    .provider-option input:checked + .provider-tile {
      border-color: var(--accent-2);
      box-shadow: 0 0 0 2px rgba(26, 147, 111, 0.14);
    }
    .provider-text strong { display: block; font-size: 15px; }
    .provider-text span { color: var(--muted); font-size: 13px; }
    .field-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 14px;
      margin-bottom: 14px;
    }
    .field-block label {
      display: block;
      font-size: 13px;
      color: var(--muted);
      margin-bottom: 8px;
      font-weight: 700;
    }
    .field-block input {
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 12px 14px;
      font-size: 14px;
      background: #fff;
    }
    .key-status {
      margin-top: 8px;
      color: var(--muted);
      font-size: 13px;
      font-weight: 600;
    }
    .modal-actions {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
    }
    .keys-message {
      color: var(--muted);
      font-size: 13px;
      font-weight: 600;
    }
    .toast {
      position: fixed;
      right: 20px;
      bottom: 20px;
      background: #173f35;
      color: #fff;
      padding: 14px 16px;
      border-radius: 16px;
      box-shadow: 0 18px 40px rgba(10, 29, 23, 0.28);
      display: none;
      align-items: center;
      gap: 10px;
      font-weight: 700;
    }
    .toast.show { display: inline-flex; }
    .toast-check {
      width: 24px;
      height: 24px;
      border-radius: 999px;
      background: rgba(255,255,255,0.16);
      display: inline-flex;
      align-items: center;
      justify-content: center;
    }
    @media (max-width: 860px) {
      .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .field-grid, .provider-options { grid-template-columns: 1fr; }
    }
    @media (max-width: 560px) {
      .topbar { flex-direction: column; align-items: stretch; }
      .grid { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <main>
    <section class="topbar">
      <div>
        <h1>Reels Manager</h1>
        <div class="sub">__ROOT_DIR__</div>
      </div>
      <div class="topbar-actions">
        <button class="mini-btn" id="keysToggleBtn">API Keys</button>
        <div class="status-badge" id="statusBadge">Idle</div>
      </div>
    </section>

    <section class="grid">
      <div class="card"><div class="label">Source Videos</div><div class="value" id="sourceCount">0</div></div>
      <div class="card"><div class="label">Packages</div><div class="value" id="packageCount">0</div></div>
      <div class="card"><div class="label">Latest Package</div><div class="value" id="latestPackage">-</div></div>
      <div class="card"><div class="label">Active AI</div><div class="provider-value" id="providerCard"></div></div>
    </section>

    <section class="controls">
      <button class="primary" id="startBtn">Start</button>
      <button class="secondary" id="openFolderBtn">Open Folder</button>
      <button class="secondary" id="openLatestBtn">Open Latest Package</button>
      <button class="secondary" id="refreshBtn">Refresh</button>
    </section>

    <div class="detail" id="detailText">Ready.</div>
  </main>

  <div class="modal-backdrop" id="keysModal">
    <div class="modal">
      <div class="modal-top">
        <div>
          <h2 class="modal-title">AI Settings</h2>
          <p class="modal-note">ជ្រើស AI ដែលត្រូវដំណើរការ ហើយរក្សាទុក API key នៅទីនេះ។ ទុក input ទទេ បើមិនចង់ប្តូរ key ចាស់។</p>
        </div>
        <button class="close-btn" id="closeKeysBtn" type="button">&times;</button>
      </div>

      <div class="provider-options">
        <label class="provider-option">
          <input type="radio" name="aiProvider" value="openai" id="providerOpenAi">
          <span class="provider-tile">
            <span class="provider-logo openai">O</span>
            <span class="provider-text"><strong>OpenAI</strong><span>Current title + thumbnail engine</span></span>
          </span>
        </label>
        <label class="provider-option">
          <input type="radio" name="aiProvider" value="gemini" id="providerGemini">
          <span class="provider-tile">
            <span class="provider-logo gemini">G</span>
            <span class="provider-text"><strong>Gemini</strong><span>Video-aware title + thumbnail engine</span></span>
          </span>
        </label>
      </div>

      <div class="field-grid">
        <div class="field-block">
          <label for="openAiKey">OpenAI API Key</label>
          <input id="openAiKey" type="password" placeholder="Paste OpenAI key">
          <div class="key-status" id="openAiStatus">Not set</div>
        </div>
        <div class="field-block">
          <label for="geminiKey">Google Gemini API Key</label>
          <input id="geminiKey" type="password" placeholder="Paste Gemini key">
          <div class="key-status" id="geminiStatus">Not set</div>
        </div>
      </div>

      <div class="modal-actions">
        <div class="keys-message" id="keysMessage">Save រួច នឹងបង្ហាញសញ្ញាបញ្ជាក់ភ្លាម។</div>
        <button class="primary" id="saveKeysBtn" type="button">Save</button>
      </div>
    </div>
  </div>

  <div class="toast" id="toast">
    <span class="toast-check">✓</span>
    <span id="toastText">Saved.</span>
  </div>

  <script>
    const statusBadge = document.getElementById("statusBadge");
    const sourceCount = document.getElementById("sourceCount");
    const packageCount = document.getElementById("packageCount");
    const latestPackage = document.getElementById("latestPackage");
    const providerCard = document.getElementById("providerCard");
    const detailText = document.getElementById("detailText");
    const startBtn = document.getElementById("startBtn");
    const openAiStatus = document.getElementById("openAiStatus");
    const geminiStatus = document.getElementById("geminiStatus");
    const keysMessage = document.getElementById("keysMessage");
    const openAiKey = document.getElementById("openAiKey");
    const geminiKey = document.getElementById("geminiKey");
    const keysModal = document.getElementById("keysModal");
    const providerOpenAi = document.getElementById("providerOpenAi");
    const providerGemini = document.getElementById("providerGemini");
    const toast = document.getElementById("toast");
    const toastText = document.getElementById("toastText");
    let toastTimer = null;

    function providerMarkup(provider, label) {
      const logoClass = provider === "gemini" ? "provider-logo gemini" : "provider-logo openai";
      const shortLabel = provider === "gemini" ? "G" : "O";
      return `<span class="${logoClass}">${shortLabel}</span><span>${label}</span>`;
    }

    function showToast(message) {
      toastText.textContent = message;
      toast.classList.add("show");
      if (toastTimer) {
        clearTimeout(toastTimer);
      }
      toastTimer = setTimeout(() => toast.classList.remove("show"), 2200);
    }

    function setProvider(provider) {
      providerOpenAi.checked = provider === "openai";
      providerGemini.checked = provider === "gemini";
    }

    async function post(path) {
      const response = await fetch(path, { method: "POST" });
      return await response.json();
    }

    async function postJson(path, payload) {
      const response = await fetch(path, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      });
      return await response.json();
    }

    async function refresh() {
      const response = await fetch("/status");
      const data = await response.json();
      statusBadge.textContent = data.status;
      sourceCount.textContent = data.source_count;
      packageCount.textContent = data.package_count;
      latestPackage.textContent = data.latest_package;
      providerCard.innerHTML = providerMarkup(data.ai_provider, data.ai_provider_label);
      detailText.textContent = data.detail;
      openAiStatus.textContent = data.openai_key_status;
      geminiStatus.textContent = data.gemini_key_status;
      if (!keysModal.classList.contains("show")) {
        setProvider(data.ai_provider);
      }
      startBtn.disabled = data.running;
    }

    document.getElementById("startBtn").addEventListener("click", async () => {
      await post("/start");
      refresh();
    });
    document.getElementById("openFolderBtn").addEventListener("click", async () => {
      await post("/open-root");
    });
    document.getElementById("openLatestBtn").addEventListener("click", async () => {
      await post("/open-latest");
    });
    document.getElementById("refreshBtn").addEventListener("click", refresh);
    document.getElementById("keysToggleBtn").addEventListener("click", () => {
      keysModal.classList.add("show");
    });
    document.getElementById("closeKeysBtn").addEventListener("click", () => {
      keysModal.classList.remove("show");
    });
    keysModal.addEventListener("click", (event) => {
      if (event.target === keysModal) {
        keysModal.classList.remove("show");
      }
    });
    document.getElementById("saveKeysBtn").addEventListener("click", async () => {
      const provider = providerGemini.checked ? "gemini" : "openai";
      const payload = {
        openai_key: openAiKey.value.trim(),
        gemini_key: geminiKey.value.trim(),
        ai_provider: provider
      };
      const result = await postJson("/save-keys", payload);
      keysMessage.textContent = result.message || "Saved.";
      openAiKey.value = "";
      geminiKey.value = "";
      keysModal.classList.remove("show");
      showToast(result.message || "Saved.");
      refresh();
    });

    refresh();
    setInterval(refresh, 1500);
  </script>
</body>
</html>
"""
HTML_PAGE = HTML_PAGE.replace("__ROOT_DIR__", str(ROOT_DIR))


class ReelsDashboardHandler(BaseHTTPRequestHandler):
    def _allowed_headers(self) -> str:
        return "Content-Type, X-Soranin-File-Name, X-Soranin-Password"

    def _request_control_password(self) -> str:
        return str(self.headers.get("X-Soranin-Password") or "").strip()

    def _require_control_password(self) -> bool:
        expected = control_password()
        if not expected:
            return True
        provided = self._request_control_password()
        if provided and hmac.compare_digest(provided, expected):
            return True
        self._send_json(
            {
                "ok": False,
                "message": "Enter the Mac control password to continue.",
                "password_required": True,
            },
            HTTPStatus.UNAUTHORIZED,
        )
        return False

    def _read_json_body(self) -> dict[str, object]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}

    def _read_raw_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _send_json(self, payload: dict[str, object], status: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", self._allowed_headers())
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html: str) -> None:
        body = html.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", self._allowed_headers())
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, file_path: Path) -> None:
        if not file_path.exists() or not file_path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        body = file_path.read_bytes()
        content_type, _ = mimetypes.guess_type(file_path.name)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type or "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", self._allowed_headers())
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", self._allowed_headers())
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in {"/", "/index.html"}:
            self._send_html(HTML_PAGE)
            return
        if parsed.path == "/status":
            self._send_json(STATE.snapshot())
            return
        if parsed.path == "/facebook-post-bootstrap":
            if not self._require_control_password():
                return
            query = parse_qs(parsed.query)
            chrome_name = (query.get("chrome_name") or [""])[0]
            page_name = (query.get("page_name") or [""])[0]
            self._send_json(build_facebook_post_bootstrap_response(chrome_name, page_name))
            return
        if parsed.path == "/facebook-packages":
            if not self._require_control_password():
                return
            self._send_json({"ok": True, "packages": load_package_cards()}, HTTPStatus.OK)
            return
        if parsed.path == "/facebook-package-thumbnail":
            package_name = (parse_qs(parsed.query).get("package_name") or [""])[0]
            try:
                thumbnail_path = thumbnail_path_for_package(package_name)
            except ValueError:
                self._send_json({"ok": False, "message": "Invalid package name."}, HTTPStatus.BAD_REQUEST)
                return
            if thumbnail_path is None:
                self._send_json({"ok": False, "message": "Thumbnail not found."}, HTTPStatus.NOT_FOUND)
                return
            self._send_file(thumbnail_path)
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        request_path = parsed.path

        if request_path == "/source-video-upload":
            if not self._require_control_password():
                return
            body = self._read_raw_body()
            if not body:
                self._send_json({"ok": False, "message": "Upload body is empty."}, HTTPStatus.BAD_REQUEST)
                return

            query = parse_qs(parsed.query)
            requested_name = (query.get("file_name") or [""])[0]
            if not requested_name:
                requested_name = str(self.headers.get("X-Soranin-File-Name") or "").strip()
            content_type = str(self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
            target_name = sanitize_source_video_filename(requested_name, content_type)
            target_path = unique_source_video_target(target_name)
            try:
                ROOT_DIR.mkdir(parents=True, exist_ok=True)
                target_path.write_bytes(body)
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return

            STATE.emit_alert(
                "New video on Mac",
                f"{target_path.name} was added to Drop Videos.",
            )

            self._send_json(
                {
                    "ok": True,
                    "message": f"Saved {target_path.name} to Drop Videos on Mac.",
                    "file_name": target_path.name,
                    "saved_path": str(target_path),
                    "source_count": len(source_videos(ROOT_DIR)),
                },
                HTTPStatus.OK,
            )
            return

        if request_path == "/start":
            ok, message = STATE.start()
            code = HTTPStatus.OK if ok else HTTPStatus.CONFLICT
            self._send_json({"ok": ok, "message": message}, code)
            return
        if request_path == "/remote-run":
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            values: list[str] = []
            raw_ids = payload.get("video_ids")
            if isinstance(raw_ids, list):
                values.extend(str(item) for item in raw_ids)
            raw_input = str(payload.get("raw_input") or "").strip()
            if raw_input:
                values.extend(extract_video_ids_from_text(raw_input))

            normalized_ids = normalize_video_ids(values)
            ok, message = STATE.start_remote(normalized_ids)
            if ok:
                self._send_json(
                    {
                        "ok": True,
                        "message": message,
                        "count": len(normalized_ids),
                    },
                    HTTPStatus.OK,
                )
            else:
                status = HTTPStatus.CONFLICT if "running" in message.lower() else HTTPStatus.BAD_REQUEST
                self._send_json(
                    {
                        "ok": False,
                        "message": message,
                        "count": len(normalized_ids),
                    },
                    status,
                )
            return
        if request_path == "/facebook-post-preflight":
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            try:
                result = run_facebook_preflight(payload)
            except Exception as exc:
                self._send_json(
                    {
                        "ok": False,
                        "message": str(exc),
                    },
                    HTTPStatus.BAD_REQUEST,
                )
                return
            self._send_json(result, HTTPStatus.OK)
            return
        if request_path == "/facebook-post-run":
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            ok, message = STATE.start_facebook_post(payload)
            status = HTTPStatus.OK if ok else HTTPStatus.BAD_REQUEST
            self._send_json(
                {
                    "ok": ok,
                    "message": message,
                },
                status,
            )
            return
        if request_path == "/quit-chrome":
            if not self._require_control_password():
                return
            quit_google_chrome()
            self._send_json({"ok": True, "message": "Google Chrome quit."}, HTTPStatus.OK)
            return
        if request_path == "/facebook-package-delete":
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            package_name = str(payload.get("package_name") or "").strip()
            try:
                package_path = package_path_for_name(package_name)
            except ValueError as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            if not package_path.exists() or not package_path.is_dir():
                self._send_json({"ok": False, "message": "Package not found."}, HTTPStatus.NOT_FOUND)
                return
            try:
                shutil.rmtree(package_path)
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return
            self._send_json(
                {
                    "ok": True,
                    "message": f"Deleted {package_name}.",
                    "package_name": package_name,
                    "packages": load_package_cards(),
                },
                HTTPStatus.OK,
            )
            return
        if request_path == "/save-keys":
            payload = self._read_json_body()
            openai_key = str(payload.get("openai_key", "")).strip()
            gemini_key = str(payload.get("gemini_key", "")).strip()
            ai_provider = normalize_provider(str(payload.get("ai_provider", "")).strip())
            kwargs: dict[str, str] = {"ai_provider": ai_provider}
            if openai_key:
                kwargs["openai_key"] = openai_key
            if gemini_key:
                kwargs["gemini_key"] = gemini_key
            save_api_keys(**kwargs)
            self._send_json(
                {
                    "ok": True,
                    "message": f"{provider_label(ai_provider)} settings saved.",
                }
            )
            return
        if request_path == "/facebook-resolve":
            payload = self._read_json_body()
            raw_value = str(payload.get("url") or payload.get("raw_input") or "").strip()
            if not raw_value:
                self._send_json(
                    {
                        "ok": False,
                        "message": "Provide a Facebook reel/video URL first.",
                    },
                    HTTPStatus.BAD_REQUEST,
                )
                return

            preferred_quality = str(payload.get("quality") or FACEBOOK_QUALITY_AUTO).strip().lower()
            if preferred_quality not in FACEBOOK_VALID_QUALITIES:
                preferred_quality = FACEBOOK_QUALITY_AUTO

            try:
                result = resolve_facebook_download_payload(raw_value, preferred_quality)
            except FacebookDownloadError as exc:
                self._send_json(
                    {
                        "ok": False,
                        "message": str(exc),
                    },
                    HTTPStatus.BAD_REQUEST,
                )
                return
            except Exception as exc:
                self._send_json(
                    {
                        "ok": False,
                        "message": f"Facebook resolve failed: {exc}",
                    },
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
                return

            self._send_json(
                {
                    "ok": True,
                    **result,
                },
                HTTPStatus.OK,
            )
            return
        if request_path == "/open-root":
            subprocess.Popen(["open", str(ROOT_DIR)])
            self._send_json({"ok": True})
            return
        if request_path == "/open-latest":
            packages = package_dirs(ROOT_DIR)
            if packages:
                subprocess.Popen(["open", str(packages[-1])])
                self._send_json({"ok": True})
            else:
                self._send_json({"ok": False, "message": "No package found."}, HTTPStatus.NOT_FOUND)
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> int:
    ROOT_DIR.mkdir(parents=True, exist_ok=True)
    relay_base_url = control_relay_base_url()
    relay_client_url = control_relay_client_base_url()
    if relay_base_url and relay_client_url:
        threading.Thread(
            target=relay_worker_loop,
            args=(relay_base_url, control_relay_poll_seconds()),
            daemon=True,
        ).start()
        print(f"Control relay worker enabled: {relay_client_url}", flush=True)
    server = ThreadingHTTPServer((HOST, PORT), ReelsDashboardHandler)
    print(f"Reels dashboard running at http://{HOST}:{PORT}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
