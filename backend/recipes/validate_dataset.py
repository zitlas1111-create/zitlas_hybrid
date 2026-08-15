"""
ZITLAS — Recipe master dataset validator (backend/recipes/validate_dataset.py)

Validates backend/recipes/data/zitlas_recipes.json against the structural
rules the recipe API depends on. Never modifies recipe content — a failure
here is reported, not silently patched, per the consolidation task's explicit
"do not alter recipe content" instruction.

Run standalone: python backend/recipes/validate_dataset.py
Also imported by services/recipe_service.py to fail loudly at startup if the
dataset is ever hand-edited into an invalid state.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

DATASET_PATH = Path(__file__).parent / "data" / "zitlas_recipes.json"

REQUIRED_FIELDS = [
    "id", "name", "description", "category", "meal_type", "fitness_goals",
    "diet_type", "servings", "prep_time_min", "cook_time_min", "total_time_min",
    "difficulty", "equipment", "cost_level", "ingredients", "instructions",
    "nutrition_estimated", "primary_protein_sources", "why_it_works", "tags",
    "regional_tag", "hostel_friendly", "home_friendly", "zitlas_original",
]
REQUIRED_NUTRITION_FIELDS = ["calories_kcal", "protein_g", "carbs_g", "fat_g", "fiber_g"]

# Fields allowed to legitimately be None/empty — regional_tag has no fixed
# regional origin for a large share of recipes (Pan-India / no specific
# regional inspiration), which is real data, not a defect.
_NULLABLE_FIELDS = {"regional_tag"}

_PLACEHOLDER_PATTERNS = [
    re.compile(r"\{p\d+\}"), re.compile(r"\{ingredient\}", re.IGNORECASE),
    re.compile(r"\{protein\}", re.IGNORECASE), re.compile(r"\bTBD\b"),
    re.compile(r"\bTODO\b"), re.compile(r"\[insert", re.IGNORECASE),
    re.compile(r"<placeholder>", re.IGNORECASE),
]

_ID_RE = re.compile(r"^ZITLAS-REC-(\d+)$")


class ValidationResult:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    @property
    def ok(self) -> bool:
        return not self.errors

    def report(self) -> str:
        lines = []
        if self.errors:
            lines.append(f"{len(self.errors)} ERROR(S):")
            lines += [f"  - {e}" for e in self.errors]
        if self.warnings:
            lines.append(f"{len(self.warnings)} WARNING(S):")
            lines += [f"  - {w}" for w in self.warnings]
        if not self.errors and not self.warnings:
            lines.append("Dataset is valid — no errors, no warnings.")
        return "\n".join(lines)


def validate_recipes(recipes: list[dict[str, Any]]) -> ValidationResult:
    result = ValidationResult()

    if not isinstance(recipes, list):
        result.errors.append("Top-level JSON is not a list of recipe objects.")
        return result

    seen_ids: dict[str, int] = {}
    seen_names: dict[str, int] = {}
    id_nums: list[int] = []

    for i, r in enumerate(recipes):
        rid = r.get("id")
        label = rid or f"<record at index {i}, no id>"

        # 1-2: ID exists + unique
        if not rid:
            result.errors.append(f"{label}: missing 'id'")
        else:
            m = _ID_RE.match(rid)
            if not m:
                result.errors.append(f"{rid}: id does not match ZITLAS-REC-#### format")
            else:
                id_nums.append(int(m.group(1)))
            if rid in seen_ids:
                result.errors.append(f"{rid}: duplicate id (also at index {seen_ids[rid]})")
            else:
                seen_ids[rid] = i

        # 3-4: name exists and non-empty
        name = r.get("name")
        if not name or not str(name).strip():
            result.errors.append(f"{label}: missing or empty 'name'")
        else:
            if name in seen_names:
                result.errors.append(f"{label}: duplicate name {name!r} (also at index {seen_names[name]})")
            else:
                seen_names[name] = i

        # 5-11: required fields present (nutrition sub-fields checked separately)
        for field in REQUIRED_FIELDS:
            if field not in r:
                result.errors.append(f"{label}: missing required field '{field}'")

        nut = r.get("nutrition_estimated")
        if nut is None:
            result.errors.append(f"{label}: missing 'nutrition_estimated'")
        elif not isinstance(nut, dict):
            result.errors.append(f"{label}: 'nutrition_estimated' is not an object")
        else:
            for nf in REQUIRED_NUTRITION_FIELDS:
                if nf not in nut:
                    result.errors.append(f"{label}: nutrition_estimated missing '{nf}'")

        # description non-empty
        desc = r.get("description")
        if not desc or not str(desc).strip():
            result.errors.append(f"{label}: missing or empty 'description'")

        # ingredients / instructions non-empty lists
        if not r.get("ingredients"):
            result.errors.append(f"{label}: 'ingredients' is empty or missing")
        if not r.get("instructions"):
            result.errors.append(f"{label}: 'instructions' is empty or missing")

        # 13: placeholder artifacts anywhere in the record
        blob = json.dumps(r, ensure_ascii=False)
        for pat in _PLACEHOLDER_PATTERNS:
            if pat.search(blob):
                result.errors.append(f"{label}: contains placeholder artifact matching /{pat.pattern}/")
                break

        # Nullable-field exemption documented, everything else should not be
        # null when present in the schema.
        for field in REQUIRED_FIELDS:
            if field in r and r[field] is None and field not in _NULLABLE_FIELDS:
                result.warnings.append(f"{label}: field '{field}' is present but null")

    # 15-16: no missing IDs within the observed range, no duplicates (dup
    # already caught above; this re-derives the range check independently)
    if id_nums:
        id_nums_sorted = sorted(id_nums)
        lo, hi = id_nums_sorted[0], id_nums_sorted[-1]
        expected = set(range(lo, hi + 1))
        missing = sorted(expected - set(id_nums_sorted))
        if missing:
            missing_ids = ", ".join(f"ZITLAS-REC-{n:04d}" for n in missing)
            result.errors.append(f"Missing IDs within range ZITLAS-REC-{lo:04d}..{hi:04d}: {missing_ids}")

    return result


def load_and_validate(path: Path = DATASET_PATH) -> tuple[list[dict[str, Any]], ValidationResult]:
    with path.open(encoding="utf-8") as f:
        recipes = json.load(f)
    return recipes, validate_recipes(recipes)


def main() -> None:
    recipes, result = load_and_validate()
    print(f"[RECIPE VALIDATE] {len(recipes)} recipes loaded from {DATASET_PATH}")
    print(result.report())
    if not result.ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
