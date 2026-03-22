#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re

from soranin_paths import CONTROL_RELAY_CONFIG_FILE


def normalize_label(value: str, fallback: str) -> str:
    text = re.sub(r"[^A-Za-z0-9._-]+", "-", str(value or "").strip()).strip("-._")
    return text or fallback


def main() -> int:
    parser = argparse.ArgumentParser(description="Save Soranin control relay settings.")
    parser.add_argument("--relay-url", required=True, help="Relay base URL, for example https://example.onrender.com")
    parser.add_argument("--user-name", required=True, help="Short user label, for example danin")
    parser.add_argument("--mac-name", required=True, help="Short Mac label, for example NIN-MBP")
    parser.add_argument("--secret-token", required=True, help="Secret token for this Mac")
    parser.add_argument("--poll-seconds", type=float, default=3.0, help="Mac poll interval in seconds")
    args = parser.parse_args()

    relay_url = str(args.relay_url).strip().rstrip("/")
    user_name = normalize_label(args.user_name, "user")
    mac_name = normalize_label(args.mac_name, "mac")
    secret_token = normalize_label(args.secret_token, "secret")
    poll_seconds = max(1.0, float(args.poll_seconds or 3.0))

    payload = {
        "relay_url": relay_url,
        "relay_user_name": user_name,
        "relay_mac_name": mac_name,
        "relay_secret_token": secret_token,
        "poll_seconds": poll_seconds,
    }
    CONTROL_RELAY_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONTROL_RELAY_CONFIG_FILE.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    client_token = f"{user_name}-{mac_name}-{secret_token}"
    client_url = f"{relay_url}/client/{client_token}"
    print(json.dumps({
        "ok": True,
        "config_file": str(CONTROL_RELAY_CONFIG_FILE),
        "client_token": client_token,
        "client_url": client_url,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
