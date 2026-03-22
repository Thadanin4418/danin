#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import importlib.util
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

from soranin_paths import DEFAULT_FACEBOOK_PACKAGE, FACEBOOK_STATE_PATH, script_path


STEP3_SCRIPT = script_path("fb_reels_step3_upload_video_and_next.py")
TIMING_SCRIPT = script_path("fb_reels_publish_timing.py")
DEFAULT_PACKAGE = DEFAULT_FACEBOOK_PACKAGE


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Step 6 for Facebook Reels upload: decide whether to schedule or post now using rolling interval timing."
    )
    parser.add_argument(
        "package_dir",
        nargs="?",
        default=str(DEFAULT_PACKAGE),
        help="Path to the numbered Reels package folder.",
    )
    parser.add_argument("--timeout", type=float, default=20.0, help="Timeout in seconds for UI transitions.")
    parser.add_argument(
        "--state-path",
        default=str(FACEBOOK_STATE_PATH),
        help="JSON state file used to remember the last schedule/post anchor time.",
    )
    parser.add_argument(
        "--close-after-finish",
        action="store_true",
        help="Quit Google Chrome completely after the schedule/post step finishes.",
    )
    parser.add_argument(
        "--force-post-now",
        action="store_true",
        help="Publish immediately for testing, regardless of the saved schedule slot.",
    )
    parser.add_argument(
        "--post-now-advance-slot",
        action="store_true",
        help="Publish immediately, but keep the saved queue moving forward by the next computed slot.",
    )
    parser.add_argument(
        "--page-name",
        default="",
        help="Optional Facebook profile/page name to use for timing state.",
    )
    parser.add_argument(
        "--interval-minutes",
        type=int,
        default=0,
        help="Optional interval in minutes for the next slot on this page/profile. Example: 30 or 60.",
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


def update_schedule_field(html_path: Path, schedule_text: str) -> bool:
    if not html_path.exists():
        return False
    content = html_path.read_text(encoding="utf-8")
    updated = re.sub(
        r'(<input id="scheduleField" value=")([^"]*)(" readonly>)',
        lambda match: match.group(1) + html.escape(schedule_text, quote=True) + match.group(3),
        content,
        count=1,
    )
    html_path.write_text(updated, encoding="utf-8")
    return True


def format_fb_date(dt: datetime) -> str:
    return f"{dt.strftime('%b')} {dt.day}, {dt.year}"


def format_fb_time(dt: datetime) -> str:
    hour12 = dt.hour % 12 or 12
    meridiem = "AM" if dt.hour < 12 else "PM"
    return f"{hour12}:{dt.minute:02d} {meridiem}"


def body_text(step3, limit: int = 20000) -> str:
    return step3.tab_js(f"document.body ? document.body.innerText.slice(0, {limit}) : ''")


def wait_for_text(step3, snippets: list[str], timeout_seconds: float) -> str:
    return step3.wait_for_text(snippets, timeout_seconds)


def wait_for_dialog_close(step3, timeout_seconds: float) -> str:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        text = body_text(step3)
        if "Reel settings" not in text and "Scheduling options" not in text and "Content Library" in text:
            return "dialog_closed"
        for snippet in ("Reel scheduled", "Planner", "Scheduled posts"):
            if snippet in text:
                return snippet
        time.sleep(0.18)
    raise RuntimeError("Timed out waiting for the reel composer dialog to close.")


def on_schedule_panel(step3) -> bool:
    text = body_text(step3)
    return "Schedule for later" in text and "Date" in text and "Time" in text


def on_reel_settings(step3) -> bool:
    text = body_text(step3)
    return "Reel settings" in text and ("Post" in text or "Schedule" in text)


def reel_settings_item_visible(step3, label: str) -> bool:
    expression = f"""(() => {{
  const normalize = (value) => String(value || '').replace(/[\\u200b\\ufeff]/g, '').replace(/\\s+/g, ' ').trim().toLowerCase();
  const wanted = {json.dumps(label.strip().lower())};
  const isVisible = (el) => {{
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  }};
  return [...document.querySelectorAll('[role="button"],button,a,div,span')].some((el) => {{
    if (!isVisible(el)) return false;
    const text = normalize(el.innerText);
    const aria = normalize(el.getAttribute('aria-label'));
    return text.includes(wanted) || aria.includes(wanted);
  }});
}})()"""
    return step3.tab_js(expression).strip().lower() == "true"


def scroll_reel_settings_panel(step3, label: str) -> dict[str, object]:
    expression = f"""(() => {{
  const normalize = (value) => String(value || '').replace(/[\\u200b\\ufeff]/g, '').replace(/\\s+/g, ' ').trim().toLowerCase();
  const wanted = {json.dumps(label.strip().lower())};
  const isVisible = (el) => {{
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  }};
  const labelVisible = [...document.querySelectorAll('[role="button"],button,a,div,span')].some((el) => {{
    if (!isVisible(el)) return false;
    const text = normalize(el.innerText);
    const aria = normalize(el.getAttribute('aria-label'));
    return text.includes(wanted) || aria.includes(wanted);
  }});
  if (labelVisible) return JSON.stringify({{ visible: true, scrolled: false, atEnd: false }});

  const dialog = [...document.querySelectorAll('[role="dialog"], [aria-modal="true"]')]
    .filter((el) => isVisible(el))
    .sort((a, b) => (b.getBoundingClientRect().height * b.getBoundingClientRect().width) - (a.getBoundingClientRect().height * a.getBoundingClientRect().width))[0]
    || document.body;

  const scrollers = [dialog, ...dialog.querySelectorAll('*')]
    .filter((el) => isVisible(el))
    .filter((el) => (el.scrollHeight - el.clientHeight) > 80)
    .sort((a, b) => (b.scrollHeight - b.clientHeight) - (a.scrollHeight - a.clientHeight));

  if (!scrollers.length) {{
    return JSON.stringify({{ visible: false, scrolled: false, atEnd: true }});
  }}

  const scroller = scrollers[0];
  const maxScrollTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
  const before = scroller.scrollTop;
  const delta = Math.max(260, Math.floor(scroller.clientHeight * 0.55));
  const after = Math.min(maxScrollTop, before + delta);
  scroller.scrollTop = after;
  scroller.dispatchEvent(new Event('scroll', {{ bubbles: true }}));

  return JSON.stringify({{
    visible: false,
    scrolled: after > before,
    atEnd: after >= maxScrollTop - 4,
    before,
    after,
    maxScrollTop
  }});
}})()"""
    return json.loads(step3.tab_js(expression))


def reveal_reel_settings_item(step3, label: str, timeout_seconds: float) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if reel_settings_item_visible(step3, label):
            return
        payload = scroll_reel_settings_panel(step3, label)
        if payload.get("visible"):
            return
        if not payload.get("scrolled") and payload.get("atEnd"):
            break
        time.sleep(0.22)
    raise RuntimeError(f'Could not reveal "{label}" inside Reel settings.')


def open_schedule_panel(step3, timeout_seconds: float) -> None:
    if on_schedule_panel(step3):
        return
    if not on_reel_settings(step3):
        raise RuntimeError("Expected Reel settings before opening Scheduling options.")
    reveal_reel_settings_item(step3, "Scheduling options", timeout_seconds)
    if not step3.click_exact("Scheduling options", contains=True):
        step3.real_click_label("Scheduling options", contains=True)
    wait_for_text(step3, ["Schedule for later", "Date", "Time"], timeout_seconds)


def close_schedule_panel(step3, timeout_seconds: float) -> None:
    if not on_schedule_panel(step3):
        return
    if not step3.click_exact("Back"):
        step3.real_click_label("Back")
    wait_for_text(step3, ["Reel settings", "Post"], timeout_seconds)


def set_schedule_inputs(step3, scheduled_for: datetime) -> dict[str, str]:
    date_text = format_fb_date(scheduled_for)
    time_text = format_fb_time(scheduled_for)
    expression = f"""(() => {{
  const isVisible = (el) => {{
    const r = el.getBoundingClientRect();
    const st = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && st.visibility !== 'hidden' && st.display !== 'none' && st.opacity !== '0';
  }};
  const inputs = [...document.querySelectorAll('input[role="combobox"][type="text"]')]
    .filter((el) => isVisible(el))
    .filter((el) => !(el.getAttribute('aria-label') || '').trim());
  const pair = inputs.slice(-2);
  if (pair.length !== 2) return JSON.stringify({{ ok: false, count: pair.length }});
  const setValue = (el, value) => {{
    const desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    desc.set.call(el, value);
    el.dispatchEvent(new Event('input', {{ bubbles: true }}));
    el.dispatchEvent(new Event('change', {{ bubbles: true }}));
    el.blur();
  }};
  setValue(pair[0], {json.dumps(date_text)});
  setValue(pair[1], {json.dumps(time_text)});
  return JSON.stringify({{
    ok: true,
    dateValue: pair[0].value,
    timeValue: pair[1].value
  }});
}})()"""
    payload = json.loads(step3.tab_js(expression))
    if not payload.get("ok"):
        raise RuntimeError(f"Could not find schedule inputs: {payload}")
    if payload.get("dateValue") != date_text or payload.get("timeValue") != time_text:
        raise RuntimeError(f"Schedule inputs did not keep the expected values: {payload}")
    return {
        "date_text": date_text,
        "time_text": time_text,
        "scheduled_label_ampm": timing_like_label(scheduled_for),
    }


def timing_like_label(dt: datetime) -> str:
    return f"{dt.strftime('%Y-%m-%d %I:%M %p')}"


def normalize_spaces(value: str) -> str:
    return re.sub(r"\s+", " ", value.replace("\xa0", " ")).strip()


def parse_observed_schedule_label(label: str, reference_now: datetime) -> datetime | None:
    cleaned = normalize_spaces(label)
    tzinfo = reference_now.astimezone().tzinfo

    today_match = re.fullmatch(r"Today at (\d{1,2}:\d{2} [AP]M)", cleaned, re.I)
    if today_match:
        parsed_time = datetime.strptime(today_match.group(1).upper(), "%I:%M %p").time()
        return datetime.combine(reference_now.astimezone().date(), parsed_time, tzinfo=tzinfo)

    tomorrow_match = re.fullmatch(r"Tomorrow at (\d{1,2}:\d{2} [AP]M)", cleaned, re.I)
    if tomorrow_match:
        parsed_time = datetime.strptime(tomorrow_match.group(1).upper(), "%I:%M %p").time()
        target_date = reference_now.astimezone().date() + timedelta(days=1)
        return datetime.combine(target_date, parsed_time, tzinfo=tzinfo)

    dated_match = re.fullmatch(r"([A-Z][a-z]{2} \d{1,2})(?:, (\d{4}))? at (\d{1,2}:\d{2} [AP]M)", cleaned, re.I)
    if dated_match:
        month_day = dated_match.group(1)
        year = dated_match.group(2) or str(reference_now.astimezone().year)
        time_part = dated_match.group(3).upper()
        parsed = datetime.strptime(f"{month_day} {year} {time_part}", "%b %d %Y %I:%M %p")
        return parsed.replace(tzinfo=tzinfo)

    return None


def observe_scheduled_time(step3, title: str, reference_now: datetime, timeout_seconds: float) -> tuple[datetime, str] | None:
    title_text = normalize_spaces(title)
    if not title_text:
        return None

    if not step3.click_exact("Scheduled"):
        try:
            step3.real_click_label("Scheduled")
        except RuntimeError:
            pass

    title_needles = [title_text]
    if len(title_text) > 28:
        title_needles.append(title_text[:28])

    schedule_pattern = re.compile(
        r"Scheduled\s*[•·]\s*(Today at \d{1,2}:\d{2}\s*[AP]M|Tomorrow at \d{1,2}:\d{2}\s*[AP]M|[A-Z][a-z]{2} \d{1,2}(?:,\s*\d{4})? at \d{1,2}:\d{2}\s*[AP]M)",
        re.I,
    )

    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        page_text = normalize_spaces(body_text(step3, 50000))
        lowered_page = page_text.lower()

        for needle in title_needles:
            idx = lowered_page.find(needle.lower())
            if idx == -1:
                continue

            snippet = page_text[max(0, idx - 120) : idx + len(needle) + 260]
            match = schedule_pattern.search(snippet)
            if not match:
                continue

            observed_label = normalize_spaces(match.group(1))
            observed_dt = parse_observed_schedule_label(observed_label, reference_now)
            if observed_dt is not None:
                return observed_dt, observed_label

        time.sleep(0.35)

    return None


def click_schedule_for_later(step3, timeout_seconds: float) -> str:
    if not step3.click_exact("Schedule for later"):
        step3.real_click_label("Schedule for later")
    time.sleep(0.5)
    if on_reel_settings(step3) and "Schedule" in body_text(step3):
        if not step3.click_exact("Schedule"):
            step3.real_click_label("Schedule")
    return wait_for_dialog_close(step3, timeout_seconds)


def click_post_now(step3, timeout_seconds: float) -> str:
    close_schedule_panel(step3, timeout_seconds)
    if not step3.click_exact("Post"):
        step3.real_click_label("Post")
    return wait_for_dialog_close(step3, timeout_seconds)


def close_active_chrome_context() -> None:
    script = """
tell application "Google Chrome"
    if not running then return
    quit
end tell
"""
    result = subprocess.run(
        ["osascript", "-"],
        input=script,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip() or "Could not quit Google Chrome."
        raise RuntimeError(message)


def main() -> int:
    args = parse_args()
    package_dir = Path(args.package_dir).expanduser()
    title_html = package_dir / "copy_title.html"
    if not title_html.exists():
        raise SystemExit(f"Title HTML not found: {title_html}")

    step3 = load_module(STEP3_SCRIPT, "fb_step3")
    timing = load_module(TIMING_SCRIPT, "fb_timing")

    state_path = Path(args.state_path).expanduser()
    step3.activate_chrome()
    step3.activate_content_library_tab()
    profile_info = step3.active_chrome_profile()

    state = timing.load_state(state_path)
    profile_state = timing.ensure_profile_state(
        state,
        profile_key=profile_info.get("profile_key"),
        profile_name=profile_info.get("profile_name"),
        profile_directory=profile_info.get("profile_directory"),
        page_name=args.page_name.strip() or None,
    )
    interval_minutes = timing.resolve_interval_minutes(
        profile_state,
        args.interval_minutes if args.interval_minutes > 0 else None,
    )
    last_anchor_at = timing.deserialize_dt(profile_state.get("last_anchor_at"))
    current_time = datetime.now().astimezone()
    title_text = step3.extract_title(title_html) or ""
    decision = timing.decide_publish_action(
        now=current_time,
        last_anchor_at=last_anchor_at,
        interval_minutes=interval_minutes,
    )
    if args.force_post_now:
        decision = timing.PublishDecision(
            action="post_now",
            effective_at=current_time.replace(second=0, microsecond=0),
            anchor_at=current_time.replace(second=0, microsecond=0),
            reason="forced_post_now_for_test",
        )
    elif args.post_now_advance_slot and decision.action == "schedule":
        decision = timing.PublishDecision(
            action="post_now",
            effective_at=current_time.replace(second=0, microsecond=0),
            anchor_at=decision.effective_at,
            reason="posted_now_and_advanced_saved_slot",
            interval_shifts=getattr(decision, "interval_shifts", 0),
        )

    final_decision = decision

    if decision.action == "schedule":
        open_schedule_panel(step3, args.timeout)
        schedule_input_values = set_schedule_inputs(step3, decision.effective_at)
        reference_time = last_anchor_at if last_anchor_at is not None else current_time
        crosses_day = timing.crosses_day_boundary(reference_time, decision.effective_at)
        schedule_input_values["crosses_day_boundary"] = crosses_day
        result_text = click_schedule_for_later(step3, args.timeout + 90.0)
        observed_schedule = observe_scheduled_time(step3, title_text, current_time, args.timeout + 30.0)
        if observed_schedule is not None:
            observed_at, observed_label = observed_schedule
            schedule_input_values["observed_label"] = observed_label
            schedule_input_values["observed_effective_at"] = timing.serialize_dt(observed_at)
            final_decision = timing.PublishDecision(
                action="schedule",
                effective_at=observed_at,
                anchor_at=observed_at,
                reason="schedule_confirmed_from_observed_time",
                interval_shifts=getattr(decision, "interval_shifts", 0),
            )
        else:
            schedule_input_values["observed_label"] = None
        schedule_note = f"{timing.format_anchor(final_decision.effective_at)} [SCHEDULE]"
    else:
        schedule_input_values = None
        result_text = click_post_now(step3, args.timeout + 90.0)
        schedule_note = f"{timing.format_anchor(decision.effective_at)} [POST NOW]"

    schedule_note_written = update_schedule_field(title_html, schedule_note)
    saved_state = timing.record_decision(
        package_name=package_dir.name,
        decision=final_decision,
        state_path=state_path,
        profile_key=profile_info.get("profile_key"),
        profile_name=profile_info.get("profile_name"),
        profile_directory=profile_info.get("profile_directory"),
        page_name=args.page_name.strip() or None,
        interval_minutes=interval_minutes,
    )

    if args.close_after_finish:
        close_active_chrome_context()

    print(
        json.dumps(
            {
                "status": "ok",
                "step": "step6",
                "package_dir": str(package_dir),
                "action": final_decision.action,
                "interval_minutes": interval_minutes,
                "effective_at": timing.serialize_dt(final_decision.effective_at),
                "anchor_at": timing.serialize_dt(final_decision.anchor_at),
                "profile": {
                    "profile_key": profile_info.get("profile_key"),
                    "profile_name": profile_info.get("profile_name"),
                    "profile_directory": profile_info.get("profile_directory"),
                    "page_name": args.page_name.strip() or None,
                    "window_title": profile_info.get("window_title"),
                    "source": profile_info.get("source"),
                },
                "profile_last_anchor_at_before": timing.serialize_dt(last_anchor_at) if last_anchor_at else None,
                "profile_next_slot_at_after": saved_state.get("next_slot_at"),
                "schedule_note": schedule_note,
                "schedule_note_written": schedule_note_written,
                "schedule_inputs": schedule_input_values,
                "result_text": result_text,
                "state_path": str(state_path),
                "closed_chrome_context": args.close_after_finish,
                "force_post_now": args.force_post_now,
                "post_now_advance_slot": args.post_now_advance_slot,
            },
            indent=2,
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
