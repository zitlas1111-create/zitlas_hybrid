"""
Generates the ZITLAS notification tone
(mobile/tool/generate_notification_sound.py)

The sound is SYNTHESISED rather than checked in as an opaque binary so it can
be reviewed, tuned and regenerated like any other source. Run it to rebuild:

    python tool/generate_notification_sound.py

Output: android/app/src/main/res/raw/zitlas_tone.wav

WHY THESE CHOICES
-----------------
* An A-major triad (A5 -> C#5 -> E6) rising. A major arpeggio reads as
  "something good happened" without a melody anyone has to learn, and rising
  beats falling for an event the user is meant to act on.
* ~640 ms total. Android truncates nothing, but a notification sound that
  outlasts the glance it interrupts is the thing users mute first.
* Sine fundamental + a quiet second harmonic. A pure sine sounds thin on a
  phone speaker, whose response falls off hard below ~500 Hz; the octave gives
  it body without the buzz a sawtooth would add.
* Exponential decay per note, notes overlapping slightly, so it rings like a
  struck bar rather than three beeps.
* Peak normalised to -3 dBFS with a hard 4 ms fade at both ends. A waveform
  that starts or ends on a non-zero sample CLICKS, and the click is the part
  people notice.

WHY 16-BIT PCM WAV AND NOT MP3/OGG
----------------------------------
res/raw takes any of them, but WAV needs no encoder — this script depends on
nothing outside the standard library, so it still runs years from now. 640 ms
of 44.1 kHz mono is ~56 KB, which is not worth an encoder dependency to shrink.

CAUTION: Android caches a channel's SOUND at channel-creation time, exactly
like its importance. Changing this file does NOT change the sound on any
device that already has the channel — that needs a new channel id. See
FcmService._channels, where the ids carry a version suffix for this reason.
"""

from __future__ import annotations

import math
import os
import struct
import wave

SAMPLE_RATE = 44100
BIT_DEPTH = 16
PEAK = 0.707  # -3 dBFS, leaving room so no device's mixer clips it

#: (frequency Hz, start seconds, duration seconds). A5, C#6, E6 — A major.
NOTES = [
    (880.00, 0.00, 0.30),
    (1108.73, 0.13, 0.30),
    (1318.51, 0.26, 0.38),
]

HARMONIC_LEVEL = 0.28  # the octave above, relative to the fundamental
DECAY = 9.0            # e-folding rate; higher = shorter, more percussive
FADE_SECONDS = 0.004   # anti-click ramp at both ends

OUT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "android", "app", "src", "main", "res", "raw", "zitlas_tone.wav",
)


def render() -> list[float]:
    """Sums the notes into one float buffer in [-1, 1]."""
    total = max(start + dur for _f, start, dur in NOTES)
    frames = int(total * SAMPLE_RATE)
    buf = [0.0] * frames

    for freq, start, dur in NOTES:
        first = int(start * SAMPLE_RATE)
        count = int(dur * SAMPLE_RATE)
        for i in range(count):
            if first + i >= frames:
                break
            t = i / SAMPLE_RATE
            # Struck-bar envelope: instant attack, exponential decay.
            env = math.exp(-DECAY * t)
            angle = 2.0 * math.pi * freq * t
            sample = math.sin(angle) + HARMONIC_LEVEL * math.sin(2.0 * angle)
            buf[first + i] += env * sample

    # Normalise AFTER summing — the notes overlap, so the true peak is not
    # knowable per-note.
    loudest = max(abs(s) for s in buf) or 1.0
    buf = [s / loudest * PEAK for s in buf]

    # Anti-click ramps.
    fade = int(FADE_SECONDS * SAMPLE_RATE)
    for i in range(fade):
        g = i / fade
        buf[i] *= g
        buf[-(i + 1)] *= g
    return buf


def write_wav(buf: list[float], path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(BIT_DEPTH // 8)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(b"".join(
            struct.pack("<h", max(-32768, min(32767, int(s * 32767))))
            for s in buf
        ))


def main() -> None:
    buf = render()
    write_wav(buf, OUT_PATH)

    # Read it back. A malformed sound file does not error at channel creation
    # — Android just makes the channel SILENT, permanently, and the only way
    # out is another channel id. Verifying here is far cheaper than that.
    with wave.open(OUT_PATH, "rb") as w:
        assert w.getnchannels() == 1, w.getnchannels()
        assert w.getsampwidth() == BIT_DEPTH // 8, w.getsampwidth()
        assert w.getframerate() == SAMPLE_RATE, w.getframerate()
        frames = w.getnframes()
    seconds = frames / SAMPLE_RATE
    assert 0.3 < seconds < 1.5, f"implausible duration: {seconds}s"

    print(f"wrote {OUT_PATH}")
    print(f"  {seconds:.3f}s, {SAMPLE_RATE} Hz, mono, {BIT_DEPTH}-bit, "
          f"{os.path.getsize(OUT_PATH) / 1024:.1f} KB")


if __name__ == "__main__":
    main()
