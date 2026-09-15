"""
ZITLAS — enriches the canonical dataset (backend/enrich_canonical_dataset.py)

Runs the EXISTING v1 → v2 → v3 enrichment chain (enrich_food_dataset.py,
_v2.py, _v3.py) over food_dataset/zitlas_food_database_canonical.json,
producing food_dataset/zitlas_food_database_enriched_canonical.json.

WHY THIS FILE EXISTS RATHER THAN CALLING THE EXISTING SCRIPTS DIRECTLY
------------------------------------------------------------------------
enrich_food_dataset_v3.main() (and v2's, and v1's) all write to the SAME
hardcoded path — food_dataset/zitlas_food_database_enriched.json, the
PRODUCTION file. Calling any of their main() functions would overwrite
production. This script never calls main() on any of them.

What it DOES call directly, unmodified, imported — not copied or
reimplemented — is enrich_food_v3(), the pure per-record enrichment
function, and _assert_untouched(), the existing protected-field integrity
check both v2 and v3 already build and enforce internally. Reusing them
here is exactly "prefer calling existing functions over duplicating logic."

INPUT / OUTPUT
--------------
    reads:  food_dataset/zitlas_food_database_canonical.json  (2,448, 15 fields)
    writes: food_dataset/zitlas_food_database_enriched_canonical.json  (NEW file)

Touches NOTHING else. The canonical file is read-only here. The production
enriched file is never opened by this script in any mode.

REGIONAL ORIGINS FOR NEW FOODS
------------------------------
    reads:  food_dataset/zitlas_food_database_canonical_origins.json

Foods added to the canonical file after the original 4,500 carry no state in
their 15 fields, and v2's name keywords only know the dishes that existed
then — a Bengali shukto or a Kodava pandi curry would otherwise be tagged
"Pan-India". The origins file (written by food_dataset/build/expand_v5.py
from each batch entry's hand-assigned origin) is merged, in memory only,
into enrich_food_dataset_v3.NEW_FOOD_LOCATION — the exact override path v3
already applies to its own 20 regional foods. enrich_food_dataset_v3.py on
disk is not changed, and the production dataset is not re-enriched.

Usage (from backend/ directory):
    python enrich_canonical_dataset.py              # refuses to overwrite
    python enrich_canonical_dataset.py --overwrite  # regenerate the output
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

import enrich_food_dataset_v3 as _v3
# Reused, not reimplemented — the whole point of this file.
from enrich_food_dataset_v3 import enrich_food_v3, _assert_untouched

_ROOT = Path(__file__).parent.parent
_SRC = _ROOT / "food_dataset" / "zitlas_food_database_canonical.json"
_DST = _ROOT / "food_dataset" / "zitlas_food_database_enriched_canonical.json"
_ORIGINS = _ROOT / "food_dataset" / "zitlas_food_database_canonical_origins.json"
_ORIGIN_KEYS = {"state_of_origin", "region", "popularity_score", "festival_food"}


def _load_origins(canonical_ids: set[int]) -> dict[int, dict]:
    """{id: origin} for new foods. Empty — and enrichment proceeds exactly as
    before — when the file doesn't exist."""
    if not _ORIGINS.exists():
        return {}
    raw = json.loads(_ORIGINS.read_text(encoding="utf-8"))
    origins: dict[int, dict] = {}
    for key, origin in raw.items():
        fid = int(key)
        if set(origin) != _ORIGIN_KEYS:
            raise AssertionError(f"origin for id={fid} has fields {sorted(origin)}")
        if not origin["state_of_origin"]:
            raise AssertionError(f"origin for id={fid} names no state")
        origins[fid] = {
            "state_of_origin": list(origin["state_of_origin"]),
            "region": origin["region"],
            "popularity_score": float(origin["popularity_score"]),
            "festival_food": bool(origin["festival_food"]),
        }
    unknown = set(origins) - canonical_ids
    if unknown:
        raise AssertionError(f"origins for ids not in the canonical file: {sorted(unknown)[:10]}")
    clash = set(origins) & set(_v3.NEW_FOOD_LOCATION)
    if clash:
        raise AssertionError(f"origins would override v3's own regional foods: {sorted(clash)}")
    return origins

# STEP 4 — the display-name correction pass. Read-only reference produced by
# food_dataset/build/step4_audit.py, which traced every one of the 573 foods
# whose canonical representative carries a Home/Restaurant/Hostel Mess/Street
# suffix even though a bare-named sibling of the SAME dish exists, and split
# them into two groups:
#
#   SAFE (549)   the bare-name sibling sits in the SAME category as the
#                chosen representative — one coherent sub-family, only the
#                venue wording differs. Restoring the bare name here is
#                exactly what "same food, presentation-suffix only" means.
#
#   UNSAFE (24)  the bare-name sibling sits in a DIFFERENT category —
#                e.g. "Sabudana Khichdi" existed as two independently
#                generated sub-families (Indian Breakfast 270kcal vs
#                Maharashtrian Foods 121kcal) in the original 4,500, and the
#                representative belongs to only one of them. Restoring the
#                bare name would misleadingly imply continuity with a record
#                this one was never derived from — left untouched.
#
# This corrects ONLY the `name` field (and the name-echo at the start of
# `description`, for internal consistency) on the ENRICHED OUTPUT. It never
# writes to zitlas_food_database_canonical.json — that file is read-only
# input here, exactly as it was before this correction existed.
_NAME_AUDIT = Path(__file__).parent.parent / "food_dataset" / "build" / "step4_name_audit.json"


def _load_safe_name_corrections() -> dict[int, str]:
    """{id: bare_name} for every record proven safe to rename. Empty dict —
    and enrichment proceeds unchanged — if the audit file doesn't exist yet."""
    if not _NAME_AUDIT.exists():
        return {}
    audit = json.loads(_NAME_AUDIT.read_text(encoding="utf-8"))
    return {
        r["id"]: r["original_name"]
        for r in audit["records"]
        if r["safe_to_restore_original_name"]
    }


def main(overwrite: bool = False) -> None:
    if not _SRC.exists():
        raise FileNotFoundError(f"Canonical dataset not found: {_SRC}")
    if _DST.exists() and not overwrite:
        raise FileExistsError(
            f"{_DST} already exists — refusing to overwrite. Re-run with "
            f"--overwrite if you intend to regenerate it.")

    canonical = json.loads(_SRC.read_text(encoding="utf-8"))
    print(f"[ENRICH CANONICAL] Loaded {len(canonical)} canonical foods from {_SRC}")

    origins = _load_origins({f["id"] for f in canonical})
    _v3.NEW_FOOD_LOCATION.update(origins)  # in memory only — see module docstring
    print(f"[ENRICH CANONICAL] Applying {len(origins)} hand-assigned regional origins")

    seen_ids: set[int] = set()
    enriched: list[dict] = []
    for food in canonical:
        if food["id"] in seen_ids:
            raise ValueError(f"Duplicate food id detected: {food['id']} ({food['name']}) — refusing to enrich")
        seen_ids.add(food["id"])
        record = enrich_food_v3(food)
        # The SAME integrity gate v2/v3 already enforce on the production
        # chain — not a new check invented for this file.
        _assert_untouched(food, record)
        enriched.append(record)

    if len(enriched) != len(canonical):
        raise AssertionError(
            f"Record count mismatch: {len(enriched)} enriched vs {len(canonical)} "
            f"source — refusing to write")

    ids_in = {f["id"] for f in canonical}
    ids_out = {f["id"] for f in enriched}
    if ids_in != ids_out:
        raise AssertionError(
            f"ID set changed. Missing: {ids_in - ids_out or None}, "
            f"New: {ids_out - ids_in or None} — refusing to write")

    # Belt + suspenders, independent of the per-record loop above: re-verify
    # every canonical record is byte-identical on every protected field.
    by_id = {f["id"]: f for f in canonical}
    for record in enriched:
        _assert_untouched(by_id[record["id"]], record)
    print(f"[ENRICH CANONICAL] Verified all {len(canonical)} canonical foods "
          f"byte-identical on every protected field")

    # ── STEP 4: proven-safe display-name corrections ────────────────────────
    # Touches ONLY `name` and the name-echo at the start of `description`.
    # Every other field — id, category, serving_size, every nutrition value,
    # and canonical identity — is verified unchanged immediately below.
    corrections = _load_safe_name_corrections()
    if corrections:
        import sys
        sys.path.insert(0, str(Path(__file__).parent.parent / "food_dataset" / "build"))
        from build_new_foods import canonical_key  # noqa: E402

        PROTECTED = ("id", "category", "serving_size", "calories", "protein",
                    "carbs", "fat", "fiber", "sugar", "sodium", "type",
                    "goals", "allergens")
        applied = 0
        for record in enriched:
            new_name = corrections.get(record["id"])
            if new_name is None:
                continue
            old_name = record["name"]
            if new_name == old_name:
                continue  # already bare, nothing to do

            # Canonical identity must not move — the new name must resolve to
            # the SAME canonical key the old one did, or this "correction"
            # would silently reclassify the food.
            if canonical_key(new_name) != canonical_key(old_name):
                raise AssertionError(
                    f"Refusing rename for id={record['id']}: '{old_name}' -> "
                    f"'{new_name}' changes canonical_key "
                    f"({canonical_key(old_name)!r} -> {canonical_key(new_name)!r})")

            before = {k: record[k] for k in PROTECTED}
            record["name"] = new_name
            if record["description"].startswith(old_name):
                record["description"] = new_name + record["description"][len(old_name):]
            after = {k: record[k] for k in PROTECTED}
            if before != after:
                raise AssertionError(
                    f"Rename for id={record['id']} touched a protected field — refusing")
            applied += 1

        # No two records may now share an exact name — proven structurally
        # impossible in the audit (same name => same canonical_key => same
        # group => only one representative), verified again here directly.
        names = [r["name"] for r in enriched]
        if len(names) != len(set(names)):
            dupes = {n for n in names if names.count(n) > 1}
            raise AssertionError(f"Renaming introduced duplicate names: {dupes}")

        print(f"[ENRICH CANONICAL] Applied {applied} proven-safe display-name "
              f"corrections ({len(corrections) - applied} already bare or unchanged)")

    # Every origin must actually have landed on its record.
    by_out = {r["id"]: r for r in enriched}
    for fid, origin in origins.items():
        if by_out[fid]["state_of_origin"] != origin["state_of_origin"]:
            raise AssertionError(f"origin for id={fid} did not apply")

    # Same compact form as the production enriched file (indent=None).
    _DST.write_text(json.dumps(enriched, ensure_ascii=False, indent=None), encoding="utf-8")
    print(f"[ENRICH CANONICAL] Wrote {len(enriched)} enriched foods -> {_DST}")

    field_count = len(enriched[0].keys()) if enriched else 0
    print(f"[ENRICH CANONICAL] Field count per record: {field_count}")
    states = Counter(s for r in enriched for s in r["state_of_origin"])
    print(f"[ENRICH CANONICAL] Foods with a state of origin: "
          f"{sum(1 for r in enriched if r['state_of_origin'])} across {len(states)} states")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--overwrite", action="store_true",
                    help="regenerate the enriched canonical file even if it exists")
    main(overwrite=ap.parse_args().overwrite)
