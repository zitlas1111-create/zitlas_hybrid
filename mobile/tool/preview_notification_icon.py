"""
Renders ic_stat_zitlas.xml the way Android will
(mobile/tool/preview_notification_icon.py)

A notification small icon is not previewable in the IDE the way it actually
ships: Android throws away the colour and keeps only the ALPHA channel, then
re-fills it with the system tint (white on a dark shade, dark grey on a light
one). An icon can therefore look perfect in a design tool and render as a solid
blob on a phone.

This parses the polygon straight out of the vector drawable — not a copy of it,
so the preview cannot drift from what ships — and renders it the way the system
will, at the sizes that matter:

    24dp  the drawable's own size
    18dp  roughly what the status bar downscales it to
    16dp  worst realistic case on a dense small screen

Two strips are produced: white-on-dark (shade / lock screen) and
dark-on-light (some OEM light themes), so both tints get checked.

    python tool/preview_notification_icon.py

Needs Pillow. Skips cleanly with a message if it is not installed — this is a
convenience for eyeballing the icon, never part of the build.
"""

from __future__ import annotations

import os
import re
import sys

DRAWABLE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "android", "app", "src", "main", "res", "drawable", "ic_stat_zitlas.xml",
)
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "build", "notification_icon_preview.png",
)


def parse_polygon(path: str) -> tuple[list[tuple[float, float]], float]:
    """Pulls the pathData polygon and the viewport size out of the drawable."""
    xml = open(path, encoding="utf-8").read()

    vp = re.search(r'viewportWidth="([\d.]+)"', xml)
    viewport = float(vp.group(1)) if vp else 24.0

    m = re.search(r'android:pathData="([^"]+)"', xml)
    if not m:
        raise SystemExit("no pathData in the drawable")
    data = " ".join(m.group(1).split())

    # Only M / L / Z are used here, deliberately — see the drawable's comment.
    unsupported = set(re.findall(r"[A-Za-z]", data)) - set("MLZmlz")
    if unsupported:
        raise SystemExit(
            f"this previewer only understands M/L/Z, found {unsupported}. "
            "If the icon gained curves, render it with a real SVG tool.")

    points: list[tuple[float, float]] = []
    for x, y in re.findall(r"(-?[\d.]+)\s*,\s*(-?[\d.]+)", data):
        points.append((float(x), float(y)))
    return points, viewport


def main() -> None:
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("Pillow is not installed — skipping the preview.")
        print("  pip install Pillow")
        return

    points, viewport = parse_polygon(DRAWABLE)
    print(f"parsed {len(points)} points from a {viewport:.0f}x{viewport:.0f} viewport")

    sizes = [24, 18, 16]
    scale = 8            # render big, downsample — this is what antialiases it
    pad = 12
    strips = []

    for bg, fg, label in ((( 28,  28,  30), (255, 255, 255), "shade / lock screen"),
                          ((245, 245, 247), ( 60,  60,  62), "light theme")):
        width = sum(s * scale + pad for s in sizes) + pad
        height = max(sizes) * scale + pad * 2
        strip = Image.new("RGB", (width, height), bg)
        x = pad
        for s in sizes:
            box = s * scale
            # Alpha-only, exactly like the silhouette pass.
            mask = Image.new("L", (box, box), 0)
            d = ImageDraw.Draw(mask)
            d.polygon([(px / viewport * box, py / viewport * box)
                       for px, py in points], fill=255)
            tinted = Image.new("RGB", (box, box), fg)
            strip.paste(tinted, (x, pad), mask)
            x += box + pad
        strips.append((strip, label))
        print(f"  rendered {label}: {', '.join(f'{s}dp' for s in sizes)}")

    total_h = sum(s.height for s, _ in strips)
    sheet = Image.new("RGB", (strips[0][0].width, total_h))
    y = 0
    for strip, _ in strips:
        sheet.paste(strip, (0, y))
        y += strip.height

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    sheet.save(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    sys.exit(main())
