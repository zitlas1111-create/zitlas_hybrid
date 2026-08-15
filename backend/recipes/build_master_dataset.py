"""
ZITLAS — Recipe master dataset builder (backend/recipes/build_master_dataset.py)

Consolidates the Claude-generated recipe batches under backend/recipes/files (N)/
into ONE canonical dataset: backend/recipes/data/zitlas_recipes.json.

WHY THIS EXISTS: the batch folders are NOT simply "one file per batch" — two
real issues were found by inspecting every file (never assume a filename
means unique content):

  1. `files (4)/batch_001_breakfast.json` (100 records, IDs 0001-0100) is
     "Batch 1 v1" — per `files (5)/00_registry.md`'s own Batch log entry,
     this was DISCARDED: a dish x concept combinatorial grid that failed the
     anti-template rule and contains unfilled `{p1}`/`{p2}` placeholders in
     every description (verified: 15/100 records actually contain them).
     It must NEVER be included.
  2. `files (5)/batch_001_breakfast.json` and `files (6)/batch_001_breakfast.json`
     are "Batch 1 v2" (50 records, IDs 0001-0050) — the real, approved batch
     — and are byte-identical to each other (two exports of the same batch
     into consecutive delivery folders). Only ONE copy is used.

Excluding those two overlaps, every remaining batch file forms a perfectly
sequential, non-overlapping ID range from ZITLAS-REC-0001 to ZITLAS-REC-0637
— 637 unique recipes, confirmed empirically (unique IDs, no gaps, no
duplicate names, zero placeholder artifacts, every required field present
on every record) before this script was written, not assumed from the
registry's own claims.

This script is RE-RUNNABLE — it always re-reads the same 12 source files (all
of them under backend/recipes/files (N)/, listed explicitly below rather than
glob-discovered, so a future batch folder never gets silently swept in
without a matching source-list update and re-validation) and regenerates
zitlas_recipes.json deterministically. It never modifies anything under
files (N)/ — those remain the untouched historical/source archive.

Run: python backend/recipes/build_master_dataset.py
"""

from __future__ import annotations

import json
from pathlib import Path

RECIPES_DIR = Path(__file__).parent
OUTPUT_PATH = RECIPES_DIR / "data" / "zitlas_recipes.json"

# Explicit, ordered list of the CANONICAL source files — one file per real
# batch, in ID order. Deliberately NOT `glob("files (*)/*.json")`: that would
# silently re-include the discarded v1 (`files (4)`) and the redundant v2
# duplicate (`files (6)`), which is exactly the "blindly concatenate every
# JSON file" mistake this script exists to avoid.
CANONICAL_SOURCES = [
    "files (5)/batch_001_breakfast.json",     # Batch 1 v2 (APPROVED) — 0001-0050
    "files (7)/batch_002_breakfast.json",     # Batch 2 — 0051-0100
    "files (7)/batch_003_breakfast.json",     # Batch 3 — 0101-0150
    "files (8)/batch_004_breakfast.json",     # Batch 4 — 0151-0200
    "files (9)/batch_005_breakfast.json",     # Batch 5 — 0201-0250
    "files (9)/batch_006_breakfast.json",     # Batch 6 — 0251-0300
    "files (10)/batch_007_breakfast.json",    # Batch 7 — 0301-0350
    "files (11)/batch_008_breakfast.json",    # Batch 8 — 0351-0400
    "files (12)/batch_009_maharashtra.json",  # Batch 9 — 0401-0460
    "files (13)/batch_010_maharashtra.json",  # Batch 10 — 0461-0520
    "files (14)/batch_011_maharashtra.json",  # Batch 11 — 0521-0581
    "files (15)/batch_012_maharashtra.json",  # Batch 12 — 0582-0637
]

# Explicitly excluded, with the reason — so a future maintainer sees WHY
# these specific files under files (N)/ were skipped rather than wondering
# if they were simply forgotten.
KNOWN_EXCLUDED = {
    "files (4)/batch_001_breakfast.json": (
        "Batch 1 v1 — DISCARDED per registry. Dish x concept combinatorial "
        "grid; contains unfilled {p1}/{p2} placeholders in every description "
        "(verified: 15/100 records). Superseded by Batch 1 v2."
    ),
    "files (6)/batch_001_breakfast.json": (
        "Byte-identical duplicate of files (5)/batch_001_breakfast.json "
        "(Batch 1 v2) — same batch exported into a second delivery folder."
    ),
}


def build() -> list[dict]:
    all_recipes: list[dict] = []
    seen_ids: set[str] = set()
    for rel_path in CANONICAL_SOURCES:
        path = RECIPES_DIR / rel_path
        if not path.exists():
            raise FileNotFoundError(f"Expected canonical source missing: {path}")
        with path.open(encoding="utf-8") as f:
            batch = json.load(f)
        for recipe in batch:
            rid = recipe.get("id")
            if rid in seen_ids:
                raise ValueError(
                    f"Duplicate recipe id {rid!r} found while consolidating "
                    f"{rel_path} — a canonical source must never repeat an ID "
                    "already contributed by an earlier source in this list."
                )
            seen_ids.add(rid)
            all_recipes.append(recipe)
    return all_recipes


def main() -> None:
    recipes = build()
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT_PATH.open("w", encoding="utf-8") as f:
        json.dump(recipes, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"[RECIPE BUILD] wrote {len(recipes)} recipes to {OUTPUT_PATH}")
    print(f"[RECIPE BUILD] ID range: {recipes[0]['id']} .. {recipes[-1]['id']}")


if __name__ == "__main__":
    main()
