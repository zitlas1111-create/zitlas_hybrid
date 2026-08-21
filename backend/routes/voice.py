"""
ZITLAS — Voice routes (backend/routes/voice.py)

Three endpoints, all of which keep the ElevenLabs/Groq credentials on the
server. The mobile app never sees an API key.

  POST /api/voice/tts    text  -> spoken audio (mp3)
  POST /api/voice/stt    audio -> transcript
  POST /api/voice/chat   text  -> Zino's reply + spoken audio, one round trip

PHASE 1 SCOPE: voice plumbing only. `/chat` routes through the EXISTING
`groq_service.chat(system_override=ZINO_COMPANION_SYSTEM)` — the same brain the
text chat uses — and adds nothing but a language/spoken-output instruction. No
assessment, goal, diet, or workout generation is triggered from here; that is
Phase 2.

The existing `/api/ai/zino-chat` endpoint is untouched, so the website and the
app's text Zino behave exactly as before.
"""

from __future__ import annotations

import asyncio
import base64
from typing import Any

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, Field

from services import groq_service, voice_service

router = APIRouter()

# Guards against a runaway request billing a full ElevenLabs quota on one call.
_MAX_TTS_CHARS = 1200
_MAX_AUDIO_BYTES = 25 * 1024 * 1024  # 25 MB — well beyond any sane utterance


class TtsRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=_MAX_TTS_CHARS)
    language: str = Field(default="hinglish")


class VoiceChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=2000)
    language: str = Field(default="hinglish")
    context: dict = Field(default_factory=dict, description="User snapshot — same shape as /api/ai/zino-chat")
    history: list[dict] = Field(default_factory=list, description="[{role:'user'|'zino', text}]")


@router.get("/health")
async def voice_health() -> dict[str, Any]:
    """Lets a deployment confirm voice is wired up without reading logs.
    Reports only whether a key EXISTS — never any part of its value."""
    return {
        "module": "voice",
        "tts_configured": voice_service.is_configured(),
        "voice_id": voice_service.DEFAULT_VOICE_ID,
        "tts_model": voice_service.DEFAULT_TTS_MODEL,
        "stt_model": voice_service.DEFAULT_STT_MODEL,
        "languages": list(voice_service.SUPPORTED_LANGUAGES),
    }


@router.post("/tts")
async def text_to_speech(body: TtsRequest) -> Response:
    """Speak arbitrary text in Zino's voice. Returns raw `audio/mpeg`.

    Used for replaying a line the athlete already received, so a replay costs
    one synthesis rather than a whole new conversational turn.
    """
    try:
        audio = await asyncio.to_thread(voice_service.synthesize, body.text)
    except voice_service.VoiceUnavailable as e:
        # 503: the text answer is fine, the voice layer specifically is down.
        raise HTTPException(status_code=503, detail=str(e))

    return Response(
        content=audio,
        media_type="audio/mpeg",
        headers={"Cache-Control": "no-store"},
    )


@router.post("/stt")
async def speech_to_text(
    audio: UploadFile = File(...),
    language: str = Form(default="hinglish"),
) -> dict[str, Any]:
    """Transcribe a recorded utterance.

    An empty transcript is returned as a normal 200 with `text: ""` — silence
    is a real outcome of holding a mic button, not a server error.
    """
    raw = await audio.read()
    if len(raw) > _MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="Audio clip is too large")

    try:
        result = await asyncio.to_thread(
            voice_service.transcribe,
            raw,
            audio.filename or "speech.m4a",
            language,
        )
    except voice_service.VoiceUnavailable as e:
        raise HTTPException(status_code=503, detail=str(e))

    print(f"[VOICE STT] {len(raw)} bytes -> {result['text'][:120]!r}")
    return {"module": "voice_stt", **result}


@router.post("/chat")
async def voice_chat(body: VoiceChatRequest) -> dict[str, Any]:
    """One conversational turn, spoken.

    Returns the reply TEXT plus base64 audio in a single response. Two separate
    calls (chat, then TTS) would serialize two network round trips into the
    athlete's perceived latency; bundling them halves the wait on a live call.

    GRACEFUL DEGRADATION: if synthesis fails, `audio_base64` is null but
    `reply` is still returned and `voice_available` is false. A voice outage
    must never cost the athlete their answer — the app falls back to showing
    the text.
    """
    language = voice_service.normalize_language(body.language)

    # Zino's REAL brain — the same persona, provider chain and grounding rules
    # as the text chat. Voice only appends how to speak, never what to think.
    system = (
        groq_service.ZINO_COMPANION_SYSTEM
        + voice_service.language_instruction(language)
        + voice_service.voice_output_hint()
    )

    history_lines = []
    for h in body.history[-16:]:
        role = "User" if h.get("role") == "user" else "Zino"
        text = str(h.get("text", ""))[:400]
        if text:
            history_lines.append(f"{role}: {text}")
    history_block = ("RECENT CONVERSATION:\n" + "\n".join(history_lines) + "\n\n") if history_lines else ""

    import json as _json
    ctx_str = _json.dumps(body.context, indent=2, default=str) if body.context else "No profile data synced yet."
    user_message = (
        f"USER CONTEXT:\n{ctx_str}\n\n"
        f"{history_block}"
        f"User says: {body.message}"
    )

    print(f"[VOICE CHAT] lang={language} message={body.message[:120]!r}")

    try:
        result = await groq_service.chat(
            user_message=user_message,
            system_override=system,
            temperature=0.8,
            # Deliberately tighter than the text endpoint's 400: a spoken reply
            # that runs long is painful to sit through, and it costs real
            # synthesis quota per character.
            max_tokens=220,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Zino is having trouble connecting: {e}")

    reply = groq_service.unwrap_conversational_reply(result["reply"])

    audio_b64: str | None = None
    voice_error: str | None = None
    try:
        audio = await asyncio.to_thread(voice_service.synthesize, reply)
        audio_b64 = base64.b64encode(audio).decode("ascii")
    except voice_service.VoiceUnavailable as e:
        voice_error = str(e)
        print(f"[VOICE CHAT] synthesis unavailable, returning text only: {e}")

    return {
        "module": "voice_chat",
        "reply": reply,
        "language": language,
        "audio_base64": audio_b64,
        "audio_mime": "audio/mpeg",
        "voice_available": audio_b64 is not None,
        "voice_error": voice_error,
        "model": result["model"],
        "tokens_used": result["tokens_used"],
    }
