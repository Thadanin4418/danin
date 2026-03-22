#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import html
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from soranin_paths import API_KEYS_FILE, ROOT_DIR

try:
    from openai import OpenAI
except ImportError:
    OpenAI = None


ROOT_DEFAULT = ROOT_DIR
VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".avi", ".mkv"}
TITLE_PLACEHOLDER = "Add action-based English title here 😮 #ViralClip #TrendingReel #MustWatch #ReelsDaily #ForYou"
TARGET_SPEED = 0.90
FINAL_DURATION_LIMIT = 15.0
POST_INTERVAL_MINUTES = 30
OPENAI_TITLE_MODEL = "gpt-5.4"
OPENAI_TRANSCRIBE_MODEL = "gpt-4o-transcribe"
OPENAI_REQUEST_TIMEOUT_SECONDS = 90.0
OPENAI_IMAGE_MODEL = "gpt-image-1"
OPENAI_IMAGE_MODEL_FALLBACK = "gpt-image-1.5"
OPENAI_VIDEO_MODEL = "sora-2"
GEMINI_TITLE_MODEL = "gemini-3-flash-preview"
GEMINI_PRO_MODEL = "gemini-3-pro-preview"
GEMINI_25_PRO_MODEL = "gemini-2.5-pro"
GEMINI_IMAGE_MODEL_FLASH = "gemini-3.1-flash-image-preview"
GEMINI_IMAGE_MODEL_PRO = "gemini-3-pro-image-preview"
GEMINI_VIDEO_MODEL = "veo-3.1-generate-preview"
GEMINI_FILES_BASE_URL = "https://generativelanguage.googleapis.com"
GEMINI_FILE_POLL_SECONDS = 5
GEMINI_FILE_TIMEOUT_SECONDS = 300
GEMINI_VIDEO_POLL_SECONDS = 10
GEMINI_VIDEO_TIMEOUT_SECONDS = 900
TEMPORARY_API_STATUS_CODES = {429, 500, 502, 503, 504}
TEMPORARY_API_RETRY_DELAYS_SECONDS = (1.5, 3.0, 6.0)
FACE_EDIT_VIDEO_MAX_FRAMES = 36
FACE_EDIT_VIDEO_MIN_FPS = 0.5
FACE_EDIT_VIDEO_MAX_FPS = 4.0
FACE_EDIT_VIDEO_OUTPUT_FPS = 24
FACE_EDIT_VIDEO_FRAME_MAX_WIDTH = 1024
ANALYSIS_FRAME_COUNT = 8
ANALYSIS_FRAME_WIDTH = 512
BATCH_STAGE_COUNT = 5
MAX_PARALLEL_VIDEOS = 4
AI_PROVIDER_DEFAULT = "openai"
AI_PROVIDER_OPENAI = "openai"
AI_PROVIDER_GEMINI = "gemini"
AI_MODEL_GEMINI_FLASH = "gemini_3_flash"
AI_MODEL_GEMINI_PRO = "gemini_3_pro"
AI_MODEL_GEMINI_25_PRO = "gemini_25_pro"
AI_MODEL_OPENAI_GPT54 = "openai_gpt54"
AI_CHAT_MEDIA_DIR_NAME = "AI_Chat_Media"
NO_CLEAR_SPOKEN_WORDS_PLACEHOLDER = "[No clear spoken words detected]"
NOISE_WORDS = {
    "download",
    "downloads",
    "video",
    "videos",
    "clip",
    "clips",
    "copy",
    "sora",
    "facebook",
    "tweeload",
    "media",
    "grok",
    "prompt",
    "new",
    "reels",
    "reel",
    "package",
    "done",
    "edit",
    "edited",
    "hd",
    "app",
    "wildz",
    "snapsora",
    "watermark",
    "mark",
    "no",
}


@dataclass
class VideoInfo:
    duration: float
    has_audio: bool


@dataclass
class AnalysisFrame:
    index: int
    timestamp: float
    path: Path


@dataclass
class VideoAssetAnalysis:
    title: str
    thumbnail_frame_index: int
    thumbnail_timestamp: float
    video_topic: str = ""
    thumbnail_reason: str = ""


@dataclass
class SocialPolicyAudit:
    facebook_reels: str
    youtube: str
    tiktok: str
    issues: list[str]
    guidance: str
    viewer_hook: str = ""


_batch_progress_lock = threading.Lock()
_batch_progress_completed_units = 0
_batch_progress_total_units = 0


def find_binary(name: str, fallbacks: list[str]) -> str | None:
    for candidate in fallbacks:
        if Path(candidate).exists():
            return candidate
    return shutil.which(name)


FFMPEG = find_binary(
    "ffmpeg",
    [
        "/Users/nin/Library/Python/3.9/lib/python/site-packages/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1",
    ],
)
FFPROBE = find_binary("ffprobe", [])
def run(cmd: list[str], expect_success: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if expect_success and proc.returncode != 0:
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr.strip()}"
        )
    return proc


def status_print(message: str) -> None:
    print(message, flush=True)


def load_saved_api_keys() -> dict[str, str]:
    if not API_KEYS_FILE.exists():
        return {}
    try:
        payload = json.loads(API_KEYS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}
    if not isinstance(payload, dict):
        return {}
    return {str(key): str(value) for key, value in payload.items() if isinstance(value, str)}


def resolve_api_key(*names: str) -> str | None:
    saved = load_saved_api_keys()
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
        value = saved.get(name)
        if value:
            return value
    return None


def resolve_setting(name: str) -> str | None:
    value = os.environ.get(name)
    if value:
        return value
    return load_saved_api_keys().get(name)


def resolve_ai_provider() -> str:
    model = (resolve_setting("AI_MODEL") or "").strip().lower()
    if model in {AI_MODEL_GEMINI_FLASH, AI_MODEL_GEMINI_PRO, AI_MODEL_GEMINI_25_PRO}:
        return AI_PROVIDER_GEMINI
    if model == AI_MODEL_OPENAI_GPT54:
        return AI_PROVIDER_OPENAI
    value = (resolve_setting("AI_PROVIDER") or AI_PROVIDER_DEFAULT).strip().lower()
    if value in {AI_PROVIDER_OPENAI, AI_PROVIDER_GEMINI}:
        return value
    return AI_PROVIDER_DEFAULT


def resolve_ai_model() -> str:
    value = (resolve_setting("AI_MODEL") or "").strip().lower()
    if value in {AI_MODEL_GEMINI_FLASH, AI_MODEL_GEMINI_PRO, AI_MODEL_GEMINI_25_PRO, AI_MODEL_OPENAI_GPT54}:
        return value
    provider = (resolve_setting("AI_PROVIDER") or AI_PROVIDER_DEFAULT).strip().lower()
    if provider == AI_PROVIDER_GEMINI:
        return AI_MODEL_GEMINI_FLASH
    return AI_MODEL_OPENAI_GPT54


def resolve_openai_model() -> str:
    return OPENAI_TITLE_MODEL


def resolve_gemini_model() -> str:
    model = resolve_ai_model()
    if model == AI_MODEL_GEMINI_PRO:
        return GEMINI_PRO_MODEL
    if model == AI_MODEL_GEMINI_25_PRO:
        return GEMINI_25_PRO_MODEL
    return GEMINI_TITLE_MODEL


def ai_model_label() -> str:
    model = resolve_ai_model()
    if model == AI_MODEL_GEMINI_PRO:
        return "Gemini 3 Pro Preview"
    if model == AI_MODEL_GEMINI_25_PRO:
        return "Gemini 2.5 Pro"
    if model == AI_MODEL_OPENAI_GPT54:
        return "OpenAI GPT-5.4"
    return "Gemini 3 Flash + Custom"


def provider_label(provider: str) -> str:
    return "Gemini" if provider == AI_PROVIDER_GEMINI else "OpenAI"


def ai_chat_media_dir() -> Path:
    path = ROOT_DEFAULT / AI_CHAT_MEDIA_DIR_NAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def safe_media_slug(text: str, *, fallback: str = "media", max_length: int = 48) -> str:
    normalized = unicodedata.normalize("NFKD", text)
    ascii_only = normalized.encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-zA-Z0-9]+", "_", ascii_only).strip("_").lower()
    if not slug:
        slug = fallback
    return slug[:max_length].rstrip("_") or fallback


def build_ai_chat_media_path(kind: str, prompt: str, suffix: str) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    prompt_slug = safe_media_slug(prompt, fallback=kind)
    return ai_chat_media_dir() / f"{timestamp}_{kind}_{prompt_slug}{suffix}"


def choose_extension_for_mime_type(mime_type: str, fallback: str = ".bin") -> str:
    mime_type = (mime_type or "").strip().lower()
    if mime_type == "image/png":
        return ".png"
    if mime_type in {"image/jpeg", "image/jpg"}:
        return ".jpg"
    if mime_type == "image/webp":
        return ".webp"
    if mime_type == "video/mp4":
        return ".mp4"
    guessed = mimetypes.guess_extension(mime_type)
    if guessed:
        return guessed
    return fallback


def preferred_openai_image_size(prompt: str) -> str:
    lowered = prompt.lower()
    vertical_markers = ("9:16", "vertical", "portrait", "phone", "story", "reel", "shorts", "tiktok")
    horizontal_markers = ("16:9", "landscape", "horizontal", "wide", "widescreen", "banner", "youtube")
    if any(marker in lowered for marker in vertical_markers):
        return "1024x1792"
    if any(marker in lowered for marker in horizontal_markers):
        return "1536x1024"
    return "1024x1024"


def preferred_gemini_image_aspect_ratio(prompt: str) -> str:
    lowered = prompt.lower()
    vertical_markers = ("9:16", "vertical", "portrait", "phone", "story", "reel", "shorts", "tiktok")
    horizontal_markers = ("16:9", "landscape", "horizontal", "wide", "widescreen", "banner", "youtube")
    if any(marker in lowered for marker in vertical_markers):
        return "9:16"
    if any(marker in lowered for marker in horizontal_markers):
        return "16:9"
    return "1:1"


def preferred_openai_video_size(prompt: str) -> str:
    lowered = prompt.lower()
    horizontal_markers = ("16:9", "landscape", "horizontal", "wide", "widescreen", "youtube")
    if any(marker in lowered for marker in horizontal_markers):
        return "1280x720"
    return "720x1280"


def preferred_gemini_video_aspect_ratio(prompt: str) -> str:
    lowered = prompt.lower()
    horizontal_markers = ("16:9", "landscape", "horizontal", "wide", "widescreen", "youtube")
    if any(marker in lowered for marker in horizontal_markers):
        return "16:9"
    return "9:16"


def resolve_gemini_image_model() -> str:
    return GEMINI_IMAGE_MODEL_PRO if resolve_ai_model() == AI_MODEL_GEMINI_PRO else GEMINI_IMAGE_MODEL_FLASH


def api_error_status_code(exc: BaseException) -> int | None:
    if isinstance(exc, urllib.error.HTTPError):
        return int(exc.code)
    for attr in ("status_code", "code", "status"):
        value = getattr(exc, attr, None)
        if isinstance(value, int):
            return value
    response = getattr(exc, "response", None)
    if response is not None:
        for attr in ("status_code", "code", "status"):
            value = getattr(response, attr, None)
            if isinstance(value, int):
                return value
    return None


def api_error_text(exc: BaseException) -> str:
    parts: list[str] = []

    def add(value: object) -> None:
        if value is None:
            return
        if isinstance(value, (dict, list)):
            try:
                text = json.dumps(value, ensure_ascii=False)
            except Exception:
                text = str(value)
        else:
            text = str(value)
        text = text.strip()
        if text and text not in parts:
            parts.append(text)

    add(exc)
    for attr in ("message", "body", "details", "error"):
        add(getattr(exc, attr, None))

    response = getattr(exc, "response", None)
    if response is not None:
        for attr in ("text", "reason", "body"):
            add(getattr(response, attr, None))

    if isinstance(exc, urllib.error.HTTPError):
        add(exc.reason)
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:
            body = ""
        add(body)

    return "\n".join(parts).strip()


def api_issue_message(provider: str, exc: BaseException) -> str | None:
    text = api_error_text(exc).lower()
    status_code = api_error_status_code(exc)

    openai_quota_markers = (
        "insufficient_quota",
        "billing_hard_limit_reached",
        "exceeded your current quota",
        "credit balance",
        "out of credits",
        "billing",
    )
    gemini_quota_markers = (
        "resource_exhausted",
        "quota",
        "billing",
        "free_tier",
        "daily limit",
        "credit",
    )
    openai_policy_markers = (
        "content_policy_violation",
        "safety system",
        "request was rejected",
        "violates our content policy",
        "violates policy",
        "moderation",
        "unsafe content",
    )
    gemini_policy_markers = (
        "safety",
        "blocked",
        "blocked due to safety",
        "safety settings",
        "prohibited_content",
        "unsafe",
        "harm category",
        "responsible ai",
    )

    if provider == AI_PROVIDER_OPENAI:
        if status_code in {500, 502, 503, 504}:
            return "OpenAI service កំពុងរវល់ ឬមានបញ្ហាបណ្តោះអាសន្ន។ សូមរង់ចាំបន្តិច rồiសាកម្ដងទៀត។"
        if any(marker in text for marker in openai_policy_markers):
            return "OpenAI បានបដិសេធរូបភាព/thumbnail នេះដោយសារ safety ឬ content policy របស់ក្រុមហ៊ុន។ សូមបន្ថយភាពសិចស៊ី ការហិង្សា ការបោកប្រាស់ clickbait ឬ content ដែលមានហានិភ័យ ហើយសាកម្ដងទៀត។"
        if any(marker in text for marker in openai_quota_markers):
            return "OpenAI API key អស់លុយ ឬអស់ quota ហើយ។ សូមបញ្ចូល balance ឬប្តូរ OpenAI key ថ្មី។"
        if "quota" in text and "rate limit" not in text:
            return "OpenAI API key អស់លុយ ឬអស់ quota ហើយ។ សូមបញ្ចូល balance ឬប្តូរ OpenAI key ថ្មី។"
        if status_code in {401, 403} and any(
            marker in text
            for marker in (
                "incorrect api key",
                "invalid api key",
                "invalid_api_key",
                "unauthorized",
                "authentication",
            )
        ):
            return "OpenAI API key មិនត្រឹមត្រូវ ឬគ្មានសិទ្ធិប្រើទេ។ សូមពិនិត្យ ឬប្តូរ OpenAI key ថ្មី។"
        return None

    if status_code in {500, 502, 503, 504}:
        return "Gemini service កំពុងរវល់ ឬមានបញ្ហាបណ្តោះអាសន្ន។ សូមរង់ចាំបន្តិច rồiសាកម្ដងទៀត។"
    if any(marker in text for marker in gemini_policy_markers):
        return "Gemini បានបដិសេធរូបភាព/thumbnail នេះដោយសារ safety ឬ content policy របស់ក្រុមហ៊ុន។ សូមបន្ថយភាពសិចស៊ី ការហិង្សា ការបោកប្រាស់ clickbait ឬ content ដែលមានហានិភ័យ ហើយសាកម្ដងទៀត។"
    if any(marker in text for marker in gemini_quota_markers):
        if "service_disabled" not in text and "api key not valid" not in text:
            return "Gemini API key អស់លុយ ឬអស់ quota ហើយ។ សូមបញ្ចូល quota/billing ឬប្តូរ Gemini key ថ្មី។"
    if status_code in {401, 403} and any(
        marker in text
        for marker in (
            "api key not valid",
            "api_key_invalid",
            "permission_denied",
            "unauthenticated",
            "authentication",
        )
    ):
        return "Gemini API key មិនត្រឹមត្រូវ ឬគ្មានសិទ្ធិប្រើទេ។ សូមពិនិត្យ ឬប្តូរ Gemini key ថ្មី។"
    return None


def describe_provider_error(provider: str, exc: BaseException) -> str:
    issue_message = api_issue_message(provider, exc)
    if issue_message:
        return issue_message
    status_code = api_error_status_code(exc)
    text = api_error_text(exc)
    if status_code == 400:
        lowered = text.lower()
        if provider == AI_PROVIDER_OPENAI:
            if any(marker in lowered for marker in ("response_format", "unsupported parameter", "unknown parameter", "invalid value", "input_fidelity")):
                return "OpenAI image request មិនត្រឹមត្រូវ (400 Bad Request)។ App បានកែ request សុវត្ថិភាពជាងមុនហើយ; សូមសាកម្ដងទៀត។"
            return "OpenAI request មិនត្រឹមត្រូវ (400 Bad Request)។ សូមសាកម្ដងទៀត ឬប្តូរ prompt/image ដែលងាយជាងមុន។"
        if any(marker in lowered for marker in ("responsemodalities", "imageconfig", "invalid argument", "unsupported", "response schema")):
            return "Gemini request មិនត្រឹមត្រូវ (400 Bad Request)។ សូមសាកម្ដងទៀត ឬបន្ថយ prompt/image config ម្តង។"
        return "Gemini request មិនត្រឹមត្រូវ (400 Bad Request)។ សូមសាកម្ដងទៀត។"
    if text:
        return text
    return f"{provider_label(provider)} request failed."


def probe_video(path: Path) -> VideoInfo:
    if FFPROBE:
        proc = run(
            [
                FFPROBE,
                "-v",
                "error",
                "-show_entries",
                "format=duration:stream=codec_type",
                "-of",
                "json",
                str(path),
            ]
        )
        payload = json.loads(proc.stdout)
        duration = float(payload["format"]["duration"])
        has_audio = any(stream.get("codec_type") == "audio" for stream in payload.get("streams", []))
        return VideoInfo(duration=duration, has_audio=has_audio)

    proc = run([FFMPEG, "-hide_banner", "-i", str(path)], expect_success=False)
    stderr = proc.stderr
    duration_match = re.search(r"Duration:\s+(\d+):(\d+):(\d+(?:\.\d+)?)", stderr)
    if not duration_match:
        raise RuntimeError(f"Could not read duration for {path}")
    hours, minutes, seconds = duration_match.groups()
    duration = int(hours) * 3600 + int(minutes) * 60 + float(seconds)
    has_audio = "Audio:" in stderr
    return VideoInfo(duration=duration, has_audio=has_audio)


def next_package_number(root: Path) -> int:
    highest = 0
    for child in root.iterdir():
        if not child.is_dir():
            continue
        match = re.match(r"^(\d+)_Reels_Package$", child.name)
        if match:
            highest = max(highest, int(match.group(1)))
    return highest + 1


def source_videos(root: Path) -> list[Path]:
    sources = []
    for child in sorted(root.iterdir()):
        if child.is_file() and child.suffix.lower() in VIDEO_EXTENSIONS and not child.name.startswith("."):
            sources.append(child)
    return sources


def stem_words(path: Path) -> list[str]:
    tokens = re.findall(r"[A-Za-z]+", path.stem)
    cleaned = []
    for token in tokens:
        word = token.lower()
        if len(word) < 2 or word in NOISE_WORDS:
            continue
        if re.fullmatch(r"[a-f0-9]+", word):
            continue
        cleaned.append(word)
    return cleaned


def hashtagify(words: list[str]) -> list[str]:
    tags = []
    for word in words:
        if len(word) < 3:
            continue
        tags.append("#" + word[:1].upper() + word[1:])
        if len(tags) == 5:
            break
    defaults = ["#ViralClip", "#TrendingReel", "#MustWatch", "#ReelsDaily", "#ForYou"]
    for tag in defaults:
        if len(tags) == 5:
            break
        if tag not in tags:
            tags.append(tag)
    return tags[:5]


def default_title(path: Path) -> str:
    return TITLE_PLACEHOLDER


def openai_client() -> OpenAI | None:
    api_key = resolve_api_key("OPENAI_API_KEY")
    if not api_key or OpenAI is None:
        return None
    return OpenAI(api_key=api_key, timeout=OPENAI_REQUEST_TIMEOUT_SECONDS, max_retries=1)


def gemini_api_key() -> str | None:
    return resolve_api_key("GEMINI_API_KEY", "GOOGLE_API_KEY")


def save_binary_output(kind: str, prompt: str, payload: bytes, mime_type: str, *, suffix: str | None = None) -> Path:
    extension = suffix or choose_extension_for_mime_type(mime_type)
    output_path = build_ai_chat_media_path(kind, prompt, extension)
    output_path.write_bytes(payload)
    return output_path


def extract_response_text(response: object) -> str:
    output_text = getattr(response, "output_text", None)
    if output_text:
        return str(output_text).strip()

    outputs = getattr(response, "output", []) or []
    for item in outputs:
        if getattr(item, "type", None) != "message":
            continue
        for content in getattr(item, "content", []) or []:
            if getattr(content, "type", None) == "output_text":
                text = getattr(content, "text", "")
                if text:
                    return str(text).strip()
    return ""


def clean_generated_title(text: str) -> str:
    cleaned = " ".join(text.replace("\n", " ").split()).strip()
    cleaned = cleaned.strip('"').strip("'")
    cleaned = repair_mojibake_text(cleaned)
    cleaned = unicodedata.normalize("NFC", cleaned)
    cleaned = " ".join(cleaned.split()).strip()
    return cleaned or TITLE_PLACEHOLDER


def repair_mojibake_text(text: str) -> str:
    if not text:
        return text
    normalized = unicodedata.normalize("NFC", text)
    if not any(marker in normalized for marker in ("ðŸ", "Ã", "â", "Â")):
        return normalized
    try:
        repaired = normalized.encode("latin-1").decode("utf-8")
    except UnicodeError:
        return normalized
    return unicodedata.normalize("NFC", repaired)


def normalize_transcript_text(text: str) -> str:
    cleaned = " ".join(str(text or "").split()).strip()
    if not cleaned:
        return ""
    lowered = cleaned.lower().strip(" .!?:;[]")
    no_speech_markers = (
        "no clear spoken words detected",
        "no clear spoken words",
        "no spoken words detected",
        "no clear speech detected",
        "no speech detected",
        "no spoken audio detected",
        "no clear audio detected",
        "there are no clear spoken words detected in the video",
        "the video contains no clear spoken words",
    )
    if any(marker in lowered for marker in no_speech_markers):
        return ""
    return cleaned


def transcript_prompt_text(text: str) -> str:
    normalized = normalize_transcript_text(text)
    return normalized or NO_CLEAR_SPOKEN_WORDS_PLACEHOLDER


def extract_gemini_text(payload: dict[str, object]) -> str:
    candidates = payload.get("candidates")
    if not isinstance(candidates, list):
        return ""
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        content = candidate.get("content")
        if not isinstance(content, dict):
            continue
        parts = content.get("parts")
        if not isinstance(parts, list):
            continue
        for part in parts:
            if isinstance(part, dict):
                text = part.get("text")
                if isinstance(text, str) and text.strip():
                    return text.strip()
    return ""


def gemini_generate_content(api_key: str, payload: dict[str, object], model_name: str | None = None) -> dict[str, object]:
    model_name = model_name or resolve_gemini_model()
    request = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model_name}:generateContent",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
        },
        method="POST",
    )
    last_error: BaseException | None = None
    for attempt in range(len(TEMPORARY_API_RETRY_DELAYS_SECONDS) + 1):
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                return json.loads(response.read().decode("utf-8"))
        except Exception as exc:
            last_error = exc
            status_code = api_error_status_code(exc)
            if status_code not in TEMPORARY_API_STATUS_CODES or attempt >= len(TEMPORARY_API_RETRY_DELAYS_SECONDS):
                raise
            time.sleep(TEMPORARY_API_RETRY_DELAYS_SECONDS[attempt])
    raise last_error or RuntimeError("Gemini request failed.")


def guess_media_mime_type(path: Path) -> str:
    guessed, _ = mimetypes.guess_type(path.name)
    if guessed:
        return guessed
    return "video/mp4"


def gemini_upload_file(api_key: str, path: Path) -> dict[str, object]:
    mime_type = guess_media_mime_type(path)
    metadata = {"file": {"display_name": path.name}}
    start_request = urllib.request.Request(
        f"{GEMINI_FILES_BASE_URL}/upload/v1beta/files?key={api_key}",
        data=json.dumps(metadata).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "X-Goog-Upload-Protocol": "resumable",
            "X-Goog-Upload-Command": "start",
            "X-Goog-Upload-Header-Content-Length": str(path.stat().st_size),
            "X-Goog-Upload-Header-Content-Type": mime_type,
        },
        method="POST",
    )
    with urllib.request.urlopen(start_request, timeout=180) as response:
        upload_url = response.headers.get("x-goog-upload-url")
    if not upload_url:
        raise RuntimeError("Gemini Files API did not return an upload URL.")

    upload_request = urllib.request.Request(
        upload_url,
        data=path.read_bytes(),
        headers={
            "Content-Length": str(path.stat().st_size),
            "Content-Type": mime_type,
            "X-Goog-Upload-Offset": "0",
            "X-Goog-Upload-Command": "upload, finalize",
        },
        method="POST",
    )
    with urllib.request.urlopen(upload_request, timeout=max(180, min(900, int(path.stat().st_size / 50000) + 180))) as response:
        payload = json.loads(response.read().decode("utf-8"))
    file_info = payload.get("file")
    if not isinstance(file_info, dict):
        raise RuntimeError("Gemini Files API upload response did not include file metadata.")
    return file_info


def gemini_get_file(api_key: str, name: str) -> dict[str, object]:
    request = urllib.request.Request(
        f"{GEMINI_FILES_BASE_URL}/v1beta/{name}?key={api_key}",
        headers={"Content-Type": "application/json"},
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def gemini_delete_file(api_key: str, name: str) -> None:
    try:
        request = urllib.request.Request(
            f"{GEMINI_FILES_BASE_URL}/v1beta/{name}?key={api_key}",
            method="DELETE",
        )
        with urllib.request.urlopen(request, timeout=60):
            return
    except Exception:
        return


def gemini_wait_for_file_active(api_key: str, file_info: dict[str, object]) -> dict[str, object]:
    name = str(file_info.get("name") or "")
    if not name:
        raise RuntimeError("Gemini file metadata did not include a file name.")
    deadline = time.time() + GEMINI_FILE_TIMEOUT_SECONDS
    latest = file_info
    while True:
        state = str(latest.get("state") or "").upper()
        if state == "ACTIVE":
            return latest
        if state == "FAILED":
            error_info = latest.get("error")
            raise RuntimeError(f"Gemini file processing failed: {error_info}")
        if time.time() >= deadline:
            raise RuntimeError("Timed out waiting for Gemini file processing.")
        time.sleep(GEMINI_FILE_POLL_SECONDS)
        latest = gemini_get_file(api_key, name)


def gemini_create_interaction(api_key: str, payload: dict[str, object]) -> dict[str, object]:
    request = urllib.request.Request(
        f"{GEMINI_FILES_BASE_URL}/v1beta/interactions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.loads(response.read().decode("utf-8"))


def extract_gemini_interaction_text(payload: dict[str, object]) -> str:
    outputs = payload.get("outputs")
    if not isinstance(outputs, list):
        return ""
    for output in outputs:
        if not isinstance(output, dict):
            continue
        text = output.get("text")
        if isinstance(text, str) and text.strip():
            return text.strip()
    return ""


def gemini_transcribe_uploaded_video(
    api_key: str,
    file_info: dict[str, object],
    mime_type: str | None = None,
    model_name: str | None = None,
) -> str:
    uri = str(file_info.get("uri") or "").strip()
    resolved_mime_type = str(file_info.get("mimeType") or mime_type or "video/mp4").strip() or "video/mp4"
    if not uri:
        raise RuntimeError("Gemini file metadata did not include a file URI.")

    response_payload = gemini_create_interaction(
        api_key,
        {
            "model": model_name or resolve_gemini_model(),
            "input": [
                {
                    "type": "text",
                    "text": (
                        "Transcribe the spoken words and meaningful speech-like sounds from this video. "
                        "Ignore music-only sections and generic background noise. "
                        f"If there are no clear spoken words, return exactly this text: {NO_CLEAR_SPOKEN_WORDS_PLACEHOLDER}. "
                        "Return only the transcript text."
                    ),
                },
                {
                    "type": "video",
                    "uri": uri,
                    "mime_type": resolved_mime_type,
                },
            ],
            "generation_config": {
                "temperature": 0.0,
                "thinking_level": "low",
                "max_output_tokens": 900,
            },
        },
    )
    return normalize_transcript_text(extract_gemini_interaction_text(response_payload))


def extract_gemini_inline_images(payload: dict[str, object]) -> list[tuple[str, bytes]]:
    images: list[tuple[str, bytes]] = []
    candidates = payload.get("candidates")
    if not isinstance(candidates, list):
        return images
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        content = candidate.get("content")
        if not isinstance(content, dict):
            continue
        parts = content.get("parts")
        if not isinstance(parts, list):
            continue
        for part in parts:
            if not isinstance(part, dict):
                continue
            inline_data = part.get("inlineData")
            if not isinstance(inline_data, dict):
                inline_data = part.get("inline_data")
            if not isinstance(inline_data, dict):
                continue
            data = inline_data.get("data")
            mime_type = str(inline_data.get("mimeType") or inline_data.get("mime_type") or "image/png")
            if not isinstance(data, str) or not data.strip():
                continue
            try:
                decoded = base64.b64decode(data)
            except Exception:
                continue
            images.append((mime_type, decoded))
    return images


def generate_openai_image(prompt: str) -> list[dict[str, str]]:
    client = openai_client()
    if client is None:
        raise RuntimeError("OpenAI API key is not set.")

    last_error: BaseException | None = None
    models = [OPENAI_IMAGE_MODEL, OPENAI_IMAGE_MODEL_FALLBACK]
    for model_name in models:
        try:
            response = client.images.generate(
                model=model_name,
                prompt=prompt,
                output_format="png",
                size=preferred_openai_image_size(prompt),
                quality="medium",
                n=1,
            )
            items = getattr(response, "data", None) or []
            if not items:
                raise RuntimeError("OpenAI image generation returned no image data.")
            first = items[0]
            image_data = getattr(first, "b64_json", None)
            if not image_data:
                raise RuntimeError("OpenAI image generation response did not include image bytes.")
            payload = base64.b64decode(str(image_data))
            output_path = save_binary_output("image", prompt, payload, "image/png")
            return [
                {
                    "kind": "image",
                    "path": str(output_path),
                    "mime_type": "image/png",
                    "display_name": output_path.name,
                }
            ]
        except Exception as exc:
            issue_message = api_issue_message(AI_PROVIDER_OPENAI, exc)
            if issue_message:
                raise RuntimeError(issue_message) from exc
            last_error = exc
    raise RuntimeError(describe_provider_error(AI_PROVIDER_OPENAI, last_error or RuntimeError("OpenAI image generation failed.")))


def generate_openai_image_edit(prompt: str, image_paths: list[Path]) -> list[dict[str, str]]:
    client = openai_client()
    if client is None:
        raise RuntimeError("OpenAI API key is not set.")
    if len(image_paths) < 2:
        raise RuntimeError("Attach at least 2 images for face swap. Put the source face first and the target image second.")

    last_error: BaseException | None = None
    models = [OPENAI_IMAGE_MODEL, OPENAI_IMAGE_MODEL_FALLBACK]
    for model_name in models:
        file_handles = []
        try:
            file_handles = [path.open("rb") for path in image_paths[:5]]
            response = client.images.edit(
                model=model_name,
                image=file_handles,
                prompt=prompt,
                input_fidelity="high",
                output_format="png",
                quality="high",
                size=preferred_openai_image_size(prompt),
                n=1,
            )
            items = getattr(response, "data", None) or []
            if not items:
                raise RuntimeError("OpenAI image editing returned no image data.")
            first = items[0]
            image_data = getattr(first, "b64_json", None)
            if not image_data:
                raise RuntimeError("OpenAI image editing response did not include image bytes.")
            payload = base64.b64decode(str(image_data))
            output_path = save_binary_output("image", prompt, payload, "image/png")
            return [
                {
                    "kind": "image",
                    "path": str(output_path),
                    "mime_type": "image/png",
                    "display_name": output_path.name,
                }
            ]
        except Exception as exc:
            issue_message = api_issue_message(AI_PROVIDER_OPENAI, exc)
            if issue_message:
                raise RuntimeError(issue_message) from exc
            last_error = exc
        finally:
            for handle in file_handles:
                try:
                    handle.close()
                except Exception:
                    pass
    raise RuntimeError(describe_provider_error(AI_PROVIDER_OPENAI, last_error or RuntimeError("OpenAI image editing failed.")))


def generate_openai_single_image_edit(prompt: str, image_path: Path) -> list[dict[str, str]]:
    client = openai_client()
    if client is None:
        raise RuntimeError("OpenAI API key is not set.")

    last_error: BaseException | None = None
    models = [OPENAI_IMAGE_MODEL, OPENAI_IMAGE_MODEL_FALLBACK]
    for model_name in models:
        handle = None
        try:
            handle = image_path.open("rb")
            response = client.images.edit(
                model=model_name,
                image=handle,
                prompt=prompt,
                input_fidelity="high",
                output_format="png",
                quality="high",
                size=preferred_openai_image_size(prompt),
                n=1,
            )
            items = getattr(response, "data", None) or []
            if not items:
                raise RuntimeError("OpenAI image editing returned no image data.")
            first = items[0]
            image_data = getattr(first, "b64_json", None)
            if not image_data:
                raise RuntimeError("OpenAI image editing response did not include image bytes.")
            payload = base64.b64decode(str(image_data))
            output_path = save_binary_output("image", prompt, payload, "image/png")
            return [
                {
                    "kind": "image",
                    "path": str(output_path),
                    "mime_type": "image/png",
                    "display_name": output_path.name,
                }
            ]
        except Exception as exc:
            issue_message = api_issue_message(AI_PROVIDER_OPENAI, exc)
            if issue_message:
                raise RuntimeError(issue_message) from exc
            last_error = exc
        finally:
            if handle is not None:
                try:
                    handle.close()
                except Exception:
                    pass
    raise RuntimeError(describe_provider_error(AI_PROVIDER_OPENAI, last_error or RuntimeError("OpenAI image editing failed.")))


def generate_openai_video(prompt: str) -> list[dict[str, str]]:
    client = openai_client()
    if client is None:
        raise RuntimeError("OpenAI API key is not set.")

    try:
        video = client.videos.create_and_poll(
            model=OPENAI_VIDEO_MODEL,
            prompt=prompt,
            seconds="8",
            size=preferred_openai_video_size(prompt),
            poll_interval_ms=5000,
            timeout=max(OPENAI_REQUEST_TIMEOUT_SECONDS, 1200),
        )
        status = str(getattr(video, "status", "") or "").lower()
        if status != "completed":
            error_info = getattr(video, "error", None)
            raise RuntimeError(f"OpenAI video generation did not complete. Status: {status or 'unknown'}. {error_info or ''}".strip())
        video_id = str(getattr(video, "id", "") or "").strip()
        if not video_id:
            raise RuntimeError("OpenAI video generation did not return a video ID.")
        output_path = build_ai_chat_media_path("video", prompt, ".mp4")
        client.videos.download_content(video_id).write_to_file(output_path)
        return [
            {
                "kind": "video",
                "path": str(output_path),
                "mime_type": "video/mp4",
                "display_name": output_path.name,
            }
        ]
    except Exception as exc:
        issue_message = api_issue_message(AI_PROVIDER_OPENAI, exc)
        if issue_message:
            raise RuntimeError(issue_message) from exc
        raise RuntimeError(describe_provider_error(AI_PROVIDER_OPENAI, exc)) from exc


def generate_openai_video_face_edit(prompt: str, source_image_paths: list[Path], target_video_path: Path) -> list[dict[str, str]]:
    try:
        return generate_face_edit_video(
            prompt,
            source_image_paths,
            target_video_path,
            generate_openai_image_edit,
            "OpenAI",
        )
    except Exception as exc:
        issue_message = api_issue_message(AI_PROVIDER_OPENAI, exc)
        if issue_message:
            raise RuntimeError(issue_message) from exc
        raise RuntimeError(describe_provider_error(AI_PROVIDER_OPENAI, exc)) from exc


def generate_gemini_image(prompt: str, preferred_model: str | None = None) -> list[dict[str, str]]:
    api_key = gemini_api_key()
    if not api_key:
        raise RuntimeError("Gemini API key is not set.")

    image_models = [preferred_model or resolve_gemini_image_model()]
    if GEMINI_IMAGE_MODEL_FLASH not in image_models:
        image_models.append(GEMINI_IMAGE_MODEL_FLASH)

    last_error: BaseException | None = None
    for model_name in image_models:
        try:
            payload = {
                "contents": [
                    {
                        "parts": [
                            {
                                "text": prompt,
                            }
                        ]
                    }
                ],
                "generationConfig": {
                    "imageConfig": {
                        "aspectRatio": preferred_gemini_image_aspect_ratio(prompt),
                        "imageSize": "1K",
                    }
                },
            }
            response = gemini_generate_content(api_key, payload, model_name=model_name)
            images = extract_gemini_inline_images(response)
            if not images:
                raise RuntimeError("Gemini image generation returned no image data.")
            mime_type, payload_bytes = images[0]
            output_path = save_binary_output("image", prompt, payload_bytes, mime_type, suffix=choose_extension_for_mime_type(mime_type, ".png"))
            return [
                {
                    "kind": "image",
                    "path": str(output_path),
                    "mime_type": mime_type,
                    "display_name": output_path.name,
                }
            ]
        except Exception as exc:
            issue_message = api_issue_message(AI_PROVIDER_GEMINI, exc)
            if issue_message:
                raise RuntimeError(issue_message) from exc
            last_error = exc
    raise RuntimeError(describe_provider_error(AI_PROVIDER_GEMINI, last_error or RuntimeError("Gemini image generation failed.")))


def generate_gemini_image_edit(prompt: str, image_paths: list[Path], preferred_model: str | None = None) -> list[dict[str, str]]:
    api_key = gemini_api_key()
    if not api_key:
        raise RuntimeError("Gemini API key is not set.")
    if len(image_paths) < 2:
        raise RuntimeError("Attach at least 2 images for face swap. Put the source face first and the target image second.")

    image_models = [preferred_model or resolve_gemini_image_model()]
    if GEMINI_IMAGE_MODEL_FLASH not in image_models:
        image_models.append(GEMINI_IMAGE_MODEL_FLASH)

    image_parts: list[dict[str, object]] = []
    for path in image_paths[:5]:
        image_parts.append(
            {
                "inline_data": {
                    "mime_type": guess_media_mime_type(path),
                    "data": base64.b64encode(path.read_bytes()).decode("ascii"),
                }
            }
        )

    last_error: BaseException | None = None
    for model_name in image_models:
        try:
            payload = {
                "contents": [
                    {
                        "parts": [{"text": prompt}, *image_parts]
                    }
                ],
                "generationConfig": {
                    "responseModalities": ["TEXT", "IMAGE"],
                    "imageConfig": {
                        "aspectRatio": preferred_gemini_image_aspect_ratio(prompt),
                        "imageSize": "1K",
                    }
                },
            }
            response = gemini_generate_content(api_key, payload, model_name=model_name)
            images = extract_gemini_inline_images(response)
            if not images:
                raise RuntimeError("Gemini image editing returned no image data.")
            mime_type, payload_bytes = images[0]
            output_path = save_binary_output("image", prompt, payload_bytes, mime_type, suffix=choose_extension_for_mime_type(mime_type, ".png"))
            return [
                {
                    "kind": "image",
                    "path": str(output_path),
                    "mime_type": mime_type,
                    "display_name": output_path.name,
                }
            ]
        except Exception as exc:
            issue_message = api_issue_message(AI_PROVIDER_GEMINI, exc)
            if issue_message:
                raise RuntimeError(issue_message) from exc
            last_error = exc
    raise RuntimeError(describe_provider_error(AI_PROVIDER_GEMINI, last_error or RuntimeError("Gemini image editing failed.")))


def generate_gemini_single_image_edit(prompt: str, image_path: Path, preferred_model: str | None = None) -> list[dict[str, str]]:
    api_key = gemini_api_key()
    if not api_key:
        raise RuntimeError("Gemini API key is not set.")

    image_models = [preferred_model or resolve_gemini_image_model()]
    if GEMINI_IMAGE_MODEL_FLASH not in image_models:
        image_models.append(GEMINI_IMAGE_MODEL_FLASH)

    image_part = {
        "inline_data": {
            "mime_type": guess_media_mime_type(image_path),
            "data": base64.b64encode(image_path.read_bytes()).decode("ascii"),
        }
    }

    last_error: BaseException | None = None
    for model_name in image_models:
        try:
            payload = {
                "contents": [
                    {
                        "parts": [{"text": prompt}, image_part]
                    }
                ],
                "generationConfig": {
                    "responseModalities": ["TEXT", "IMAGE"],
                    "imageConfig": {
                        "aspectRatio": preferred_gemini_image_aspect_ratio(prompt),
                        "imageSize": "1K",
                    }
                },
            }
            response = gemini_generate_content(api_key, payload, model_name=model_name)
            images = extract_gemini_inline_images(response)
            if not images:
                raise RuntimeError("Gemini image editing returned no image data.")
            mime_type, payload_bytes = images[0]
            output_path = save_binary_output("image", prompt, payload_bytes, mime_type, suffix=choose_extension_for_mime_type(mime_type, ".png"))
            return [
                {
                    "kind": "image",
                    "path": str(output_path),
                    "mime_type": mime_type,
                    "display_name": output_path.name,
                }
            ]
        except Exception as exc:
            issue_message = api_issue_message(AI_PROVIDER_GEMINI, exc)
            if issue_message:
                raise RuntimeError(issue_message) from exc
            last_error = exc
    raise RuntimeError(describe_provider_error(AI_PROVIDER_GEMINI, last_error or RuntimeError("Gemini image editing failed.")))


def generate_gemini_video_face_edit(prompt: str, source_image_paths: list[Path], target_video_path: Path, preferred_model: str | None = None) -> list[dict[str, str]]:
    def edit_frame(frame_prompt: str, image_paths: list[Path]) -> list[dict[str, str]]:
        return generate_gemini_image_edit(frame_prompt, image_paths, preferred_model=preferred_model)

    try:
        return generate_face_edit_video(
            prompt,
            source_image_paths,
            target_video_path,
            edit_frame,
            "Gemini",
        )
    except Exception as exc:
        issue_message = api_issue_message(AI_PROVIDER_GEMINI, exc)
        if issue_message:
            raise RuntimeError(issue_message) from exc
        raise RuntimeError(describe_provider_error(AI_PROVIDER_GEMINI, exc)) from exc


def gemini_generate_video_operation(api_key: str, prompt: str) -> dict[str, object]:
    payload = {
        "instances": [
            {
                "prompt": prompt,
            }
        ],
        "parameters": {
            "aspectRatio": preferred_gemini_video_aspect_ratio(prompt),
            "numberOfVideos": 1,
            "resolution": "720p",
        },
    }
    request = urllib.request.Request(
        f"{GEMINI_FILES_BASE_URL}/v1beta/models/{GEMINI_VIDEO_MODEL}:predictLongRunning",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.loads(response.read().decode("utf-8"))


def gemini_poll_video_operation(api_key: str, operation_name: str) -> dict[str, object]:
    request = urllib.request.Request(
        f"{GEMINI_FILES_BASE_URL}/v1beta/{operation_name}",
        headers={
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
        },
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def extract_gemini_video_uri(operation_payload: dict[str, object]) -> str:
    response = operation_payload.get("response")
    if not isinstance(response, dict):
        return ""
    generate_video_response = response.get("generateVideoResponse")
    if isinstance(generate_video_response, dict):
        generated_samples = generate_video_response.get("generatedSamples")
        if isinstance(generated_samples, list) and generated_samples:
            first = generated_samples[0]
            if isinstance(first, dict):
                video = first.get("video")
                if isinstance(video, dict):
                    uri = video.get("uri")
                    if isinstance(uri, str) and uri.strip():
                        return uri.strip()
    generated_videos = response.get("generatedVideos")
    if isinstance(generated_videos, list) and generated_videos:
        first = generated_videos[0]
        if isinstance(first, dict):
            video = first.get("video")
            if isinstance(video, dict):
                uri = video.get("uri")
                if isinstance(uri, str) and uri.strip():
                    return uri.strip()
    return ""


def download_gemini_video(api_key: str, uri: str, output_path: Path) -> None:
    request = urllib.request.Request(
        uri,
        headers={"x-goog-api-key": api_key},
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=max(180, GEMINI_VIDEO_TIMEOUT_SECONDS)) as response:
        output_path.write_bytes(response.read())


def generate_gemini_video(prompt: str) -> list[dict[str, str]]:
    api_key = gemini_api_key()
    if not api_key:
        raise RuntimeError("Gemini API key is not set.")

    try:
        operation = gemini_generate_video_operation(api_key, prompt)
        operation_name = str(operation.get("name") or "").strip()
        if not operation_name:
            raise RuntimeError("Gemini video generation did not return an operation name.")
        deadline = time.time() + GEMINI_VIDEO_TIMEOUT_SECONDS
        latest = operation
        while True:
            if bool(latest.get("done")):
                break
            if time.time() >= deadline:
                raise RuntimeError("Timed out waiting for Gemini video generation.")
            time.sleep(GEMINI_VIDEO_POLL_SECONDS)
            latest = gemini_poll_video_operation(api_key, operation_name)

        if isinstance(latest.get("error"), dict):
            raise RuntimeError(json.dumps(latest["error"], ensure_ascii=False))

        video_uri = extract_gemini_video_uri(latest)
        if not video_uri:
            raise RuntimeError("Gemini video generation completed but did not return a video download URI.")

        output_path = build_ai_chat_media_path("video", prompt, ".mp4")
        download_gemini_video(api_key, video_uri, output_path)
        return [
            {
                "kind": "video",
                "path": str(output_path),
                "mime_type": "video/mp4",
                "display_name": output_path.name,
            }
        ]
    except Exception as exc:
        issue_message = api_issue_message(AI_PROVIDER_GEMINI, exc)
        if issue_message:
            raise RuntimeError(issue_message) from exc
        raise RuntimeError(describe_provider_error(AI_PROVIDER_GEMINI, exc)) from exc


def analysis_timestamps(duration: float, count: int) -> list[float]:
    if count <= 1 or duration <= 0.20:
        return [max(duration / 2.0, 0.0)]

    margin = min(0.40, duration * 0.08)
    start = margin
    end = max(start, duration - margin)
    if end <= start:
        return [max(duration / 2.0, 0.0)]

    step = (end - start) / (count - 1)
    return [start + step * idx for idx in range(count)]


def sample_analysis_frames(video_path: Path) -> tuple[Path, list[AnalysisFrame]]:
    info = probe_video(video_path)
    temp_dir = Path(tempfile.mkdtemp(prefix="reels_title_frames_"))
    frames: list[AnalysisFrame] = []
    for index, timestamp in enumerate(analysis_timestamps(info.duration, ANALYSIS_FRAME_COUNT), start=1):
        output_path = temp_dir / f"frame_{index:02d}.jpg"
        run(
            [
                FFMPEG,
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-ss",
                f"{timestamp:.3f}",
                "-i",
                str(video_path),
                "-frames:v",
                "1",
                "-vf",
                f"scale={ANALYSIS_FRAME_WIDTH}:-2:flags=lanczos",
                str(output_path),
            ]
        )
        frames.append(AnalysisFrame(index=index, timestamp=timestamp, path=output_path))
    return temp_dir, frames


def image_data_url(path: Path) -> str:
    payload = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:image/jpeg;base64,{payload}"


def face_edit_video_sampling_fps(duration: float) -> float:
    if duration <= 0.20:
        return 2.0
    estimated = FACE_EDIT_VIDEO_MAX_FRAMES / max(duration, 0.20)
    return max(FACE_EDIT_VIDEO_MIN_FPS, min(FACE_EDIT_VIDEO_MAX_FPS, estimated))


def extract_face_edit_video_frames(video_path: Path) -> tuple[Path, list[Path], float]:
    info = probe_video(video_path)
    fps = face_edit_video_sampling_fps(info.duration)
    temp_dir = Path(tempfile.mkdtemp(prefix="soranin_face_video_frames_"))
    pattern = temp_dir / "frame_%05d.png"
    run(
        [
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(video_path),
            "-vf",
            f"fps={fps:.4f},scale='min({FACE_EDIT_VIDEO_FRAME_MAX_WIDTH},iw)':-2:flags=lanczos",
            str(pattern),
        ]
    )
    frames = sorted(temp_dir.glob("frame_*.png"))
    if not frames:
        raise RuntimeError("Could not extract frames from the target video for face swap.")
    return temp_dir, frames, fps


def normalize_face_edit_frame_image(source: Path, output: Path) -> None:
    run(
        [
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-frames:v",
            "1",
            str(output),
        ]
    )


def rebuild_face_edit_video(source_video: Path, frames_dir: Path, sampling_fps: float, output_path: Path) -> str:
    has_audio = probe_video(source_video).has_audio
    base_cmd = [
        FFMPEG,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-framerate",
        f"{sampling_fps:.4f}",
        "-i",
        str(frames_dir / "frame_%05d.png"),
        "-i",
        str(source_video),
        "-map",
        "0:v:0",
        "-map",
        "1:a?",
        "-r",
        str(FACE_EDIT_VIDEO_OUTPUT_FPS),
        "-pix_fmt",
        "yuv420p",
    ]

    hardware_cmd = base_cmd + [
        "-c:v",
        "h264_videotoolbox",
        "-allow_sw",
        "1",
        "-profile:v",
        "high",
        "-level",
        "4.1",
        "-b:v",
        "8M",
        "-maxrate",
        "10M",
        "-bufsize",
        "16M",
        "-prio_speed",
        "1",
        "-realtime",
        "1",
    ]

    software_cmd = base_cmd + [
        "-c:v",
        "libx264",
        "-preset",
        "superfast",
        "-crf",
        "21",
        "-profile:v",
        "high",
        "-level",
        "4.1",
    ]

    if has_audio:
        audio_args = [
            "-c:a",
            "aac",
            "-b:a",
            "160k",
            "-ar",
            "48000",
        ]
    else:
        audio_args = ["-an"]

    common_tail = audio_args + ["-shortest", "-movflags", "+faststart", str(output_path)]
    try:
        run(hardware_cmd + common_tail)
        return "h264_videotoolbox"
    except RuntimeError:
        run(software_cmd + common_tail)
        return "libx264"


def generate_face_edit_video(
    prompt: str,
    source_image_paths: list[Path],
    target_video_path: Path,
    frame_edit_func,
    provider_label_text: str,
) -> list[dict[str, str]]:
    if not FFMPEG:
        raise RuntimeError("ffmpeg not found, so video face swap cannot run.")
    if not source_image_paths:
        raise RuntimeError("Attach at least 1 source face image for video face swap.")

    source_references = source_image_paths[:4]
    extracted_dir: Path | None = None
    edited_dir: Path | None = None
    generated_outputs: list[Path] = []
    try:
        extracted_dir, frame_paths, sampling_fps = extract_face_edit_video_frames(target_video_path)
        edited_dir = Path(tempfile.mkdtemp(prefix="soranin_face_video_edited_"))
        total = len(frame_paths)
        for index, frame_path in enumerate(frame_paths, start=1):
            status_print(f"[{provider_label_text}] Face swap frame {index}/{total}")
            media_items = frame_edit_func(prompt, [*source_references, frame_path])
            if not media_items:
                raise RuntimeError("Face swap frame editing returned no media.")
            generated_path = Path(str(media_items[0].get("path") or "")).expanduser()
            if not generated_path.exists():
                raise RuntimeError("Face swap frame editing did not create an output image.")
            generated_outputs.append(generated_path)
            normalized_frame = edited_dir / f"frame_{index:05d}.png"
            normalize_face_edit_frame_image(generated_path, normalized_frame)

        output_path = build_ai_chat_media_path("video", prompt, ".mp4")
        encoder = rebuild_face_edit_video(target_video_path, edited_dir, sampling_fps, output_path)
        status_print(f"[{provider_label_text}] Face-swap video built with {encoder}")
        return [
            {
                "kind": "video",
                "path": str(output_path),
                "mime_type": "video/mp4",
                "display_name": output_path.name,
            }
        ]
    finally:
        for generated_path in generated_outputs:
            try:
                generated_path.unlink(missing_ok=True)
            except Exception:
                pass
        if extracted_dir is not None:
            shutil.rmtree(extracted_dir, ignore_errors=True)
        if edited_dir is not None:
            shutil.rmtree(edited_dir, ignore_errors=True)


def transcribe_video_audio(client: OpenAI, video_path: Path) -> str:
    with video_path.open("rb") as video_file:
        transcription = client.audio.transcriptions.create(
            file=video_file,
            model=OPENAI_TRANSCRIBE_MODEL,
            response_format="json",
            prompt=(
                "Transcribe the spoken words and meaningful on-screen speech sounds. "
                "Ignore music-only sections and generic background noise."
            ),
        )
    return str(getattr(transcription, "text", "") or "").strip()


def analyze_video_assets_with_openai(video_path: Path, has_audio: bool) -> VideoAssetAnalysis | None:
    client = openai_client()
    if client is None:
        return None

    transcript = ""
    if has_audio:
        try:
            transcript = transcribe_video_audio(client, video_path)
        except Exception as exc:
            issue_message = api_issue_message(AI_PROVIDER_OPENAI, exc)
            if issue_message:
                raise RuntimeError(issue_message) from exc
            transcript = ""

    temp_dir: Path | None = None
    frames: list[AnalysisFrame] = []
    try:
        temp_dir, frames = sample_analysis_frames(video_path)
        schema = {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "thumbnail_frame_index": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": len(frames),
                },
                "video_topic": {"type": "string"},
                "thumbnail_reason": {"type": "string"},
            },
            "required": ["title", "thumbnail_frame_index", "video_topic", "thumbnail_reason"],
            "additionalProperties": False,
        }
        content: list[dict[str, object]] = [
            {
                "type": "input_text",
                "text": (
                    "Analyze this full reel and create the final post assets. "
                    "Choose the single best thumbnail moment and write the final title. "
                    "The thumbnail must match the real action, feel clickable, and fit what viewers like to watch: "
                    "clear payoff, visible action, satisfying detail, strong curiosity, or the most dramatic close-up. "
                    "Avoid weak setup frames, boring frames, hidden action, and blurry motion-heavy frames. "
                    "The title must match the same story as the thumbnail."
                ),
            },
            {
                "type": "input_text",
                "text": (
                    "Audio transcript from the full edited reel:\n"
                    f"{transcript_prompt_text(transcript)}"
                ),
            },
            {
                "type": "input_text",
                "text": (
                    f"There are {len(frames)} candidate frames below in chronological order. "
                    "For the title: create exactly one English Facebook Reels title with 1 or 2 emoji and exactly 5 relevant hashtags. "
                    "Do not mention watermark, snapsora, filename, package number, editing, or generic filler words. "
                    "For the thumbnail: return the chosen frame index from the candidate frames."
                ),
            },
        ]
        for frame in frames:
            content.append(
                {
                    "type": "input_text",
                    "text": f"Candidate frame {frame.index} at {frame.timestamp:.2f} seconds.",
                }
            )
            content.append(
                {
                    "type": "input_image",
                    "image_url": image_data_url(frame.path),
                    "detail": "low",
                }
            )
        response = client.responses.create(
            model=resolve_openai_model(),
            instructions=(
                "You select short-video assets for Facebook Reels. "
                "Use the transcript and frames together. "
                "Pick the thumbnail frame that best represents the real topic and has the strongest viewer appeal. "
                "Keep the chosen frame and title aligned to the same moment and same story."
            ),
            input=[
                {
                    "role": "user",
                    "content": content,
                }
            ],
            text={
                "format": {
                    "type": "json_schema",
                    "name": "reel_asset_selection",
                    "strict": True,
                    "schema": schema,
                    "description": "Structured reel title and thumbnail frame selection.",
                }
            },
            max_output_tokens=260,
            temperature=0.7,
            store=False,
        )
        payload = json.loads(extract_response_text(response))
        chosen_index = int(payload["thumbnail_frame_index"])
        if chosen_index < 1 or chosen_index > len(frames):
            chosen_index = max(1, min(len(frames), chosen_index))
        chosen_frame = frames[chosen_index - 1]
        return VideoAssetAnalysis(
            title=clean_generated_title(payload["title"]),
            thumbnail_frame_index=chosen_index,
            thumbnail_timestamp=chosen_frame.timestamp,
            video_topic=str(payload.get("video_topic") or "").strip(),
            thumbnail_reason=str(payload.get("thumbnail_reason") or "").strip(),
        )
    except Exception as exc:
        issue_message = api_issue_message(AI_PROVIDER_OPENAI, exc)
        if issue_message:
            raise RuntimeError(issue_message) from exc
        return None
    finally:
        for frame in frames:
            frame.path.unlink(missing_ok=True)
        if temp_dir is not None:
            shutil.rmtree(temp_dir, ignore_errors=True)


def analyze_video_assets_with_gemini(video_path: Path) -> VideoAssetAnalysis | None:
    api_key = gemini_api_key()
    if not api_key:
        return None

    uploaded_file_name = ""
    try:
        info = probe_video(video_path)
        mime_type = guess_media_mime_type(video_path)
        status_print("[Gemini] Uploading full video to Files API")
        uploaded_file = gemini_upload_file(api_key, video_path)
        uploaded_file_name = str(uploaded_file.get("name") or "")
        status_print("[Gemini] Waiting for uploaded video to become ACTIVE")
        uploaded_file = gemini_wait_for_file_active(api_key, uploaded_file)
        status_print("[Gemini] Generating transcript from uploaded video")
        transcript = ""
        try:
            transcript = gemini_transcribe_uploaded_video(api_key, uploaded_file, mime_type, model_name=resolve_gemini_model())
        except Exception as exc:
            issue_message = api_issue_message(AI_PROVIDER_GEMINI, exc)
            if issue_message:
                raise RuntimeError(issue_message) from exc
            status_print("[Gemini] Transcript unavailable, continuing without transcript")
            transcript = ""
        schema = {
            "type": "object",
            "properties": {
                "title": {
                    "type": "string",
                    "description": "One English Facebook Reels title with 1 or 2 emoji and exactly 5 relevant hashtags.",
                },
                "thumbnail_timestamp_seconds": {
                    "type": "number",
                    "minimum": 0,
                    "maximum": round(max(info.duration - 0.05, 0.0), 3),
                    "description": "The strongest thumbnail moment in seconds from the real video.",
                },
                "video_topic": {
                    "type": "string",
                    "description": "Short description of the actual topic and action in the video.",
                },
                "thumbnail_reason": {
                    "type": "string",
                    "description": "Why this timestamp is the strongest click-worthy thumbnail.",
                },
            },
            "required": [
                "title",
                "thumbnail_timestamp_seconds",
                "video_topic",
                "thumbnail_reason",
            ],
            "additionalProperties": False,
        }
        interaction_payload = {
            "model": resolve_gemini_model(),
            "input": [
                {
                    "type": "text",
                    "text": (
                        "Analyze this full Facebook Reel using both the audio and visual content from the entire video. "
                        "Understand what people are doing, what is being said or implied by audio, and where the real payoff happens. "
                        "Write exactly one English Facebook Reels title with 1 or 2 emoji and exactly 5 relevant hashtags. "
                        "Choose the single best thumbnail timestamp from the real video. "
                        "The thumbnail moment must be the strongest viewer hook and must match the same story as the title. "
                        "Prefer the most satisfying, dramatic, or curiosity-driving close-up moment that clearly shows the action. "
                        "Avoid boring setup moments, blurry moments, watermark talk, filename words, editing words, and generic filler."
                    ),
                },
                {
                    "type": "text",
                    "text": (
                        "Audio transcript from the full edited reel:\n"
                        f"{transcript_prompt_text(transcript)}"
                    ),
                },
                {
                    "type": "video",
                    "uri": str(uploaded_file.get("uri") or ""),
                    "mime_type": str(uploaded_file.get("mimeType") or mime_type),
                },
            ],
            "response_format": schema,
            "generation_config": {
                "temperature": 0.6,
                "thinking_level": "low",
                "max_output_tokens": 260,
            },
        }
        status_print(f"[Gemini] Analyzing full video with {resolve_gemini_model()}")
        response_payload = gemini_create_interaction(api_key, interaction_payload)
        text = extract_gemini_interaction_text(response_payload)
        if not text:
            return None
        parsed = json.loads(text)
        timestamp = float(parsed["thumbnail_timestamp_seconds"])
        timestamp = max(0.0, min(max(info.duration - 0.05, 0.0), timestamp))
        return VideoAssetAnalysis(
            title=clean_generated_title(parsed["title"]),
            thumbnail_frame_index=1,
            thumbnail_timestamp=timestamp,
            video_topic=str(parsed.get("video_topic") or "").strip(),
            thumbnail_reason=str(parsed.get("thumbnail_reason") or "").strip(),
        )
    except Exception as exc:
        issue_message = api_issue_message(AI_PROVIDER_GEMINI, exc)
        if issue_message:
            raise RuntimeError(issue_message) from exc
        return None
    finally:
        if uploaded_file_name:
            gemini_delete_file(api_key, uploaded_file_name)


def analyze_video_assets_for_provider(video_path: Path, has_audio: bool, provider: str) -> VideoAssetAnalysis | None:
    if provider == AI_PROVIDER_GEMINI:
        return analyze_video_assets_with_gemini(video_path)
    return analyze_video_assets_with_openai(video_path, has_audio)


def analyze_video_assets(video_path: Path, has_audio: bool) -> VideoAssetAnalysis | None:
    return analyze_video_assets_for_provider(video_path, has_audio, resolve_ai_provider())


def render_ai_chat_video_thumbnail(video_path: Path, prompt: str, provider: str) -> tuple[list[dict[str, str]], VideoAssetAnalysis | None]:
    info = probe_video(video_path)
    analysis = analyze_video_assets_for_provider(video_path, info.has_audio, provider)
    output_path = build_ai_chat_media_path("image", prompt or f"thumbnail {video_path.stem}", ".jpg")
    render_thumbnail(video_path, output_path, analysis.thumbnail_timestamp if analysis else None)
    return [
        {
            "kind": "image",
            "path": str(output_path),
            "mime_type": "image/jpeg",
            "display_name": output_path.name,
        }
    ], analysis


def designed_video_thumbnail_style(request_text: str) -> str:
    lowered = request_text.lower()
    if any(marker in lowered for marker in ("luxury clean", "clean luxury", "premium clean", "elegant clean", "luxury style")):
        return "luxury_clean"
    return "safe_viral"


def build_designed_video_thumbnail_prompt(request_text: str, analysis: VideoAssetAnalysis | None) -> str:
    title_hint = analysis.title if analysis and analysis.title else ""
    topic_hint = analysis.video_topic if analysis and analysis.video_topic else ""
    reason_hint = analysis.thumbnail_reason if analysis and analysis.thumbnail_reason else ""
    style = designed_video_thumbnail_style(request_text)
    guidance = (
        "Turn this real video frame into a stronger short-form social thumbnail. "
        "Keep it truthful to the original video scene and preserve the main subject, action, identity, lighting direction, and story payoff. "
        "Make it more eye-catching for Facebook Reels, YouTube Shorts, and TikTok by emphasizing the clearest focal subject, stronger contrast, cleaner composition, sharper detail, slightly tighter crop-in, richer color separation, premium polish, and a stronger emotional or curiosity hook. "
        "Do not add any title text, captions, logos, stickers, arrows, circles, or overlays. "
        "Keep it vertical 9:16, high-definition, crisp, and natural-looking. "
        "Avoid misleading clickbait, explicit nudity, graphic gore, hateful symbols, illegal acts, scam-style claims, or anything unsafe for major social video platforms. "
    )
    if style == "luxury_clean":
        guidance += (
            "Use a luxury clean style: refined composition, elegant premium color grading, polished highlights, clean negative space, sophisticated beauty retouching, and upscale magazine-quality finish. "
            "Also strengthen click-through appeal with a clearer focal subject, stronger subject-background separation, and sharper first-glance readability while keeping the result stylish, expensive-looking, and uncluttered. "
        )
    else:
        guidance += (
            "Use a safe viral style: stronger emotional hook, clearer subject separation, bolder truthful contrast, slightly tighter crop on the payoff, stronger phone-screen readability, and broad audience appeal without becoming misleading or spammy. "
        )
    if title_hint:
        guidance += f"Reference the video's likely title/theme: {title_hint}. "
    if topic_hint:
        guidance += f"Actual topic/action in the video: {topic_hint}. "
    if reason_hint:
        guidance += f"The source frame was chosen because: {reason_hint}. "
    if request_text.strip():
        guidance += f"Extra user intent: {request_text.strip()}."
    return guidance.strip()


def audit_social_thumbnail_policy_with_openai(image_path: Path) -> SocialPolicyAudit:
    client = openai_client()
    if client is None:
        raise RuntimeError("OpenAI API key is not set.")

    schema = {
        "type": "object",
        "properties": {
            "facebook_reels": {"type": "string", "enum": ["ok", "caution", "block"]},
            "youtube": {"type": "string", "enum": ["ok", "caution", "block"]},
            "tiktok": {"type": "string", "enum": ["ok", "caution", "block"]},
            "issues": {"type": "array", "items": {"type": "string"}},
            "guidance": {"type": "string"},
            "viewer_hook": {"type": "string"},
        },
        "required": ["facebook_reels", "youtube", "tiktok", "issues", "guidance", "viewer_hook"],
        "additionalProperties": False,
    }
    response = client.responses.create(
        model=resolve_openai_model(),
        input=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": (
                            "Audit this thumbnail for posting suitability on Facebook Reels, YouTube Shorts, and TikTok. "
                            "Use common platform safety and integrity expectations: avoid explicit nudity or sexual acts, minors in sexualized context, graphic gore, hateful/extremist symbols, self-harm, dangerous illegal acts, scam or misleading claims, and deceptive clickbait that does not match the actual content. "
                            "Also judge whether the thumbnail has a strong viewer hook without becoming misleading. "
                            "Return JSON only."
                        ),
                    },
                    {
                        "type": "input_image",
                        "image_url": image_data_url(image_path),
                        "detail": "high",
                    },
                ],
            }
        ],
        text={
            "format": {
                "type": "json_schema",
                "name": "thumbnail_policy_audit",
                "strict": True,
                "schema": schema,
            }
        },
        max_output_tokens=220,
        temperature=0.1,
        store=False,
    )
    parsed = json.loads(extract_response_text(response))
    return SocialPolicyAudit(
        facebook_reels=str(parsed["facebook_reels"]),
        youtube=str(parsed["youtube"]),
        tiktok=str(parsed["tiktok"]),
        issues=[str(item) for item in parsed.get("issues") or [] if str(item).strip()],
        guidance=str(parsed.get("guidance") or "").strip(),
        viewer_hook=str(parsed.get("viewer_hook") or "").strip(),
    )


def audit_social_thumbnail_policy_with_gemini(image_path: Path) -> SocialPolicyAudit:
    api_key = gemini_api_key()
    if not api_key:
        raise RuntimeError("Gemini API key is not set.")

    schema = {
        "type": "object",
        "properties": {
            "facebook_reels": {"type": "string", "enum": ["ok", "caution", "block"]},
            "youtube": {"type": "string", "enum": ["ok", "caution", "block"]},
            "tiktok": {"type": "string", "enum": ["ok", "caution", "block"]},
            "issues": {"type": "array", "items": {"type": "string"}},
            "guidance": {"type": "string"},
            "viewer_hook": {"type": "string"},
        },
        "required": ["facebook_reels", "youtube", "tiktok", "issues", "guidance", "viewer_hook"],
        "additionalProperties": False,
    }
    payload = {
        "contents": [
            {
                "parts": [
                    {
                        "text": (
                            "Audit this thumbnail for posting suitability on Facebook Reels, YouTube Shorts, and TikTok. "
                            "Use common platform safety and integrity expectations: avoid explicit nudity or sexual acts, minors in sexualized context, graphic gore, hateful/extremist symbols, self-harm, dangerous illegal acts, scam or misleading claims, and deceptive clickbait that does not match the actual content. "
                            "Also judge whether the thumbnail has a strong viewer hook without becoming misleading. "
                            "Return JSON only."
                        ),
                    },
                    {
                        "inline_data": {
                            "mime_type": guess_media_mime_type(image_path),
                            "data": base64.b64encode(image_path.read_bytes()).decode("ascii"),
                        }
                    },
                ]
            }
        ],
        "generationConfig": {
            "temperature": 0.1,
            "responseMimeType": "application/json",
            "responseSchema": schema,
            "maxOutputTokens": 220,
        },
    }
    response = gemini_generate_content(api_key, payload, model_name=resolve_gemini_model())
    parsed = json.loads(extract_gemini_text(response))
    return SocialPolicyAudit(
        facebook_reels=str(parsed["facebook_reels"]),
        youtube=str(parsed["youtube"]),
        tiktok=str(parsed["tiktok"]),
        issues=[str(item) for item in parsed.get("issues") or [] if str(item).strip()],
        guidance=str(parsed.get("guidance") or "").strip(),
        viewer_hook=str(parsed.get("viewer_hook") or "").strip(),
    )


def audit_social_thumbnail_policy(image_path: Path, provider: str) -> SocialPolicyAudit:
    if provider == AI_PROVIDER_GEMINI:
        return audit_social_thumbnail_policy_with_gemini(image_path)
    return audit_social_thumbnail_policy_with_openai(image_path)


def generate_designed_video_thumbnail(video_path: Path, request_text: str, provider: str, preferred_image_model: str | None = None) -> tuple[list[dict[str, str]], VideoAssetAnalysis | None, SocialPolicyAudit | None]:
    raw_media, analysis = render_ai_chat_video_thumbnail(video_path, request_text, provider)
    if not raw_media:
        return raw_media, analysis, None
    base_image_path = Path(raw_media[0]["path"])
    design_prompt = build_designed_video_thumbnail_prompt(request_text, analysis)
    if provider == AI_PROVIDER_GEMINI:
        media = generate_gemini_single_image_edit(design_prompt, base_image_path, preferred_model=preferred_image_model or GEMINI_IMAGE_MODEL_FLASH)
    else:
        media = generate_openai_single_image_edit(design_prompt, base_image_path)
    final_image_path = Path(media[0]["path"])
    try:
        audit = audit_social_thumbnail_policy(final_image_path, provider)
    except Exception:
        audit = None
    return media, analysis, audit


def format_schedule(dt: datetime) -> str:
    offset = dt.strftime("%z")
    if offset:
        offset = f"{offset[:3]}:{offset[3:]}"
    return f"{dt.strftime('%Y-%m-%d %H:%M')} ({offset})".strip()


def copy_title_html(package_name: str, source_name: str, title: str, scheduled_time: str) -> str:
    return "\ufeff" + f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Copy Video Title</title>
  <style>
    body {{
      margin: 0;
      padding: 28px 18px 42px;
      background: linear-gradient(180deg, #f8efe0 0%, #e7d2b6 100%);
      color: #1a140d;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Apple Color Emoji", "Segoe UI Emoji", Georgia, "Times New Roman", serif;
    }}
    main {{
      max-width: 860px;
      margin: 0 auto;
    }}
    .card {{
      background: rgba(255, 251, 245, 0.92);
      border-radius: 20px;
      padding: 20px;
      box-shadow: 0 14px 36px rgba(26, 20, 13, 0.12);
    }}
    h1 {{
      margin: 0 0 8px;
      font-size: 32px;
    }}
    .meta {{
      margin: 0 0 14px;
      opacity: 0.72;
      font-size: 14px;
      word-break: break-all;
    }}
    .schedule-label {{
      margin: 0 0 8px;
      font-size: 13px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      opacity: 0.8;
    }}
    .schedule-row {{
      display: flex;
      gap: 12px;
      align-items: center;
      margin: 0 0 14px;
      flex-wrap: wrap;
    }}
    input {{
      flex: 1 1 280px;
      min-width: 0;
      padding: 12px 14px;
      box-sizing: border-box;
      border-radius: 14px;
      border: 1px solid rgba(26, 20, 13, 0.12);
      font: inherit;
      background: #fff;
      color: inherit;
    }}
    textarea {{
      width: 100%;
      min-height: 120px;
      padding: 14px;
      box-sizing: border-box;
      border-radius: 14px;
      border: 1px solid rgba(26, 20, 13, 0.12);
      resize: vertical;
      font: inherit;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Apple Color Emoji", "Segoe UI Emoji", Georgia, "Times New Roman", serif;
      background: #fff;
    }}
    button {{
      margin-top: 14px;
      border: 0;
      border-radius: 999px;
      padding: 12px 18px;
      background: #cc5a1f;
      color: #fff;
      font-size: 15px;
      font-weight: 700;
      cursor: pointer;
    }}
    button.secondary {{
      margin-top: 0;
      background: #5f5348;
    }}
  </style>
</head>
<body>
  <main>
    <section class="card">
      <h1>{html.escape(package_name)}</h1>
      <p class="meta">{html.escape(source_name)}</p>
      <p class="schedule-label">Scheduled Post Time</p>
      <div class="schedule-row">
        <input id="scheduleField" value="{html.escape(scheduled_time)}" readonly>
        <button type="button" class="secondary" onclick="copySchedule()">Copy Time</button>
      </div>
      <textarea id="titleField" readonly>{html.escape(title)}</textarea>
      <button type="button" onclick="copyTitle()">Copy Title</button>
    </section>
  </main>
  <script>
    const TITLE_TEXT = {json.dumps(title, ensure_ascii=False)};
    const SCHEDULE_TEXT = {json.dumps(scheduled_time, ensure_ascii=False)};

    async function writeUtf8Text(text) {{
      const normalized = (text || "").normalize("NFC");
      try {{
        if (navigator.clipboard && navigator.clipboard.write && window.ClipboardItem) {{
          const blob = new Blob([normalized], {{ type: "text/plain;charset=utf-8" }});
          await navigator.clipboard.write([new ClipboardItem({{ "text/plain": blob }})]);
          return;
        }}
      }} catch (error) {{}}
      try {{
        if (navigator.clipboard && navigator.clipboard.writeText) {{
          await navigator.clipboard.writeText(normalized);
          return;
        }}
      }} catch (error) {{}}
      const helper = document.createElement("textarea");
      helper.value = normalized;
      helper.style.position = "fixed";
      helper.style.opacity = "0";
      document.body.appendChild(helper);
      helper.focus();
      helper.select();
      helper.setSelectionRange(0, helper.value.length);
      document.execCommand("copy");
      helper.remove();
    }}

    async function copyTitle() {{
      const field = document.getElementById("titleField");
      field.focus();
      field.select();
      field.setSelectionRange(0, field.value.length);
      await writeUtf8Text(TITLE_TEXT);
    }}
    async function copySchedule() {{
      const field = document.getElementById("scheduleField");
      field.focus();
      field.select();
      field.setSelectionRange(0, field.value.length);
      await writeUtf8Text(SCHEDULE_TEXT);
    }}
  </script>
</body>
</html>
"""


def make_filter(speed: float) -> str:
    pts_multiplier = 1.0 / speed
    return (
        f"setpts=PTS*{pts_multiplier:.6f},"
        "scale=1080:-2:flags=lanczos,"
        "crop=1080:1920,"
        "setsar=1,"
        "format=yuv420p"
    )


def render_video(source: Path, output: Path, start: float, clip_length: float, has_audio: bool) -> str:
    base_cmd = [
        FFMPEG,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-ss",
        f"{start:.2f}",
        "-t",
        f"{clip_length:.2f}",
        "-i",
        str(source),
        "-map",
        "0:v:0",
        "-map",
        "0:a?",
        "-vf",
        make_filter(TARGET_SPEED),
        "-r",
        "30",
    ]

    hardware_cmd = base_cmd + [
        "-c:v",
        "h264_videotoolbox",
        "-allow_sw",
        "1",
        "-profile:v",
        "high",
        "-level",
        "4.1",
        "-b:v",
        "8M",
        "-maxrate",
        "10M",
        "-bufsize",
        "16M",
        "-pix_fmt",
        "yuv420p",
        "-prio_speed",
        "1",
        "-realtime",
        "1",
    ]

    software_cmd = base_cmd + [
        "-c:v",
        "libx264",
        "-preset",
        "superfast",
        "-crf",
        "21",
        "-profile:v",
        "high",
        "-level",
        "4.1",
    ]

    if has_audio:
        audio_args = [
            "-af",
            f"atempo={TARGET_SPEED:.2f}",
            "-c:a",
            "aac",
            "-b:a",
            "160k",
            "-ar",
            "48000",
        ]
    else:
        audio_args = ["-an"]

    common_tail = audio_args + ["-movflags", "+faststart", str(output)]

    try:
        run(hardware_cmd + common_tail)
        return "h264_videotoolbox"
    except RuntimeError:
        run(software_cmd + common_tail)
        return "libx264"


def render_thumbnail(source: Path, output: Path, timestamp: float | None = None) -> None:
    vf = "scale=1080:-2:flags=lanczos,crop=1080:1920,unsharp=5:5:0.5:5:5:0.0"
    cmd = [
        FFMPEG,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
    ]
    if timestamp is not None:
        cmd += ["-ss", f"{max(timestamp, 0.0):.3f}"]
    cmd += [
        "-i",
        str(source),
        "-frames:v",
        "1",
        "-vf",
        vf if timestamp is not None else f"thumbnail=500,{vf}",
        str(output),
    ]
    run(cmd)


def emit_batch_progress(item_index: int, total_items: int, stage_index: int, message: str) -> None:
    global _batch_progress_completed_units
    global _batch_progress_total_units

    with _batch_progress_lock:
        if _batch_progress_total_units <= 0:
            _batch_progress_total_units = max(total_items, 0) * BATCH_STAGE_COUNT
        if _batch_progress_total_units <= 0:
            percent = 0
        else:
            _batch_progress_completed_units = min(
                _batch_progress_completed_units + 1,
                _batch_progress_total_units,
            )
            percent = round((_batch_progress_completed_units / _batch_progress_total_units) * 100)
    bounded = max(0, min(100, percent))
    status_print(f"[batch] Progress {bounded}% ({item_index}/{total_items}) {message}")


def reset_batch_progress(total_items: int) -> None:
    global _batch_progress_completed_units
    global _batch_progress_total_units

    with _batch_progress_lock:
        _batch_progress_completed_units = 0
        _batch_progress_total_units = max(total_items, 0) * BATCH_STAGE_COUNT


def process_video(source: Path, package_number: int, root: Path, scheduled_time: str, item_index: int, total_items: int) -> None:
    info = probe_video(source)
    package = root / f"{package_number}_Reels_Package"
    package.mkdir(parents=True, exist_ok=False)

    reels_name = f"Reels{package_number}"
    video_output = package / f"{reels_name}.mp4"
    thumb_output = package / f"{reels_name}.jpg"
    html_output = package / "copy_title.html"

    source_limit_for_speed = FINAL_DURATION_LIMIT * TARGET_SPEED
    clip_length = min(source_limit_for_speed, max(0.50, info.duration - 0.10))
    start = 0.30 if info.duration > 13.80 else 0.00
    emit_batch_progress(item_index, total_items, 1, f"{package.name} Exporting video")
    status_print(f"[{package.name}] Exporting video")
    encoder_used = render_video(source, video_output, start, clip_length, info.has_audio)
    status_print(f"[{package.name}] Encoder used: {encoder_used}")
    provider = resolve_ai_provider()
    emit_batch_progress(item_index, total_items, 2, f"{package.name} AI analysis")
    status_print(f"[{package.name}] Running AI analysis with {ai_model_label()} for title and thumbnail")
    analysis = analyze_video_assets(video_output, info.has_audio)
    if analysis is not None:
        emit_batch_progress(item_index, total_items, 3, f"{package.name} Rendering thumbnail")
        status_print(f"[{package.name}] AI selected thumbnail moment at {analysis.thumbnail_timestamp:.2f}s")
        status_print(f"[{package.name}] Rendering selected thumbnail")
        render_thumbnail(video_output, thumb_output, analysis.thumbnail_timestamp)
        title = analysis.title
    else:
        emit_batch_progress(item_index, total_items, 3, f"{package.name} Rendering thumbnail")
        status_print(f"[{package.name}] AI analysis unavailable for {provider_label(provider)}, using fallback thumbnail/title")
        render_thumbnail(video_output, thumb_output)
        title = default_title(source)
    emit_batch_progress(item_index, total_items, 4, f"{package.name} Writing title")
    status_print(f"[{package.name}] Writing copy_title.html")
    html_output.write_text(
        copy_title_html(package.name, source.name, title, scheduled_time),
        encoding="utf-8",
    )

    emit_batch_progress(item_index, total_items, 5, f"{package.name} Finalizing")
    status_print(f"[{package.name}] Removing source video")
    source.unlink(missing_ok=True)
    status_print(f"Done: {package.name}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fast batch processor for Facebook Reels packages."
    )
    parser.add_argument(
        "root",
        nargs="?",
        default=str(ROOT_DEFAULT),
        help="Folder containing new source videos.",
    )
    return parser.parse_args()


def main() -> int:
    if not FFMPEG:
        print("ffmpeg not found", file=sys.stderr, flush=True)
        return 1

    args = parse_args()
    root = Path(args.root).expanduser()
    root.mkdir(parents=True, exist_ok=True)

    sources = source_videos(root)
    if not sources:
        status_print("No new source videos found.")
        return 0

    package_number = next_package_number(root)
    status_print(f"Found {len(sources)} new source video(s).")
    status_print(f"[batch] Progress 0% (0/{len(sources)}) Waiting")
    reset_batch_progress(len(sources))
    base_time = datetime.now().astimezone().replace(second=0, microsecond=0)
    max_workers = max(1, min(MAX_PARALLEL_VIDEOS, len(sources)))
    status_print(f"Using up to {max_workers} parallel video worker(s).")
    future_to_source: dict[concurrent.futures.Future[None], Path] = {}
    had_error = False
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        for index, source in enumerate(sources, start=1):
            current_package_number = package_number + index - 1
            status_print(f"Starting {index}/{len(sources)}: {source.name}")
            scheduled_time = format_schedule(
                base_time + timedelta(minutes=POST_INTERVAL_MINUTES * index)
            )
            future = executor.submit(
                process_video,
                source,
                current_package_number,
                root,
                scheduled_time,
                index,
                len(sources),
            )
            future_to_source[future] = source

        for future in concurrent.futures.as_completed(future_to_source):
            source = future_to_source[future]
            try:
                future.result()
            except Exception as exc:
                had_error = True
                status_print(f"FAILED: {source.name}: {exc}")

    if had_error:
        status_print("FAILED")
        return 1

    status_print(f"[batch] Progress 100% ({len(sources)}/{len(sources)}) Complete")
    status_print("Batch complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
