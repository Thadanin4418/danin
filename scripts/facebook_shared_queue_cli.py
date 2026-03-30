#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys

import facebook_shared_queue


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="CLI wrapper for Facebook shared queue relay calls.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    reserve = subparsers.add_parser("reserve", help="Reserve the next queue slot for a page/package.")
    reserve.add_argument("--page-id", required=True)
    reserve.add_argument("--package-name", required=True)
    reserve.add_argument("--reservation-key", required=True)
    reserve.add_argument("--requested-schedule-at", default="")
    reserve.add_argument("--timeout", type=float, default=8.0)

    release = subparsers.add_parser("release", help="Release a queue reservation.")
    release.add_argument("--page-id", required=True)
    release.add_argument("--reservation-key", default="")
    release.add_argument("--anchor-at", default="")
    release.add_argument("--timeout", type=float, default=8.0)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv or sys.argv[1:])

    if not facebook_shared_queue.shared_queue_enabled():
        parser.error("Shared queue relay is not configured.")

    try:
        if args.command == "reserve":
            result = facebook_shared_queue.reserve_schedule(
                page_id=str(args.page_id or "").strip(),
                package_name=str(args.package_name or "").strip(),
                reservation_key=str(args.reservation_key or "").strip(),
                requested_schedule_at=str(args.requested_schedule_at or "").strip(),
                timeout=float(args.timeout),
            )
        elif args.command == "release":
            result = facebook_shared_queue.release_schedule(
                page_id=str(args.page_id or "").strip(),
                reservation_key=str(args.reservation_key or "").strip(),
                anchor_at=str(args.anchor_at or "").strip(),
                timeout=float(args.timeout),
            )
        else:
            parser.error(f"Unsupported command: {args.command}")
            return 2
    except Exception as exc:
        print(json.dumps({"ok": False, "message": str(exc)}), flush=True)
        return 1

    if not isinstance(result, dict):
        print(json.dumps({"ok": False, "message": "Relay returned no data."}), flush=True)
        return 1

    print(json.dumps(result), flush=True)
    return 0 if bool(result.get("ok")) else 1


if __name__ == "__main__":
    raise SystemExit(main())
