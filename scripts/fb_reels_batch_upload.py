#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

from soranin_paths import FACEBOOK_STATE_PATH, ROOT_DIR, script_path

ROOT_DEFAULT = ROOT_DIR
STATE_DEFAULT = FACEBOOK_STATE_PATH
PREFLIGHT_SCRIPT = script_path("fb_reels_preflight_check.py")
STEP3_SCRIPT = script_path("fb_reels_step3_upload_video_and_next.py")
STEP4_SCRIPT = script_path("fb_reels_step4_edit_thumbnail.py")
STEP5_SCRIPT = script_path("fb_reels_step5_add_title_from_html.py")
STEP6_SCRIPT = script_path("fb_reels_step6_schedule_or_post.py")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Upload Facebook Reels packages in order, then schedule/post each one using rolling interval timing."
    )
    parser.add_argument(
        "root",
        nargs="?",
        default=str(ROOT_DEFAULT),
        help="Folder that contains numbered Reels packages.",
    )
    parser.add_argument(
        "--start-at",
        type=int,
        default=1,
        help="Only process package numbers greater than or equal to this value.",
    )
    parser.add_argument(
        "--state-path",
        default=str(STATE_DEFAULT),
        help="JSON state file used to remember the last schedule/post anchor time.",
    )
    parser.add_argument(
        "--close-after-finish",
        action="store_true",
        help="Quit Google Chrome completely after the final package finishes.",
    )
    parser.add_argument(
        "--page-name",
        default="",
        help="Optional Facebook profile/page name to switch to and use for timing state.",
    )
    parser.add_argument(
        "--interval-minutes",
        type=int,
        default=0,
        help="Optional interval in minutes for this page/profile. Example: 30 or 60.",
    )
    parser.add_argument(
        "--packages",
        nargs="*",
        default=[],
        help="Optional explicit package folder names, for example 21_Reels_Package 22_Reels_Package.",
    )
    parser.add_argument(
        "--close-after-each",
        action="store_true",
        help="Quit Google Chrome completely after every package finishes posting/scheduling.",
    )
    parser.add_argument(
        "--post-now-advance-slot",
        action="store_true",
        help="Post immediately but keep the saved slot queue moving forward.",
    )
    return parser.parse_args()


def package_list(root: Path, *, start_at: int) -> list[Path]:
    packages: list[Path] = []
    for path in sorted(root.glob("*_Reels_Package"), key=lambda item: int(item.name.split("_", 1)[0])):
        number = int(path.name.split("_", 1)[0])
        if number < start_at:
            continue
        if not path.is_dir():
            continue
        packages.append(path)
    return packages


def explicit_package_list(root: Path, names: list[str]) -> list[Path]:
    packages: list[Path] = []
    for name in names:
        cleaned = name.strip()
        if not cleaned:
            continue
        package_dir = (root / cleaned).expanduser()
        if not package_dir.exists():
            raise RuntimeError(f"Package folder not found: {package_dir}")
        if not package_dir.is_dir():
            raise RuntimeError(f"Package path is not a folder: {package_dir}")
        packages.append(package_dir)
    return packages


def run_step(
    script_path: Path,
    package_dir: Path,
    *,
    state_path: Path | None = None,
    page_name: str = "",
    interval_minutes: int = 0,
    extra_args: list[str] | None = None,
) -> dict:
    command = ["python3", str(script_path), str(package_dir)]
    if state_path is not None:
        command.extend(["--state-path", str(state_path)])
    if page_name:
        command.extend(["--page-name", page_name])
    if interval_minutes > 0:
        command.extend(["--interval-minutes", str(interval_minutes)])
    if extra_args:
        command.extend(extra_args)

    result = subprocess.run(
        command,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip() or f"Step failed: {script_path.name}"
        raise RuntimeError(message)

    output = (result.stdout or "").strip()
    if not output:
        return {"status": "ok", "script": script_path.name}
    lines = output.splitlines()
    for start in range(len(lines)):
        candidate = "\n".join(lines[start:]).strip()
        if not candidate.startswith("{"):
            continue
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue
    raise RuntimeError(f"Could not parse JSON output from {script_path.name}: {output[:500]}")


def main() -> int:
    args = parse_args()
    root = Path(args.root).expanduser()
    state_path = Path(args.state_path).expanduser()
    packages = explicit_package_list(root, args.packages) if args.packages else package_list(root, start_at=args.start_at)

    if not packages:
        print(json.dumps({"status": "ok", "message": "No packages found. Nothing left to upload."}, indent=2))
        return 0

    results: list[dict] = []
    for index, package_dir in enumerate(packages):
        page_name_for_upload = args.page_name if index == 0 else ""
        preflight_result = run_step(
            PREFLIGHT_SCRIPT,
            package_dir,
            state_path=state_path,
            page_name=args.page_name,
            interval_minutes=args.interval_minutes,
        )
        facebook_schedule = preflight_result.get("facebook_schedule", {})
        decision_preview = preflight_result.get("decision_preview", {})
        if decision_preview.get("action") == "schedule" and not facebook_schedule.get("exact_schedule_possible", True):
            desired = decision_preview.get("effective_label")
            earliest = facebook_schedule.get("earliest_allowed_label")
            raise RuntimeError(
                f"Preflight blocked upload for {package_dir.name}. Desired slot: {desired}. "
                f"Earliest Facebook schedule right now: {earliest}."
            )
        step3_result = run_step(STEP3_SCRIPT, package_dir, page_name=page_name_for_upload)
        step4_result = run_step(STEP4_SCRIPT, package_dir)
        step5_result = run_step(STEP5_SCRIPT, package_dir)
        step6_extra_args: list[str] = []
        if args.post_now_advance_slot:
            step6_extra_args.append("--post-now-advance-slot")
        if args.close_after_each:
            step6_extra_args.append("--close-after-finish")
        elif args.close_after_finish and index == len(packages) - 1:
            step6_extra_args.append("--close-after-finish")
        step6_result = run_step(
            STEP6_SCRIPT,
            package_dir,
            state_path=state_path,
            page_name=args.page_name,
            interval_minutes=args.interval_minutes,
            extra_args=step6_extra_args,
        )
        results.append(
            {
                "package_dir": str(package_dir),
                "steps": {
                    "preflight": preflight_result,
                    "step3": step3_result,
                    "step4": step4_result,
                    "step5": step5_result,
                    "step6": step6_result,
                },
            }
        )

    print(
        json.dumps(
            {
                "status": "ok",
                "processed_count": len(results),
                "stopped_because": "no_more_folders",
                "state_path": str(state_path),
                "results": results,
            },
            indent=2,
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
