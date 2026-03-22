#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import time
from pathlib import Path

from soranin_paths import CLICK_POINT_SWIFT


CLICK_POINT_BINARY = Path("/tmp/click_point")
TARGET_URL = "https://web.facebook.com/professional_dashboard/content/content_library"
CONTENT_LIBRARY_MARKER = "content_library"


def status_print(message: str) -> None:
    print(message, flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Step 2 for Facebook Reels upload: open the Create > Reel dialog in the already-open Chrome window."
    )
    parser.add_argument("--timeout", type=float, default=10.0, help="Timeout in seconds.")
    return parser.parse_args()


def run_osascript_lines(lines: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(lines, text=True, capture_output=True, check=False)


def jxa_output(source: str) -> str:
    result = subprocess.run(
        ["osascript", "-l", "JavaScript"],
        input=source,
        text=True,
        capture_output=True,
        check=False,
    )
    output = (result.stdout or "").strip() or (result.stderr or "").strip()
    if result.returncode != 0:
        raise RuntimeError(output or "JXA command failed.")
    return output


def chrome_active_url() -> str:
    return jxa_output(
        """
var chrome = Application("Google Chrome");
chrome.includeStandardAdditions = true;
console.log(String(chrome.windows[0].activeTab().url()));
"""
    )


def activate_chrome() -> None:
    last_message = "Could not activate Google Chrome."
    for _ in range(8):
        subprocess.run(["open", "-a", "Google Chrome"], text=True, capture_output=True, check=False)
        time.sleep(0.8)
        result = run_osascript_lines(["osascript", "-e", 'tell application "Google Chrome" to activate'])
        if result.returncode == 0:
            return
        probe = run_osascript_lines(
            ["osascript", "-e", 'tell application "Google Chrome" to get URL of active tab of front window']
        )
        if probe.returncode == 0:
            return
        last_message = (result.stderr or result.stdout).strip() or last_message
    raise RuntimeError(last_message)


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


def activate_exact_content_library_page(timeout_seconds: float = 20.0) -> str:
    open_exact_content_library_url()
    deadline = time.time() + timeout_seconds
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


def reel_dialog_state() -> dict[str, object]:
    expression = r"""(() => {
  const text = document.body ? document.body.innerText : '';
  return JSON.stringify({
    hasCreateReel: /Create reel/i.test(text),
    hasAddVideo: /Add video|drag and drop/i.test(text),
    hasPreview: /Upload Preview|video preview/i.test(text)
  });
})()"""
    return json.loads(tab_js(expression))


def body_text(limit: int = 20000) -> str:
    return str(tab_js(f"document.body ? document.body.innerText.slice(0, {limit}) : ''"))


def wait_for_library_ready(timeout_seconds: float) -> None:
    deadline = time.time() + timeout_seconds
    reloaded = False
    while time.time() < deadline:
        text = body_text(12000)
        if "Content Library" in text and ("Create" in text or "Published" in text or "Scheduled" in text):
            return
        if not reloaded and time.time() + 5.0 < deadline:
            open_exact_content_library_url()
            reloaded = True
        time.sleep(0.25)
    raise RuntimeError("Content Library page did not finish loading.")


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
  const el = matches[{ 'matches.length - 1' if use_last else '0' }];
  if (!el) return false;
  el.click();
  return true;
}})()"""
    return tab_js(expression).strip().lower() == "true"


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
        close_x, close_y = close_button_click_point()
        click_screen_point(close_x, close_y)

    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        text = body_text()
        if not any(marker in text for marker in stale_markers):
            return
        time.sleep(0.15)

    raise RuntimeError("Could not dismiss the existing Edit reel dialog.")


def close_button_click_point() -> tuple[float, float]:
    expression = r"""(() => {
  const normalize = (s) => String(s || '').replace(/[\u200b\ufeff]/g, '').replace(/\s+/g, ' ').trim();
  const isVisible = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const button = [...document.querySelectorAll('[role="button"],button,div,span,a')]
    .find((el) => isVisible(el) && normalize(el.getAttribute('aria-label')) === 'Close');
  if (!button) return JSON.stringify({found: false});
  const r = button.getBoundingClientRect();
  const x = r.left + r.width / 2;
  const y = r.top + r.height / 2;
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
        raise RuntimeError("Close button not found.")
    return float(payload["clickX"]), float(payload["clickY"])


def create_dropdown_click_point() -> tuple[float, float]:
    expression = r"""(() => {
  const normalize = (s) => String(s || '').replace(/[\u200b\ufeff]/g, '').replace(/\s+/g, ' ').trim();
  const isVisible = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const raw = [...document.querySelectorAll('[role="button"],button,div,span,a')]
    .find((el) => {
      if (!isVisible(el)) return false;
      const text = normalize(el.innerText);
      const aria = normalize(el.getAttribute('aria-label'));
      return text === 'Create' || aria === 'Create';
    });
  const create = raw ? (raw.closest('[role="button"],button,a') || raw) : null;
  if (!create) return JSON.stringify({error: 'Create button not found'});
  const r = create.getBoundingClientRect();
  const x = r.right - 18;
  const y = r.top + r.height / 2;
  const scale = window.outerWidth / window.innerWidth;
  const xOffset = (window.outerWidth - (window.innerWidth * scale)) / 2;
  const yOffset = (window.outerHeight - (window.innerHeight * scale));
  return JSON.stringify({
    clickX: window.screenX + xOffset + (x * scale),
    clickY: window.screenY + yOffset + (y * scale)
  });
})()"""
    payload = json.loads(tab_js(expression))
    if "error" in payload:
        raise RuntimeError(str(payload["error"]))
    return float(payload["clickX"]), float(payload["clickY"])


def reel_menuitem_click_point() -> tuple[float, float] | None:
    expression = r"""(() => {
  const normalize = (s) => String(s || '').replace(/[\u200b\ufeff]/g, '').replace(/\s+/g, ' ').trim();
  const isVisible = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const item = [...document.querySelectorAll('[role="menuitem"],a,div,button,span')]
    .find((el) => isVisible(el) && normalize(el.innerText) === 'Reel');
  if (!item) return JSON.stringify({found: false});
  const r = item.getBoundingClientRect();
  const x = r.left + r.width / 2;
  const y = r.top + r.height / 2;
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
        return None
    return float(payload["clickX"]), float(payload["clickY"])


def wait_for_reel_menuitem(timeout_seconds: float) -> tuple[float, float]:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        point = reel_menuitem_click_point()
        if point is not None:
            return point
        time.sleep(0.15)
    raise RuntimeError("Reel menu item did not appear.")


def click_reel_menuitem(timeout_seconds: float) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if click_exact("Reel"):
            return True
        time.sleep(0.15)
    return False


def wait_for_create_dropdown(timeout_seconds: float) -> tuple[float, float]:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            return create_dropdown_click_point()
        except RuntimeError:
            time.sleep(0.15)
    raise RuntimeError("Create button did not appear.")


def wait_for_reel_dialog(timeout_seconds: float) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        state = reel_dialog_state()
        if state.get("hasCreateReel") and state.get("hasAddVideo"):
            return
        time.sleep(0.2)
    raise RuntimeError("Create reel dialog did not open.")


def main() -> int:
    args = parse_args()
    activate_chrome()
    current_url = activate_exact_content_library_page(max(args.timeout, 12.0))
    wait_for_library_ready(max(args.timeout, 12.0))
    dismiss_stale_reel_dialog(args.timeout)

    state = reel_dialog_state()
    if state.get("hasCreateReel") and state.get("hasAddVideo"):
        status_print("[facebook] Reel dialog is already open.")
        print(json.dumps({"status": "ok", "step": "step2", "dialog": "already_open"}, indent=2))
        return 0

    status_print("[facebook] Opening Create menu...")
    opened_menu = click_exact("Create")
    if not opened_menu:
        create_x, create_y = wait_for_create_dropdown(args.timeout)
        click_screen_point(create_x, create_y)

    status_print("[facebook] Waiting for Reel menu item...")
    if click_reel_menuitem(args.timeout):
        status_print("[facebook] Clicking Reel...")
    else:
        reel_x, reel_y = wait_for_reel_menuitem(args.timeout)
        status_print("[facebook] Clicking Reel...")
        click_screen_point(reel_x, reel_y)

    status_print("[facebook] Waiting for Create reel dialog...")
    wait_for_reel_dialog(args.timeout)

    print(json.dumps({"status": "ok", "step": "step2", "dialog": "open"}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
