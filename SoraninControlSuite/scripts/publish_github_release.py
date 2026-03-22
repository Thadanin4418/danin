#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


REPO_ROOT = repo_root()
DEFAULT_NOTES_PATH = REPO_ROOT / "RELEASE_NOTES.md"
DEFAULT_ASSET_DIR = REPO_ROOT.parent
EXCLUDED_PARTS = {".git", "__pycache__", ".DS_Store"}
EXCLUDED_SUFFIXES = {".pyc", ".pyo", ".tmp", ".log"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a release zip, create/push a tag, and create or update a GitHub release."
    )
    parser.add_argument("--tag", required=True, help="Release tag, for example v0.1.1")
    parser.add_argument("--name", default="", help="Optional release title. Default: repo name + tag.")
    parser.add_argument(
        "--notes",
        default=str(DEFAULT_NOTES_PATH),
        help="Markdown file used as the GitHub release body.",
    )
    parser.add_argument(
        "--repo-dir",
        default=str(REPO_ROOT),
        help="Path to the git repository root.",
    )
    parser.add_argument(
        "--asset-dir",
        default=str(DEFAULT_ASSET_DIR),
        help="Folder where the release zip should be written.",
    )
    parser.add_argument(
        "--asset-name",
        default="",
        help="Optional custom zip filename.",
    )
    parser.add_argument(
        "--target",
        default="main",
        help="Target commitish for the GitHub release metadata. Default: main.",
    )
    parser.add_argument("--draft", action="store_true", help="Create the GitHub release as draft.")
    parser.add_argument("--prerelease", action="store_true", help="Mark the GitHub release as prerelease.")
    parser.add_argument("--skip-asset", action="store_true", help="Do not upload a zip asset.")
    parser.add_argument("--skip-tag", action="store_true", help="Do not create or push the tag.")
    parser.add_argument(
        "--replace-asset",
        action="store_true",
        help="If an asset with the same name already exists, delete and upload the new one.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would happen without creating tags or touching GitHub.",
    )
    return parser.parse_args()


def run_git(repo_dir: Path, *args: str, capture: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo_dir), *args],
        text=True,
        capture_output=capture,
        check=False,
    )
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "").strip() or "git command failed"
        raise RuntimeError(message)
    return (result.stdout or "").strip()


def github_owner_repo(repo_dir: Path) -> tuple[str, str]:
    remote = run_git(repo_dir, "config", "--get", "remote.origin.url")
    url = remote.strip()
    if url.startswith("git@github.com:"):
        path = url.split(":", 1)[1]
    elif url.startswith("https://github.com/"):
        path = url.split("https://github.com/", 1)[1]
    else:
        raise RuntimeError(f"Unsupported GitHub remote URL: {url}")
    path = path.removesuffix(".git").strip("/")
    parts = path.split("/", 1)
    if len(parts) != 2:
        raise RuntimeError(f"Unable to parse owner/repo from remote URL: {url}")
    return parts[0], parts[1]


def git_credential(host: str = "github.com") -> tuple[str, str]:
    request = f"protocol=https\nhost={host}\n\n"
    result = subprocess.run(
        ["git", "credential", "fill"],
        input=request,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("Unable to read GitHub credentials from git credential helper.")
    data: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            data[key] = value
    username = data.get("username", "").strip()
    password = data.get("password", "").strip()
    if not username or not password:
        raise RuntimeError("Missing GitHub credentials in git credential helper.")
    return username, password


def github_headers() -> dict[str, str]:
    username, password = git_credential()
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return {
        "Authorization": f"Basic {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "soranin-release-publisher",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def github_json(url: str, *, method: str = "GET", payload: dict | None = None, headers: dict[str, str] | None = None) -> dict:
    body = None
    request_headers = dict(headers or {})
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=body, headers=request_headers, method=method)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read().decode("utf-8"))


def github_delete(url: str, *, headers: dict[str, str]) -> None:
    request = urllib.request.Request(url, headers=headers, method="DELETE")
    with urllib.request.urlopen(request):
        return


def release_title(repo_dir: Path, tag: str, explicit: str) -> str:
    if explicit.strip():
        return explicit.strip()
    return f"{repo_dir.name} {tag}"


def release_asset_name(repo_dir: Path, tag: str, explicit: str) -> str:
    if explicit.strip():
        return explicit.strip()
    safe_tag = tag.replace("/", "-")
    return f"{repo_dir.name}_release_{safe_tag}.zip"


def build_release_zip(repo_dir: Path, output_path: Path) -> Path:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(repo_dir.rglob("*")):
            relative = path.relative_to(repo_dir)
            if any(part in EXCLUDED_PARTS for part in relative.parts):
                continue
            if path.is_dir():
                continue
            if path.suffix.lower() in EXCLUDED_SUFFIXES:
                continue
            archive.write(path, arcname=str(Path(repo_dir.name) / relative))
    return output_path


def ensure_tag(repo_dir: Path, tag: str, *, dry_run: bool) -> str:
    head_sha = run_git(repo_dir, "rev-parse", "HEAD")
    has_tag = False
    try:
        run_git(repo_dir, "rev-parse", f"refs/tags/{tag}")
        has_tag = True
    except RuntimeError:
        has_tag = False

    if not has_tag:
        if dry_run:
            return head_sha
        run_git(repo_dir, "tag", "-a", tag, "-m", f"{repo_dir.name} {tag}")
    if not dry_run:
        run_git(repo_dir, "push", "origin", tag)
    return head_sha


def upload_asset(upload_url_template: str, asset_path: Path, *, headers: dict[str, str]) -> dict:
    upload_url = upload_url_template.split("{", 1)[0] + "?" + urllib.parse.urlencode({"name": asset_path.name})
    upload_headers = dict(headers)
    upload_headers["Content-Type"] = mimetypes.guess_type(str(asset_path))[0] or "application/zip"
    request = urllib.request.Request(upload_url, data=asset_path.read_bytes(), headers=upload_headers, method="POST")
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read().decode("utf-8"))


def create_or_update_release(
    owner: str,
    repo: str,
    tag: str,
    name: str,
    notes: str,
    target: str,
    *,
    draft: bool,
    prerelease: bool,
    asset_path: Path | None,
    replace_asset: bool,
    dry_run: bool,
) -> dict:
    if dry_run:
        return {
            "html_url": f"https://github.com/{owner}/{repo}/releases/tag/{tag}",
            "created": False,
            "asset_name": asset_path.name if asset_path else None,
            "asset_url": None,
        }

    headers = github_headers()
    base = f"https://api.github.com/repos/{owner}/{repo}"
    release = None
    existing = False
    try:
        release = github_json(f"{base}/releases/tags/{tag}", headers=headers)
        existing = True
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"GitHub API error checking release: {exc.code} {detail}")

    payload = {
        "tag_name": tag,
        "target_commitish": target,
        "name": name,
        "body": notes,
        "draft": draft,
        "prerelease": prerelease,
        "generate_release_notes": False,
    }
    if existing:
        release = github_json(f"{base}/releases/{release['id']}", method="PATCH", payload=payload, headers=headers)
    else:
        release = github_json(f"{base}/releases", method="POST", payload=payload, headers=headers)

    asset_result = None
    if asset_path is not None:
        existing_asset = None
        for asset in release.get("assets") or []:
            if asset.get("name") == asset_path.name:
                existing_asset = asset
                break
        if existing_asset and replace_asset:
            github_delete(f"{base}/releases/assets/{existing_asset['id']}", headers=headers)
            existing_asset = None
        if existing_asset is None:
            asset_result = upload_asset(release["upload_url"], asset_path, headers=headers)
        else:
            asset_result = existing_asset

    return {
        "html_url": release.get("html_url"),
        "created": not existing,
        "asset_name": asset_result.get("name") if asset_result else None,
        "asset_url": asset_result.get("browser_download_url") if asset_result else None,
    }


def main() -> int:
    args = parse_args()
    repo_dir = Path(args.repo_dir).expanduser().resolve()
    notes_path = Path(args.notes).expanduser().resolve()
    asset_dir = Path(args.asset_dir).expanduser().resolve()

    if not repo_dir.exists():
        raise SystemExit(f"Repo folder not found: {repo_dir}")
    if not notes_path.exists():
        raise SystemExit(f"Release notes file not found: {notes_path}")

    owner, repo = github_owner_repo(repo_dir)
    asset_path = None
    if not args.skip_asset:
        asset_name = release_asset_name(repo_dir, args.tag, args.asset_name)
        asset_path = build_release_zip(repo_dir, asset_dir / asset_name)

    if not args.skip_tag:
        ensure_tag(repo_dir, args.tag, dry_run=args.dry_run)

    release = create_or_update_release(
        owner,
        repo,
        args.tag,
        release_title(repo_dir, args.tag, args.name),
        notes_path.read_text(encoding="utf-8").strip(),
        args.target,
        draft=args.draft,
        prerelease=args.prerelease,
        asset_path=asset_path,
        replace_asset=args.replace_asset,
        dry_run=args.dry_run,
    )

    print(
        json.dumps(
            {
                "tag": args.tag,
                "repo": f"{owner}/{repo}",
                "release_url": release["html_url"],
                "asset_path": str(asset_path) if asset_path else None,
                "asset_url": release.get("asset_url"),
                "dry_run": args.dry_run,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
