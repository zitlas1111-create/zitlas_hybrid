"""
ZITLAS — what the Railway production image contains
(backend/tests/test_production_image.py)

The Railway image grew to ~3 GB. `COPY . .` sent the whole monorepo as the
build context, and the default PyPI torch (a dependency of
sentence-transformers) is the CUDA build, which brings NVIDIA libraries. The
root .dockerignore is now default-deny and the Dockerfile copies only what the
backend reads at runtime.

These tests take the runtime paths from the code that reads them, so a path
the backend needs can never be excluded silently, and secrets, tests, Flutter
build output and the OLD food dataset can never be shipped.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

import main  # noqa: E402
from services import food_engine, groq_service, offline_fallback, workout_engine  # noqa: E402
from services import workout_nutrition_service  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DOCKERIGNORE = (ROOT / ".dockerignore").read_text(encoding="utf-8")
DOCKERFILE = (ROOT / "Dockerfile").read_text(encoding="utf-8")
RAILWAY = json.loads((ROOT / "railway.json").read_text(encoding="utf-8"))


def _rules() -> list[str]:
    return [line.strip() for line in DOCKERIGNORE.splitlines()
            if line.strip() and not line.strip().startswith("#")]


def _pattern(p: str) -> re.Pattern:
    out, i = "", 0
    while i < len(p):
        if p.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif p.startswith("**", i):
            out, i = out + ".*", i + 2
        else:
            out += {"*": "[^/]*", "?": "[^/]"}.get(p[i], re.escape(p[i]))
            i += 1
    return re.compile(out + r"\Z")


def in_context(rel: str) -> bool:
    """Docker's .dockerignore rules as used here: patterns are anchored at the
    context root, a pattern that matches a parent directory matches everything
    under it, and the LAST matching rule wins (`!` re-includes)."""
    parts = rel.replace("\\", "/").split("/")
    candidates = ["/".join(parts[:i]) for i in range(1, len(parts) + 1)]
    keep = True
    for rule in _rules():
        negate = rule.startswith("!")
        pat = _pattern((rule[1:] if negate else rule).rstrip("/"))
        if any(pat.match(c) for c in candidates):
            keep = negate
    return keep


def _rel(path: Path) -> str:
    return path.resolve().relative_to(ROOT).as_posix()


def _first_file(directory: Path) -> Path:
    return next(p for p in sorted(directory.rglob("*")) if p.is_file() and "__pycache__" not in p.parts)


def _runtime_files() -> list[str]:
    """One real file for every path the backend reads outside its own code."""
    files = [
        main.FRONTEND_DIR / "pages" / "login" / "login.html",
        food_engine._DATASET_PATH,
        _first_file(food_engine._PROFILES_DIR),
        workout_engine._KB_PATH,
        workout_nutrition_service.DATASET_PATH,
        _first_file(groq_service.DATA_DIR),
        _first_file(offline_fallback._DATA_DIR),
        _first_file(main.BASE_DIR / "vector_store"),
        *[main._PROGRAM_ART_DIR / source for source in main._PROGRAM_ART.values()],
    ]
    return [_rel(f) for f in files]


@pytest.mark.parametrize("rel", _runtime_files())
def test_every_runtime_file_is_in_the_build_context(rel):
    assert (ROOT / rel).is_file(), f"{rel} does not exist"
    assert in_context(rel), f"{rel} is read at runtime but .dockerignore excludes it"


@pytest.mark.parametrize("rel", ["backend/main.py", "backend/services/food_engine.py",
                                 "backend/routes/coaching_programs.py", "backend/requirements.txt",
                                 "requirements.txt", "Dockerfile"])
def test_the_app_and_its_requirements_are_in_the_build_context(rel):
    assert in_context(rel)


def test_the_dockerfile_copies_every_runtime_path():
    for copied in ("COPY backend/ ./backend/", "COPY frontend/website/ ./frontend/website/",
                   "COPY food_profiles/ ./food_profiles/",
                   f"COPY food_dataset/{food_engine._DATASET_PATH.name} ./food_dataset/"):
        assert copied in DOCKERFILE, copied
    for source in main._PROGRAM_ART.values():
        assert f'"mobile/assets/images/{source}"' in DOCKERFILE, source


def test_only_the_new_food_dataset_is_shipped_and_the_old_one_stays_refused():
    assert food_engine._DATASET_PATH.name == "zitlas_food_database_enriched_canonical.json"
    old = _rel(food_engine._FROZEN_OLD_DATASET)
    assert not in_context(old)
    assert food_engine._FROZEN_OLD_DATASET.name not in DOCKERFILE
    # Refused by path — even in an image where the file is absent.
    with pytest.raises(food_engine.FoodDatasetError, match="frozen OLD"):
        food_engine.load_food_dataset(food_engine._FROZEN_OLD_DATASET)
    others = [p for p in (ROOT / "food_dataset").iterdir()
              if p.is_file() and p.name != food_engine._DATASET_PATH.name]
    assert others and not [p.name for p in others if in_context(_rel(p))]


@pytest.mark.parametrize("rel", [
    "backend/.env",
    "backend/zitlas-b8677-firebase-adminsdk-fbsvc-0000000000.json",
    "backend/serviceAccountKey.json",
    "backend/tests/test_swap_engine.py",
    "backend/services/__pycache__/food_engine.cpython-314.pyc",
    "backend/uploads/chat/photo.jpg",
    ".git/HEAD",
    ".claude/settings.json",
    "mobile/build/app/outputs/flutter-apk/app-release.apk",
    "mobile/build/app/outputs/bundle/release/app-release.aab",
    "mobile/.dart_tool/package_config.json",
    "mobile/android/.gradle/8.0/checksums.bin",
    "mobile/android/build/reports/x.html",
    "mobile/ios/Pods/Manifest.lock",
    "mobile/ios/.symlinks/plugins/x",
    "mobile/lib/main.dart",
    "mobile/assets/images/logo.png",
    "tests/js/coaching-programs-web.test.mjs",
    "tests/firestore-rules/node_modules/x/index.js",
    "zitlas_test/anything.py",
    "docs/architecture.md",
    "food_dataset/build/expand_v5.py",
    "frontend/website/assets/images/programs/10-day-program.png",
    "frontend/website/node_modules/x/index.js",
])
def test_secrets_tests_and_build_output_are_never_shipped(rel):
    assert not in_context(rel), f"{rel} would be sent to the builder"


def test_pytorch_is_the_cpu_build_and_installed_before_the_requirements():
    cpu = DOCKERFILE.index("pip install torch --index-url https://download.pytorch.org/whl/cpu")
    reqs = DOCKERFILE.index("pip install -r backend/requirements.txt -c /tmp/torch-cpu.txt")
    assert cpu < reqs, "CPU torch first; the requirements are installed with it pinned"
    guard = DOCKERFILE.index("torch.version.cuda")
    assert reqs < guard, "the build fails if a CUDA torch or an NVIDIA/triton package got in"
    for name in ("'nvidia-'", "'triton'", "'cuda-'"):
        assert name in DOCKERFILE[guard - 400:guard + 400], name


def test_no_requirements_file_asks_for_torch_itself():
    """torch comes ONLY from the CPU index in the Dockerfile — a torch line in a
    requirements file would be the way a CUDA build slips back in."""
    for name in ("backend/requirements.txt", "requirements.txt"):
        lines = [l.strip().lower() for l in (ROOT / name).read_text(encoding="utf-8").splitlines()]
        assert not [l for l in lines if re.match(r"(torch|nvidia|triton)\b", l)], name


def test_the_railway_start_command_is_unchanged():
    assert 'cd backend && exec uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}' in DOCKERFILE
    start = RAILWAY["deploy"]["startCommand"]
    assert "cd backend" in start and "uvicorn main:app" in start
    assert RAILWAY["deploy"]["healthcheckPath"] == "/api/auth/health"
    assert RAILWAY["build"]["builder"] == "DOCKERFILE"
    assert RAILWAY["build"]["dockerfilePath"] == "Dockerfile"
