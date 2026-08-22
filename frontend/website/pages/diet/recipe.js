/*!
 * ZITLAS — Easy ZITLAS Recipe page (pages/diet/recipe.js)
 *
 * Dedicated page (never a modal — see diet.js's buildRecipeButton) reached
 * from a meal card's "Get Easy ZITLAS Recipe" button. Re-derives the
 * athlete's real context from the SAME localStorage keys diet.js/ai-coach.js
 * already read (athlete_profile, zitlas_assessment, zitlas_location/
 * zitlas_personal_info) — nothing is duplicated into the URL beyond the one
 * thing the click itself decided: which meal.
 *
 * Backend is the single source of truth for recipe data (services/
 * recipe_service.py, routes/recipes.py) — this file only builds the query,
 * renders the response, and tracks which recipe IDs have already been shown
 * this session so "Get Another Recipe" doesn't repeat.
 */
(function () {
  'use strict';

  function esc(str) {
    return String(str || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  /* esc()'s `String(x || '')` collapses the number 0 to '' — a real bug for
     fields like cook_time_min, where 0 is a common, legitimate value
     (no-cook recipes). Stringify null/undefined only, never 0, before esc(). */
  function numOr(v, fallback) {
    return esc(v === null || v === undefined ? fallback : String(v));
  }

  function safeJSON(key, fallback) {
    try {
      var v = JSON.parse(localStorage.getItem(key) || 'null');
      return v === null ? fallback : v;
    } catch (_) { return fallback; }
  }

  function showToast(message, duration) {
    var toast = document.getElementById('toast');
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add('show');
    setTimeout(function () { toast.classList.remove('show'); }, duration || 2800);
  }

  /* ── Context gathering — reuses existing storage, invents nothing ── */

  function savedLocation() {
    /* Mirrors ai-coach.js's _savedLocation() exactly: GPS-resolved location
       first, then a manually-typed city/state from Personal Info. */
    var loc = safeJSON('zitlas_location', null);
    if (loc && typeof loc === 'object' && (loc.city || loc.state || loc.latitude)) return loc;
    var pi = safeJSON('zitlas_personal_info', null);
    if (pi && typeof pi === 'object' && (pi.city || pi.state)) {
      return { city: pi.city || '', state: pi.state || '' };
    }
    return null;
  }

  /* Family Combo / Multi-Goal is a named ZITLAS concept in the spec but has
     no implementation anywhere in this codebase yet (checked: no
     family_combo/family_members storage key exists on web or backend). This
     is deliberately a real, currently-always-null hook rather than a
     fabricated signal — the moment that feature stores a real value here,
     the "Family Friendly" section below starts working with no other
     change needed (item 6/17's "implement the architecture so the field
     can be added cleanly later"). */
  function familyContext() {
    return safeJSON('zitlas_family_combo', null);
  }

  function athleteContext() {
    var profile     = safeJSON('athlete_profile', {});
    var assessment  = safeJSON('zitlas_assessment', {});
    return {
      fitnessGoal:     profile.fitness_goal || '',
      dietType:        assessment.diet_preference || '',
      livingSituation: assessment.living_situation || '',
      location:        savedLocation(),
    };
  }

  /* ── Page state ── */
  var S = {
    mealType: 'breakfast',
    context: null,
    shownIds: [],     // recipe IDs already shown this session, for "Get Another Recipe"
    current: null,    // the currently displayed recipe
    reason: [],
    overrides: {},    // filter overrides from the panel, on top of athleteContext()
    /* The DISH from the Diet page. When present this page is answering
       "the recipe for THIS meal", not "a recipe for this slot" — a
       different question with a different endpoint. */
    mealName: '',
    mealFoods: '',
    video: null,
  };

  function mealLabel(mealType) {
    var labels = { breakfast: 'Breakfast', lunch: 'Lunch', dinner: 'Dinner', snack: 'Snack' };
    return labels[mealType] || (mealType.charAt(0).toUpperCase() + mealType.slice(1));
  }

  function buildQuery(excludeShown) {
    var ctx = S.context;
    var params = new URLSearchParams();
    params.set('meal_type', S.overrides.meal_type || S.mealType);
    params.set('limit', '1');

    var fitnessGoal = S.overrides.fitness_goal || ctx.fitnessGoal;
    if (fitnessGoal) params.set('fitness_goal', fitnessGoal);

    var dietType = S.overrides.diet_type || ctx.dietType;
    if (dietType) params.set('diet_type', dietType);

    var living = S.overrides.living_situation || ctx.livingSituation;
    if (living) params.set('living_situation', living);

    if (ctx.location) {
      if (ctx.location.city)  params.set('city', ctx.location.city);
      if (ctx.location.state) params.set('state', ctx.location.state);
    }
    if (excludeShown && S.shownIds.length) {
      params.set('exclude_ids', S.shownIds.join(','));
    }
    return params;
  }

  function showState(id) {
    ['recipeLoading', 'recipeError', 'recipeNone', 'recipePreview', 'recipeDetail'].forEach(function (elId) {
      var el = document.getElementById(elId);
      if (el) el.style.display = (elId === id) ? '' : 'none';
    });
  }

  /* ── THE recipe for one specific dish ──────────────────────────────────
     Used whenever the Diet page handed us a meal_name. Hits /for-meal,
     which keys everything off the dish rather than the slot, so the result
     is always about the meal the athlete tapped. Falls back to the generic
     recommender ONLY when no dish was supplied (e.g. the page opened
     directly), never as a silent substitute for a failed lookup. */
  async function fetchMealRecipe() {
    showState('recipeLoading');
    var fallbackNote = document.getElementById('recipeFallbackNote');
    if (fallbackNote) fallbackNote.style.display = 'none';

    var params = new URLSearchParams();
    params.set('meal_name', S.mealName);
    if (S.mealType)  params.set('meal_type', mealLabel(S.mealType));
    if (S.mealFoods) params.set('foods', S.mealFoods);
    var ctxDiet = S.overrides.diet_type || S.context.dietType;
    var ctxGoal = S.overrides.fitness_goal || S.context.fitnessGoal;
    if (ctxDiet) params.set('diet_type', ctxDiet);
    if (ctxGoal) params.set('fitness_goal', ctxGoal);

    console.log('[RECIPE] recipe query:', params.toString());

    try {
      var headers = {};
      if (typeof getIdToken === 'function') {
        try {
          var token = await getIdToken();
          if (token) headers['Authorization'] = 'Bearer ' + token;
        } catch (_) { /* metering only — never blocks the recipe */ }
      }
      const resp = await fetch('/api/recipes/for-meal?' + params.toString(), { headers: headers });
      if (!resp.ok) throw new Error('API error ' + resp.status);
      const data = await resp.json();
      if (!data || !data.recipe) { showState('recipeNone'); return false; }

      S.current = data.recipe;
      S.reason  = [];
      S.video   = data.video || null;

      console.log('[RECIPE] video selected:', S.video ? S.video.title : '(none)');
      console.log('[RECIPE] video relevance:', S.video ? S.video.relevance : 'n/a');
      console.log('[RECIPE] recipe entitlement:', data.usage || '(not metered)');

      renderPreview(data.recipe);
      renderMealVideo(S.video, data.video_note);
      showState('recipePreview');
      return true;
    } catch (e) {
      console.error('[RECIPE] meal recipe failed', e);
      showState('recipeError');
      return false;
    }
  }

  /* Renders the cooking video, or an explicit note when none was relevant
     enough. An unrelated video is worse than no video, so the backend
     returns null rather than a loose match and this simply says so. */
  function renderMealVideo(video, note) {
    var host = document.getElementById('recipeVideo');
    if (!host) return;
    host.innerHTML = '';

    /* Only a VERIFIED preparation video is rendered. The backend refuses to
       send anything else, so this is a second gate rather than the decision:
       a clip that merely shows the finished dish being poured misleads about
       what the athlete is meant to do, and no video is better than that. */
    if (!video || !video.video_id || video.verified === false) {
      host.innerHTML = '<p class="recipe-video-none">' +
        esc(note || 'Recipe video coming soon.') + '</p>';
      host.style.display = '';
      return;
    }

    host.innerHTML =
      '<h3 class="recipe-video-title">How to make it</h3>' +
      '<div class="recipe-video-frame">' +
        '<iframe src="https://www.youtube.com/embed/' + esc(video.video_id) + '"' +
        ' title="' + esc(video.title || 'Cooking video') + '"' +
        ' loading="lazy" allowfullscreen' +
        ' allow="accelerometer; clipboard-write; encrypted-media; picture-in-picture"' +
        ' referrerpolicy="strict-origin-when-cross-origin"></iframe>' +
      '</div>' +
      '<p class="recipe-video-meta">' + esc(video.title || '') +
        (video.channel_name ? ' · ' + esc(video.channel_name) : '') + '</p>';
    host.style.display = '';
  }

  /* The single entry point every trigger goes through. A dish from the Diet
     page means "the recipe for THIS meal"; without one we fall back to the
     slot recommender exactly as before. */
  function loadRecipe(excludeShown) {
    if (S.mealName) return fetchMealRecipe();
    return fetchRecipe(excludeShown);
  }

  async function fetchRecipe(excludeShown) {
    showState('recipeLoading');
    document.getElementById('recipeFallbackNote').style.display = 'none';
    var params = buildQuery(excludeShown);
    try {
      const resp = await fetch('/api/recipes/recommended?' + params.toString());
      if (!resp.ok) throw new Error('API error ' + resp.status);
      const data = await resp.json();
      const recipe = (data.recipes || [])[0];
      if (!recipe) {
        showState('recipeNone');
        return false;
      }
      /* "Get Another Recipe" excludes every previously-shown ID server-side,
         but the pool for a narrow filter combination is finite — the
         backend gracefully cycles back to an already-seen recipe rather
         than returning nothing (see RecipeService.recommend's exclude_ids
         fallback). Tell the athlete honestly when that's what just
         happened, instead of silently re-showing "another" recipe that
         isn't actually new. */
      var alreadySeen = excludeShown && S.shownIds.indexOf(recipe.id) !== -1;
      if (alreadySeen) {
        showToast("You've seen all matching recipes — starting over.");
      }
      S.current = recipe;
      S.reason  = (data.reasons && data.reasons[recipe.id]) || [];
      if (S.shownIds.indexOf(recipe.id) === -1) S.shownIds.push(recipe.id);

      /* Honesty banner (item 22): a recipe that doesn't fully match the
         athlete's fitness goal is still a legitimate, safe suggestion
         (diet type is never violated — that's a hard filter server-side),
         just not a perfect one. Surfaced rather than silently presented as
         ideal. */
      var goalWanted = S.overrides.fitness_goal || S.context.fitnessGoal;
      var isExactGoalMatch = !goalWanted || (recipe.fitness_goals || []).some(function (g) {
        return g.toLowerCase().replace(/\s+/g, '_') === goalWanted.toLowerCase().replace(/\s+/g, '_')
          || g === 'Body Transformation' && goalWanted === 'transformation';
      });
      document.getElementById('recipeFallbackNote').style.display = isExactGoalMatch ? 'none' : '';

      renderPreview(recipe);
      showState('recipePreview');
      return true;
    } catch (e) {
      console.error('[RECIPE] fetch failed', e);
      showState('recipeError');
      return false;
    }
  }

  function renderPreview(r) {
    var nut = r.nutrition_estimated || {};
    var totalTime = (r.prep_time_min || 0) + (r.cook_time_min || 0);
    document.getElementById('previewName').textContent = r.name || '';
    document.getElementById('previewStats').innerHTML =
      '<span>' + numOr(nut.calories_kcal, '—') + ' kcal</span>' +
      '<span>' + numOr(nut.protein_g, '—') + 'g Protein</span>' +
      '<span>' + numOr(totalTime, '—') + ' min</span>';
    var tags = [r.difficulty, r.diet_type, r.home_friendly ? 'Home Friendly' : (r.hostel_friendly ? 'Hostel Friendly' : null)]
      .filter(Boolean);
    document.getElementById('previewTags').innerHTML =
      tags.map(function (t) { return '<span class="recipe-preview-tag">' + esc(t) + '</span>'; }).join('');
    document.getElementById('previewWhy').textContent = S.reason.join(' · ');
  }

  function renderDetail(r) {
    var nut = r.nutrition_estimated || {};
    document.getElementById('detailName').textContent = r.name || '';
    document.getElementById('detailDescription').textContent = r.description || '';

    var totalTime = (r.prep_time_min || 0) + (r.cook_time_min || 0);
    var suitability = [r.hostel_friendly ? 'Hostel Friendly' : null, r.home_friendly ? 'Home Friendly' : null]
      .filter(Boolean).join(' & ');
    var badges = [
      r.difficulty, totalTime + ' min total',
      r.servings ? r.servings + ' serving' + (r.servings === 1 ? '' : 's') : null,
      r.cost_level, r.diet_type, r.regional_tag, suitability || null,
    ].filter(Boolean).concat(r.fitness_goals || []);
    document.getElementById('detailBadges').innerHTML =
      badges.map(function (b) { return '<span class="recipe-badge">' + esc(b) + '</span>'; }).join('');

    document.getElementById('detailMacros').innerHTML =
      '<span>🔥 ' + numOr(nut.calories_kcal, '—') + ' kcal</span>' +
      '<span>💪 ' + numOr(nut.protein_g, '—') + 'g protein</span>' +
      '<span>🌾 ' + numOr(nut.carbs_g, '—') + 'g carbs</span>' +
      '<span>🥑 ' + numOr(nut.fat_g, '—') + 'g fat</span>' +
      '<span>🌿 ' + numOr(nut.fiber_g, '—') + 'g fiber</span>';

    document.getElementById('detailNutrition').innerHTML = [
      ['Calories', numOr(nut.calories_kcal, '—') + ' kcal'],
      ['Protein', numOr(nut.protein_g, '—') + 'g'],
      ['Carbohydrates', numOr(nut.carbs_g, '—') + 'g'],
      ['Fat', numOr(nut.fat_g, '—') + 'g'],
      ['Fiber', numOr(nut.fiber_g, '—') + 'g'],
    ].map(function (pair) {
      return '<div class="recipe-nutrition-cell"><span>' + esc(pair[0]) + '</span><strong>' + pair[1] + '</strong></div>';
    }).join('');

    document.getElementById('detailIngredients').innerHTML =
      (r.ingredients || []).map(function (x) { return '<li>' + esc(x) + '</li>'; }).join('');
    document.getElementById('detailInstructions').innerHTML =
      (r.instructions || []).map(function (x) { return '<li>' + esc(x) + '</li>'; }).join('');

    var protein = r.primary_protein_sources || [];
    document.getElementById('proteinSection').style.display = protein.length ? '' : 'none';
    document.getElementById('detailProtein').innerHTML =
      protein.map(function (x) { return '<li>' + esc(x) + '</li>'; }).join('');

    var why = r.why_it_works || [];
    document.getElementById('whySection').style.display = why.length ? '' : 'none';
    document.getElementById('detailWhy').innerHTML =
      why.map(function (x) { return '<li>' + esc(x) + '</li>'; }).join('');

    document.getElementById('detailReason').textContent =
      S.reason.length ? S.reason.join('. ') + '.' : 'A well-rounded ZITLAS recipe for this meal.';

    var tags = r.tags || [];
    document.getElementById('detailTags').innerHTML =
      tags.map(function (t) { return '<span class="recipe-tag">' + esc(t) + '</span>'; }).join('') +
      (r.equipment && r.equipment.length ? r.equipment.map(function (e) {
        return '<span class="recipe-tag recipe-tag--equipment">🍽 ' + esc(e) + '</span>';
      }).join('') : '');

    /* Family Combo / Multi-Goal (item 17) — see familyContext()'s comment.
       Shows only when that (currently never-populated) signal is present,
       so this never fabricates a claim about a system that doesn't exist
       yet on this build. */
    var family = familyContext();
    document.getElementById('familySection').style.display = family ? '' : 'none';
  }

  function initFilters() {
    var toggle = document.getElementById('recipeFiltersToggle');
    var panel  = document.getElementById('recipeFiltersPanel');
    toggle.addEventListener('click', function () {
      panel.style.display = panel.style.display === 'none' ? '' : 'none';
    });
    document.getElementById('applyFiltersBtn').addEventListener('click', function () {
      S.overrides = {
        meal_type:        document.getElementById('filterMealType').value || undefined,
        living_situation: document.getElementById('filterCooking').value || undefined,
        diet_type:        document.getElementById('filterDiet').value || undefined,
        fitness_goal:      document.getElementById('filterGoal').value || undefined,
      };
      if (S.overrides.meal_type) S.mealType = S.overrides.meal_type;
      document.getElementById('recipeMealLabel').textContent = mealLabel(S.mealType);
      S.shownIds = []; // a filter change is a new query, not "another" of the old one
      panel.style.display = 'none';
      fetchRecipe(false);
    });
  }

  function init() {
    var params = new URLSearchParams(window.location.search);
    S.mealType  = (params.get('meal_type') || 'breakfast').toLowerCase();
    S.mealName  = (params.get('meal_name') || '').trim();
    S.mealFoods = (params.get('foods') || '').trim();
    console.log('[RECIPE] selected meal:', S.mealName || '(none — slot only)');
    console.log('[RECIPE] meal type:', S.mealType);
    S.context  = athleteContext();
    document.getElementById('recipeMealLabel').textContent = mealLabel(S.mealType);
    document.getElementById('filterMealType').value = S.mealType;
    if (S.context.livingSituation) {
      var cookingOpt = document.getElementById('filterCooking');
      // Best-effort pre-select if the raw value happens to match an option.
      for (var i = 0; i < cookingOpt.options.length; i++) {
        if (cookingOpt.options[i].value && S.context.livingSituation.toLowerCase().indexOf(cookingOpt.options[i].value) !== -1) {
          cookingOpt.value = cookingOpt.options[i].value;
          break;
        }
      }
    }

    document.getElementById('backBtn').addEventListener('click', function () {
      window.location.href = 'diet.html';
    });
    document.getElementById('recipeRetryBtn').addEventListener('click', function () { loadRecipe(false); });
    document.getElementById('viewRecipeBtn').addEventListener('click', function () {
      renderDetail(S.current);
      showState('recipeDetail');
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });
    /* "Get Another Recipe" is meaningless once we are answering for a
       SPECIFIC dish — there is exactly one recipe for "Masala Oats with
       Vegetables", and swapping it for a different dish is the very bug
       this change fixes. Hidden rather than left to contradict itself. */
    var anotherBtn = document.getElementById('getAnotherBtn');
    if (S.mealName && anotherBtn) anotherBtn.style.display = 'none';
    anotherBtn.addEventListener('click', function () {
      loadRecipe(true).then(function (found) {
        /* Only jump straight back to the detail view when a genuinely NEW
           recipe was found — otherwise fetchRecipe() has already shown the
           correct state (recipeNone/recipeError) and re-rendering the
           previous, now-stale S.current would silently contradict it. */
        if (found) { renderDetail(S.current); showState('recipeDetail'); }
      });
    });
    initFilters();

    loadRecipe(false);
  }

  document.addEventListener('DOMContentLoaded', init);
})();
