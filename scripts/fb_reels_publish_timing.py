#!/usr/bin/env python3
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Literal
from zoneinfo import ZoneInfo

from soranin_paths import FACEBOOK_STATE_PATH


POST_INTERVAL_MINUTES = 30
MIN_SCHEDULE_LEAD_MINUTES = 30
DEFAULT_STATE_PATH = FACEBOOK_STATE_PATH
STATE_SCHEMA_VERSION = 6
MAX_RECENT_RESULTS = 20
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
    "reserved_until_at",
    "reserved_until_label",
    "reserved_until_label_ampm",
    "today_remaining_slots",
    "morning_only",
)


Action = Literal["schedule", "post_now"]
ResultStatus = Literal["success", "failed", "stopped"]

# The fixed Khmer slot list requested by the user.
ALLOWED_SLOT_TIMES = (
    (19, 0),
    (20, 0),
    (21, 0),
    (22, 0),
    (23, 0),
    (0, 0),
    (1, 0),
    (2, 0),
    (3, 0),
    (4, 0),
    (5, 0),
    (5, 30),
    (6, 0),
    (6, 30),
    (7, 0),
    (7, 30),
    (8, 0),
    (8, 30),
    (9, 0),
    (9, 30),
)
ALLOWED_SLOT_TIMES_SORTED = tuple(sorted(ALLOWED_SLOT_TIMES, key=lambda item: item[0] * 60 + item[1]))
MORNING_ONLY_SLOT_TIMES = tuple(item for item in ALLOWED_SLOT_TIMES_SORTED if item[0] < 10)
KHMER_TZ = ZoneInfo("Asia/Phnom_Penh")


def now_khmer() -> datetime:
    return datetime.now(KHMER_TZ)


def to_khmer(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=KHMER_TZ)
    return dt.astimezone(KHMER_TZ)


def khmer_offset_label(dt: datetime) -> str:
    offset = to_khmer(dt).strftime("%z")
    return f"{offset[:3]}:{offset[3:]}" if offset else "+07:00"


def khmer_day_period(dt: datetime) -> str:
    hour = to_khmer(dt).hour
    if hour < 5:
        return "យប់"
    if hour < 12:
        return "ព្រឹក"
    if hour < 17:
        return "រសៀល"
    return "ល្ងាច"


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
    return to_khmer(dt).replace(second=0, microsecond=0)


def format_anchor(dt: datetime) -> str:
    local = current_minute(dt)
    return f"{local.strftime('%Y-%m-%d')} ម៉ោង {local.strftime('%H:%M')} ({khmer_offset_label(local)})"


def format_anchor_ampm(dt: datetime) -> str:
    local = current_minute(dt)
    hour_label = local.strftime("%I:%M").lstrip("0") or "0:00"
    return f"{local.strftime('%Y-%m-%d')} ម៉ោង {hour_label} {khmer_day_period(local)} ({khmer_offset_label(local)})"


def serialize_dt(dt: datetime) -> str:
    return to_khmer(dt).isoformat()


def deserialize_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=KHMER_TZ)
    return parsed.astimezone(KHMER_TZ)


def add_minutes_with_day_rollover(anchor_at: datetime, minutes: int) -> datetime:
    return to_khmer(anchor_at) + timedelta(minutes=minutes)


def crosses_day_boundary(start: datetime, end: datetime) -> bool:
    return to_khmer(start).date() != to_khmer(end).date()


def _allowed_slot_times(morning_only: bool) -> tuple[tuple[int, int], ...]:
    return MORNING_ONLY_SLOT_TIMES if morning_only else ALLOWED_SLOT_TIMES_SORTED


def _slot_datetime(reference: datetime, hour: int, minute: int) -> datetime:
    local = to_khmer(reference)
    return local.replace(hour=hour, minute=minute, second=0, microsecond=0)


def _iter_allowed_slots(
    *,
    start: datetime,
    morning_only: bool,
    days: int = 7,
) -> list[datetime]:
    local = current_minute(start)
    times = _allowed_slot_times(morning_only)
    slots: list[datetime] = []
    for day_offset in range(days):
        base_day = local + timedelta(days=day_offset)
        for hour, minute in times:
            slots.append(_slot_datetime(base_day, hour, minute))
    return slots


def _normalize_reserved_slots(profile_state: dict, now: datetime | None = None) -> list[datetime]:
    now_floor = current_minute(now or now_khmer())
    reserved: list[datetime] = []
    for raw in profile_state.get("reserved_slots", []) or []:
        candidate = deserialize_dt(raw)
        if candidate is None:
            continue
        slot = current_minute(candidate)
        if slot < now_floor:
            continue
        reserved.append(slot)
    reserved = sorted({slot for slot in reserved})
    profile_state["reserved_slots"] = [serialize_dt(slot) for slot in reserved]
    return reserved


def _normalize_reserved_slot_values(values: list[object] | None, now: datetime | None = None) -> list[datetime]:
    now_floor = current_minute(now or now_khmer())
    reserved: list[datetime] = []
    for raw in values or []:
        candidate = deserialize_dt(str(raw) if raw is not None else None)
        if candidate is None:
            continue
        slot = current_minute(candidate)
        if slot < now_floor:
            continue
        reserved.append(slot)
    return sorted({slot for slot in reserved})


def _all_reserved_slots(state: dict, now: datetime | None = None) -> list[datetime]:
    profiles = state.get("profiles", {}) if isinstance(state, dict) else {}
    if not isinstance(profiles, dict):
        return []
    combined: list[object] = []
    for profile_state in profiles.values():
        if not isinstance(profile_state, dict):
            continue
        combined.extend(profile_state.get("reserved_slots", []) or [])
    return _normalize_reserved_slot_values(combined, now=now)


def _reserved_slot_key(slot: datetime) -> str:
    return serialize_dt(current_minute(slot))


def _next_free_allowed_slot(
    *,
    start: datetime,
    reserved_slots: list[datetime],
    morning_only: bool,
    min_schedule_lead_minutes: int,
) -> tuple[datetime, int]:
    earliest = current_minute(start) + timedelta(minutes=max(0, min_schedule_lead_minutes))
    reserved_keys = {_reserved_slot_key(slot) for slot in reserved_slots}
    interval_shifts = 0
    for candidate in _iter_allowed_slots(start=earliest, morning_only=morning_only, days=10):
        if candidate < earliest:
            continue
        if _reserved_slot_key(candidate) in reserved_keys:
            interval_shifts += 1
            continue
        return candidate, interval_shifts
    raise RuntimeError("Could not find a free allowed Facebook schedule slot.")


def _project_future_slots(
    *,
    start: datetime,
    reserved_slots: list[datetime],
    morning_only: bool,
    count: int,
    min_schedule_lead_minutes: int = MIN_SCHEDULE_LEAD_MINUTES,
) -> list[datetime]:
    if count <= 0:
        return []

    working_reserved = sorted({current_minute(slot) for slot in reserved_slots})
    projected: list[datetime] = []
    pointer = current_minute(start)
    lead_minutes = min_schedule_lead_minutes
    for _ in range(count):
        next_slot, _ = _next_free_allowed_slot(
            start=pointer,
            reserved_slots=working_reserved,
            morning_only=morning_only,
            min_schedule_lead_minutes=lead_minutes,
        )
        projected.append(next_slot)
        working_reserved.append(next_slot)
        working_reserved.sort()
        pointer = next_slot + timedelta(minutes=1)
        lead_minutes = 0
    return projected


def _today_remaining_slots(
    *,
    now: datetime,
    reserved_slots: list[datetime],
    morning_only: bool,
    min_schedule_lead_minutes: int,
) -> int:
    earliest = current_minute(now) + timedelta(minutes=max(0, min_schedule_lead_minutes))
    reserved_keys = {_reserved_slot_key(slot) for slot in reserved_slots}
    count = 0
    for candidate in _iter_allowed_slots(start=earliest, morning_only=morning_only, days=1):
        if candidate.date() != earliest.date():
            continue
        if candidate < earliest:
            continue
        if _reserved_slot_key(candidate) in reserved_keys:
            continue
        count += 1
    return count


def advance_schedule_slot(
    scheduled_at: datetime,
    *,
    interval_minutes: int,
    not_before: datetime | None = None,
) -> tuple[datetime, int]:
    candidate = current_minute(to_khmer(scheduled_at))
    target = current_minute(to_khmer(not_before)) if not_before is not None else None
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
    profile_state: dict | None = None,
    reserved_slots: list[datetime] | None = None,
) -> PublishDecision:
    current = current_minute(to_khmer(now))

    if profile_state is None:
        if last_anchor_at is None:
            return PublishDecision(
                action="schedule",
                effective_at=current + timedelta(minutes=min_schedule_lead_minutes),
                anchor_at=current + timedelta(minutes=min_schedule_lead_minutes),
                reason="legacy_schedule_first_item",
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

    effective_reserved_slots = (
        _normalize_reserved_slot_values([serialize_dt(slot) for slot in reserved_slots], now=current)
        if reserved_slots is not None
        else _normalize_reserved_slots(profile_state, now=current)
    )
    morning_only = bool(profile_state.get("morning_only"))
    next_slot, interval_shifts = _next_free_allowed_slot(
        start=current,
        reserved_slots=effective_reserved_slots,
        morning_only=morning_only,
        min_schedule_lead_minutes=min_schedule_lead_minutes,
    )
    return PublishDecision(
        action="schedule",
        effective_at=next_slot,
        anchor_at=next_slot,
        reason="schedule_next_allowed_fixed_slot",
        interval_shifts=interval_shifts,
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
        "recent_results": [],
        "reserved_slots": [],
        "morning_only": False,
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


def normalize_recent_results(entries: list[dict] | None, identity: ProfileIdentity) -> list[dict]:
    results: list[dict] = []
    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        item = dict(entry)
        item.setdefault("profile_key", identity.profile_key)
        item.setdefault("profile_name", identity.profile_name)
        item.setdefault("profile_directory", identity.profile_directory)
        item.setdefault("page_name", identity.page_name)
        results.append(item)
    results.sort(key=lambda item: item.get("recorded_at") or item.get("effective_at") or "", reverse=True)
    return results[:MAX_RECENT_RESULTS]


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
        key=lambda item: item[1].get("last_anchor_at") or item[1].get("next_slot_at") or "",
    )
    return keyed_profiles[-1][0] if keyed_profiles else None


def apply_root_summary_from_profile(state: dict, profile_state: dict) -> None:
    copy_summary_fields(profile_state, state)
    state["last_profile_key"] = profile_state.get("profile_key")
    state["last_profile_name"] = profile_state.get("profile_name")
    state["last_profile_directory"] = profile_state.get("profile_directory")
    state["last_page_name"] = profile_state.get("page_name")


def _queue_status(
    profile_state: dict,
    *,
    now: datetime | None = None,
    package_count: int = 0,
    reserved_slots: list[datetime] | None = None,
) -> dict[str, object]:
    reference = current_minute(now or now_khmer())
    effective_reserved_slots = (
        _normalize_reserved_slot_values([serialize_dt(slot) for slot in reserved_slots], now=reference)
        if reserved_slots is not None
        else _normalize_reserved_slots(profile_state, now=reference)
    )
    morning_only = bool(profile_state.get("morning_only"))
    next_queue_at, _ = _next_free_allowed_slot(
        start=reference,
        reserved_slots=effective_reserved_slots,
        morning_only=morning_only,
        min_schedule_lead_minutes=MIN_SCHEDULE_LEAD_MINUTES,
    )
    today_remaining_slots = _today_remaining_slots(
        now=reference,
        reserved_slots=effective_reserved_slots,
        morning_only=morning_only,
        min_schedule_lead_minutes=MIN_SCHEDULE_LEAD_MINUTES,
    )
    future_reserved = sorted(slot for slot in effective_reserved_slots if slot >= reference)
    reserved_until = future_reserved[-1] if future_reserved else None
    current_projection = _project_future_slots(
        start=reference,
        reserved_slots=effective_reserved_slots,
        morning_only=morning_only,
        count=max(0, package_count),
    )
    projection_40 = _project_future_slots(
        start=reference,
        reserved_slots=effective_reserved_slots,
        morning_only=morning_only,
        count=40,
    )
    projection_80 = _project_future_slots(
        start=reference,
        reserved_slots=effective_reserved_slots,
        morning_only=morning_only,
        count=80,
    )
    recent_results = normalize_recent_results(
        profile_state.get("recent_results", []),
        normalize_profile_identity(
            profile_key=profile_state.get("profile_key"),
            profile_name=profile_state.get("profile_name"),
            profile_directory=profile_state.get("profile_directory"),
            page_name=profile_state.get("page_name"),
        ),
    )

    return {
        "morning_only": morning_only,
        "today_remaining_slots": today_remaining_slots,
        "next_queue_at": serialize_dt(next_queue_at),
        "next_queue_label": format_anchor(next_queue_at),
        "next_queue_label_ampm": format_anchor_ampm(next_queue_at),
        "reserved_slots": [serialize_dt(slot) for slot in future_reserved],
        "reserved_count": len(future_reserved),
        "reserved_until_at": serialize_dt(reserved_until) if reserved_until else None,
        "reserved_until_label": format_anchor(reserved_until) if reserved_until else None,
        "reserved_until_label_ampm": format_anchor_ampm(reserved_until) if reserved_until else None,
        "current_edited_end_at": serialize_dt(current_projection[-1]) if current_projection else None,
        "current_edited_end_label_ampm": format_anchor_ampm(current_projection[-1]) if current_projection else None,
        "videos_40_end_at": serialize_dt(projection_40[-1]) if projection_40 else None,
        "videos_40_end_label_ampm": format_anchor_ampm(projection_40[-1]) if projection_40 else None,
        "videos_80_end_at": serialize_dt(projection_80[-1]) if projection_80 else None,
        "videos_80_end_label_ampm": format_anchor_ampm(projection_80[-1]) if projection_80 else None,
        "recent_results": recent_results,
    }


def _refresh_profile_summary(
    profile_state: dict,
    *,
    now: datetime | None = None,
    package_count: int = 0,
    reserved_slots: list[datetime] | None = None,
) -> dict[str, object]:
    summary = _queue_status(
        profile_state,
        now=now,
        package_count=package_count,
        reserved_slots=reserved_slots,
    )
    profile_state["reserved_slots"] = summary["reserved_slots"]
    profile_state["morning_only"] = summary["morning_only"]
    profile_state["today_remaining_slots"] = summary["today_remaining_slots"]
    profile_state["next_slot_at"] = summary["next_queue_at"]
    profile_state["next_slot_label"] = summary["next_queue_label"]
    profile_state["next_slot_label_ampm"] = summary["next_queue_label_ampm"]
    last_anchor = deserialize_dt(profile_state.get("last_anchor_at"))
    next_slot = deserialize_dt(summary["next_queue_at"])
    profile_state["next_slot_moves_to_new_day"] = bool(
        last_anchor and next_slot and crosses_day_boundary(last_anchor, next_slot)
    )
    profile_state["reserved_until_at"] = summary["reserved_until_at"]
    profile_state["reserved_until_label"] = summary["reserved_until_label"]
    profile_state["reserved_until_label_ampm"] = summary["reserved_until_label_ampm"]
    profile_state["recent_results"] = summary["recent_results"]
    return summary


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
        migrated_profile["recent_results"] = normalize_recent_results(raw_state.get("recent_results", []), identity)
        if isinstance(raw_state.get("reserved_slots"), list):
            migrated_profile["reserved_slots"] = list(raw_state.get("reserved_slots") or [])
        migrated_profile["morning_only"] = bool(raw_state.get("morning_only"))
        _refresh_profile_summary(migrated_profile)
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
        profile_state["recent_results"] = normalize_recent_results(profile_value.get("recent_results", []), identity)
        profile_state["reserved_slots"] = list(profile_value.get("reserved_slots", []) or [])
        profile_state["morning_only"] = bool(profile_value.get("morning_only"))
        _refresh_profile_summary(profile_state)
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
    if not isinstance(profile_state.get("recent_results"), list):
        profile_state["recent_results"] = []
    if not isinstance(profile_state.get("reserved_slots"), list):
        profile_state["reserved_slots"] = []
    profile_state["morning_only"] = bool(profile_state.get("morning_only"))
    _refresh_profile_summary(profile_state)
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


def queue_status(
    state: dict,
    *,
    profile_key: str | None = None,
    profile_name: str | None = None,
    profile_directory: str | None = None,
    page_name: str | None = None,
    package_count: int = 0,
    now: datetime | None = None,
) -> dict[str, object]:
    profile_state = ensure_profile_state(
        state,
        profile_key=profile_key,
        profile_name=profile_name,
        profile_directory=profile_directory,
        page_name=page_name,
    )
    global_reserved_slots = _all_reserved_slots(state, now=now)
    summary = _refresh_profile_summary(
        profile_state,
        now=now,
        package_count=package_count,
        reserved_slots=global_reserved_slots,
    )
    summary["profile_key"] = profile_state.get("profile_key")
    summary["profile_name"] = profile_state.get("profile_name")
    summary["profile_directory"] = profile_state.get("profile_directory")
    summary["page_name"] = profile_state.get("page_name")
    summary["interval_minutes"] = profile_state.get("interval_minutes")
    return summary


def _append_recent_result(
    profile_state: dict,
    *,
    package_name: str,
    result: ResultStatus,
    note: str,
    effective_at: datetime | None = None,
    action: str | None = None,
) -> None:
    recent_results = list(profile_state.get("recent_results", []))
    entry = {
        "package_name": package_name,
        "result": result,
        "note": note,
        "action": action or "",
        "effective_at": serialize_dt(effective_at) if effective_at is not None else None,
        "effective_label_ampm": format_anchor_ampm(effective_at) if effective_at is not None else None,
        "recorded_at": serialize_dt(now_khmer()),
        "profile_key": profile_state.get("profile_key"),
        "profile_name": profile_state.get("profile_name"),
        "profile_directory": profile_state.get("profile_directory"),
        "page_name": profile_state.get("page_name"),
    }
    recent_results.insert(0, entry)
    profile_state["recent_results"] = recent_results[:MAX_RECENT_RESULTS]


def record_result(
    *,
    package_name: str,
    result: ResultStatus,
    note: str,
    state_path: Path = DEFAULT_STATE_PATH,
    profile_key: str | None = None,
    profile_name: str | None = None,
    profile_directory: str | None = None,
    page_name: str | None = None,
    effective_at: datetime | None = None,
    action: str | None = None,
) -> dict:
    state = load_state(state_path)
    profile_state = ensure_profile_state(
        state,
        profile_key=profile_key,
        profile_name=profile_name,
        profile_directory=profile_directory,
        page_name=page_name,
    )
    _append_recent_result(
        profile_state,
        package_name=package_name,
        result=result,
        note=note,
        effective_at=effective_at,
        action=action,
    )
    _refresh_profile_summary(profile_state)
    state["history"] = combined_history(state["profiles"])
    apply_root_summary_from_profile(state, profile_state)
    state["schema_version"] = STATE_SCHEMA_VERSION
    save_state(state, state_path)
    return state


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
    reserved_slots = _all_reserved_slots(state)
    anchor_slot = current_minute(decision.anchor_at)
    if anchor_slot not in reserved_slots:
        reserved_slots.append(anchor_slot)
        reserved_slots.sort()
    profile_state["reserved_slots"] = [serialize_dt(slot) for slot in reserved_slots]

    history_entry = {
        "package_name": package_name,
        "action": decision.action,
        "interval_minutes": resolved_interval_minutes,
        "effective_at": serialize_dt(decision.effective_at),
        "anchor_at": serialize_dt(decision.anchor_at),
        "reason": decision.reason,
        "effective_at_label_ampm": format_anchor_ampm(decision.effective_at),
        "recorded_at": serialize_dt(now_khmer()),
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
    _append_recent_result(
        profile_state,
        package_name=package_name,
        result="success",
        note=decision.reason,
        effective_at=decision.effective_at,
        action=decision.action,
    )

    _refresh_profile_summary(profile_state, reserved_slots=reserved_slots)

    state["history"] = combined_history(state["profiles"])
    apply_root_summary_from_profile(state, profile_state)
    state["schema_version"] = STATE_SCHEMA_VERSION
    save_state(state, state_path)
    return state


def reserve_anchor(
    *,
    anchor_at: datetime,
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
    reserved_slots = _all_reserved_slots(state)
    anchor_slot = current_minute(anchor_at)
    if anchor_slot not in reserved_slots:
        reserved_slots.append(anchor_slot)
        reserved_slots.sort()
    profile_state["reserved_slots"] = [serialize_dt(slot) for slot in reserved_slots]
    profile_state["interval_minutes"] = resolved_interval_minutes
    _refresh_profile_summary(profile_state, reserved_slots=reserved_slots)
    state["history"] = combined_history(state["profiles"])
    apply_root_summary_from_profile(state, profile_state)
    state["schema_version"] = STATE_SCHEMA_VERSION
    save_state(state, state_path)
    return state


def release_anchor(
    *,
    anchor_at: datetime,
    state_path: Path = DEFAULT_STATE_PATH,
    profile_key: str | None = None,
    profile_name: str | None = None,
    profile_directory: str | None = None,
    page_name: str | None = None,
) -> dict:
    state = load_state(state_path)
    anchor_key = serialize_dt(current_minute(anchor_at))
    profiles = state.get("profiles", {})
    if isinstance(profiles, dict):
        for profile_state in profiles.values():
            if not isinstance(profile_state, dict):
                continue
            slots = [
                raw
                for raw in list(profile_state.get("reserved_slots", []) or [])
                if str(raw or "").strip() != anchor_key
            ]
            profile_state["reserved_slots"] = slots
            _refresh_profile_summary(profile_state)
    state["history"] = combined_history(state.get("profiles", {}))
    if profiles:
        selected_key = choose_last_profile_key(
            {
                "profiles": profiles,
                "history": state["history"],
                "last_profile_key": profile_key,
            }
        )
        if isinstance(selected_key, str) and selected_key in profiles:
            apply_root_summary_from_profile(state, profiles[selected_key])
        else:
            profile_state = ensure_profile_state(
                state,
                profile_key=profile_key,
                profile_name=profile_name,
                profile_directory=profile_directory,
                page_name=page_name,
            )
            apply_root_summary_from_profile(state, profile_state)
    state["schema_version"] = STATE_SCHEMA_VERSION
    save_state(state, state_path)
    return state


def clear_queue(
    *,
    state_path: Path = DEFAULT_STATE_PATH,
    profile_key: str | None = None,
    profile_name: str | None = None,
    profile_directory: str | None = None,
    page_name: str | None = None,
) -> dict:
    state = load_state(state_path)
    profile_state = ensure_profile_state(
        state,
        profile_key=profile_key,
        profile_name=profile_name,
        profile_directory=profile_directory,
        page_name=page_name,
    )
    profile_state["reserved_slots"] = []
    _refresh_profile_summary(profile_state)
    state["history"] = combined_history(state["profiles"])
    apply_root_summary_from_profile(state, profile_state)
    save_state(state, state_path)
    return state


def reset_times(
    *,
    state_path: Path = DEFAULT_STATE_PATH,
    profile_key: str | None = None,
    profile_name: str | None = None,
    profile_directory: str | None = None,
    page_name: str | None = None,
) -> dict:
    state = load_state(state_path)
    profile_state = ensure_profile_state(
        state,
        profile_key=profile_key,
        profile_name=profile_name,
        profile_directory=profile_directory,
        page_name=page_name,
    )
    profile_state["reserved_slots"] = []
    profile_state["last_anchor_at"] = None
    profile_state["last_anchor_label"] = None
    profile_state["last_anchor_label_ampm"] = None
    profile_state["last_action"] = None
    profile_state["last_package_name"] = None
    _refresh_profile_summary(profile_state)
    state["history"] = combined_history(state["profiles"])
    apply_root_summary_from_profile(state, profile_state)
    save_state(state, state_path)
    return state


def set_morning_only(
    enabled: bool,
    *,
    state_path: Path = DEFAULT_STATE_PATH,
    profile_key: str | None = None,
    profile_name: str | None = None,
    profile_directory: str | None = None,
    page_name: str | None = None,
) -> dict:
    state = load_state(state_path)
    profile_state = ensure_profile_state(
        state,
        profile_key=profile_key,
        profile_name=profile_name,
        profile_directory=profile_directory,
        page_name=page_name,
    )
    profile_state["morning_only"] = bool(enabled)
    _refresh_profile_summary(profile_state)
    state["history"] = combined_history(state["profiles"])
    apply_root_summary_from_profile(state, profile_state)
    save_state(state, state_path)
    return state
