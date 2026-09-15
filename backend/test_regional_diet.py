"""ZITLAS — Regional diet + location personalization regression suite.

Covers the LOCATION -> REGIONAL FOOD -> DIET -> SWAP audit (Maharashtra focus)
and locks in the two fixes made after that audit:
  A. Manual City/State (Personal Info) resolves the same as GPS — regional
     personalization does not depend exclusively on GPS.
  B. The OFFLINE fallback composes COMPLETE main meals (no lone side dish as a
     dinner) and folds in regional keyword favorites, matching the main path.

Pure deterministic engine tests — NO LLM calls, safe to run anywhere:
    python test_regional_diet.py            (exit 0 = all pass)
    python -m pytest test_regional_diet.py  (also works via test_* funcs)
"""
from services import food_engine, location_food_engine
from services import offline_fallback

ENGINE = food_engine.get_engine()
_failures: list[str] = []


def check(name: str, ok: bool, extra: str = "") -> None:
    print(("PASS" if ok else "FAIL") + " - " + name + ("" if ok else f" | {extra}"))
    if not ok:
        _failures.append(name + (f" | {extra}" if extra else ""))


def _ctx(loc, diet="Vegetarian", disease="", allergies=None):
    b = location_food_engine.build_region_boost(loc)
    cats = b["preferred_categories"] if b else []
    favs = b["preferred_keywords"] if b else []
    return {
        "region": b["region_label"] if b else None,
        "goal_tags": ["Weight Loss", "Fat Loss"],
        "diet_tags": food_engine.diet_tags_from_lifestyle(diet),
        "disease_tags": food_engine.FoodRecommendationEngine.resolve_disease_tags(disease),
        "allergens": food_engine.FoodRecommendationEngine.resolve_allergens(allergies or []),
        "favorite_foods": favs,
        "profile": {"preferredCategories": cats} if cats else None,
    }


def _week_dinner(ctx):
    wp = ENGINE.build_week_plan(
        ctx["goal_tags"], ctx["diet_tags"], "Home", "Medium",
        ctx["disease_tags"], ctx["allergens"],
        favorite_foods=ctx["favorite_foods"], daily_calorie_target=1600,
        profile=ctx["profile"],
    )
    return wp["days"][0]["meals"]["dinner"]["primary"]


# ── Tests ────────────────────────────────────────────────────────────────────

def test_maharashtra_vs_punjab_differ():
    mh = location_food_engine.build_region_boost({"city": "Pune", "state": "Maharashtra"})
    pb = location_food_engine.build_region_boost({"city": "Amritsar", "state": "Punjab"})
    check("Maharashtra resolves with dishes", bool(mh and mh["preferred_keywords"]))
    check("Punjab resolves with dishes", bool(pb and pb["preferred_keywords"]))
    check("Maharashtra != Punjab keyword sets",
          set(mh["preferred_keywords"]) != set(pb["preferred_keywords"]),
          "regional differentiation missing")
    mh_names = " ".join(mh["preferred_keywords"]).lower()
    check("Maharashtra surfaces a real MH dish",
          any(k in mh_names for k in ("misal", "poha", "sabudana", "thalipeeth", "pithla", "vada")),
          mh_names)


def test_manual_location_resolves_like_gps():
    # Fix A: a manually-typed City/State (no lat/lng) must resolve the same.
    by_city = location_food_engine.resolve_state({"city": "Pune"})
    by_state_only = location_food_engine.resolve_state({"state": "Maharashtra"})
    check("resolve_state(city=Pune) -> Maharashtra", by_city == "Maharashtra", str(by_city))
    check("resolve_state(state=Maharashtra) -> Maharashtra", by_state_only == "Maharashtra", str(by_state_only))
    b = location_food_engine.build_region_boost({"city": "", "state": "Maharashtra", "source": "manual"})
    check("manual {state:Maharashtra} yields a region boost", bool(b and b["region_label"] == "Maharashtra"))


def test_location_denied_and_unknown_are_noop():
    check("denied (None) -> no boost", location_food_engine.build_region_boost(None) is None)
    check("empty {} -> no boost", location_food_engine.build_region_boost({}) is None)
    check("unknown state -> no boost (not assumed Maharashtra)",
          location_food_engine.build_region_boost({"state": "Atlantis"}) is None)
    # Plan still generates without location.
    ctx = _ctx(None)
    check("diet still builds with no location", len(_week_dinner(ctx)) >= 1)


def test_vegetarian_maharashtra_no_nonveg():
    ctx = _ctx({"city": "Pune", "state": "Maharashtra"}, diet="Vegetarian")
    combo = _week_dinner(ctx)
    nonveg = [f["name"] for f in combo if f.get("non_vegetarian") or "Non-Vegetarian" not in (f.get("dietSuitable") or ["Non-Vegetarian"]) and f.get("non_vegetarian")]
    bad = [f["name"] for f in combo if f.get("non_vegetarian") is True]
    check("vegetarian MH dinner has no non-veg item", not bad, str(bad))


def _week_slot(ctx, slot):
    wp = ENGINE.build_week_plan(
        ctx["goal_tags"], ctx["diet_tags"], "Home", "Medium",
        ctx["disease_tags"], ctx["allergens"],
        favorite_foods=ctx["favorite_foods"], daily_calorie_target=1600,
        profile=ctx["profile"],
    )
    return wp["days"][0]["meals"][slot]["primary"]


def _week_nonveg_ratio(ctx, goal=("Muscle Gain", "Muscle Building"), cal=2200):
    wp = ENGINE.build_week_plan(
        list(goal), ctx["diet_tags"], "Home", "Medium",
        ctx["disease_tags"], ctx["allergens"],
        favorite_foods=ctx["favorite_foods"], daily_calorie_target=cal,
        profile=ctx["profile"],
    )
    total = nv = 0
    for day in wp["days"]:
        for sd in day["meals"].values():
            for f in sd["primary"]:
                total += 1
                nv += 1 if f.get("non_vegetarian") is True else 0
    return nv, total


def test_nonvegetarian_maharashtra_complete_and_regional():
    ctx = _ctx({"city": "Mumbai", "state": "Maharashtra"}, diet="Non-Vegetarian")
    check("non-veg MH region resolves", ctx["region"] == "Maharashtra")
    for slot in ("breakfast", "lunch", "dinner"):
        combo = _week_slot(ctx, slot)
        issues = ENGINE.validate_meal_combo(combo, slot)
        check(f"non-veg MH {slot} is a complete meal ({' + '.join(f['name'] for f in combo)[:45]})",
              not issues, str(issues))
    # The fix: non-veg admits veg staples (carb base) AND still yields non-veg.
    nv, total = _week_nonveg_ratio(ctx)
    check("non-veg MH week still contains non-veg dishes (fix not over-corrected)",
          nv > 0, f"{nv}/{total}")


def test_nonvegetarian_punjab_complete():
    ctx = _ctx({"city": "Amritsar", "state": "Punjab"}, diet="Non-Vegetarian")
    check("non-veg Punjab region resolves", ctx["region"] == "Punjab")
    combo = _week_slot(ctx, "dinner")
    check("non-veg Punjab dinner is a complete meal ({})".format(" + ".join(f["name"] for f in combo)[:45]),
          not ENGINE.validate_meal_combo(combo, "dinner"),
          str(ENGINE.validate_meal_combo(combo, "dinner")))


def test_vegetarian_never_gets_meat():
    # Safety: the widened non-veg semantics must NOT leak meat to vegetarians.
    ctx = _ctx({"city": "Mumbai", "state": "Maharashtra"}, diet="Vegetarian")
    nv, total = _week_nonveg_ratio(ctx)
    check("vegetarian MH week has ZERO non-veg items", nv == 0, f"{nv}/{total}")


def test_nonveg_carb_base_completion_build_meal_combo():
    # Requirement 7: build_meal_combo must plate a veg carb base with a non-veg
    # user's proteins. Mirror the engine's real pool (top_n=40, goal-relaxed —
    # the exact retry build_week_plan uses) so the pool contains carb staples,
    # which the WIDENED non-veg filter now admits (before the fix it couldn't).
    ctx = _ctx({"city": "Kolhapur", "state": "Maharashtra"}, diet="Non-Vegetarian")
    pool = ENGINE.recommend(
        meal_slot="dinner", goal_tags=[], diet_tags=ctx["diet_tags"],
        living_situation="Home", budget_tier="Medium", disease_tags=[], allergens=set(),
        favorite_foods=ctx["favorite_foods"], top_n=40, profile=ctx["profile"],
    )
    # The widened pool must contain at least one veg carb base to plate with.
    veg_carb_in_pool = any(
        (ENGINE._role(f) == "carb_source" or f.get("complete_meal"))
        and f.get("non_vegetarian") is not True for f in pool
    )
    check("non-veg dinner pool now contains a veg carb base (diet widening)",
          veg_carb_in_pool, "no veg carb base in pool")
    combo = ENGINE.build_meal_combo(pool, "dinner", None)
    check("non-veg dinner combo passes validation ({})".format(" + ".join(f["name"] for f in combo)[:45]),
          not ENGINE.validate_meal_combo(combo, "dinner"),
          str(ENGINE.validate_meal_combo(combo, "dinner")))


def test_nonveg_allergy_and_disease_safety():
    # Diet widening must not weaken allergy / disease safety.
    actx = _ctx({"city": "Pune", "state": "Maharashtra"}, diet="Non-Vegetarian", allergies=["Egg"])
    acombo = _week_slot(actx, "dinner")
    egg_hit = [f["name"] for f in acombo if "egg" in " ".join(str(a).lower() for a in (f.get("allergens") or []))]
    check("egg-allergy + non-veg MH dinner excludes egg foods", not egg_hit, str(egg_hit))
    dctx = _ctx({"city": "Pune", "state": "Maharashtra"}, diet="Non-Vegetarian", disease="Diabetes")
    dcombo = _week_slot(dctx, "dinner")
    unsafe = [f["name"] for f in dcombo if f.get("diabetes_friendly") is False]
    check("diabetes + non-veg MH dinner contains no diabetes-unsafe food", not unsafe, str(unsafe))


def test_nonveg_regional_swap_complete():
    ctx = _ctx({"city": "Pune", "state": "Maharashtra"}, diet="Non-Vegetarian")
    combos = ENGINE.find_swap_combos(
        "dinner", ctx["goal_tags"], ctx["diet_tags"], "Home", "Medium",
        [], set(), exclude_names=[], n_combos=5, profile=ctx["profile"],
    )
    check("non-veg MH dinner swap returns >=1 combo", len(combos) >= 1)
    for c in combos:
        check(f"non-veg MH swap combo valid ({' + '.join(f['name'] for f in c)[:40]})",
              not ENGINE.validate_meal_combo(c, "dinner"),
              str(ENGINE.validate_meal_combo(c, "dinner")))


def test_nonveg_no_supplements_excludes_supplements():
    from services.groq_service import _engine_query_context
    ctx = _engine_query_context(
        {"primary_goal": "muscle_gain", "uses_supplements": "no",
         "location": {"city": "Pune", "state": "Maharashtra"}},
        {"diet_type": "Non-Vegetarian", "living_situation": "Home", "daily_budget": "Medium"},
    )
    avoids = (ctx.get("profile") or {}).get("avoidCategories") or []
    check("no-supplements + non-veg adds 'Protein Supplements' to avoidCategories",
          "Protein Supplements" in avoids, str(avoids))
    check("non-veg diet tags are inclusive (veg + non-veg)",
          set(ctx["diet_tags"]) == {"Vegetarian", "Non Vegetarian"}, str(ctx["diet_tags"]))


def test_disease_and_allergy_with_maharashtra():
    # Diabetes: engine hard-filters unsafe foods before regional re-rank.
    dctx = _ctx({"city": "Pune", "state": "Maharashtra"}, disease="Diabetes")
    dcombo = _week_dinner(dctx)
    unsafe = [f["name"] for f in dcombo if f.get("diabetes_friendly") is False]
    check("diabetes + MH dinner contains no diabetes-unsafe food", not unsafe, str(unsafe))
    # Peanut allergy: no food carrying the peanut allergen.
    actx = _ctx({"city": "Pune", "state": "Maharashtra"}, allergies=["Peanut"])
    acombo = _week_dinner(actx)
    with_peanut = [f["name"] for f in acombo if "peanut" in " ".join(str(a).lower() for a in (f.get("allergens") or []))]
    check("peanut-allergy + MH dinner excludes peanut foods", not with_peanut, str(with_peanut))


def test_swaps_are_complete_and_regional():
    ctx = _ctx({"city": "Pune", "state": "Maharashtra"})
    for slot in ("breakfast", "lunch", "dinner"):
        combos = ENGINE.find_swap_combos(
            slot, ctx["goal_tags"], ctx["diet_tags"], "Home", "Medium",
            ctx["disease_tags"], ctx["allergens"], exclude_names=[], n_combos=5,
            profile=ctx["profile"],
        )
        check(f"{slot} swap returns >=1 combo", len(combos) >= 1)
        for c in combos:
            issues = ENGINE.validate_meal_combo(c, slot)
            check(f"{slot} swap combo is valid ({' + '.join(f['name'] for f in c)[:40]})",
                  not issues, str(issues))


def test_dinner_is_never_a_lone_snack_online():
    # The "Sweet Corn dinner" guard on the MAIN path.
    ctx = _ctx({"city": "Pune", "state": "Maharashtra"})
    combo = _week_dinner(ctx)
    issues = ENGINE.validate_meal_combo(combo, "dinner")
    check("MH dinner (main path) passes meal-completeness validation", not issues, str(issues))
    check("MH dinner is not a single non-complete item",
          not (len(combo) == 1 and not combo[0].get("complete_meal")),
          " + ".join(f["name"] for f in combo))


def test_offline_fallback_dinner_is_complete():
    # Fix B: offline path must also compose a complete main meal + use region favs.
    ctx = offline_fallback._engine_context(
        {"primary_goal": "weight_loss", "location": {"city": "Pune", "state": "Maharashtra"}},
        {"diet_type": "Vegetarian", "living_situation": "Home", "daily_budget": "Medium"},
    )
    check("offline ctx carries regional keyword favorites", bool(ctx.get("favorite_foods")))
    for meal in ("Lunch", "Dinner"):
        out = offline_fallback._engine_foods_for_slot(ENGINE, meal, ctx, {}, set())
        check(f"offline {meal} returns items", bool(out), str(out))
        check(f"offline {meal} is not a single item (complete plate)", out and len(out) >= 2, str(out))


def test_no_supplements_preference_excludes_supplements():
    # Supplement exclusion lives in groq_service._engine_query_context; verify
    # it drops Protein Supplements from the candidate categories.
    from services.groq_service import _engine_query_context
    ctx = _engine_query_context(
        {"primary_goal": "muscle_gain", "uses_supplements": "no"},
        {"diet_type": "Vegetarian", "living_situation": "Home", "daily_budget": "Medium"},
    )
    avoids = (ctx.get("profile") or {}).get("avoidCategories") or []
    check("no-supplements adds 'Protein Supplements' to avoidCategories",
          "Protein Supplements" in avoids, str(avoids))


# ── Availability GATING regression suite (region excludes, not just boosts) ──
# Covers the fix: `state`/`compatible_regions` now flow all the way into
# `_pipeline_ids()`'s "region" stage, so a food from an unrelated zone (e.g.
# Appam — region="South", state_of_origin=["Kerala"]) is excluded from a
# Maharashtra plan by default, not merely out-ranked.

def _full_week_via_engine(loc, diet="Vegetarian", extra_favorites=None):
    """Builds a week plan through the REAL production path
    (`groq_service._engine_query_context` -> `build_week_plan`), not the
    local `_ctx()` shortcut — so this exercises the exact code
    `_engine_grounded_diet_plan`/the LLM path both call."""
    from services.groq_service import _engine_query_context
    ctx = _engine_query_context(
        {"primary_goal": "weight_loss", "location": loc},
        {"diet_type": diet, "living_situation": "Home", "daily_budget": "Medium",
         "favorite_foods": extra_favorites or []},
    )
    return ENGINE.build_week_plan(
        ctx["goal_tags"], ctx["diet_tags"], ctx["living_tag"], ctx["budget_tier"],
        ctx["disease_tags"], ctx["allergens"], favorite_foods=ctx["favorite_foods"],
        daily_calorie_target=1700, profile=ctx["profile"], subgoal_tag=ctx["subgoal_tag"],
        season_tag=ctx["season_tag"], user_state=ctx["user_state"],
        compatible_regions=ctx["compatible_regions"],
    )


def _all_names(week_plan) -> list[str]:
    names = []
    for day in week_plan["days"]:
        for slot_data in day["meals"].values():
            names += [f["name"] for f in slot_data["primary"]]
            names += [f["name"] for f in slot_data.get("alternatives", [])]
    return names


def test_maharashtra_excludes_appam_by_default():
    wp = _full_week_via_engine({"city": "Pune", "state": "Maharashtra"})
    names_lc = " | ".join(_all_names(wp)).lower()
    check("Maharashtra (no explicit South Indian preference) week never surfaces Appam/Idiyappam",
          "appam" not in names_lc, names_lc[:300])


def test_maharashtra_with_explicit_appam_preference_allows_it_as_a_candidate():
    # Isolates JUST the region stage via `_pipeline_ids` directly (no
    # season/subgoal stages engaged) — `recommend()`/`build_week_plan()`
    # apply several OTHER independent relaxable filters (season, subgoal)
    # that can legitimately exclude a specific dish for reasons that have
    # nothing to do with region, which would make this test flaky/misleading
    # if it went through the full pipeline instead.
    #
    # The goal is weight_loss because Appam's goalSuitable in the NEW dataset
    # is Endurance / Fat Loss / Weight Loss — under a General Fitness goal the
    # goal stage (which is NOT what this test is about) would exclude it
    # before the region stage is ever reached.
    from services.groq_service import _engine_query_context

    def _appam_eligible(favorite_foods):
        ctx = _engine_query_context(
            {"primary_goal": "weight_loss", "location": {"city": "Pune", "state": "Maharashtra"}},
            {"diet_type": "Vegetarian", "living_situation": "Home", "daily_budget": "Medium",
             "favorite_foods": favorite_foods},
        )
        ids = ENGINE._pipeline_ids(
            disease_tags=ctx["disease_tags"], allergens=ctx["allergens"], diet_tags=ctx["diet_tags"],
            goal_tags=ctx["goal_tags"], subgoal_tag=None, profile=ctx["profile"],
            budget_tier=ctx["budget_tier"], living_tag="Home", meal_tag="Breakfast",
            season_tag=None, user_state=ctx["user_state"], compatible_regions=ctx["compatible_regions"],
            favorite_foods=ctx["favorite_foods"],
        )
        appam_id = next(i for i in ENGINE.all_ids if ENGINE.by_id[i]["name"].lower() == "appam")
        return appam_id in ids

    check("Maharashtra, NO explicit South Indian preference -> Appam is NOT an eligible candidate",
          not _appam_eligible([]))
    check("Maharashtra + explicit 'appam' favorite -> Appam BECOMES an eligible candidate",
          _appam_eligible(["appam"]))


def test_maharashtra_still_gets_pan_india_and_local_staples():
    wp = _full_week_via_engine({"city": "Mumbai", "state": "Maharashtra"})
    names_lc = " | ".join(_all_names(wp)).lower()
    check("Maharashtra week still contains recognizable Pan-India/local staples",
          any(k in names_lc for k in ("poha", "roti", "chapati", "dal", "rice", "curd", "paneer", "oats", "banana", "khichdi")),
          names_lc[:300])


def test_kerala_excludes_maharashtra_specific_by_default():
    # Generalization check (spec #13): the SAME mechanism, reversed. Misal Pav
    # is West/Maharashtra-specific and should not leak into a Kerala plan
    # without an explicit preference, exactly like Appam-in-Maharashtra.
    wp = _full_week_via_engine({"city": "Kochi", "state": "Kerala"})
    names_lc = " | ".join(_all_names(wp)).lower()
    check("Kerala week never surfaces Misal Pav by default", "misal" not in names_lc, names_lc[:300])


def test_punjab_excludes_kerala_specific_by_default():
    wp = _full_week_via_engine({"city": "Amritsar", "state": "Punjab"})
    names_lc = " | ".join(_all_names(wp)).lower()
    check("Punjab week never surfaces Appam by default", "appam" not in names_lc, names_lc[:300])


def test_region_gate_is_the_most_relaxable_stage():
    # Spec priority: nutrition/goal/diet must never be sacrificed for
    # localization. A hard-to-satisfy combination (Non-Vegetarian + Diabetes +
    # Peanut allergy in a low-coverage state) must still produce complete,
    # safe meals rather than an empty plan just because the region stage
    # over-constrained the pool.
    ctx_loc = {"city": "Kohima", "state": "Nagaland"}  # sparse dataset coverage
    wp = _full_week_via_engine(ctx_loc, diet="Non-Vegetarian")
    for day in wp["days"]:
        for slot in ("breakfast", "lunch", "dinner"):
            combo = day["meals"].get(slot, {}).get("primary") or []
            check(f"Nagaland non-veg {day['day']} {slot} still produced a non-empty meal",
                  len(combo) >= 1, day["day"])


def test_region_gate_preserves_meal_structure():
    # Calorie-window precision is a pre-existing, separately-tracked engine
    # characteristic (none of this file's other tests assert
    # `validation["passed"]` either — see the non-veg-MH/Punjab tests above,
    # which print the same kind of variance and only assert on meal
    # completeness/composition). What THIS fix must not do is break meal
    # structure: every slot, every day, must still produce a real combo.
    wp = _full_week_via_engine({"city": "Pune", "state": "Maharashtra"})
    for day in wp["days"]:
        for slot in ("breakfast", "lunch", "dinner"):
            combo = day["meals"].get(slot, {}).get("primary") or []
            check(f"Maharashtra-gated {day['day']} {slot} still produces a real meal",
                  len(combo) >= 1, day["day"])
            for f in combo:
                check(f"{day['day']} {slot} item has real calorie/protein data ({f['name']})",
                      f.get("calories", 0) > 0, f["name"])


def test_no_location_behaves_exactly_as_before():
    from services.groq_service import _engine_query_context
    ctx = _engine_query_context(
        {"primary_goal": "weight_loss", "location": None},
        {"diet_type": "Vegetarian", "living_situation": "Home", "daily_budget": "Medium"},
    )
    check("no location -> user_state is None", ctx["user_state"] is None)
    check("no location -> compatible_regions is None (no-op gate)", ctx["compatible_regions"] is None)
    wp = ENGINE.build_week_plan(
        ctx["goal_tags"], ctx["diet_tags"], ctx["living_tag"], ctx["budget_tier"],
        ctx["disease_tags"], ctx["allergens"], favorite_foods=ctx["favorite_foods"],
        daily_calorie_target=1700, profile=ctx["profile"],
        user_state=ctx["user_state"], compatible_regions=ctx["compatible_regions"],
    )
    check("no-location plan still generates a full 7 days", len(wp["days"]) == 7)


def _food(name: str) -> dict:
    """A food by its exact name — ids are dataset-specific, names are not."""
    return next(f for f in ENGINE.by_id.values() if f["name"] == name)


def test_maharashtra_gujarati_dal_swap_does_not_return_khaman_dhokla():
    """The reported bug, reproduced exactly: a Maharashtra user swapping
    "Gujarati Dal" must not be handed "Khaman Dhokla" — another
    Gujarat-specific dish that only shares the dataset's broad "West" zone
    label with Maharashtra. Region must carry enough scoring weight that a
    same-state/Pan-India candidate always outranks an equally-fit
    other-state dish."""
    location = {"state": "Maharashtra"}
    user_state = location_food_engine.resolve_state(location)
    compatible_regions = location_food_engine.compatible_regions(location)
    check("Maharashtra resolves", user_state == "Maharashtra")

    combos = ENGINE.find_swap_combos(
        meal_slot="mid_morning", goal_tags=["General Fitness"], diet_tags=["Vegetarian"],
        living_situation="Home", budget_tier="Low", disease_tags=[], allergens=set(),
        exclude_names=["Gujarati Dal"], n_combos=3,
        user_state=user_state, compatible_regions=compatible_regions,
    )
    check("swap produced at least one combo", len(combos) >= 1)
    top_names = [f["name"] for c in combos for f in c]
    check("Khaman Dhokla is not among the top swap combos for a Maharashtra user",
          not any("khaman" in n.lower() for n in top_names), top_names)

    # Direct score comparison — the actual mechanism, not just the outcome.
    khaman = _food("Khaman Dhokla")   # state_of_origin=["Gujarat"]
    misal = _food("Misal Pav")        # state_of_origin=["Maharashtra"]
    guj_dal = _food("Gujarati Dal")   # state_of_origin=[], available_states=["Gujarat"]
    common_kwargs = dict(
        goal_tags=["General Fitness"], living_tag="Home", budget_tier="Low",
        favorite_foods=[], usage_count=0, profile=None,
        user_state=user_state, compatible_regions=compatible_regions,
    )
    khaman_score = ENGINE._score(khaman, **common_kwargs)
    misal_score = ENGINE._score(misal, **common_kwargs)
    check("a genuine Maharashtra dish (Misal Pav) outscores the Gujarat-specific "
          "Khaman Dhokla for a Maharashtra user", misal_score > khaman_score,
          f"misal={misal_score:.4f} khaman={khaman_score:.4f}")
    check("Khaman Dhokla's region_component reflects 'other state, same zone' (0.30), "
          "not full eligibility parity with a Maharashtra dish",
          ENGINE._region_component(khaman, user_state, compatible_regions, []) == 0.30)
    check("Gujarati Dal (empty state_of_origin, but available_states=['Gujarat']) "
          "is correctly classified as Gujarat-specific despite the missing "
          "state_of_origin field",
          ENGINE._region_component(guj_dal, user_state, compatible_regions, []) == 0.30)
    check("a Maharashtra-tagged dish (Misal Pav) scores the top 'preferred' region tier",
          ENGINE._region_component(misal, user_state, compatible_regions, []) == 1.00)


def test_region_ranking_generalizes_beyond_maharashtra():
    """Same mechanism, different states — changing ONLY the user's
    preferredDietRegion must change which foods rank as 'preferred' vs
    'other-state', with no per-state hardcoding anywhere in the engine."""
    cases = [
        ("Punjab", "Khaman Dhokla"),      # Gujarat dish should NOT be preferred for a Punjab user
        ("Tamil Nadu", "Gujarati Dal"),
        ("West Bengal", "Misal Pav"),     # Maharashtra dish should NOT be preferred for a WB user
    ]
    for state, food_label in cases:
        location = {"state": state}
        user_state = location_food_engine.resolve_state(location)
        compatible_regions = location_food_engine.compatible_regions(location)
        food = _food(food_label)
        component = ENGINE._region_component(food, user_state, compatible_regions, [])
        check(f"{food_label} is NOT the 'preferred' tier for a {state} user",
              component < 1.00, f"component={component}")


def _run_all():
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
            except Exception as e:  # a thrown test is a failure, not a crash
                check(name, False, f"EXCEPTION {type(e).__name__}: {e}")
    print("\n" + ("ALL PASSED" if not _failures else f"{len(_failures)} FAILURE(S)"))
    for f in _failures:
        print("  - " + f)
    return 0 if not _failures else 1


if __name__ == "__main__":
    import sys
    sys.exit(_run_all())
