"""
ZITLAS — Personal Coaching Program artwork on the website
(backend/tests/test_program_artwork.py)

The website's program cards ask for /assets/images/programs/<name>.png. The
website never had a committed copy of those files, so the live Programs page
showed a broken image. They are now served from the app's own tracked banners
(mobile/assets/images) — one copy of each image, shared by both clients.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parent.parent))

import main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
BANNERS = {
    "10-day-program.png": "10 program.png",
    "1-month-program.png": "1 month program.png",
    "3-month-program.png": "3 month.png",
}


@pytest.fixture(scope="module")
def client():
    # Not entered as a context manager: no lifespan, no schedulers.
    return TestClient(main.app)


@pytest.mark.parametrize("name,source", BANNERS.items())
def test_each_program_banner_is_the_apps_tracked_file(client, name, source):
    r = client.get(f"/assets/images/programs/{name}")
    assert r.status_code == 200
    assert r.headers["content-type"] == "image/png"
    assert r.content == (ROOT / "mobile" / "assets" / "images" / source).read_bytes()


@pytest.mark.parametrize("name", ["nope.png", "10 program.png", "logo.png", "main.py"])
def test_nothing_else_is_served_from_there(client, name):
    assert client.get(f"/assets/images/programs/{name}").status_code == 404


def test_the_website_asks_for_exactly_these_files():
    flow = (ROOT / "frontend" / "website" / "assets" / "js" / "coaching-programs-flow.js").read_text(encoding="utf-8")
    assert sorted(re.findall(r"/assets/images/programs/([\w.-]+)", flow)) == sorted(BANNERS)


def test_the_app_uses_the_same_banners():
    dart = (ROOT / "mobile" / "lib" / "features" / "coaching_programs" / "coaching_programs.dart").read_text(encoding="utf-8")
    for source in BANNERS.values():
        assert f"'assets/images/{source}'" in dart
