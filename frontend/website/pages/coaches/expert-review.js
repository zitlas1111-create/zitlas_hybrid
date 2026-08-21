/* =============================================
   ZITLAS Expert Review Dashboard — expert-review.js
   ============================================= */
(function () {
  'use strict';

  /* ─── THEME ────────────────────────────────────────────────────────────── */
  (function applyTheme() {
    var t = localStorage.getItem('zitlas_theme') || 'dark';
    var r = t === 'system'
      ? (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
      : t;
    document.documentElement.setAttribute('data-theme', r);
  })();

  /* ─── TOAST ─────────────────────────────────────────────────────────────── */
  var _toastTimer;
  function showToast(msg) {
    var el = document.getElementById('erToast');
    if (!el) return;
    clearTimeout(_toastTimer);
    el.textContent = msg;
    el.classList.add('show');
    _toastTimer = setTimeout(function() { el.classList.remove('show'); }, 2800);
  }

  /* ─── UTILITIES ─────────────────────────────────────────────────────────── */
  function esc(str) {
    return String(str || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }

  function capitalize(str) {
    if (!str) return '';
    return String(str).replace(/_/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase(); });
  }

  function fmt(v, suffix) {
    return v ? (v + (suffix || '')) : '—';
  }

  /* ─── STATE ──────────────────────────────────────────────────────────────── */
  var request             = null;
  var modifiedPlan        = null;   /* diet plan — deep-cloned at load */
  var modifiedWorkoutPlan = null;   /* workout plan — deep-cloned at load */
  var changeCount         = 0;      /* diet meal changes */
  var workoutChangeCount  = 0;      /* workout day changes */
  var currentDay          = 0;

  /* ─── LOAD REQUEST ───────────────────────────────────────────────────────── */
  function loadRequest() {
    try { request = JSON.parse(localStorage.getItem('zitlas_review_request') || 'null'); } catch(_) {}

    /* ── DEBUG ── */
    console.log('[ZITLAS] reviewData:', request);
    if (request && request.context) {
      var ctx = request.context;
      console.log('[ZITLAS] assessment:', ctx.assessment || ctx.survey);
      console.log('[ZITLAS] calculations (fitness):', ctx.calculations);
      console.log('[ZITLAS] swot:', ctx.swot);
      console.log('[ZITLAS] dietPlan:', ctx.diet_plan);
      console.log('[ZITLAS] workoutPlan:', ctx.workout_plan);
      /* Check for missing fields */
      ['assessment', 'calculations', 'swot', 'diet_plan', 'workout_plan'].forEach(function(k) {
        if (!ctx[k]) console.warn('[ZITLAS] MISSING field in context:', k);
      });
    } else {
      console.warn('[ZITLAS] No request or no context — nothing to render');
    }

    if (!request) {
      var emptyEl = document.getElementById('erEmpty');
      if (emptyEl) emptyEl.style.display = 'flex';
      return;
    }

    /* Deep-clone the diet plan for editing */
    try { modifiedPlan = JSON.parse(JSON.stringify(request.context.diet_plan || null)); } catch(_) { modifiedPlan = null; }

    /* Deep-clone the workout plan for editing (same pattern as diet plan) */
    try { modifiedWorkoutPlan = JSON.parse(JSON.stringify((request.context || {}).workout_plan || null)); } catch(_) { modifiedWorkoutPlan = null; }

    var contentEl = document.getElementById('erContent');
    var footerEl  = document.getElementById('erFooter');
    if (contentEl) contentEl.style.display = 'block';
    if (footerEl)  footerEl.style.display  = 'block';

    /* Header: request ID and status */
    var reqIdEl = document.getElementById('erRequestId');
    if (reqIdEl) reqIdEl.textContent = request.athlete_name
      ? (request.athlete_name + ' · ' + request.id)
      : request.id;

    var badge = document.getElementById('erStatusBadge');
    if (badge) {
      badge.textContent = capitalize(request.status || 'pending');
      badge.className   = 'er-status-badge er-status-' + (request.status || 'pending');
    }

    renderProfile();
    renderAssessment();
    renderFitnessSnapshot();
    renderSwot();
    renderUserNote();
    renderDietPlan();
    renderWorkout();
    updateChangeBar();
  }

  /* ─── PROFILE STRIP ──────────────────────────────────────────────────────── */
  function renderProfile() {
    var strip = document.getElementById('erProfileStrip');
    if (!strip) return;

    var ctx  = request.context || {};
    var a    = ctx.assessment  || ctx.survey || {};
    var c    = ctx.calculations || {};
    var name = request.athlete_name || 'Athlete';
    var bmi  = c.bmi ? parseFloat(c.bmi).toFixed(1) : '—';
    var bmiCat = c.bmi_category || 'BMI';

    strip.innerHTML =
      '<div class="er-profile-row">' +
        '<div class="er-profile-avatar">' + (a.gender === 'female' ? '👩' : '👨') + '</div>' +
        '<div class="er-profile-info">' +
          '<span class="er-profile-name">' + esc(name) + '</span>' +
          '<span class="er-profile-meta">' + esc(request.expertName || 'Expert') + ' · ' + formatDate(request.submittedAt) + '</span>' +
        '</div>' +
      '</div>' +
      '<div class="er-profile-stats">' +
        '<div class="er-ps-item"><span class="er-ps-val">' + fmt(a.age) + '</span><span class="er-ps-label">Age</span></div>' +
        '<div class="er-ps-item"><span class="er-ps-val">' + fmt(a.weight_kg, ' kg') + '</span><span class="er-ps-label">Weight</span></div>' +
        '<div class="er-ps-item"><span class="er-ps-val">' + fmt(a.goal_weight_kg, ' kg') + '</span><span class="er-ps-label">Goal Wt.</span></div>' +
        '<div class="er-ps-item"><span class="er-ps-val">' + esc(bmi) + '</span><span class="er-ps-label">' + esc(bmiCat) + '</span></div>' +
      '</div>';
  }

  /* ─── ASSESSMENT ANSWERS ─────────────────────────────────────────────────── */
  function renderAssessment() {
    var section = document.getElementById('erAssessmentSection');
    var grid    = document.getElementById('erAssessmentGrid');
    if (!section || !grid) return;

    var ctx = request.context || {};
    var a   = ctx.assessment || ctx.survey || {};

    if (!Object.keys(a).length) return;

    var rows = [
      { label: 'Age',              val: fmt(a.age, ' years') },
      { label: 'Gender',           val: capitalize(a.gender) || '—' },
      { label: 'Height',           val: fmt(a.height_cm, ' cm') },
      { label: 'Current Weight',   val: fmt(a.weight_kg, ' kg') },
      { label: 'Goal Weight',      val: fmt(a.goal_weight_kg, ' kg') },
      { label: 'Goal',             val: capitalize(a.goal) || '—' },
      { label: 'Activity Level',   val: capitalize(a.activity_level) || '—' },
      { label: 'Diet Type',        val: capitalize(a.diet_preference) || '—' },
      { label: 'Workout Location', val: capitalize(a.workout_preference) || '—' },
      { label: 'Sleep',            val: a.sleep_hours ? a.sleep_hours + ' hrs/night' : '—' },
      { label: 'Medical Conditions', val: a.medical_conditions || '—' },
    ].filter(function(r) { return r.val && r.val !== '—'; });

    grid.innerHTML = rows.map(function(r) {
      return '<div class="er-assess-item">' +
        '<span class="er-assess-label">' + esc(r.label) + '</span>' +
        '<span class="er-assess-val">' + esc(r.val) + '</span>' +
      '</div>';
    }).join('');

    section.style.display = 'block';
  }

  /* ─── FITNESS SNAPSHOT ───────────────────────────────────────────────────── */
  function renderFitnessSnapshot() {
    var section = document.getElementById('erFitnessSection');
    var grid    = document.getElementById('erStatsGrid');
    if (!section || !grid) return;

    var c = (request.context || {}).calculations || {};
    if (!c.bmi && !c.bmr_kcal) return;

    var items = [
      { val: c.bmi ? parseFloat(c.bmi).toFixed(1) : '—',                        label: 'BMI' },
      { val: c.bmi_category || '—',                                               label: 'Category' },
      { val: c.bmr_kcal  ? Math.round(c.bmr_kcal)  + ' kcal' : '—',             label: 'BMR' },
      { val: c.tdee_kcal ? Math.round(c.tdee_kcal) + ' kcal' : '—',             label: 'TDEE' },
      { val: c.weight_loss_calories_kcal ? c.weight_loss_calories_kcal + ' kcal' : '—', label: 'Target Cal' },
      { val: c.protein_target_g ? c.protein_target_g + 'g' : '—',               label: 'Protein' },
      { val: c.water_target_liters ? c.water_target_liters + 'L' : '—',         label: 'Water' },
      { val: c.daily_steps_goal ? Number(c.daily_steps_goal).toLocaleString() : '—', label: 'Daily Steps' },
    ].filter(function(i) { return i.val !== '—'; });

    grid.innerHTML = items.map(function(i) {
      return '<div class="er-stat-card">' +
        '<span class="er-stat-val">' + esc(String(i.val)) + '</span>' +
        '<span class="er-stat-lbl">' + esc(i.label) + '</span>' +
      '</div>';
    }).join('');

    section.style.display = 'block';
  }

  /* ─── SWOT REPORT ────────────────────────────────────────────────────────── */
  function renderSwot() {
    var section = document.getElementById('erSwotSection');
    var grid    = document.getElementById('erSwotGrid');
    if (!section || !grid) return;

    var swotOuter = (request.context || {}).swot;
    if (!swotOuter) return;
    var swot = swotOuter.swot || swotOuter;

    var quadrants = [
      { key: 'strengths',     label: 'Strengths',     icon: '💪', cls: 'swot-s' },
      { key: 'weaknesses',    label: 'Weaknesses',    icon: '⚠️', cls: 'swot-w' },
      { key: 'opportunities', label: 'Opportunities', icon: '🎯', cls: 'swot-o' },
      { key: 'threats',       label: 'Threats',       icon: '🔴', cls: 'swot-t' },
    ];

    grid.innerHTML = quadrants.map(function(q) {
      var items = swot[q.key] || [];
      return '<div class="er-swot-card ' + q.cls + '">' +
        '<div class="er-swot-label">' + q.icon + ' ' + esc(q.label) + '</div>' +
        '<ul class="er-swot-list">' +
        items.map(function(item) {
          var text = typeof item === 'object' ? (item.title || '') : String(item || '');
          return '<li>' + esc(text) + '</li>';
        }).join('') +
        '</ul>' +
      '</div>';
    }).join('');

    section.style.display = 'block';
  }

  /* ─── ATHLETE NOTE ───────────────────────────────────────────────────────── */
  function renderUserNote() {
    if (!request.note) return;
    var section = document.getElementById('erNoteSection');
    var card    = document.getElementById('erNoteCard');
    if (!section || !card) return;
    card.textContent = request.note;
    section.style.display = 'block';
  }

  /* ─── DIET PLAN ──────────────────────────────────────────────────────────── */
  function renderDietPlan() {
    var section  = document.getElementById('erDietSection');
    var metaBar  = document.getElementById('erDietMetaBar');
    if (!section) return;

    if (!modifiedPlan) {
      section.style.display = 'none';
      return;
    }

    if (metaBar) {
      var cal  = modifiedPlan.daily_calories_target;
      var prot = modifiedPlan.daily_protein_target_g;
      var name = modifiedPlan.plan_name || 'AI Diet Plan';
      var sub  = [cal ? cal + ' kcal/day' : '', prot ? prot + 'g protein/day' : ''].filter(Boolean).join(' · ');
      metaBar.innerHTML = '<span class="er-plan-name-tag">' + esc(name) + '</span>' +
        (sub ? '<span class="er-plan-sub-tag">' + esc(sub) + '</span>' : '');
    }

    renderDayPills();
    renderMeals(currentDay);
    section.style.display = 'block';
  }

  /* ─── DAY PILLS ──────────────────────────────────────────────────────────── */
  function renderDayPills() {
    var container = document.getElementById('erDayPills');
    if (!container || !modifiedPlan || !modifiedPlan.days) return;

    var labels = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    container.innerHTML = modifiedPlan.days.map(function(d, i) {
      return '<button class="er-day-pill' + (i === currentDay ? ' active' : '') + '" data-day="' + i + '">' +
        esc(d.day ? d.day.slice(0,3) : (labels[i] || 'D'+(i+1))) +
      '</button>';
    }).join('');

    container.addEventListener('click', function(e) {
      var btn = e.target.closest('.er-day-pill');
      if (!btn) return;
      currentDay = parseInt(btn.dataset.day, 10);
      container.querySelectorAll('.er-day-pill').forEach(function(p) { p.classList.remove('active'); });
      btn.classList.add('active');
      renderMeals(currentDay);
    });
  }

  /* ─── MEAL LIST ──────────────────────────────────────────────────────────── */

  /* Get the original food display string from a meal */
  function getMealFoodsText(meal) {
    if (Array.isArray(meal.foods) && meal.foods.length) return meal.foods.join('\n');
    if (meal.food_items) return String(meal.food_items);
    return '';
  }

  /* Render foods as an HTML bullet list */
  function foodsToList(text) {
    var lines = text.split('\n').map(function(l) { return l.trim(); }).filter(Boolean);
    if (!lines.length) return '<em class="er-meal-empty">No food data</em>';
    return '<ul class="er-meal-foods-list">' +
      lines.map(function(l) { return '<li>' + esc(l) + '</li>'; }).join('') +
    '</ul>';
  }

  function renderMeals(dayIndex) {
    var list = document.getElementById('erMealList');
    if (!list || !modifiedPlan || !modifiedPlan.days || !modifiedPlan.days[dayIndex]) return;

    var dayData = modifiedPlan.days[dayIndex];
    var meals   = dayData.meals || [];

    /* Day header */
    var dayHdr = '';
    if (dayData.day || dayData.theme || dayData.total_calories) {
      dayHdr = '<div class="er-day-hdr">' +
        (dayData.day   ? '<span class="er-day-hdr-name">' + esc(dayData.day) + '</span>' : '') +
        (dayData.theme ? '<span class="er-day-hdr-theme">' + esc(dayData.theme) + '</span>' : '') +
        (dayData.total_calories ? '<span class="er-day-hdr-cal">' + dayData.total_calories + ' kcal total</span>' : '') +
      '</div>';
    }

    var mealsHtml = meals.map(function(meal, mi) {
      var isModified    = !!meal._modified;
      var originalText  = getMealFoodsText(meal);
      var replacementText = isModified ? (meal._replacement || '') : '';

      return '<div class="er-meal-card' + (isModified ? ' er-meal--modified' : '') + '" data-meal="' + mi + '">' +

        /* ── Meal header ── */
        '<div class="er-meal-top">' +
          '<div class="er-meal-title-row">' +
            '<span class="er-meal-emoji">' + esc(meal.emoji || '🍽️') + '</span>' +
            '<span class="er-meal-type">' + esc(meal.meal_name || 'Meal') + '</span>' +
            (meal.time ? '<span class="er-meal-time">' + esc(meal.time) + '</span>' : '') +
            (isModified ? '<span class="er-meal-modified-tag">Modified</span>' : '') +
          '</div>' +
          /* Macros */
          ((meal.calories || meal.protein_g) ?
            '<div class="er-meal-macros">' +
              (meal.calories  ? '<span class="er-macro-chip">🔥 ' + esc(String(meal.calories))  + ' kcal</span>' : '') +
              (meal.protein_g ? '<span class="er-macro-chip">💪 ' + esc(String(meal.protein_g)) + 'g protein</span>' : '') +
            '</div>' : '') +
        '</div>' +

        /* ── Current meal ── */
        '<div class="er-meal-section">' +
          '<div class="er-meal-section-label">Current Meal</div>' +
          '<div class="er-meal-foods-wrap">' + foodsToList(originalText) + '</div>' +
        '</div>' +

        /* ── Expert replacement ── */
        '<div class="er-meal-section er-meal-edit-wrap">' +
          '<label class="er-meal-section-label">Expert Replacement</label>' +
          '<textarea class="er-meal-edit-input" data-day="' + dayIndex + '" data-meal="' + mi + '" ' +
            'placeholder="Enter replacement foods, one per line… (leave blank to keep)" rows="3">' +
            esc(replacementText) +
          '</textarea>' +
          '<label class="er-meal-section-label" style="margin-top:8px">Reason</label>' +
          '<input class="er-meal-note-input" type="text" ' +
            'data-day="' + dayIndex + '" data-meal="' + mi + '" ' +
            'placeholder="e.g. Vegetarian alternative" ' +
            'value="' + esc(meal._note || '') + '" />' +
        '</div>' +

      '</div>';
    }).join('');

    list.innerHTML = dayHdr + mealsHtml;

    /* Wire change listeners */
    list.querySelectorAll('.er-meal-edit-input').forEach(function(ta) {
      ta.addEventListener('input', function() {
        applyMealEdit(parseInt(ta.dataset.day, 10), parseInt(ta.dataset.meal, 10), ta.value.trim());
      });
    });
    list.querySelectorAll('.er-meal-note-input').forEach(function(inp) {
      inp.addEventListener('input', function() {
        var meal = modifiedPlan.days[parseInt(inp.dataset.day, 10)].meals[parseInt(inp.dataset.meal, 10)];
        if (meal) meal._note = inp.value;
      });
    });
  }

  /* ─── APPLY MEAL EDIT ────────────────────────────────────────────────────── */
  function applyMealEdit(dayIndex, mealIndex, newText) {
    var meal = modifiedPlan.days[dayIndex].meals[mealIndex];
    if (!meal) return;

    /* Preserve original on first edit */
    if (!meal._originalFoods) {
      meal._originalFoods = Array.isArray(meal.foods) ? meal.foods.slice() : [];
      meal._original      = getMealFoodsText(meal);
    }

    var wasModified = meal._modified;

    if (newText) {
      meal._replacement = newText;
      meal.food_items   = newText;
      meal.foods        = newText.split('\n').map(function(f) { return f.trim(); }).filter(Boolean);
      meal._modified    = true;
    } else {
      meal._replacement = '';
      meal.food_items   = meal._original;
      meal.foods        = meal._originalFoods;
      meal._modified    = false;
    }

    if (wasModified !== meal._modified) recountChanges();

    /* Update card visual without full re-render */
    var card = document.querySelector('.er-meal-card[data-meal="' + mealIndex + '"]');
    if (card) {
      card.classList.toggle('er-meal--modified', !!meal._modified);
      var tag = card.querySelector('.er-meal-modified-tag');
      if (meal._modified && !tag) {
        var titleRow = card.querySelector('.er-meal-title-row');
        if (titleRow) {
          var s = document.createElement('span');
          s.className   = 'er-meal-modified-tag';
          s.textContent = 'Modified';
          titleRow.appendChild(s);
        }
      } else if (!meal._modified && tag) {
        tag.remove();
      }
    }
  }

  /* ─── RECOUNT + CHANGE BAR ───────────────────────────────────────────────── */
  function recountChanges() {
    changeCount = 0;
    if (!modifiedPlan || !modifiedPlan.days) return;
    modifiedPlan.days.forEach(function(day) {
      (day.meals || []).forEach(function(meal) { if (meal._modified) changeCount++; });
    });
    updateChangeBar();
  }

  function updateChangeBar() {
    var bar   = document.getElementById('erChangeBar');
    var count = document.getElementById('erChangeCount');
    if (count) count.textContent = changeCount + (changeCount === 1 ? ' change' : ' changes');
    if (bar)   bar.classList.toggle('er-change-bar--active', changeCount > 0);
  }

  /* ─── WORKOUT PLAN (editable — mirrors diet review architecture) ─────────── */
  function renderWorkout() {
    var section = document.getElementById('erWorkoutSection');
    var wrap    = document.getElementById('erWorkoutWrap');
    if (!section || !wrap) return;

    if (!modifiedWorkoutPlan) return;

    var wDays = modifiedWorkoutPlan.weekly_plan     ||
                modifiedWorkoutPlan.days             ||
                modifiedWorkoutPlan.weekly_schedule  ||
                modifiedWorkoutPlan.workout_days     || [];
    if (!wDays.length) return;

    var dayLabels = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    wrap.innerHTML = '';

    /* Plan name bar */
    if (modifiedWorkoutPlan.plan_name || modifiedWorkoutPlan.goal) {
      var nameBar = document.createElement('div');
      nameBar.className = 'er-workout-name-bar';
      nameBar.innerHTML =
        (modifiedWorkoutPlan.plan_name ? '<span class="er-plan-name-tag">' + esc(modifiedWorkoutPlan.plan_name) + '</span>' : '') +
        (modifiedWorkoutPlan.goal      ? '<span class="er-plan-sub-tag">'  + esc(modifiedWorkoutPlan.goal)      + '</span>' : '');
      wrap.appendChild(nameBar);
    }

    wDays.forEach(function(d, i) {
      var activity  = d.focus || d.theme || d.type || d.activity || 'Training';
      var durVal    = d.duration_minutes != null ? String(d.duration_minutes) : '';
      var isRest    = /rest|recovery/i.test(activity);
      var exercises = d.exercises || d.drills || [];
      var tip       = d.daily_tip || d.tip || '';
      var label     = d.day ? d.day : (dayLabels[i] || 'Day ' + (i + 1));
      var existNote = d._expertNote || '';

      /* ── Editable exercise rows ── */
      var exHtml = '';
      if (exercises.length) {
        exHtml += '<div class="er-wd-exercises">';
        exercises.forEach(function(ex, j) {
          var exName = ex.name || ex.drill_name || '';
          var exSets = ex.sets != null ? String(ex.sets) : '';
          var exReps = ex.reps_or_duration || ex.reps || ex.duration || '';
          var exTip  = ex.tip || ex.notes || '';

          exHtml +=
            '<div class="er-wd-exercise er-wd-exercise--edit">' +
              /* Exercise name — editable */
              '<input class="er-wd-edit-input er-wd-ex-name" type="text"' +
                ' data-wo-day="' + i + '" data-wo-ex="' + j + '" data-wo-field="name"' +
                ' data-wo-original="' + esc(exName) + '"' +
                ' value="' + esc(exName) + '" placeholder="Exercise name" />' +
              /* Sets + Reps row */
              '<div class="er-wd-ex-meta-row">' +
                '<input class="er-wd-edit-input er-wd-ex-meta" type="text"' +
                  ' data-wo-day="' + i + '" data-wo-ex="' + j + '" data-wo-field="sets"' +
                  ' data-wo-original="' + esc(exSets) + '"' +
                  ' value="' + esc(exSets) + '" placeholder="Sets" />' +
                '<input class="er-wd-edit-input er-wd-ex-meta" type="text"' +
                  ' data-wo-day="' + i + '" data-wo-ex="' + j + '" data-wo-field="reps_or_duration"' +
                  ' data-wo-original="' + esc(exReps) + '"' +
                  ' value="' + esc(exReps) + '" placeholder="Reps / Duration" />' +
              '</div>' +
              /* Exercise tip — editable */
              '<input class="er-wd-edit-input er-wd-ex-tip" type="text"' +
                ' data-wo-day="' + i + '" data-wo-ex="' + j + '" data-wo-field="tip"' +
                ' data-wo-original="' + esc(exTip) + '"' +
                ' value="' + esc(exTip) + '" placeholder="Tip (optional)" />' +
            '</div>';
        });
        exHtml += '</div>';
      }

      var card = document.createElement('div');
      card.className = 'er-workout-day-card' + (isRest ? ' er-wd-rest' : '');
      card.innerHTML =
        '<div class="er-wd-header">' +
          '<div class="er-wd-day-col">' +
            '<span class="er-wd-day-name">' + esc(label) + '</span>' +
          '</div>' +
          '<div class="er-wd-info-col">' +
            /* Activity / focus — editable */
            '<input class="er-wd-edit-input er-wd-activity-input" type="text"' +
              ' data-wo-day="' + i + '" data-wo-field="focus"' +
              ' data-wo-original="' + esc(activity) + '"' +
              ' value="' + esc(activity) + '" placeholder="Workout / Activity" />' +
            /* Duration — editable */
            '<input class="er-wd-edit-input er-wd-dur-input" type="number" min="0"' +
              ' data-wo-day="' + i + '" data-wo-field="duration"' +
              ' data-wo-original="' + esc(durVal) + '"' +
              ' value="' + esc(durVal) + '" placeholder="Duration (min)" />' +
          '</div>' +
        '</div>' +
        exHtml +
        (tip ? '<div class="er-wd-tip">💡 ' + esc(tip) + '</div>' : '') +
        /* Expert note — optional annotation (dashed, like before) */
        '<div class="er-wd-notes-wrap">' +
          '<input class="er-wd-notes-input" type="text"' +
            ' data-wo-day="' + i + '" data-wo-field="note"' +
            ' value="' + esc(existNote) + '"' +
            ' placeholder="Expert note for ' + esc(label) + '… (optional)" />' +
        '</div>';

      wrap.appendChild(card);
    });

    section.style.display = 'block';
  }

  /* ─── PUBLISH REVISED PLAN ──────────────────────────────────────────────── */
  function initApprove() {
    var btn = document.getElementById('erApproveBtn');
    if (!btn) return;

    btn.addEventListener('click', function() {
      if (!request) return;

      btn.textContent = 'Publishing…';
      btn.disabled    = true;

      recountChanges();

      var expertNotes = (document.getElementById('erExpertNotes') || {}).value || '';
      var reviewedBy  = request.expertName || request.expertId || 'Expert';
      var reviewedAt  = new Date().toISOString();

      /* ── Build modifiedDietPlan ──
         Keep _modified / _replacement / _originalFoods so athlete page
         can diff original vs expert version. Strip only the UI-only keys. */
      var modifiedDietPlan = null;
      if (modifiedPlan) {
        modifiedDietPlan = JSON.parse(JSON.stringify(modifiedPlan));
        modifiedDietPlan.days.forEach(function(day) {
          (day.meals || []).forEach(function(meal) {
            delete meal._note;   /* expert's reason is already saved in meal._replacement text */
          });
        });
      }

      /* ── Collect expert edits from workout inputs ──
         modifiedWorkoutPlan was deep-cloned at loadRequest time (same pattern
         as the diet modifiedPlan). Read all inputs tagged with [data-wo-day]
         and write their values back into modifiedWorkoutPlan before saving. */
      workoutChangeCount = 0;
      if (modifiedWorkoutPlan) {
        var wDaysArr = modifiedWorkoutPlan.weekly_plan    ||
                       modifiedWorkoutPlan.days            ||
                       modifiedWorkoutPlan.weekly_schedule ||
                       modifiedWorkoutPlan.workout_days    || [];

        document.querySelectorAll('[data-wo-day][data-wo-field]').forEach(function(inp) {
          var dayIdx = parseInt(inp.dataset.woDay, 10);
          if (isNaN(dayIdx) || !wDaysArr[dayIdx]) return;

          var exStr  = inp.dataset.woEx;         /* undefined = day-level */
          var field  = inp.dataset.woField;
          var val    = inp.value.trim();
          var orig   = inp.dataset.woOriginal !== undefined ? inp.dataset.woOriginal : '';

          if (exStr !== undefined && exStr !== '') {
            /* Exercise-level field */
            var exIdx     = parseInt(exStr, 10);
            var exercises = wDaysArr[dayIdx].exercises || wDaysArr[dayIdx].drills || [];
            if (!isNaN(exIdx) && exercises[exIdx]) {
              exercises[exIdx][field] = val;
              if (val !== orig && !wDaysArr[dayIdx]._modified) {
                wDaysArr[dayIdx]._modified = true;
                workoutChangeCount++;
              }
            }
          } else {
            /* Day-level field */
            if (field === 'focus') {
              wDaysArr[dayIdx].focus = val || wDaysArr[dayIdx].focus;
              if (val !== orig && !wDaysArr[dayIdx]._modified) {
                wDaysArr[dayIdx]._modified = true;
                workoutChangeCount++;
              }
            } else if (field === 'duration') {
              var durNum = parseInt(val, 10);
              if (!isNaN(durNum)) wDaysArr[dayIdx].duration_minutes = durNum;
              if (val !== orig && !wDaysArr[dayIdx]._modified) {
                wDaysArr[dayIdx]._modified = true;
                workoutChangeCount++;
              }
            } else if (field === 'note') {
              if (val) wDaysArr[dayIdx]._expertNote = val;
            }
          }
        });
      }

      /* ── Full diagnostic dump before save ── */
      var savePlanId = request.planId || localStorage.getItem('zitlas_plan_id') || null;
      console.log('SAVING REVIEWED PLAN', modifiedWorkoutPlan);
      console.log('[EXPERT] planId being saved:', savePlanId, '| request.planId:', request.planId, '| local planId:', localStorage.getItem('zitlas_plan_id'));
      console.log('[EXPERT] modifiedWorkoutPlan is null?', modifiedWorkoutPlan === null);
      if (modifiedWorkoutPlan) {
        var _dbgDays = modifiedWorkoutPlan.weekly_plan || modifiedWorkoutPlan.days || modifiedWorkoutPlan.weekly_schedule || modifiedWorkoutPlan.workout_days || [];
        console.log('[EXPERT] days count:', _dbgDays.length);
        if (_dbgDays[4]) console.log('[EXPERT] Friday (index 4):', JSON.stringify(_dbgDays[4]));
        else console.log('[EXPERT] WARNING: no day at index 4 — total days:', _dbgDays.length, '| keys:', JSON.stringify(_dbgDays.map(function(d,i){ return i + ':' + (d.day || d.focus || '?'); })));
      }
      console.log('SAVING REVIEW', modifiedWorkoutPlan);
      console.log('TRAINING REVIEW SAVED', modifiedWorkoutPlan);

      /* ── Write zitlas_expert_review ──
         This is the dedicated sync key the athlete page reads.
         Do NOT overwrite zitlas_diet_plan — keep original AI plan intact.
         Use request.planId (athlete's planId) — not expert's localStorage —
         so diet.js / day.js planId guards match correctly. */
      var expertReview = {
        planId:              savePlanId,
        reviewId:            request.id,
        athleteId:           request.athleteId || request.userId || null,
        expertId:            request.expertId  || null,
        modifiedDietPlan:    modifiedDietPlan,
        modifiedWorkoutPlan: modifiedWorkoutPlan,
        status:              'APPROVED',
        reviewedBy:          reviewedBy,
        reviewedAt:          reviewedAt,
        expertNotes:         expertNotes,
        changeCount:         changeCount + workoutChangeCount,
      };

      console.log('[ZITLAS] Expert Plan Saved', modifiedDietPlan);
      console.log('[ZITLAS] Expert Workout Saved', modifiedWorkoutPlan);

      try { localStorage.setItem('zitlas_expert_review', JSON.stringify(expertReview)); } catch(_) {}

      /* ── Update plan version history ── */
      var versions = [];
      try { versions = JSON.parse(localStorage.getItem('zitlas_plan_versions') || '[]'); } catch(_) {}
      if (!versions.length) {
        /* Create Version 1 (AI Generated) entry if missing */
        var hasAiPlan = !!(
          localStorage.getItem('zitlas_diet_plan') ||
          localStorage.getItem('zitlas_workout_plan')
        );
        if (hasAiPlan) {
          versions.push({ version: 1, type: 'ai_generated', createdAt: localStorage.getItem('zitlas_plan_generated_at') || reviewedAt });
        }
      }
      versions.push({
        version:            versions.length + 1,
        type:               'expert_revised',
        expertName:         reviewedBy,
        createdAt:          reviewedAt,
        changeCount:        changeCount,
        workoutChangeCount: workoutChangeCount,
      });
      try { localStorage.setItem('zitlas_plan_versions', JSON.stringify(versions)); } catch(_) {}

      /* ── Update review request status ── */
      request.status     = 'APPROVED';
      request.reviewedBy = reviewedBy;
      request.reviewedAt = reviewedAt;
      request.approvedAt = reviewedAt;
      try { localStorage.setItem('zitlas_review_request', JSON.stringify(request)); } catch(_) {}

      /* ── Firestore sync ── */
      if (typeof ZitlasDB !== 'undefined' && typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser && request.id) {
        var firestoreUpdate = {
          status:             'APPROVED',
          reviewedBy:         reviewedBy,
          reviewedAt:         reviewedAt,
          changeCount:        changeCount,
          workoutChangeCount: workoutChangeCount,
          expertNotes:        expertNotes,
        };
        ZitlasDB.collection('review_requests').doc(request.id).update(firestoreUpdate)
          .catch(function(e) { console.warn('[ZITLAS] Firestore status update failed:', e); });

        ZitlasDB.collection('expert_reviews').doc(request.id).set(
          Object.assign({}, expertReview, { savedAt: firebase.firestore.FieldValue.serverTimestamp() })
        ).catch(function(e) { console.warn('[ZITLAS] Firestore expert_review save failed:', e); });
      }

      var badge = document.getElementById('erStatusBadge');
      if (badge) { badge.textContent = 'Approved'; badge.className = 'er-status-badge er-status-approved'; }

      var toastParts = [];
      if (changeCount)       toastParts.push(changeCount + ' meal ' + (changeCount !== 1 ? 'changes' : 'change'));
      if (workoutChangeCount) toastParts.push(workoutChangeCount + ' workout ' + (workoutChangeCount !== 1 ? 'days' : 'day'));
      showToast('Plan approved' + (toastParts.length ? ' — ' + toastParts.join(', ') : '') + ' · user will see updated plan');

      setTimeout(function() {
        btn.textContent      = 'Plan Approved ✓';
        btn.style.background = 'var(--success)';
      }, 600);
    });
  }

  /* ─── BACK BUTTON ────────────────────────────────────────────────────────── */
  function initBack() {
    var btn = document.getElementById('backBtn');
    if (!btn) return;
    btn.addEventListener('click', function() {
      if (document.referrer) { history.back(); } else { window.location.href = '../experts/expert-dashboard.html'; }
    });
  }

  /* ─── DATE FORMAT ────────────────────────────────────────────────────────── */
  function formatDate(iso) {
    if (!iso) return '';
    try {
      return new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
    } catch(_) { return iso; }
  }

  /* ─── INIT ───────────────────────────────────────────────────────────────── */
  function init() {
    loadRequest();
    initApprove();
    initBack();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
