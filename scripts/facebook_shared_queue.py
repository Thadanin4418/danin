#!/usr/bin/env python3
from __future__ import annotations

import json
from typing import Any
from urllib import error as urllib_error, parse as urllib_parse, request as urllib_request

from soranin_paths import CONTROL_RELAY_CONFIG_FILE


def load_relay_config() -> dict[str, object]:
    try:
        payload = json.loads(CONTROL_RELAY_CONFIG_FILE.read_text(encoding="utf-8"))
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    relay_url = str(payload.get("relay_url") or "").strip().rstrip("/")
    control_password = str(
        payload.get("control_password")
        or payload.get("password")
        or ""
    ).strip()
    return {
        "relay_url": relay_url,
        "control_password": control_password,
    }


def relay_base_url() -> str:
    return str(load_relay_config().get("relay_url") or "").strip()


def relay_control_password() -> str:
    return str(load_relay_config().get("control_password") or "").strip()


def shared_queue_enabled() -> bool:
    return bool(relay_base_url() and relay_control_password())


def relay_request_json(
    method: str,
    url: str,
    *,
    payload: dict[str, object] | None = None,
    timeout: float = 10.0,
) -> dict[str, Any]:
    headers = {"Accept": "application/json"}
    password = relay_control_password()
    if password:
        headers["X-Soranin-Password"] = password
    data: bytes | None = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode("utf-8")
    request = urllib_request.Request(url, data=data, headers=headers, method=method.upper())
    try:
        with urllib_request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
    except urllib_error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw or "{}")
        except Exception:
            parsed = {}
        message = str(parsed.get("message") or raw or f"Relay HTTP {exc.code}").strip()
        raise RuntimeError(message) from exc
    except urllib_error.URLError as exc:
        raise RuntimeError(str(exc.reason or exc)) from exc

    try:
        parsed = json.loads(raw or "{}")
    except Exception as exc:
        raise RuntimeError("Relay returned invalid JSON.") from exc
    if not isinstance(parsed, dict):
        raise RuntimeError("Relay returned invalid payload.")
    return parsed


def fetch_queue_statuses(page_ids: list[str], *, package_count: int = 0, timeout: float = 4.0) -> dict[str, dict[str, Any]]:
    base = relay_base_url()
    cleaned = [str(page_id or "").strip() for page_id in page_ids if str(page_id or "").strip()]
    if not base or not cleaned:
        return {}
    payload = {
        "pages": [
            {
                "page_id": page_id,
                "package_count": int(package_count),
            }
            for page_id in cleaned
        ]
    }
    response = relay_request_json(
        "POST",
        f"{base}/shared/facebook-page-queues/status",
        payload=payload,
        timeout=timeout,
    )
    rows = response.get("queues")
    if not isinstance(rows, dict):
        return {}
    return {
        str(page_id): dict(value)
        for page_id, value in rows.items()
        if isinstance(page_id, str) and isinstance(value, dict)
    }


def reserve_schedule(
    *,
    page_id: str,
    package_name: str,
    requested_schedule_at: str = "",
    timeout: float = 8.0,
) -> dict[str, Any] | None:
    base = relay_base_url()
    if not base:
        return None
    response = relay_request_json(
        "POST",
        f"{base}/shared/facebook-page-queue/reserve",
        payload={
            "page_id": str(page_id or "").strip(),
            "package_name": str(package_name or "").strip(),
            "requested_schedule_at": str(requested_schedule_at or "").strip(),
        },
        timeout=timeout,
    )
    return response if response.get("ok") else None


def finalize_schedule(
    *,
    page_id: str,
    package_name: str,
    decision: dict[str, object],
    interval_minutes: int | None = None,
    timeout: float = 8.0,
) -> dict[str, Any] | None:
    base = relay_base_url()
    if not base:
        return None
    payload: dict[str, object] = {
        "page_id": str(page_id or "").strip(),
        "package_name": str(package_name or "").strip(),
        "decision": dict(decision),
    }
    if interval_minutes is not None:
        payload["interval_minutes"] = int(interval_minutes)
    response = relay_request_json(
        "POST",
        f"{base}/shared/facebook-page-queue/finalize",
        payload=payload,
        timeout=timeout,
    )
    return response if response.get("ok") else None


def release_schedule(
    *,
    page_id: str,
    anchor_at: str,
    timeout: float = 8.0,
) -> dict[str, Any] | None:
    base = relay_base_url()
    if not base:
        return None
    response = relay_request_json(
        "POST",
        f"{base}/shared/facebook-page-queue/release",
        payload={
            "page_id": str(page_id or "").strip(),
            "anchor_at": str(anchor_at or "").strip(),
        },
        timeout=timeout,
    )
    return response if response.get("ok") else None


def record_result(
    *,
    page_id: str,
    package_name: str,
    result: str,
    note: str,
    action: str = "",
    effective_at: str = "",
    timeout: float = 8.0,
) -> dict[str, Any] | None:
    base = relay_base_url()
    if not base:
        return None
    response = relay_request_json(
        "POST",
        f"{base}/shared/facebook-page-queue/result",
        payload={
            "page_id": str(page_id or "").strip(),
            "package_name": str(package_name or "").strip(),
            "result": str(result or "").strip(),
            "note": str(note or "").strip(),
            "action": str(action or "").strip(),
            "effective_at": str(effective_at or "").strip(),
        },
        timeout=timeout,
    )
    return response if response.get("ok") else None
