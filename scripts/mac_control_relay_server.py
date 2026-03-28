#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from soranin_paths import runtime_data_file


HOST = "0.0.0.0"
PORT = 8788
CLIENT_STALE_SECONDS = 20.0
JOB_TIMEOUT_SECONDS = 180.0
STORE_PATH = runtime_data_file("mac_control_relay_store.json", env_name="SORANIN_MAC_CONTROL_RELAY_STORE")


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
        token, tail = parse_client_path(self.path)
        if urlparse(self.path).path == "/status":
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
            timeout_seconds = 150.0 if tail == "/facebook-post-preflight" else JOB_TIMEOUT_SECONDS
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
