#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import json
import os
import platform
import secrets
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import fb_reels_publish_timing as facebook_timing
from soranin_paths import runtime_data_file


HOST = "0.0.0.0"
PORT = 8788
CLIENT_STALE_SECONDS = 20.0
JOB_TIMEOUT_SECONDS = 180.0
SHARED_QUEUE_LOCK_TIMEOUT_SECONDS = 8.0
CONTROL_AUTH_WINDOW_SECONDS = 600.0
CONTROL_AUTH_LOCKOUT_SECONDS = 900.0
CONTROL_AUTH_MAX_FAILURES = 8
CONTROL_SESSION_TTL_SECONDS = 12 * 60 * 60.0
CONTROL_SESSION_REMEMBER_TTL_SECONDS = 30 * 24 * 60 * 60.0


def _relay_store_path() -> Path:
    if str(os.environ.get("SORANIN_MAC_CONTROL_RELAY_STORE") or "").strip():
        return runtime_data_file("mac_control_relay_store.json", env_name="SORANIN_MAC_CONTROL_RELAY_STORE")
    if platform.system() == "Darwin":
        return runtime_data_file("mac_control_relay_store.json", env_name="SORANIN_MAC_CONTROL_RELAY_STORE")
    runtime_root = Path(
        str(
            os.environ.get("XDG_RUNTIME_DIR")
            or os.environ.get("TMPDIR")
            or "/tmp"
        )
    )
    relay_dir = runtime_root / "soranin-relay"
    relay_dir.mkdir(parents=True, exist_ok=True)
    return relay_dir / "mac_control_relay_store.json"


STORE_PATH = _relay_store_path()
SHARED_QUEUE_DIR = STORE_PATH.parent / "facebook_shared_queues"
SHARED_QUEUE_LOCKS: dict[str, threading.Lock] = {}
SHARED_QUEUE_LOCKS_GUARD = threading.Lock()
CONTROL_WEB_HTML_PATH = Path(__file__).resolve().with_name("soranin_web_control.html")


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


RELAY_AUTH_ATTEMPTS = AuthAttemptTracker(
    window_seconds=CONTROL_AUTH_WINDOW_SECONDS,
    lockout_seconds=CONTROL_AUTH_LOCKOUT_SECONDS,
    max_failures=CONTROL_AUTH_MAX_FAILURES,
)
RELAY_WEB_SESSIONS = WebSessionStore()


@contextmanager
def _shared_queue_guard(page_id: str, queue_secret: str = ""):
    state_path = _shared_queue_state_path(page_id, queue_secret)
    lock_key = str(state_path)
    with SHARED_QUEUE_LOCKS_GUARD:
        queue_lock = SHARED_QUEUE_LOCKS.get(lock_key)
        if queue_lock is None:
            queue_lock = threading.Lock()
            SHARED_QUEUE_LOCKS[lock_key] = queue_lock
    acquired = queue_lock.acquire(timeout=SHARED_QUEUE_LOCK_TIMEOUT_SECONDS)
    if not acquired:
        raise RuntimeError("Shared queue is busy. Try again.")
    try:
        yield
    finally:
        queue_lock.release()


class RelayStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lock = threading.Lock()
        self.data = self._load()

    def _load(self) -> dict:
        if not self.path.exists():
            return {"clients": {}}
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except Exception:
            payload = {}
        if not isinstance(payload, dict):
            payload = {}
        payload.setdefault("clients", {})
        return payload

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.data, indent=2), encoding="utf-8")

    def _client(self, token: str) -> dict:
        clients = self.data.setdefault("clients", {})
        client = clients.setdefault(token, {})
        client.setdefault("jobs", [])
        client.setdefault("events", [])
        client.setdefault("last_snapshot_alert_id", 0)
        return client

    def _normalize_alert(self, raw: object) -> dict | None:
        if not isinstance(raw, dict):
            return None
        try:
            alert_id = int(raw.get("id") or 0)
        except Exception:
            alert_id = 0
        if alert_id <= 0:
            return None
        try:
            created_at = float(raw.get("created_at") or time.time())
        except Exception:
            created_at = time.time()
        return {
            "id": alert_id,
            "title": str(raw.get("title") or "").strip(),
            "message": str(raw.get("message") or "").strip(),
            "level": str(raw.get("level") or "info").strip().lower() or "info",
            "created_at": created_at,
        }

    def _extract_new_alert_events(self, snapshot: dict, last_alert_id: int) -> list[dict]:
        candidates: list[dict] = []
        raw_alerts = snapshot.get("alerts")
        if isinstance(raw_alerts, list):
            for raw in raw_alerts:
                alert = self._normalize_alert(raw)
                if alert is not None and int(alert.get("id") or 0) > last_alert_id:
                    candidates.append(alert)
        latest_alert = self._normalize_alert(snapshot.get("latest_alert"))
        if latest_alert is not None and int(latest_alert.get("id") or 0) > last_alert_id:
            candidates.append(latest_alert)

        deduped: dict[int, dict] = {}
        for alert in candidates:
            deduped[int(alert["id"])] = alert
        return [deduped[key] for key in sorted(deduped)]

    def update_heartbeat(self, token: str, snapshot: dict) -> dict:
        with self.lock:
            client = self._client(token)
            last_alert_id = int(client.get("last_snapshot_alert_id") or 0)
            new_alerts = self._extract_new_alert_events(snapshot, last_alert_id)
            if new_alerts:
                events = list(client.get("events") or [])
                for alert in new_alerts:
                    events.append({
                        "id": int(alert["id"]),
                        "type": "mac_alert",
                        "alert": alert,
                        "created_at": float(alert.get("created_at") or time.time()),
                    })
                client["events"] = events[-128:]
                client["last_snapshot_alert_id"] = max(int(alert["id"]) for alert in new_alerts)
            client["last_seen_at"] = time.time()
            client["snapshot"] = snapshot
            self._save()
            return dict(client)

    def client_status(self, token: str) -> dict:
        with self.lock:
            client = self._client(token)
            return {
                "last_seen_at": client.get("last_seen_at"),
                "snapshot": dict(client.get("snapshot") or {}),
                "jobs": list(client.get("jobs") or []),
                "events": list(client.get("events") or []),
            }

    def next_event_after(self, token: str, after_id: int) -> dict | None:
        with self.lock:
            client = self._client(token)
            for event in client.get("events") or []:
                try:
                    event_id = int(event.get("id") or 0)
                except Exception:
                    event_id = 0
                if event_id > after_id:
                    return dict(event)
            return None

    def list_clients(self) -> list[dict]:
        with self.lock:
            clients = self.data.setdefault("clients", {})
            rows: list[dict] = []
            for token, client in clients.items():
                snapshot = client.get("snapshot")
                jobs = client.get("jobs")
                events = client.get("events")
                rows.append(
                    {
                        "token": str(token or "").strip(),
                        "last_seen_at": client.get("last_seen_at"),
                        "snapshot": dict(snapshot) if isinstance(snapshot, dict) else {},
                        "jobs": list(jobs) if isinstance(jobs, list) else [],
                        "events": list(events) if isinstance(events, list) else [],
                    }
                )
            return rows

    def enqueue_job(self, token: str, request_path: str, payload: dict | None = None, query: dict | None = None) -> str:
        with self.lock:
            client = self._client(token)
            job_id = uuid.uuid4().hex
            job = {
                "id": job_id,
                "request_path": request_path,
                "payload": payload or {},
                "query": query or {},
                "status": "queued",
                "created_at": time.time(),
                "claimed_at": None,
                "completed_at": None,
                "response_status": None,
                "response_body": None,
            }
            client["jobs"].append(job)
            self._save()
            return job_id

    def claim_next_job(self, token: str) -> dict | None:
        with self.lock:
            client = self._client(token)
            jobs = client.get("jobs") or []
            now = time.time()
            for job in jobs:
                if job.get("status") == "queued":
                    job["status"] = "claimed"
                    job["claimed_at"] = now
                    self._save()
                    return dict(job)
            return None

    def finish_job(self, token: str, job_id: str, response_status: int, response_body: dict) -> bool:
        with self.lock:
            client = self._client(token)
            for job in client.get("jobs") or []:
                if str(job.get("id")) != job_id:
                    continue
                job["status"] = "done"
                job["completed_at"] = time.time()
                job["response_status"] = int(response_status)
                job["response_body"] = response_body
                self._save()
                return True
            return False

    def get_job(self, token: str, job_id: str) -> dict | None:
        with self.lock:
            client = self._client(token)
            for job in client.get("jobs") or []:
                if str(job.get("id")) == job_id:
                    return dict(job)
            return None

    def purge_job(self, token: str, job_id: str) -> None:
        with self.lock:
            client = self._client(token)
            jobs = client.get("jobs") or []
            kept = [job for job in jobs if str(job.get("id")) != job_id]
            if len(kept) != len(jobs):
                client["jobs"] = kept
                self._save()


STORE = RelayStore(STORE_PATH)


def _shared_queue_page_id(page_id: object) -> str:
    value = str(page_id or "").strip()
    if not value:
        raise ValueError("Page ID is required.")
    return value


def _shared_queue_state_path(page_id: str, queue_secret: str = "") -> Path:
    digest = hashlib.sha256(f"{page_id}::{queue_secret}".encode("utf-8")).hexdigest()
    SHARED_QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    return SHARED_QUEUE_DIR / f"facebook_page_{digest[:32]}.json"


def _shared_queue_identity(page_id: str) -> dict[str, str]:
    normalized = _shared_queue_page_id(page_id)
    return {
        "profile_key": f"facebook_api::{normalized}",
        "profile_name": "Facebook API",
        "page_name": normalized,
    }


def _shared_queue_owner_key(package_name: str, reservation_key: str = "") -> str:
    explicit = str(reservation_key or "").strip()
    if explicit:
        return explicit
    fallback = str(package_name or "").strip()
    if fallback:
        return f"package::{fallback}"
    raise RuntimeError("Shared queue reservation key is required.")


def _shared_queue_pending_map(profile_state: dict, *, now=None) -> dict[str, dict[str, str]]:
    return facebook_timing._normalize_pending_reservations(profile_state, now=now)


def _is_allowed_fixed_slot(candidate: object, morning_only: bool) -> bool:
    if not hasattr(candidate, "tzinfo"):
        return False
    local = facebook_timing.current_minute(facebook_timing.to_khmer(candidate))
    slot = (local.hour, local.minute)
    allowed = (
        facebook_timing.MORNING_ONLY_SLOT_TIMES
        if morning_only
        else facebook_timing.ALLOWED_SLOT_TIMES_SORTED
    )
    return slot in allowed


def _shared_queue_status(page_id: str, *, queue_secret: str = "", package_count: int = 0) -> dict[str, object]:
    state_path = _shared_queue_state_path(page_id, queue_secret)
    identity = _shared_queue_identity(page_id)
    state = facebook_timing.load_state(state_path)
    return facebook_timing.queue_status(
        state,
        package_count=max(0, int(package_count)),
        **identity,
    )


def _shared_queue_reserve(
    page_id: str,
    *,
    queue_secret: str = "",
    package_name: str,
    reservation_key: str = "",
    requested_schedule_at: str = "",
    allow_near_slot: bool = False,
) -> dict[str, object]:
    with _shared_queue_guard(page_id, queue_secret):
        state_path = _shared_queue_state_path(page_id, queue_secret)
        identity = _shared_queue_identity(page_id)
        now = facebook_timing.now_khmer()
        state = facebook_timing.load_state(state_path)
        profile_state = facebook_timing.ensure_profile_state(state, **identity)
        owner_key = _shared_queue_owner_key(package_name, reservation_key)
        pending = _shared_queue_pending_map(profile_state, now=now)
        existing_pending = pending.get(owner_key)
        existing_anchor = None
        if isinstance(existing_pending, dict):
            existing_anchor = facebook_timing.deserialize_dt(str(existing_pending.get("anchor_at") or "").strip())
        if existing_anchor is not None:
            facebook_timing.release_anchor(
                anchor_at=existing_anchor,
                state_path=state_path,
                **identity,
            )
            state = facebook_timing.load_state(state_path)
            profile_state = facebook_timing.ensure_profile_state(state, **identity)
            pending = _shared_queue_pending_map(profile_state, now=now)
            pending.pop(owner_key, None)
            facebook_timing.save_state(state, state_path)
        morning_only = bool(profile_state.get("morning_only"))
        reserved_slots = facebook_timing._all_reserved_slots(state, now=now)
        reserved_keys = {facebook_timing.serialize_dt(slot) for slot in reserved_slots}
        if allow_near_slot:
            earliest = facebook_timing.current_minute(now)
        else:
            earliest = facebook_timing.current_minute(
                now + timedelta(minutes=max(10, facebook_timing.MIN_SCHEDULE_LEAD_MINUTES))
            )

        summary = ""
        decision: facebook_timing.PublishDecision | None = None
        requested_dt = facebook_timing.deserialize_dt(requested_schedule_at) if requested_schedule_at else None
        if requested_dt is not None:
            requested_dt = facebook_timing.current_minute(requested_dt)
            requested_key = facebook_timing.serialize_dt(requested_dt)
            if not _is_allowed_fixed_slot(requested_dt, morning_only):
                summary = "saved schedule is not on an allowed Khmer slot"
            elif requested_key in reserved_keys:
                summary = "saved schedule overlaps an already reserved slot"
            elif requested_dt < earliest:
                summary = "saved schedule is earlier than the minimum lead time"
            else:
                decision = facebook_timing.PublishDecision(
                    action="schedule",
                    effective_at=requested_dt,
                    anchor_at=requested_dt,
                    reason="facebook_api_schedule_from_package",
                )
                summary = "using saved package schedule"
        elif requested_schedule_at.strip():
            summary = f"invalid saved schedule: {requested_schedule_at.strip()}"
        else:
            summary = "package does not contain a saved schedule"

        if decision is None:
            decision = facebook_timing.decide_publish_action(
                now=now,
                last_anchor_at=facebook_timing.deserialize_dt(profile_state.get("last_anchor_at")),
                profile_state=profile_state,
                reserved_slots=reserved_slots,
            )
            summary = (
                f"fallback to next free Khmer slot {facebook_timing.format_anchor_ampm(decision.effective_at)} "
                f"because {summary}"
            )

        facebook_timing.reserve_anchor(
            anchor_at=decision.anchor_at,
            state_path=state_path,
            **identity,
        )
        state = facebook_timing.load_state(state_path)
        profile_state = facebook_timing.ensure_profile_state(state, **identity)
        pending = _shared_queue_pending_map(profile_state, now=now)
        pending[owner_key] = {
            "anchor_at": facebook_timing.serialize_dt(decision.anchor_at),
            "package_name": str(package_name or "").strip(),
        }
        facebook_timing.save_state(state, state_path)
        queue = facebook_timing.queue_status(
            facebook_timing.load_state(state_path),
            **identity,
        )
        return {
            "ok": True,
            "page_id": page_id,
            "package_name": str(package_name or "").strip(),
            "reservation_key": owner_key,
            "scheduled_publish_time": int(decision.effective_at.timestamp()),
            "summary": summary,
            "decision": {
                "action": decision.action,
                "effective_at": facebook_timing.serialize_dt(decision.effective_at),
                "anchor_at": facebook_timing.serialize_dt(decision.anchor_at),
                "reason": decision.reason,
                "interval_shifts": int(decision.interval_shifts),
            },
            "facebook_queue": queue,
        }


def _shared_queue_finalize(
    page_id: str,
    *,
    queue_secret: str = "",
    package_name: str,
    reservation_key: str = "",
    decision_payload: dict[str, object],
    interval_minutes: int | None = None,
) -> dict[str, object]:
    with _shared_queue_guard(page_id, queue_secret):
        state_path = _shared_queue_state_path(page_id, queue_secret)
        identity = _shared_queue_identity(page_id)
        action = str(decision_payload.get("action") or "schedule").strip()
        effective_at = facebook_timing.deserialize_dt(str(decision_payload.get("effective_at") or "").strip())
        anchor_at = facebook_timing.deserialize_dt(str(decision_payload.get("anchor_at") or "").strip())
        reason = str(decision_payload.get("reason") or "facebook_api_schedule_from_package").strip()
        interval_shifts = int(decision_payload.get("interval_shifts") or 0)
        if effective_at is None or anchor_at is None:
            raise RuntimeError("Shared queue finalize requires decision timestamps.")
        facebook_timing.record_decision(
            package_name=str(package_name or "").strip(),
            decision=facebook_timing.PublishDecision(
                action="schedule" if action != "post_now" else "post_now",
                effective_at=effective_at,
                anchor_at=anchor_at,
                reason=reason,
                interval_shifts=interval_shifts,
            ),
            state_path=state_path,
            interval_minutes=interval_minutes,
            **identity,
        )
        state = facebook_timing.load_state(state_path)
        profile_state = facebook_timing.ensure_profile_state(state, **identity)
        owner_key = _shared_queue_owner_key(package_name, reservation_key)
        pending = _shared_queue_pending_map(profile_state)
        pending.pop(owner_key, None)
        facebook_timing.save_state(state, state_path)
        return {
            "ok": True,
            "page_id": page_id,
            "facebook_queue": facebook_timing.queue_status(
                facebook_timing.load_state(state_path),
                **identity,
            ),
        }


def _shared_queue_release(
    page_id: str,
    *,
    queue_secret: str = "",
    reservation_key: str = "",
    anchor_at: str = "",
) -> dict[str, object]:
    with _shared_queue_guard(page_id, queue_secret):
        state_path = _shared_queue_state_path(page_id, queue_secret)
        identity = _shared_queue_identity(page_id)
        state = facebook_timing.load_state(state_path)
        profile_state = facebook_timing.ensure_profile_state(state, **identity)
        owner_key = _shared_queue_owner_key("", reservation_key) if str(reservation_key or "").strip() else ""
        pending = _shared_queue_pending_map(profile_state)
        anchor_dt = facebook_timing.deserialize_dt(anchor_at)
        if owner_key:
            pending_entry = pending.get(owner_key)
            if isinstance(pending_entry, dict):
                owner_anchor = facebook_timing.deserialize_dt(str(pending_entry.get("anchor_at") or "").strip())
                if owner_anchor is not None:
                    anchor_dt = owner_anchor
        if anchor_dt is not None:
            facebook_timing.release_anchor(
                anchor_at=anchor_dt,
                state_path=state_path,
                **identity,
            )
            state = facebook_timing.load_state(state_path)
            profile_state = facebook_timing.ensure_profile_state(state, **identity)
            pending = _shared_queue_pending_map(profile_state)
        if owner_key:
            pending.pop(owner_key, None)
        if anchor_dt is not None:
            anchor_key = facebook_timing.serialize_dt(anchor_dt)
            stale_keys = [
                key
                for key, value in pending.items()
                if isinstance(value, dict) and str(value.get("anchor_at") or "").strip() == anchor_key
            ]
            for stale_key in stale_keys:
                pending.pop(stale_key, None)
        if owner_key or anchor_dt is not None:
            facebook_timing.save_state(state, state_path)
        elif not str(anchor_at or "").strip():
            raise RuntimeError("Shared queue release requires reservation_key or anchor_at.")
        return {
            "ok": True,
            "page_id": page_id,
            "facebook_queue": facebook_timing.queue_status(
                facebook_timing.load_state(state_path),
                **identity,
            ),
        }


def _shared_queue_record_result(
    page_id: str,
    *,
    queue_secret: str = "",
    package_name: str,
    reservation_key: str = "",
    result: str,
    note: str,
    action: str = "",
    effective_at: str = "",
) -> dict[str, object]:
    with _shared_queue_guard(page_id, queue_secret):
        state_path = _shared_queue_state_path(page_id, queue_secret)
        identity = _shared_queue_identity(page_id)
        effective_dt = facebook_timing.deserialize_dt(effective_at) if effective_at else None
        normalized_result = str(result or "").strip().lower() or "failed"
        if normalized_result not in {"success", "failed", "stopped"}:
            normalized_result = "failed"
        facebook_timing.record_result(
            package_name=str(package_name or "").strip(),
            result=normalized_result,  # type: ignore[arg-type]
            note=str(note or "").strip(),
            state_path=state_path,
            effective_at=effective_dt,
            action=str(action or "").strip() or None,
            **identity,
        )
        state = facebook_timing.load_state(state_path)
        profile_state = facebook_timing.ensure_profile_state(state, **identity)
        owner_key = _shared_queue_owner_key(package_name, reservation_key)
        pending = _shared_queue_pending_map(profile_state)
        pending.pop(owner_key, None)
        facebook_timing.save_state(state, state_path)
        return {
            "ok": True,
            "page_id": page_id,
            "facebook_queue": facebook_timing.queue_status(
                facebook_timing.load_state(state_path),
                **identity,
            ),
        }


def now_is_recent(timestamp: object, threshold_seconds: float) -> bool:
    try:
        value = float(timestamp)
    except Exception:
        return False
    return (time.time() - value) <= threshold_seconds


def parse_client_path(path: str) -> tuple[str | None, str]:
    parsed = urlparse(path)
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 2 or parts[0] != "client":
        return None, parsed.path
    token = parts[1].strip()
    tail = "/" + "/".join(parts[2:]) if len(parts) > 2 else "/"
    return token or None, tail


def extract_query_dict(path: str) -> dict[str, str]:
    parsed = urlparse(path)
    query = parse_qs(parsed.query)
    return {str(key): str(values[0]) for key, values in query.items() if values}


def wait_for_job_result(token: str, job_id: str, timeout_seconds: float) -> tuple[int, dict]:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        job = STORE.get_job(token, job_id)
        if isinstance(job, dict) and job.get("status") == "done":
            body = job.get("response_body")
            status = int(job.get("response_status") or 200)
            STORE.purge_job(token, job_id)
            return status, body if isinstance(body, dict) else {"ok": False, "message": "Invalid relay response body."}
        time.sleep(0.35)
    return int(HTTPStatus.GATEWAY_TIMEOUT), {"ok": False, "message": "Mac relay job timed out."}


def _safe_int(value: object) -> int:
    try:
        return int(value or 0)
    except Exception:
        return 0


def relay_portal_clients_payload() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for client in STORE.list_clients():
        token = str(client.get("token") or "").strip()
        if not token:
            continue
        snapshot = client.get("snapshot")
        snapshot = snapshot if isinstance(snapshot, dict) else {}
        last_seen_at = client.get("last_seen_at")
        online = now_is_recent(last_seen_at, CLIENT_STALE_SECONDS)
        pending_jobs = sum(1 for job in client.get("jobs") or [] if isinstance(job, dict) and job.get("status") == "queued")
        relay_user_name = str(snapshot.get("relay_user_name") or "").strip()
        relay_mac_name = str(snapshot.get("relay_mac_name") or "").strip()
        mac_display_name = str(snapshot.get("mac_display_name") or "").strip()
        mac_device_name = str(snapshot.get("mac_device_name") or "").strip()
        mac_user_name = str(snapshot.get("mac_user_name") or "").strip()
        title = mac_display_name or relay_mac_name or mac_device_name or token
        subtitle_parts = [part for part in [relay_user_name or mac_user_name, relay_mac_name or mac_device_name] if part]
        subtitle = " / ".join(subtitle_parts) if subtitle_parts else token
        rows.append(
            {
                "token": token,
                "title": title,
                "subtitle": subtitle,
                "online": online,
                "last_seen_at": last_seen_at,
                "running": bool(snapshot.get("running")),
                "status": str(snapshot.get("status") or "").strip(),
                "detail": str(snapshot.get("detail") or "").strip(),
                "package_count": _safe_int(snapshot.get("package_count")),
                "source_count": _safe_int(snapshot.get("source_count")),
                "pending_jobs": pending_jobs,
                "control_url": f"/client/{token}/control",
            }
        )
    rows.sort(key=lambda row: (not bool(row.get("online")), str(row.get("title") or "").lower(), str(row.get("token") or "").lower()))
    return rows


def relay_public_client_status_payload(snapshot: dict[str, object], client: dict[str, object]) -> dict[str, object]:
    return {
        "ok": True,
        "status": str(snapshot.get("status") or "").strip(),
        "detail": str(snapshot.get("detail") or "").strip(),
        "running": bool(snapshot.get("running")),
        "remote_running": bool(snapshot.get("remote_running")),
        "task_kind": str(snapshot.get("task_kind") or "").strip(),
        "mac_user_name": str(snapshot.get("mac_user_name") or "").strip(),
        "mac_device_name": str(snapshot.get("mac_device_name") or "").strip(),
        "mac_display_name": str(snapshot.get("mac_display_name") or "").strip(),
        "password_required": bool(snapshot.get("password_required")),
        "relay_online": now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS),
        "relay_last_seen_at": client.get("last_seen_at"),
    }


def relay_portal_html() -> str:
    bootstrap_json = json.dumps(
        {
            "service": "mac-control-relay",
            "clients": relay_portal_clients_payload(),
        },
        separators=(",", ":"),
    ).replace("</", "<\\/")
    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Soranin Relay</title>
  <style>
    :root {
      color-scheme: dark;
      --bg0: #07101d;
      --bg1: #0f1b33;
      --card: rgba(13, 20, 38, 0.88);
      --line: rgba(170, 193, 255, 0.18);
      --text: #f7faff;
      --muted: #9baed2;
      --accent: #67e8f9;
      --accent2: #8b5cf6;
      --success: #34d399;
      --warn: #f59e0b;
      --shadow: 0 24px 60px rgba(0, 0, 0, 0.38);
      --radius: 24px;
    }
    * { box-sizing: border-box; }
    html, body {
      margin: 0;
      min-height: 100%;
      background:
        radial-gradient(circle at top left, rgba(103, 232, 249, 0.12), transparent 28%),
        radial-gradient(circle at top right, rgba(139, 92, 246, 0.12), transparent 32%),
        linear-gradient(180deg, var(--bg1) 0%, var(--bg0) 100%);
      color: var(--text);
      font-family: ui-rounded, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
    }
    body {
      padding: env(safe-area-inset-top) 14px calc(env(safe-area-inset-bottom) + 24px);
    }
    .shell {
      width: min(1120px, 100%);
      margin: 0 auto;
      padding: 10px 0 24px;
    }
    .hero, .card {
      border: 1px solid var(--line);
      border-radius: var(--radius);
      background: linear-gradient(180deg, rgba(24, 36, 67, 0.92) 0%, rgba(10, 17, 31, 0.9) 100%);
      box-shadow: var(--shadow);
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
    }
    .hero {
      padding: 22px;
      margin-bottom: 16px;
    }
    .eyebrow {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      border-radius: 999px;
      background: rgba(103, 232, 249, 0.12);
      border: 1px solid rgba(103, 232, 249, 0.2);
      color: var(--accent);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }
    h1, h2, h3, p { margin: 0; }
    h1 {
      margin-top: 16px;
      font-size: clamp(30px, 6vw, 46px);
      line-height: 1;
      letter-spacing: -0.04em;
    }
    .copy {
      margin-top: 10px;
      color: var(--muted);
      line-height: 1.55;
      max-width: 760px;
    }
    .meta {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 16px;
    }
    .pill {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 10px 12px;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.04);
      border: 1px solid var(--line);
      color: var(--muted);
      font-size: 13px;
    }
    .grid {
      display: grid;
      gap: 14px;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    }
    .card {
      padding: 18px;
      display: grid;
      gap: 14px;
    }
    .row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }
    .title {
      font-size: 22px;
      font-weight: 750;
      letter-spacing: -0.03em;
    }
    .subtitle {
      margin-top: 6px;
      color: var(--muted);
      font-size: 14px;
      line-height: 1.45;
    }
    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      border: 1px solid var(--line);
      white-space: nowrap;
    }
    .status.online {
      color: var(--success);
      background: rgba(52, 211, 153, 0.12);
      border-color: rgba(52, 211, 153, 0.22);
    }
    .status.offline {
      color: var(--warn);
      background: rgba(245, 158, 11, 0.12);
      border-color: rgba(245, 158, 11, 0.22);
    }
    .stats {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 10px;
    }
    .stat {
      padding: 12px;
      border-radius: 16px;
      background: rgba(255, 255, 255, 0.04);
      border: 1px solid rgba(170, 193, 255, 0.12);
    }
    .stat-label {
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }
    .stat-value {
      margin-top: 8px;
      font-size: 22px;
      font-weight: 780;
      letter-spacing: -0.03em;
    }
    .detail {
      min-height: 42px;
      color: var(--muted);
      line-height: 1.45;
      font-size: 14px;
    }
    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
    }
    a.button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 44px;
      padding: 0 16px;
      border-radius: 14px;
      text-decoration: none;
      color: var(--text);
      background: linear-gradient(135deg, rgba(103, 232, 249, 0.18), rgba(139, 92, 246, 0.24));
      border: 1px solid rgba(103, 232, 249, 0.18);
      font-weight: 700;
    }
    a.secondary {
      background: rgba(255, 255, 255, 0.04);
      border-color: var(--line);
      color: var(--muted);
    }
    .empty {
      padding: 26px;
      text-align: center;
      color: var(--muted);
      border: 1px dashed var(--line);
      border-radius: var(--radius);
    }
    @media (max-width: 680px) {
      .stats {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }
      .stats .stat:last-child {
        grid-column: 1 / -1;
      }
      .row {
        align-items: flex-start;
        flex-direction: column;
      }
      .status {
        align-self: flex-start;
      }
    }
  </style>
</head>
<body>
  <div class="shell">
    <section class="hero">
      <div class="eyebrow">Soranin Relay</div>
      <h1>All Macs in one relay page</h1>
      <p class="copy">Open one public relay URL, choose the Mac you want, then the control page will ask for that Mac's password first. This keeps Mac mini and NIN in one place for iPad Safari.</p>
      <div class="meta">
        <div class="pill" id="clientCount">0 Macs</div>
        <div class="pill" id="onlineCount">0 online</div>
        <div class="pill" id="updatedAt">Updating...</div>
      </div>
    </section>
    <section id="cards" class="grid"></section>
  </div>
  <script>
    const bootstrap = __BOOTSTRAP__;

    function trim(value) {
      return String(value || "").trim();
    }

    function escapeHtml(value) {
      return String(value || "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
    }

    function formatLastSeen(timestamp) {
      const value = Number(timestamp || 0);
      if (!value) return "No heartbeat yet";
      const seconds = Math.max(0, Math.round(Date.now() / 1000 - value));
      if (seconds < 10) return "Seen just now";
      if (seconds < 60) return `Seen ${seconds}s ago`;
      const minutes = Math.round(seconds / 60);
      if (minutes < 60) return `Seen ${minutes}m ago`;
      const hours = Math.round(minutes / 60);
      if (hours < 24) return `Seen ${hours}h ago`;
      const days = Math.round(hours / 24);
      return `Seen ${days}d ago`;
    }

    function renderCards(clients) {
      const cards = document.getElementById("cards");
      const onlineCount = clients.filter((item) => item.online).length;
      document.getElementById("clientCount").textContent = `${clients.length} Mac${clients.length === 1 ? "" : "s"}`;
      document.getElementById("onlineCount").textContent = `${onlineCount} online`;
      document.getElementById("updatedAt").textContent = `Updated ${new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;

      if (!clients.length) {
        cards.innerHTML = '<div class="empty">No relay clients yet. Open Soranin on each Mac and keep Remote Relay enabled first.</div>';
        return;
      }

      cards.innerHTML = clients.map((client) => {
        const statusClass = client.online ? "online" : "offline";
        const statusText = client.online ? "Online" : "Offline";
        const detail = trim(client.detail || client.status) || (client.online ? "Ready for remote control." : "Open Soranin on this Mac first.");
        const running = client.running ? "Running" : "Idle";
        return `
          <article class="card">
            <div class="row">
              <div>
                <div class="title">${escapeHtml(client.title)}</div>
                <div class="subtitle">${escapeHtml(client.subtitle)}</div>
              </div>
              <div class="status ${statusClass}">${statusText}</div>
            </div>
            <div class="stats">
              <div class="stat">
                <div class="stat-label">Packages</div>
                <div class="stat-value">${Number(client.package_count || 0)}</div>
              </div>
              <div class="stat">
                <div class="stat-label">Jobs</div>
                <div class="stat-value">${Number(client.pending_jobs || 0)}</div>
              </div>
              <div class="stat">
                <div class="stat-label">Runner</div>
                <div class="stat-value">${escapeHtml(running)}</div>
              </div>
            </div>
            <div class="detail">${escapeHtml(detail)}<br>${escapeHtml(formatLastSeen(client.last_seen_at))}</div>
            <div class="actions">
              <a class="button" href="${escapeHtml(client.control_url)}">Open Control</a>
            </div>
          </article>
        `;
      }).join("");
    }

    async function refresh() {
      try {
        const response = await fetch("/clients", { cache: "no-store" });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const payload = await response.json();
        renderCards(Array.isArray(payload.clients) ? payload.clients : []);
      } catch (error) {
        renderCards(Array.isArray(bootstrap.clients) ? bootstrap.clients : []);
      }
    }

    renderCards(Array.isArray(bootstrap.clients) ? bootstrap.clients : []);
    refresh();
    setInterval(refresh, 5000);
  </script>
</body>
</html>
""".replace("__BOOTSTRAP__", bootstrap_json)


class RelayHandler(BaseHTTPRequestHandler):
    server_version = "SoraninMacRelay/0.1"

    def _allowed_headers(self) -> str:
        return "Content-Type, X-Soranin-Password, X-Soranin-File-Name, X-Soranin-Session"

    def _request_client_ip(self) -> str:
        for header_name in ("CF-Connecting-IP", "X-Forwarded-For"):
            header_value = str(self.headers.get(header_name) or "").strip()
            if not header_value:
                continue
            return header_value.split(",", 1)[0].strip()
        return str(self.client_address[0] or "").strip()

    def _request_user_agent(self) -> str:
        return str(self.headers.get("User-Agent") or "").strip()

    def _request_control_session_token(self) -> str:
        header_value = str(self.headers.get("X-Soranin-Session") or "").strip()
        if header_value:
            return header_value
        try:
            parsed = urlparse(self.path)
            return str((parse_qs(parsed.query).get("__control_session") or [""])[0]).strip()
        except Exception:
            return ""

    def _relay_session_payload(self, client_token: str) -> dict[str, object] | None:
        payload = RELAY_WEB_SESSIONS.get(
            self._request_control_session_token(),
            client_ip=self._request_client_ip(),
            user_agent=self._request_user_agent(),
        )
        if not isinstance(payload, dict):
            return None
        if str(payload.get("client_token") or "").strip() != str(client_token or "").strip():
            return None
        return payload

    def _auth_attempt_key(self, client_token: str) -> str:
        return f"{client_token}|{self._request_client_ip()}|{self._request_user_agent()}"

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

    def _issue_control_session(self, *, client_token: str, remember: bool) -> tuple[str, float]:
        return RELAY_WEB_SESSIONS.create(
            client_ip=self._request_client_ip(),
            user_agent=self._request_user_agent(),
            ttl_seconds=CONTROL_SESSION_REMEMBER_TTL_SECONDS if remember else CONTROL_SESSION_TTL_SECONDS,
            data={
                "client_token": str(client_token or "").strip(),
                "remember": bool(remember),
            },
        )

    def _client_password_required(self, client: dict[str, object]) -> bool:
        snapshot = client.get("snapshot") if isinstance(client, dict) else {}
        snapshot = snapshot if isinstance(snapshot, dict) else {}
        return bool(snapshot.get("password_required"))

    def _verify_client_password(
        self,
        client_token: str,
        client: dict[str, object],
        provided_password: str,
        *,
        timeout_seconds: float = 30.0,
    ) -> tuple[int, dict[str, object]]:
        if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
            return HTTPStatus.SERVICE_UNAVAILABLE, {
                "ok": False,
                "message": "This Mac is offline. Open Soranin on the Mac first.",
            }
        if not self._client_password_required(client):
            return HTTPStatus.OK, {"ok": True, "password_required": False}
        password = str(provided_password or "").strip()
        if not password:
            return HTTPStatus.UNAUTHORIZED, {
                "ok": False,
                "message": "Enter the Mac control password to continue.",
                "password_required": True,
            }
        job_id = STORE.enqueue_job(
            client_token,
            "/auth/verify",
            {"password": password},
            {},
        )
        status, body = wait_for_job_result(client_token, job_id, timeout_seconds)
        payload = body if isinstance(body, dict) else {"ok": False, "message": "Relay auth verification failed."}
        return status, payload

    def _require_client_auth(self, client_token: str, client: dict[str, object]) -> bool:
        if not self._client_password_required(client):
            return True
        if self._relay_session_payload(client_token) is not None:
            return True
        attempt_key = self._auth_attempt_key(client_token)
        retry_after = RELAY_AUTH_ATTEMPTS.remaining_lockout(attempt_key)
        if retry_after > 0:
            self._auth_lockout_response(retry_after)
            return False
        provided_password = self._request_control_password()
        if not provided_password:
            self._send_json(
                {
                    "ok": False,
                    "message": "Enter the Mac control password to continue.",
                    "password_required": True,
                },
                HTTPStatus.UNAUTHORIZED,
            )
            return False
        status, payload = self._verify_client_password(client_token, client, provided_password)
        if 200 <= int(status) < 300 and bool(payload.get("ok")):
            RELAY_AUTH_ATTEMPTS.record_success(attempt_key)
            return True
        if int(status) == HTTPStatus.UNAUTHORIZED:
            retry_after = RELAY_AUTH_ATTEMPTS.record_failure(attempt_key)
            if retry_after > 0:
                self._auth_lockout_response(retry_after)
                return False
        self._send_json(payload, int(status))
        return False

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

    def _send_json(self, payload: dict, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html: str, status: int = HTTPStatus.OK) -> None:
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self) -> dict:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}

    def _read_raw_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _request_control_password(self) -> str:
        return str(self.headers.get("X-Soranin-Password") or "").strip()

    def _send_bytes(self, body: bytes, content_type: str, status: int = HTTPStatus.OK, file_name: str | None = None) -> None:
        total_size = len(body)
        range_header = str(self.headers.get("Range") or "").strip()
        start = 0
        end = max(total_size - 1, 0)

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

        payload = body[start : end + 1] if total_size else b""
        self.send_response(status)
        self.send_header("Content-Type", content_type or "application/octet-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Accept-Ranges", "bytes")
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total_size}")
        if file_name:
            self.send_header("Content-Disposition", f'inline; filename="{file_name}"')
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Content-Length", "0")
        self._send_security_headers()
        self.end_headers()

    def _handle_client_auth_login(self, client_token: str, client: dict[str, object]) -> None:
        if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
            self._send_json(
                {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                HTTPStatus.SERVICE_UNAVAILABLE,
            )
            return
        attempt_key = self._auth_attempt_key(client_token)
        retry_after = RELAY_AUTH_ATTEMPTS.remaining_lockout(attempt_key)
        if retry_after > 0:
            self._auth_lockout_response(retry_after)
            return
        payload = self._read_json_body()
        provided_password = str(payload.get("password") or "").strip()
        remember = bool(payload.get("remember"))
        password_required = self._client_password_required(client)
        status, body = self._verify_client_password(client_token, client, provided_password)
        if not (200 <= int(status) < 300 and bool((body or {}).get("ok"))):
            if int(status) == HTTPStatus.UNAUTHORIZED:
                retry_after = RELAY_AUTH_ATTEMPTS.record_failure(attempt_key)
                if retry_after > 0:
                    self._auth_lockout_response(retry_after)
                    return
            self._send_json(
                {
                    "ok": False,
                    "message": str((body or {}).get("message") or "Enter the Mac control password to continue.").strip(),
                    "password_required": password_required,
                },
                int(status),
            )
            return
        RELAY_AUTH_ATTEMPTS.record_success(attempt_key)
        session_token, expires_at = self._issue_control_session(
            client_token=client_token,
            remember=remember,
        )
        self._send_json(
            {
                "ok": True,
                "message": "Login OK.",
                "session_token": session_token,
                "expires_at": datetime.fromtimestamp(expires_at).isoformat(),
                "password_required": password_required,
            },
            HTTPStatus.OK,
        )

    def _handle_client_auth_logout(self) -> None:
        RELAY_WEB_SESSIONS.delete(self._request_control_session_token())
        self._send_json({"ok": True, "message": "Logged out."}, HTTPStatus.OK)

    def do_GET(self) -> None:
        parsed_path = urlparse(self.path).path
        if parsed_path in {"/", "/index.html", "/control", "/control/", "/control/index.html"}:
            self._send_html(relay_portal_html(), HTTPStatus.OK)
            return
        if parsed_path == "/clients":
            self._send_json({"ok": True, "clients": relay_portal_clients_payload()}, HTTPStatus.OK)
            return
        token, tail = parse_client_path(self.path)
        if parsed_path == "/status":
            self._send_json(
                {
                    "ok": True,
                    "service": "mac-control-relay",
                    "port": PORT,
                    "client_count": len(relay_portal_clients_payload()),
                },
                HTTPStatus.OK,
            )
            return
        if not token:
            self._send_json({"ok": False, "message": "Client token is required."}, HTTPStatus.NOT_FOUND)
            return

        if tail in {"/", "/index.html", "/control", "/control/", "/control/index.html"}:
            self._send_html(load_control_web_html(), HTTPStatus.OK)
            return

        client = STORE.client_status(token)
        snapshot = client.get("snapshot") if isinstance(client, dict) else {}
        snapshot = snapshot if isinstance(snapshot, dict) else {}

        if tail == "/status":
            if not bool(snapshot.get("password_required")):
                payload = dict(snapshot)
                payload.setdefault("ok", True)
                payload["relay_online"] = now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS)
                payload["relay_last_seen_at"] = client.get("last_seen_at")
            elif self._relay_session_payload(token) is not None:
                payload = dict(snapshot)
                payload.setdefault("ok", True)
                payload["relay_online"] = now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS)
                payload["relay_last_seen_at"] = client.get("last_seen_at")
            elif self._request_control_password():
                if not self._require_client_auth(token, client):
                    return
                payload = dict(snapshot)
                payload.setdefault("ok", True)
                payload["relay_online"] = now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS)
                payload["relay_last_seen_at"] = client.get("last_seen_at")
            else:
                payload = relay_public_client_status_payload(snapshot, client)
            self._send_json(payload, HTTPStatus.OK)
            return

        if tail == "/alerts/poll":
            if not self._require_client_auth(token, client):
                return
            query = extract_query_dict(self.path)
            try:
                after_id = max(0, int(query.get("after_id") or 0))
            except Exception:
                after_id = 0
            try:
                timeout_seconds = float(query.get("timeout") or 25.0)
            except Exception:
                timeout_seconds = 25.0
            timeout_seconds = max(0.0, min(timeout_seconds, 30.0))
            deadline = time.time() + timeout_seconds
            while True:
                event = STORE.next_event_after(token, after_id)
                if isinstance(event, dict):
                    self._send_json({"ok": True, "event": event}, HTTPStatus.OK)
                    return
                if time.time() >= deadline:
                    self._send_json({"ok": True, "event": None}, HTTPStatus.OK)
                    return
                time.sleep(0.35)

        if tail == "/facebook-post-bootstrap":
            if not self._require_client_auth(token, client):
                return
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            job_id = STORE.enqueue_job(token, "/facebook-post-bootstrap", {}, extract_query_dict(self.path))
            status, body = wait_for_job_result(token, job_id, 30.0)
            self._send_json(body, status)
            return

        if tail == "/facebook-feed-videos":
            if not self._require_client_auth(token, client):
                return
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            job_id = STORE.enqueue_job(token, "/facebook-feed-videos", {}, {})
            status, body = wait_for_job_result(token, job_id, 30.0)
            self._send_json(body, status)
            return

        if tail == "/facebook-feed-video":
            if not self._require_client_auth(token, client):
                return
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            query = extract_query_dict(self.path)
            job_id = STORE.enqueue_job(token, "/facebook-feed-video", {}, query)
            status, body = wait_for_job_result(token, job_id, 180.0)
            if (200 <= status < 300) and isinstance(body, dict) and body.get("data_base64"):
                try:
                    raw = base64.b64decode(str(body.get("data_base64") or ""), validate=True)
                except Exception:
                    self._send_json({"ok": False, "message": "Invalid video payload from Mac."}, HTTPStatus.BAD_GATEWAY)
                    return
                self._send_bytes(
                    raw,
                    str(body.get("mime_type") or "application/octet-stream"),
                    status,
                    str(body.get("file_name") or "").strip() or None,
                )
                return
            self._send_json(body, status)
            return

        if tail == "/facebook-packages":
            if not self._require_client_auth(token, client):
                return
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            job_id = STORE.enqueue_job(token, "/facebook-packages", {}, {})
            status, body = wait_for_job_result(token, job_id, 30.0)
            self._send_json(body, status)
            return

        if tail == "/facebook-package-thumbnail":
            if not self._require_client_auth(token, client):
                return
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            query = extract_query_dict(self.path)
            job_id = STORE.enqueue_job(token, "/facebook-package-thumbnail", {}, query)
            status, body = wait_for_job_result(token, job_id, 60.0)
            if (200 <= status < 300) and isinstance(body, dict) and body.get("data_base64"):
                try:
                    raw = base64.b64decode(str(body.get("data_base64") or ""), validate=True)
                except Exception:
                    self._send_json({"ok": False, "message": "Invalid thumbnail payload from Mac."}, HTTPStatus.BAD_GATEWAY)
                    return
                self._send_bytes(
                    raw,
                    str(body.get("mime_type") or "application/octet-stream"),
                    status,
                    str(body.get("file_name") or "").strip() or None,
                )
                return
            self._send_json(body, status)
            return

        if tail == "/facebook-package-video":
            if not self._require_client_auth(token, client):
                return
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            query = extract_query_dict(self.path)
            job_id = STORE.enqueue_job(token, "/facebook-package-video", {}, query)
            status, body = wait_for_job_result(token, job_id, 180.0)
            if (200 <= status < 300) and isinstance(body, dict) and body.get("data_base64"):
                try:
                    raw = base64.b64decode(str(body.get("data_base64") or ""), validate=True)
                except Exception:
                    self._send_json({"ok": False, "message": "Invalid video payload from Mac."}, HTTPStatus.BAD_GATEWAY)
                    return
                self._send_bytes(
                    raw,
                    str(body.get("mime_type") or "application/octet-stream"),
                    status,
                    str(body.get("file_name") or "").strip() or None,
                )
                return
            self._send_json(body, status)
            return

        self._send_json({"ok": False, "message": "Not found."}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        parsed_path = urlparse(self.path).path
        if parsed_path == "/shared/facebook-page-queues/status":
            payload = self._read_json_body()
            rows = payload.get("pages") if isinstance(payload.get("pages"), list) else []
            queue_secret = self._request_control_password()
            queues: dict[str, object] = {}
            for row in rows:
                if not isinstance(row, dict):
                    continue
                page_id = str(row.get("page_id") or "").strip()
                if not page_id:
                    continue
                package_count = int(row.get("package_count") or 0)
                last_error: Exception | None = None
                response_payload: dict[str, object] | None = None
                for attempt in range(4):
                    try:
                        response_payload = _shared_queue_status(
                            page_id,
                            queue_secret=queue_secret,
                            package_count=package_count,
                        )
                        last_error = None
                        break
                    except Exception as exc:
                        last_error = exc
                        message = str(exc).strip().lower()
                        retryable = "busy" in message or "timed out" in message
                        if retryable and attempt < 3:
                            time.sleep(0.35 * (attempt + 1))
                            continue
                        break
                if response_payload is not None:
                    queues[page_id] = response_payload
                else:
                    queues[page_id] = {"ok": False, "message": str(last_error or "Shared queue status failed.")}
            self._send_json({"ok": True, "queues": queues}, HTTPStatus.OK)
            return

        if parsed_path == "/shared/facebook-page-queue/reserve":
            payload = self._read_json_body()
            try:
                body = _shared_queue_reserve(
                    _shared_queue_page_id(payload.get("page_id")),
                    queue_secret=self._request_control_password(),
                    package_name=str(payload.get("package_name") or "").strip(),
                    reservation_key=str(payload.get("reservation_key") or "").strip(),
                    requested_schedule_at=str(payload.get("requested_schedule_at") or "").strip(),
                    allow_near_slot=bool(payload.get("allow_near_slot")),
                )
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            self._send_json(body, HTTPStatus.OK)
            return

        if parsed_path == "/shared/facebook-page-queue/finalize":
            payload = self._read_json_body()
            try:
                decision_payload = payload.get("decision")
                if not isinstance(decision_payload, dict):
                    raise RuntimeError("Decision payload is required.")
                interval_minutes = payload.get("interval_minutes")
                body = _shared_queue_finalize(
                    _shared_queue_page_id(payload.get("page_id")),
                    queue_secret=self._request_control_password(),
                    package_name=str(payload.get("package_name") or "").strip(),
                    reservation_key=str(payload.get("reservation_key") or "").strip(),
                    decision_payload=decision_payload,
                    interval_minutes=int(interval_minutes) if interval_minutes is not None else None,
                )
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            self._send_json(body, HTTPStatus.OK)
            return

        if parsed_path == "/shared/facebook-page-queue/release":
            payload = self._read_json_body()
            try:
                body = _shared_queue_release(
                    _shared_queue_page_id(payload.get("page_id")),
                    queue_secret=self._request_control_password(),
                    reservation_key=str(payload.get("reservation_key") or "").strip(),
                    anchor_at=str(payload.get("anchor_at") or "").strip(),
                )
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            self._send_json(body, HTTPStatus.OK)
            return

        if parsed_path == "/shared/facebook-page-queue/result":
            payload = self._read_json_body()
            try:
                body = _shared_queue_record_result(
                    _shared_queue_page_id(payload.get("page_id")),
                    queue_secret=self._request_control_password(),
                    package_name=str(payload.get("package_name") or "").strip(),
                    reservation_key=str(payload.get("reservation_key") or "").strip(),
                    result=str(payload.get("result") or "").strip(),
                    note=str(payload.get("note") or "").strip(),
                    action=str(payload.get("action") or "").strip(),
                    effective_at=str(payload.get("effective_at") or "").strip(),
                )
            except Exception as exc:
                self._send_json({"ok": False, "message": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            self._send_json(body, HTTPStatus.OK)
            return

        token, tail = parse_client_path(self.path)
        if not token:
            self._send_json({"ok": False, "message": "Client token is required."}, HTTPStatus.NOT_FOUND)
            return

        client = STORE.client_status(token)

        if tail == "/auth/login":
            self._handle_client_auth_login(token, client)
            return

        if tail == "/auth/logout":
            self._handle_client_auth_logout()
            return

        if tail == "/heartbeat":
            payload = self._read_json_body()
            snapshot = payload.get("snapshot") if isinstance(payload.get("snapshot"), dict) else {}
            client = STORE.update_heartbeat(token, snapshot)
            self._send_json(
                {
                    "ok": True,
                    "message": "Heartbeat saved.",
                    "relay_online": True,
                    "pending_jobs": sum(1 for job in client.get("jobs") or [] if job.get("status") == "queued"),
                },
                HTTPStatus.OK,
            )
            return

        if tail == "/jobs/claim":
            job = STORE.claim_next_job(token)
            self._send_json({"ok": True, "job": job}, HTTPStatus.OK)
            return

        if tail.startswith("/jobs/") and tail.endswith("/finish"):
            job_id = tail.split("/")[2]
            payload = self._read_json_body()
            response_status = int(payload.get("response_status") or 200)
            response_body = payload.get("response_body")
            if not isinstance(response_body, dict):
                response_body = {"ok": False, "message": "Invalid relay response body."}
            ok = STORE.finish_job(token, job_id, response_status, response_body)
            self._send_json({"ok": ok}, HTTPStatus.OK if ok else HTTPStatus.NOT_FOUND)
            return

        if tail == "/source-video-upload":
            if not self._require_client_auth(token, client):
                return
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            body = self._read_raw_body()
            if not body:
                self._send_json({"ok": False, "message": "Upload body is empty."}, HTTPStatus.BAD_REQUEST)
                return
            query = extract_query_dict(self.path)
            requested_name = str(query.get("file_name") or "").strip()
            if not requested_name:
                requested_name = str(self.headers.get("X-Soranin-File-Name") or "").strip()
            payload = {
                "file_name": requested_name,
                "content_type": str(self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower(),
                "file_data_base64": base64.b64encode(body).decode("ascii"),
            }
            job_id = STORE.enqueue_job(token, "/source-video-upload", payload, {})
            status, body = wait_for_job_result(token, job_id, 600.0)
            self._send_json(body, status)
            return

        if tail in {
            "/facebook-queue-clear",
            "/facebook-queue-reset",
            "/facebook-queue-morning-only",
            "/facebook-post-preflight",
            "/facebook-post-run",
            "/facebook-post-stop",
            "/facebook-post-save-page",
            "/facebook-upload-run",
            "/quit-chrome",
            "/remote-run",
            "/facebook-package-assign-page",
            "/facebook-package-back-to-old",
        }:
            if not self._require_client_auth(token, client):
                return
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            payload = self._read_json_body()
            timeout_seconds = (
                150.0
                if tail == "/facebook-post-preflight"
                else 30.0
                if tail == "/facebook-post-save-page"
                else 30.0
                if tail in {"/facebook-queue-clear", "/facebook-queue-reset", "/facebook-queue-morning-only", "/facebook-post-stop"}
                else 60.0
                if tail in {"/facebook-package-assign-page", "/facebook-package-back-to-old"}
                else JOB_TIMEOUT_SECONDS
            )
            job_id = STORE.enqueue_job(token, tail, payload, {})
            status, body = wait_for_job_result(token, job_id, timeout_seconds)
            self._send_json(body, status)
            return

        if tail == "/facebook-package-delete":
            if not self._require_client_auth(token, client):
                return
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            payload = self._read_json_body()
            job_id = STORE.enqueue_job(token, "/facebook-package-delete", payload, {})
            status, body = wait_for_job_result(token, job_id, 90.0)
            self._send_json(body, status)
            return

        self._send_json({"ok": False, "message": "Not found."}, HTTPStatus.NOT_FOUND)

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> int:
    server = ThreadingHTTPServer((HOST, PORT), RelayHandler)
    print(f"Mac control relay running at http://{HOST}:{PORT}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
