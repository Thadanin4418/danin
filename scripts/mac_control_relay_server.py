#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import json
import threading
import time
import uuid
from datetime import timedelta
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
STORE_PATH = runtime_data_file("mac_control_relay_store.json", env_name="SORANIN_MAC_CONTROL_RELAY_STORE")
SHARED_QUEUE_DIR = STORE_PATH.parent / "facebook_shared_queues"
SHARED_QUEUE_LOCK = threading.Lock()


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
        return client

    def update_heartbeat(self, token: str, snapshot: dict) -> dict:
        with self.lock:
            client = self._client(token)
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
            }

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
    with SHARED_QUEUE_LOCK:
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
    requested_schedule_at: str = "",
) -> dict[str, object]:
    with SHARED_QUEUE_LOCK:
        state_path = _shared_queue_state_path(page_id, queue_secret)
        identity = _shared_queue_identity(page_id)
        now = facebook_timing.now_khmer()
        state = facebook_timing.load_state(state_path)
        profile_state = facebook_timing.ensure_profile_state(state, **identity)
        morning_only = bool(profile_state.get("morning_only"))
        reserved_slots = facebook_timing._all_reserved_slots(state, now=now)
        reserved_keys = {facebook_timing.serialize_dt(slot) for slot in reserved_slots}
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
        queue = facebook_timing.queue_status(
            facebook_timing.load_state(state_path),
            **identity,
        )
        return {
            "ok": True,
            "page_id": page_id,
            "package_name": str(package_name or "").strip(),
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
    decision_payload: dict[str, object],
    interval_minutes: int | None = None,
) -> dict[str, object]:
    with SHARED_QUEUE_LOCK:
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
        return {
            "ok": True,
            "page_id": page_id,
            "facebook_queue": facebook_timing.queue_status(
                facebook_timing.load_state(state_path),
                **identity,
            ),
        }


def _shared_queue_release(page_id: str, *, queue_secret: str = "", anchor_at: str) -> dict[str, object]:
    with SHARED_QUEUE_LOCK:
        state_path = _shared_queue_state_path(page_id, queue_secret)
        identity = _shared_queue_identity(page_id)
        anchor_dt = facebook_timing.deserialize_dt(anchor_at)
        if anchor_dt is None:
            raise RuntimeError("Shared queue release requires anchor_at.")
        facebook_timing.release_anchor(
            anchor_at=anchor_dt,
            state_path=state_path,
            **identity,
        )
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
    result: str,
    note: str,
    action: str = "",
    effective_at: str = "",
) -> dict[str, object]:
    with SHARED_QUEUE_LOCK:
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


class RelayHandler(BaseHTTPRequestHandler):
    server_version = "SoraninMacRelay/0.1"

    def _send_json(self, payload: dict, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Soranin-Password, X-Soranin-File-Name")
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
        self.send_response(status)
        self.send_header("Content-Type", content_type or "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        if file_name:
            self.send_header("Content-Disposition", f'inline; filename="{file_name}"')
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Soranin-Password")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Soranin-Password, X-Soranin-File-Name")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        parsed_path = urlparse(self.path).path
        token, tail = parse_client_path(self.path)
        if parsed_path == "/status":
            self._send_json({"ok": True, "service": "mac-control-relay", "port": PORT}, HTTPStatus.OK)
            return
        if not token:
            self._send_json({"ok": False, "message": "Client token is required."}, HTTPStatus.NOT_FOUND)
            return

        client = STORE.client_status(token)
        snapshot = client.get("snapshot") if isinstance(client, dict) else {}
        snapshot = snapshot if isinstance(snapshot, dict) else {}

        if tail == "/status":
            payload = dict(snapshot)
            payload.setdefault("ok", True)
            payload["relay_online"] = now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS)
            payload["relay_last_seen_at"] = client.get("last_seen_at")
            self._send_json(payload, HTTPStatus.OK)
            return

        if tail == "/facebook-post-bootstrap":
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            payload = {"__control_password": self._request_control_password()}
            job_id = STORE.enqueue_job(token, "/facebook-post-bootstrap", payload, extract_query_dict(self.path))
            status, body = wait_for_job_result(token, job_id, 30.0)
            self._send_json(body, status)
            return

        if tail == "/facebook-packages":
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            payload = {"__control_password": self._request_control_password()}
            job_id = STORE.enqueue_job(token, "/facebook-packages", payload, {})
            status, body = wait_for_job_result(token, job_id, 30.0)
            self._send_json(body, status)
            return

        if tail == "/facebook-package-thumbnail":
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            query = extract_query_dict(self.path)
            payload = {"__control_password": self._request_control_password()}
            job_id = STORE.enqueue_job(token, "/facebook-package-thumbnail", payload, query)
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
                try:
                    queues[page_id] = _shared_queue_status(
                        page_id,
                        queue_secret=queue_secret,
                        package_count=package_count,
                    )
                except Exception as exc:
                    queues[page_id] = {"ok": False, "message": str(exc)}
            self._send_json({"ok": True, "queues": queues}, HTTPStatus.OK)
            return

        if parsed_path == "/shared/facebook-page-queue/reserve":
            payload = self._read_json_body()
            try:
                body = _shared_queue_reserve(
                    _shared_queue_page_id(payload.get("page_id")),
                    queue_secret=self._request_control_password(),
                    package_name=str(payload.get("package_name") or "").strip(),
                    requested_schedule_at=str(payload.get("requested_schedule_at") or "").strip(),
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
            client = STORE.client_status(token)
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
                "__control_password": self._request_control_password(),
                "file_name": requested_name,
                "content_type": str(self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower(),
                "file_data_base64": base64.b64encode(body).decode("ascii"),
            }
            job_id = STORE.enqueue_job(token, "/source-video-upload", payload, {})
            status, body = wait_for_job_result(token, job_id, 600.0)
            self._send_json(body, status)
            return

        if tail in {
            "/facebook-post-preflight",
            "/facebook-post-run",
            "/facebook-post-save-page",
            "/facebook-upload-run",
            "/quit-chrome",
            "/remote-run",
        }:
            client = STORE.client_status(token)
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            payload = self._read_json_body()
            payload["__control_password"] = self._request_control_password()
            timeout_seconds = (
                150.0
                if tail == "/facebook-post-preflight"
                else 30.0
                if tail == "/facebook-post-save-page"
                else JOB_TIMEOUT_SECONDS
            )
            job_id = STORE.enqueue_job(token, tail, payload, {})
            status, body = wait_for_job_result(token, job_id, timeout_seconds)
            self._send_json(body, status)
            return

        if tail == "/facebook-package-delete":
            client = STORE.client_status(token)
            if not now_is_recent(client.get("last_seen_at"), CLIENT_STALE_SECONDS):
                self._send_json(
                    {"ok": False, "message": "This Mac is offline. Open Soranin on the Mac first."},
                    HTTPStatus.SERVICE_UNAVAILABLE,
                )
                return
            payload = self._read_json_body()
            payload["__control_password"] = self._request_control_password()
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
