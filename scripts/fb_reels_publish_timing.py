#!/usr/bin/env python3
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Literal


POST_INTERVAL_MINUTES = 30
MIN_SCHEDULE_LEAD_MINUTES = 30
DEFAULT_STATE_PATH = Path("/Users/nin/Downloads/Soranin/.fb_reels_publish_state.json")
STATE_SCHEMA_VERSION = 4
SUMMARY_FIELDS = (
    "interval_minutes",
    "last_anchor_at",
    "last_anchor_label",
    "last_anchor_label_ampm",
    "last_action",
    "last_package_name",
    "next_slot_at",
    "next_slot_label",
    "next_slot_label_ampm",
    "next_slot_moves_to_new_day",
)


Action = Literal["schedule", "post_now"]


@dataclass(frozen=True)
class PublishDecision:
    action: Action
    effective_at: datetime
    anchor_at: datetime
    reason: str
    interval_shifts: int = 0


@dataclass(frozen=True)
class ProfileIdentity:
    profile_key: str
    profile_name: str | None = None
    profile_directory: str | None = None
    page_name: str | None = None


def normalize_interval_minutes(value: int | str | None) -> int:
    try:
        interval = int(value) if value is not None else POST_INTERVAL_MINUTES
    except (TypeError, ValueError):
        interval = POST_INTERVAL_MINUTES
    return interval if interval > 0 else POST_INTERVAL_MINUTES


def normalized_page_name(value: str | None) -> str | None:
    cleaned = (value or "").strip()
    return cleaned.casefold() if cleaned else None


def current_minute(dt: datetime) -> datetime:
    return dt.replace(second=0, microsecond=0)


def format_anchor(dt: datetime) -> str:
    offset = dt.strftime("%z")
    offset = f"{offset[:3]}:{offset[3:]}" if offset else ""
    return f"{dt.strftime('%Y-%m-%d %H:%M')} ({offset})".strip()


def format_anchor_ampm(dt: datetime) -> str:
    offset = dt.strftime("%z")
    offset = f"{offset[:3]}:{offset[3:]}" if offset else ""
    return f"{dt.strftime('%Y-%m-%d %I:%M %p')} ({offset})".strip()


def serialize_dt(dt: datetime) -> str:
    return dt.isoformat()


def deserialize_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value)


def add_minutes_with_day_rollover(anchor_at: datetime, minutes: int) -> datetime:
    local_anchor = anchor_at.astimezone()
    return local_anchor + timedelta(minutes=minutes)


def crosses_day_boundary(start: datetime, end: datetime) -> bool:
    return start.astimezone().date() != end.astimezone().date()


def advance_schedule_slot(
    scheduled_at: datetime,
    *,
    interval_minutes: int,
    not_before: datetime | None = None,
) -> tuple[datetime, int]:
    candidate = current_minute(scheduled_at.astimezone())
    target = current_minute(not_before.astimezone()) if not_before is not None else None
    shifts = 0
    while target is not None and candidate < target:
        candidate = add_minutes_with_day_rollover(candidate, interval_minutes)
        shifts += 1
    return candidate, shifts


def decide_publish_action(
    *,
    now: datetime,
    last_anchor_at: datetime | None,
    interval_minutes: int = POST_INTERVAL_MINUTES,
    min_schedule_lead_minutes: int = MIN_SCHEDULE_LEAD_MINUTES,
) -> PublishDecision:
    current = current_minute(now.astimezone())

    if last_anchor_at is None:
        return PublishDecision(
            action="post_now",
            effective_at=current,
            anchor_at=current,
            reason="first_item_post_now_for_new_page",
        )

    candidate = add_minutes_with_day_rollover(last_anchor_at, interval_minutes)
    if current >= candidate:
        return PublishDecision(
            action="post_now",
            effective_at=current,
            anchor_at=current,
            reason="saved_slot_passed_post_now",
        )

    return PublishDecision(
        action="schedule",
        effective_at=candidate,
        anchor_at=candidate,
        reason="schedule_saved_slot_from_anchor",
    )


def normalize_profile_identity(
    *,
    profile_key: str | None = None,
    profile_name: str | None = None,
    profile_directory: str | None = None,
    page_name: str | None = None,
) -> ProfileIdentity:
    key = (profile_key or "").strip() or None
    name = (profile_name or "").strip() or None
    directory = (profile_directory or "").strip() or None
    page = (page_name or "").strip() or None
    if not key:
        key = directory or (f"name::{name}" if name else "__default__")
    if page and "::page::" not in key:
        key = f"{key}::page::{page.casefold()}"
    return ProfileIdentity(profile_key=key, profile_name=name, profile_directory=directory, page_name=page)


def empty_state() -> dict:
    return {"schema_version": STATE_SCHEMA_VERSION, "profiles": {}, "history": []}


def empty_profile_state(identity: ProfileIdentity) -> dict:
    return {
        "profile_key": identity.profile_key,
        "profile_name": identity.profile_name,
        "profile_directory": identity.profile_directory,
        "page_name": identity.page_name,
        "interval_minutes": POST_INTERVAL_MINUTES,
        "last_anchor_at": None,
        "history": [],
    }


def annotate_history(entries: list[dict] | None, identity: ProfileIdentity) -> list[dict]:
    normalized_entries: list[dict] = []
    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        item = dict(entry)
        item.setdefault("profile_key", identity.profile_key)
        if identity.profile_name:
            item.setdefault("profile_name", identity.profile_name)
        if identity.profile_directory:
            item.setdefault("profile_directory", identity.profile_directory)
        if identity.page_name:
            item.setdefault("page_name", identity.page_name)
        normalized_entries.append(item)
    return normalized_entries


def copy_summary_fields(source: dict, target: dict) -> None:
    for field in SUMMARY_FIELDS:
        if field in source:
            target[field] = source[field]


def combined_history(profiles: dict[str, dict]) -> list[dict]:
    entries: list[dict] = []
    for profile_state in profiles.values():
        profile_history = profile_state.get("history", [])
        if isinstance(profile_history, list):
            entries.extend(item for item in profile_history if isinstance(item, dict))
    return sorted(entries, key=lambda item: item.get("recorded_at") or item.get("effective_at") or "")


def choose_last_profile_key(state: dict) -> str | None:
    profiles = state.get("profiles", {})
    if not isinstance(profiles, dict) or not profiles:
        return None

    last_profile_key = state.get("last_profile_key")
    if isinstance(last_profile_key, str) and last_profile_key in profiles:
        return last_profile_key

    history = state.get("history", [])
    if isinstance(history, list):
        for item in reversed(history):
            if not isinstance(item, dict):
                continue
            candidate = item.get("profile_key")
            if isinstance(candidate, str) and candidate in profiles:
                return candidate

    if len(profiles) == 1:
        return next(iter(profiles))

    keyed_profiles = sorted(
        profiles.items(),
        key=lambda item: item[1].get("last_anchor_at") or item[1].get("last_anchor_label") or "",
    )
    return keyed_profiles[-1][0] if keyed_profiles else None


def apply_root_summary_from_profile(state: dict, profile_state: dict) -> None:
    copy_summary_fields(profile_state, state)
    state["last_profile_key"] = profile_state.get("profile_key")
    state["last_profile_name"] = profile_state.get("profile_name")
    state["last_profile_directory"] = profile_state.get("profile_directory")
    state["last_page_name"] = profile_state.get("page_name")


def normalize_state(raw_state: dict | None, legacy_profile: ProfileIdentity | None = None) -> dict:
    if not isinstance(raw_state, dict):
        return empty_state()

    raw_profiles = raw_state.get("profiles")
    if not isinstance(raw_profiles, dict):
        identity = legacy_profile or normalize_profile_identity(profile_key="__legacy__", profile_name="Legacy")
        migrated_state = empty_state()
        migrated_profile = empty_profile_state(identity)
        copy_summary_fields(raw_state, migrated_profile)
        migrated_profile["history"] = annotate_history(raw_state.get("history", []), identity)
        migrated_state["profiles"][identity.profile_key] = migrated_profile
        migrated_state["history"] = list(migrated_profile["history"])
        apply_root_summary_from_profile(migrated_state, migrated_profile)
        migrated_state["schema_version"] = STATE_SCHEMA_VERSION
        return migrated_state

    state = empty_state()
    state["schema_version"] = raw_state.get("schema_version", STATE_SCHEMA_VERSION)

    normalized_profiles: dict[str, dict] = {}
    for fallback_key, value in raw_profiles.items():
        profile_value = value if isinstance(value, dict) else {}
        identity = normalize_profile_identity(
            profile_key=str(profile_value.get("profile_key") or fallback_key).strip() or None,
            profile_name=profile_value.get("profile_name"),
            profile_directory=profile_value.get("profile_directory"),
            page_name=profile_value.get("page_name"),
        )
        profile_state = empty_profile_state(identity)
        copy_summary_fields(profile_value, profile_state)
        profile_state["history"] = annotate_history(profile_value.get("history", []), identity)
        normalized_profiles[identity.profile_key] = profile_state

    state["profiles"] = normalized_profiles
    state["history"] = combined_history(normalized_profiles)

    selected_profile_key = choose_last_profile_key(
        {
            "profiles": normalized_profiles,
            "history": state["history"],
            "last_profile_key": raw_state.get("last_profile_key"),
        }
    )
    if selected_profile_key and selected_profile_key in normalized_profiles:
        apply_root_summary_from_profile(state, normalized_profiles[selected_profile_key])

    return state


def load_state(
    state_path: Path = DEFAULT_STATE_PATH,
    *,
    legacy_profile_key: str | None = None,
    legacy_profile_name: str | None = None,
    legacy_profile_directory: str | None = None,
) -> dict:
    if not state_path.exists():
        return empty_state()

    raw_state = json.loads(state_path.read_text(encoding="utf-8"))
    legacy_profile = None
    if legacy_profile_key or legacy_profile_name or legacy_profile_directory:
        legacy_profile = normalize_profile_identity(
            profile_key=legacy_profile_key,
            profile_name=legacy_profile_name,
            profile_directory=legacy_profile_directory,
        )
    return normalize_state(raw_state, legacy_profile=legacy_profile)


def save_state(state: dict, state_path: Path = DEFAULT_STATE_PATH) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")


def resolve_profile_key(state: dict, identity: ProfileIdentity) -> str:
    profiles = state.get("profiles", {})
    if not isinstance(profiles, dict):
        return identity.profile_key

    if identity.profile_key in profiles:
        return identity.profile_key

    target_page_name = normalized_page_name(identity.page_name)
    if target_page_name:
        for candidate_key, profile_state in profiles.items():
            if normalized_page_name(profile_state.get("page_name")) != target_page_name:
                continue
            if identity.profile_directory and profile_state.get("profile_directory") == identity.profile_directory:
                return candidate_key

        for candidate_key, profile_state in profiles.items():
            if normalized_page_name(profile_state.get("page_name")) != target_page_name:
                continue
            if identity.profile_name and profile_state.get("profile_name") == identity.profile_name:
                return candidate_key

        for candidate_key, profile_state in profiles.items():
            if normalized_page_name(profile_state.get("page_name")) == target_page_name:
                return candidate_key

        return identity.profile_key

    if identity.profile_directory:
        for candidate_key, profile_state in profiles.items():
            if profile_state.get("profile_directory") == identity.profile_directory:
                return candidate_key

    if identity.profile_name:
        for candidate_key, profile_state in profiles.items():
            if profile_state.get("profile_name") == identity.profile_name:
                return candidate_key

    return identity.profile_key


def ensure_profile_state(
    state: dict,
    *,
    profile_key: str | None = None,
    profile_name: str | None = None,
    profile_directory: str | None = None,
    page_name: str | None = None,
) -> dict:
    if "profiles" not in state or not isinstance(state.get("profiles"), dict):
        normalized = normalize_state(state)
        state.clear()
        state.update(normalized)

    identity = normalize_profile_identity(
        profile_key=profile_key,
        profile_name=profile_name,
        profile_directory=profile_directory,
        page_name=page_name,
    )
    resolved_key = resolve_profile_key(state, identity)
    profiles = state["profiles"]

    if resolved_key not in profiles:
        identity = normalize_profile_identity(
            profile_key=resolved_key,
            profile_name=profile_name,
            profile_directory=profile_directory,
            page_name=page_name,
        )
        profiles[resolved_key] = empty_profile_state(identity)

    profile_state = profiles[resolved_key]
    profile_state["profile_key"] = resolved_key
    if profile_name:
        profile_state["profile_name"] = profile_name
    profile_state.setdefault("profile_name", None)
    if profile_directory:
        profile_state["profile_directory"] = profile_directory
    profile_state.setdefault("profile_directory", None)
    if page_name:
        profile_state["page_name"] = page_name
    profile_state.setdefault("page_name", None)
    profile_state["interval_minutes"] = normalize_interval_minutes(profile_state.get("interval_minutes"))
    if not isinstance(profile_state.get("history"), list):
        profile_state["history"] = []
    return profile_state


def remembered_profile_for_page(state: dict, page_name: str | None) -> dict[str, str | None] | None:
    target_page_name = normalized_page_name(page_name)
    if not target_page_name:
        return None

    profiles = state.get("profiles", {})
    if not isinstance(profiles, dict):
        return None

    matches: list[dict] = []
    for profile_state in profiles.values():
        if normalized_page_name(profile_state.get("page_name")) != target_page_name:
            continue
        matches.append(profile_state)

    if not matches:
        return None

    matches.sort(
        key=lambda item: item.get("last_anchor_at")
        or item.get("next_slot_at")
        or item.get("last_anchor_label")
        or "",
    )
    remembered = matches[-1]
    return {
        "profile_key": remembered.get("profile_key"),
        "profile_name": remembered.get("profile_name"),
        "profile_directory": remembered.get("profile_directory"),
        "page_name": remembered.get("page_name"),
    }


def resolve_interval_minutes(profile_state: dict, override_minutes: int | None = None) -> int:
    if override_minutes is not None:
        interval = normalize_interval_minutes(override_minutes)
        profile_state["interval_minutes"] = interval
        return interval
    interval = normalize_interval_minutes(profile_state.get("interval_minutes"))
    profile_state["interval_minutes"] = interval
    return interval


def record_decision(
    *,
    package_name: str,
    decision: PublishDecision,
    state_path: Path = DEFAULT_STATE_PATH,
    profile_key: str | None = None,
    profile_name: str | None = None,
    profile_directory: str | None = None,
    page_name: str | None = None,
    interval_minutes: int | None = None,
) -> dict:
    state = load_state(state_path)
    profile_state = ensure_profile_state(
        state,
        profile_key=profile_key,
        profile_name=profile_name,
        profile_directory=profile_directory,
        page_name=page_name,
    )
    resolved_interval_minutes = resolve_interval_minutes(profile_state, interval_minutes)

    next_slot_at = add_minutes_with_day_rollover(decision.anchor_at, resolved_interval_minutes)
    moved_to_new_day = crosses_day_boundary(decision.anchor_at, next_slot_at)
    history_entry = {
        "package_name": package_name,
        "action": decision.action,
        "interval_minutes": resolved_interval_minutes,
        "effective_at": serialize_dt(decision.effective_at),
        "anchor_at": serialize_dt(decision.anchor_at),
        "reason": decision.reason,
        "effective_at_label_ampm": format_anchor_ampm(decision.effective_at),
        "recorded_at": serialize_dt(datetime.now().astimezone()),
        "profile_key": profile_state.get("profile_key"),
        "profile_name": profile_state.get("profile_name"),
        "profile_directory": profile_state.get("profile_directory"),
        "page_name": profile_state.get("page_name"),
    }
    profile_history = list(profile_state.get("history", []))
    profile_history.append(history_entry)
    profile_state["history"] = profile_history
    profile_state["last_anchor_at"] = serialize_dt(decision.anchor_at)
    profile_state["last_anchor_label"] = format_anchor(decision.anchor_at)
    profile_state["last_anchor_label_ampm"] = format_anchor_ampm(decision.anchor_at)
    profile_state["last_action"] = decision.action
    profile_state["last_package_name"] = package_name
    profile_state["interval_minutes"] = resolved_interval_minutes
    profile_state["next_slot_at"] = serialize_dt(next_slot_at)
    profile_state["next_slot_label"] = format_anchor(next_slot_at)
    profile_state["next_slot_label_ampm"] = format_anchor_ampm(next_slot_at)
    profile_state["next_slot_moves_to_new_day"] = moved_to_new_day

    state["history"] = combined_history(state["profiles"])
    apply_root_summary_from_profile(state, profile_state)
    state["schema_version"] = STATE_SCHEMA_VERSION
    save_state(state, state_path)
    return state
