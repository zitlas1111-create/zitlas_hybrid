/*!
 * ZITLAS — Zino AI Companion (assets/js/zino.js)
 *
 * Self-mounting on every page that includes this script + zino.css.
 * Three cooperating pieces, all in this one file:
 *
 *   TutorialEngine + GuideStep  — first-time spotlight walkthrough. Steps
 *     span multiple real page loads; progress is persisted in localStorage
 *     so "Next" can navigate to a different page and resume exactly where
 *     it left off. Runs ONCE ever (zitlas_zino_tutorial_completed).
 *
 *   ZinoManager  — builds the athlete context snapshot (goal, calculations,
 *     SWOT, diet/workout summaries, coaching status, medical conditions,
 *     today's health status, streak) from localStorage (+ an optional live
 *     Firestore read when available) and talks to POST /api/ai/zino-chat.
 *
 *   FloatingAssistant + ZinoOverlay  — the permanent small circular button
 *     and the chat window it opens. Not fullscreen — a rounded floating
 *     card, ChatGPT-style.
 *
 * Nothing here touches existing page logic — it only reads localStorage/
 * Firestore and injects its own DOM subtree.
 */
(function (win) {
  'use strict';

  var ASSET = '../../assets/'; /* overridden per-page below via data attribute */
  var scriptEl = document.currentScript;
  if (scriptEl) {
    var m = scriptEl.getAttribute('src').match(/^(.*assets\/)js\/zino\.js/);
    if (m) ASSET = m[1];
  }
  var IMG = { fab: ASSET + 'zino.png', intro: ASSET + 'zino_intro.png', done: ASSET + 'zino_done.png' };

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function safeJSON(key, fallback) {
    try { var v = JSON.parse(localStorage.getItem(key) || 'null'); return v == null ? (fallback || null) : v; }
    catch (_) { return fallback || null; }
  }
  function myUid() {
    if (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) return ZitlasAuth.currentUser.uid;
    var fb = safeJSON('zitlas_firebase_user');
    return (fb && fb.uid) || localStorage.getItem('zitlas_athlete_id') || null;
  }
  function myName() {
    var fb = safeJSON('zitlas_firebase_user');
    return (fb && (fb.displayName || fb.name)) || 'User';
  }

  /* ══════════════════════════════════════════════
     ZinoManager — context + backend chat
  ══════════════════════════════════════════════ */
  var ZinoManager = (function () {
    var _coachingCache = null; /* filled async if ZitlasDB is on this page */

    function refreshCoachingStatus() {
      if (typeof ZitlasDB === 'undefined') return;
      var uid = myUid();
      if (!uid) return;
      ZitlasDB.collection('personal_coaching').doc(uid).get().then(function (snap) {
        _coachingCache = snap.exists ? snap.data() : null;
      }).catch(function () {});
    }

    function summarizeDiet(plan) {
      if (!plan) return null;
      var flat = plan.currentDietPlan || plan.originalDietPlan || plan;
      if (!flat || !flat.days) return null;
      var today = flat.days[new Date().getDay() === 0 ? 6 : new Date().getDay() - 1] || flat.days[0];
      return {
        totalDays: flat.days.length,
        isCoachManaged: !!(plan.isExpertPlan || plan.expertModifications),
        todayMeals: (today && today.meals || []).map(function (m) {
          return { name: m.meal_name, foods: m.foods };
        }),
      };
    }
    function summarizeWorkout(plan) {
      if (!plan) return null;
      var flat = plan.currentWorkoutPlan || plan.originalWorkoutPlan || plan;
      var days = flat && (flat.weekly_plan || flat.days) || [];
      if (!days.length) return null;
      var today = days[new Date().getDay() === 0 ? 6 : new Date().getDay() - 1] || days[0];
      return {
        totalDays: days.length,
        isCoachManaged: !!(plan.isExpertPlan || plan.workoutModifications),
        todayFocus: today && (today.focus || today.type),
      };
    }

    /* ── Page awareness — where the athlete IS right now ──
       Zino must answer "who do I send it to?" on the Experts page like a
       coach standing next to the user, not like a chatbot with amnesia. */
    var _PAGE_MAP = [
      { re: /\/dashboard\/dashboard/,   name: 'Home Dashboard',    purpose: 'overview: goal progress, today’s steps, SWOT, health status check-in' },
      { re: /\/weekly-plan/,            name: 'Training Plan',     purpose: 'the weekly workout plan — user questions here are usually about exercises, skipping, replacing, or making workouts easier/harder' },
      { re: /\/diet\/diet/,             name: 'Diet Plan',         purpose: 'the 7-day meal plan — user questions here are usually about foods, replacing meals (Swap Meal button on each meal card), or requesting an expert diet review' },
      { re: /\/coaches\/cprofile/,      name: 'Expert Profile',    purpose: 'viewing one specific expert — user can Chat, hire as Personal Coach, or Request Review of their diet/workout plan from this page' },
      { re: /\/coaches\/coaches/,       name: 'Experts Directory', purpose: 'browsing verified experts — user questions here are usually about WHICH expert to pick or send a review/verification request to' },
      { re: /\/profile\/profile/,       name: 'My Profile',        purpose: 'account settings, personal info, wallet' },
    ];
    function currentPage() {
      var p = win.location.pathname;
      for (var i = 0; i < _PAGE_MAP.length; i++) {
        if (_PAGE_MAP[i].re.test(p)) return { name: _PAGE_MAP[i].name, purpose: _PAGE_MAP[i].purpose };
      }
      return { name: 'ZITLAS app', purpose: '' };
    }

    /* Experts cached at login (zitlas_experts) — lets Zino recommend a
       specific person by name instead of "browse the experts page". */
    function availableExperts() {
      var list = safeJSON('zitlas_experts');
      if (!Array.isArray(list) || !list.length) return undefined;
      return list.slice(0, 8).map(function (e) {
        return { name: e.name, specialization: e.specialization || e.role || 'Expert' };
      });
    }

    /* On an Expert Profile page, name the expert being viewed */
    function viewingExpert() {
      if (!/\/coaches\/cprofile/.test(win.location.pathname)) return undefined;
      var id = new URLSearchParams(win.location.search).get('expertId') ||
               new URLSearchParams(win.location.search).get('id');
      if (!id) return undefined;
      var list = safeJSON('zitlas_experts') || [];
      var e = list.find(function (x) { return String(x.id) === String(id); });
      return e ? { name: e.name, specialization: e.specialization || 'Expert' } : undefined;
    }

    /* The active review request + whether its result is waiting to be
       accepted — so "the request" / "my review" always has a referent. */
    function reviewRequestContext() {
      var req = safeJSON('zitlas_review_request');
      if (!req || !req.id) return undefined;
      var experts = safeJSON('zitlas_experts') || [];
      var exp = experts.find(function (x) { return String(x.id) === String(req.expertId); });
      var out = { status: req.status || 'pending', expertName: exp ? exp.name : undefined };
      var all = safeJSON('expert_plan_reviews') || [];
      var done = all.find(function (r) {
        return r.id === req.id && (r.status === 'review_completed' || r.status === 'completed');
      });
      if (done) {
        out.status = done.athleteAccepted ? 'completed_and_accepted' : 'completed_awaiting_your_acceptance';
        out.expertName = done.expertName || out.expertName;
      }
      return out;
    }

    function buildContext() {
      var assessment = safeJSON('zitlas_assessment') || safeJSON('zitlas_survey');
      var calc = safeJSON('zitlas_calculations');
      var swot = safeJSON('zitlas_swot');
      var goal = safeJSON('zitlas_goal');
      var precautions = safeJSON('zitlas_precautions');
      var healthToday = safeJSON('zitlas_health_today');
      var streak = (typeof ZitlasStreak !== 'undefined' && ZitlasStreak.getStreak) ? ZitlasStreak.getStreak() : null;

      var loc = safeJSON('zitlas_location');
      var ctx = {
        athleteName: myName(),
        today: new Date().toLocaleDateString('en-IN', { weekday: 'long', day: 'numeric', month: 'short' }),
        /* Where the user is RIGHT NOW — anchor ambiguous questions here */
        current_page: currentPage(),
        viewing_expert: viewingExpert(),
        experts_available: availableExperts(),
        review_request: reviewRequestContext(),
        region: loc && (loc.city || loc.state) ? { city: loc.city, state: loc.state } : undefined,
        goal: goal || undefined,
        bmi: calc && calc.bmi, bmi_category: calc && calc.bmi_category,
        bmr_kcal: calc && calc.bmr_kcal, tdee_kcal: calc && calc.tdee_kcal,
        target_calories_kcal: calc && (calc.weight_loss_calories_kcal || calc.target_calories_kcal),
        protein_target_g: calc && calc.protein_target_g,
        water_target_l: calc && calc.water_target_liters,
        daily_steps_goal: calc && calc.daily_steps_goal,
        swot_summary: swot && swot.swot ? {
          top_strength: swot.swot.strengths && swot.swot.strengths[0] && swot.swot.strengths[0].title,
          top_weakness: swot.swot.weaknesses && swot.swot.weaknesses[0] && swot.swot.weaknesses[0].title,
          archetype: swot.user_archetype,
        } : undefined,
        medical_conditions: (assessment && assessment.medical_conditions) || 'none',
        precautions_today: precautions && precautions.precautions,
        diet: summarizeDiet(safeJSON('zitlas_diet_plan')) || undefined,
        workout: summarizeWorkout(safeJSON('zitlas_workout_plan')) || undefined,
        current_mood_status: healthToday && healthToday.date === new Date().toISOString().slice(0, 10)
          ? { status: healthToday.status, safety: healthToday.safety } : 'feeling normal / not reported today',
        streak_days: streak && streak.currentStreak,
        /* Live step tracking (activity-service.js) — lets Zino say things
           like "only 1,577 steps to go" or suggest an evening walk. */
        activity_today: (function () {
          var A = window.ZitlasActivity;
          if (!A) return undefined;
          var t = A.getToday();
          var eff = A.getEffectiveGoal ? A.getEffectiveGoal() : { goal: A.getDailyGoal(), recovery: false, rest: false };
          return {
            steps: t.steps,
            step_goal: eff.goal,
            goal_pct: eff.goal > 0 ? Math.round((t.steps / eff.goal) * 100) : 100,
            steps_remaining: Math.max(0, eff.goal - t.steps),
            distance_km: t.distance,
            calories_burned: t.calories,
            recovery_mode: eff.recovery,
            rest_day: eff.rest,
            goal_suggestion: A.getAdaptiveGoalSuggestion ? (A.getAdaptiveGoalSuggestion() || undefined) : undefined,
          };
        })(),
        personal_coaching: _coachingCache && _coachingCache.status === 'active'
          ? { active: true, coachName: _coachingCache.coachName, planType: _coachingCache.planType }
          : { active: false },
      };
      Object.keys(ctx).forEach(function (k) { if (ctx[k] === undefined) delete ctx[k]; });
      return ctx;
    }

    /* Defense-in-depth: the backend already unwraps a model's occasional
       self-wrapped JSON reply (unwrap_conversational_reply in
       groq_service.py), but a chat bubble must NEVER render raw JSON even
       if that layer ever regresses or a future endpoint skips it. Plain
       prose (the overwhelming common case) returns from this unchanged —
       JSON.parse throws immediately on non-JSON text. */
    var REPLY_KEYS = ['response', 'message', 'answer', 'reply', 'text', 'content'];
    function unwrapReply(raw) {
      if (typeof raw !== 'string' || !raw) return raw;
      var trimmed = raw.trim();
      if (!trimmed) return raw;
      var candidate = trimmed;
      var fence = /^```(?:json)?\s*([\s\S]*?)\s*```$/.exec(trimmed);
      if (fence) candidate = fence[1].trim();
      if (!candidate || (candidate[0] !== '{' && candidate[0] !== '"')) return raw;
      var parsed;
      try { parsed = JSON.parse(candidate); } catch (_) { return raw; }
      if (typeof parsed === 'string') return parsed;
      if (parsed && typeof parsed === 'object') {
        for (var i = 0; i < REPLY_KEYS.length; i++) {
          if (typeof parsed[REPLY_KEYS[i]] === 'string' && parsed[REPLY_KEYS[i]].trim()) {
            return parsed[REPLY_KEYS[i]];
          }
        }
        var strVals = Object.keys(parsed).map(function (k) { return parsed[k]; })
          .filter(function (v) { return typeof v === 'string' && v.trim(); });
        if (strVals.length === 1) return strVals[0];
        console.warn('[ZINO] backend returned an unrecognized object shape — using fallback message', parsed);
        return "Sorry, I got a bit tangled up there 😅 Could you ask that again?";
      }
      return raw;
    }

    function send(message, history) {
      var body = { message: message, context: buildContext(), history: history || [] };
      return fetch('/api/ai/zino-chat', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      }).then(function (r) {
        if (!r.ok) throw new Error('Zino is having trouble connecting (' + r.status + ')');
        return r.json();
      }).then(function (data) { return unwrapReply(data.reply); });
    }

    refreshCoachingStatus();
    return { buildContext: buildContext, send: send };
  })();

  /* ══════════════════════════════════════════════
     TUTORIAL ENGINE — spotlight walkthrough
  ══════════════════════════════════════════════ */
  var TutorialEngine = (function () {
    var STATE_KEY = 'zitlas_zino_tour_state';
    var DONE_KEY  = 'zitlas_zino_tutorial_completed';

    /* Each stop: { id, page (pathname substring, '' = any page),
       url (absolute path to navigate to if not already there),
       selector (element to spotlight; null = full-slide intro/finish),
       title, body, hero (image key for full slides) } */
    var STOPS = [
      { id: 'intro', page: 'dashboard.html', hero: 'intro',
        title: "👋 Hey! Welcome to ZITLAS.",
        body: "I'm Zino, your personal AI fitness companion.\n\nI'll quickly show you how everything works. It'll only take a minute." },
      { id: 'goal', page: 'dashboard.html', selector: '#goalCard',
        title: 'Your Fitness Journey',
        body: 'This is your fitness journey. You can set your goal, track progress, and monitor everything from here.' },
      { id: 'reset-goal', page: 'dashboard.html', selector: '#goalActionBtn',
        title: 'Changed your mind?',
        body: "If your goal changes, you can reset everything here. I'll generate a completely new roadmap." },
      { id: 'health-status', page: 'dashboard.html', selector: '#healthStatusMount',
        title: 'How Are You Feeling?',
        body: "Every day you can tell me how you're feeling. I'll automatically adjust today's diet and workout.\n\nIf you have a Personal Coach, they'll be notified too." },
      { id: 'diet-today', page: 'diet.html', url: '/pages/diet/diet.html', selector: '#focusCard',
        title: "Today's Diet",
        body: 'This is your today’s AI generated diet 🍽️' },
      { id: 'diet-swap', page: 'diet.html', selector: '.swap-btn',
        title: 'Swap Meal',
        body: "If you don't like a meal, you can swap it.",
        coachExtra: 'When your Personal Coach creates a plan, Swap Meal uses ONLY the three alternatives your coach provided.' },
      { id: 'diet-snap', page: 'diet.html', selector: '.pc-checkin-btn', optional: true,
        title: 'Meal Snap',
        body: 'You can send a meal photo directly to your Personal Coach 📸' },
      { id: 'training', page: 'weekly-plan.html', url: '/pages/dashboard/weekly-plan/weekly-plan.html', selector: '#wpContent',
        title: 'Your Training Plan',
        body: 'This is your daily workout. You can see your entire weekly plan here.\n\nIf your Personal Coach updates your training, it instantly appears here — no refresh needed.' },
      { id: 'ask-expert', page: 'coaches.html', url: '/pages/coaches/coaches.html', selector: '.ask-btn',
        title: 'Connect With Experts',
        body: 'You can connect with verified experts here.\n\n"Ask Expert" is for one-time reviews — the expert checks your plan and suggests improvements, then the relationship ends.' },
      { id: 'personal-coach-diff', page: 'coaches.html', selector: '.main-content', optional: true,
        title: 'Personal Coaching',
        body: 'Personal Coaching is different — a dedicated coach who gives you unlimited chat, manages your diet AND training, reviews your meals daily, and guides your full transformation.' },
      { id: 'request-review', page: 'cprofile.html', selector: '#verifyPlanBtn',
        dynamicUrl: function () {
          var card = document.querySelector('.ask-btn[data-id]');
          return card ? '/pages/coaches/cprofile.html?expertId=' + encodeURIComponent(card.dataset.id) : null;
        },
        title: 'Request a Review',
        body: 'This sends a review request. The expert will analyse your plan and improve it.' },
      { id: 'hire-coach', page: 'cprofile.html', selector: '#personalCoachBtn',
        title: 'Hire Your Coach',
        body: 'Here you can hire your own coach — Diet Only, Training Only, or Complete Transformation.\n\nOnce accepted, your coach gets access to your profile, BMI, SWOT, medical conditions, goals, diet, training, and progress.' },
      { id: 'chat', page: 'cprofile.html', selector: '#inlineChatBtn',
        title: 'Chat Anytime',
        body: 'You can chat with your Personal Coach anytime — they create your weekly diet, weekly training, meal alternatives, and answer your questions.' },
      { id: 'profile', page: 'profile.html', url: '/pages/profile/profile.html', selector: '.profile-header',
        title: 'Your Profile',
        body: 'This is where all your personal information lives — goals, assessment, health details, medical conditions, and progress.' },
      { id: 'finish', page: 'profile.html', hero: 'done',
        title: "Awesome! You're all set.",
        body: "Remember, I'm always here if you need help.\n\nLet's build the healthiest version of you. 🚀" },
    ];

    function getState() { return safeJSON(STATE_KEY, null); }
    function setState(s) { localStorage.setItem(STATE_KEY, JSON.stringify(s)); }
    function isDone() { return localStorage.getItem(DONE_KEY) === 'true'; }
    function markDone() {
      localStorage.setItem(DONE_KEY, 'true');
      localStorage.removeItem(STATE_KEY);
      /* Persist to users/{uid}.zinoTourCompleted — the AUTHORITATIVE,
         cross-device copy (SCALAR_FIELD_MAP in cloud-sync.js). Without
         this, the flag lived only in localStorage, which the Account
         Guard wipes on every logout/switch — so returning users saw the
         tour on every single login. Covers both Finish and Skip (skip()
         funnels into finish() → here). Direct-Firestore fallback because
         Skip can be pressed on ANY tour stop, including pages that don't
         load cloud-sync (e.g. coaches.html). */
      if (typeof ZitlasCloudSync !== 'undefined') {
        ZitlasCloudSync.save('zinoTourCompleted', 'true');
      } else if (typeof ZitlasDB !== 'undefined' && typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) {
        ZitlasDB.collection('users').doc(ZitlasAuth.currentUser.uid)
          .set({ zinoTourCompleted: 'true', zinoTourCompletedUpdatedAt: new Date().toISOString() }, { merge: true })
          .catch(function (e) { console.warn('[ZINO TOUR] cloud persist failed (local flag kept)', e); });
      }
    }

    /* Resolves the signed-in uid, waiting for Firebase's async session
       restore if needed (auth is rarely settled at DOMContentLoaded). */
    function _uidWhenAuthSettles() {
      return new Promise(function (resolve) {
        if (typeof ZitlasAuth === 'undefined') { resolve(null); return; }
        if (ZitlasAuth.currentUser) { resolve(ZitlasAuth.currentUser.uid); return; }
        var settled = false;
        var unsub = ZitlasAuth.onAuthStateChanged(function (u) {
          if (settled) return;
          settled = true;
          try { unsub(); } catch (_) {}
          resolve(u ? u.uid : null);
        });
        /* Auth never settling shouldn't wedge the decision forever */
        setTimeout(function () { if (!settled) { settled = true; resolve(null); } }, 4000);
      });
    }

    /* TRUE only when this account has verifiably never completed the tour.
       maybeResume() runs at DOMContentLoaded — BEFORE cloud-sync's async
       hydrate can mirror the flag locally — so the auto-start decision
       must ask the authoritative users/{uid} doc directly. Fail-closed:
       if the check errors, DON'T start (a returning user must never be
       re-toured; a genuinely new user simply gets the tour on the next
       page load when the read succeeds). */
    function _confirmNeverToured() {
      return _uidWhenAuthSettles().then(function (uid) {
        if (isDone()) return false;              /* hydrate may have landed meanwhile */
        if (!uid || typeof ZitlasDB === 'undefined') {
          /* No signed-in account (guest/under-review session) — fall back
             to the local-only behavior this flow always had. */
          return !isDone();
        }
        return ZitlasDB.collection('users').doc(uid).get().then(function (snap) {
          var done = snap.exists && String(snap.data().zinoTourCompleted) === 'true';
          if (done) {
            /* Heal the purged local mirror so every later check is sync */
            try { localStorage.setItem(DONE_KEY, 'true'); } catch (_) {}
            return false;
          }
          return true;
        }).catch(function (e) {
          console.warn('[ZINO TOUR] remote completion check failed — not auto-starting', e);
          return false;
        });
      });
    }

    function currentPageMatches(stop) {
      return !stop.page || win.location.pathname.indexOf(stop.page) !== -1;
    }

    /* ── DOM shell ── */
    var _domReady = false;
    function ensureDom() {
      if (_domReady) return;
      _domReady = true;
      var overlay = document.createElement('div');
      overlay.className = 'zn-tut-overlay'; overlay.id = 'znTutOverlay';
      document.body.appendChild(overlay);
      var spot = document.createElement('div');
      spot.className = 'zn-spotlight'; spot.id = 'znSpotlight';
      document.body.appendChild(spot);
      var card = document.createElement('div');
      card.className = 'zn-guide-card'; card.id = 'znGuideCard';
      document.body.appendChild(card);
      var slide = document.createElement('div');
      slide.className = 'zn-slide'; slide.id = 'znSlide';
      document.body.appendChild(slide);
    }

    function hideAll() {
      var overlay = $('znTutOverlay'), spot = $('znSpotlight'), card = $('znGuideCard'), slide = $('znSlide');
      [overlay, spot, card].forEach(function (el) { if (el) { el.classList.remove('open'); } });
      if (slide) slide.classList.remove('open');
      setTimeout(function () {
        [overlay, spot, card, slide].forEach(function (el) { if (el) el.classList.remove('show'); });
      }, 260);
    }

    function goToStop(index, opts) {
      opts = opts || {};
      if (index >= STOPS.length) { finish(); return; }
      var stop = STOPS[index];

      if (!currentPageMatches(stop)) {
        var navUrl = stop.url || (stop.dynamicUrl && stop.dynamicUrl());
        if (navUrl) { setState({ index: index }); win.location.href = navUrl; }
        else { goToStop(index + 1); } /* this stop's page/data isn't reachable — skip it */
        return;
      }
      setState({ index: index });

      if (stop.hero) { renderSlide(stop, index); return; }

      var el = stop.selector ? document.querySelector(stop.selector) : null;
      if (!el && stop.optional) { goToStop(index + 1); return; }
      if (!el) {
        /* Wait briefly for async-rendered content (diet/workout pages) */
        var tries = opts.tries || 0;
        if (tries > 24) { /* ~3.6s */ goToStop(index + 1); return; }
        setTimeout(function () { goToStop(index, { tries: tries + 1 }); }, 150);
        return;
      }
      renderSpotlight(stop, el, index);
    }

    function positionSpotlight(el) {
      var r = el.getBoundingClientRect();
      var pad = 8;
      var spot = $('znSpotlight');
      spot.style.top = Math.max(8, r.top - pad) + 'px';
      spot.style.left = Math.max(8, r.left - pad) + 'px';
      spot.style.width = (r.width + pad * 2) + 'px';
      spot.style.height = (r.height + pad * 2) + 'px';
      var card = $('znGuideCard');
      var spaceBelow = win.innerHeight - r.bottom;
      if (spaceBelow > 220 || r.top < 200) {
        card.classList.remove('zn-guide-card--top'); card.classList.add('zn-guide-card--bottom');
      } else {
        card.classList.remove('zn-guide-card--bottom'); card.classList.add('zn-guide-card--top');
      }
    }

    function renderSpotlight(stop, el, index) {
      ensureDom();
      el.scrollIntoView({ block: 'center', behavior: 'smooth' });
      var overlay = $('znTutOverlay'), spot = $('znSpotlight'), card = $('znGuideCard');

      var body = stop.body;
      var coaching = ZinoManager.buildContext().personal_coaching;
      if (stop.coachExtra && coaching && coaching.active) body += '\n\n' + stop.coachExtra;

      card.innerHTML =
        '<div class="zn-guide-head">' +
          '<img class="zn-guide-avatar" src="' + IMG.fab + '" alt="Zino">' +
          '<span class="zn-guide-name">Zino</span>' +
          '<span class="zn-guide-step-dot">' + (index + 1) + ' / ' + STOPS.length + '</span>' +
        '</div>' +
        '<p class="zn-guide-title">' + esc(stop.title) + '</p>' +
        '<p class="zn-guide-body">' + esc(body) + '</p>' +
        '<div class="zn-guide-actions">' +
          '<button class="zn-guide-skip" id="znSkipBtn">Skip Tour</button>' +
          '<div class="zn-guide-spacer"></div>' +
          (index > 0 ? '<button class="zn-guide-back" id="znBackBtn">Back</button>' : '') +
          '<button class="zn-guide-next" id="znNextBtn">' + (index === STOPS.length - 1 ? 'Finish' : 'Next →') + '</button>' +
        '</div>';

      setTimeout(function () { positionSpotlight(el); }, 260);
      [overlay, spot, card].forEach(function (x) { x.classList.add('show'); });
      requestAnimationFrame(function () {
        requestAnimationFrame(function () { [overlay, spot, card].forEach(function (x) { x.classList.add('open'); }); });
      });

      $('znSkipBtn').addEventListener('click', skip);
      $('znNextBtn').addEventListener('click', function () { goToStop(index + 1); });
      var backBtn = $('znBackBtn');
      if (backBtn) backBtn.addEventListener('click', function () { goToStop(index - 1); });
    }

    function renderSlide(stop, index) {
      ensureDom();
      var slide = $('znSlide');
      var isLast = index === STOPS.length - 1;
      slide.innerHTML =
        '<img class="zn-slide-hero" src="' + IMG[stop.hero] + '" alt="Zino">' +
        '<div class="zn-slide-card">' +
          '<div class="zn-slide-bubble">' + esc(stop.title) + '\n\n' + esc(stop.body) + '</div>' +
          '<div class="zn-slide-actions">' +
            (isLast ? '' : '<button class="zn-slide-skip" id="znSlideSkip">Skip Tour</button>') +
            '<button class="zn-slide-primary" id="znSlideNext">' + (isLast ? 'Start My Journey 🚀' : 'Next →') + '</button>' +
          '</div>' +
        '</div>';
      slide.classList.add('show');
      requestAnimationFrame(function () { requestAnimationFrame(function () { slide.classList.add('open'); }); });

      var skipBtn = $('znSlideSkip');
      if (skipBtn) skipBtn.addEventListener('click', skip);
      $('znSlideNext').addEventListener('click', function () {
        slide.classList.remove('open', 'show');
        if (isLast) finish(); else goToStop(index + 1);
      });
    }

    function skip() { finish(); }
    function finish() {
      markDone();
      hideAll();
      if (win.location.pathname.indexOf('profile.html') !== -1) {
        setTimeout(function () { win.location.href = '/pages/dashboard/dashboard.html'; }, 250);
      }
    }

    function maybeResume() {
      if (isDone()) return;
      var state = getState();
      if (state && typeof state.index === 'number') {
        /* Tour already in progress — resume only if this page is the
           right stop; never hijack navigation on an unrelated page. */
        var stop = STOPS[state.index];
        if (stop && currentPageMatches(stop)) goToStop(state.index);
        return;
      }
      /* Never started locally: auto-begin ONLY from the dashboard — the
         natural first landing page — and ONLY after confirming against
         users/{uid} that this ACCOUNT has never completed/skipped the
         tour. The local flag alone is not evidence of a new user: the
         Account Guard purges it on every logout/account switch, and a
         new device never had it. */
      if (win.location.pathname.indexOf('dashboard.html') !== -1 || win.location.pathname === '/') {
        _confirmNeverToured().then(function (neverToured) {
          if (!neverToured) return;
          /* Re-check in-progress state — another tab may have started */
          if (isDone() || getState()) return;
          goToStop(0);
        });
      }
    }

    return { maybeResume: maybeResume, isDone: isDone };
  })();

  /* ══════════════════════════════════════════════
     FLOATING ASSISTANT + CHAT OVERLAY
  ══════════════════════════════════════════════ */
  var FloatingAssistant = (function () {
    /* [{role:'user'|'zino', text}] — persisted per browser session so the
       conversation SURVIVES page navigation: "I want to verify my diet"
       said on the Diet page must still be in memory when the athlete asks
       "who do I send it to?" on the Experts page a moment later. */
    var HISTORY_KEY = 'zitlas_zino_history';
    var _history = (function () {
      try { var v = JSON.parse(sessionStorage.getItem(HISTORY_KEY) || '[]'); return Array.isArray(v) ? v : []; }
      catch (_) { return []; }
    })();
    function _persistHistory() {
      try { sessionStorage.setItem(HISTORY_KEY, JSON.stringify(_history)); } catch (_) {}
    }
    var _busy = false;

    var CHIPS = [
      { icon: '🍽', label: "Explain Today's Diet", q: "Can you explain today's diet plan and why it's set up this way?" },
      { icon: '🏋', label: 'Explain Workout', q: "Can you explain today's workout?" },
      { icon: '📊', label: 'My Progress', q: 'Summarize my progress so far.' },
      { icon: '💧', label: 'Water Target', q: "What's my water target for today?" },
      { icon: '😴', label: 'Sleep Tips', q: 'Any tips to help me sleep better?' },
      { icon: '🤒', label: "I'm Sick Today", q: "I'm not feeling well today, what should I do?" },
      { icon: '👨‍⚕️', label: 'Ask My Coach', q: 'How do I ask my Personal Coach a question?' },
      { icon: '📅', label: 'Weekly Summary', q: 'Give me a summary of my week.' },
      { icon: '🔥', label: 'Motivate Me', q: 'I need some motivation today.' },
    ];

    function ensureDom() {
      if ($('znFab')) return;
      var fab = document.createElement('button');
      fab.id = 'znFab'; fab.className = 'zn-fab'; fab.setAttribute('aria-label', 'Ask Zino');
      fab.innerHTML = '<img src="' + IMG.fab + '" alt="Zino"><span class="zn-fab-badge" id="znFabBadge"></span>';
      document.body.appendChild(fab);
      fab.addEventListener('click', open);

      var backdrop = document.createElement('div');
      backdrop.id = 'znChatBackdrop'; backdrop.className = 'zn-chat-backdrop';
      backdrop.innerHTML =
        '<div class="zn-chat-card">' +
          '<div class="zn-chat-head">' +
            '<img class="zn-chat-avatar" src="' + IMG.done + '" alt="Zino">' +
            '<div><div class="zn-chat-title">Zino</div>' +
              '<div class="zn-chat-sub"><span class="zn-chat-dot"></span>Online · AI Fitness Companion</div></div>' +
            '<button class="zn-chat-close" id="znChatClose" aria-label="Close">✕</button>' +
          '</div>' +
          '<div class="zn-chat-msgs" id="znChatMsgs"></div>' +
          '<div class="zn-chips-row" id="znChipsRow"></div>' +
          '<div class="zn-chat-input-bar">' +
            '<textarea class="zn-chat-input" id="znChatInput" rows="1" placeholder="Ask Zino anything…"></textarea>' +
            '<button class="zn-chat-send zn-chat-mic" id="znChatMic" aria-label="Record voice message">' +
              '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" y1="19" x2="12" y2="23"/></svg>' +
            '</button>' +
            '<button class="zn-chat-send" id="znChatSend" aria-label="Send">' +
              '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>' +
            '</button>' +
          '</div>' +
        '</div>';
      document.body.appendChild(backdrop);
      /* Voice-mic visual state (self-contained; injected once so it doesn't
         need a separate zino.css change). */
      if (!$('znVoiceStyle')) {
        var _vs = document.createElement('style');
        _vs.id = 'znVoiceStyle';
        _vs.textContent = '.zn-chat-mic{margin-right:6px}' +
          '.zn-mic--recording{color:#ef4444;animation:znMicPulse 1s ease-in-out infinite}' +
          '@keyframes znMicPulse{0%,100%{opacity:1}50%{opacity:.35}}';
        document.head.appendChild(_vs);
      }
      backdrop.addEventListener('click', function (e) { if (e.target === backdrop) close(); });
      $('znChatClose').addEventListener('click', close);
      $('znChatSend').addEventListener('click', sendCurrentInput);
      $('znChatMic').addEventListener('click', toggleVoice);
      $('znChatInput').addEventListener('keydown', function (e) {
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendCurrentInput(); }
      });

      $('znChipsRow').innerHTML = CHIPS.map(function (c, i) {
        return '<button class="zn-chip" data-chip="' + i + '">' + c.icon + ' ' + esc(c.label) + '</button>';
      }).join('');
      $('znChipsRow').querySelectorAll('[data-chip]').forEach(function (btn) {
        btn.addEventListener('click', function () { sendMessage(CHIPS[+btn.dataset.chip].q); });
      });
    }

    function open() {
      ensureDom();
      var bd = $('znChatBackdrop');
      var badge = $('znFabBadge');
      if (badge) badge.classList.remove('show');
      if (!_history.length) {
        renderBubble('zino', "Hey " + myName().split(' ')[0] + "! 👋 I'm Zino — ask me anything about your plan, or tap a quick action below.");
      } else {
        /* Session history restored (e.g. after navigating between pages) —
           re-render it so the visible thread matches what Zino remembers */
        var wrap = $('znChatMsgs');
        if (wrap && !wrap.childElementCount) {
          _history.forEach(function (h) { renderBubble(h.role === 'user' ? 'user' : 'zino', h.text); });
        }
      }
      bd.classList.add('show');
      requestAnimationFrame(function () { requestAnimationFrame(function () { bd.classList.add('open'); }); });
      setTimeout(function () { var i = $('znChatInput'); if (i) i.focus(); }, 300);
    }
    function close() {
      var bd = $('znChatBackdrop');
      if (!bd) return;
      bd.classList.remove('open');
      setTimeout(function () { bd.classList.remove('show'); }, 220);
    }

    function renderBubble(role, text) {
      var wrap = $('znChatMsgs');
      var el = document.createElement('div');
      el.className = 'zn-bubble zn-bubble--' + (role === 'user' ? 'user' : 'zino');
      el.textContent = text;
      wrap.appendChild(el);
      wrap.scrollTop = wrap.scrollHeight;
      return el;
    }
    function renderTyping() {
      var wrap = $('znChatMsgs');
      var el = document.createElement('div');
      el.className = 'zn-typing'; el.id = 'znTyping';
      el.innerHTML = '<span></span><span></span><span></span>';
      wrap.appendChild(el);
      wrap.scrollTop = wrap.scrollHeight;
    }
    function removeTyping() { var t = $('znTyping'); if (t) t.remove(); }

    function sendCurrentInput() {
      var input = $('znChatInput');
      var text = (input.value || '').trim();
      if (!text) return;
      input.value = '';
      sendMessage(text);
    }

    function sendMessage(text) {
      if (_busy) return;
      _busy = true;
      renderBubble('user', text);
      renderTyping();
      ZinoManager.send(text, _history).then(function (reply) {
        removeTyping();
        renderBubble('zino', reply);
        _history.push({ role: 'user', text: text }, { role: 'zino', text: reply });
        if (_history.length > 20) _history = _history.slice(-20);
        _persistHistory();
      }).catch(function (err) {
        removeTyping();
        renderBubble('zino', "Hmm, I'm having trouble connecting right now 😅 Try again in a moment?");
        console.error('[ZINO]', err);
      }).then(function () { _busy = false; });
    }

    /* ── Voice Zino (feature parity with the Flutter voice_service) ──
       Mic capture -> POST /api/voice/stt (transcript) -> POST /api/voice/chat
       (Zino's reply + spoken mp3, same brain/persona as the text path). All
       LLM/TTS/STT work stays server-side; the browser only records and plays.
       Unauthenticated, exactly like the existing /api/ai/zino-chat text call. */
    var _mediaRecorder = null, _audioChunks = [], _recording = false, _voiceAudio = null;

    function _setMicState(state) {
      var btn = $('znChatMic');
      if (!btn) return;
      btn.classList.toggle('zn-mic--recording', state === 'recording');
      btn.disabled = state === 'busy';
      btn.setAttribute('aria-label', state === 'recording' ? 'Stop recording' : 'Record voice message');
    }

    function toggleVoice() {
      if (_recording) { _stopRecording(); return; }
      if (_busy) return;
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || typeof window.MediaRecorder === 'undefined') {
        renderBubble('zino', "Voice isn't supported in this browser 😅 You can still type to me.");
        return;
      }
      navigator.mediaDevices.getUserMedia({ audio: true }).then(function (stream) {
        _audioChunks = [];
        var opts = (window.MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported('audio/webm'))
          ? { mimeType: 'audio/webm' } : undefined;
        _mediaRecorder = opts ? new MediaRecorder(stream, opts) : new MediaRecorder(stream);
        _mediaRecorder.ondataavailable = function (e) { if (e.data && e.data.size) _audioChunks.push(e.data); };
        _mediaRecorder.onstop = function () {
          stream.getTracks().forEach(function (t) { t.stop(); });
          _recording = false;
          _setMicState('busy');
          var blob = new Blob(_audioChunks, { type: (_mediaRecorder && _mediaRecorder.mimeType) || 'audio/webm' });
          if (blob.size < 800) { _setMicState('idle'); return; } // too short to be speech
          _sendVoiceClip(blob);
        };
        _mediaRecorder.start();
        _recording = true;
        _setMicState('recording');
      }).catch(function (err) {
        console.error('[ZINO VOICE] mic unavailable', err);
        renderBubble('zino', "I couldn't access your microphone. Allow mic access in your browser and try again.");
      });
    }

    function _stopRecording() {
      try {
        if (_mediaRecorder && _mediaRecorder.state !== 'inactive') _mediaRecorder.stop();
      } catch (_) { _recording = false; _setMicState('idle'); }
    }

    function _sendVoiceClip(blob) {
      if (_busy) { _setMicState('idle'); return; }
      _busy = true;
      renderTyping();
      var fd = new FormData();
      fd.append('audio', blob, 'voice.webm');
      fd.append('language', 'hinglish');
      fetch('/api/voice/stt', { method: 'POST', body: fd })
        .then(function (r) { return r.ok ? r.json() : Promise.reject(new Error('stt_http_' + r.status)); })
        .then(function (data) {
          var transcript = ((data && data.text) || '').trim();
          if (!transcript) {
            removeTyping(); _busy = false; _setMicState('idle');
            renderBubble('zino', "I didn't catch that — try again a little closer to the mic 🎙️");
            return null;
          }
          renderBubble('user', transcript);
          return fetch('/api/voice/chat', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ message: transcript, context: ZinoManager.buildContext(), history: _history }),
          }).then(function (r) {
            return r.ok ? r.json() : Promise.reject(new Error('chat_http_' + r.status));
          }).then(function (vc) {
            removeTyping();
            var reply = (vc && vc.reply) || "Sorry, I couldn't respond just now — try again?";
            renderBubble('zino', reply);
            _history.push({ role: 'user', text: transcript }, { role: 'zino', text: reply });
            if (_history.length > 20) _history = _history.slice(-20);
            _persistHistory();
            if (vc && vc.audio_base64) _playVoice(vc.audio_base64);
          });
        })
        .catch(function (err) {
          removeTyping();
          renderBubble('zino', "Hmm, voice isn't working right now 😅 Try again, or type your question instead?");
          console.error('[ZINO VOICE]', err);
        })
        .then(function () { _busy = false; _setMicState('idle'); });
    }

    function _playVoice(b64) {
      try {
        if (_voiceAudio) { try { _voiceAudio.pause(); } catch (_) {} }
        _voiceAudio = new Audio('data:audio/mpeg;base64,' + b64);
        // Autoplay may be blocked by the browser; the reply text is already
        // rendered, so a blocked play is a silent no-op, never an error.
        _voiceAudio.play().catch(function () {});
      } catch (_) {}
    }

    /* ── Celebrations — real data only ── */
    function checkCelebrations() {
      if (typeof ZitlasStreak === 'undefined' || !ZitlasStreak.getStreak) return;
      var s = ZitlasStreak.getStreak();
      var streak = s && s.currentStreak;
      if (streak !== 7 && streak !== 30) return;
      var flagKey = 'zitlas_zino_celebrated_streak_' + streak;
      if (localStorage.getItem(flagKey)) return;
      localStorage.setItem(flagKey, new Date().toISOString());
      var msg = streak === 30
        ? '🔥 30-day streak! You are absolutely unstoppable — incredible consistency!'
        : '🎉 7-day streak! One week strong — keep this momentum going!';
      showCelebration(msg);
      if (typeof ZitlasNotify !== 'undefined') {
        var selfUid = myUid();
        if (selfUid) {
          ZitlasNotify.send(selfUid, {
            title: streak + '-Day Streak! 🔥', message: msg,
            category: 'achievement', type: 'streak_milestone', action: 'dashboard',
          });
        }
      }
    }
    function showCelebration(msg) {
      var el = $('znCelebrate');
      if (!el) {
        el = document.createElement('div');
        el.id = 'znCelebrate'; el.className = 'zn-celebrate';
        document.body.appendChild(el);
      }
      el.textContent = msg;
      el.classList.add('show');
      setTimeout(function () { el.classList.remove('show'); }, 4200);
    }

    function init() {
      ensureDom();
      setTimeout(checkCelebrations, 1200);
    }
    return { init: init, open: open };
  })();

  /* ── Boot: floating assistant always mounts; tutorial only when relevant ── */
  function boot() {
    FloatingAssistant.init();
    TutorialEngine.maybeResume();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();

  win.ZinoManager = ZinoManager;
  win.ZinoTutorial = TutorialEngine;
  win.ZinoFloating = FloatingAssistant;
})(window);
