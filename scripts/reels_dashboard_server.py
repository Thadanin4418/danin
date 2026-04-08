#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import json
import html
import hmac
import importlib.util
import mimetypes
import os
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import getpass
import socket
import sys
import traceback
import zipfile
from collections import deque
from datetime import datetime, timedelta, timezone
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
    stable_download_key_for_url,
)
from post_links_downloader import DownloadEntry, build_entries
from soranin_paths import (
    API_KEYS_FILE,
    CONTROL_RELAY_CONFIG_FILE,
    FACEBOOK_STATE_PATH,
    FACEBOOK_SAVED_PAGES_FILE,
    FACEBOOK_UPLOAD_PAGES_FILE,
    ROOT_DIR,
    mirrored_package_paths,
    script_path,
)
import fb_reels_publish_timing as facebook_timing
import facebook_shared_queue
import facebook_reels_api


HOST = "0.0.0.0"
PORT = 8765
BATCH_SCRIPT = script_path("fast_reels_batch.py")
DOWNLOADER_SCRIPT = script_path("post_links_downloader.py")
FACEBOOK_BATCH_SCRIPT = script_path("fb_reels_batch_upload.py")
FACEBOOK_API_UPLOAD_SCRIPT = script_path("fb_reels_api_upload.py")
FACEBOOK_PREFLIGHT_SCRIPT = script_path("fb_reels_preflight_check.py")
FACEBOOK_STEP3_SCRIPT = script_path("fb_reels_step3_upload_video_and_next.py")
FACEBOOK_TIMING_STATE_PATH = FACEBOOK_STATE_PATH
CHROME_LOCAL_STATE = Path.home() / "Library/Application Support/Google/Chrome/Local State"
CHROME_APP = "Google Chrome"
FACEBOOK_CONTENT_LIBRARY_URL = "https://www.facebook.com/"
AI_PROVIDER_DEFAULT = "openai"
AI_PROVIDER_OPENAI = "openai"
AI_PROVIDER_GEMINI = "gemini"
VIDEO_ID_PATTERN = re.compile(r"\b(?:s_|gen_)[A-Za-z0-9_-]{8,}\b", re.IGNORECASE)
DEFAULT_CONTROL_RELAY_POLL_SECONDS = 3.0
CONTROL_RELAY_CLIENT_SCRIPT = script_path("control_relay_client.py")
REMOTE_USED_IDS_FILE = API_KEYS_FILE.parent / "remote_used_ids.json"
REMOTE_FACEBOOK_KEY_CACHE_FILE = API_KEYS_FILE.parent / "remote_facebook_download_keys.json"
FACEBOOK_PAGE_ASSIGNMENTS_FILE = API_KEYS_FILE.parent / ".soranin_facebook_page_links.json"
FACEBOOK_PAGE_QUEUE_ORDER_FILE = API_KEYS_FILE.parent / ".soranin_facebook_page_queue_order.json"
REMOTE_FACEBOOK_KEY_CACHE_LOCK = threading.Lock()
TAILSCALE_CACHE_TTL_SECONDS = 60.0
BOOTSTRAP_CACHE_TTL_SECONDS = 4.0
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
FACEBOOK_UPLOAD_PATTERN = re.compile(r"^\[facebook-upload\]\s*(\d{1,3})\|(.*)$")
REMOTE_DOWNLOAD_PROGRESS_PATTERN = re.compile(
    r"^(?:\[remote\]\s+)?\[(download|facebook)\]\s+Progress(?:\s+([^\s]+))?\s+(\d{1,3})%$",
    re.IGNORECASE,
)
OPENAI_RESPONSES_API_URL = "https://api.openai.com/v1/responses"
REMOTE_USED_IDS_LOCK = threading.Lock()
TAILSCALE_CACHE_LOCK = threading.Lock()
BOOTSTRAP_CACHE_LOCK = threading.Lock()
FACEBOOK_PAGE_METRICS_CACHE_LOCK = threading.Lock()
FACEBOOK_PAGE_METRICS_CACHE_TTL_SECONDS = 1200.0
FACEBOOK_PAGE_METRICS_REFRESH_TIMEOUT_SECONDS = 8
FACEBOOK_PAGE_METRICS_BACKGROUND_POLL_SECONDS = 60.0
PYTHON_EXECUTABLE = sys.executable or "python3"
_TAILSCALE_URL_CACHE: list[str] = []
_TAILSCALE_URL_CACHE_AT = 0.0
_FACEBOOK_BOOTSTRAP_CACHE: dict[tuple[str, str], tuple[float, dict[str, object]]] = {}
_FACEBOOK_PAGE_METRICS_CACHE: dict[str, tuple[float, dict[str, object]]] = {}
_FACEBOOK_PAGE_METRICS_REFRESHING: set[str] = set()
CONTROL_WEB_HTML_PATH = Path(__file__).resolve().with_name("soranin_web_control.html")
CONTROL_AUTH_WINDOW_SECONDS = 600.0
CONTROL_AUTH_LOCKOUT_SECONDS = 900.0
CONTROL_AUTH_MAX_FAILURES = 8
CONTROL_SESSION_TTL_SECONDS = 12 * 60 * 60.0
CONTROL_SESSION_REMEMBER_TTL_SECONDS = 30 * 24 * 60 * 60.0


def load_control_web_html() -> str:
    try:
        return CONTROL_WEB_HTML_PATH.read_text(encoding="utf-8")
    except Exception:
        return """<!doctype html><html><body><h1>Soranin Control</h1><p>Web control page is missing.</p></body></html>"""


class AuthAttemptTracker:
    def __init__(self, *, window_seconds: float, lockout_seconds: float, max_failures: int) -> None:
        self.window_seconds = max(60.0, float(window_seconds))
        self.lockout_seconds = max(60.0, float(lockout_seconds))
        self.max_failures = max(3, int(max_failures))
        self.lock = threading.Lock()
        self.state: dict[str, dict[str, object]] = {}

    def _prune(self, record: dict[str, object], now: float) -> list[float]:
        raw_failures = record.get("failures")
        failures = raw_failures if isinstance(raw_failures, list) else []
        kept = [float(value) for value in failures if now - float(value) <= self.window_seconds]
        record["failures"] = kept
        return kept

    def remaining_lockout(self, key: str) -> int:
        now = time.time()
        with self.lock:
            record = self.state.get(key)
            if not isinstance(record, dict):
                return 0
            locked_until = float(record.get("locked_until") or 0.0)
            if locked_until <= now:
                self._prune(record, now)
                if not record.get("failures"):
                    self.state.pop(key, None)
                else:
                    record["locked_until"] = 0.0
                return 0
            return max(1, int(locked_until - now + 0.999))

    def record_failure(self, key: str) -> int:
        now = time.time()
        with self.lock:
            record = self.state.setdefault(key, {"failures": [], "locked_until": 0.0})
            locked_until = float(record.get("locked_until") or 0.0)
            if locked_until > now:
                return max(1, int(locked_until - now + 0.999))
            failures = self._prune(record, now)
            failures.append(now)
            record["failures"] = failures
            if len(failures) >= self.max_failures:
                record["failures"] = []
                record["locked_until"] = now + self.lockout_seconds
                return max(1, int(self.lockout_seconds + 0.999))
            return 0

    def record_success(self, key: str) -> None:
        with self.lock:
            self.state.pop(key, None)


class WebSessionStore:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.sessions: dict[str, dict[str, object]] = {}

    def create(self, *, client_ip: str, user_agent: str, ttl_seconds: float, data: dict[str, object] | None = None) -> tuple[str, float]:
        token = secrets.token_urlsafe(32)
        expires_at = time.time() + max(300.0, float(ttl_seconds))
        session = {
            "token": token,
            "client_ip": str(client_ip or "").strip(),
            "user_agent": str(user_agent or "").strip(),
            "expires_at": expires_at,
            "data": dict(data or {}),
        }
        with self.lock:
            self.sessions[token] = session
        return token, expires_at

    def get(self, token: str, *, client_ip: str, user_agent: str) -> dict[str, object] | None:
        now = time.time()
        trimmed_token = str(token or "").strip()
        if not trimmed_token:
            return None
        with self.lock:
            session = self.sessions.get(trimmed_token)
            if not isinstance(session, dict):
                return None
            if float(session.get("expires_at") or 0.0) <= now:
                self.sessions.pop(trimmed_token, None)
                return None
            expected_ip = str(session.get("client_ip") or "").strip()
            expected_ua = str(session.get("user_agent") or "").strip()
            if expected_ip and expected_ip != str(client_ip or "").strip():
                return None
            if expected_ua and expected_ua != str(user_agent or "").strip():
                return None
            return dict(session.get("data") or {})

    def delete(self, token: str) -> None:
        trimmed_token = str(token or "").strip()
        if not trimmed_token:
            return
        with self.lock:
            self.sessions.pop(trimmed_token, None)


CONTROL_AUTH_ATTEMPTS = AuthAttemptTracker(
    window_seconds=CONTROL_AUTH_WINDOW_SECONDS,
    lockout_seconds=CONTROL_AUTH_LOCKOUT_SECONDS,
    max_failures=CONTROL_AUTH_MAX_FAILURES,
)
CONTROL_WEB_SESSIONS = WebSessionStore()


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def unique_ordered_strings(values: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for value in values:
        text = str(value or "").strip()
        if not text:
            continue
        key = text.casefold()
        if key in seen:
            continue
        seen.add(key)
        ordered.append(text)
    return ordered


def load_remote_used_ids() -> set[str]:
    if not REMOTE_USED_IDS_FILE.exists():
        return set()
    try:
        payload = json.loads(REMOTE_USED_IDS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return set()
    if not isinstance(payload, list):
        return set()
    return {
        str(item).strip().lower()
        for item in payload
        if str(item).strip()
    }


def save_remote_used_ids(values: set[str]) -> None:
    REMOTE_USED_IDS_FILE.parent.mkdir(parents=True, exist_ok=True)
    REMOTE_USED_IDS_FILE.write_text(
        json.dumps(sorted(values), indent=2),
        encoding="utf-8",
    )
    try:
        REMOTE_USED_IDS_FILE.chmod(0o600)
    except Exception:
        pass


def load_remote_facebook_key_cache() -> dict[str, str]:
    if not REMOTE_FACEBOOK_KEY_CACHE_FILE.exists():
        return {}
    try:
        payload = json.loads(REMOTE_FACEBOOK_KEY_CACHE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}
    if not isinstance(payload, dict):
        return {}
    normalized: dict[str, str] = {}
    for key, value in payload.items():
        normalized_key = str(key).strip().lower()
        normalized_value = str(value).strip().lower()
        if normalized_key and normalized_value:
            normalized[normalized_key] = normalized_value
    return normalized


def save_remote_facebook_key_cache(values: dict[str, str]) -> None:
    REMOTE_FACEBOOK_KEY_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    REMOTE_FACEBOOK_KEY_CACHE_FILE.write_text(
        json.dumps(values, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    try:
        REMOTE_FACEBOOK_KEY_CACHE_FILE.chmod(0o600)
    except Exception:
        pass


def cached_facebook_remote_key(value: str) -> str | None:
    normalized = str(value).strip().lower()
    if not normalized:
        return None
    with REMOTE_FACEBOOK_KEY_CACHE_LOCK:
        cache = load_remote_facebook_key_cache()
        cached = cache.get(normalized)
        if cached:
            return cached
    resolved = stable_download_key_for_url(value)
    if not resolved:
        return None
    normalized_resolved = resolved.strip().lower()
    if not normalized_resolved:
        return None
    with REMOTE_FACEBOOK_KEY_CACHE_LOCK:
        cache = load_remote_facebook_key_cache()
        cache[normalized] = normalized_resolved
        save_remote_facebook_key_cache(cache)
    return normalized_resolved


def remote_entry_key(entry: DownloadEntry) -> str:
    if entry.kind == "facebook":
        resolved = cached_facebook_remote_key(entry.value)
        if resolved:
            return f"{entry.kind}:{resolved}"
    return f"{entry.kind}:{entry.value.strip().lower()}"


def filter_unused_remote_entries(entries: list[DownloadEntry]) -> tuple[list[DownloadEntry], list[DownloadEntry]]:
    with REMOTE_USED_IDS_LOCK:
        used = load_remote_used_ids()
    fresh_entries: list[DownloadEntry] = []
    duplicate_entries: list[DownloadEntry] = []
    for entry in entries:
        key = remote_entry_key(entry)
        if not key:
            continue
        if key in used:
            duplicate_entries.append(entry)
        else:
            fresh_entries.append(entry)
    return fresh_entries, duplicate_entries


def mark_remote_entries_used(entries: list[DownloadEntry]) -> None:
    keys = {
        remote_entry_key(entry)
        for entry in entries
        if remote_entry_key(entry)
    }
    if not keys:
        return
    with REMOTE_USED_IDS_LOCK:
        used = load_remote_used_ids()
        used.update(keys)
        save_remote_used_ids(used)


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


def control_display_user_name() -> str:
    config = load_control_relay_config()
    value = str(config.get("relay_user_name") or "").strip()
    if value:
        return value
    return current_mac_user_name()


def control_display_device_name() -> str:
    config = load_control_relay_config()
    value = str(config.get("relay_mac_name") or "").strip()
    if value:
        return value
    return current_mac_device_name()


def control_display_name() -> str:
    device_name = control_display_device_name().strip()
    user_name = control_display_user_name().strip()
    if not device_name:
        device_name = current_mac_device_name()
    if not user_name:
        user_name = current_mac_user_name()
    if not user_name or device_name.casefold() == user_name.casefold():
        return device_name
    return f"{device_name} • user {user_name}"


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


def tailscale_cli_output(arguments: list[str]) -> str | None:
    explicit_executables = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    def run_process(executable: str, args: list[str]) -> str | None:
        try:
            completed = subprocess.run(
                [executable, *args],
                capture_output=True,
                text=True,
                timeout=1.5,
                check=False,
            )
        except Exception:
            return None
        if completed.returncode != 0:
            return None
        text = (completed.stdout or "").strip()
        return text or None

    for path in explicit_executables:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            output = run_process(path, arguments)
            if output:
                return output

    return run_process("/usr/bin/env", ["tailscale", *arguments])


def tailscale_ipv4_addresses() -> list[str]:
    output = tailscale_cli_output(["ip", "-4"])
    if not output:
        return []
    results: list[str] = []
    seen: set[str] = set()
    for raw_line in output.splitlines():
        ip = raw_line.strip()
        if not ip:
            continue
        key = ip.lower()
        if key in seen:
            continue
        seen.add(key)
        results.append(ip)
    return results


def compute_tailscale_control_server_urls() -> list[str]:
    results: list[str] = []
    seen: set[str] = set()
    for ip in tailscale_ipv4_addresses():
        url = f"http://{ip}:8765"
        key = url.lower()
        if key in seen:
            continue
        seen.add(key)
        results.append(url)
    return results


def refresh_tailscale_control_server_urls() -> list[str]:
    global _TAILSCALE_URL_CACHE_AT, _TAILSCALE_URL_CACHE
    urls = compute_tailscale_control_server_urls()
    with TAILSCALE_CACHE_LOCK:
        _TAILSCALE_URL_CACHE = list(urls)
        _TAILSCALE_URL_CACHE_AT = time.time()
        return list(_TAILSCALE_URL_CACHE)


def tailscale_control_server_urls(force_refresh: bool = False) -> list[str]:
    global _TAILSCALE_URL_CACHE_AT
    now = time.time()
    with TAILSCALE_CACHE_LOCK:
        cache = list(_TAILSCALE_URL_CACHE)
        age = now - _TAILSCALE_URL_CACHE_AT if _TAILSCALE_URL_CACHE_AT else float("inf")
    if cache and not force_refresh and age < TAILSCALE_CACHE_TTL_SECONDS:
        return cache
    return refresh_tailscale_control_server_urls()


def preferred_tailscale_control_server_url() -> str:
    urls = tailscale_control_server_urls()
    return urls[0] if urls else ""


def control_password() -> str:
    config = load_control_relay_config()
    return str(
        os.environ.get("SORANIN_CONTROL_PASSWORD")
        or config.get("control_password")
        or config.get("password")
        or ""
    ).strip()


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


def public_control_status_payload(snapshot: dict[str, object] | None = None) -> dict[str, object]:
    payload = snapshot if isinstance(snapshot, dict) else STATE.snapshot()
    return {
        "ok": True,
        "status": str(payload.get("status") or "").strip(),
        "detail": str(payload.get("detail") or "").strip(),
        "running": bool(payload.get("running")),
        "remote_running": bool(payload.get("remote_running")),
        "task_kind": str(payload.get("task_kind") or "").strip(),
        "mac_user_name": str(payload.get("mac_user_name") or "").strip(),
        "mac_device_name": str(payload.get("mac_device_name") or "").strip(),
        "mac_display_name": str(payload.get("mac_display_name") or "").strip(),
        "relay_enabled": bool(payload.get("relay_enabled")),
        "relay_client_url": str(payload.get("relay_client_url") or "").strip(),
        "tailscale_url": str(payload.get("tailscale_url") or "").strip(),
        "password_required": bool(payload.get("password_required")),
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
    for path in list(root.iterdir()):
        if (
            path.is_file()
            and path.suffix.lower() in ALLOWED_SOURCE_VIDEO_EXTENSIONS
            and path.name.lower().startswith("codex-alert-")
        ):
            try:
                path.unlink()
            except Exception:
                pass
    return sorted(
        path
        for path in root.iterdir()
        if path.is_file()
        and path.suffix.lower() in ALLOWED_SOURCE_VIDEO_EXTENSIONS
        and not path.name.startswith(".")
        and not path.name.lower().startswith("codex-alert-")
    )


def sha256_digest_for_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def duplicate_source_video_path_for_bytes(body: bytes) -> Path | None:
    if not body:
        return None
    if not ROOT_DIR.exists():
        return None

    body_size = len(body)
    body_digest = hashlib.sha256(body).hexdigest()
    for candidate in source_videos(ROOT_DIR):
        try:
            if candidate.stat().st_size != body_size:
                continue
        except OSError:
            continue
        try:
            if sha256_digest_for_file(candidate) == body_digest:
                return candidate
        except Exception:
            continue
    return None


def handle_source_video_saved(target_path: Path) -> dict[str, object]:
    STATE.emit_alert(
        "New video on Mac",
        f"{target_path.name} was added to Drop Videos.",
    )

    auto_started = False
    auto_message = ""
    started, message = STATE.start()
    if started:
        auto_started = True
        STATE.append_log("[upload] Auto starting AI edit for uploaded video.")
    else:
        auto_message = str(message or "").strip()
        lowered = auto_message.lower()
        if "batch is already running" in lowered:
            with STATE.lock:
                STATE.remote_batch_autostart_pending = True
            STATE.append_log(f"[upload] Saved {target_path.name}. Auto start deferred: {auto_message}")
        elif "remote flow is already running" in lowered:
            STATE.append_log(f"[upload] Saved {target_path.name}. Auto start waiting for current remote flow: {auto_message}")
        else:
            STATE.append_log(f"[upload] Saved {target_path.name}. Auto start skipped: {auto_message}")

    return {
        "ok": True,
        "message": f"Saved {target_path.name} to Drop Videos on Mac.",
        "file_name": target_path.name,
        "saved_path": str(target_path),
        "source_count": len(source_videos(ROOT_DIR)),
        "auto_edit_started": auto_started,
        "auto_edit_message": auto_message,
    }


def handle_duplicate_source_video(existing_path: Path) -> dict[str, object]:
    STATE.append_log(f"[upload] Skipped duplicate source video: {existing_path.name}")
    return {
        "ok": True,
        "duplicate": True,
        "message": f"Video already exists in Drop Videos on Mac as {existing_path.name}.",
        "file_name": existing_path.name,
        "saved_path": str(existing_path),
        "source_count": len(source_videos(ROOT_DIR)),
        "auto_edit_started": False,
        "auto_edit_message": "Skipped duplicate source video.",
    }


def next_imported_package_target(preferred_package_name: str = "") -> Path:
    raw = str(preferred_package_name or "").strip()
    if raw and re.match(r"^\d+_Reels_Package$", raw):
        preferred = ROOT_DIR / raw
        if not preferred.exists():
            return preferred

    highest = 0
    for package_dir in package_dirs(ROOT_DIR):
        try:
            highest = max(highest, int(package_dir.name.split("_", 1)[0]))
        except Exception:
            continue
    return ROOT_DIR / f"{highest + 1}_Reels_Package"


def imported_package_source_dir(extract_root: Path) -> Path | None:
    direct = [
        candidate
        for candidate in extract_root.iterdir()
        if candidate.is_dir() and re.match(r"^\d+_Reels_Package$", candidate.name)
    ]
    if len(direct) == 1:
        return direct[0]

    nested = [
        candidate
        for candidate in extract_root.rglob("*")
        if candidate.is_dir() and re.match(r"^\d+_Reels_Package$", candidate.name)
    ]
    if len(nested) == 1:
        return nested[0]
    return None


def package_transfer_staging_root() -> Path:
    return ROOT_DIR / ".incoming_package_transfers"


def sanitize_package_relative_path(raw_relative_path: str) -> Path:
    candidate = Path(str(raw_relative_path or "").strip())
    if not candidate.parts:
        raise ValueError("Package file path is missing.")
    if candidate.is_absolute():
        raise ValueError("Package file path must be relative.")
    cleaned_parts: list[str] = []
    for part in candidate.parts:
        piece = str(part).strip()
        if not piece or piece in {".", ".."}:
            raise ValueError("Package file path is invalid.")
        cleaned_parts.append(piece)
    return Path(*cleaned_parts)


def package_transfer_stage_dir(session_id: str, target_package_name: str) -> Path:
    safe_session_id = re.sub(r"[^A-Za-z0-9._-]+", "_", str(session_id or "").strip()).strip("._-")
    safe_target = re.sub(r"[^A-Za-z0-9._-]+", "_", str(target_package_name or "").strip()).strip("._-")
    if not safe_session_id:
        raise ValueError("Transfer session ID is missing.")
    if not safe_target:
        raise ValueError("Target package name is missing.")
    return package_transfer_staging_root() / safe_session_id / safe_target


def stage_imported_package_file(
    body: bytes,
    *,
    session_id: str,
    source_package_name: str = "",
    relative_path: str = "",
    target_package_name: str = "",
    assigned_page_id: str = "",
) -> dict[str, object]:
    if not body:
        raise ValueError("Package file is empty.")
    safe_relative_path = sanitize_package_relative_path(relative_path)
    preferred_name = str(target_package_name or source_package_name).strip()
    if target_package_name:
        final_package_name = str(target_package_name).strip()
    else:
        final_package_name = next_imported_package_target(preferred_name).name
    stage_dir = package_transfer_stage_dir(session_id, final_package_name)
    stage_dir.mkdir(parents=True, exist_ok=True)
    target_path = (stage_dir / safe_relative_path).resolve()
    try:
        target_path.relative_to(stage_dir.resolve())
    except Exception as exc:
        raise ValueError("Package file path is outside the staging folder.") from exc
    target_path.parent.mkdir(parents=True, exist_ok=True)
    target_path.write_bytes(body)

    metadata = {
        "source_package_name": str(source_package_name or "").strip(),
        "assigned_page_id": str(assigned_page_id or "").strip(),
        "target_package_name": final_package_name,
        "session_id": str(session_id or "").strip(),
    }
    (stage_dir / ".transfer_meta.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")

    return {
        "ok": True,
        "target_package_name": final_package_name,
        "relative_path": safe_relative_path.as_posix(),
        "saved_path": str(target_path),
    }


def finalize_staged_package_transfer(
    *,
    session_id: str,
    target_package_name: str,
    source_package_name: str = "",
    assigned_page_id: str = "",
) -> dict[str, object]:
    stage_dir = package_transfer_stage_dir(session_id, target_package_name)
    if not stage_dir.exists() or not stage_dir.is_dir():
        raise ValueError("Package transfer staging folder was not found.")

    final_target = ROOT_DIR / str(target_package_name).strip()
    if final_target.exists():
        final_target = next_imported_package_target(str(target_package_name).strip())
    final_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(stage_dir), str(final_target))

    try:
        session_root = stage_dir.parent
        if session_root.exists():
            shutil.rmtree(session_root, ignore_errors=True)
    except Exception:
        pass

    return handle_imported_package_saved(
        final_target,
        source_package_name=str(source_package_name or target_package_name).strip(),
        assigned_page_id=assigned_page_id,
    )


def maybe_preserve_imported_page_assignment(package_name: str, assigned_page_id: str) -> bool:
    page_id = str(assigned_page_id or "").strip()
    if not page_id:
        return False
    saved_pages_by_id = {
        str(item.get("page_id") or "").strip(): item
        for item in load_saved_facebook_upload_pages()
        if str(item.get("page_id") or "").strip()
    }
    if page_id not in saved_pages_by_id:
        return False
    assignments = load_facebook_page_assignments()
    assignments[str(package_name).strip()] = page_id
    persist_facebook_page_assignments(assignments)
    return True


def handle_imported_package_saved(
    target_path: Path,
    *,
    source_package_name: str,
    assigned_page_id: str = "",
) -> dict[str, object]:
    assignment_preserved = maybe_preserve_imported_page_assignment(target_path.name, assigned_page_id)
    STATE.emit_alert(
        "Package transferred to Mac",
        f"{source_package_name or target_path.name} was imported as {target_path.name}.",
    )
    STATE.append_log(
        f"[package-transfer] Imported {source_package_name or target_path.name} into {target_path.name}."
    )
    return {
        "ok": True,
        "message": f"Imported package {target_path.name} on Mac.",
        "package_name": target_path.name,
        "source_package_name": source_package_name or target_path.name,
        "saved_path": str(target_path),
        "package_count": len(package_dirs(ROOT_DIR)),
        "assigned_page_preserved": assignment_preserved,
    }


def import_package_archive_bytes(
    body: bytes,
    *,
    source_package_name: str = "",
    assigned_page_id: str = "",
) -> dict[str, object]:
    ROOT_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="soranin_package_import_") as temp_dir:
        temp_root = Path(temp_dir)
        archive_path = temp_root / "package.zip"
        extract_root = temp_root / "extract"
        archive_path.write_bytes(body)
        extract_root.mkdir(parents=True, exist_ok=True)

        with zipfile.ZipFile(archive_path) as zip_file:
            zip_file.extractall(extract_root)

        source_dir = imported_package_source_dir(extract_root)
        if source_dir is None:
            raise ValueError("Imported archive does not contain a valid package folder.")

        preferred_name = str(source_package_name or source_dir.name).strip()
        target_path = next_imported_package_target(preferred_name)
        shutil.copytree(source_dir, target_path)

    return handle_imported_package_saved(
        target_path,
        source_package_name=str(source_package_name or source_dir.name).strip(),
        assigned_page_id=assigned_page_id,
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


def facebook_video_roots() -> list[Path]:
    candidates = [
        ROOT_DIR.parent / "facebook",
        Path.home() / "Downloads" / "facebook",
        Path.home() / ".soranin" / "facebook",
    ]
    ordered: list[Path] = []
    seen: set[Path] = set()
    for candidate in candidates:
        try:
            resolved = candidate.expanduser().resolve()
        except Exception:
            resolved = candidate.expanduser()
        if resolved in seen or not resolved.exists() or not resolved.is_dir():
            continue
        seen.add(resolved)
        ordered.append(resolved)
    return ordered


def source_video_path_for_name(file_name: str) -> Path:
    raw = unquote(str(file_name or "").strip())
    candidate = Path(raw).name
    if not candidate or candidate != raw:
        raise ValueError("Invalid file name.")
    suffix = Path(candidate).suffix.lower()
    if suffix not in ALLOWED_SOURCE_VIDEO_EXTENSIONS:
        raise ValueError("Invalid file name.")

    for root in facebook_video_roots():
        path = (root / candidate).resolve()
        try:
            path.relative_to(root.resolve())
        except Exception as exc:
            raise ValueError("File path is outside the Facebook folder.") from exc
        if path.exists() and path.is_file():
            return path

    raise ValueError("Video not found.")


def load_facebook_feed_videos() -> list[dict[str, object]]:
    ordered_roots = facebook_video_roots()
    if not ordered_roots:
        return []

    def sort_key(path: Path) -> tuple[float, str]:
        try:
            modified_at = float(path.stat().st_mtime)
        except Exception:
            modified_at = 0.0
        return (modified_at, path.name.lower())

    unique_paths: list[Path] = []
    seen_names: set[str] = set()
    for root in ordered_roots:
        for path in source_videos(root):
            key = path.name.casefold()
            if key in seen_names:
                continue
            seen_names.add(key)
            unique_paths.append(path)

    ordered_paths = sorted(unique_paths, key=sort_key, reverse=True)
    rows: list[dict[str, object]] = []
    for path in ordered_paths:
        mime_type, _encoding = mimetypes.guess_type(path.name)
        title = re.sub(r"[_-]+", " ", path.stem).strip() or path.name
        rows.append(
            {
                "file_name": path.name,
                "title": title,
                "source_name": path.name,
                "mime_type": mime_type or "application/octet-stream",
            }
        )
    return rows


def delete_facebook_feed_video_mirrors(file_name: str) -> tuple[bool, str | None]:
    raw = unquote(str(file_name or "").strip())
    candidate = Path(raw).name
    if not candidate or candidate != raw:
        raise ValueError("Invalid file name.")
    suffix = Path(candidate).suffix.lower()
    if suffix not in ALLOWED_SOURCE_VIDEO_EXTENSIONS:
        raise ValueError("Invalid file name.")

    deleted_any = False
    last_error: str | None = None
    for root in facebook_video_roots():
        try:
            path = (root / candidate).resolve()
            path.relative_to(root.resolve())
        except Exception as exc:
            last_error = str(exc)
            continue
        if not path.exists() or not path.is_file():
            continue
        try:
            path.unlink()
            deleted_any = True
        except Exception as exc:
            last_error = str(exc)
    return deleted_any, last_error


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


def delete_package_mirrors(package_name: str, *, primary_path: Path | None = None) -> tuple[bool, str | None]:
    deleted_any = False
    last_error: str | None = None
    for candidate in mirrored_package_paths(package_name, primary_path=primary_path):
        if not candidate.exists() or not candidate.is_dir():
            continue
        try:
            shutil.rmtree(candidate)
            deleted_any = True
        except Exception as exc:
            last_error = str(exc)
    return deleted_any, last_error


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


def load_package_schedule_text(html_text: str) -> str:
    if not html_text.strip():
        return ""
    field_match = re.search(
        r'<input[^>]+id=["\']scheduleField["\'][^>]*value=["\'](.*?)["\']',
        html_text,
        re.IGNORECASE | re.DOTALL,
    )
    if field_match:
        return html.unescape(field_match.group(1)).strip()
    script_match = re.search(
        r"""(?:const|let|var)\s+SCHEDULE_TEXT\s*=\s*["'](.*?)["'];""",
        html_text,
        re.IGNORECASE | re.DOTALL,
    )
    if script_match:
        return html.unescape(script_match.group(1)).strip()
    return ""


def load_facebook_page_assignments() -> dict[str, str]:
    return _load_string_mapping_from_candidates(FACEBOOK_PAGE_ASSIGNMENTS_FILE)


def persist_facebook_page_assignments(mapping: dict[str, str]) -> None:
    FACEBOOK_PAGE_ASSIGNMENTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    FACEBOOK_PAGE_ASSIGNMENTS_FILE.write_text(
        json.dumps(mapping, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    try:
        FACEBOOK_PAGE_ASSIGNMENTS_FILE.chmod(0o600)
    except Exception:
        pass


def load_facebook_page_queue_orders() -> dict[str, list[str]]:
    for candidate in _runtime_fallback_paths(FACEBOOK_PAGE_QUEUE_ORDER_FILE):
        if not candidate.exists():
            continue
        try:
            payload = json.loads(candidate.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        sanitized: dict[str, list[str]] = {}
        for key, value in payload.items():
            page_id = str(key).strip()
            if not page_id or not isinstance(value, list):
                continue
            sanitized[page_id] = [
                str(item).strip()
                for item in value
                if str(item).strip()
            ]
        if candidate != FACEBOOK_PAGE_QUEUE_ORDER_FILE:
            try:
                persist_facebook_page_queue_orders(sanitized)
            except Exception:
                pass
        return sanitized
    return {}


def persist_facebook_page_queue_orders(mapping: dict[str, list[str]]) -> None:
    FACEBOOK_PAGE_QUEUE_ORDER_FILE.parent.mkdir(parents=True, exist_ok=True)
    FACEBOOK_PAGE_QUEUE_ORDER_FILE.write_text(
        json.dumps(mapping, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    try:
        FACEBOOK_PAGE_QUEUE_ORDER_FILE.chmod(0o600)
    except Exception:
        pass


def remove_packages_from_facebook_page_queue_orders(
    queue_orders: dict[str, list[str]],
    package_names: list[str],
) -> dict[str, list[str]]:
    removal = {str(name).strip() for name in package_names if str(name).strip()}
    if not removal:
        return {
            str(page_id): [str(item).strip() for item in values if str(item).strip()]
            for page_id, values in queue_orders.items()
            if str(page_id).strip()
        }

    cleaned: dict[str, list[str]] = {}
    for page_id, values in queue_orders.items():
        trimmed_page_id = str(page_id).strip()
        if not trimmed_page_id:
            continue
        remaining: list[str] = []
        seen: set[str] = set()
        for value in values:
            package_name = str(value).strip()
            if not package_name or package_name in removal or package_name in seen:
                continue
            seen.add(package_name)
            remaining.append(package_name)
        cleaned[trimmed_page_id] = remaining
    return cleaned


def append_packages_to_facebook_page_queue_order(
    queue_orders: dict[str, list[str]],
    package_names: list[str],
    page_id: str,
) -> dict[str, list[str]]:
    trimmed_page_id = str(page_id).strip()
    updated = remove_packages_from_facebook_page_queue_orders(queue_orders, package_names)
    if not trimmed_page_id:
        return updated
    ordered = list(updated.get(trimmed_page_id) or [])
    seen = {str(item).strip() for item in ordered if str(item).strip()}
    for value in package_names:
        package_name = str(value).strip()
        if not package_name or package_name in seen:
            continue
        seen.add(package_name)
        ordered.append(package_name)
    updated[trimmed_page_id] = ordered
    return updated


def snapshot_facebook_page_queue_state(
    package_names: list[str],
    *,
    assignments: dict[str, str] | None = None,
    queue_orders: dict[str, list[str]] | None = None,
) -> dict[str, object]:
    normalized_packages = [
        str(name).strip()
        for name in package_names
        if str(name).strip()
    ]
    if not normalized_packages:
        return {"assignments": {}, "queue_orders": {}}

    package_set = set(normalized_packages)
    effective_assignments = assignments if assignments is not None else load_facebook_page_assignments()
    effective_queue_orders = queue_orders if queue_orders is not None else load_facebook_page_queue_orders()

    assignment_snapshot: dict[str, str] = {}
    for package_name in normalized_packages:
        page_id = str(effective_assignments.get(package_name) or "").strip()
        if page_id:
            assignment_snapshot[package_name] = page_id

    queue_snapshot: dict[str, list[str]] = {}
    for raw_page_id, raw_values in effective_queue_orders.items():
        page_id = str(raw_page_id).strip()
        if not page_id:
            continue
        kept = [
            str(item).strip()
            for item in raw_values
            if str(item).strip() in package_set
        ]
        if kept:
            queue_snapshot[page_id] = kept

    return {
        "assignments": assignment_snapshot,
        "queue_orders": queue_snapshot,
    }


def remove_packages_from_facebook_page_queue_state(package_names: list[str]) -> dict[str, object]:
    normalized_packages = [
        str(name).strip()
        for name in package_names
        if str(name).strip()
    ]
    if not normalized_packages:
        return {"assignments": {}, "queue_orders": {}}

    assignments = load_facebook_page_assignments()
    queue_orders = load_facebook_page_queue_orders()
    snapshot = snapshot_facebook_page_queue_state(
        normalized_packages,
        assignments=assignments,
        queue_orders=queue_orders,
    )

    for package_name in normalized_packages:
        assignments.pop(package_name, None)
    queue_orders = remove_packages_from_facebook_page_queue_orders(queue_orders, normalized_packages)

    persist_facebook_page_assignments(assignments)
    persist_facebook_page_queue_orders(queue_orders)
    return snapshot


def load_package_facebook_status_payload(package_dir: Path) -> dict[str, object]:
    status_path = package_dir / "facebook_reel_status.json"
    if not status_path.exists():
        return {}
    try:
        payload = json.loads(status_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def package_needs_facebook_queue_restore(package_name: str) -> bool:
    try:
        package_path = package_path_for_name(package_name)
    except Exception:
        return False
    if not package_path.exists() or not package_path.is_dir():
        return False
    status_payload = load_package_facebook_status_payload(package_path)
    state = str(status_payload.get("state") or "").strip().lower()
    return state not in {"published", "scheduled"}


def restore_packages_to_facebook_page_queue_state(snapshot: dict[str, object]) -> int:
    assignment_snapshot = snapshot.get("assignments")
    queue_snapshot = snapshot.get("queue_orders")
    if not isinstance(assignment_snapshot, dict) and not isinstance(queue_snapshot, dict):
        return 0

    candidate_packages: set[str] = set()
    if isinstance(assignment_snapshot, dict):
        candidate_packages.update(
            str(package_name).strip()
            for package_name in assignment_snapshot.keys()
            if str(package_name).strip()
        )
    if isinstance(queue_snapshot, dict):
        for values in queue_snapshot.values():
            if not isinstance(values, list):
                continue
            candidate_packages.update(
                str(package_name).strip()
                for package_name in values
                if str(package_name).strip()
            )

    restorable_packages = [
        package_name
        for package_name in sorted(candidate_packages)
        if package_needs_facebook_queue_restore(package_name)
    ]
    if not restorable_packages:
        return 0

    assignments = load_facebook_page_assignments()
    queue_orders = load_facebook_page_queue_orders()
    queue_orders = remove_packages_from_facebook_page_queue_orders(queue_orders, restorable_packages)

    restored_count = 0
    if isinstance(assignment_snapshot, dict):
        for package_name in restorable_packages:
            page_id = str(assignment_snapshot.get(package_name) or "").strip()
            if not page_id:
                continue
            assignments[package_name] = page_id
            restored_count += 1

    if isinstance(queue_snapshot, dict):
        for raw_page_id, raw_values in queue_snapshot.items():
            page_id = str(raw_page_id).strip()
            if not page_id or not isinstance(raw_values, list):
                continue
            ordered = [
                str(package_name).strip()
                for package_name in raw_values
                if str(package_name).strip() in restorable_packages
            ]
            if not ordered:
                continue
            queue_orders = append_packages_to_facebook_page_queue_order(queue_orders, ordered, page_id)

    persist_facebook_page_assignments(assignments)
    persist_facebook_page_queue_orders(queue_orders)
    return restored_count


def load_package_card(
    package_dir: Path,
    *,
    page_assignments: dict[str, str] | None = None,
    queued_page_ids_by_package: dict[str, str] | None = None,
    saved_pages_by_id: dict[str, dict[str, str]] | None = None,
) -> dict[str, object] | None:
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
    package_name = package_dir.name
    assigned_page_id = str((page_assignments or {}).get(package_name) or "").strip()
    queued_page_id = str((queued_page_ids_by_package or {}).get(package_name) or "").strip()
    effective_page_id = assigned_page_id or queued_page_id
    assigned_page = (saved_pages_by_id or {}).get(effective_page_id) or {}
    status_payload = load_package_facebook_status_payload(package_dir)
    status_state = str(status_payload.get("state") or "").strip().lower()
    if status_state not in {"scheduled", "published", "failed"}:
        status_state = ""

    return {
        "id": package_name,
        "package_name": package_name,
        "source_name": source_name,
        "video_name": video_path.name if video_path else "",
        "title": re.sub(r"\s+", " ", title).strip(),
        "has_thumbnail": bool(thumb_path and thumb_path.exists()),
        "thumbnail_name": thumb_path.name if thumb_path else "",
        "schedule_text": load_package_schedule_text(html_text),
        "assigned_facebook_page_id": effective_page_id,
        "assigned_facebook_page_label": str(assigned_page.get("label") or "").strip(),
        "assigned_facebook_page_token_status": str(assigned_page.get("token_status") or "").strip(),
        "is_in_page_queue": bool(queued_page_id),
        "facebook_status_state": status_state,
        "facebook_status_recorded_at": str(status_payload.get("recorded_at") or "").strip(),
        "facebook_status_scheduled_publish_time": str(status_payload.get("scheduled_publish_time") or "").strip(),
        "facebook_status_published_at": str(status_payload.get("published_at") or "").strip(),
    }


def load_package_cards() -> list[dict[str, object]]:
    page_assignments = load_facebook_page_assignments()
    queue_orders = load_facebook_page_queue_orders()
    queued_page_ids_by_package: dict[str, str] = {}
    for page_id, package_names in queue_orders.items():
        trimmed_page_id = str(page_id).strip()
        if not trimmed_page_id:
            continue
        for package_name in package_names:
            trimmed_package = str(package_name).strip()
            if trimmed_package:
                queued_page_ids_by_package[trimmed_package] = trimmed_page_id
    saved_pages_by_id = {
        str(item.get("page_id") or "").strip(): item
        for item in load_saved_facebook_upload_pages()
        if str(item.get("page_id") or "").strip()
    }
    cards: list[dict[str, object]] = []
    for package_dir in reversed(package_dirs(ROOT_DIR)):
        card = load_package_card(
            package_dir,
            page_assignments=page_assignments,
            queued_page_ids_by_package=queued_page_ids_by_package,
            saved_pages_by_id=saved_pages_by_id,
        )
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


def video_path_for_package(package_name: str) -> Path | None:
    package_dir = package_path_for_name(package_name)
    if not package_dir.exists() or not package_dir.is_dir():
        return None
    base_name = preferred_reels_base_name(package_dir)
    return preferred_package_media_path(
        package_dir,
        {"mp4", "mov", "m4v"},
        [f"{base_name}.mp4", "edited_reel_9x16_hd_0.90x_15s.mp4"],
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


def _runtime_fallback_paths(primary_path: Path) -> list[Path]:
    candidates = [
        primary_path,
        Path.home() / "Library/Application Support/Soranin" / primary_path.name,
        Path.home() / "Downloads/Soranin" / primary_path.name,
        Path.home() / ".soranin" / primary_path.name,
    ]
    ordered: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        try:
            normalized = candidate.expanduser().resolve()
        except Exception:
            normalized = candidate.expanduser()
        key = str(normalized)
        if key in seen:
            continue
        seen.add(key)
        ordered.append(normalized)
    return ordered


def _load_string_mapping_from_candidates(primary_path: Path) -> dict[str, str]:
    for candidate in _runtime_fallback_paths(primary_path):
        if not candidate.exists():
            continue
        try:
            payload = json.loads(candidate.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        result = {str(key): str(value) for key, value in payload.items() if isinstance(value, str)}
        if not result:
            continue
        if candidate != primary_path:
            try:
                primary_path.parent.mkdir(parents=True, exist_ok=True)
                primary_path.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
                primary_path.chmod(0o600)
            except Exception:
                pass
        return result
    return {}


def load_saved_api_keys() -> dict[str, str]:
    return _load_string_mapping_from_candidates(API_KEYS_FILE)


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


def build_codex_chat_health_response() -> dict[str, object]:
    openai_key = resolve_api_key("OPENAI_API_KEY")
    return {
        "ok": True,
        "mac_display_name": control_display_name(),
        "openai_key_status": mask_key(openai_key),
        "ready": bool(openai_key),
        "message": "Ready." if openai_key else "OpenAI API key is not set on this Mac.",
    }


def proxy_codex_chat_request(raw_payload: bytes) -> tuple[int, bytes, str]:
    openai_key = resolve_api_key("OPENAI_API_KEY")
    if not openai_key:
        body = json.dumps(
            {
                "ok": False,
                "message": "OpenAI API key is not set on this Mac.",
            }
        ).encode("utf-8")
        return int(HTTPStatus.SERVICE_UNAVAILABLE), body, "application/json; charset=utf-8"

    try:
        payload = json.loads(raw_payload.decode("utf-8")) if raw_payload else {}
    except Exception:
        payload = None
    if not isinstance(payload, dict):
        body = json.dumps(
            {
                "ok": False,
                "message": "Invalid chat payload.",
            }
        ).encode("utf-8")
        return int(HTTPStatus.BAD_REQUEST), body, "application/json; charset=utf-8"

    upstream_body = json.dumps(payload).encode("utf-8")
    request = urllib_request.Request(
        OPENAI_RESPONSES_API_URL,
        data=upstream_body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {openai_key}",
        },
    )
    try:
        with urllib_request.urlopen(request, timeout=180.0) as response:
            content_type = str(response.headers.get("Content-Type") or "application/json; charset=utf-8")
            return int(response.status), response.read(), content_type
    except urllib_error.HTTPError as exc:
        content_type = str(exc.headers.get("Content-Type") or "application/json; charset=utf-8")
        body = exc.read() or json.dumps(
            {
                "ok": False,
                "message": f"OpenAI error {exc.code}.",
            }
        ).encode("utf-8")
        return int(exc.code), body, content_type
    except Exception as exc:
        body = json.dumps(
            {
                "ok": False,
                "message": f"Chat proxy failed: {exc}",
            }
        ).encode("utf-8")
        return int(HTTPStatus.BAD_GATEWAY), body, "application/json; charset=utf-8"


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


def find_profile_item(
    profile_name: str = "",
    profile_directory: str = "",
) -> dict[str, str] | None:
    trimmed_directory = str(profile_directory or "").strip()
    trimmed_name = str(profile_name or "").strip()
    normalized_directory = normalize_name(trimmed_directory)
    normalized_name = normalize_name(trimmed_name)
    for item in load_chrome_profiles():
        item_directory = str(item.get("directory") or "").strip()
        item_name = str(item.get("name") or "").strip()
        if normalized_directory and normalize_name(item_directory) == normalized_directory:
            return {"name": item_name, "directory": item_directory}
        if normalized_name and normalize_name(item_name) == normalized_name:
            return {"name": item_name, "directory": item_directory}
    return None


def find_profile_directory(profile_name: str = "", profile_directory: str = "") -> str | None:
    item = find_profile_item(profile_name=profile_name, profile_directory=profile_directory)
    if item is None:
        return None
    return str(item.get("directory") or "").strip() or None


def load_state_snapshot(state_path: Path) -> dict:
    try:
        return facebook_timing.load_state(state_path)
    except Exception:
        return {}


def load_saved_page_records_snapshot() -> list[dict[str, str]]:
    if not FACEBOOK_SAVED_PAGES_FILE.exists():
        return []
    try:
        payload = json.loads(FACEBOOK_SAVED_PAGES_FILE.read_text(encoding="utf-8"))
    except Exception:
        return []
    if not isinstance(payload, list):
        return []

    records: list[dict[str, str]] = []
    for item in payload:
        if not isinstance(item, dict):
            continue
        page_name = str(item.get("pageName") or "").strip()
        if not page_name:
            continue
        records.append(
            {
                "profile_directory_name": str(item.get("profileDirectoryName") or "").strip(),
                "profile_display_name": str(item.get("profileDisplayName") or "").strip(),
                "page_name": page_name,
                "page_url": str(item.get("pageURL") or "").strip(),
                "page_kind": str(item.get("pageKind") or "page").strip().lower() or "page",
            }
        )
    return records


def normalized_saved_page_kind(value: str | None) -> str:
    lowered = str(value or "").strip().lower()
    return "account" if lowered == "account" else "page"


def persist_saved_page_records_snapshot(records: list[dict[str, str]]) -> None:
    payload: list[dict[str, str]] = []
    for record in records:
        if not isinstance(record, dict):
            continue
        page_name = str(record.get("page_name") or "").strip()
        if not page_name:
            continue
        payload.append(
            {
                "profileDirectoryName": str(record.get("profile_directory_name") or "").strip(),
                "profileDisplayName": str(record.get("profile_display_name") or "").strip(),
                "pageName": page_name,
                "pageURL": str(record.get("page_url") or "").strip(),
                "pageKind": normalized_saved_page_kind(record.get("page_kind")),
            }
        )
    FACEBOOK_SAVED_PAGES_FILE.parent.mkdir(parents=True, exist_ok=True)
    FACEBOOK_SAVED_PAGES_FILE.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def save_saved_page_record(
    chrome_name: str,
    page_name: str,
    page_url: str,
    page_kind: str,
    profile_directory: str = "",
) -> dict[str, str]:
    trimmed_chrome_name = str(chrome_name or "").strip()
    trimmed_profile_directory = str(profile_directory or "").strip()
    trimmed_page_name = str(page_name or "").strip()
    trimmed_page_url = str(page_url or "").strip()
    normalized_kind = normalized_saved_page_kind(page_kind)

    if not trimmed_chrome_name and not trimmed_profile_directory:
        raise ValueError("Chrome Name is required.")
    if not trimmed_page_name:
        raise ValueError("Page or Account Name is required.")

    profile_item = find_profile_item(
        profile_name=trimmed_chrome_name,
        profile_directory=trimmed_profile_directory,
    )
    profile_directory_name = str((profile_item or {}).get("directory") or trimmed_profile_directory).strip()
    profile_display_name = str((profile_item or {}).get("name") or trimmed_chrome_name or trimmed_profile_directory).strip()

    record = {
        "profile_directory_name": profile_directory_name,
        "profile_display_name": profile_display_name,
        "page_name": trimmed_page_name,
        "page_url": trimmed_page_url,
        "page_kind": normalized_kind,
    }

    existing = load_saved_page_records_snapshot()
    filtered: list[dict[str, str]] = []
    target_name = normalize_name(trimmed_page_name)
    for item in existing:
        remembered_profile_name = item.get("profile_display_name") or item.get("profile_directory_name") or ""
        same_profile = profile_names_match(profile_display_name, remembered_profile_name) or (
            profile_directory_name
            and normalize_name(profile_directory_name) == normalize_name(item.get("profile_directory_name"))
        )
        same_name = normalize_name(item.get("page_name")) == target_name
        same_kind = normalized_saved_page_kind(item.get("page_kind")) == normalized_kind
        if same_profile and same_name and same_kind:
            continue
        filtered.append(item)
    filtered.insert(0, record)
    persist_saved_page_records_snapshot(filtered)
    return record


def find_profile_state(
    state_path: Path,
    profile_name: str,
    page_name: str,
    profile_directory: str = "",
) -> dict | None:
    state = load_state_snapshot(state_path)
    profiles = state.get("profiles", {}) if isinstance(state, dict) else {}
    if not isinstance(profiles, dict):
        return None

    target_profile = normalize_name(profile_name)
    target_page = normalize_name(page_name)
    target_profile_directory = normalize_name(profile_directory)
    matches: list[dict] = []
    for profile_state in profiles.values():
        if not isinstance(profile_state, dict):
            continue
        if target_profile_directory and normalize_name(profile_state.get("profile_directory")) != target_profile_directory:
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


def queue_snapshot_for_profile(
    state_path: Path,
    *,
    profile_name: str = "",
    profile_directory: str = "",
    page_name: str = "",
    package_count: int = 0,
) -> dict[str, object]:
    state = load_state_snapshot(state_path)
    if not isinstance(state, dict):
        return {}
    effective_profile_name = profile_name
    effective_profile_directory = profile_directory
    effective_page_name = page_name
    if not any([effective_profile_name, effective_profile_directory, effective_page_name]):
        effective_profile_name = str(state.get("last_profile_name") or "")
        effective_profile_directory = str(state.get("last_profile_directory") or "")
        effective_page_name = str(state.get("last_page_name") or "")
    try:
        summary = facebook_timing.queue_status(
            state,
            profile_name=effective_profile_name or None,
            profile_directory=effective_profile_directory or None,
            page_name=effective_page_name or None,
            package_count=max(0, int(package_count)),
            now=datetime.now().astimezone(),
        )
        return summary if isinstance(summary, dict) else {}
    except Exception:
        return {}


def format_state_summary(profile_state: dict | None) -> str:
    if not profile_state:
        return "No saved memory for this Chrome + page yet."
    queue = queue_snapshot_for_profile(
        FACEBOOK_TIMING_STATE_PATH,
        profile_name=str(profile_state.get("profile_name") or ""),
        profile_directory=str(profile_state.get("profile_directory") or ""),
        page_name=str(profile_state.get("page_name") or ""),
    )
    return (
        f"Chrome: {profile_state.get('profile_name') or '-'}\n"
        f"Page: {profile_state.get('page_name') or '-'}\n"
        f"Last Package: {profile_state.get('last_package_name') or '-'}\n"
        f"Last Anchor: {profile_state.get('last_anchor_label_ampm') or '-'}\n"
        f"Next Queue Time: {queue.get('next_queue_label_ampm') or profile_state.get('next_slot_label_ampm') or '-'}\n"
        f"Reserved Until: {queue.get('reserved_until_label_ampm') or '-'}\n"
        f"Today Remaining Slots: {queue.get('today_remaining_slots') if queue else '-'}\n"
        f"Last Action: {profile_state.get('last_action') or '-'}"
    )


def profile_name_aliases(value: str | None) -> set[str]:
    raw = str(value or "").strip()
    aliases: set[str] = set()
    normalized = normalize_name(raw)
    if normalized:
        aliases.add(normalized)

    plain = normalize_name(re.sub(r"\([^)]*\)", " ", raw))
    if plain:
        aliases.add(plain)

    for match in re.findall(r"\(([^)]*)\)", raw):
        inner = normalize_name(match)
        if inner:
            aliases.add(inner)

    return aliases


def profile_names_match(chrome_profile_name: str | None, remembered_profile_name: str | None) -> bool:
    chrome_aliases = profile_name_aliases(chrome_profile_name)
    remembered_aliases = profile_name_aliases(remembered_profile_name)
    if not chrome_aliases or not remembered_aliases:
        return False
    if chrome_aliases.intersection(remembered_aliases):
        return True
    for chrome_alias in chrome_aliases:
        for remembered_alias in remembered_aliases:
            if chrome_alias and remembered_alias and (
                chrome_alias in remembered_alias or remembered_alias in chrome_alias
            ):
                return True
    return False


def remembered_pages_for_chrome_profile(
    state_path: Path,
    chrome_profile_name: str,
    *,
    state: dict | None = None,
) -> list[str]:
    state = state if isinstance(state, dict) else load_state_snapshot(state_path)
    profiles = state.get("profiles", {}) if isinstance(state, dict) else {}
    if not isinstance(profiles, dict):
        return []

    pages: list[str] = []
    for profile_state in profiles.values():
        if not isinstance(profile_state, dict):
            continue
        page_name = str(profile_state.get("page_name") or "").strip()
        if not page_name:
            continue
        remembered_profile_name = str(profile_state.get("profile_name") or "").strip()
        if profile_names_match(chrome_profile_name, remembered_profile_name):
            pages.append(page_name)
    return unique_ordered_strings(pages)


def build_page_suggestions_by_profile(state_path: Path) -> dict[str, list[str]]:
    suggestions: dict[str, list[str]] = {}
    saved_records = load_saved_page_records_snapshot()
    state = load_state_snapshot(state_path)
    for item in load_chrome_profiles():
        profile_name = str(item.get("name") or "").strip()
        if not profile_name:
            continue
        pages = [
            str(record.get("page_name") or "").strip()
            for record in saved_records
            if profile_names_match(profile_name, record.get("profile_display_name") or record.get("profile_directory_name"))
        ]
        if not pages:
            pages = remembered_pages_for_chrome_profile(
                state_path,
                profile_name,
                state=state,
            )
        suggestions[profile_name] = pages
    return suggestions


def build_saved_page_records_by_profile() -> dict[str, list[dict[str, str]]]:
    saved_records = load_saved_page_records_snapshot()
    grouped: dict[str, list[dict[str, str]]] = {}
    for item in load_chrome_profiles():
        profile_name = str(item.get("name") or "").strip()
        if not profile_name:
            continue
        rows: list[dict[str, str]] = []
        seen: set[tuple[str, str, str]] = set()
        for record in saved_records:
            remembered_profile_name = record.get("profile_display_name") or record.get("profile_directory_name") or ""
            if not profile_names_match(profile_name, remembered_profile_name):
                continue
            key = (
                normalize_name(record.get("page_kind")),
                normalize_name(record.get("page_name")),
                str(record.get("page_url") or "").strip(),
            )
            if key in seen:
                continue
            seen.add(key)
            rows.append(
                {
                    "page_name": str(record.get("page_name") or "").strip(),
                    "page_url": str(record.get("page_url") or "").strip(),
                    "page_kind": str(record.get("page_kind") or "page").strip().lower() or "page",
                }
            )
        grouped[profile_name] = rows
    return grouped


def load_saved_api_settings_snapshot() -> dict[str, str]:
    return _load_string_mapping_from_candidates(API_KEYS_FILE)


def persist_saved_api_settings(payload: dict[str, str]) -> None:
    API_KEYS_FILE.parent.mkdir(parents=True, exist_ok=True)
    API_KEYS_FILE.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    try:
        API_KEYS_FILE.chmod(0o600)
    except Exception:
        pass


def fetch_saved_facebook_page_metrics(
    *,
    page_id: str,
    access_token: str,
    graph_api_version: str = "",
) -> dict[str, object]:
    trimmed_page_id = str(page_id or "").strip()
    trimmed_access_token = str(access_token or "").strip()
    if not trimmed_page_id or not trimmed_access_token:
        return {}

    cache_key = f"{trimmed_page_id}|{graph_api_version.strip()}"
    cache_now = time.monotonic()

    def _refresh_worker() -> None:
        try:
            try:
                payload = facebook_reels_api.fetch_page_video_metrics(
                    page_id=trimmed_page_id,
                    access_token=trimmed_access_token,
                    graph_api_version=graph_api_version or facebook_reels_api.DEFAULT_GRAPH_API_VERSION,
                    window_hours=24,
                    limit=100,
                    timeout=FACEBOOK_PAGE_METRICS_REFRESH_TIMEOUT_SECONDS,
                )
                result = {
                    "video_total": int(payload.get("video_total") or 0),
                    "videos_24h": int(payload.get("videos_24h") or 0),
                    "views_24h": int(payload.get("views_24h") or 0),
                    "metrics_status": "OK",
                    "metrics_checked_at": str(payload.get("checked_at") or "").strip(),
                }
            except Exception as exc:
                result = {
                    "video_total": None,
                    "videos_24h": None,
                    "views_24h": None,
                    "metrics_status": str(exc).strip() or "Facebook metrics unavailable",
                    "metrics_checked_at": "",
                }
            with FACEBOOK_PAGE_METRICS_CACHE_LOCK:
                _FACEBOOK_PAGE_METRICS_CACHE[cache_key] = (time.monotonic(), dict(result))
        finally:
            with FACEBOOK_PAGE_METRICS_CACHE_LOCK:
                _FACEBOOK_PAGE_METRICS_REFRESHING.discard(cache_key)

    with FACEBOOK_PAGE_METRICS_CACHE_LOCK:
        cached = _FACEBOOK_PAGE_METRICS_CACHE.get(cache_key)
        cached_payload = dict(cached[1]) if cached is not None else None
        cache_is_fresh = cached is not None and (cache_now - cached[0]) <= FACEBOOK_PAGE_METRICS_CACHE_TTL_SECONDS
        if cache_is_fresh:
            return cached_payload or {}
        if cache_key not in _FACEBOOK_PAGE_METRICS_REFRESHING:
            _FACEBOOK_PAGE_METRICS_REFRESHING.add(cache_key)
            thread = threading.Thread(target=_refresh_worker, name=f"fb-metrics-{trimmed_page_id}", daemon=True)
            thread.start()
        if cached_payload is not None:
            return cached_payload
    return {
        "video_total": None,
        "videos_24h": None,
        "views_24h": None,
        "metrics_status": "Refreshing in background…",
        "metrics_checked_at": "",
    }


def _saved_facebook_metrics_graph_version(saved_api_settings: dict[str, str] | None = None) -> str:
    payload = saved_api_settings or load_saved_api_settings_snapshot()
    return str(
        payload.get("FACEBOOK_GRAPH_API_VERSION")
        or payload.get("FACEBOOK_GRAPH_VERSION")
        or facebook_reels_api.DEFAULT_GRAPH_API_VERSION
    ).strip()


def refresh_saved_facebook_page_metrics_background_once() -> None:
    saved_pages = load_saved_facebook_upload_pages()
    if not saved_pages:
        return
    graph_api_version = _saved_facebook_metrics_graph_version()
    for record in saved_pages:
        page_id = str(record.get("page_id") or "").strip()
        access_token = str(record.get("access_token") or "").strip()
        if not page_id or not access_token:
            continue
        fetch_saved_facebook_page_metrics(
            page_id=page_id,
            access_token=access_token,
            graph_api_version=graph_api_version,
        )


def facebook_page_metrics_worker_loop() -> None:
    while True:
        try:
            refresh_saved_facebook_page_metrics_background_once()
        except Exception:
            traceback.print_exc()
        time.sleep(FACEBOOK_PAGE_METRICS_BACKGROUND_POLL_SECONDS)


def masked_facebook_token_status(value: str) -> str:
    trimmed = str(value or "").strip()
    if not trimmed:
        return "Not set"
    if len(trimmed) <= 8:
        return "Saved"
    return f"Saved (...{trimmed[-4:]})"


def _facebook_token_parse_timestamp(value: object) -> datetime | None:
    cleaned = str(value or "").strip()
    if not cleaned:
        return None
    normalized = cleaned.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
    except Exception:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _facebook_token_timestamp_string(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat()


def _facebook_token_saved_label(value: str) -> str:
    parsed = _facebook_token_parse_timestamp(value)
    if not parsed:
        return "Not set"
    return parsed.astimezone(facebook_timing.KHMER_TZ).strftime("%Y-%m-%d")


def _facebook_token_countdown_label(saved_at: str, expires_at: str) -> tuple[str, int]:
    now = datetime.now(timezone.utc)
    saved_dt = _facebook_token_parse_timestamp(saved_at)
    expiry_dt = _facebook_token_parse_timestamp(expires_at) or (
        saved_dt + timedelta(days=60) if saved_dt else None
    )
    if not expiry_dt:
        return "60d est. not set", 0
    delta = expiry_dt - now
    if delta.total_seconds() <= 0:
        days_ago = max(1, int(abs(delta.total_seconds()) // 86400))
        return f"Expired ~{days_ago}d ago", 0
    days_left = max(1, int((delta.total_seconds() + 86399) // 86400))
    if days_left >= 1:
        return f"{days_left}d left", days_left
    hours_left = max(1, int((delta.total_seconds() + 3599) // 3600))
    return f"{hours_left}h left", 1


def load_saved_facebook_upload_pages() -> list[dict[str, str]]:
    sanitized: list[dict[str, str]] = []
    for candidate in _runtime_fallback_paths(FACEBOOK_UPLOAD_PAGES_FILE):
        if not candidate.exists():
            continue
        try:
            payload = json.loads(candidate.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(payload, list):
            continue
        records: list[dict[str, str]] = []
        seen_page_ids: set[str] = set()
        did_mutate = False
        now = datetime.now(timezone.utc)
        for item in payload:
            if not isinstance(item, dict):
                continue
            label = str(item.get("label") or "").strip()
            page_id = str(item.get("pageID") or item.get("page_id") or "").strip()
            access_token = str(item.get("accessToken") or item.get("access_token") or "").strip()
            if not label or not page_id or not access_token:
                did_mutate = True
                continue
            if page_id in seen_page_ids:
                did_mutate = True
                continue
            seen_page_ids.add(page_id)
            saved_at = str(item.get("tokenSavedAt") or item.get("token_saved_at") or "").strip()
            expires_at = str(item.get("tokenEstimatedExpiryAt") or item.get("token_estimated_expiry_at") or "").strip()
            saved_dt = _facebook_token_parse_timestamp(saved_at) or now
            expiry_dt = _facebook_token_parse_timestamp(expires_at) or (saved_dt + timedelta(days=60))
            normalized_saved_at = _facebook_token_timestamp_string(saved_dt)
            normalized_expires_at = _facebook_token_timestamp_string(expiry_dt)
            if saved_at != normalized_saved_at or expires_at != normalized_expires_at:
                did_mutate = True
            records.append(
                {
                    "label": label,
                    "page_id": page_id,
                    "access_token": access_token,
                    "token_status": masked_facebook_token_status(access_token),
                    "token_saved_at": normalized_saved_at,
                    "token_estimated_expiry_at": normalized_expires_at,
                }
            )
        if not records:
            continue
        sanitized = records
        if candidate != FACEBOOK_UPLOAD_PAGES_FILE or did_mutate:
            try:
                FACEBOOK_UPLOAD_PAGES_FILE.parent.mkdir(parents=True, exist_ok=True)
                FACEBOOK_UPLOAD_PAGES_FILE.write_text(
                    json.dumps(records, indent=2, ensure_ascii=False),
                    encoding="utf-8",
                )
                FACEBOOK_UPLOAD_PAGES_FILE.chmod(0o600)
            except Exception:
                pass
        break
    return sanitized


def active_facebook_upload_page_summary() -> tuple[str, str, bool]:
    saved_settings = load_saved_api_settings_snapshot()
    page_id = str(saved_settings.get("FACEBOOK_PAGE_ID") or "").strip()
    token = str(
        saved_settings.get("FACEBOOK_PAGE_ACCESS_TOKEN")
        or saved_settings.get("FACEBOOK_ACCESS_TOKEN")
        or ""
    ).strip()
    delete_after_success = str(saved_settings.get("FACEBOOK_DELETE_AFTER_SUCCESS") or "").strip() == "1"
    if not page_id:
        return "", "", delete_after_success
    records = load_saved_facebook_upload_pages()
    record = next((item for item in records if str(item.get("page_id") or "").strip() == page_id), None)
    label = str(record.get("label") or "").strip() if record else page_id
    if not token and record is not None:
        token = str(record.get("access_token") or "").strip()
    return page_id, label, delete_after_success


def build_saved_facebook_upload_pages_response(*, package_count: int = 0) -> list[dict[str, object]]:
    active_page_id, _active_label, _delete_after_success = active_facebook_upload_page_summary()
    state = load_state_snapshot(FACEBOOK_TIMING_STATE_PATH)
    saved_pages = load_saved_facebook_upload_pages()
    saved_api_settings = load_saved_api_settings_snapshot()
    graph_api_version = _saved_facebook_metrics_graph_version(saved_api_settings)
    relay_queue_map: dict[str, dict[str, object]] = {}
    relay_page_ids = [
        str(record.get("page_id") or "").strip()
        for record in saved_pages
        if str(record.get("page_id") or "").strip()
    ]
    if relay_page_ids and facebook_shared_queue.shared_queue_enabled():
        try:
            relay_queue_map = {
                str(page_id): dict(value)
                for page_id, value in facebook_shared_queue.fetch_queue_statuses(
                    relay_page_ids,
                    package_count=package_count,
                    timeout=4.0,
                ).items()
                if isinstance(page_id, str) and isinstance(value, dict)
            }
        except Exception:
            relay_queue_map = {}
    rows: list[dict[str, object]] = []
    for record in saved_pages:
        page_id = str(record.get("page_id") or "").strip()
        access_token = str(record.get("access_token") or "").strip()
        token_saved_at = str(record.get("token_saved_at") or "").strip()
        token_expires_at = str(record.get("token_estimated_expiry_at") or "").strip()
        token_countdown_label, token_days_left = _facebook_token_countdown_label(token_saved_at, token_expires_at)
        metrics_info = fetch_saved_facebook_page_metrics(
            page_id=page_id,
            access_token=access_token,
            graph_api_version=graph_api_version,
        ) if page_id and access_token else {}
        queue_info: dict[str, object] = relay_queue_map.get(page_id) or {}
        if page_id:
            if not queue_info:
                try:
                    queue_info = facebook_timing.queue_status(
                        state,
                        profile_key=f"facebook_api::{page_id}",
                        page_name=page_id,
                        package_count=package_count,
                    )
                except Exception:
                    queue_info = {}
        rows.append(
            {
                "label": str(record.get("label") or "").strip(),
                "page_id": page_id,
                "token_status": str(record.get("token_status") or "Not set"),
                "is_active": bool(active_page_id and page_id == active_page_id),
                "facebook_queue": queue_info,
                "token_saved_at": token_saved_at,
                "token_saved_label": _facebook_token_saved_label(token_saved_at),
                "token_expires_at": token_expires_at,
                "token_expires_label": _facebook_token_saved_label(token_expires_at),
                "token_countdown_label": token_countdown_label,
                "token_days_left": token_days_left,
                "next_queue_label_ampm": str(queue_info.get("next_queue_label_ampm") or "-"),
                "reserved_until_label_ampm": str(queue_info.get("reserved_until_label_ampm") or "-"),
                "today_remaining_slots": int(queue_info.get("today_remaining_slots") or 0),
                "reserved_slots": [
                    str(value).strip()
                    for value in (queue_info.get("reserved_slots") or [])
                    if str(value).strip()
                ],
                "reserved_count": int(queue_info.get("reserved_count") or 0),
                "video_total": metrics_info.get("video_total"),
                "videos_24h": metrics_info.get("videos_24h"),
                "views_24h": metrics_info.get("views_24h"),
                "metrics_status": str(metrics_info.get("metrics_status") or "").strip(),
                "metrics_checked_at": str(metrics_info.get("metrics_checked_at") or "").strip(),
            }
        )
    return rows


def apply_saved_facebook_upload_page(page_id: str, *, delete_after_success: bool | None = None) -> dict[str, str]:
    trimmed_page_id = str(page_id or "").strip()
    if not trimmed_page_id:
        raise RuntimeError("Saved Facebook upload page is required.")

    record = next(
        (item for item in load_saved_facebook_upload_pages() if str(item.get("page_id") or "").strip() == trimmed_page_id),
        None,
    )
    if record is None:
        raise RuntimeError(f"Saved Facebook upload page not found for Page ID: {trimmed_page_id}")

    payload = load_saved_api_settings_snapshot()
    payload["FACEBOOK_PAGE_ID"] = trimmed_page_id
    payload["FACEBOOK_PAGE_ACCESS_TOKEN"] = str(record.get("access_token") or "").strip()
    payload["FACEBOOK_ACCESS_TOKEN"] = str(record.get("access_token") or "").strip()
    payload["FACEBOOK_GRAPH_API_VERSION"] = payload.get("FACEBOOK_GRAPH_API_VERSION") or "v23.0"
    payload["FACEBOOK_GRAPH_VERSION"] = payload.get("FACEBOOK_GRAPH_VERSION") or payload["FACEBOOK_GRAPH_API_VERSION"]
    if delete_after_success is not None:
        payload["FACEBOOK_DELETE_AFTER_SUCCESS"] = "1" if delete_after_success else "0"
    persist_saved_api_settings(payload)
    return record


def quit_google_chrome() -> None:
    subprocess.run(
        ["osascript", "-e", 'tell application "Google Chrome" to quit'],
        text=True,
        capture_output=True,
        check=False,
    )


def run_osascript_lines(lines: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(lines, text=True, capture_output=True, check=False)


def chrome_profile_display_name(profile_directory: str) -> str:
    item = find_profile_item(profile_directory=str(profile_directory or "").strip())
    return str((item or {}).get("name") or profile_directory or "").strip()


def chrome_window_count_for_profile_name(profile_name: str) -> int:
    target_profile_name = str(profile_name or "").strip()
    if not target_profile_name:
        return 0
    profile_suffix = f" - Google Chrome - {target_profile_name}"
    script = f"""
tell application "Google Chrome"
    if not running then return "0"
end tell
tell application "System Events" to tell process "Google Chrome" to set fullTitles to name of every window
set matchingCount to 0
repeat with currentTitle in fullTitles
    if (currentTitle as text) ends with {json.dumps(profile_suffix)} then
        set matchingCount to matchingCount + 1
    end if
end repeat
return matchingCount as text
"""
    result = run_osascript_lines(["osascript", "-e", script])
    output = (result.stdout or "").strip() or (result.stderr or "").strip()
    if result.returncode != 0:
        return 0
    try:
        return int(output or "0")
    except ValueError:
        return 0


def close_chrome_windows_for_profile_name(profile_name: str) -> int:
    target_profile_name = str(profile_name or "").strip()
    if not target_profile_name:
        return 0
    profile_suffix = f" - Google Chrome - {target_profile_name}"
    script = f"""
tell application "Google Chrome"
    if not running then return "0"
end tell
tell application "System Events" to tell process "Google Chrome" to set fullTitles to name of every window
tell application "Google Chrome"
    set closedCount to 0
    repeat with i from (count windows) to 1 by -1
        if item i of fullTitles ends with {json.dumps(profile_suffix)} then
            close window i
            set closedCount to closedCount + 1
        end if
    end repeat
    return closedCount as text
end tell
"""
    result = run_osascript_lines(["osascript", "-e", script])
    output = (result.stdout or "").strip() or (result.stderr or "").strip()
    if result.returncode != 0:
        return 0
    try:
        return int(output or "0")
    except ValueError:
        return 0


def chrome_main_process_command_matches(command: str) -> bool:
    normalized = str(command or "").lower()
    return (
        "google chrome.app/contents/macos/google chrome" in normalized
        and "google chrome helper" not in normalized
    )


def running_chrome_profile_processes() -> list[tuple[int, str]]:
    try:
        result = subprocess.run(
            ["/bin/ps", "axww", "-o", "pid=,command="],
            text=True,
            capture_output=True,
            check=False,
        )
    except Exception:
        return []

    pid_regex = re.compile(r"^\s*(\d+)\s+(.*)$")
    profile_regex = re.compile(r'--profile-directory=(?:"([^"]+)"|([^\s]+))')
    matches: list[tuple[int, str]] = []

    for raw_line in (result.stdout or "").splitlines():
        if not chrome_main_process_command_matches(raw_line):
            continue
        pid_match = pid_regex.match(raw_line)
        if not pid_match:
            continue
        pid = int(pid_match.group(1))
        command = pid_match.group(2)
        profile_match = profile_regex.search(command)
        if not profile_match:
            continue
        directory = (profile_match.group(1) or profile_match.group(2) or "").strip()
        if directory:
            matches.append((pid, directory))

    return matches


def close_chrome_profile(profile_directory: str) -> int:
    target = str(profile_directory or "").strip()
    if not target:
        return 0

    profile_name = chrome_profile_display_name(target)
    closed_windows = close_chrome_windows_for_profile_name(profile_name) if profile_name else 0
    if profile_name:
        deadline = time.time() + 2.0
        saw_profile_window = False
        while time.time() < deadline:
            remaining_profile_windows = chrome_window_count_for_profile_name(profile_name)
            if remaining_profile_windows <= 0:
                if saw_profile_window:
                    closed_windows = max(closed_windows, 1)
                break
            saw_profile_window = True
            time.sleep(0.12)
    if closed_windows:
        time.sleep(0.28)

    matching_pids = [pid for pid, directory in running_chrome_profile_processes() if directory == target]
    if not matching_pids:
        return closed_windows

    closed = 0
    for pid in matching_pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            continue
        closed += 1

    deadline = time.time() + 2.5
    while time.time() < deadline:
        remaining = [pid for pid, directory in running_chrome_profile_processes() if directory == target]
        if not remaining:
            time.sleep(0.18)
            return closed
        time.sleep(0.12)

    remaining = [pid for pid, directory in running_chrome_profile_processes() if directory == target]
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            continue
    if remaining:
        time.sleep(0.22)
    return max(closed, closed_windows)


def open_chrome_profile(profile_directory: str, launch_url: str = "") -> None:
    target_url = str(launch_url or "").strip() or FACEBOOK_CONTENT_LIBRARY_URL
    subprocess.run(
        [
            "open",
            "-na",
            CHROME_APP,
            "--args",
            f"--profile-directory={profile_directory}",
            target_url,
        ],
        text=True,
        capture_output=True,
        check=False,
    )


def build_facebook_post_payload(
    payload: dict[str, object]
) -> tuple[Path, str, str, str, str, str, list[str], int, bool, bool, bool, bool, bool]:
    root = Path(str(payload.get("root") or ROOT_DIR)).expanduser()
    chrome_name = str(payload.get("chrome_name") or "").strip()
    profile_directory = str(payload.get("profile_directory") or "").strip()
    page_name = str(payload.get("page_name") or "").strip()
    page_url = str(payload.get("page_url") or "").strip()
    page_kind = str(payload.get("page_kind") or "").strip().lower()
    packages = parse_folder_names(payload.get("folders") or payload.get("packages") or "")
    interval_raw = str(payload.get("interval_minutes") or "").strip()
    interval = int(interval_raw) if interval_raw.isdigit() and int(interval_raw) > 0 else 30
    close_after_finish = bool(payload.get("close_after_finish", True))
    close_after_each = bool(payload.get("close_after_each", False))
    post_now_advance_slot = bool(payload.get("post_now_advance_slot", False))
    delete_after_each_success = bool(payload.get("delete_after_each_success", True))
    restart_selected_profile_first = bool(payload.get("open_chrome_first", True))
    return (
        root,
        chrome_name,
        profile_directory,
        page_name,
        page_url,
        page_kind,
        packages,
        interval,
        close_after_finish,
        close_after_each,
        post_now_advance_slot,
        delete_after_each_success,
        restart_selected_profile_first,
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
    (
        root,
        chrome_name,
        profile_directory,
        page_name,
        page_url,
        page_kind,
        packages,
        interval,
        _close_after_finish,
        _close_after_each,
        _post_now_advance_slot,
        _delete_after_each_success,
        _restart_selected_profile_first,
    ) = build_facebook_post_payload(payload)
    if not chrome_name and not profile_directory:
        raise RuntimeError("Chrome Name is required.")
    if not packages:
        raise RuntimeError("Please enter at least one folder.")

    first_package = root / packages[0]
    if not first_package.exists():
        raise RuntimeError(f"Package folder not found: {first_package}")

    profile_item = find_profile_item(
        profile_name=chrome_name,
        profile_directory=profile_directory,
    )
    effective_profile_name = str((profile_item or {}).get("name") or chrome_name or profile_directory).strip()
    effective_profile_directory = str((profile_item or {}).get("directory") or profile_directory).strip()
    if not effective_profile_name:
        raise RuntimeError("Could not resolve Chrome profile.")

    command = [
        PYTHON_EXECUTABLE,
        str(FACEBOOK_PREFLIGHT_SCRIPT),
        str(first_package),
        "--interval-minutes",
        str(interval),
        "--profile-name",
        effective_profile_name,
    ]
    if effective_profile_directory:
        command.extend(["--profile-directory", effective_profile_directory])
    if page_name:
        command.extend(["--page-name", page_name])
    if page_url:
        command.extend(["--page-url", page_url])
    if page_kind:
        command.extend(["--page-kind", page_kind])
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
    profile_state = find_profile_state(
        root / ".fb_reels_publish_state.json",
        effective_profile_name,
        page_name,
        effective_profile_directory,
    )
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


def build_facebook_post_bootstrap_response(
    chrome_name: str = "",
    page_name: str = "",
    profile_directory: str = "",
) -> dict[str, object]:
    cache_key = (
        str(chrome_name or "").strip().casefold(),
        str(page_name or "").strip().casefold(),
        str(profile_directory or "").strip().casefold(),
    )
    cache_now = time.monotonic()
    with BOOTSTRAP_CACHE_LOCK:
        cached_entry = _FACEBOOK_BOOTSTRAP_CACHE.get(cache_key)
        if cached_entry is not None:
            cached_at, cached_payload = cached_entry
            if (cache_now - cached_at) <= BOOTSTRAP_CACHE_TTL_SECONDS:
                return dict(cached_payload)

    state_path = FACEBOOK_TIMING_STATE_PATH
    profile_item = find_profile_item(
        profile_name=chrome_name,
        profile_directory=profile_directory,
    )
    effective_profile_name = str((profile_item or {}).get("name") or chrome_name or profile_directory).strip()
    effective_profile_directory = str((profile_item or {}).get("directory") or profile_directory).strip()
    profile_state = find_profile_state(
        state_path,
        effective_profile_name,
        page_name,
        effective_profile_directory,
    )
    package_cards = load_package_cards()
    queue_info = queue_snapshot_for_profile(
        state_path,
        profile_name=effective_profile_name,
        profile_directory=effective_profile_directory,
        page_name=page_name,
        package_count=len(package_cards),
    )
    page_suggestions_by_profile = build_page_suggestions_by_profile(state_path)
    saved_page_records_by_profile = build_saved_page_records_by_profile()
    saved_upload_pages = build_saved_facebook_upload_pages_response(package_count=len(package_cards))
    active_upload_page_id, active_upload_page_label, facebook_delete_after_success = active_facebook_upload_page_summary()
    mac_user_name = control_display_user_name()
    mac_device_name = control_display_device_name()
    payload = {
        "ok": True,
        "profiles": [item["name"] for item in load_chrome_profiles()],
        "profile_items": load_chrome_profiles(),
        "page_suggestions_by_profile": page_suggestions_by_profile,
        "page_suggestions": page_suggestions_by_profile.get(effective_profile_name, []),
        "saved_page_records_by_profile": saved_page_records_by_profile,
        "saved_page_records": saved_page_records_by_profile.get(effective_profile_name, []),
        "saved_upload_pages": saved_upload_pages,
        "active_upload_page_id": active_upload_page_id,
        "active_upload_page_label": active_upload_page_label,
        "facebook_delete_after_success": facebook_delete_after_success,
        "packages": package_cards,
        "default_root": str(ROOT_DIR),
        "memory_summary": format_state_summary(profile_state),
        "facebook_queue": queue_info,
        "mac_user_name": mac_user_name,
        "mac_device_name": mac_device_name,
        "mac_display_name": control_display_name(),
        "relay_enabled": bool(control_relay_base_url() and control_relay_client_token()),
        "relay_base_url": control_relay_base_url(),
        "relay_client_token": control_relay_client_token(),
        "relay_client_url": control_relay_client_base_url(),
        "tailscale_url": preferred_tailscale_control_server_url(),
        "relay_user_name": control_relay_user_name(),
        "relay_mac_name": control_relay_mac_name(),
        "password_required": control_password_required(),
    }
    with BOOTSTRAP_CACHE_LOCK:
        _FACEBOOK_BOOTSTRAP_CACHE[cache_key] = (cache_now, payload)
    return dict(payload)


class ManagerState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.proc: subprocess.Popen[str] | None = None
        self.remote_running = False
        self.remote_download_thread_active = False
        self.remote_batch_autostart_pending = False
        self.remote_queue: deque[DownloadEntry] = deque()
        self.remote_queue_keys: set[str] = set()
        self.task_kind = ""
        self.facebook_post_stop_requested = False
        self.logs: deque[str] = deque(maxlen=500)
        self.alerts: deque[dict[str, object]] = deque(maxlen=32)
        self.next_alert_id = 1
        self.status = "Idle"
        self.detail = "Ready."
        self.progress_percent = 0
        self.progress_label = ""
        self.facebook_profile_name = ""
        self.facebook_profile_directory = ""
        self.facebook_page_name = ""
        self.remote_download_almost_done_notified = False

    def _remote_entry_key(self, entry: DownloadEntry) -> str:
        return f"{entry.kind}:{entry.value.lower()}"

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

    def _download_progress_snapshot(self, line: str) -> tuple[str, str, int, str] | None:
        match = REMOTE_DOWNLOAD_PROGRESS_PATTERN.match(line)
        if not match:
            return None
        source_kind = match.group(1).strip().lower()
        source_value = (match.group(2) or "").strip()
        try:
            percent = max(0, min(100, int(match.group(3))))
        except Exception:
            return None
        if source_kind == "facebook":
            label = f"Downloading Facebook video... {percent}%"
        elif source_value:
            label = f"Downloading {source_value}... {percent}%"
        else:
            label = f"Downloading on Mac... {percent}%"
        return source_kind, source_value, percent, label

    def _maybe_emit_remote_download_progress_alert(self, line: str) -> None:
        snapshot = self._download_progress_snapshot(line)
        if snapshot is None:
            return
        source_kind, source_value, percent, _ = snapshot
        should_emit = False
        with self.lock:
            if (
                self.task_kind == "remote_download"
                and percent >= 90
                and not self.remote_download_almost_done_notified
            ):
                self.remote_download_almost_done_notified = True
                should_emit = True
        if should_emit:
            if source_kind == "facebook":
                title = "Facebook download 90%"
                message = "Facebook video download on Mac reached 90%. Almost done."
            elif source_value:
                title = "Sora download 90%"
                message = f"{source_value} download on Mac reached 90%. Almost done."
            else:
                title = "Mac download 90%"
                message = "Download on Mac reached 90%. Almost done."
            self.emit_alert(
                title,
                message,
            )

    def _remote_download_failure_message(self, lines: list[str], returncode: int) -> str:
        for raw_line in reversed(lines):
            line = str(raw_line or "").strip()
            if not line:
                continue
            if line.startswith("[remote] "):
                line = line[len("[remote] "):].strip()
            if line.startswith("[post] FAILED:"):
                detail = line.split("FAILED:", 1)[1].strip()
                if detail:
                    return detail
            if line.startswith("[facebook] FAILED:"):
                detail = line.split("FAILED:", 1)[1].strip()
                if detail:
                    return detail
            if line.startswith("[post] Complete with failures:"):
                continue
            if "yt-dlp is required" in line:
                return line
            if "Could not resolve Facebook URL:" in line:
                return line
            if "No supported Facebook reel/video URL was found." in line:
                return line
            if "No valid Sora or Facebook links found." in line:
                return line
            if "Unexpected content-type" in line:
                return line
            if "Network error:" in line:
                return line
            if re.search(r"\bHTTP \d{3}\b", line):
                return line
        return f"Remote download failed with exit code {returncode}."

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
        upload_match = FACEBOOK_UPLOAD_PATTERN.match(line)
        if upload_match:
            try:
                self.progress_percent = max(0, min(100, int(upload_match.group(1))))
            except Exception:
                self.progress_percent = 0
            self.progress_label = upload_match.group(2).strip()
            self.status = "Running"
            if self.progress_label:
                self.detail = self.progress_label
            return
        download_progress = self._download_progress_snapshot(line)
        if download_progress is not None:
            _, _, self.progress_percent, self.progress_label = download_progress
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
            self.task_kind = "batch"
            self.facebook_post_stop_requested = False

            self.proc = subprocess.Popen(
                [PYTHON_EXECUTABLE, str(BATCH_SCRIPT), str(ROOT_DIR)],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            threading.Thread(target=self._consume_output, daemon=True).start()
        self.emit_alert("Soranin on Mac", "Batch started on this Mac.")
        return True, "Batch started."

    def start_remote(self, raw_values: list[str]) -> tuple[bool, str]:
        entries = build_entries(raw_values)
        if not entries:
            return False, "No valid Sora or Facebook links were provided."

        fresh_entries, duplicate_entries = filter_unused_remote_entries(entries)
        if not fresh_entries:
            return False, "This link or ID was already used on this Mac."

        with self.lock:
            queued_entries: list[DownloadEntry] = []
            already_queued_count = 0
            for entry in fresh_entries:
                entry_key = self._remote_entry_key(entry)
                if entry_key in self.remote_queue_keys:
                    already_queued_count += 1
                    continue
                self.remote_queue.append(entry)
                self.remote_queue_keys.add(entry_key)
                queued_entries.append(entry)

            if not queued_entries:
                skipped_count = len(duplicate_entries) + already_queued_count
                if skipped_count:
                    return False, f"Skipped {skipped_count} already-used or already-queued item(s)."
                return False, "No new items were queued."

            process_running = self.proc is not None and self.proc.poll() is None
            should_start_thread = not self.remote_download_thread_active
            self.remote_running = True
            self.facebook_post_stop_requested = False
            self.remote_download_almost_done_notified = False
            if not process_running:
                self.logs.clear()
                self.status = "Running"
                self.detail = f"Preparing remote download ({len(queued_entries)} item(s))..."
                self.progress_percent = 0
                self.progress_label = self.detail
                self.task_kind = "remote_download"
            else:
                self.logs.append(
                    f"[remote] Queued {len(queued_entries)} item(s) while current batch is running."
                )
            self.logs.append(f"[remote] Received {len(queued_entries)} new item(s).")
            if duplicate_entries or already_queued_count:
                self.logs.append(
                    f"[remote] Skipped {len(duplicate_entries) + already_queued_count} already-used/already-queued item(s)."
                )
            if should_start_thread:
                self.remote_download_thread_active = True

        self.emit_alert(
            "New URL on Mac",
            f"Received {len(queued_entries)} link(s) from iPhone. Preparing download...",
        )
        if should_start_thread:
            threading.Thread(target=self._run_remote_flow, daemon=True).start()
        skipped_total = len(duplicate_entries) + already_queued_count
        if should_start_thread:
            if skipped_total:
                return True, f"Remote flow started for {len(queued_entries)} item(s). Skipped {skipped_total} already-used/already-queued item(s)."
            return True, f"Remote flow started for {len(queued_entries)} item(s)."
        if skipped_total:
            return True, f"Queued {len(queued_entries)} item(s). Skipped {skipped_total} already-used/already-queued item(s)."
        return True, f"Queued {len(queued_entries)} item(s)."

    def start_facebook_post(self, payload: dict[str, object]) -> tuple[bool, str]:
        (
            root,
            chrome_name,
            profile_directory,
            page_name,
            page_url,
            page_kind,
            packages,
            interval,
            close_after_finish,
            close_after_each,
            post_now_advance_slot,
            delete_after_each_success,
            restart_selected_profile_first,
        ) = build_facebook_post_payload(payload)

        if not chrome_name and not profile_directory:
            return False, "Chrome Name is required."
        if not packages:
            return False, "Please enter at least one folder."

        profile_item = find_profile_item(
            profile_name=chrome_name,
            profile_directory=profile_directory,
        )
        effective_profile_name = str((profile_item or {}).get("name") or chrome_name or profile_directory).strip()
        effective_profile_directory = str((profile_item or {}).get("directory") or profile_directory).strip()
        if not effective_profile_name or not effective_profile_directory:
            if profile_directory:
                return False, f"Could not find Chrome profile directory for: {profile_directory}"
            return False, f"Could not find Chrome profile directory for: {chrome_name}"

        with self.lock:
            if self.remote_running:
                return False, "A remote flow is already running."
            if self.proc is not None and self.proc.poll() is None:
                return False, "A batch is already running."

            target_label = page_name or "Current account"
            self.remote_running = True
            self.logs.clear()
            self.logs.append(f"[facebook-post] Chrome: {effective_profile_name}")
            self.logs.append(f"[facebook-post] Target: {target_label}")
            if page_kind:
                self.logs.append(f"[facebook-post] Target Type: {page_kind}")
            if page_url:
                self.logs.append(f"[facebook-post] Page URL: {page_url}")
            self.logs.append(f"[facebook-post] Folders: {' '.join(packages)}")
            self.status = "Running"
            self.detail = f"Preparing Facebook post run ({len(packages)} folder(s))..."
            self.progress_percent = 0
            self.progress_label = self.detail
            self.task_kind = "facebook_post"
            self.facebook_post_stop_requested = False
            self.facebook_profile_name = effective_profile_name
            self.facebook_profile_directory = effective_profile_directory
            self.facebook_page_name = page_name
        self.emit_alert(
            "Facebook post on Mac",
            f"Preparing {len(packages)} folder(s) for {target_label}.",
        )

        thread = threading.Thread(
            target=self._run_facebook_post_flow,
            args=(
                root,
                effective_profile_name,
                effective_profile_directory,
                page_name,
                page_url,
                page_kind,
                packages,
                interval,
                close_after_finish,
                close_after_each,
                post_now_advance_slot,
                delete_after_each_success,
                restart_selected_profile_first,
            ),
            daemon=True,
        )
        thread.start()
        return True, f"Facebook post run started for {len(packages)} folder(s)."

    def start_facebook_api_upload(self, payload: dict[str, object]) -> tuple[bool, str]:
        raw_packages = payload.get("packages")
        if not isinstance(raw_packages, list):
            raw_packages = payload.get("folders")
        packages = [
            str(item).strip()
            for item in (raw_packages or [])
            if str(item).strip()
        ]
        mode = str(payload.get("mode") or "publish").strip().lower()
        page_id = str(payload.get("page_id") or "").strip()
        delete_after_success = bool(payload.get("delete_after_success"))
        if mode == "publish":
            # Control-Mac publish should always clear the finished package folder.
            delete_after_success = True

        if mode not in {"publish", "schedule"}:
            return False, "Mode must be publish or schedule."
        if not page_id:
            return False, "Saved Facebook upload page is required."
        if not packages:
            return False, "Please choose at least one package."

        missing = [name for name in packages if not (ROOT_DIR / name).is_dir()]
        if missing:
            return False, f"Package folder not found: {missing[0]}"

        with self.lock:
            if self.remote_running:
                return False, "A remote flow is already running."
            if self.proc is not None and self.proc.poll() is None:
                return False, "A batch is already running."

            self.remote_running = True
            self.logs.clear()
            self.status = "Running"
            self.detail = f"Preparing Facebook {mode} ({len(packages)} package(s))..."
            self.progress_percent = 0
            self.progress_label = self.detail
            self.task_kind = "facebook_api_upload"
            self.facebook_post_stop_requested = False
            self.facebook_profile_name = ""
            self.facebook_profile_directory = ""
            self.facebook_page_name = page_id

        queue_restore_snapshot: dict[str, object] | None = None
        if mode == "publish":
            try:
                queue_restore_snapshot = remove_packages_from_facebook_page_queue_state(packages)
            except Exception as exc:
                with self.lock:
                    self.remote_running = False
                    self.task_kind = ""
                    self.facebook_page_name = ""
                    self.status = "Failed"
                    self.detail = f"Facebook publish failed: {exc}"
                    self.progress_label = self.detail
                return False, f"Could not update page queue before publish: {exc}"

        try:
            record = apply_saved_facebook_upload_page(
                page_id,
                delete_after_success=delete_after_success,
            )
        except Exception as exc:
            if queue_restore_snapshot:
                try:
                    restore_packages_to_facebook_page_queue_state(queue_restore_snapshot)
                except Exception:
                    pass
            with self.lock:
                self.remote_running = False
                self.task_kind = ""
                self.facebook_page_name = ""
                self.status = "Failed"
                self.detail = f"Facebook {mode} failed: {exc}"
                self.progress_label = self.detail
            return False, str(exc)

        label = str(record.get("label") or page_id).strip() or page_id

        with self.lock:
            self.logs.clear()
            self.logs.append(f"[facebook-upload] Page: {label}")
            self.logs.append(f"[facebook-upload] Mode: {mode}")
            self.logs.append(f"[facebook-upload] Packages: {' '.join(packages)}")
            self.status = "Running"
            self.detail = f"Preparing Facebook {mode} ({len(packages)} package(s))..."
            self.progress_percent = 0
            self.progress_label = self.detail
            self.task_kind = "facebook_api_upload"
            self.facebook_post_stop_requested = False
            self.facebook_profile_name = ""
            self.facebook_profile_directory = ""
            self.facebook_page_name = page_id

        self.emit_alert(
            "Facebook upload on Mac",
            f"Preparing {mode} for {len(packages)} package(s) on {label}.",
        )

        thread = threading.Thread(
            target=self._run_facebook_api_upload_flow,
            args=(packages, mode, delete_after_success, page_id, label, queue_restore_snapshot),
            daemon=True,
        )
        thread.start()
        return True, f"Facebook {mode} started for {len(packages)} package(s)."

    def _facebook_post_stop_requested_now(self) -> bool:
        with self.lock:
            return self.task_kind == "facebook_post" and self.facebook_post_stop_requested

    def _finish_facebook_post_stopped(self, detail: str) -> None:
        with self.lock:
            self.remote_running = False
            self.proc = None
            self.task_kind = ""
            self.facebook_post_stop_requested = False
            self.logs.append("STOPPED")
            self.status = "Stopped"
            self.detail = detail
            self.progress_percent = 0
            self.progress_label = detail
        self.emit_alert("Facebook post stopped", detail)

    def stop_facebook_post(self) -> tuple[bool, str]:
        process: subprocess.Popen[str] | None = None
        with self.lock:
            process = self.proc
            process_running = process is not None and process.poll() is None
            if self.task_kind != "facebook_post" or not (self.remote_running or process_running):
                return False, "Facebook post is not running."

            self.facebook_post_stop_requested = True
            self.status = "Stopping"
            self.detail = "Stopping Facebook post run..."
            self.progress_label = self.detail
            self.logs.append("[facebook-post] STOP_REQUESTED")

        if process is not None and process.poll() is None:
            try:
                process.terminate()
            except Exception:
                pass
            pid = process.pid

            def force_kill() -> None:
                try:
                    if process.poll() is None:
                        os.kill(pid, signal.SIGKILL)
                except Exception:
                    pass

            threading.Timer(0.8, force_kill).start()

        return True, "Stopping Facebook post run..."

    def _run_facebook_post_flow(
        self,
        root: Path,
        chrome_name: str,
        profile_directory: str,
        page_name: str,
        page_url: str,
        page_kind: str,
        packages: list[str],
        interval: int,
        close_after_finish: bool,
        close_after_each: bool,
        post_now_advance_slot: bool,
        delete_after_each_success: bool,
        restart_selected_profile_first: bool,
    ) -> None:
        close_selected_profile_when_done = close_after_finish or close_after_each
        command = [
            PYTHON_EXECUTABLE,
            str(FACEBOOK_BATCH_SCRIPT),
            str(root),
            "--profile-name",
            chrome_name,
            "--profile-directory",
            profile_directory,
            "--packages",
            *packages,
            "--interval-minutes",
            str(interval),
        ]
        if page_name:
            command.extend(["--page-name", page_name])
        if page_url:
            command.extend(["--page-url", page_url])
        if page_kind:
            command.extend(["--page-kind", page_kind])
        if close_after_finish:
            command.append("--close-after-finish")
        if close_after_each:
            command.append("--close-after-each")
        if post_now_advance_slot:
            command.append("--post-now-advance-slot")
        if delete_after_each_success:
            command.append("--delete-after-each-success")

        try:
            if restart_selected_profile_first:
                self.append_log(
                    f"[facebook-post] Batch will close only the selected Chrome profile before first folder, then reopen it on the upload step: {chrome_name}"
                )
            else:
                self.append_log(f"[facebook-post] Using existing Chrome profile session: {chrome_name}")
            if self._facebook_post_stop_requested_now():
                if close_selected_profile_when_done:
                    closed_after_stop = close_chrome_profile(profile_directory)
                    if closed_after_stop:
                        self.append_log(
                            f"[facebook-post] Closed {closed_after_stop} selected Chrome profile window/process item(s) after stop."
                        )
                self._finish_facebook_post_stopped("Facebook post stopped.")
                return

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
            should_emit_stopped = False
            failed_message = ""
            closed_after_run = 0
            stop_requested = self._facebook_post_stop_requested_now()
            if returncode == 0 and close_selected_profile_when_done:
                closed_after_run = close_chrome_profile(profile_directory)
            elif stop_requested and close_selected_profile_when_done:
                closed_after_run = close_chrome_profile(profile_directory)
            with self.lock:
                if stop_requested:
                    if closed_after_run:
                        self.logs.append(
                            f"[facebook-post] Closed {closed_after_run} selected Chrome profile window/process item(s) after stop."
                        )
                    self.logs.append("STOPPED")
                    self.status = "Stopped"
                    self.detail = "Facebook post stopped."
                    self.progress_percent = 0
                    self.progress_label = self.detail
                    should_emit_stopped = True
                elif returncode == 0:
                    if closed_after_run:
                        self.logs.append(
                            f"[facebook-post] Closed {closed_after_run} selected Chrome profile window/process item(s) after run."
                        )
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
                self.task_kind = ""
                self.facebook_post_stop_requested = False
                if not self.remote_running:
                    self.facebook_profile_name = chrome_name
                    self.facebook_profile_directory = profile_directory
                    self.facebook_page_name = page_name
            if should_emit_done:
                self.emit_alert("Facebook post done", "Facebook post batch finished on this Mac.")
            elif should_emit_stopped:
                self.emit_alert("Facebook post stopped", "Facebook post run was stopped on this Mac.")
            elif should_emit_failed:
                self.emit_alert("Facebook post failed", failed_message, "error")
            return
        except Exception as exc:
            stop_requested = self._facebook_post_stop_requested_now()
            closed_after_stop = 0
            if stop_requested and close_selected_profile_when_done:
                closed_after_stop = close_chrome_profile(profile_directory)
            with self.lock:
                self.remote_running = False
                self.proc = None
                self.task_kind = ""
                self.facebook_post_stop_requested = False
                self.facebook_profile_name = chrome_name
                self.facebook_profile_directory = profile_directory
                self.facebook_page_name = page_name
                if stop_requested:
                    if closed_after_stop:
                        self.logs.append(
                            f"[facebook-post] Closed {closed_after_stop} selected Chrome profile window/process item(s) after stop."
                        )
                    self.logs.append("STOPPED")
                    self.status = "Stopped"
                    self.detail = "Facebook post stopped."
                    self.progress_percent = 0
                    self.progress_label = self.detail
                else:
                    self.logs.append(f"[facebook-post] FAILED: {exc}")
                    self.logs.append("FAILED")
                    self.status = "Failed"
                    self.detail = f"Facebook post flow failed: {exc}"
                    self.progress_label = self.detail
            if stop_requested:
                self.emit_alert("Facebook post stopped", "Facebook post run was stopped on this Mac.")
            else:
                self.emit_alert("Facebook post failed", str(exc), "error")
            return

    def _run_facebook_api_upload_flow(
        self,
        packages: list[str],
        mode: str,
        delete_after_success: bool,
        page_id: str,
        page_label: str,
        queue_restore_snapshot: dict[str, object] | None = None,
    ) -> None:
        command = [
            PYTHON_EXECUTABLE,
            str(FACEBOOK_API_UPLOAD_SCRIPT),
            *packages,
            "--mode",
            mode,
        ]
        if delete_after_success:
            command.append("--delete-after-success")

        try:
            should_autostart_batch = False
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
                self.detail = f"Facebook {mode} running..."
                self.progress_label = self.detail
                self.facebook_page_name = page_id

            if process.stdout is not None:
                for raw_line in process.stdout:
                    line = raw_line.rstrip()
                    if not line:
                        continue
                    self.append_log(line if line.startswith("[") else f"[facebook-upload] {line}")

            returncode = process.wait()
            should_emit_done = False
            should_emit_failed = False
            failed_message = ""
            with self.lock:
                if returncode == 0:
                    self.logs.append("DONE")
                    self.status = "Done"
                    self.detail = "Facebook upload complete."
                    self.progress_percent = 100
                    self.progress_label = self.detail
                    should_autostart_batch = bool(source_videos(ROOT_DIR))
                    should_emit_done = True
                else:
                    self.logs.append("FAILED")
                    self.status = "Failed"
                    self.detail = f"Facebook upload failed (exit {returncode})."
                    self.progress_label = self.detail
                    should_emit_failed = True
                    failed_message = f"Facebook {mode} failed for {page_label} (exit {returncode})."
                self.remote_running = False
                self.proc = None
                self.task_kind = ""
                self.facebook_page_name = ""
                self.facebook_profile_name = ""
                self.facebook_profile_directory = ""

            if should_emit_done:
                self.emit_alert(
                    "Facebook upload done",
                    f"Facebook {mode} finished on {page_label}.",
                )
                if should_autostart_batch:
                    started, message = self.start()
                    if started:
                            self.append_log("[facebook-upload] Auto starting AI edit for remaining source videos.")
                    else:
                        self.append_log(f"[facebook-upload] Remaining source videos found, but auto start was skipped: {message}")
            elif should_emit_failed:
                if queue_restore_snapshot:
                    try:
                        restored_count = restore_packages_to_facebook_page_queue_state(queue_restore_snapshot)
                        if restored_count > 0:
                            self.append_log(
                                f"[facebook-upload] Restored {restored_count} package(s) back to the page queue after failed publish."
                            )
                    except Exception as restore_exc:
                        self.append_log(
                            f"[facebook-upload] Queue restore warning after failed publish: {restore_exc}"
                        )
                self.emit_alert("Facebook upload failed", failed_message, "error")
        except Exception as exc:
            if queue_restore_snapshot:
                try:
                    restored_count = restore_packages_to_facebook_page_queue_state(queue_restore_snapshot)
                    if restored_count > 0:
                        self.append_log(
                            f"[facebook-upload] Restored {restored_count} package(s) back to the page queue after upload exception."
                        )
                except Exception as restore_exc:
                    self.append_log(
                        f"[facebook-upload] Queue restore warning after upload exception: {restore_exc}"
                    )
            with self.lock:
                self.remote_running = False
                self.logs.append(f"[facebook-upload] FAILED: {exc}")
                self.logs.append("FAILED")
                self.status = "Failed"
                self.detail = f"Facebook upload failed: {exc}"
                self.progress_label = self.detail
                self.task_kind = ""
                self.proc = None
                self.facebook_page_name = ""
                self.facebook_profile_name = ""
                self.facebook_profile_directory = ""
            self.emit_alert("Facebook upload failed", str(exc), "error")
            return

    def _run_remote_flow(self) -> None:
        try:
            while True:
                with self.lock:
                    entries = list(self.remote_queue)
                    self.remote_queue.clear()
                    self.remote_queue_keys.clear()
                    if not entries:
                        self.remote_running = False
                        self.remote_download_thread_active = False
                        if self.task_kind == "remote_download":
                            self.task_kind = ""
                        break

                command = [
                    PYTHON_EXECUTABLE,
                    str(DOWNLOADER_SCRIPT),
                    str(ROOT_DIR),
                    *[entry.value for entry in entries],
                ]
                self.emit_alert(
                    "Running download on Mac",
                    f"Downloading {len(entries)} item(s) on this Mac now.",
                )
                proc = subprocess.Popen(
                    command,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
                run_lines: list[str] = []

                if proc.stdout is not None:
                    for raw_line in proc.stdout:
                        line = raw_line.rstrip()
                        if not line:
                            continue
                        prefixed_line = line if line.startswith("[remote]") else f"[remote] {line}"
                        run_lines.append(prefixed_line)
                        self._maybe_emit_remote_download_progress_alert(prefixed_line)
                        self.append_log(prefixed_line)

                returncode = proc.wait()
                if returncode != 0:
                    failure_message = self._remote_download_failure_message(run_lines, returncode)
                    with self.lock:
                        self.logs.append("FAILED")
                        self.status = "Failed"
                        self.detail = failure_message
                        self.progress_label = self.detail
                        self.remote_download_almost_done_notified = False
                    self.emit_alert(
                        "Mac download failed",
                        failure_message,
                        "error",
                    )
                    continue

                mark_remote_entries_used(entries)
                self.append_log("[remote] Download complete.")

                with self.lock:
                    batch_running = self.proc is not None and self.proc.poll() is None
                    has_more_queued_entries = bool(self.remote_queue)
                    if batch_running:
                        self.remote_batch_autostart_pending = True
                        self.status = "Running"
                        self.detail = "Downloads complete. Waiting for current batch to finish..."
                        self.progress_label = self.detail
                        self.task_kind = "remote_download"
                    elif has_more_queued_entries:
                        self.status = "Running"
                        self.detail = "Downloads complete. Continuing queued downloads..."
                        self.progress_label = self.detail
                        self.task_kind = "remote_download"
                    else:
                        self.remote_running = False
                        self.remote_download_thread_active = False
                        self.task_kind = ""
                        self.remote_download_almost_done_notified = False

                if batch_running:
                    self.emit_alert(
                        "Download queued on Mac",
                        "Download finished. Waiting for current edit / batch to finish before continuing.",
                    )
                    continue
                if has_more_queued_entries:
                    self.append_log("[remote] Continuing queued downloads before starting batch...")
                    continue

                self.emit_alert(
                    "Download done on Mac",
                    "Download finished. Starting edit / batch now.",
                )
                ok, message = self.start()
                if not ok:
                    with self.lock:
                        self.logs.append(f"[remote] {message}")
                        self.status = "Failed"
                        self.detail = message
                        self.progress_label = self.detail
                        self.task_kind = ""
                        self.remote_download_almost_done_notified = False
                    self.emit_alert("Mac batch failed", message, "error")
        except Exception as exc:
            with self.lock:
                self.remote_running = False
                self.remote_download_thread_active = False
                self.logs.append(f"[remote] FAILED: {exc}")
                self.logs.append("FAILED")
                self.status = "Failed"
                self.detail = f"Remote flow failed: {exc}"
                self.progress_label = self.detail
                self.task_kind = ""
                self.remote_download_almost_done_notified = False
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
            self.task_kind = ""
        if should_emit_done:
            self.emit_alert("Mac edit done", "Download / edit flow finished on this Mac.")
            should_restart_remote_batch = False
            with self.lock:
                if self.remote_batch_autostart_pending and bool(source_videos(ROOT_DIR)):
                    self.remote_batch_autostart_pending = False
                    should_restart_remote_batch = True
                else:
                    self.remote_batch_autostart_pending = False
            if should_restart_remote_batch:
                self.append_log("[remote] Current batch finished. Starting next batch for newly downloaded items.")
                started, message = self.start()
                if not started:
                    self.append_log(f"[remote] Auto start skipped: {message}")
        elif should_emit_failed:
            self.emit_alert("Mac batch failed", failed_message, "error")

    def snapshot(self) -> dict[str, object]:
        ROOT_DIR.mkdir(parents=True, exist_ok=True)
        sources = source_videos(ROOT_DIR)
        packages = package_dirs(ROOT_DIR)
        openai_key = resolve_api_key("OPENAI_API_KEY")
        gemini_key = resolve_api_key("GEMINI_API_KEY", "GOOGLE_API_KEY")
        provider = resolve_ai_provider()
        mac_user_name = control_display_user_name()
        mac_device_name = control_display_device_name()
        mac_display_name = control_display_name()
        with self.lock:
            is_running = self.remote_running or (self.proc is not None and self.proc.poll() is None)
            profile_name = self.facebook_profile_name
            profile_directory = self.facebook_profile_directory
            page_name = self.facebook_page_name
        queue_info = queue_snapshot_for_profile(
            FACEBOOK_TIMING_STATE_PATH,
            profile_name=profile_name,
            profile_directory=profile_directory,
            page_name=page_name,
            package_count=len(packages),
        )
        with self.lock:
            is_running = self.remote_running or (self.proc is not None and self.proc.poll() is None)
            return {
                "status": self.status,
                "detail": self.detail,
                "progress_percent": self.progress_percent,
                "progress_label": self.progress_label,
                "running": is_running,
                "remote_running": self.remote_running,
                "task_kind": self.task_kind,
                "source_count": len(sources),
                "package_count": len(packages),
                "latest_package": packages[-1].name if packages else "-",
                "logs": list(self.logs),
                "alerts": list(self.alerts),
                "latest_alert": self.alerts[-1] if self.alerts else None,
                "facebook_queue": queue_info,
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
                "tailscale_url": preferred_tailscale_control_server_url(),
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
        "/facebook-feed-videos",
        "/facebook-feed-video",
        "/facebook-feed-video-delete",
        "/facebook-packages",
        "/facebook-package-video",
        "/facebook-package-import",
        "/facebook-package-file-upload",
        "/facebook-package-finalize",
        "/source-video-upload",
        "/facebook-queue-clear",
        "/facebook-queue-reset",
        "/facebook-queue-morning-only",
        "/facebook-post-preflight",
        "/facebook-post-run",
        "/facebook-post-stop",
        "/facebook-post-save-page",
        "/facebook-upload-run",
        "/quit-chrome",
        "/facebook-package-delete",
        "/facebook-package-assign-page",
        "/facebook-package-back-to-old",
        "/remote-run",
    }
    if request_path in protected_paths and not relay_control_password_ok(provided_password):
        return relay_password_error_response()

    if request_path == "/facebook-post-bootstrap":
        chrome_name = str(query.get("chrome_name") or "").strip()
        page_name = str(query.get("page_name") or "").strip()
        profile_directory = str(query.get("profile_directory") or "").strip()
        return HTTPStatus.OK, build_facebook_post_bootstrap_response(chrome_name, page_name, profile_directory)

    if request_path == "/facebook-feed-videos":
        return HTTPStatus.OK, {"ok": True, "videos": load_facebook_feed_videos()}

    if request_path == "/facebook-feed-video":
        file_name = str(query.get("file_name") or payload.get("file_name") or "").strip()
        try:
            video_path = source_video_path_for_name(file_name)
        except ValueError as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
        if not video_path.exists() or not video_path.is_file():
            return HTTPStatus.NOT_FOUND, {"ok": False, "message": "Video not found."}
        mime_type, _encoding = mimetypes.guess_type(video_path.name)
        mime_type = mime_type or "application/octet-stream"
        return HTTPStatus.OK, {
            "ok": True,
            "file_name": video_path.name,
            "mime_type": mime_type,
            "data_base64": base64.b64encode(video_path.read_bytes()).decode("ascii"),
        }

    if request_path == "/facebook-feed-video-delete":
        file_name = str(payload.get("file_name") or query.get("file_name") or "").strip()
        try:
            deleted_any, last_error = delete_facebook_feed_video_mirrors(file_name)
        except ValueError as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
        if not deleted_any:
            status = HTTPStatus.INTERNAL_SERVER_ERROR if last_error else HTTPStatus.NOT_FOUND
            return status, {"ok": False, "message": last_error or "Video not found."}
        return HTTPStatus.OK, {
            "ok": True,
            "message": f"Deleted {Path(file_name).name}.",
            "file_name": Path(file_name).name,
            "videos": load_facebook_feed_videos(),
        }

    if request_path == "/facebook-packages":
        return HTTPStatus.OK, {"ok": True, "packages": load_package_cards()}

    if request_path == "/facebook-package-import":
        file_data_base64 = str(payload.get("file_data_base64") or "").strip()
        source_package_name = str(payload.get("package_name") or "").strip()
        assigned_page_id = str(payload.get("assigned_page_id") or "").strip()
        if not file_data_base64:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": "Package archive is empty."}
        try:
            body = base64.b64decode(file_data_base64, validate=True)
        except Exception:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": "Package archive is invalid."}
        try:
            result = import_package_archive_bytes(
                body,
                source_package_name=source_package_name,
                assigned_page_id=assigned_page_id,
            )
        except ValueError as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
        except Exception as exc:
            return HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "message": str(exc)}
        return HTTPStatus.OK, result

    if request_path == "/facebook-package-file-upload":
        file_data_base64 = str(payload.get("file_data_base64") or "").strip()
        session_id = str(payload.get("session_id") or "").strip()
        source_package_name = str(payload.get("package_name") or "").strip()
        relative_path = str(payload.get("relative_path") or "").strip()
        target_package_name = str(payload.get("target_package_name") or "").strip()
        assigned_page_id = str(payload.get("assigned_page_id") or "").strip()
        if not file_data_base64:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": "Package file is empty."}
        try:
            body = base64.b64decode(file_data_base64, validate=True)
        except Exception:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": "Package file is invalid."}
        try:
            result = stage_imported_package_file(
                body,
                session_id=session_id,
                source_package_name=source_package_name,
                relative_path=relative_path,
                target_package_name=target_package_name,
                assigned_page_id=assigned_page_id,
            )
        except ValueError as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
        except Exception as exc:
            return HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "message": str(exc)}
        return HTTPStatus.OK, result

    if request_path == "/facebook-package-finalize":
        session_id = str(payload.get("session_id") or "").strip()
        source_package_name = str(payload.get("package_name") or "").strip()
        target_package_name = str(payload.get("target_package_name") or "").strip()
        assigned_page_id = str(payload.get("assigned_page_id") or "").strip()
        try:
            result = finalize_staged_package_transfer(
                session_id=session_id,
                target_package_name=target_package_name,
                source_package_name=source_package_name,
                assigned_page_id=assigned_page_id,
            )
        except ValueError as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
        except Exception as exc:
            return HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "message": str(exc)}
        return HTTPStatus.OK, result

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

    if request_path == "/facebook-package-video":
        package_name = str(query.get("package_name") or payload.get("package_name") or "").strip()
        try:
            video_path = video_path_for_package(package_name)
        except ValueError as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
        if video_path is None:
            return HTTPStatus.NOT_FOUND, {"ok": False, "message": "Video not found."}
        mime_type, _encoding = mimetypes.guess_type(video_path.name)
        mime_type = mime_type or "application/octet-stream"
        return HTTPStatus.OK, {
            "ok": True,
            "file_name": video_path.name,
            "mime_type": mime_type,
            "data_base64": base64.b64encode(video_path.read_bytes()).decode("ascii"),
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
        duplicate_path = duplicate_source_video_path_for_bytes(body)
        if duplicate_path is not None:
            return HTTPStatus.OK, handle_duplicate_source_video(duplicate_path)
        target_name = sanitize_source_video_filename(file_name, content_type)
        target_path = unique_source_video_target(target_name)
        try:
            ROOT_DIR.mkdir(parents=True, exist_ok=True)
            target_path.write_bytes(body)
        except Exception as exc:
            return HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "message": str(exc)}
        return HTTPStatus.OK, handle_source_video_saved(target_path)

    if request_path in {"/facebook-queue-clear", "/facebook-queue-reset", "/facebook-queue-morning-only"}:
        chrome_name = str(payload.get("chrome_name") or "").strip()
        requested_profile_directory = str(payload.get("profile_directory") or "").strip()
        page_name = str(payload.get("page_name") or "").strip()
        profile_item = find_profile_item(
            profile_name=chrome_name,
            profile_directory=requested_profile_directory,
        )
        profile_directory = str((profile_item or {}).get("directory") or requested_profile_directory).strip()
        effective_profile_name = str((profile_item or {}).get("name") or chrome_name or requested_profile_directory).strip()
        try:
            if request_path == "/facebook-queue-clear":
                updated_state = facebook_timing.clear_queue(
                    state_path=FACEBOOK_TIMING_STATE_PATH,
                    profile_name=effective_profile_name or None,
                    profile_directory=profile_directory or None,
                    page_name=page_name or None,
                )
                message = "Queue memory cleared."
            elif request_path == "/facebook-queue-reset":
                updated_state = facebook_timing.reset_times(
                    state_path=FACEBOOK_TIMING_STATE_PATH,
                    profile_name=effective_profile_name or None,
                    profile_directory=profile_directory or None,
                    page_name=page_name or None,
                )
                message = "Queue times reset."
            else:
                enabled = bool(payload.get("morning_only"))
                updated_state = facebook_timing.set_morning_only(
                    enabled,
                    state_path=FACEBOOK_TIMING_STATE_PATH,
                    profile_name=effective_profile_name or None,
                    profile_directory=profile_directory or None,
                    page_name=page_name or None,
                )
                message = "Morning only enabled." if enabled else "Morning only disabled."
            queue_info = facebook_timing.queue_status(
                updated_state,
                profile_name=effective_profile_name or None,
                profile_directory=profile_directory or None,
                page_name=page_name or None,
                package_count=len(package_dirs(ROOT_DIR)),
            )
            return HTTPStatus.OK, {"ok": True, "message": message, "facebook_queue": queue_info}
        except Exception as exc:
            return HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "message": str(exc)}

    if request_path == "/facebook-post-preflight":
        try:
            return HTTPStatus.OK, run_facebook_preflight(payload)
        except Exception as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}

    if request_path == "/facebook-post-run":
        ok, message = STATE.start_facebook_post(payload)
        return (HTTPStatus.OK if ok else HTTPStatus.BAD_REQUEST), {"ok": ok, "message": message}

    if request_path == "/facebook-upload-run":
        ok, message = STATE.start_facebook_api_upload(payload)
        return (HTTPStatus.OK if ok else HTTPStatus.BAD_REQUEST), {"ok": ok, "message": message}

    if request_path == "/facebook-post-stop":
        ok, message = STATE.stop_facebook_post()
        return (HTTPStatus.OK if ok else HTTPStatus.BAD_REQUEST), {"ok": ok, "message": message}

    if request_path == "/facebook-post-save-page":
        try:
            record = save_saved_page_record(
                str(payload.get("chrome_name") or ""),
                str(payload.get("page_name") or ""),
                str(payload.get("page_url") or ""),
                str(payload.get("page_kind") or "page"),
                str(payload.get("profile_directory") or ""),
            )
        except Exception as exc:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
        return HTTPStatus.OK, {
            "ok": True,
            "message": f"Saved {record.get('page_kind', 'page')} target on Mac.",
            "record": record,
            "saved_page_records_by_profile": build_saved_page_records_by_profile(),
        }

    if request_path == "/quit-chrome":
        chrome_name = str(payload.get("chrome_name") or "").strip()
        profile_directory = str(payload.get("profile_directory") or "").strip()
        profile_item = find_profile_item(
            profile_name=chrome_name,
            profile_directory=profile_directory,
        )
        effective_profile_directory = str((profile_item or {}).get("directory") or profile_directory).strip()
        if effective_profile_directory:
            closed_count = close_chrome_profile(effective_profile_directory)
            return HTTPStatus.OK, {
                "ok": True,
                "message": f"Closed {closed_count} selected Chrome profile window/process item(s)." if closed_count else "Selected profile is already offline.",
                "closed_count": closed_count,
            }
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
        deleted_any, last_error = delete_package_mirrors(package_name, primary_path=package_path)
        if not deleted_any:
            return HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "message": last_error or "Delete failed."}
        return HTTPStatus.OK, {
            "ok": True,
            "message": f"Deleted {package_name}.",
            "package_name": package_name,
            "packages": load_package_cards(),
        }

    if request_path == "/facebook-package-assign-page":
        package_names = [
            str(item).strip()
            for item in (payload.get("package_names") or [])
            if str(item).strip()
        ]
        page_id = str(payload.get("page_id") or "").strip()
        move_to_queue = bool(payload.get("move_to_queue", True))
        if not package_names:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": "Choose at least one package."}
        if not page_id:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": "Choose a saved upload page first."}
        saved_pages_by_id = {
            str(item.get("page_id") or "").strip(): item
            for item in load_saved_facebook_upload_pages()
            if str(item.get("page_id") or "").strip()
        }
        selected_page = saved_pages_by_id.get(page_id)
        if selected_page is None:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": "Saved upload page not found."}
        for package_name in package_names:
            try:
                package_path = package_path_for_name(package_name)
            except ValueError as exc:
                return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
            if not package_path.exists() or not package_path.is_dir():
                return HTTPStatus.NOT_FOUND, {"ok": False, "message": f"Package not found: {package_name}"}
        assignments = load_facebook_page_assignments()
        queue_orders = load_facebook_page_queue_orders()
        for package_name in package_names:
            assignments[package_name] = page_id
        if move_to_queue:
            queue_orders = append_packages_to_facebook_page_queue_order(queue_orders, package_names, page_id)
        else:
            queue_orders = remove_packages_from_facebook_page_queue_orders(queue_orders, package_names)
        persist_facebook_page_assignments(assignments)
        persist_facebook_page_queue_orders(queue_orders)
        action_verb = "Assigned" if move_to_queue else "Set page"
        return HTTPStatus.OK, {
            "ok": True,
            "message": f"{action_verb} for {len(package_names)} package(s) to {str(selected_page.get('label') or page_id).strip()}.",
            "packages": load_package_cards(),
        }

    if request_path == "/facebook-package-back-to-old":
        package_names = [
            str(item).strip()
            for item in (payload.get("package_names") or [])
            if str(item).strip()
        ]
        if not package_names:
            return HTTPStatus.BAD_REQUEST, {"ok": False, "message": "Choose at least one package."}
        for package_name in package_names:
            try:
                package_path = package_path_for_name(package_name)
            except ValueError as exc:
                return HTTPStatus.BAD_REQUEST, {"ok": False, "message": str(exc)}
            if not package_path.exists() or not package_path.is_dir():
                return HTTPStatus.NOT_FOUND, {"ok": False, "message": f"Package not found: {package_name}"}
        assignments = load_facebook_page_assignments()
        for package_name in package_names:
            assignments.pop(package_name, None)
        queue_orders = remove_packages_from_facebook_page_queue_orders(
            load_facebook_page_queue_orders(),
            package_names,
        )
        persist_facebook_page_assignments(assignments)
        persist_facebook_page_queue_orders(queue_orders)
        return HTTPStatus.OK, {
            "ok": True,
            "message": f"Moved {len(package_names)} package(s) back to old cards.",
            "packages": load_package_cards(),
        }

    if request_path == "/remote-run":
        values: list[str] = []
        raw_ids = payload.get("video_ids")
        if isinstance(raw_ids, list):
            values.extend(str(item) for item in raw_ids)
        raw_input = str(payload.get("raw_input") or "").strip()
        if raw_input:
            values.append(raw_input)
        ok, message = STATE.start_remote(values)
        count = len(build_entries(values))
        status = HTTPStatus.OK if ok else HTTPStatus.BAD_REQUEST
        return status, {"ok": ok, "message": message, "count": count}

    return HTTPStatus.NOT_FOUND, {"ok": False, "message": f"Unsupported relay job path: {request_path}"}


def relay_worker_loop(base_url: str, poll_seconds: float) -> None:
    client_base_url = control_relay_client_base_url()
    if not client_base_url:
        return
    while True:
        try:
            heartbeat = relay_request_json(
                "POST",
                f"{client_base_url}/heartbeat",
                {
                    "snapshot": STATE.snapshot(),
                },
                timeout=10.0,
            )
            if heartbeat.get("pending_jobs"):
                print(
                    f"[relay-worker] heartbeat ok pending_jobs={heartbeat.get('pending_jobs')}",
                    flush=True,
                )
            claimed = relay_request_json("POST", f"{client_base_url}/jobs/claim", {}, timeout=15.0)
            job = claimed.get("job")
            if isinstance(job, dict) and job.get("id"):
                job_id = str(job.get("id"))
                print(
                    f"[relay-worker] claimed job {job_id} path={job.get('request_path')}",
                    flush=True,
                )
                try:
                    response_status, response_body = execute_relay_job(job)
                except Exception as exc:
                    response_status = int(HTTPStatus.INTERNAL_SERVER_ERROR)
                    response_body = {"ok": False, "message": str(exc)}
                    print(
                        f"[relay-worker] execute error job={job_id}: {exc}\n{traceback.format_exc()}",
                        flush=True,
                    )
                relay_request_json(
                    "POST",
                    f"{client_base_url}/jobs/{job_id}/finish",
                    {
                        "response_status": int(response_status),
                        "response_body": response_body,
                    },
                    timeout=30.0,
                )
                print(f"[relay-worker] finished job {job_id} status={response_status}", flush=True)
                continue
        except Exception as exc:
            print(f"[relay-worker] loop error: {exc}\n{traceback.format_exc()}", flush=True)
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
        return "Content-Type, X-Soranin-File-Name, X-Soranin-Password, X-Soranin-Session"

    def _request_control_password(self) -> str:
        header_value = str(self.headers.get("X-Soranin-Password") or "").strip()
        if header_value:
            return header_value
        try:
            parsed = urlparse(self.path)
            return str((parse_qs(parsed.query).get("__control_password") or [""])[0]).strip()
        except Exception:
            return ""

    def _request_control_session_token(self) -> str:
        header_value = str(self.headers.get("X-Soranin-Session") or "").strip()
        if header_value:
            return header_value
        try:
            parsed = urlparse(self.path)
            return str((parse_qs(parsed.query).get("__control_session") or [""])[0]).strip()
        except Exception:
            return ""

    def _request_client_ip(self) -> str:
        for header_name in ("CF-Connecting-IP", "X-Forwarded-For"):
            header_value = str(self.headers.get(header_name) or "").strip()
            if not header_value:
                continue
            return header_value.split(",", 1)[0].strip()
        return str(self.client_address[0] or "").strip()

    def _request_user_agent(self) -> str:
        return str(self.headers.get("User-Agent") or "").strip()

    def _control_session_payload(self) -> dict[str, object] | None:
        if self._is_loopback_request():
            return {"loopback": True}
        return CONTROL_WEB_SESSIONS.get(
            self._request_control_session_token(),
            client_ip=self._request_client_ip(),
            user_agent=self._request_user_agent(),
        )

    def _has_valid_control_auth(self) -> bool:
        expected = control_password()
        if not expected:
            return True
        if self._is_loopback_request():
            return True
        if self._control_session_payload() is not None:
            return True
        provided = self._request_control_password()
        return bool(provided) and hmac.compare_digest(provided, expected)

    def _auth_attempt_key(self) -> str:
        return f"{self._request_client_ip()}|{self._request_user_agent()}"

    def _auth_lockout_response(self, retry_after_seconds: int) -> None:
        retry_after = max(1, int(retry_after_seconds or 0))
        self._send_json(
            {
                "ok": False,
                "message": f"Too many failed login attempts. Try again in {retry_after}s.",
                "password_required": True,
                "retry_after_seconds": retry_after,
            },
            HTTPStatus.TOO_MANY_REQUESTS,
        )

    def _issue_control_session(self, remember: bool) -> tuple[str, float]:
        return CONTROL_WEB_SESSIONS.create(
            client_ip=self._request_client_ip(),
            user_agent=self._request_user_agent(),
            ttl_seconds=CONTROL_SESSION_REMEMBER_TTL_SECONDS if remember else CONTROL_SESSION_TTL_SECONDS,
            data={"remember": bool(remember)},
        )

    def _is_loopback_request(self) -> bool:
        client_host = str(self.client_address[0] or "").strip()
        return client_host in {"127.0.0.1", "::1", "::ffff:127.0.0.1"}

    def _require_control_password(self) -> bool:
        expected = control_password()
        if not expected:
            return True
        if self._is_loopback_request():
            return True
        if self._control_session_payload() is not None:
            return True
        attempt_key = self._auth_attempt_key()
        retry_after = CONTROL_AUTH_ATTEMPTS.remaining_lockout(attempt_key)
        if retry_after > 0:
            self._auth_lockout_response(retry_after)
            return False
        provided = self._request_control_password()
        if provided and hmac.compare_digest(provided, expected):
            CONTROL_AUTH_ATTEMPTS.record_success(attempt_key)
            return True
        if provided:
            retry_after = CONTROL_AUTH_ATTEMPTS.record_failure(attempt_key)
            if retry_after > 0:
                self._auth_lockout_response(retry_after)
                return False
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

    def _send_security_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob: data:; "
            "connect-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
            "base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
        )

    def _send_json(self, payload: dict[str, object], status: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html: str) -> None:
        body = html.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, file_path: Path) -> None:
        if not file_path.exists() or not file_path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        content_type, _ = mimetypes.guess_type(file_path.name)
        total_size = file_path.stat().st_size
        range_header = str(self.headers.get("Range") or "").strip()
        start = 0
        end = max(total_size - 1, 0)
        status = HTTPStatus.OK

        if range_header.startswith("bytes="):
            try:
                byte_range = range_header.split("=", 1)[1].split(",", 1)[0].strip()
                start_text, end_text = byte_range.split("-", 1)
                if not start_text:
                    suffix_length = int(end_text)
                    if suffix_length <= 0:
                        raise ValueError("Invalid suffix length.")
                    start = max(total_size - suffix_length, 0)
                else:
                    start = int(start_text)
                if end_text:
                    end = int(end_text)
                if start < 0 or start >= total_size or end < start:
                    raise ValueError("Invalid byte range.")
                end = min(end, total_size - 1)
                status = HTTPStatus.PARTIAL_CONTENT
            except Exception:
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{total_size}")
                self.send_header("Content-Length", "0")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Accept-Ranges", "bytes")
                self._send_security_headers()
                self.end_headers()
                return

        content_length = max(end - start + 1, 0)
        self.send_response(status)
        self.send_header("Content-Type", content_type or "application/octet-stream")
        self.send_header("Content-Length", str(content_length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Accept-Ranges", "bytes")
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total_size}")
        self._send_security_headers()
        self.end_headers()
        with file_path.open("rb") as handle:
            if start:
                handle.seek(start)
            remaining = content_length
            while remaining > 0:
                chunk = handle.read(min(1024 * 64, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def _send_raw(self, body: bytes, content_type: str, status: int = HTTPStatus.OK) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Content-Length", "0")
        self._send_security_headers()
        self.end_headers()

    def _handle_auth_login(self) -> None:
        payload = self._read_json_body()
        remember = bool(payload.get("remember"))
        provided = str(payload.get("password") or "").strip()
        expected = control_password()
        attempt_key = self._auth_attempt_key()
        retry_after = CONTROL_AUTH_ATTEMPTS.remaining_lockout(attempt_key)
        if retry_after > 0:
            self._auth_lockout_response(retry_after)
            return
        if expected and not self._is_loopback_request():
            if not provided or not hmac.compare_digest(provided, expected):
                retry_after = CONTROL_AUTH_ATTEMPTS.record_failure(attempt_key)
                if retry_after > 0:
                    self._auth_lockout_response(retry_after)
                    return
                self._send_json(
                    {
                        "ok": False,
                        "message": "Enter the Mac control password to continue.",
                        "password_required": True,
                    },
                    HTTPStatus.UNAUTHORIZED,
                )
                return
        CONTROL_AUTH_ATTEMPTS.record_success(attempt_key)
        session_token, expires_at = self._issue_control_session(remember)
        self._send_json(
            {
                "ok": True,
                "message": "Login OK.",
                "session_token": session_token,
                "expires_at": datetime.fromtimestamp(expires_at, tz=timezone.utc).isoformat(),
                "password_required": bool(expected),
            },
            HTTPStatus.OK,
        )

    def _handle_auth_logout(self) -> None:
        CONTROL_WEB_SESSIONS.delete(self._request_control_session_token())
        self._send_json({"ok": True, "message": "Logged out."}, HTTPStatus.OK)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in {"/control", "/control/", "/control/index.html"}:
            self._send_html(load_control_web_html())
            return
        if parsed.path in {"/", "/index.html"}:
            self._send_html(HTML_PAGE)
            return
        if parsed.path == "/status":
            snapshot = STATE.snapshot()
            if control_password_required() and not self._has_valid_control_auth():
                self._send_json(public_control_status_payload(snapshot), HTTPStatus.OK)
            else:
                self._send_json(snapshot)
            return
        if parsed.path == "/codex-chat-health":
            if not self._require_control_password():
                return
            self._send_json(build_codex_chat_health_response(), HTTPStatus.OK)
            return
        if parsed.path == "/facebook-feed-videos":
            if not self._require_control_password():
                return
            self._send_json({"ok": True, "videos": load_facebook_feed_videos()}, HTTPStatus.OK)
            return
        if parsed.path == "/facebook-feed-video":
            if not self._require_control_password():
                return
            file_name = (parse_qs(parsed.query).get("file_name") or [""])[0]
            try:
                video_path = source_video_path_for_name(file_name)
            except ValueError:
                self._send_json({"ok": False, "message": "Invalid file name."}, HTTPStatus.BAD_REQUEST)
                return
            if not video_path.exists() or not video_path.is_file():
                self._send_json({"ok": False, "message": "Video not found."}, HTTPStatus.NOT_FOUND)
                return
            self._send_file(video_path)
            return
        if parsed.path == "/facebook-post-bootstrap":
            if not self._require_control_password():
                return
            query = parse_qs(parsed.query)
            chrome_name = (query.get("chrome_name") or [""])[0]
            page_name = (query.get("page_name") or [""])[0]
            profile_directory = (query.get("profile_directory") or [""])[0]
            self._send_json(build_facebook_post_bootstrap_response(chrome_name, page_name, profile_directory))
            return
        if parsed.path == "/facebook-packages":
            if not self._require_control_password():
                return
            self._send_json({"ok": True, "packages": load_package_cards()}, HTTPStatus.OK)
            return
        if parsed.path == "/facebook-package-import":
            if not self._require_control_password():
                return
            body = self._read_raw_body()
            if not body:
                self._send_json({"ok": False, "message": "Package archive is empty."}, HTTPStatus.BAD_REQUEST)
                return
            query = parse_qs(parsed.query)
            source_package_name = (query.get("package_name") or [""])[0]
            assigned_page_id = (query.get("assigned_page_id") or [""])[0]
            if not source_package_name:
                source_package_name = str(self.headers.get("X-Soranin-Package-Name") or "").strip()
            if not assigned_page_id:
                assigned_page_id = str(self.headers.get("X-Soranin-Assigned-Page-ID") or "").strip()
            try:
                result = import_package_archive_bytes(
                    body,
                    source_package_name=source_package_name,
                    assigned_page_id=assigned_page_id,
                )
            except ValueError as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return
            self._send_json(result, HTTPStatus.OK)
            return
        if parsed.path == "/facebook-package-file-upload":
            if not self._require_control_password():
                return
            body = self._read_raw_body()
            if not body:
                self._send_json({"ok": False, "message": "Package file is empty."}, HTTPStatus.BAD_REQUEST)
                return
            query = parse_qs(parsed.query)
            session_id = (query.get("session_id") or [""])[0]
            source_package_name = (query.get("package_name") or [""])[0]
            relative_path = (query.get("relative_path") or [""])[0]
            target_package_name = (query.get("target_package_name") or [""])[0]
            assigned_page_id = (query.get("assigned_page_id") or [""])[0]
            try:
                result = stage_imported_package_file(
                    body,
                    session_id=session_id,
                    source_package_name=source_package_name,
                    relative_path=relative_path,
                    target_package_name=target_package_name,
                    assigned_page_id=assigned_page_id,
                )
            except ValueError as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return
            self._send_json(result, HTTPStatus.OK)
            return
        if parsed.path == "/facebook-package-finalize":
            if not self._require_control_password():
                return
            query = parse_qs(parsed.query)
            session_id = (query.get("session_id") or [""])[0]
            source_package_name = (query.get("package_name") or [""])[0]
            target_package_name = (query.get("target_package_name") or [""])[0]
            assigned_page_id = (query.get("assigned_page_id") or [""])[0]
            try:
                result = finalize_staged_package_transfer(
                    session_id=session_id,
                    target_package_name=target_package_name,
                    source_package_name=source_package_name,
                    assigned_page_id=assigned_page_id,
                )
            except ValueError as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return
            self._send_json(result, HTTPStatus.OK)
            return
        if parsed.path == "/facebook-package-video":
            if not self._require_control_password():
                return
            package_name = (parse_qs(parsed.query).get("package_name") or [""])[0]
            try:
                video_path = video_path_for_package(package_name)
            except ValueError:
                self._send_json({"ok": False, "message": "Invalid package name."}, HTTPStatus.BAD_REQUEST)
                return
            if video_path is None:
                self._send_json({"ok": False, "message": "Video not found."}, HTTPStatus.NOT_FOUND)
                return
            self._send_file(video_path)
            return
        if parsed.path == "/facebook-package-thumbnail":
            if not self._require_control_password():
                return
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

        if request_path == "/auth/login":
            self._handle_auth_login()
            return

        if request_path == "/auth/logout":
            self._handle_auth_logout()
            return

        if request_path == "/facebook-package-file-upload":
            if not self._require_control_password():
                return
            body = self._read_raw_body()
            if not body:
                self._send_json({"ok": False, "message": "Package file is empty."}, HTTPStatus.BAD_REQUEST)
                return

            query = parse_qs(parsed.query)
            session_id = (query.get("session_id") or [""])[0]
            source_package_name = (query.get("package_name") or [""])[0]
            relative_path = (query.get("relative_path") or [""])[0]
            target_package_name = (query.get("target_package_name") or [""])[0]
            assigned_page_id = (query.get("assigned_page_id") or [""])[0]
            try:
                result = stage_imported_package_file(
                    body,
                    session_id=session_id,
                    source_package_name=source_package_name,
                    relative_path=relative_path,
                    target_package_name=target_package_name,
                    assigned_page_id=assigned_page_id,
                )
            except ValueError as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return
            self._send_json(result, HTTPStatus.OK)
            return

        if request_path == "/facebook-package-finalize":
            if not self._require_control_password():
                return
            query = parse_qs(parsed.query)
            session_id = (query.get("session_id") or [""])[0]
            source_package_name = (query.get("package_name") or [""])[0]
            target_package_name = (query.get("target_package_name") or [""])[0]
            assigned_page_id = (query.get("assigned_page_id") or [""])[0]
            try:
                result = finalize_staged_package_transfer(
                    session_id=session_id,
                    target_package_name=target_package_name,
                    source_package_name=source_package_name,
                    assigned_page_id=assigned_page_id,
                )
            except ValueError as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return
            self._send_json(result, HTTPStatus.OK)
            return

        if request_path == "/facebook-package-import":
            if not self._require_control_password():
                return
            body = self._read_raw_body()
            if not body:
                self._send_json({"ok": False, "message": "Package archive is empty."}, HTTPStatus.BAD_REQUEST)
                return

            query = parse_qs(parsed.query)
            source_package_name = (query.get("package_name") or [""])[0]
            assigned_page_id = (query.get("assigned_page_id") or [""])[0]
            if not source_package_name:
                source_package_name = str(self.headers.get("X-Soranin-Package-Name") or "").strip()
            if not assigned_page_id:
                assigned_page_id = str(self.headers.get("X-Soranin-Assigned-Page-ID") or "").strip()
            try:
                result = import_package_archive_bytes(
                    body,
                    source_package_name=source_package_name,
                    assigned_page_id=assigned_page_id,
                )
            except ValueError as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
                return
            self._send_json(result, HTTPStatus.OK)
            return

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
            self._send_json(handle_source_video_saved(target_path), HTTPStatus.OK)
            return

        if request_path == "/codex-chat-proxy":
            if not self._require_control_password():
                return
            response_status, response_body, content_type = proxy_codex_chat_request(self._read_raw_body())
            self._send_raw(response_body, content_type, response_status)
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
                values.append(raw_input)

            parsed_entries = build_entries(values)
            ok, message = STATE.start_remote(values)
            if ok:
                self._send_json(
                    {
                        "ok": True,
                        "message": message,
                        "count": len(parsed_entries),
                    },
                    HTTPStatus.OK,
                )
            else:
                status = HTTPStatus.CONFLICT if "running" in message.lower() else HTTPStatus.BAD_REQUEST
                self._send_json(
                    {
                        "ok": False,
                        "message": message,
                        "count": len(parsed_entries),
                    },
                    status,
                )
            return
        if request_path in {"/facebook-queue-clear", "/facebook-queue-reset", "/facebook-queue-morning-only"}:
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            chrome_name = str(payload.get("chrome_name") or "").strip()
            requested_profile_directory = str(payload.get("profile_directory") or "").strip()
            page_name = str(payload.get("page_name") or "").strip()
            profile_item = find_profile_item(
                profile_name=chrome_name,
                profile_directory=requested_profile_directory,
            )
            profile_directory = str((profile_item or {}).get("directory") or requested_profile_directory).strip()
            effective_profile_name = str((profile_item or {}).get("name") or chrome_name or requested_profile_directory).strip()
            try:
                if request_path == "/facebook-queue-clear":
                    updated_state = facebook_timing.clear_queue(
                        state_path=FACEBOOK_TIMING_STATE_PATH,
                        profile_name=effective_profile_name or None,
                        profile_directory=profile_directory or None,
                        page_name=page_name or None,
                    )
                    message = "Queue memory cleared."
                elif request_path == "/facebook-queue-reset":
                    updated_state = facebook_timing.reset_times(
                        state_path=FACEBOOK_TIMING_STATE_PATH,
                        profile_name=effective_profile_name or None,
                        profile_directory=profile_directory or None,
                        page_name=page_name or None,
                    )
                    message = "Queue times reset."
                else:
                    enabled = bool(payload.get("morning_only"))
                    updated_state = facebook_timing.set_morning_only(
                        enabled,
                        state_path=FACEBOOK_TIMING_STATE_PATH,
                        profile_name=effective_profile_name or None,
                        profile_directory=profile_directory or None,
                        page_name=page_name or None,
                    )
                    message = "Morning only enabled." if enabled else "Morning only disabled."
                queue_info = facebook_timing.queue_status(
                    updated_state,
                    profile_name=effective_profile_name or None,
                    profile_directory=profile_directory or None,
                    page_name=page_name or None,
                    package_count=len(package_dirs(ROOT_DIR)),
                )
                self._send_json({"ok": True, "message": message, "facebook_queue": queue_info}, HTTPStatus.OK)
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
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
        if request_path == "/facebook-upload-run":
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            ok, message = STATE.start_facebook_api_upload(payload)
            status = HTTPStatus.OK if ok else HTTPStatus.BAD_REQUEST
            self._send_json(
                {
                    "ok": ok,
                    "message": message,
                },
                status,
            )
            return
        if request_path == "/facebook-post-stop":
            if not self._require_control_password():
                return
            ok, message = STATE.stop_facebook_post()
            status = HTTPStatus.OK if ok else HTTPStatus.BAD_REQUEST
            self._send_json(
                {
                    "ok": ok,
                    "message": message,
                },
                status,
            )
            return
        if request_path == "/facebook-post-save-page":
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            try:
                record = save_saved_page_record(
                    str(payload.get("chrome_name") or ""),
                    str(payload.get("page_name") or ""),
                    str(payload.get("page_url") or ""),
                    str(payload.get("page_kind") or "page"),
                    str(payload.get("profile_directory") or ""),
                )
            except Exception as exc:
                self._send_json(
                    {
                        "ok": False,
                        "message": str(exc),
                    },
                    HTTPStatus.BAD_REQUEST,
                )
                return

            self._send_json(
                {
                    "ok": True,
                    "message": f"Saved {record.get('page_kind', 'page')} target on Mac.",
                    "record": record,
                    "saved_page_records_by_profile": build_saved_page_records_by_profile(),
                },
                HTTPStatus.OK,
            )
            return
        if request_path == "/quit-chrome":
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            chrome_name = str(payload.get("chrome_name") or "").strip()
            profile_directory = str(payload.get("profile_directory") or "").strip()
            profile_item = find_profile_item(
                profile_name=chrome_name,
                profile_directory=profile_directory,
            )
            effective_profile_directory = str((profile_item or {}).get("directory") or profile_directory).strip()
            if effective_profile_directory:
                closed_count = close_chrome_profile(effective_profile_directory)
                self._send_json(
                    {
                        "ok": True,
                        "message": f"Closed {closed_count} selected Chrome profile window/process item(s)." if closed_count else "Selected profile is already offline.",
                        "closed_count": closed_count,
                    },
                    HTTPStatus.OK,
                )
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
            deleted_any, last_error = delete_package_mirrors(package_name, primary_path=package_path)
            if not deleted_any:
                self._send_json({"ok": False, "message": last_error or "Delete failed."}, HTTPStatus.INTERNAL_SERVER_ERROR)
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
        if request_path == "/facebook-feed-video-delete":
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            file_name = str(payload.get("file_name") or "").strip()
            try:
                deleted_any, last_error = delete_facebook_feed_video_mirrors(file_name)
            except ValueError as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            if not deleted_any:
                status = HTTPStatus.INTERNAL_SERVER_ERROR if last_error else HTTPStatus.NOT_FOUND
                self._send_json({"ok": False, "message": last_error or "Video not found."}, status)
                return
            self._send_json(
                {
                    "ok": True,
                    "message": f"Deleted {Path(file_name).name}.",
                    "file_name": Path(file_name).name,
                    "videos": load_facebook_feed_videos(),
                },
                HTTPStatus.OK,
            )
            return
        if request_path == "/facebook-package-assign-page":
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            package_names = [
                str(item).strip()
                for item in (payload.get("package_names") or [])
                if str(item).strip()
            ]
            page_id = str(payload.get("page_id") or "").strip()
            move_to_queue = bool(payload.get("move_to_queue", True))
            if not package_names:
                self._send_json({"ok": False, "message": "Choose at least one package."}, HTTPStatus.BAD_REQUEST)
                return
            if not page_id:
                self._send_json({"ok": False, "message": "Choose a saved upload page first."}, HTTPStatus.BAD_REQUEST)
                return
            saved_pages_by_id = {
                str(item.get("page_id") or "").strip(): item
                for item in load_saved_facebook_upload_pages()
                if str(item.get("page_id") or "").strip()
            }
            selected_page = saved_pages_by_id.get(page_id)
            if selected_page is None:
                self._send_json({"ok": False, "message": "Saved upload page not found."}, HTTPStatus.BAD_REQUEST)
                return
            for package_name in package_names:
                try:
                    package_path = package_path_for_name(package_name)
                except ValueError as exc:
                    self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                    return
                if not package_path.exists() or not package_path.is_dir():
                    self._send_json({"ok": False, "message": f"Package not found: {package_name}"}, HTTPStatus.NOT_FOUND)
                    return
            assignments = load_facebook_page_assignments()
            queue_orders = load_facebook_page_queue_orders()
            for package_name in package_names:
                assignments[package_name] = page_id
            if move_to_queue:
                queue_orders = append_packages_to_facebook_page_queue_order(queue_orders, package_names, page_id)
            else:
                queue_orders = remove_packages_from_facebook_page_queue_orders(queue_orders, package_names)
            persist_facebook_page_assignments(assignments)
            persist_facebook_page_queue_orders(queue_orders)
            action_verb = "Assigned" if move_to_queue else "Set page"
            self._send_json(
                {
                    "ok": True,
                    "message": f"{action_verb} for {len(package_names)} package(s) to {str(selected_page.get('label') or page_id).strip()}.",
                    "packages": load_package_cards(),
                },
                HTTPStatus.OK,
            )
            return
        if request_path == "/facebook-package-back-to-old":
            if not self._require_control_password():
                return
            payload = self._read_json_body()
            package_names = [
                str(item).strip()
                for item in (payload.get("package_names") or [])
                if str(item).strip()
            ]
            if not package_names:
                self._send_json({"ok": False, "message": "Choose at least one package."}, HTTPStatus.BAD_REQUEST)
                return
            for package_name in package_names:
                try:
                    package_path = package_path_for_name(package_name)
                except ValueError as exc:
                    self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                    return
                if not package_path.exists() or not package_path.is_dir():
                    self._send_json({"ok": False, "message": f"Package not found: {package_name}"}, HTTPStatus.NOT_FOUND)
                    return
            assignments = load_facebook_page_assignments()
            for package_name in package_names:
                assignments.pop(package_name, None)
            queue_orders = remove_packages_from_facebook_page_queue_orders(
                load_facebook_page_queue_orders(),
                package_names,
            )
            persist_facebook_page_assignments(assignments)
            persist_facebook_page_queue_orders(queue_orders)
            self._send_json(
                {
                    "ok": True,
                    "message": f"Moved {len(package_names)} package(s) back to old cards.",
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
    threading.Thread(
        target=refresh_tailscale_control_server_urls,
        daemon=True,
    ).start()
    threading.Thread(
        target=facebook_page_metrics_worker_loop,
        daemon=True,
    ).start()
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
