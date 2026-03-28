#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import facebook_reels_api as facebook_api
import facebook_shared_queue
import fast_reels_batch as batch
import fb_reels_publish_timing as facebook_timing
from fb_reels_publish_timing import PublishDecision, record_decision, record_result
from soranin_paths import ROOT_DIR, mirrored_package_paths, runtime_data_file


FACEBOOK_STATUS_FILE_NAME = "facebook_reel_status.json"
FACEBOOK_HISTORY_FILE = runtime_data_file(".facebook_reels_history.jsonl")


@dataclass
class PackageUploadItem:
    package_path: Path
    package_name: str
    video_path: Path
    title: str
    schedule_text: str
    thumbnail_path: Path | None


def serialize_video_spec(spec: facebook_api.FacebookVideoSpec | None) -> dict[str, object] | None:
    if spec is None:
        return None
    return facebook_api.video_spec_to_payload(spec)


def status_print(message: str) -> None:
    print(message, flush=True)


def first_match(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text, flags=re.DOTALL)
    if not match:
        return None
    return match.group(1).strip()


def preferred_reels_base_name(package_path: Path) -> str:
    prefix = package_path.name.split("_", 1)[0]
    return f"Reels{prefix}" if prefix.isdigit() else "Reels"


def preferred_package_media(package_path: Path, preferred_names: list[str], extensions: set[str]) -> Path | None:
    for name in preferred_names:
        candidate = package_path / name
        if candidate.exists():
            return candidate
    for child in sorted(package_path.iterdir()):
        if child.is_file() and child.suffix.lower() in extensions:
            return child
    return None


def normalize_upload_title(text: str) -> str:
    repaired = repair_mojibake_title(text)
    return " ".join(repaired.split()).strip()


def repair_mojibake_title(title: str) -> str:
    if not any(marker in title for marker in ("ðŸ", "Ã", "â", "Â")):
        return title
    try:
        repaired = title.encode("latin-1").decode("utf-8")
    except UnicodeError:
        return title
    return repaired or title


def status_path_for_package(package_path: Path) -> Path:
    return package_path / FACEBOOK_STATUS_FILE_NAME


def load_package_facebook_status(package_path: Path) -> dict[str, object]:
    status_path = status_path_for_package(package_path)
    if not status_path.exists():
        return {}
    try:
        payload = json.loads(status_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def should_skip_existing_success(package_path: Path) -> bool:
    payload = load_package_facebook_status(package_path)
    state = str(payload.get("state") or "").strip().lower()
    return state in {"scheduled", "published"}


def load_package_item(package_name: str) -> PackageUploadItem:
    package_path = ROOT_DIR / package_name
    if not package_path.is_dir():
        raise facebook_api.FacebookReelsError(f"Package folder not found: {package_name}")

    html_path = package_path / "copy_title.html"
    if not html_path.exists():
        raise facebook_api.FacebookReelsError(f"copy_title.html not found in {package_name}")

    html_text = html_path.read_text(encoding="utf-8")
    video_path = preferred_package_media(
        package_path,
        [f"{preferred_reels_base_name(package_path)}.mp4", "edited_reel_9x16_hd_0.90x_15s.mp4"],
        {".mp4", ".mov", ".m4v", ".avi", ".mkv"},
    )
    if video_path is None or not video_path.exists():
        raise facebook_api.FacebookReelsError(f"Video file not found in {package_name}")

    title_text = first_match(html_text, r'<textarea id="titleField" readonly>(.*?)</textarea>') or ""
    schedule_text = (
        first_match(html_text, r'<input id="scheduleField" value="(.*?)" readonly>')
        or first_match(html_text, r"const SCHEDULE_TEXT = (.*?);")
        or ""
    )
    if schedule_text.startswith('"') and schedule_text.endswith('"'):
        try:
            schedule_text = json.loads(schedule_text)
        except Exception:
            schedule_text = schedule_text.strip('"')

    thumbnail_path = preferred_package_media(
        package_path,
        [f"{preferred_reels_base_name(package_path)}.jpg", "thumbnail_1080x1920.jpg"],
        {".jpg", ".jpeg", ".png"},
    )

    return PackageUploadItem(
        package_path=package_path,
        package_name=package_name,
        video_path=video_path,
        title=normalize_upload_title(html.unescape(title_text)),
        schedule_text=str(schedule_text).strip(),
        thumbnail_path=thumbnail_path,
    )


def append_history(entry: dict[str, object]) -> None:
    FACEBOOK_HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    with FACEBOOK_HISTORY_FILE.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


def write_success_status(package: PackageUploadItem, result: facebook_api.FacebookPublishResult) -> None:
    recorded_at = datetime.now(facebook_api.KHMER_TZ)
    payload: dict[str, object] = {
        "state": "scheduled" if result.scheduled else "published",
        "video_id": result.video_id,
        "page_id": result.page_id,
        "recorded_at": recorded_at.isoformat(timespec="seconds"),
        "title": package.title,
        "thumbnail_mode": "local_only",
        "upload_target": "facebook_reels",
        "video_spec": serialize_video_spec(result.video_spec),
        "facebook_status_response": result.status_response,
        "scheduled_confirmed_by_api": result.scheduled_confirmed_by_api,
        "scheduled_confirmation_note": result.scheduled_confirmation_note,
        "facebook_debug": result.facebook_debug,
        "facebook_debug_summary": result.facebook_debug_summary,
        "facebook_debug_warning": result.debug_warning,
    }
    if result.scheduled and result.scheduled_publish_time is not None:
        payload["scheduled_publish_time"] = datetime.fromtimestamp(
            result.scheduled_publish_time,
            tz=facebook_api.KHMER_TZ,
        ).isoformat(timespec="seconds")
    else:
        payload["published_at"] = recorded_at.isoformat(timespec="seconds")

    status_path = status_path_for_package(package.package_path)
    temp_path = status_path.with_suffix(status_path.suffix + ".tmp")
    temp_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    temp_path.replace(status_path)

    append_history(
        {
            "recorded_at": recorded_at.isoformat(timespec="seconds"),
            "package_name": package.package_name,
            "state": payload["state"],
            "video_id": result.video_id,
            "page_id": result.page_id,
            "scheduled_publish_time": payload.get("scheduled_publish_time"),
            "published_at": payload.get("published_at"),
            "title": package.title,
            "thumbnail_mode": "local_only",
            "upload_target": "facebook_reels",
            "video_spec": serialize_video_spec(result.video_spec),
            "facebook_status_response": result.status_response,
            "scheduled_confirmed_by_api": result.scheduled_confirmed_by_api,
            "scheduled_confirmation_note": result.scheduled_confirmation_note,
            "facebook_debug": result.facebook_debug,
            "facebook_debug_summary": result.facebook_debug_summary,
            "facebook_debug_warning": result.debug_warning,
        }
    )


def write_failure_status(
    package: PackageUploadItem,
    message: str,
    *,
    video_spec: facebook_api.FacebookVideoSpec | None = None,
    facebook_debug: dict[str, object] | None = None,
    facebook_debug_summary: str = "",
    debug_warning: str | None = None,
) -> None:
    recorded_at = datetime.now(facebook_api.KHMER_TZ)
    payload = {
        "state": "failed",
        "message": " ".join((message or "").split()).strip() or "Unknown Facebook upload error.",
        "recorded_at": recorded_at.isoformat(timespec="seconds"),
        "title": package.title,
        "thumbnail_mode": "local_only",
        "upload_target": "facebook_reels",
        "video_spec": serialize_video_spec(video_spec),
        "facebook_debug": facebook_debug,
        "facebook_debug_summary": facebook_debug_summary,
        "facebook_debug_warning": debug_warning,
    }
    status_path = status_path_for_package(package.package_path)
    temp_path = status_path.with_suffix(status_path.suffix + ".tmp")
    temp_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    temp_path.replace(status_path)
    append_history(
        {
            "recorded_at": recorded_at.isoformat(timespec="seconds"),
            "package_name": package.package_name,
            "state": "failed",
            "message": payload["message"],
            "title": package.title,
            "thumbnail_mode": "local_only",
            "upload_target": "facebook_reels",
            "video_spec": serialize_video_spec(video_spec),
            "facebook_debug": facebook_debug,
            "facebook_debug_summary": facebook_debug_summary,
            "facebook_debug_warning": debug_warning,
        }
    )


def maybe_delete_package_after_success(package: PackageUploadItem, enabled: bool, *, mode: str) -> None:
    if not enabled:
        return
    if mode == "schedule":
        status_print(f"[facebook-upload] Kept {package.package_name} after schedule success for post-publish verification")
        return
    deleted_any = False
    last_error: str | None = None
    for candidate in mirrored_package_paths(package.package_name, primary_path=package.package_path):
        if not candidate.exists() or not candidate.is_dir():
            continue
        try:
            shutil.rmtree(candidate)
            deleted_any = True
        except Exception as exc:
            last_error = str(exc)
    if not deleted_any and last_error:
        raise RuntimeError(last_error)
    status_print(f"[facebook-upload] Auto deleted {package.package_name}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Direct Facebook Reels publish/schedule using Page token.")
    parser.add_argument("packages", nargs="+", help="Package folder names under the Soranin packages root.")
    parser.add_argument("--mode", choices=("publish", "schedule"), required=True)
    parser.add_argument("--delete-after-success", action="store_true")
    parser.add_argument("--skip-existing-success", action="store_true")
    return parser.parse_args(argv)


def facebook_api_profile_identity(settings: facebook_api.FacebookSettings) -> dict[str, str]:
    return {
        "profile_key": f"facebook_api::{settings.page_id}",
        "profile_name": "Facebook API",
        "page_name": settings.page_id,
    }


def is_allowed_fixed_slot(candidate: datetime, morning_only: bool) -> bool:
    local = candidate.astimezone(facebook_api.KHMER_TZ)
    slot = (local.hour, local.minute)
    allowed = (
        facebook_timing.MORNING_ONLY_SLOT_TIMES
        if morning_only
        else facebook_timing.ALLOWED_SLOT_TIMES_SORTED
    )
    return slot in allowed


def resolve_scheduled_publish_time(
    package: PackageUploadItem,
    settings: facebook_api.FacebookSettings,
) -> tuple[int, PublishDecision, str, dict[str, object] | None]:
    now = datetime.now(facebook_api.KHMER_TZ)
    identity = facebook_api_profile_identity(settings)
    requested_dt = facebook_api.parse_schedule_text(package.schedule_text)
    requested_schedule_at = ""
    if requested_dt is not None:
        requested_schedule_at = facebook_timing.serialize_dt(
            facebook_timing.current_minute(requested_dt.astimezone(facebook_api.KHMER_TZ))
        )

    if facebook_shared_queue.shared_queue_enabled():
        try:
            shared = facebook_shared_queue.reserve_schedule(
                page_id=settings.page_id,
                package_name=package.package_name,
                requested_schedule_at=requested_schedule_at,
            )
        except Exception as exc:
            status_print(f"[facebook-upload] Shared queue unavailable for {settings.page_id}: {exc}")
        else:
            if isinstance(shared, dict):
                decision_payload = shared.get("decision")
                if isinstance(decision_payload, dict):
                    effective_at = facebook_timing.deserialize_dt(str(decision_payload.get("effective_at") or "").strip())
                    anchor_at = facebook_timing.deserialize_dt(str(decision_payload.get("anchor_at") or "").strip())
                    if effective_at is not None and anchor_at is not None:
                        decision = PublishDecision(
                            action="schedule",
                            effective_at=effective_at,
                            anchor_at=anchor_at,
                            reason=str(decision_payload.get("reason") or "shared_queue_schedule").strip(),
                            interval_shifts=int(decision_payload.get("interval_shifts") or 0),
                        )
                        return (
                            int(shared.get("scheduled_publish_time") or int(effective_at.timestamp())),
                            decision,
                            str(shared.get("summary") or "using shared queue").strip(),
                            {"mode": "shared_queue", "page_id": settings.page_id},
                        )

    state = facebook_timing.load_state()
    profile_state = facebook_timing.ensure_profile_state(state, **identity)
    morning_only = bool(profile_state.get("morning_only"))
    reserved_slots = facebook_timing._all_reserved_slots(state, now=now)
    reserved_keys = {facebook_timing.serialize_dt(slot) for slot in reserved_slots}

    schedule_issue = ""
    if requested_dt is not None:
        requested_dt = facebook_timing.current_minute(requested_dt.astimezone(facebook_api.KHMER_TZ))
        requested_ts = int(requested_dt.timestamp())
        requested_key = facebook_timing.serialize_dt(requested_dt)
        if not is_allowed_fixed_slot(requested_dt, morning_only):
            schedule_issue = "saved schedule is not on an allowed Khmer slot"
        elif requested_key in reserved_keys:
            schedule_issue = "saved schedule overlaps an already reserved slot"
        else:
            try:
                facebook_api.validate_scheduled_publish_time(requested_ts)
                return (
                    requested_ts,
                    PublishDecision(
                        action="schedule",
                        effective_at=requested_dt,
                        anchor_at=requested_dt,
                        reason="facebook_api_schedule_from_package",
                    ),
                    "using saved package schedule",
                    None,
                )
            except facebook_api.FacebookReelsError as exc:
                schedule_issue = str(exc)
    elif package.schedule_text.strip():
        schedule_issue = f"invalid saved schedule: {package.schedule_text.strip()}"
    else:
        schedule_issue = "package does not contain a saved schedule"

    decision = facebook_timing.decide_publish_action(
        now=now,
        last_anchor_at=facebook_timing.deserialize_dt(profile_state.get("last_anchor_at")),
        profile_state=profile_state,
        reserved_slots=reserved_slots,
    )
    summary = (
        f"fallback to next free Khmer slot {facebook_timing.format_anchor_ampm(decision.effective_at)}"
        f" because {schedule_issue}"
    )
    return int(decision.effective_at.timestamp()), decision, summary, None


def publish_packages(args: argparse.Namespace) -> int:
    settings = facebook_api.load_facebook_settings()
    if settings is None:
        raise facebook_api.FacebookReelsError("Save a Facebook Page ID and Page access token first.")

    package_names = list(dict.fromkeys(args.packages))
    total = len(package_names)
    success_count = 0
    failed_count = 0
    skipped_count = 0

    for index, package_name in enumerate(package_names, start=1):
        package = load_package_item(package_name)
        if args.skip_existing_success and should_skip_existing_success(package.package_path):
            skipped_count += 1
            status_print(f"[facebook-upload] Skipped {index}/{total} {package.package_name}: already published or scheduled")
            continue

        scheduled_publish_time: int | None = None
        decision: PublishDecision | None = None
        shared_queue_context: dict[str, object] | None = None
        video_spec: facebook_api.FacebookVideoSpec | None = None
        if args.mode == "schedule":
            scheduled_publish_time, decision, schedule_summary, shared_queue_context = resolve_scheduled_publish_time(
                package,
                settings,
            )
            status_print(f"[facebook-upload] Schedule {index}/{total} {package.package_name}: {schedule_summary}")

        status_print(f"[facebook-upload] Start {index}/{total} {package.package_name} {args.mode}")
        try:
            video_spec = facebook_api.probe_video_spec(package.video_path)
            facebook_api.validate_reels_video_spec(video_spec)
            status_print(f"[facebook-upload] Reels spec OK {package.package_name}: {facebook_api.format_video_spec_summary(video_spec)}")
            if package.thumbnail_path is not None:
                status_print(
                    f"[facebook-upload] Thumbnail local-only {package.package_name}: {package.thumbnail_path.name}"
                )
            else:
                status_print(f"[facebook-upload] Thumbnail local-only {package.package_name}: not found")
            result = facebook_api.publish_reel(
                package.video_path,
                settings,
                title=package.title,
                description=package.title,
                scheduled_publish_time=scheduled_publish_time,
                logger=status_print,
                upload_progress=lambda percent, idx=index, total_items=total, name=package.package_name: status_print(
                    f"[facebook-upload] Progress {percent}% ({idx}/{total_items}) {name}"
                ),
                validated_video_spec=video_spec,
            )
            write_success_status(package, result)
            if result.scheduled:
                if result.scheduled_confirmed_by_api is True:
                    status_print(
                        f"[facebook-upload] Schedule confirmed {index}/{total} {package.package_name}: "
                        f"{result.scheduled_confirmation_note or 'status check passed'}"
                    )
                elif result.scheduled_confirmed_by_api is False:
                    status_print(
                        f"[facebook-upload] Schedule not confirmed {index}/{total} {package.package_name}: "
                        f"{result.scheduled_confirmation_note or 'status check failed'}"
                    )
                elif result.scheduled_confirmation_note:
                    status_print(
                        f"[facebook-upload] Schedule check {index}/{total} {package.package_name}: "
                        f"{result.scheduled_confirmation_note}"
                    )
            if result.facebook_debug_summary:
                status_print(f"[facebook-upload] Debug {index}/{total} {package.package_name}: {result.facebook_debug_summary}")
            elif result.debug_warning:
                status_print(f"[facebook-upload] Debug {index}/{total} {package.package_name}: skipped ({result.debug_warning})")
            if decision is not None:
                if shared_queue_context and str(shared_queue_context.get("mode") or "") == "shared_queue":
                    try:
                        facebook_shared_queue.finalize_schedule(
                            page_id=settings.page_id,
                            package_name=package.package_name,
                            decision={
                                "action": decision.action,
                                "effective_at": facebook_timing.serialize_dt(decision.effective_at),
                                "anchor_at": facebook_timing.serialize_dt(decision.anchor_at),
                                "reason": decision.reason,
                                "interval_shifts": int(decision.interval_shifts),
                            },
                        )
                    except Exception as exc:
                        status_print(
                            f"[facebook-upload] Shared queue finalize warning {package.package_name}: {exc}"
                        )
                record_decision(
                    package_name=package.package_name,
                    decision=decision,
                    profile_key=f"facebook_api::{settings.page_id}",
                    profile_name="Facebook API",
                    page_name=settings.page_id,
                )
                if result.scheduled_publish_time is not None:
                    scheduled_label = facebook_timing.format_anchor_ampm(datetime.fromtimestamp(
                        result.scheduled_publish_time,
                        tz=facebook_api.KHMER_TZ,
                    ))
                else:
                    scheduled_label = package.schedule_text or "-"
                status_print(f"[facebook-upload] Scheduled {index}/{total} {package.package_name} -> {scheduled_label}")
            else:
                record_result(
                    package_name=package.package_name,
                    result="success",
                    note="facebook_api_publish_now",
                    profile_key=f"facebook_api::{settings.page_id}",
                    profile_name="Facebook API",
                    page_name=settings.page_id,
                    action="publish",
                )
                status_print(f"[facebook-upload] Published {index}/{total} {package.package_name}")
            maybe_delete_package_after_success(package, args.delete_after_success, mode=args.mode)
            success_count += 1
        except Exception as exc:
            failed_count += 1
            message = str(exc)
            write_failure_status(package, message, video_spec=video_spec)
            if decision is not None and shared_queue_context and str(shared_queue_context.get("mode") or "") == "shared_queue":
                try:
                    facebook_shared_queue.release_schedule(
                        page_id=settings.page_id,
                        anchor_at=facebook_timing.serialize_dt(decision.anchor_at),
                    )
                except Exception as release_exc:
                    status_print(
                        f"[facebook-upload] Shared queue release warning {package.package_name}: {release_exc}"
                    )
                try:
                    facebook_shared_queue.record_result(
                        page_id=settings.page_id,
                        package_name=package.package_name,
                        result="failed",
                        note=message,
                        action=args.mode,
                        effective_at=facebook_timing.serialize_dt(decision.effective_at),
                    )
                except Exception as result_exc:
                    status_print(
                        f"[facebook-upload] Shared queue result warning {package.package_name}: {result_exc}"
                    )
            record_result(
                package_name=package.package_name,
                result="failed",
                note=message,
                profile_key=f"facebook_api::{settings.page_id}",
                profile_name="Facebook API",
                page_name=settings.page_id,
                action=args.mode,
            )
            status_print(f"[facebook-upload] Failed {index}/{total} {package.package_name}: {message}")

    summary = (
        f"[facebook-upload] Summary mode={args.mode} success={success_count} "
        f"failed={failed_count} skipped={skipped_count}"
    )
    status_print(summary)
    return 0 if failed_count == 0 else 1


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    return publish_packages(args)


if __name__ == "__main__":
    raise SystemExit(main())
