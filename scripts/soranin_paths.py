#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path


def _expand_path(raw: str | None) -> Path | None:
    value = (raw or "").strip()
    if not value:
        return None
    return Path(value).expanduser().resolve()


def _repo_root() -> Path:
    explicit = _expand_path(os.environ.get("SORANIN_CONTROL_SUITE_DIR"))
    if explicit is not None:
        if explicit.name == "scripts":
            return explicit.parent
        return explicit
    return Path(__file__).resolve().parents[1]


REPO_ROOT = _repo_root()
SCRIPTS_DIR = REPO_ROOT / "scripts"
LEGACY_DOWNLOADS_DIR = REPO_ROOT.parent
LEGACY_PACKAGES_ROOT = LEGACY_DOWNLOADS_DIR / "Soranin"


def _runtime_dir() -> Path:
    runtime = _expand_path(os.environ.get("SORANIN_RUNTIME_DIR"))
    if runtime is None:
        runtime = Path.home() / ".soranin"
    runtime.mkdir(parents=True, exist_ok=True)
    return runtime


RUNTIME_DIR = _runtime_dir()


def _packages_root() -> Path:
    explicit = _expand_path(os.environ.get("SORANIN_PACKAGES_ROOT") or os.environ.get("SORANIN_ROOT_DIR"))
    if explicit is not None:
        root = explicit
    elif LEGACY_PACKAGES_ROOT.exists():
        root = LEGACY_PACKAGES_ROOT
    else:
        root = RUNTIME_DIR / "Soranin"
    root.mkdir(parents=True, exist_ok=True)
    return root


ROOT_DIR = _packages_root()
FACEBOOK_STATE_PATH = ROOT_DIR / ".fb_reels_publish_state.json"


def runtime_data_file(filename: str, *, env_name: str | None = None) -> Path:
    if env_name:
        explicit = _expand_path(os.environ.get(env_name))
        if explicit is not None:
            explicit.parent.mkdir(parents=True, exist_ok=True)
            return explicit
    legacy = LEGACY_DOWNLOADS_DIR / filename
    if legacy.exists():
        return legacy
    target = RUNTIME_DIR / filename
    target.parent.mkdir(parents=True, exist_ok=True)
    return target


API_KEYS_FILE = runtime_data_file(".reels_api_keys.json", env_name="SORANIN_API_KEYS_FILE")


def script_path(name: str) -> Path:
    return SCRIPTS_DIR / name


CLICK_POINT_SWIFT = script_path("click_point.swift")
DEFAULT_FACEBOOK_PACKAGE = ROOT_DIR / "64_Reels_Package"
