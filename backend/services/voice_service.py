"""
ZITLAS — Voice service (backend/services/voice_service.py)

VOICE ONLY. This module synthesizes speech and transcribes audio; it contains
no conversational intelligence whatsoever.

Zino's brain stays exactly where it already is — groq_service (Groq → Gemini →
OpenRouter), the RAG layer, the food/workout engines, and the assessment
pipeline. ElevenLabs is a speaker, not a mind: routes/voice.py calls the SAME
`groq_service.chat(system_override=ZINO_COMPANION_SYSTEM)` the text chat uses,
then hands the resulting sentence to `synthesize()` here. Nothing about what
Zino knows or decides moves to a voice vendor, and ElevenLabs Agents are
deliberately NOT used.

SECRETS: `ELEVENLABS_API_KEY` is read from the environment here and never
leaves the backend. The mobile app talks only to this server.
"""

from __future__ import annotations

import os
from typing import Any

import requests

# ── Configuration (env-overridable — never hardcode the voice through the
# codebase, so switching Zino's voice is a deployment change, not a patch) ────

_ELEVEN_BASE = "https://api.elevenlabs.io/v1"

# Zino's permanent voice. Overridable via ELEVENLABS_VOICE_ID.
DEFAULT_VOICE_ID = os.getenv("ELEVENLABS_VOICE_ID", "SGbOfpm28edC83pZ9iGb")

# multilingual_v2 is required, not preferred: English/Hindi/Hinglish are all
# supported voices for ZITLAS, and the monolingual models mangle Devanagari
# and Roman-script Hindi alike.
DEFAULT_TTS_MODEL = os.getenv("ELEVENLABS_MODEL_ID", "eleven_multilingual_v2")

# Groq hosts Whisper, and GROQ_API_KEY is already configured for the LLM path —
# no new vendor, no new secret, and it handles Hindi + code-switched Hinglish
# far better than a monolingual recognizer.
DEFAULT_STT_MODEL = os.getenv("GROQ_STT_MODEL", "whisper-large-v3-turbo")
_GROQ_TRANSCRIBE_URL = "https://api.groq.com/openai/v1/audio/transcriptions"

_TTS_TIMEOUT = 45
_STT_TIMEOUT = 45

# ── Languages ────────────────────────────────────────────────────────────────

# Whisper wants an ISO-639-1 hint. Hinglish is code-switched Hindi/English with
# no ISO code of its own; hinting "hi" makes Whisper transcribe the Hindi words
# correctly while still passing English words through, which is exactly the
# transcript a Hinglish speaker expects to see.
_STT_LANGUAGE_HINT = {
    "english": "en",
    "hindi": "hi",
    "hinglish": "hi",
}

SUPPORTED_LANGUAGES = ("english", "hindi", "hinglish")


def normalize_language(value: str | None) -> str:
    """Any unknown/missing value falls back to Hinglish — the recommended
    default for ZITLAS's audience, and the safest for a mixed-vocabulary
    fitness conversation ('protein', 'reps' and 'सुबह' in one sentence)."""
    lang = (value or "").strip().lower()
    return lang if lang in SUPPORTED_LANGUAGES else "hinglish"


def language_instruction(language: str) -> str:
    """A prompt fragment appended to Zino's EXISTING system persona.

    Deliberately additive: the text-chat endpoint and its prompt are left
    untouched, so this cannot change how the website or the app's text Zino
    behaves. It only tells the same persona which language to answer in when
    the athlete is speaking rather than typing.
    """
    return {
        "english": (
            "\n\nSPEAK ENGLISH: reply in natural, simple English."
        ),
        "hindi": (
            "\n\nSPEAK HINDI: reply in natural conversational Hindi using "
            "Devanagari script. Keep common English fitness words (protein, "
            "reps, sets, calories) as-is — that's how people actually speak."
        ),
        "hinglish": (
            "\n\nSPEAK HINGLISH: reply in natural Hinglish — conversational "
            "Hindi written in ROMAN script, mixed with English the way Indian "
            "users actually talk (e.g. \"Bhai aaj ka workout easy hai, bas "
            "20 minute\"). Never use Devanagari script."
        ),
    }[language]


def voice_output_hint() -> str:
    """Extra guidance for text that will be SPOKEN rather than read.

    Spoken replies have different constraints from chat bubbles: emoji and
    markdown are read aloud as noise by a TTS engine, and long paragraphs are
    exhausting to listen to with no way to skim.
    """
    return (
        "\n\nYOU ARE BEING SPOKEN ALOUD:\n"
        "- Keep it SHORT — 1-3 sentences. The user is listening, not reading.\n"
        "- NO emoji, NO markdown, NO bullet points, NO numbered lists — a "
        "speech engine reads those out as literal noise.\n"
        "- Write numbers the way you'd say them ('six thousand eight hundred' "
        "reads better than '6,840' in some engines, but plain digits are fine "
        "for small numbers).\n"
        "- Sound like a friend on a phone call, not like a document."
    )


# ── Text-to-Speech ───────────────────────────────────────────────────────────


class VoiceUnavailable(RuntimeError):
    """Raised when speech can't be produced. Callers degrade to text rather
    than failing the whole conversation."""


def _api_key() -> str:
    key = os.getenv("ELEVENLABS_API_KEY")
    if not key:
        raise VoiceUnavailable("ELEVENLABS_API_KEY is not configured")
    return key


def synthesize(
    text: str,
    voice_id: str | None = None,
    model_id: str | None = None,
) -> bytes:
    """Text -> MP3 bytes via ElevenLabs.

    Blocking (uses `requests`, matching the rest of this codebase); the route
    wraps it in `asyncio.to_thread` so the event loop is never held.
    """
    clean = (text or "").strip()
    if not clean:
        raise VoiceUnavailable("nothing to speak")

    voice = voice_id or DEFAULT_VOICE_ID
    url = f"{_ELEVEN_BASE}/text-to-speech/{voice}"
    try:
        res = requests.post(
            url,
            headers={
                "xi-api-key": _api_key(),
                "Content-Type": "application/json",
                "Accept": "audio/mpeg",
            },
            json={
                "text": clean,
                "model_id": model_id or DEFAULT_TTS_MODEL,
                "voice_settings": {
                    # Tuned for a companion rather than a narrator: enough
                    # stability to stay recognisably Zino across a call,
                    # enough style/similarity to keep warmth instead of a
                    # flat corporate read.
                    "stability": 0.45,
                    "similarity_boost": 0.75,
                    "style": 0.35,
                    "use_speaker_boost": True,
                },
            },
            timeout=_TTS_TIMEOUT,
        )
    except requests.RequestException as e:
        raise VoiceUnavailable(f"ElevenLabs unreachable: {type(e).__name__}") from e

    if res.status_code != 200:
        # The body can contain quota/permission detail worth logging, but it
        # is never returned to the client verbatim.
        detail = res.text[:300] if res.text else "(empty)"
        print(f"[VOICE] ElevenLabs TTS failed {res.status_code}: {detail}")
        raise VoiceUnavailable(f"ElevenLabs returned {res.status_code}")

    if not res.content:
        raise VoiceUnavailable("ElevenLabs returned empty audio")
    return res.content


# ── Speech-to-Text ───────────────────────────────────────────────────────────


def transcribe(
    audio_bytes: bytes,
    filename: str = "speech.m4a",
    language: str = "hinglish",
    model: str | None = None,
) -> dict[str, Any]:
    """Audio -> transcript via Groq-hosted Whisper.

    Returns `{"text": ..., "language": ...}`. An empty transcript is a valid
    result (silence / no speech detected), NOT an error — the caller decides
    whether to prompt the athlete to try again.
    """
    if not audio_bytes:
        raise VoiceUnavailable("no audio received")

    key = os.getenv("GROQ_API_KEY")
    if not key:
        raise VoiceUnavailable("GROQ_API_KEY is not configured")

    lang = normalize_language(language)
    try:
        res = requests.post(
            _GROQ_TRANSCRIBE_URL,
            headers={"Authorization": f"Bearer {key}"},
            files={"file": (filename, audio_bytes)},
            data={
                "model": model or DEFAULT_STT_MODEL,
                "language": _STT_LANGUAGE_HINT[lang],
                "response_format": "json",
                # Nudges Whisper toward fitness vocabulary it would otherwise
                # mis-hear ("reps" as "raps", "ghee" as "gee").
                "prompt": "Fitness and nutrition conversation. Terms: reps, sets, "
                          "protein, calories, roti, dal, ghee, paneer, workout, cardio.",
            },
            timeout=_STT_TIMEOUT,
        )
    except requests.RequestException as e:
        raise VoiceUnavailable(f"Speech recognition unreachable: {type(e).__name__}") from e

    if res.status_code != 200:
        print(f"[VOICE] STT failed {res.status_code}: {res.text[:300]}")
        raise VoiceUnavailable(f"Speech recognition returned {res.status_code}")

    try:
        payload = res.json()
    except ValueError as e:
        raise VoiceUnavailable("Speech recognition returned a malformed response") from e

    return {"text": (payload.get("text") or "").strip(), "language": lang}


def is_configured() -> bool:
    """Whether speech synthesis can work at all — surfaced on a health route so
    a misconfigured deployment is visible without reading logs."""
    return bool(os.getenv("ELEVENLABS_API_KEY"))
