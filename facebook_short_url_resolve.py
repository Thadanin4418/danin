#!/usr/bin/env python3
import json
import sys
import urllib.error
import urllib.parse
import urllib.request


USER_AGENT = "Mozilla/5.0"


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def probe(url: str, method: str) -> str:
    opener = urllib.request.build_opener(NoRedirectHandler())
    request = urllib.request.Request(
        url,
        method=method,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
    )
    try:
        with opener.open(request, timeout=10) as response:
            return response.headers.get("Location", "").strip()
    except urllib.error.HTTPError as exc:
        return str(exc.headers.get("Location", "") or "").strip()


def normalize(url: str) -> str:
    raw_url = str(url or "").strip()
    parsed = urllib.parse.urlparse(raw_url)
    host = (parsed.hostname or "").lower()
    if host != "fb.watch" and not host.endswith(".fb.watch"):
        return raw_url

    location = ""
    for method in ("HEAD", "GET"):
        location = probe(raw_url, method)
        if location:
            break

    if not location:
        return raw_url

    next_url = urllib.parse.urljoin(raw_url, location)
    next_parsed = urllib.parse.urlparse(next_url)
    query = urllib.parse.parse_qs(next_parsed.query)
    video_id = (query.get("v") or [""])[0].strip()
    next_host = (next_parsed.hostname or "").lower()
    if next_host.endswith(".facebook.com") and video_id:
        return f"https://www.facebook.com/watch/?v={video_id}"

    return next_url


def main() -> int:
    raw_url = sys.argv[1] if len(sys.argv) > 1 else ""
    normalized_url = normalize(raw_url)
    print(json.dumps({"ok": True, "normalized_url": normalized_url}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
