#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import re
import subprocess
import time
from pathlib import Path

from soranin_paths import CLICK_POINT_SWIFT, DEFAULT_FACEBOOK_PACKAGE, FACEBOOK_STATE_PATH, ROOT_DIR, script_path


CLICK_POINT_BINARY = Path("/tmp/click_point")
STEP2_SCRIPT = script_path("fb_reels_step2_open_reel_dialog.py")
DEFAULT_PACKAGE = DEFAULT_FACEBOOK_PACKAGE
FAVORITE_ROOT = ROOT_DIR
STATE_PATH = FACEBOOK_STATE_PATH
TARGET_URL = "https://web.facebook.com/professional_dashboard/content/content_library"
CONTENT_LIBRARY_MARKER = "content_library"
CHROME_LOCAL_STATE = Path.home() / "Library/Application Support/Google/Chrome/Local State"
VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".avi", ".mkv"}
NEXT_CLICK_DELAY_SECONDS = 2.0
PROFILE_SEARCH_WAIT_SECONDS = 2.5
PROFILE_SWITCH_SETTLE_SECONDS = 3.5


def status_print(message: str) -> None:
    print(message, flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Step 3 for Facebook Reels upload: add video from the package, then click Next twice."
    )
    parser.add_argument(
        "package_dir",
        nargs="?",
        default=str(DEFAULT_PACKAGE),
        help="Path to the numbered Reels package folder.",
    )
    parser.add_argument("--timeout", type=float, default=14.0, help="Timeout in seconds for UI transitions.")
    parser.add_argument(
        "--upload-timeout",
        type=float,
        default=180.0,
        help="Timeout in seconds for video upload to become visible.",
    )
    parser.add_argument(
        "--page-name",
        default="",
        help="Optional Facebook profile/page name to switch to before uploading.",
    )
    return parser.parse_args()


def pick_first_file(folder: Path, allowed_extensions: set[str]) -> Path | None:
    candidates = [
        path
        for path in sorted(folder.iterdir())
        if path.is_file() and path.suffix.lower() in allowed_extensions
    ]
    return candidates[0] if candidates else None


def extract_title(html_path: Path) -> str | None:
    if not html_path.exists():
        return None
    text = html_path.read_text(encoding="utf-8")
    match = re.search(r'<textarea id="titleField" readonly>(.*?)</textarea>', text, re.S)
    if not match:
        return None
    return html.unescape(match.group(1).strip())


def resolve_assets(package_dir: Path) -> dict[str, Path | None]:
    video_path = package_dir / "edited_reel_9x16_hd_0.90x_15s.mp4"
    if not video_path.exists():
        video_path = pick_first_file(package_dir, VIDEO_EXTENSIONS)

    title_path = package_dir / "copy_title.html"
    title = extract_title(title_path) if title_path.exists() else None

    return {
        "package_dir": package_dir,
        "video_path": video_path,
        "title_path": title_path if title_path.exists() else None,
        "title": title,
    }


def ensure_package_dir(package_dir: Path) -> dict[str, Path | str | None]:
    if not package_dir.exists():
        raise SystemExit(f"Package folder not found: {package_dir}")
    if not package_dir.is_dir():
        raise SystemExit(f"Package path is not a folder: {package_dir}")

    assets = resolve_assets(package_dir)
    if not assets["video_path"]:
        raise SystemExit(f"No video file found in: {package_dir}")
    return assets


def run_osascript_lines(lines: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(lines, text=True, capture_output=True, check=False)


def jxa_output(source: str, args: list[str] | None = None) -> str:
    command = ["osascript", "-l", "JavaScript"]
    if args:
        command.extend(["-"] + args)
    result = subprocess.run(
        command,
        input=source,
        text=True,
        capture_output=True,
        check=False,
    )
    output = (result.stdout or "").strip() or (result.stderr or "").strip()
    if result.returncode != 0:
        raise RuntimeError(output or "JXA command failed.")
    return output


def applescript_output(source: str) -> str:
    result = subprocess.run(
        ["osascript", "-"],
        input=source,
        text=True,
        capture_output=True,
        check=False,
    )
    output = (result.stdout or "").strip() or (result.stderr or "").strip()
    if result.returncode != 0:
        raise RuntimeError(output or "AppleScript command failed.")
    return output


def activate_chrome() -> None:
    last_message = "Could not activate Google Chrome."
    probe = run_osascript_lines(["osascript", "-e", 'tell application "System Events" to (name of processes) contains "Google Chrome"'])
    if probe.returncode == 0 and probe.stdout.strip().lower() == "true":
        activate_result = run_osascript_lines(["osascript", "-e", 'tell application "Google Chrome" to activate'])
        if activate_result.returncode == 0:
            time.sleep(0.4)
            return
        last_message = (activate_result.stderr or activate_result.stdout).strip() or last_message

    for _ in range(10):
        subprocess.run(["open", "-a", "Google Chrome"], text=True, capture_output=True, check=False)
        time.sleep(1.0)
        result = run_osascript_lines(["osascript", "-e", 'tell application "Google Chrome" to activate'])
        if result.returncode == 0:
            time.sleep(0.4)
            return
        probe = run_osascript_lines(
            ["osascript", "-e", 'tell application "Google Chrome" to get name of front window']
        )
        if probe.returncode == 0:
            time.sleep(0.4)
            return
        last_message = (result.stderr or result.stdout).strip() or last_message
    raise RuntimeError(last_message)


def chrome_front_window_title() -> str:
    return applescript_output(
        """
tell application "System Events"
  tell process "Google Chrome"
    return name of front window
  end tell
end tell
"""
    )


def chrome_profile_index() -> dict[str, object]:
    if not CHROME_LOCAL_STATE.exists():
        return {}
    return json.loads(CHROME_LOCAL_STATE.read_text(encoding="utf-8"))


def active_chrome_profile() -> dict[str, str | None]:
    title = ""
    try:
        title = chrome_front_window_title()
    except Exception:
        title = ""

    marker = " - Google Chrome - "
    profile_name = title.rsplit(marker, 1)[1].strip() if marker in title else None

    local_state = chrome_profile_index()
    profile_block = local_state.get("profile", {}) if isinstance(local_state, dict) else {}
    info_cache = profile_block.get("info_cache", {}) if isinstance(profile_block, dict) else {}
    last_used = profile_block.get("last_used") if isinstance(profile_block, dict) else None
    last_active_profiles = profile_block.get("last_active_profiles", []) if isinstance(profile_block, dict) else []

    def pick_profile_directory(matches: list[tuple[str, dict[str, object]]]) -> str | None:
        if not matches:
            return None
        if last_used:
            for directory, _info in matches:
                if directory == last_used:
                    return directory
        for active_directory in last_active_profiles:
            for directory, _info in matches:
                if directory == active_directory:
                    return directory
        matches = sorted(matches, key=lambda item: float(item[1].get("active_time", 0.0)), reverse=True)
        return matches[0][0]

    profile_directory: str | None = None
    source = "window_title"

    if profile_name:
        matches = [
            (directory, info)
            for directory, info in info_cache.items()
            if isinstance(info, dict) and str(info.get("name", "")).strip() == profile_name
        ]
        profile_directory = pick_profile_directory(matches)
    else:
        source = "local_state_fallback"
        candidate_directories: list[str] = []
        if isinstance(last_used, str) and last_used:
            candidate_directories.append(last_used)
        for directory in last_active_profiles:
            if isinstance(directory, str) and directory and directory not in candidate_directories:
                candidate_directories.append(directory)
        if not candidate_directories and info_cache:
            candidate_directories = sorted(
                info_cache.keys(),
                key=lambda key: float(info_cache.get(key, {}).get("active_time", 0.0)),
                reverse=True,
            )
        if candidate_directories:
            profile_directory = candidate_directories[0]
            info = info_cache.get(profile_directory, {})
            profile_name = str(info.get("name") or profile_directory).strip()

    if not profile_name and profile_directory:
        info = info_cache.get(profile_directory, {})
        profile_name = str(info.get("name") or profile_directory).strip()

    profile_key = profile_directory or (f"name::{profile_name}" if profile_name else "__default__")
    return {
        "profile_key": profile_key,
        "profile_name": profile_name,
        "profile_directory": profile_directory,
        "window_title": title,
        "source": source,
    }


def activate_content_library_tab() -> str:
    source = f"""
var chrome = Application("Google Chrome");
chrome.includeStandardAdditions = true;
var windows = chrome.windows();
var targetUrl = null;
var exactUrls = [{json.dumps(TARGET_URL)}, {json.dumps(TARGET_URL + "/")}];
if (windows.length > 0) {{
  var frontWindow = windows[0];
  var frontTabs = frontWindow.tabs();
  for (var j = 0; j < frontTabs.length; j++) {{
    var frontUrl = String(frontTabs[j].url() || "");
    if (exactUrls.indexOf(frontUrl) !== -1) {{
      chrome.activate();
      frontWindow.index = 1;
      frontWindow.activeTabIndex = j + 1;
      targetUrl = frontUrl;
      break;
    }}
  }}
  if (!targetUrl) {{
    var activeUrl = String(frontWindow.activeTab().url() || "");
    if (activeUrl.indexOf({json.dumps(CONTENT_LIBRARY_MARKER)}) !== -1) {{
      chrome.activate();
      frontWindow.index = 1;
      targetUrl = activeUrl;
    }}
  }}
}}
if (!targetUrl) {{
for (var i = 0; i < windows.length; i++) {{
  var tabs = windows[i].tabs();
  for (var j = 0; j < tabs.length; j++) {{
    var url = String(tabs[j].url() || "");
    if (exactUrls.indexOf(url) !== -1) {{
      chrome.activate();
      windows[i].index = 1;
      windows[i].activeTabIndex = j + 1;
      targetUrl = url;
      break;
    }}
  }}
  if (targetUrl) break;
}}
}}
if (!targetUrl) {{
  for (var i = 0; i < windows.length; i++) {{
    var tabs = windows[i].tabs();
    for (var j = 0; j < tabs.length; j++) {{
      var url = String(tabs[j].url() || "");
      if (url.indexOf({json.dumps(CONTENT_LIBRARY_MARKER)}) !== -1) {{
        chrome.activate();
        windows[i].index = 1;
        windows[i].activeTabIndex = j + 1;
        targetUrl = url;
        break;
      }}
    }}
    if (targetUrl) break;
  }}
}}
if (!targetUrl) {{
  throw new Error("Content Library tab not found in Google Chrome.");
}}
console.log(targetUrl);
"""
    return jxa_output(source)


def open_exact_content_library_url() -> None:
    script = f"""
tell application "Google Chrome"
    if not running then error "Google Chrome is not open."
    activate
    if (count of windows) is 0 then error "Google Chrome has no open windows."
    tell front window
        set URL of active tab to "{TARGET_URL}"
    end tell
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
        message = (result.stderr or result.stdout).strip() or "Could not open the Facebook Content Library URL."
        raise RuntimeError(message)


def activate_exact_content_library_page() -> str:
    open_exact_content_library_url()
    deadline = time.time() + 15.0
    last_url = ""
    while time.time() < deadline:
        last_url = activate_content_library_tab()
        if last_url.rstrip("/") == TARGET_URL:
            return last_url
        time.sleep(0.12)
    raise RuntimeError(f"Chrome did not finish loading the expected URL: {TARGET_URL} (last URL: {last_url})")


def ensure_click_point_binary() -> None:
    if CLICK_POINT_BINARY.exists():
        return
    if not CLICK_POINT_SWIFT.exists():
        raise RuntimeError(f"Missing click helper source: {CLICK_POINT_SWIFT}")
    result = subprocess.run(
        ["swiftc", str(CLICK_POINT_SWIFT), "-o", str(CLICK_POINT_BINARY)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout).strip() or "Could not build click helper.")


def click_screen_point(x: float, y: float) -> None:
    ensure_click_point_binary()
    result = subprocess.run(
        [str(CLICK_POINT_BINARY), f"{x:.3f}", f"{y:.3f}"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout).strip() or "Could not click screen point.")


def tab_js(expression: str, delay_seconds: float = 0.0) -> str:
    delay_line = f"delay({delay_seconds});" if delay_seconds > 0 else ""
    source = f"""
ObjC.import("stdlib");
var app = Application.currentApplication();
app.includeStandardAdditions = true;
{delay_line}
var chrome = Application("Google Chrome");
chrome.includeStandardAdditions = true;
var tab = chrome.windows[0].activeTab();
var result = tab.execute({{javascript: {json.dumps(expression)}}});
console.log(String(result));
"""
    return jxa_output(source)


def current_state() -> dict[str, object]:
    expression = r"""(() => {
  const text = document.body ? document.body.innerText : '';
  return JSON.stringify({
    hasCreateReel: /Create reel/i.test(text),
    hasAddVideo: /Add video|drag and drop/i.test(text),
    hasAudio: /(^|\n)\s*Audio(\n|$)/i.test(text),
    hasEditReview: /Edit reel/i.test(text) && /Your reel is safe to publish!/i.test(text),
    hasScheduling: /Reel settings|Scheduling options|Share to your story/i.test(text),
    hasUploadImage: /Upload image/i.test(text),
    bodySnippet: text.slice(0, 1000)
  });
})()"""
    return json.loads(tab_js(expression))


def ensure_reel_dialog_open(timeout_seconds: float) -> None:
    state = current_state()
    if state.get("hasCreateReel") and (state.get("hasAddVideo") or state.get("hasAudio") or state.get("hasScheduling")):
        return
    if not STEP2_SCRIPT.exists():
        raise RuntimeError(f"Step 2 script missing: {STEP2_SCRIPT}")
    result = subprocess.run(
        ["python3", str(STEP2_SCRIPT), "--timeout", str(timeout_seconds)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip() or "Could not open Create reel dialog."
        raise RuntimeError(message)
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        state = current_state()
        if state.get("hasCreateReel") and (state.get("hasAddVideo") or state.get("hasAudio") or state.get("hasScheduling")):
            return
        time.sleep(0.15)
    raise RuntimeError("Create reel dialog did not stay open after step 2 completed.")


def pause_media() -> None:
    tab_js(
        r"""(() => {
  document.querySelectorAll('video,audio').forEach((media) => {
    try { media.muted = true; } catch (error) {}
    try { media.volume = 0; } catch (error) {}
    try { media.pause(); } catch (error) {}
    try { media.autoplay = false; } catch (error) {}
  });
  return true;
})()"""
    )


def preview_media_state() -> dict[str, object]:
    expression = r"""(() => {
  const normalize = (value) => String(value || '').replace(/[\u200b\ufeff]/g, '').replace(/\s+/g, ' ').trim();
  const isVisible = (el) => {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  };
  const toScreen = (x, y) => {
    const scale = window.outerWidth / window.innerWidth;
    const xOffset = (window.outerWidth - (window.innerWidth * scale)) / 2;
    const yOffset = (window.outerHeight - (window.innerHeight * scale));
    return {
      clickX: window.screenX + xOffset + (x * scale),
      clickY: window.screenY + yOffset + (y * scale)
    };
  };
  const visibleVideos = [...document.querySelectorAll('video')].filter((el) => isVisible(el));
  if (!visibleVideos.length) {
    return JSON.stringify({ hasVisibleVideo: false, anyPlaying: false });
  }

  let primaryVideo = visibleVideos[0];
  let largestArea = 0;
  for (const video of visibleVideos) {
    const rect = video.getBoundingClientRect();
    const area = rect.width * rect.height;
    if (area > largestArea) {
      largestArea = area;
      primaryVideo = video;
    }
  }

  const videoRect = primaryVideo.getBoundingClientRect();
  const anyPlaying = visibleVideos.some((video) => !video.paused && !video.ended);
  const targetX = videoRect.left + Math.min(26, Math.max(16, videoRect.width * 0.08));
  const targetY = videoRect.bottom - Math.min(18, Math.max(14, videoRect.height * 0.04));

  const pauseCandidates = [...document.querySelectorAll('button,[role="button"],div,span')]
    .filter((el) => isVisible(el))
    .map((el) => {
      const text = normalize(el.innerText);
      const aria = normalize(el.getAttribute('aria-label'));
      const title = normalize(el.getAttribute('title'));
      return { el, text, aria, title };
    })
    .filter((item) => /pause/i.test(`${item.text} ${item.aria} ${item.title}`))
    .map((item) => {
      const rect = item.el.getBoundingClientRect();
      const cx = rect.left + rect.width / 2;
      const cy = rect.top + rect.height / 2;
      const distance = Math.hypot(cx - targetX, cy - targetY);
      return { ...item, rect, cx, cy, distance };
    })
    .filter((item) => (
      item.cx >= videoRect.left - 40 &&
      item.cx <= videoRect.right + 40 &&
      item.cy >= videoRect.top - 40 &&
      item.cy <= videoRect.bottom + 40
    ))
    .sort((a, b) => a.distance - b.distance);

  const pauseButton = pauseCandidates.length
    ? toScreen(pauseCandidates[0].cx, pauseCandidates[0].cy)
    : null;

  return JSON.stringify({
    hasVisibleVideo: true,
    anyPlaying,
    primaryPaused: !!primaryVideo.paused,
    pauseButton,
    fallbackClick: toScreen(targetX, targetY)
  });
})()"""
    return json.loads(tab_js(expression))


def pause_preview_playback(timeout_seconds: float = 8.0) -> bool:
    deadline = time.time() + timeout_seconds
    saw_preview = False

    while time.time() < deadline:
        state = preview_media_state()
        if not state.get("hasVisibleVideo"):
            time.sleep(0.05)
            continue

        saw_preview = True
        pause_media()
        if not state.get("anyPlaying"):
            return True

        target = state.get("pauseButton") or state.get("fallbackClick")
        if isinstance(target, dict) and "clickX" in target and "clickY" in target:
            click_screen_point(float(target["clickX"]), float(target["clickY"]))
            time.sleep(0.04)
            pause_media()

        verify = preview_media_state()
        if verify.get("hasVisibleVideo") and not verify.get("anyPlaying"):
            return True
        time.sleep(0.08)

    return saw_preview


def file_dialog_open() -> bool:
    source = r"""
var system = Application("System Events");
system.includeStandardAdditions = true;
var proc = system.processes.byName("Google Chrome");
var isOpen = false;
try {
  isOpen = proc.windows.length > 0 && proc.windows[0].sheets.length > 0;
} catch (error) {
  isOpen = false;
}
console.log(String(isOpen));
"""
    return jxa_output(source).strip().lower() == "true"


def wait_for_file_dialog(timeout_seconds: float) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if file_dialog_open():
            return
        time.sleep(0.08)
    raise RuntimeError("File dialog did not open.")


def file_dialog_where() -> str:
    return applescript_output(
        """
tell application "System Events"
  tell process "Google Chrome"
    return value of pop up button "Where:" of splitter group 1 of sheet 1 of window 1
  end tell
end tell
"""
    )


def clear_file_dialog_search() -> str:
    return applescript_output(
        """
tell application "System Events"
  tell process "Google Chrome"
    tell splitter group 1 of sheet 1 of window 1
      set value of text field 1 to ""
      delay 0.12
      return value of pop up button "Where:"
    end tell
  end tell
end tell
"""
    )


def select_file_dialog_sidebar_favorite(name: str) -> str:
    script = f"""
tell application "System Events"
  tell process "Google Chrome"
    tell outline 1 of scroll area 1 of splitter group 1 of sheet 1 of window 1
      set rowCount to count of rows
      repeat with i from 1 to rowCount
        try
          if (value of static text 1 of UI element 1 of row i as text) is {json.dumps(name)} then
            perform action "AXPress" of row i
            delay 0.15
            exit repeat
          end if
        end try
      end repeat
    end tell
    return value of pop up button "Where:" of splitter group 1 of sheet 1 of window 1
  end tell
end tell
"""
    return applescript_output(script)


def switch_file_dialog_to_list_view() -> str:
    return applescript_output(
        """
tell application "System Events"
  tell process "Google Chrome"
    keystroke "2" using {command down}
    delay 0.25
    return value of pop up button "Where:" of splitter group 1 of sheet 1 of window 1
  end tell
end tell
"""
    )


def file_dialog_outline_rows() -> list[str]:
    output = applescript_output(
        """
tell application "System Events"
  tell process "Google Chrome"
    set outText to ""
    tell outline 1 of scroll area 1 of splitter group 1 of splitter group 1 of sheet 1 of window 1
      set rowCount to count of rows
      repeat with i from 1 to rowCount
        try
          set outText to outText & i & ":" & (value of text field 1 of UI element 1 of row i as text) & linefeed
        end try
      end repeat
    end tell
    return outText
  end tell
end tell
"""
    )
    rows: list[str] = []
    for line in output.splitlines():
        if ":" not in line:
            continue
        _index, value = line.split(":", 1)
        value = value.strip()
        if value:
            rows.append(value)
    return rows


def open_file_dialog_row(name: str) -> str:
    script = f"""
tell application "System Events"
  tell process "Google Chrome"
    tell outline 1 of scroll area 1 of splitter group 1 of splitter group 1 of sheet 1 of window 1
      set rowCount to count of rows
      repeat with i from 1 to rowCount
        try
          if (value of text field 1 of UI element 1 of row i as text) is {json.dumps(name)} then
            select row i
            exit repeat
          end if
        end try
      end repeat
    end tell
    delay 0.08
    click button "Open" of splitter group 1 of sheet 1 of window 1
    delay 0.35
    try
      return value of pop up button "Where:" of splitter group 1 of sheet 1 of window 1
    on error
      return "dialog_closed"
    end try
  end tell
end tell
"""
    return applescript_output(script)


def choose_file_via_favorites(file_path: Path) -> None:
    try:
        relative_path = file_path.relative_to(FAVORITE_ROOT)
    except ValueError as error:
        raise RuntimeError(
            f"{file_path} is outside the Favorites root {FAVORITE_ROOT}; cannot use sidebar navigation."
        ) from error

    relative_parts = list(relative_path.parts)
    remaining_parts = relative_parts[:]
    downloads_root = FAVORITE_ROOT.parent

    current_where = ""
    try:
        current_where = file_dialog_where()
    except Exception:
        current_where = ""

    if current_where == FAVORITE_ROOT.name:
        remaining_parts = relative_parts[:]
    elif current_where == downloads_root.name:
        remaining_parts = [FAVORITE_ROOT.name] + relative_parts[:]
    elif current_where in relative_parts[:-1]:
        start_index = relative_parts.index(current_where) + 1
        remaining_parts = relative_parts[start_index:]
    else:
        clear_file_dialog_search()
        current_where = select_file_dialog_sidebar_favorite(FAVORITE_ROOT.name)
        if current_where != FAVORITE_ROOT.name:
            raise RuntimeError(f'Could not switch file dialog to "{FAVORITE_ROOT.name}".')
        remaining_parts = relative_parts[:]

    switch_file_dialog_to_list_view()

    for folder_name in remaining_parts[:-1]:
        rows = file_dialog_outline_rows()
        if folder_name not in rows:
            raise RuntimeError(f'Folder "{folder_name}" not found in file dialog rows: {rows}')
        open_file_dialog_row(folder_name)
        switch_file_dialog_to_list_view()

    rows = file_dialog_outline_rows()
    target_name = remaining_parts[-1]
    if target_name not in rows:
        raise RuntimeError(f'File "{target_name}" not found in file dialog rows: {rows}')
    result = open_file_dialog_row(target_name)
    if result != "dialog_closed":
        raise RuntimeError(f"File dialog did not close after selecting {target_name}.")


def choose_file_via_go_to_folder(file_path: Path) -> None:
    escaped_path = json.dumps(str(file_path))
    script = f"""
tell application "System Events"
  tell process "Google Chrome"
    keystroke "g" using {{command down, shift down}}
    delay 0.25
    keystroke {escaped_path}
    delay 0.15
    key code 36
    delay 0.3
    key code 36
    delay 0.6
  end tell
end tell
"""
    applescript_output(script)


def choose_file(file_path: Path) -> None:
    try:
        choose_file_via_favorites(file_path)
    except Exception:
        choose_file_via_go_to_folder(file_path)


def next_button_point() -> tuple[float, float]:
    expression = """(() => {
  const normalize = (value) => String(value || '').replace(/[\\u200b\\ufeff]/g, '').replace(/\\s+/g, ' ').trim();
  const isVisible = (el) => {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  };
  const matches = [...document.querySelectorAll('[role="button"],button,a,label')]
    .filter((el) => isVisible(el))
    .filter((el) => {
      const text = normalize(el.innerText);
      const aria = normalize(el.getAttribute('aria-label'));
      return text.toLowerCase() === 'next' || aria.toLowerCase() === 'next';
    })
    .map((el) => ({ el, rect: el.getBoundingClientRect() }))
    .sort((a, b) => (a.rect.bottom - b.rect.bottom) || (a.rect.right - b.rect.right));
  if (!matches.length) return JSON.stringify({ found: false });
  const target = matches[matches.length - 1].el;
  target.scrollIntoView({ block: 'center', inline: 'center' });
  const rect = target.getBoundingClientRect();
  const x = rect.left + rect.width / 2;
  const y = rect.top + rect.height / 2;
  const scale = window.outerWidth / window.innerWidth;
  const xOffset = (window.outerWidth - (window.innerWidth * scale)) / 2;
  const yOffset = (window.outerHeight - (window.innerHeight * scale));
  return JSON.stringify({
    found: true,
    clickX: window.screenX + xOffset + (x * scale),
    clickY: window.screenY + yOffset + (y * scale)
  });
})()"""
    payload = json.loads(tab_js(expression))
    if not payload.get("found"):
        raise RuntimeError('Could not find the bottom "Next" button.')
    return float(payload["clickX"]), float(payload["clickY"])


def click_next_button() -> bool:
    try:
        x, y = next_button_point()
    except RuntimeError:
        return False
    click_screen_point(x, y)
    return True


def click_exact(label: str, *, use_last: bool = False, contains: bool = False) -> bool:
    expression = f"""(() => {{
  const normalize = (value) => String(value || '').replace(/[\\u200b\\ufeff]/g, '').replace(/\\s+/g, ' ').trim();
  const wanted = {json.dumps(label)};
  const wantedLower = wanted.toLowerCase();
  const isVisible = (el) => {{
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  }};
  const match = (el) => {{
    if (!isVisible(el)) return false;
    const text = normalize(el.innerText);
    const aria = normalize(el.getAttribute('aria-label'));
    return { 'text.toLowerCase() === wantedLower || aria.toLowerCase() === wantedLower' if not contains else 'text.toLowerCase().includes(wantedLower) || aria.toLowerCase().includes(wantedLower)' };
  }};
  const preferred = [...document.querySelectorAll('[role="button"],button,a')].filter(match);
  const fallback = [...document.querySelectorAll('div,span')].filter(match);
  const matches = preferred.length ? preferred : fallback;
  const raw = matches[{ 'matches.length - 1' if use_last else '0' }];
  const el = raw ? (raw.closest('[role="button"],button,a,label') || raw) : null;
  if (!el) return false;
  el.click();
  return true;
}})()"""
    return tab_js(expression).strip().lower() == "true"


def click_point_for_label(label: str, *, use_last: bool = False, contains: bool = False) -> tuple[float, float]:
    expression = f"""(() => {{
  const normalize = (value) => String(value || '').replace(/[\\u200b\\ufeff]/g, '').replace(/\\s+/g, ' ').trim();
  const wanted = {json.dumps(label)};
  const wantedLower = wanted.toLowerCase();
  const isVisible = (el) => {{
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  }};
  const match = (el) => {{
    if (!isVisible(el)) return false;
    const text = normalize(el.innerText);
    const aria = normalize(el.getAttribute('aria-label'));
    return { 'text.toLowerCase() === wantedLower || aria.toLowerCase() === wantedLower' if not contains else 'text.toLowerCase().includes(wantedLower) || aria.toLowerCase().includes(wantedLower)' };
  }};
  const preferred = [...document.querySelectorAll('[role="button"],button,a')].filter(match);
  const fallback = [...document.querySelectorAll('div,span')].filter(match);
  const matches = preferred.length ? preferred : fallback;
  const raw = matches[{ 'matches.length - 1' if use_last else '0' }];
  const el = raw ? (raw.closest('[role="button"],button,a,label') || raw) : null;
  if (!el) return JSON.stringify({{ found: false }});
  el.scrollIntoView({{ block: 'center', inline: 'center' }});
  const rect = el.getBoundingClientRect();
  const x = rect.left + rect.width / 2;
  const y = rect.top + rect.height / 2;
  const scale = window.outerWidth / window.innerWidth;
  const xOffset = (window.outerWidth - (window.innerWidth * scale)) / 2;
  const yOffset = (window.outerHeight - (window.innerHeight * scale));
  return JSON.stringify({{
    found: true,
    clickX: window.screenX + xOffset + (x * scale),
    clickY: window.screenY + yOffset + (y * scale)
  }});
}})()"""
    payload = json.loads(tab_js(expression))
    if not payload.get("found"):
        raise RuntimeError(f"Could not find clickable label: {label}")
    return float(payload["clickX"]), float(payload["clickY"])


def real_click_label(label: str, *, use_last: bool = False, contains: bool = False) -> None:
    x, y = click_point_for_label(label, use_last=use_last, contains=contains)
    click_screen_point(x, y)


def body_text(limit: int = 20000) -> str:
    return str(tab_js(f"document.body ? document.body.innerText.slice(0, {limit}) : ''"))


def normalize_name(value: str | None) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip().casefold()


def load_publish_state() -> dict:
    if not STATE_PATH.exists():
        return {}
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}


def remembered_page_for_chrome_profile(profile_info: dict[str, str | None]) -> str | None:
    state = load_publish_state()
    profiles = state.get("profiles", {}) if isinstance(state, dict) else {}
    if not isinstance(profiles, dict):
        return None

    target_directory = (profile_info.get("profile_directory") or "").strip()
    target_name = (profile_info.get("profile_name") or "").strip()

    matches: list[dict] = []
    for profile_state in profiles.values():
        if not isinstance(profile_state, dict):
            continue
        page_name = (profile_state.get("page_name") or "").strip()
        if not page_name:
            continue
        if target_directory and str(profile_state.get("profile_directory") or "").strip() == target_directory:
            matches.append(profile_state)
            continue
        if target_name and str(profile_state.get("profile_name") or "").strip() == target_name:
            matches.append(profile_state)

    if not matches:
        return None

    matches.sort(
        key=lambda item: item.get("recorded_at")
        or item.get("last_anchor_at")
        or item.get("next_slot_at")
        or "",
    )
    return str(matches[-1].get("page_name") or "").strip() or None


def profile_switcher_button_point() -> tuple[float, float]:
    expression = r"""(() => {
  const normalize = (value) => String(value || '').replace(/[\u200b\ufeff]/g, '').replace(/\s+/g, ' ').trim();
  const isVisible = (el) => {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  };
  const clickable = (el) => el.closest('[role="button"],button,a,label') || el;
  const candidates = [...document.querySelectorAll('[role="button"],button,a,div,span')]
    .filter((el) => isVisible(el))
    .map((el) => {
      const node = clickable(el);
      const rect = node.getBoundingClientRect();
      const img = node.matches('img') ? node : node.querySelector('img');
      const text = normalize(node.innerText);
      const aria = normalize(node.getAttribute('aria-label'));
      const alt = normalize(img ? img.getAttribute('alt') : '');
      const inTopRight = rect.top >= 0 && rect.top <= 140 && rect.right >= (window.innerWidth - 240);
      return {
        node,
        rect,
        text,
        aria,
        alt,
        hasImg: !!img,
        hasProfileHint: /profile|account|switch/i.test(`${text} ${aria} ${alt}`),
        inTopRight
      };
    })
    .filter((item) => item.inTopRight)
    .filter((item) => item.rect.width >= 24 && item.rect.height >= 24)
    .filter((item) => item.rect.width <= 120 && item.rect.height <= 120)
    .sort((a, b) => (
      Number(b.hasImg) - Number(a.hasImg) ||
      Number(b.hasProfileHint) - Number(a.hasProfileHint) ||
      b.rect.right - a.rect.right ||
      a.rect.top - b.rect.top
    ));
  if (!candidates.length) return JSON.stringify({ found: false });
  const rect = candidates[0].rect;
  const x = rect.left + rect.width / 2;
  const y = rect.top + rect.height / 2;
  const scale = window.outerWidth / window.innerWidth;
  const xOffset = (window.outerWidth - (window.innerWidth * scale)) / 2;
  const yOffset = (window.outerHeight - (window.innerHeight * scale));
  return JSON.stringify({
    found: true,
    clickX: window.screenX + xOffset + (x * scale),
    clickY: window.screenY + yOffset + (y * scale)
  });
})()"""
    payload = json.loads(tab_js(expression))
    if payload.get("found"):
        return float(payload["clickX"]), float(payload["clickY"])

    fallback_expression = r"""(() => {
  const scale = window.outerWidth / window.innerWidth;
  const xOffset = (window.outerWidth - (window.innerWidth * scale)) / 2;
  const yOffset = (window.outerHeight - (window.innerHeight * scale));
  const x = window.innerWidth - 42;
  const y = 42;
  return JSON.stringify({
    found: true,
    clickX: window.screenX + xOffset + (x * scale),
    clickY: window.screenY + yOffset + (y * scale)
  });
})()"""
    fallback = json.loads(tab_js(fallback_expression))
    if not fallback.get("found"):
        raise RuntimeError("Could not find the Facebook page/profile switcher button.")
    return float(fallback["clickX"]), float(fallback["clickY"])


def profile_switcher_open() -> bool:
    text = body_text(16000)
    return "See all profiles" in text and ("Settings & privacy" in text or "Meta Business Suite" in text)


def profiles_pages_modal_open() -> bool:
    text = body_text(22000)
    return "Your profiles & Pages" in text and ("Search profiles" in text or "See more profiles" in text)


def press_escape_key() -> None:
    applescript_output(
        """
tell application "System Events"
  key code 53
end tell
"""
    )


def current_page_name_from_profile_switcher() -> str | None:
    expression = r"""(() => {
  const normalize = (value) => String(value || '').replace(/[\u200b\ufeff]/g, '').replace(/\s+/g, ' ').trim();
  const isVisible = (el) => {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  };
  const blocklist = new Set([
    'see all profiles',
    'settings & privacy',
    'meta business suite'
  ]);
  const allNodes = [...document.querySelectorAll('[role="button"],button,a,div,span')].filter(isVisible);
  const seeAll = allNodes.find((el) => normalize(el.innerText).toLowerCase().includes('see all profiles'));
  if (!seeAll) return '';

  let container = seeAll;
  for (let i = 0; i < 8 && container; i += 1) {
    const text = normalize(container.innerText).toLowerCase();
    if (text.includes('see all profiles') && (text.includes('settings & privacy') || text.includes('meta business suite'))) {
      break;
    }
    container = container.parentElement;
  }
  if (!container) return '';

  const seeAllRect = seeAll.getBoundingClientRect();
  const candidates = [...container.querySelectorAll('[role="button"],button,a,div,span')]
    .filter(isVisible)
    .map((el) => {
      const rect = el.getBoundingClientRect();
      const text = normalize(el.innerText);
      return { text, rect };
    })
    .filter((item) => item.text)
    .filter((item) => item.rect.bottom <= seeAllRect.top + 4)
    .filter((item) => !blocklist.has(item.text.toLowerCase()))
    .sort((a, b) => (a.rect.top - b.rect.top) || (a.rect.left - b.rect.left));

  const seen = new Set();
  for (const item of candidates) {
    const lowered = item.text.toLowerCase();
    if (seen.has(lowered)) continue;
    seen.add(lowered);
    return item.text;
  }
  return '';
})()"""
    value = str(tab_js(expression)).strip()
    return value or None


def open_profile_switcher(timeout_seconds: float) -> None:
    if profile_switcher_open():
        return
    wait_for_text(["Content Library", "Professional dashboard"], timeout_seconds)
    x, y = profile_switcher_button_point()
    click_screen_point(x, y)
    wait_for_text(["See all profiles", "Settings & privacy", "Meta Business Suite"], timeout_seconds)


def click_profile_icon(timeout_seconds: float) -> None:
    open_profile_switcher(timeout_seconds)


def current_facebook_page_name(timeout_seconds: float) -> str | None:
    open_profile_switcher(timeout_seconds)
    return current_page_name_from_profile_switcher()


def click_see_all_profiles(timeout_seconds: float) -> None:
    if profiles_pages_modal_open():
        return
    click_profile_icon(timeout_seconds)
    if not click_exact("See all profiles", contains=True):
        real_click_label("See all profiles", contains=True)
    wait_for_text(["Your profiles & Pages", "Search profiles", "See more profiles"], timeout_seconds)


def open_profiles_pages_modal(timeout_seconds: float) -> None:
    if profiles_pages_modal_open():
        return
    click_see_all_profiles(timeout_seconds)


def profiles_pages_search_point() -> tuple[float, float]:
    expression = r"""(() => {
  const normalize = (value) => String(value || '').replace(/[\u200b\ufeff]/g, '').replace(/\s+/g, ' ').trim();
  const isVisible = (el) => {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  };
  const candidates = [
    ...document.querySelectorAll('input, textarea, [role="searchbox"], [contenteditable="true"], div, span')
  ].filter((el) => isVisible(el)).map((el) => {
    const rect = el.getBoundingClientRect();
    const text = normalize(el.innerText);
    const aria = normalize(el.getAttribute('aria-label'));
    const placeholder = normalize(el.getAttribute('placeholder'));
    const value = normalize(el.value);
    return { el, rect, text, aria, placeholder, value };
  }).filter((item) => {
    const haystack = `${item.text} ${item.aria} ${item.placeholder} ${item.value}`.toLowerCase();
    return haystack.includes('search profiles') || haystack.includes('search profiles and pages');
  }).sort((a, b) => (a.rect.top - b.rect.top) || (a.rect.left - b.rect.left));
  if (!candidates.length) return JSON.stringify({ found: false });
  const rect = candidates[0].rect;
  const x = rect.left + Math.min(120, Math.max(50, rect.width * 0.25));
  const y = rect.top + rect.height / 2;
  const scale = window.outerWidth / window.innerWidth;
  const xOffset = (window.outerWidth - (window.innerWidth * scale)) / 2;
  const yOffset = (window.outerHeight - (window.innerHeight * scale));
  return JSON.stringify({
    found: true,
    clickX: window.screenX + xOffset + (x * scale),
    clickY: window.screenY + yOffset + (y * scale)
  });
})()"""
    payload = json.loads(tab_js(expression))
    if not payload.get("found"):
        raise RuntimeError("Could not find the Search profiles and Pages box.")
    return float(payload["clickX"]), float(payload["clickY"])


def focus_profiles_pages_search_box() -> None:
    if click_exact("Search profiles and Pages", contains=True):
        time.sleep(0.15)
        return
    try:
        real_click_label("Search profiles and Pages", contains=True)
        time.sleep(0.15)
        return
    except RuntimeError:
        pass
    x, y = profiles_pages_search_point()
    click_screen_point(x, y)
    time.sleep(0.15)


def click_profiles_pages_search_box() -> None:
    focus_profiles_pages_search_box()


def paste_text(text: str, *, clear_first: bool = True) -> None:
    subprocess.run(["pbcopy"], input=text, text=True, check=True)
    applescript = """
tell application "System Events"
  keystroke "a" using {command down}
  delay 0.08
  key code 51
  delay 0.08
  keystroke "v" using {command down}
end tell
"""
    if not clear_first:
        applescript = """
tell application "System Events"
  keystroke "v" using {command down}
end tell
"""
    subprocess.run(["osascript", "-"], input=applescript, text=True, check=True)


def page_result_visible(page_name: str) -> bool:
    lowered = page_name.strip().lower()
    if not lowered:
        return False
    expression = f"""(() => {{
  const normalize = (value) => String(value || '').replace(/[\\u200b\\ufeff]/g, '').replace(/\\s+/g, ' ').trim().toLowerCase();
  const isVisible = (el) => {{
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  }};
  const wanted = {json.dumps(lowered)};
  return [...document.querySelectorAll('div, span, [role="button"], button, a')]
    .filter((el) => isVisible(el))
    .some((el) => normalize(el.innerText).includes(wanted));
}})()"""
    return tab_js(expression).strip().lower() == "true"


def wait_for_page_result(page_name: str, timeout_seconds: float) -> None:
    deadline = time.time() + timeout_seconds
    last_text = ""
    while time.time() < deadline:
        last_text = body_text(6000)
        if page_result_visible(page_name):
            return
        time.sleep(0.18)
    snippet = re.sub(r"\s+", " ", last_text).strip()[:500]
    raise RuntimeError(
        f'Page "{page_name}" did not appear in profile/page search results. '
        f'Visible text snippet: {snippet}'
    )


def search_page_name(page_name: str, *, search_wait_seconds: float = PROFILE_SEARCH_WAIT_SECONDS) -> None:
    click_profiles_pages_search_box()
    paste_text(page_name, clear_first=True)
    time.sleep(search_wait_seconds)


def click_page_name_result(page_name: str, timeout_seconds: float) -> None:
    wait_for_page_result(page_name, timeout_seconds)
    if not click_exact(page_name, contains=False):
        if not click_exact(page_name, contains=True):
            real_click_label(page_name, contains=True)


def wait_for_page_switch_settle(settle_seconds: float = PROFILE_SWITCH_SETTLE_SECONDS) -> None:
    time.sleep(settle_seconds)


def switch_facebook_page_via_profiles_menu(
    target_page_name: str,
    timeout_seconds: float = 20.0,
    *,
    search_wait_seconds: float = PROFILE_SEARCH_WAIT_SECONDS,
    settle_seconds: float = PROFILE_SWITCH_SETTLE_SECONDS,
) -> None:
    page_name = target_page_name.strip()
    if not page_name:
        return

    try:
        current_page_name = current_facebook_page_name(timeout_seconds)
    except Exception:
        current_page_name = None

    if normalize_name(current_page_name) == normalize_name(page_name):
        try:
            press_escape_key()
            time.sleep(0.2)
        except Exception:
            pass
        return

    open_profiles_pages_modal(timeout_seconds)
    search_page_name(page_name, search_wait_seconds=search_wait_seconds)
    click_page_name_result(page_name, min(timeout_seconds, 10.0))
    wait_for_page_switch_settle(settle_seconds)

    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        text = body_text(22000)
        if "Your profiles & Pages" not in text:
            time.sleep(0.8)
            return
        time.sleep(0.2)
    raise RuntimeError(f'Could not finish switching Facebook page/profile to "{page_name}".')


def switch_facebook_page(target_page_name: str, timeout_seconds: float = 20.0) -> None:
    switch_facebook_page_via_profiles_menu(target_page_name, timeout_seconds)


def dismiss_stale_reel_dialog(timeout_seconds: float) -> None:
    text = body_text()
    if "Create reel" in text:
        return

    stale_markers = [
        "Edit reel",
        "Your reel is safe to publish!",
        "Trim video",
        "Closed Captions",
        "Text transcript",
    ]
    if not any(marker in text for marker in stale_markers):
        return

    if not click_exact("Close"):
        real_click_label("Close")

    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        text = body_text()
        if not any(marker in text for marker in stale_markers):
            return
        time.sleep(0.12)

    raise RuntimeError("Could not dismiss the existing Edit reel dialog.")


def open_add_video_dialog() -> None:
    labels = [
        ("Upload", False),
        ("Add video", True),
    ]
    for attempt in range(3):
        for label, contains in labels:
            if click_exact(label, contains=contains):
                time.sleep(0.35)
                if file_dialog_open():
                    return
            try:
                real_click_label(label, contains=contains)
                wait_for_file_dialog(2.0)
                return
            except RuntimeError:
                continue
        if attempt < 2:
            time.sleep(0.8)
    raise RuntimeError("File dialog did not open.")


def wait_for_text(snippets: list[str], timeout_seconds: float) -> str:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        body_text = str(
            tab_js("document.body ? document.body.innerText.slice(0, 12000) : ''")
        )
        for snippet in snippets:
            if snippet in body_text:
                return snippet
        time.sleep(0.18)
    raise RuntimeError(f"Timed out waiting for any of: {', '.join(snippets)}")


def wait_for_video_ready(video_path: Path, timeout_seconds: float) -> str:
    return wait_for_text(
        [
            video_path.name,
            "Replace video",
            "Your reel is safe to publish!",
        ],
        timeout_seconds,
    )


def click_next_to_audio(timeout_seconds: float) -> None:
    if click_next_button():
        try:
            wait_for_text(["Audio"], timeout_seconds)
            return
        except RuntimeError:
            pass
    if not click_next_button():
        raise RuntimeError('Could not click the bottom "Next" button.')
    wait_for_text(["Audio"], timeout_seconds)


def click_next_to_edit_review(timeout_seconds: float) -> None:
    target_snippets = ["Edit reel", "Your reel is safe to publish!"]
    if click_next_button():
        try:
            wait_for_text(target_snippets, timeout_seconds)
            return
        except RuntimeError:
            pass
    if not click_next_button():
        raise RuntimeError('Could not click the bottom "Next" button.')
    wait_for_text(target_snippets, timeout_seconds)


def click_next_to_share(timeout_seconds: float) -> str:
    target_snippets = ["Reel settings", "Scheduling options", "Share to your story"]
    deadline = time.time() + timeout_seconds
    last_error: RuntimeError | None = None

    while time.time() < deadline:
        if click_next_button():
            time.sleep(0.2)
        else:
            last_error = RuntimeError('Could not click the bottom "Next" button.')
            time.sleep(0.25)
            continue

        short_wait = min(4.0, max(0.75, deadline - time.time()))
        try:
            reached = wait_for_text(target_snippets, short_wait)
            if current_state().get("hasScheduling"):
                return reached
        except RuntimeError as error:
            last_error = error
        state = current_state()
        if state.get("hasScheduling"):
            return "Reel settings"
        time.sleep(0.35)

    if last_error is not None:
        raise last_error
    raise RuntimeError("Could not move from Edit reel to Reel settings.")


def settle_into_share_step(timeout_seconds: float) -> tuple[dict[str, object], str | None]:
    deadline = time.time() + timeout_seconds
    reached: str | None = None
    while time.time() < deadline:
        state = current_state()
        text = body_text(12000)
        if state.get("hasScheduling") or "Reel settings" in text or "Scheduling options" in text:
            return current_state(), reached or "Reel settings"
        if "Next" not in text:
            return state, reached
        if not click_next_button():
            return state, reached
        reached = "Next"
        time.sleep(1.1)
        pause_media()
    return current_state(), reached


def advance_with_next_until_share(timeout_seconds: float, max_clicks: int = 4) -> tuple[dict[str, object], str | None]:
    deadline = time.time() + timeout_seconds
    reached: str | None = None
    clicks_used = 0

    while time.time() < deadline:
        state = current_state()
        text = body_text(12000)
        if state.get("hasScheduling") or "Reel settings" in text or "Scheduling options" in text:
            return current_state(), reached or "Reel settings"

        if "Next" in text and clicks_used < max_clicks:
            if not click_next_button():
                time.sleep(0.35)
                continue
            clicks_used += 1
            reached = "Next"
            time.sleep(2.0 if clicks_used == 1 else 1.35)
            pause_media()
            continue

        time.sleep(0.35)

    return current_state(), reached


def main() -> int:
    args = parse_args()
    package_dir = Path(args.package_dir).expanduser()
    assets = ensure_package_dir(package_dir)
    video_path = Path(str(assets["video_path"]))

    activate_chrome()
    current_url = activate_exact_content_library_page()
    if args.page_name.strip():
        target_page_name = args.page_name.strip()
        current_page_name = None
        should_switch_page = True
        remembered_page_name = None
        try:
            remembered_page_name = remembered_page_for_chrome_profile(active_chrome_profile())
        except Exception:
            remembered_page_name = None
        if normalize_name(remembered_page_name) == normalize_name(target_page_name):
            should_switch_page = False
            status_print(f"[facebook] Page already active from saved Chrome+page memory: {target_page_name}")
            try:
                press_escape_key()
                time.sleep(0.2)
            except Exception:
                pass
        else:
            try:
                current_page_name = current_facebook_page_name(args.timeout)
            except Exception:
                current_page_name = None
            if normalize_name(current_page_name) == normalize_name(target_page_name):
                should_switch_page = False
                status_print(f"[facebook] Page already active: {target_page_name}")
                try:
                    press_escape_key()
                    time.sleep(0.2)
                except Exception:
                    pass
            else:
                status_print(f"[facebook] Switching target page: {target_page_name}")
        if should_switch_page:
            switch_facebook_page(args.page_name.strip(), args.timeout + 10.0)
            current_url = activate_exact_content_library_page()

    dismiss_stale_reel_dialog(args.timeout)
    ensure_reel_dialog_open(args.timeout)
    time.sleep(0.8)
    state = current_state()

    if state.get("hasScheduling"):
        status_print("[facebook] Reel dialog is already on the share step.")
        print(
            json.dumps(
                {
                    "status": "ok",
                    "step": "step3",
                    "page": "share",
                    "content_library_url": current_url,
                    "video_path": str(video_path),
                    "target_page_name": args.page_name.strip() or None,
                },
                indent=2,
            )
        )
        return 0

    if not state.get("hasAudio"):
        status_print(f"[facebook] Uploading video: {video_path.name}")
        open_add_video_dialog()
        choose_file(video_path)
        pause_preview_playback(min(args.upload_timeout, 4.0))
        wait_for_video_ready(video_path, args.upload_timeout)
        pause_preview_playback(1.2)
        pause_media()

        state = current_state()
        if state.get("hasAddVideo"):
            status_print("[facebook] Moving to edit step...")
            click_next_to_audio(args.timeout + 6.0)
            pause_media()
            time.sleep(NEXT_CLICK_DELAY_SECONDS)
            state = current_state()

    reached = None
    if not state.get("hasScheduling"):
        status_print("[facebook] Advancing through Next steps...")
        state, reached = advance_with_next_until_share(args.timeout + 14.0)
        if not state.get("hasScheduling"):
            state, settled_reached = settle_into_share_step(8.0)
            if settled_reached is not None:
                reached = settled_reached

    if not state.get("hasScheduling"):
        raise RuntimeError("Could not reach the share/scheduling step after clicking Next.")

    print(
        json.dumps(
            {
                "status": "ok",
                "step": "step3",
                "page": "share",
                "content_library_url": current_url,
                "video_path": str(video_path),
                "title_loaded": bool(assets.get("title")),
                "reached_text": reached,
                "target_page_name": args.page_name.strip() or None,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
