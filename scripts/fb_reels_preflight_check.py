#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from datetime import datetime, timedelta
from pathlib import Path


STEP3_SCRIPT = Path("/Users/nin/Downloads/fb_reels_step3_upload_video_and_next.py")
TIMING_SCRIPT = Path("/Users/nin/Downloads/fb_reels_publish_timing.py")
ROOT_DEFAULT = Path("/Users/nin/Downloads/Soranin")
STATE_DEFAULT = ROOT_DEFAULT / ".fb_reels_publish_state.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check the current Mac time/date against the saved Facebook Reels timing state before upload."
    )
    parser.add_argument(
        "package_dir",
        nargs="?",
        default="",
        help="Optional path to a numbered Reels package folder.",
    )
    parser.add_argument(
        "--state-path",
        default=str(STATE_DEFAULT),
        help="JSON state file used to remember the last schedule/post anchor time.",
    )
    parser.add_argument("--profile-key", default="", help="Optional Chrome profile key override.")
    parser.add_argument("--profile-name", default="", help="Optional Chrome profile name override.")
    parser.add_argument("--profile-directory", default="", help="Optional Chrome profile directory override.")
    parser.add_argument("--page-name", default="", help="Optional Facebook profile/page name override.")
    parser.add_argument(
        "--interval-minutes",
        type=int,
        default=0,
        help="Optional interval in minutes for this page/profile. Example: 30 or 60.",
    )
    return parser.parse_args()


def load_module(path: Path, name: str):
    if not path.exists():
        raise RuntimeError(f"Missing dependency script: {path}")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def choose_profile_hint(step3, timing, args: argparse.Namespace, state: dict) -> dict[str, str | None]:
    if args.profile_key or args.profile_name or args.profile_directory or args.page_name:
        remembered = timing.remembered_profile_for_page(state, args.page_name) if args.page_name else None
        return {
            "profile_key": args.profile_key or (remembered or {}).get("profile_key"),
            "profile_name": args.profile_name or (remembered or {}).get("profile_name"),
            "profile_directory": args.profile_directory or (remembered or {}).get("profile_directory"),
            "page_name": args.page_name or (remembered or {}).get("page_name"),
            "source": "cli_override_page_memory" if remembered and args.page_name else "cli_override",
        }

    try:
        info = step3.active_chrome_profile()
    except Exception:
        info = {}

    if any(info.get(key) for key in ("profile_key", "profile_name", "profile_directory")):
        return {
            "profile_key": info.get("profile_key"),
            "profile_name": info.get("profile_name"),
            "profile_directory": info.get("profile_directory"),
            "page_name": args.page_name or state.get("last_page_name"),
            "source": str(info.get("source") or "chrome_active"),
        }

    return {
        "profile_key": state.get("last_profile_key"),
        "profile_name": state.get("last_profile_name"),
        "profile_directory": state.get("last_profile_directory"),
        "page_name": args.page_name or state.get("last_page_name"),
        "source": "state_last_profile",
    }


def iso_or_none(dt: datetime | None) -> str | None:
    return dt.isoformat() if dt else None


def package_summary(step3, package_dir: Path | None) -> dict[str, object] | None:
    if package_dir is None:
        return None
    if not package_dir.exists():
        return {
            "package_dir": str(package_dir),
            "exists": False,
        }

    assets = step3.resolve_assets(package_dir)
    return {
        "package_dir": str(package_dir),
        "exists": True,
        "video_path": str(assets.get("video_path")) if assets.get("video_path") else None,
        "title_path": str(assets.get("title_path")) if assets.get("title_path") else None,
        "title_loaded": bool(assets.get("title")),
    }


def minutes_delta(now: datetime, other: datetime | None) -> int | None:
    if other is None:
        return None
    return int((other - now).total_seconds() // 60)


def main() -> int:
    args = parse_args()
    step3 = load_module(STEP3_SCRIPT, "fb_step3_preflight")
    timing = load_module(TIMING_SCRIPT, "fb_timing_preflight")

    state_path = Path(args.state_path).expanduser()
    state = timing.load_state(state_path)
    profile_hint = choose_profile_hint(step3, timing, args, state)
    profile_state = timing.ensure_profile_state(
        state,
        profile_key=profile_hint.get("profile_key"),
        profile_name=profile_hint.get("profile_name"),
        profile_directory=profile_hint.get("profile_directory"),
        page_name=profile_hint.get("page_name"),
    )
    interval_minutes = timing.resolve_interval_minutes(
        profile_state,
        args.interval_minutes if args.interval_minutes > 0 else None,
    )

    now = datetime.now().astimezone()
    now_floor = timing.current_minute(now)
    last_anchor_at = timing.deserialize_dt(profile_state.get("last_anchor_at"))
    next_slot_at = timing.deserialize_dt(profile_state.get("next_slot_at"))
    decision = timing.decide_publish_action(
        now=now,
        last_anchor_at=last_anchor_at,
        interval_minutes=interval_minutes,
    )

    package_dir = Path(args.package_dir).expanduser() if args.package_dir else None
    slot_status = "no_saved_slot"
    if next_slot_at is not None:
        slot_status = "slot_reached_or_passed" if now_floor >= next_slot_at else "slot_not_reached_yet"

    warnings: list[str] = []
    if package_dir is not None and not package_dir.exists():
        warnings.append("package_missing")
    if next_slot_at is not None and last_anchor_at is not None and next_slot_at <= last_anchor_at:
        warnings.append("saved_state_slot_not_after_anchor")
    print(
        json.dumps(
            {
                "status": "ok",
                "step": "preflight",
                "state_path": str(state_path),
                "current_time": timing.serialize_dt(now_floor),
                "current_time_label": timing.format_anchor_ampm(now_floor),
                "profile": {
                    "profile_key": profile_state.get("profile_key"),
                    "profile_name": profile_state.get("profile_name"),
                    "profile_directory": profile_state.get("profile_directory"),
                    "page_name": profile_state.get("page_name"),
                    "interval_minutes": interval_minutes,
                    "source": profile_hint.get("source"),
                },
                "saved": {
                    "interval_minutes": profile_state.get("interval_minutes"),
                    "last_anchor_at": iso_or_none(last_anchor_at),
                    "last_anchor_label": profile_state.get("last_anchor_label_ampm"),
                    "next_slot_at": iso_or_none(next_slot_at),
                    "next_slot_label": profile_state.get("next_slot_label_ampm"),
                    "last_action": profile_state.get("last_action"),
                    "last_package_name": profile_state.get("last_package_name"),
                    "page_name": profile_state.get("page_name"),
                },
                "comparison": {
                    "slot_status": slot_status,
                    "minutes_until_next_slot": minutes_delta(now_floor, next_slot_at),
                    "minutes_since_last_anchor": None if last_anchor_at is None else int((now_floor - last_anchor_at).total_seconds() // 60),
                },
                "decision_preview": {
                    "action": decision.action,
                    "effective_at": timing.serialize_dt(decision.effective_at),
                    "effective_label": timing.format_anchor_ampm(decision.effective_at),
                    "reason": decision.reason,
                },
                "facebook_schedule": {
                    "earliest_allowed_at": None,
                    "earliest_allowed_label": None,
                    "exact_schedule_possible": True,
                },
                "package": package_summary(step3, package_dir),
                "warnings": warnings,
            },
            indent=2,
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
