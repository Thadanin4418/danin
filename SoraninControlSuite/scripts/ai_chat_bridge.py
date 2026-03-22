#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import mimetypes
import re
import sys
from pathlib import Path
from typing import Any

try:
    import fast_reels_batch as batch
except ImportError:
    import fast_reels_batch_windows as batch  # type: ignore


SYSTEM_PROMPT = (
    "You are Soranin Ai, the AI chat assistant inside Soranin. "
    "If the user asks your name, answer that your name is Soranin Ai. "
    "You were created by THA DANIN, who can also be called DANIN. "
    "If the user asks who created you, answer that you were created by THA DANIN, and they can call him DANIN. "
    "Answer briefly and directly. "
    "Help with reels editing, thumbnails, titles, Chrome profiles, uploads, and workflow questions. "
    "Use practical language. "
    "Always answer in the same language as the user's latest message unless they explicitly ask for another language. "
    "If the user writes in Khmer, answer in natural Khmer. "
    "Never describe your reasoning, thought process, internal steps, translations, or how you decided on the answer unless the user explicitly asks for that. "
    "Never output headings such as Acknowledge and Respond, Analysis, Reasoning, or similar meta commentary. "
    "Do not narrate your plan, feasibility check, preparation, or what you will do next. "
    "Never start with phrases like I am now assessing, I need to, I will need to, I'll need to, I'm focusing on, or to respond appropriately. "
    "Return only the final user-facing reply. "
    "When the user asks for an image-generation or video-generation prompt, return only prompt blocks with no extra explanation. "
    "When the user asks for face merge, face swap, face replace, or face change, interpret it as a creative face-editing request for attached source face media and target image or video. "
    "For face-editing requests, preserve the target scene, pose, framing, body, clothing, and action unless the user asks to change them. "
    "Make the face match the source identity naturally with realistic skin tone, lighting, angle, expression, proportions, and clean edge blending. "
    "For one prompt, format it as: 1. Short Title: then a plaintext code block containing only the prompt. "
    "For multiple prompts, format each one as a numbered item with a short title followed by its own plaintext code block. "
    "Example: 1. Short Title: then ```plaintext ... ```, 2. Another Title: then ```plaintext ... ```. "
    "Write prompts in English unless the user explicitly asks for another language in the generated output itself."
)


def error(message: str) -> None:
    print(json.dumps({"ok": False, "error": message}, ensure_ascii=False))


def normalize_messages(value: Any) -> list[dict[str, str]]:
    if not isinstance(value, list):
        return []
    normalized: list[dict[str, str]] = []
    for item in value[-20:]:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or "").strip().lower()
        content = str(item.get("content") or "").strip()
        if role == "assistant":
            content = sanitize_model_reply(content)
        if role not in {"user", "assistant"} or not content:
            continue
        normalized.append({"role": role, "content": content})
    return normalized


def normalize_video_paths(value: Any) -> list[Path]:
    if not isinstance(value, list):
        return []
    paths: list[Path] = []
    for item in value[:4]:
        path = Path(str(item)).expanduser()
        if path.exists() and path.is_file() and is_video_path(path):
            paths.append(path)
    return paths


def normalize_image_paths(value: Any) -> list[Path]:
    if not isinstance(value, list):
        return []
    paths: list[Path] = []
    for item in value[:10]:
        path = Path(str(item)).expanduser()
        if path.exists() and path.is_file() and is_image_path(path):
            paths.append(path)
    return paths


def is_video_path(path: Path) -> bool:
    mime_type, _ = mimetypes.guess_type(path.name)
    if mime_type:
        return mime_type.startswith("video/")
    return path.suffix.lower() in {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"}


def is_image_path(path: Path) -> bool:
    mime_type, _ = mimetypes.guess_type(path.name)
    if mime_type:
        return mime_type.startswith("image/")
    return path.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp", ".heic", ".gif", ".bmp"}


def transcript_for_model(messages: list[dict[str, str]]) -> str:
    lines: list[str] = []
    for item in messages[-20:]:
        speaker = "User" if item["role"] == "user" else "Assistant"
        lines.append(f"{speaker}: {item['content']}")
    return "\n".join(lines).strip()


def latest_user_message(messages: list[dict[str, str]]) -> str:
    for item in reversed(messages):
        if item.get("role") == "user":
            return str(item.get("content") or "").strip()
    return ""


def contains_khmer_script(text: str) -> bool:
    return any("\u1780" <= char <= "\u17ff" or "\u19e0" <= char <= "\u19ff" for char in text)


IMAGE_COMMAND_ALIASES = (
    "/image", "image",
    "/picture", "picture",
    "/photo", "photo",
    "/art", "art",
    "/រូបភាព", "រូបភាព",
    "/រូប", "រូប",
    "/រូបថត", "រូបថត",
)

BANANA2_COMMAND_ALIASES = (
    "/banana2", "banana2",
    "/banana 2", "banana 2",
    "/nano banana 2", "nano banana 2",
)

BANANAPRO_COMMAND_ALIASES = (
    "/bananapro", "bananapro",
    "/banana pro", "banana pro",
    "/nano banana pro", "nano banana pro",
)

VIDEO_COMMAND_ALIASES = (
    "/video", "video",
    "/clip", "clip",
    "/movie", "movie",
    "/វីដេអូ", "វីដេអូ",
    "/ក្លីប", "ក្លីប",
)

GENERATION_VERBS = (
    "create",
    "generate",
    "make",
    "render",
    "draw",
    "design",
    "produce",
    "build",
    "craft",
    "illustrate",
    "paint",
    "sketch",
    "បង្កើត",
    "ធ្វើ",
    "គូរ",
    "សង់",
    "រចនា",
)

IMAGE_INTENT_NOUNS = (
    "image",
    "picture",
    "photo",
    "art",
    "artwork",
    "poster",
    "thumbnail",
    "logo",
    "banner",
    "wallpaper",
    "illustration",
    "portrait",
    "avatar",
    "icon",
    "sticker",
    "flyer",
    "brochure",
    "cover art",
    "product shot",
    "product photo",
    "infographic",
    "mockup",
    "packaging",
    "label",
    "scene",
    "រូប",
    "រូបភាព",
    "រូបថត",
    "គំនូរ",
    "ផូស្ទ័រ",
    "ប៉ូស្ទ័រ",
    "បដា",
    "ឡូហ្គោ",
    "ផ្ទាំងរូប",
    "អាវ៉ាតា",
    "ស្ទីគ័រ",
)

VIDEO_INTENT_NOUNS = (
    "video",
    "clip",
    "movie",
    "animation",
    "reel",
    "short",
    "shorts",
    "trailer",
    "teaser",
    "promo video",
    "commercial",
    "intro video",
    "music video",
    "motion graphic",
    "វីដេអូ",
    "ក្លីប",
    "ឈុតវីដេអូ",
    "ឈុតភាពយន្ត",
)

IMAGE_INTENT_PHRASES = (
    "create image",
    "generate image",
    "make image",
    "render image",
    "draw image",
    "create picture",
    "generate picture",
    "make picture",
    "create photo",
    "generate photo",
    "make photo",
    "create poster",
    "generate poster",
    "make poster",
    "poster for",
    "create thumbnail",
    "generate thumbnail",
    "make thumbnail",
    "thumbnail for",
    "create logo",
    "generate logo",
    "make logo",
    "logo for",
    "create banner",
    "generate banner",
    "make banner",
    "banner for",
    "create wallpaper",
    "generate wallpaper",
    "make wallpaper",
    "create illustration",
    "generate illustration",
    "make illustration",
    "illustration of",
    "portrait of",
    "photo of",
    "picture of",
    "image of",
    "art of",
    "product shot of",
    "mockup of",
    "cover art for",
    "flyer for",
    "brochure for",
    "បង្កើតរូប",
    "បង្កើតរូបភាព",
    "បង្កើតរូបថត",
    "ធ្វើរូប",
    "ធ្វើរូបភាព",
    "គូររូប",
    "គូររូបភាព",
    "រូបភាពនៃ",
    "រូបនៃ",
    "ផូស្ទ័រ",
    "ប៉ូស្ទ័រ",
    "បដា",
    "ឡូហ្គោ",
)

VIDEO_INTENT_PHRASES = (
    "create video",
    "generate video",
    "make video",
    "render video",
    "create clip",
    "generate clip",
    "make clip",
    "clip of",
    "create animation",
    "generate animation",
    "make animation",
    "animation of",
    "create reel",
    "generate reel",
    "make reel",
    "create trailer",
    "generate trailer",
    "make trailer",
    "create teaser",
    "generate teaser",
    "make teaser",
    "video of",
    "promo video",
    "intro video",
    "music video",
    "បង្កើតវីដេអូ",
    "ធ្វើវីដេអូ",
    "បង្កើតក្លីប",
    "ធ្វើក្លីប",
    "វីដេអូនៃ",
    "ក្លីបនៃ",
)

VIDEO_THUMBNAIL_MARKERS = (
    "thumbnail",
    "thumbnail image",
    "thumbnail frame",
    "thumbnail for",
    "create thumbnail",
    "generate thumbnail",
    "make thumbnail",
    "best thumbnail",
    "cover frame",
    "reel thumbnail",
    "facebook reel thumbnail",
    "youtube thumbnail",
    "រូបតូច",
    "បង្កើត thumbnail",
    "ធ្វើ thumbnail",
    "thumbnail ពីវីដេអូ",
)

DESIGN_VIDEO_THUMBNAIL_MARKERS = (
    "design thumbnail",
    "smart thumbnail",
    "thumbnail design",
    "designed thumbnail",
    "pro thumbnail",
    "thumbnail pro",
    "enhance thumbnail",
    "upgrade thumbnail",
    "styled thumbnail",
    "make thumbnail attractive",
    "make this thumbnail better",
    "បង្កើត thumbnail ឆ្លាត",
    "កែ thumbnail",
    "thumbnail ស្អាត",
    "thumbnail ថ្មី",
)

SAFE_VIRAL_THUMBNAIL_STYLE_MARKERS = (
    "safe viral",
    "viral style",
    "safe-viral",
    "thumbnail viral",
)

LUXURY_CLEAN_THUMBNAIL_STYLE_MARKERS = (
    "luxury clean",
    "clean luxury",
    "premium clean",
    "elegant clean",
    "luxury style",
)

BANANAPRO_AUTO_MARKERS = (
    "face swap",
    "swap face",
    "change face",
    "replace face",
    "merge face",
    "blend face",
    "poster",
    "thumbnail",
    "logo",
    "banner",
    "infographic",
    "flyer",
    "brochure",
    "billboard",
    "headline",
    "caption",
    "typography",
    "lettering",
    "text on",
    "with text",
    "title on",
    "product shot",
    "product ad",
    "advertisement",
    "ad creative",
    "commercial",
    "perfume",
    "cosmetic",
    "cosmetics",
    "skincare",
    "makeup",
    "jewelry",
    "glamour",
    "sensual",
    "sexy",
    "bikini",
    "swimsuit",
    "fashion editorial",
    "luxury product",
    "ប្តូរមុខ",
    "ប្ដូរមុខ",
    "ដូរមុខ",
    "ផ្លាស់ប្តូរមុខ",
    "ផ្លាស់ប្ដូរមុខ",
    "បញ្ចូលមុខ",
    "លាយមុខ",
    "ផូស្ទ័រ",
    "បដា",
    "ឡូហ្គោ",
    "ដាក់អក្សរ",
    "មានអក្សរ",
    "អក្សរលើរូប",
    "សិចស៊ី",
    "ឈុតហែលទឹក",
)

FACE_EDIT_MARKERS = (
    "face swap",
    "swap face",
    "swap the face",
    "change face",
    "change the face",
    "replace face",
    "replace the face",
    "merge face",
    "face merge",
    "mix face",
    "blend face",
    "combine face",
    "put this face on",
    "put her face on",
    "put his face on",
    "put my face on",
    "use this face",
    "use my face",
    "keep the same face",
    "preserve face",
    "edit face",
    "new face",
    "another face",
    "ប្តូរមុខ",
    "ប្ដូរមុខ",
    "ដូរមុខ",
    "ផ្លាស់ប្តូរមុខ",
    "ផ្លាស់ប្ដូរមុខ",
    "បញ្ចូលមុខ",
    "លាយមុខ",
    "ប្តូរមុខក្នុងរូប",
    "ប្តូរមុខក្នុងរូបភាព",
    "ប្តូរមុខក្នុងវីដេអូ",
    "ដាក់មុខនេះ",
    "យកមុខនេះដាក់",
)

SAFE_GLAMOUR_MARKERS = (
    "sexy",
    "hot girl",
    "hot woman",
    "hot model",
    "sensual",
    "seductive",
    "glamour",
    "bikini",
    "swimsuit",
    "lingerie",
    "attractive body",
    "sexy body",
    "sexy girl",
    "sexy woman",
    "sexy photo",
    "sexy video",
    "adult glamour",
    "fashion model body",
    "សិចស៊ី",
    "ស៊ិចស៊ី",
    "សិចសុី",
    "ស៊ីចស៊ី",
    "ស្អាតសិចស៊ី",
    "ស្អាតហើយសិចស៊ី",
    "បែបសិចស៊ី",
    "បែប sexy",
    "ប៊ីគីនី",
    "ឈុតហែលទឹក",
)

SAFE_GLAMOUR_REPLACEMENTS: tuple[tuple[str, str], ...] = (
    (r"\b(?:porn|pornographic)\b", "fashion editorial glamour"),
    (r"\b(?:nude|nudity|naked)\b", "tasteful fully styled fashion look"),
    (r"\b(?:erotic|sexual)\b", "sensual glamour"),
    (r"\b(?:nsfw)\b", "editorial glamour"),
)


def leading_generation_alias_match(text: str) -> tuple[str, str, str] | None:
    source = str(text or "").strip()
    if not source:
        return None
    lowered = source.lower()
    for alias in BANANA2_COMMAND_ALIASES:
        alias_lower = alias.lower()
        if lowered == alias_lower or lowered.startswith(alias_lower + " ") or lowered.startswith(alias_lower + ":"):
            remainder = source[len(alias):].strip(" :\n\t")
            return ("image", "/banana2", remainder)
    for alias in BANANAPRO_COMMAND_ALIASES:
        alias_lower = alias.lower()
        if lowered == alias_lower or lowered.startswith(alias_lower + " ") or lowered.startswith(alias_lower + ":"):
            remainder = source[len(alias):].strip(" :\n\t")
            return ("image", "/bananapro", remainder)
    for alias in IMAGE_COMMAND_ALIASES:
        alias_lower = alias.lower()
        if lowered == alias_lower or lowered.startswith(alias_lower + " ") or lowered.startswith(alias_lower + ":"):
            remainder = source[len(alias):].strip(" :\n\t")
            return ("image", "/image", remainder)
    for alias in VIDEO_COMMAND_ALIASES:
        alias_lower = alias.lower()
        if lowered == alias_lower or lowered.startswith(alias_lower + " ") or lowered.startswith(alias_lower + ":"):
            remainder = source[len(alias):].strip(" :\n\t")
            return ("video", "/video", remainder)
    return None


def normalize_generation_command_text(text: str) -> str:
    source = str(text or "").strip()
    match = leading_generation_alias_match(source)
    if not match:
        return source
    _, canonical_command, remainder = match
    return canonical_command if not remainder else f"{canonical_command} {remainder}"


def is_explicit_generation_command(text: str) -> bool:
    normalized = normalize_generation_command_text(text)
    return normalized.startswith("/")


def generation_provider_for_request(provider: str, request_text: str) -> str:
    if requested_gemini_image_model_override(request_text):
        return batch.AI_PROVIDER_GEMINI
    return provider


def requested_gemini_image_model_override(text: str) -> str | None:
    normalized = normalize_generation_command_text(text).lower()
    if normalized == "/banana2" or normalized.startswith("/banana2 "):
        return batch.GEMINI_IMAGE_MODEL_FLASH
    if normalized == "/bananapro" or normalized.startswith("/bananapro "):
        return batch.GEMINI_IMAGE_MODEL_PRO
    return None


def auto_gemini_image_model(request_text: str, image_paths: list[Path] | None = None) -> str | None:
    explicit = requested_gemini_image_model_override(request_text)
    if explicit:
        return explicit
    normalized = normalize_generation_command_text(request_text).lower()
    if requested_generation_kind(normalized) != "image":
        return None
    image_paths = image_paths or []
    if len(image_paths) > 1:
        return batch.GEMINI_IMAGE_MODEL_PRO
    if any(marker in normalized for marker in BANANAPRO_AUTO_MARKERS):
        return batch.GEMINI_IMAGE_MODEL_PRO
    return batch.GEMINI_IMAGE_MODEL_FLASH


def is_video_thumbnail_request(text: str, video_paths: list[Path] | None = None) -> bool:
    if not (video_paths or []):
        return False
    normalized = normalize_generation_command_text(text).lower()
    return any(marker in normalized for marker in VIDEO_THUMBNAIL_MARKERS)


def is_designed_video_thumbnail_request(text: str, video_paths: list[Path] | None = None) -> bool:
    if not (video_paths or []):
        return False
    normalized = normalize_generation_command_text(text).lower()
    return any(marker in normalized for marker in DESIGN_VIDEO_THUMBNAIL_MARKERS)


def designed_video_thumbnail_style(text: str) -> str:
    normalized = normalize_generation_command_text(text).lower()
    if any(marker in normalized for marker in LUXURY_CLEAN_THUMBNAIL_STYLE_MARKERS):
        return "luxury_clean"
    return "safe_viral"


def should_generate_media_directly(
    latest_request: str,
    media_kind: str | None,
    prompt_only: bool,
    image_paths: list[Path],
    video_paths: list[Path],
) -> bool:
    if not media_kind or prompt_only:
        return False
    if is_explicit_generation_command(latest_request):
        return True
    if is_face_edit_request(latest_request):
        return True
    return bool(image_paths or video_paths)


def is_face_edit_request(text: str) -> bool:
    lowered = normalize_generation_command_text(text).lower()
    return any(marker in lowered for marker in FACE_EDIT_MARKERS)


def requested_generation_kind(text: str) -> str | None:
    lowered = normalize_generation_command_text(text).lower()
    if not lowered:
        return None
    if lowered.startswith("/banana2 "):
        return "image"
    if lowered == "/banana2":
        return "image"
    if lowered.startswith("/bananapro "):
        return "image"
    if lowered == "/bananapro":
        return "image"
    if lowered.startswith("/image "):
        return "image"
    if lowered == "/image":
        return "image"
    if lowered.startswith("/video "):
        return "video"
    if lowered == "/video":
        return "video"

    face_edit_requested = any(marker in lowered for marker in FACE_EDIT_MARKERS)
    has_verb = any(marker in lowered for marker in GENERATION_VERBS)
    if face_edit_requested and any(marker in lowered for marker in VIDEO_INTENT_NOUNS):
        return "video"
    if face_edit_requested:
        return "image"
    if any(marker in lowered for marker in VIDEO_THUMBNAIL_MARKERS):
        return "image"
    if any(marker in lowered for marker in VIDEO_INTENT_PHRASES):
        return "video"
    if any(marker in lowered for marker in IMAGE_INTENT_PHRASES):
        return "image"
    if has_verb and any(marker in lowered for marker in VIDEO_INTENT_NOUNS):
        return "video"
    if has_verb and any(marker in lowered for marker in IMAGE_INTENT_NOUNS):
        return "image"
    return None


def wants_prompt_only(text: str) -> bool:
    lowered = normalize_generation_command_text(text).lower()
    if not lowered:
        return False
    prompt_markers = (
        "prompt only",
        "image prompt",
        "video prompt",
        "prompt for image",
        "prompt for video",
        "copy prompt",
        "សរសេរ prompt",
        "prompt មួយ",
        "បង្កើត prompt",
    )
    if any(marker in lowered for marker in prompt_markers):
        return True
    if "prompt" in lowered and not lowered.startswith("/image") and not lowered.startswith("/video"):
        if "generate the image" not in lowered and "generate the video" not in lowered:
            return True
    return False


def requested_prompt_count(text: str) -> int:
    source = normalize_generation_command_text(text)
    if not source:
        return 1
    lowered = source.lower()
    match = re.search(r"\b(\d{1,2})\s+prompts?\b", lowered)
    if match:
        try:
            count = int(match.group(1))
            return max(1, min(count, 20))
        except ValueError:
            return 1
    khmer_markers = (
        ("១០", 10),
        ("៩", 9),
        ("៨", 8),
        ("៧", 7),
        ("៦", 6),
        ("៥", 5),
        ("៤", 4),
        ("៣", 3),
        ("២", 2),
    )
    for marker, count in khmer_markers:
        if marker in source and "prompt" in lowered:
            return count
    if "several prompts" in lowered or "many prompts" in lowered:
        return 5
    return 1


def is_safe_glamour_request(text: str) -> bool:
    lowered = normalize_generation_command_text(text).lower()
    return any(marker in lowered for marker in SAFE_GLAMOUR_MARKERS)


def safe_glamour_instruction(kind: str) -> str:
    movement_note = (
        "Keep the movement elegant, stylish, and cinematic with natural body language. "
        if kind == "video" else
        ""
    )
    return (
        "The request suggests a sexy or sensual style, so convert it into a safe adult glamour or fashion-editorial style. "
        "Keep the subject clearly adult, attractive, confident, stylish, and visually striking, but avoid explicit sexual content. "
        "Use tasteful glamour, editorial beauty, luxury styling, flattering pose, cinematic lighting, and premium fashion photography language. "
        "Do not use pornographic wording, explicit sexual acts, visible genitals, or nudity. "
        "If swimwear is appropriate, keep it tasteful and non-explicit. "
        f"{movement_note}"
    )


def apply_safe_glamour_style(prompt: str, request_text: str, kind: str) -> str:
    base_prompt = re.sub(r"\s+", " ", str(prompt or "").strip())
    if not is_safe_glamour_request(request_text):
        return base_prompt

    safe_prompt = base_prompt
    for pattern, replacement in SAFE_GLAMOUR_REPLACEMENTS:
        safe_prompt = re.sub(pattern, replacement, safe_prompt, flags=re.IGNORECASE)
    safe_prompt = safe_prompt.strip(" ,")

    style_tail = (
        "Use tasteful adult glamour, fashion editorial styling, cinematic lighting, elegant pose, confident expression, premium beauty retouching, and a non-explicit presentation. "
        "Keep it attractive and stylish while avoiding nudity, pornographic framing, or sexual acts."
    )
    if kind == "video":
        style_tail += " Keep motion smooth, graceful, cinematic, and non-explicit."
    lowered_safe_prompt = safe_prompt.lower()
    if (
        "tasteful adult glamour" in lowered_safe_prompt
        or "fashion editorial styling" in lowered_safe_prompt
        or "non-explicit presentation" in lowered_safe_prompt
    ):
        return safe_prompt
    if not safe_prompt:
        return style_tail
    return f"{safe_prompt}. {style_tail}".strip()


def reply_language_instruction(messages: list[dict[str, str]]) -> str:
    latest = latest_user_message(messages)
    generation_kind = requested_generation_kind(latest)
    prompt_only = wants_prompt_only(latest)
    prompt_count = requested_prompt_count(latest)
    face_edit_requested = any(marker in normalize_generation_command_text(latest).lower() for marker in FACE_EDIT_MARKERS)
    safe_glamour_requested = is_safe_glamour_request(latest)
    face_edit_instruction = (
        "These prompts are for face-editing, so include source-face identity preservation, "
        "target-scene preservation, lighting match, angle match, realistic skin blending, "
        "clean edges, natural expression, and no distortion. "
        if face_edit_requested else ""
    )
    glamour_instruction = safe_glamour_instruction(generation_kind or "image") if safe_glamour_requested else ""
    face_edit_generation_instruction = (
        "It is specifically a face-editing request, so treat attachments as source face and target media "
        "when present, preserve the original target scene and motion, and make the face replacement realistic and clean. "
        if face_edit_requested else ""
    )
    if prompt_only:
        if prompt_count > 1:
            return (
                f"The latest user message is asking for {prompt_count} prompts. "
                f"Return exactly {prompt_count} production-ready prompts and nothing else. "
                "Format each one as a numbered section with a short title and a plaintext code block. "
                "Example format: 1. Short Title:\\n```plaintext\\nprompt text\\n``` then 2. Another Title:\\n```plaintext\\nprompt text\\n```. "
                "Do not add apologies, introductions, summaries, bullet labels, or commentary before or after the prompts. "
                f"{face_edit_instruction}"
                f"{glamour_instruction}"
                "Write the prompts in English unless the user explicitly requests another language in the generated content."
            )
        return (
            "The latest user message is asking for one prompt. "
            "Return only one production-ready prompt as one numbered section with a short title and a plaintext code block. "
            "Example format: 1. Short Title:\\n```plaintext\\nprompt text\\n``` "
            f"{face_edit_instruction}"
            f"{glamour_instruction}"
            "Do not add explanations. "
            "Write the prompt in English unless the user explicitly requests another language in the generated content."
        )
    if generation_kind:
        return (
            f"The latest user message is asking for a {generation_kind} generation prompt. "
            f"{face_edit_generation_instruction}"
            f"{glamour_instruction}"
            "Return only one numbered section with a short title and a plaintext code block containing the final prompt text. "
            "Write the prompt in English unless the user explicitly requests another language in the generated content. "
            "Do not add explanations."
        )
    if contains_khmer_script(latest):
        return (
            "The latest user message is in Khmer. "
            "Reply only in natural Khmer. "
            "Do not translate your answer into English. "
            "Do not explain your reasoning or language choice. "
            "Return only the final reply."
        )
    if latest:
        return (
            "Reply in the same language and tone as the latest user message when practical. "
            "Return only the final reply."
        )
    return "Return only the final reply."


def sanitize_model_reply(text: str) -> str:
    cleaned = str(text or "").strip()
    if not cleaned:
        return ""

    lowered = cleaned.lower()
    meta_markers = (
        "acknowledge and respond",
        "i've processed the user's",
        "i have processed the user's",
        "my core approach",
        "i've formulated a response",
        "i have formulated a response",
        "which translates to",
        "this seems a solid approach",
        "i am now assessing",
        "i'm now assessing",
        "i am assessing",
        "i need to clarify",
        "i will need to",
        "i'll need to",
        "i need to determine",
        "i'm focusing on",
        "i am focusing on",
        "to respond appropriately",
        "the feasibility of",
        "clarify the details",
        "what tools or steps are needed",
        "providing khmer response",
    )
    lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
    if lines:
        filtered = []
        for line in lines:
            lowered_line = line.lower()
            if any(marker in lowered_line for marker in meta_markers):
                continue
            if lowered_line.startswith((
                "i am now ",
                "i'm now ",
                "i am assessing",
                "i'm assessing",
                "i need to ",
                "i will need to ",
                "i'll need to ",
                "i am going to ",
                "i'm going to ",
                "i will ",
                "i'm focusing on ",
                "i am focusing on ",
                "to respond appropriately",
            )):
                continue
            filtered.append(line)
        if filtered and len(filtered) != len(lines):
            return "\n".join(filtered).strip()
    if any(marker in lowered for marker in meta_markers):
        targeted_patterns = (
            r"(?:i['’]ve formulated a response|i have formulated a response|response|reply)\s*:\s*[\"“](.+?)[\"”]",
            r"(?:final answer|answer)\s*:\s*[\"“](.+?)[\"”]",
        )
        for pattern in targeted_patterns:
            match = re.search(pattern, cleaned, flags=re.DOTALL | re.IGNORECASE)
            if match:
                candidate = re.sub(r"\s+", " ", match.group(1)).strip()
                candidate_lower = candidate.lower()
                if candidate and not any(marker in candidate_lower for marker in meta_markers):
                    return candidate

        quoted_matches = re.findall(r"[\"“](.+?)[\"”]", cleaned, flags=re.DOTALL)
        for match in quoted_matches:
            candidate = re.sub(r"\s+", " ", match).strip()
            candidate_lower = candidate.lower()
            if (
                candidate
                and not any(marker in candidate_lower for marker in meta_markers)
                and (" " in candidate or contains_khmer_script(candidate) or len(candidate) > 18)
            ):
                return candidate

    if re.search(r"(?is)\b(?:image|video)?\s*prompt(?:\s*\d+)?\b\s*:", cleaned):
        return cleaned
    cleaned = re.sub(r"^\s*\*\*[^*]+\*\*\s*", "", cleaned, count=1, flags=re.DOTALL)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned


def extract_generation_prompt(text: str) -> str:
    source = str(text or "").strip()
    if not source:
        return ""
    prompt_blocks = extract_prompt_blocks(source)
    if prompt_blocks:
        return prompt_blocks[0]
    source = re.sub(r"(?is)\*\*\s*((?:image|video)?\s*prompt\s*:)\s*\*\*", r"\1", source)
    patterns = (
        r'(?is)\*{0,2}(?:image|video)?\s*prompt\*{0,2}\s*:\s*["“](.+?)["”]',
        r"(?is)\*{0,2}(?:image|video)?\s*prompt\*{0,2}\s*:\s*['‘](.+?)['’]",
        r"(?is)\*{0,2}(?:image|video)?\s*prompt\*{0,2}\s*:\s*```(?:[\w-]+)?\s*(.+?)\s*```",
        r"(?is)\*{0,2}(?:image|video)?\s*prompt\*{0,2}\s*:\s*(.+)$",
    )
    for pattern in patterns:
        match = re.search(pattern, source, flags=re.DOTALL)
        if not match:
            continue
        prompt = match.group(1).strip().strip("\"'“”‘’")
        if prompt:
            return prompt
    return source


def extract_prompt_blocks(text: str) -> list[str]:
    source = str(text or "").strip()
    if not source:
        return []
    source = re.sub(r"(?is)\*\*\s*((?:image|video)?\s*prompt(?:\s*\d+)?\s*:)\s*\*\*", r"\1", source)
    patterns = (
        r'(?is)\*{0,2}(?:image|video)?\s*prompt(?:\s*\d+)?\*{0,2}\s*:\s*["“](.+?)["”]',
        r"(?is)\*{0,2}(?:image|video)?\s*prompt(?:\s*\d+)?\*{0,2}\s*:\s*['‘](.+?)['’]",
        r"(?is)\*{0,2}(?:image|video)?\s*prompt(?:\s*\d+)?\*{0,2}\s*:\s*```(?:[\w-]+)?\s*(.+?)\s*```",
        r"(?im)^\s*(?:\d+[.)-]?\s*)?[\"“](.+?)[\"”]\s*$",
        r"(?im)^\s*(?:\d+[.)-]?\s*)['‘](.+?)['’]\s*$",
    )
    results: list[str] = []
    seen: set[str] = set()
    for pattern in patterns:
        for match in re.finditer(pattern, source, flags=re.DOTALL | re.IGNORECASE | re.MULTILINE):
            prompt = re.sub(r"\s+", " ", match.group(1)).strip().strip("\"'“”‘’")
            if prompt and prompt.lower() not in seen:
                seen.add(prompt.lower())
                results.append(prompt)

    for match in re.finditer(r"(?is)```(?:plaintext|text|prompt|[\w+-]+)?\s*(.*?)\s*```", source):
        prompt = re.sub(r"\s+", " ", match.group(1)).strip().strip("\"'“”‘’")
        if prompt and len(prompt) >= 12 and prompt.lower() not in seen:
            seen.add(prompt.lower())
            results.append(prompt)
    return results


def format_prompt_blocks_for_reply(prompts: list[str]) -> str:
    lines: list[str] = []
    for index, prompt in enumerate(prompts, start=1):
        label = f"Prompt {index}"
        lines.append(f"{index}. {label}:")
        lines.append("```plaintext")
        lines.append(prompt)
        lines.append("```")
    return "\n\n".join(lines)


def normalize_prompt_only_reply(text: str, latest_request: str) -> str:
    prompt_count = requested_prompt_count(latest_request)
    prompt_blocks = extract_prompt_blocks(text)
    if not prompt_blocks:
        return text.strip()
    limited = prompt_blocks[: max(1, prompt_count)]
    return format_prompt_blocks_for_reply(limited)


def fallback_generation_prompt(text: str, kind: str) -> str:
    lowered = normalize_generation_command_text(text)
    if lowered.startswith("/image"):
        lowered = lowered[6:].strip()
    elif lowered.startswith("/banana2"):
        lowered = lowered[8:].strip()
    elif lowered.startswith("/bananapro"):
        lowered = lowered[10:].strip()
    elif lowered.startswith("/video"):
        lowered = lowered[6:].strip()
    base_prompt = lowered or f"Create one strong {kind} about the user's request."
    return apply_safe_glamour_style(base_prompt, text, kind)


def formatted_generation_reply(
    messages: list[dict[str, str]],
    kind: str,
    prompt: str,
    model_label: str | None = None,
    *,
    edited: bool = False,
) -> str:
    if edited and kind == "image":
        summary = "Edited image."
    elif edited and kind == "video":
        summary = "Edited video."
    else:
        summary = "Generated image." if kind == "image" else "Generated video."
    if kind == "image" and model_label:
        summary = f"{'Edited' if edited else 'Generated'} image with {model_label}."
    if contains_khmer_script(latest_user_message(messages)):
        if kind == "image" and model_label:
            summary = f"បាន{'កែ' if edited else 'បង្កើត'}រូបភាពដោយ {model_label} រួចហើយ។"
        else:
            if kind == "image":
                summary = "បានកែរូបភាពរួចហើយ។" if edited else "បានបង្កើតរូបភាពរួចហើយ។"
            else:
                summary = "បានកែវីដេអូរួចហើយ។" if edited else "បានបង្កើតវីដេអូរួចហើយ។"
    return f"{summary}\n\n**Prompt:** \"{prompt}\""


def formatted_video_thumbnail_reply(request_text: str, analysis: batch.VideoAssetAnalysis | None, provider: str) -> str:
    provider_label = "Gemini full video scan" if provider == batch.AI_PROVIDER_GEMINI else "OpenAI video analysis"
    if contains_khmer_script(request_text):
        lines = [f"បានបង្កើត thumbnail ពីវីដេអូពិតៗដោយ {provider_label} រួចហើយ។"]
        if analysis is not None:
            if analysis.title:
                lines.append(f"Title: {analysis.title}")
            lines.append(f"Timestamp: {analysis.thumbnail_timestamp:.2f}s")
            if analysis.thumbnail_reason:
                lines.append(f"Reason: {analysis.thumbnail_reason}")
        return "\n\n".join(lines)
    lines = [f"Created a real thumbnail from the attached video using {provider_label}."]
    if analysis is not None:
        if analysis.title:
            lines.append(f"Title: {analysis.title}")
        lines.append(f"Timestamp: {analysis.thumbnail_timestamp:.2f}s")
        if analysis.thumbnail_reason:
            lines.append(f"Reason: {analysis.thumbnail_reason}")
    return "\n\n".join(lines)


def formatted_designed_video_thumbnail_reply(
    request_text: str,
    analysis: batch.VideoAssetAnalysis | None,
    audit: batch.SocialPolicyAudit | None,
    provider: str,
) -> str:
    provider_label = "Gemini smart thumbnail design" if provider == batch.AI_PROVIDER_GEMINI else "OpenAI smart thumbnail design"
    if contains_khmer_script(request_text):
        lines = [f"បានបង្កើត designed thumbnail ពីវីដេអូដោយ {provider_label} រួចហើយ។"]
        if analysis is not None:
            if analysis.title:
                lines.append(f"Title: {analysis.title}")
            lines.append(f"Timestamp: {analysis.thumbnail_timestamp:.2f}s")
            if analysis.thumbnail_reason:
                lines.append(f"Hook reason: {analysis.thumbnail_reason}")
        if audit is not None:
            lines.append(
                f"Policy Check: Facebook Reels = {audit.facebook_reels}, YouTube = {audit.youtube}, TikTok = {audit.tiktok}"
            )
            if audit.viewer_hook:
                lines.append(f"Viewer Hook: {audit.viewer_hook}")
            if audit.issues:
                lines.append("Risk: " + "; ".join(audit.issues))
            if audit.guidance:
                lines.append("Guidance: " + audit.guidance)
            if any(value == "block" for value in (audit.facebook_reels, audit.youtube, audit.tiktok)):
                lines.append("ស្ថានភាព: thumbnail នេះអាចត្រូវបាន block លើ platform ខ្លះៗ។ សូមកែរូបឲ្យសុវត្ថិភាពជាងមុន មុនពេល post។")
            elif any(value == "caution" for value in (audit.facebook_reels, audit.youtube, audit.tiktok)):
                lines.append("ស្ថានភាព: thumbnail នេះអាចមានហានិភ័យ policy ខ្លះៗ។ សូមពិនិត្យ guidance មុនពេល post។")
        else:
            lines.append("Policy Check: មិនអាចពិនិត្យបានពេញលេញទេ ប៉ុន្តែ thumbnail ត្រូវបានបង្កើតរួចហើយ។")
        return "\n\n".join(lines)
    lines = [f"Created a designed thumbnail from the attached video using {provider_label}."]
    if analysis is not None:
        if analysis.title:
            lines.append(f"Title: {analysis.title}")
        lines.append(f"Timestamp: {analysis.thumbnail_timestamp:.2f}s")
        if analysis.thumbnail_reason:
            lines.append(f"Hook reason: {analysis.thumbnail_reason}")
    if audit is not None:
        lines.append(
            f"Policy Check: Facebook Reels = {audit.facebook_reels}, YouTube = {audit.youtube}, TikTok = {audit.tiktok}"
        )
        if audit.viewer_hook:
            lines.append(f"Viewer Hook: {audit.viewer_hook}")
        if audit.issues:
            lines.append("Risk: " + "; ".join(audit.issues))
        if audit.guidance:
            lines.append("Guidance: " + audit.guidance)
        if any(value == "block" for value in (audit.facebook_reels, audit.youtube, audit.tiktok)):
            lines.append("Status: This thumbnail may be blocked on one or more platforms. Adjust the image before posting.")
        elif any(value == "caution" for value in (audit.facebook_reels, audit.youtube, audit.tiktok)):
            lines.append("Status: This thumbnail has some policy risk. Review the guidance before posting.")
    else:
        lines.append("Policy Check: unavailable, but the thumbnail was created successfully.")
    return "\n\n".join(lines)


def build_face_edit_generation_prompt(prompt: str, request_text: str, image_paths: list[Path]) -> str:
    source_name = image_paths[0].name if image_paths else "the first attached image"
    target_name = image_paths[1].name if len(image_paths) > 1 else "the second attached image"
    extra_references = ""
    if len(image_paths) > 2:
        extra_names = ", ".join(path.name for path in image_paths[2:5])
        extra_references = f"Use these additional attached images as extra source-face references when helpful: {extra_names}. "
    if prompt.strip():
        base_prompt = apply_safe_glamour_style(prompt.strip(), request_text, "image")
    else:
        base_prompt = fallback_generation_prompt(request_text, "image")
    return (
        f"{base_prompt}\n\n"
        "This is a face-editing request using attached images. "
        f"Use the first attached image ({source_name}) as the source face identity reference. "
        f"Use the second attached image ({target_name}) as the target/base image to edit. "
        f"{extra_references}"
        "Replace or blend the face according to the user's request while preserving the target scene, pose, framing, body, hands, clothing, background, and lighting unless the user explicitly asks to change them. "
        "Keep the face realistic with accurate identity, natural expression, matching angle, clean edges, skin texture, and believable shadows."
    ).strip()


def build_face_edit_video_generation_prompt(
    prompt: str,
    request_text: str,
    source_image_paths: list[Path],
    target_video_path: Path,
) -> str:
    source_name = source_image_paths[0].name if source_image_paths else "the first attached image"
    extra_references = ""
    if len(source_image_paths) > 1:
        extra_names = ", ".join(path.name for path in source_image_paths[1:4])
        extra_references = f"Use these additional attached images as extra source-face references when helpful: {extra_names}. "
    if prompt.strip():
        base_prompt = apply_safe_glamour_style(prompt.strip(), request_text, "video")
    else:
        base_prompt = fallback_generation_prompt(request_text, "video")
    return (
        f"{base_prompt}\n\n"
        "This is a face-editing request for a target video. "
        f"Use the attached source face image ({source_name}) as the identity reference. "
        f"Use the attached video ({target_video_path.name}) as the target/base video. "
        f"{extra_references}"
        "For every frame, preserve the original target video scene, action, camera movement, timing, body, hands, clothing, background, and lighting unless the user explicitly asks to change them. "
        "Replace or blend the face naturally with stable identity, consistent angle, clean edges, realistic skin texture, and minimal flicker across frames."
    ).strip()


def generate_provider_media(
    provider: str,
    kind: str,
    prompt: str,
    request_text: str,
    image_paths: list[Path] | None = None,
    video_paths: list[Path] | None = None,
) -> tuple[list[dict[str, str]], str | None, str | None]:
    image_paths = image_paths or []
    video_paths = video_paths or []
    face_edit_requested = is_face_edit_request(request_text)
    if kind == "image" and is_video_thumbnail_request(request_text, video_paths):
        target_video_path = video_paths[0]
        requested_image_model = requested_gemini_image_model_override(request_text)
        if provider == batch.AI_PROVIDER_GEMINI:
            requested_image_model = requested_image_model or batch.GEMINI_IMAGE_MODEL_FLASH
        media, analysis, audit = batch.generate_designed_video_thumbnail(
            target_video_path,
            request_text,
            provider,
            preferred_image_model=requested_image_model,
        )
        if provider == batch.AI_PROVIDER_GEMINI:
            model_label = "Gemini 3 Pro Image Preview Thumbnail" if requested_image_model == batch.GEMINI_IMAGE_MODEL_PRO else "Gemini 3.1 Flash Image Preview Thumbnail"
        else:
            model_label = "OpenAI Smart Thumbnail"
        return media, model_label, formatted_designed_video_thumbnail_reply(request_text, analysis, audit, provider)
    if face_edit_requested and kind == "video":
        if not image_paths:
            raise RuntimeError("Attach at least 1 source face image for video face swap.")
        if not video_paths:
            raise RuntimeError("Attach 1 target video for video face swap.")
        target_video_path = video_paths[0]
        edit_prompt = build_face_edit_video_generation_prompt(prompt, request_text, image_paths, target_video_path)
        requested_image_model = requested_gemini_image_model_override(request_text)
        if requested_image_model:
            model_label = "Nano Banana Pro" if requested_image_model == batch.GEMINI_IMAGE_MODEL_PRO else "Nano Banana 2"
            return batch.generate_gemini_video_face_edit(edit_prompt, image_paths, target_video_path, preferred_model=requested_image_model), model_label, None
        if provider == batch.AI_PROVIDER_GEMINI:
            return batch.generate_gemini_video_face_edit(edit_prompt, image_paths, target_video_path), None, None
        return batch.generate_openai_video_face_edit(edit_prompt, image_paths, target_video_path), None, None
    if face_edit_requested and kind == "image":
        if len(image_paths) < 2:
            raise RuntimeError("Attach at least 2 images for face swap. Put the source face first and the target image second.")
        edit_prompt = build_face_edit_generation_prompt(prompt, request_text, image_paths)
        requested_image_model = auto_gemini_image_model(request_text, image_paths)
        if requested_image_model:
            model_label = "Nano Banana Pro" if requested_image_model == batch.GEMINI_IMAGE_MODEL_PRO else "Nano Banana 2"
            return batch.generate_gemini_image_edit(edit_prompt, image_paths, preferred_model=requested_image_model), model_label, None
        if provider == batch.AI_PROVIDER_GEMINI:
            return batch.generate_gemini_image_edit(edit_prompt, image_paths), None, None
        return batch.generate_openai_image_edit(edit_prompt, image_paths), None, None

    requested_image_model = auto_gemini_image_model(request_text, image_paths) if provider == batch.AI_PROVIDER_GEMINI or requested_gemini_image_model_override(request_text) else requested_gemini_image_model_override(request_text)
    if requested_image_model:
        model_label = "Nano Banana Pro" if requested_image_model == batch.GEMINI_IMAGE_MODEL_PRO else "Nano Banana 2"
        return batch.generate_gemini_image(apply_safe_glamour_style(prompt, request_text, "image"), preferred_model=requested_image_model), model_label, None
    if provider == batch.AI_PROVIDER_GEMINI:
        if kind == "video":
            return batch.generate_gemini_video(apply_safe_glamour_style(prompt, request_text, "video")), None, None
        return batch.generate_gemini_image(apply_safe_glamour_style(prompt, request_text, "image")), None, None
    if kind == "video":
        return batch.generate_openai_video(apply_safe_glamour_style(prompt, request_text, "video")), None, None
    return batch.generate_openai_image(apply_safe_glamour_style(prompt, request_text, "image")), None, None


def summarize_attached_videos(video_paths: list[Path]) -> str:
    if not video_paths:
        return ""
    return "\n".join(f"- {path.name}" for path in video_paths)


def summarize_attached_images(image_paths: list[Path]) -> str:
    if not image_paths:
        return ""
    return "\n".join(f"- {path.name}" for path in image_paths)


def image_inline_part(path: Path) -> dict[str, object]:
    return {
        "type": "image",
        "data": base64.b64encode(path.read_bytes()).decode("ascii"),
        "mime_type": batch.guess_media_mime_type(path),
    }


def run_gemini(messages: list[dict[str, str]], image_paths: list[Path], video_paths: list[Path]) -> str:
    api_key = batch.gemini_api_key()
    if not api_key:
        raise RuntimeError("Gemini API key is not set.")

    if not image_paths and not video_paths:
        payload = {
            "contents": [
                {
                    "role": "user",
                    "parts": [
                        {
                            "text": (
                                f"{SYSTEM_PROMPT}\n\n"
                                f"{reply_language_instruction(messages)}\n\n"
                                "Conversation so far:\n"
                                f"{transcript_for_model(messages)}\n\n"
                                "Reply to the last user message."
                            )
                        }
                    ],
                }
            ],
            "generationConfig": {
                "temperature": 0.6,
                "maxOutputTokens": 900,
            },
        }
        response = batch.gemini_generate_content(api_key, payload, model_name=batch.resolve_gemini_model())
        text = sanitize_model_reply(batch.extract_gemini_text(response))
        if not text:
            raise RuntimeError("Gemini returned an empty response.")
        return text.strip()

    uploaded_names: list[str] = []
    try:
        inputs: list[dict[str, object]] = [
            {
                "type": "text",
                    "text": (
                        f"{SYSTEM_PROMPT}\n\n"
                        f"{reply_language_instruction(messages)}\n\n"
                        "Use the attached media files and the chat history together. "
                        "If the latest user request is about the attached media, answer from the real visual and audio content. "
                        "If something is unclear, say that clearly.\n\n"
                    "Attached images:\n"
                    f"{summarize_attached_images(image_paths) if image_paths else '[None]'}\n\n"
                    "Attached videos:\n"
                    f"{summarize_attached_videos(video_paths) if video_paths else '[None]'}\n\n"
                    "Conversation so far:\n"
                    f"{transcript_for_model(messages)}\n\n"
                    "Reply to the last user message."
                ),
            }
        ]
        for image_path in image_paths:
            inputs.append(image_inline_part(image_path))
        for video_path in video_paths:
            file_info = batch.gemini_upload_file(api_key, video_path)
            uploaded_names.append(str(file_info.get("name") or ""))
            file_info = batch.gemini_wait_for_file_active(api_key, file_info)
            print(f"[Gemini] Generating transcript from attached video: {video_path.name}", file=sys.stderr, flush=True)
            transcript = ""
            try:
                transcript = batch.gemini_transcribe_uploaded_video(
                    api_key,
                    file_info,
                    batch.guess_media_mime_type(video_path),
                    model_name=batch.resolve_gemini_model(),
                )
            except Exception as exc:
                issue_message = batch.api_issue_message(batch.AI_PROVIDER_GEMINI, exc)
                if issue_message:
                    raise RuntimeError(issue_message) from exc
                print(
                    f"[Gemini] Transcript unavailable for {video_path.name}; continuing without transcript",
                    file=sys.stderr,
                    flush=True,
                )
                transcript = ""
            inputs.append(
                {
                    "type": "text",
                    "text": (
                        f"Attached video: {video_path.name}\n"
                        f"Transcript: {batch.transcript_prompt_text(transcript)}"
                    ),
                }
            )
            inputs.append(
                {
                    "type": "video",
                    "uri": str(file_info.get("uri") or ""),
                    "mime_type": str(file_info.get("mimeType") or batch.guess_media_mime_type(video_path)),
                }
            )

        response_payload = batch.gemini_create_interaction(
            api_key,
            {
                "model": batch.resolve_gemini_model(),
                "input": inputs,
                "generation_config": {
                    "temperature": 0.6,
                    "thinking_level": "low",
                    "max_output_tokens": 900,
                },
            },
        )
        text = sanitize_model_reply(batch.extract_gemini_interaction_text(response_payload)).strip()
        if not text:
            raise RuntimeError("Gemini returned an empty response.")
        return text
    finally:
        for name in uploaded_names:
            if name:
                batch.gemini_delete_file(api_key, name)


def run_openai(messages: list[dict[str, str]], image_paths: list[Path], video_paths: list[Path]) -> str:
    client = batch.openai_client()
    if client is None:
        raise RuntimeError("OpenAI API key is not set.")

    content: list[dict[str, object]] = [
        {
            "type": "input_text",
            "text": (
                "Conversation so far:\n"
                f"{transcript_for_model(messages)}\n\n"
                "Reply to the last user message."
            ),
        }
    ]

    temp_dirs: list[Path] = []
    try:
        for image_path in image_paths[:10]:
            content.append(
                {
                    "type": "input_text",
                    "text": f"Attached image: {image_path.name}",
                }
            )
            content.append(
                {
                    "type": "input_image",
                    "image_url": batch.image_data_url(image_path),
                    "detail": "low",
                }
            )

        for video_path in video_paths[:2]:
            transcript = ""
            try:
                info = batch.probe_video(video_path)
                if info.has_audio:
                    transcript = batch.transcribe_video_audio(client, video_path)
            except Exception as exc:
                issue_message = batch.api_issue_message(batch.AI_PROVIDER_OPENAI, exc)
                if issue_message:
                    raise RuntimeError(issue_message) from exc
                transcript = ""

            temp_dir, frames = batch.sample_analysis_frames(video_path)
            temp_dirs.append(temp_dir)
            content.append(
                {
                    "type": "input_text",
                    "text": (
                        f"Attached video: {video_path.name}\n"
                        f"Transcript: {batch.transcript_prompt_text(transcript)}"
                    ),
                }
            )
            for frame in frames:
                content.append({"type": "input_text", "text": f"{video_path.name} frame {frame.index} at {frame.timestamp:.2f}s"})
                content.append({"type": "input_image", "image_url": batch.image_data_url(frame.path), "detail": "low"})

        response = client.responses.create(
            model=batch.resolve_openai_model(),
            instructions=SYSTEM_PROMPT,
            input=[
                {
                    "role": "user",
                    "content": content,
                }
            ],
            max_output_tokens=900,
            temperature=0.7,
            store=False,
        )
        text = batch.extract_response_text(response)
        if not text:
            raise RuntimeError("OpenAI returned an empty response.")
        return text.strip()
    finally:
        for temp_dir in temp_dirs:
            for frame in temp_dir.glob("*.jpg"):
                frame.unlink(missing_ok=True)
            temp_dir.rmdir()


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        error("No chat payload received.")
        return 1

    try:
        payload = json.loads(raw)
    except Exception:
        error("Chat payload is not valid JSON.")
        return 1

    messages = normalize_messages(payload.get("messages"))
    if not messages:
        error("No chat messages were provided.")
        return 1
    image_paths = normalize_image_paths(payload.get("image_paths"))
    video_paths = normalize_video_paths(payload.get("video_paths"))

    provider = str(payload.get("provider") or batch.resolve_ai_provider()).strip().lower()
    if provider not in {batch.AI_PROVIDER_GEMINI, batch.AI_PROVIDER_OPENAI}:
        provider = batch.resolve_ai_provider()
    latest_request = latest_user_message(messages)
    prompt_only = wants_prompt_only(latest_request)
    media_kind = requested_generation_kind(latest_request)
    media_provider = generation_provider_for_request(provider, latest_request)
    face_edit_requested = is_face_edit_request(latest_request)
    direct_generation = should_generate_media_directly(
        latest_request,
        media_kind,
        prompt_only,
        image_paths,
        video_paths,
    )

    if direct_generation and media_kind:
        try:
            prompt_text = fallback_generation_prompt(latest_request, media_kind)
            media, model_label, custom_text = generate_provider_media(media_provider, media_kind, prompt_text, latest_request, image_paths=image_paths, video_paths=video_paths)
            text = custom_text or formatted_generation_reply(messages, media_kind, prompt_text, model_label=model_label, edited=face_edit_requested and media_kind in {"image", "video"})
        except Exception as exc:
            error(batch.describe_provider_error(media_provider, exc))
            return 1
        print(json.dumps({"ok": True, "provider": media_provider, "text": text, "media": media}, ensure_ascii=False))
        return 0

    try:
        if provider == batch.AI_PROVIDER_GEMINI:
            text = run_gemini(messages, image_paths, video_paths)
        else:
            text = run_openai(messages, image_paths, video_paths)
    except Exception as exc:
        error(batch.describe_provider_error(provider, exc))
        return 1

    if prompt_only:
        text = normalize_prompt_only_reply(text, latest_request)

    media: list[dict[str, str]] = []
    if media_kind and not prompt_only:
        try:
            prompt_text = extract_generation_prompt(text)
            if not prompt_text:
                prompt_text = fallback_generation_prompt(latest_request, media_kind)
            else:
                prompt_text = apply_safe_glamour_style(prompt_text, latest_request, media_kind)
            media, model_label, custom_text = generate_provider_media(media_provider, media_kind, prompt_text, latest_request, image_paths=image_paths, video_paths=video_paths)
            text = custom_text or formatted_generation_reply(messages, media_kind, prompt_text, model_label=model_label, edited=face_edit_requested and media_kind in {"image", "video"})
        except Exception as exc:
            error(batch.describe_provider_error(media_provider, exc))
            return 1

    print(json.dumps({"ok": True, "provider": media_provider if media else provider, "text": text, "media": media}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
