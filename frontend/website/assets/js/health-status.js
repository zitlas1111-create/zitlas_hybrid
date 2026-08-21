/*!
 * ZITLAS — Health Status / Recovery Mode (assets/js/health-status.js)
 *
 * "❤️ How are you feeling today?" card on the Home Dashboard. Self-mounting:
 * looks for #healthStatusMount and renders itself there — dashboard.js is
 * untouched. One active status per day.
 *
 * Adjustments are DETERMINISTIC (rule-based, instant, no LLM call): the
 * status/symptom rules below rewrite ONLY today's training, diet focus and
 * step goal — the rest of the week is never touched. Results are stored in
 * localStorage `zitlas_health_today` and applied by the pages that render
 * today's plan (diet.js reads the diet override; this card shows the
 * replacement workout + step goal). History accumulates in
 * `zitlas_health_history` (recovery timeline + analytics).
 *
 * When a Personal Coach is active, every report also writes a
 * `health_alerts` Firestore doc, notifies the coach (coaching_notifications)
 * and drops a system-style message into the coaching chat — all realtime.
 *
 * SAFETY: severe severity, chest pain / difficulty breathing symptoms,
 * pain ≥ 8, or a sick report from an athlete with a critical condition
 * (heart disease, etc.) suppresses ALL workout generation and shows
 * "Seek medical attention" instead.
 */
(function (win) {
  'use strict';

  var STATUSES = [
    { key: 'great',      label: '😊 Feeling Great',   cls: 'active' },
    { key: 'unwell',     label: '😐 Slightly Unwell', cls: 'active--warn' },
    { key: 'sick',       label: '🤒 Sick Today',      cls: 'active--danger' },
    { key: 'injured',    label: '🤕 Injured',         cls: 'active--danger' },
    { key: 'poor_sleep', label: '😴 Poor Sleep',      cls: 'active--warn' },
    { key: 'stress',     label: '😰 High Stress',     cls: 'active--warn' },
    { key: 'other',      label: '➕ Other',           cls: 'active--warn' },
  ];
  var SYMPTOMS = ['Fever', 'Cold', 'Cough', 'Headache', 'Vomiting', 'Diarrhea',
    'Food Poisoning', 'Sore Throat', 'Stomach Pain', 'Weakness', 'Fatigue',
    'Body Pain', 'Chest Pain', 'Difficulty Breathing', 'Other'];
  var BODY_PARTS = ['Neck', 'Shoulder', 'Chest', 'Back', 'Lower Back', 'Elbow',
    'Wrist', 'Hip', 'Knee', 'Ankle', 'Foot'];
  var STATUS_LABEL = {};
  STATUSES.forEach(function (s) { STATUS_LABEL[s.key] = s.label; });

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function todayKey() { return new Date().toISOString().slice(0, 10); }
  function safeJSON(key) {
    try { return JSON.parse(localStorage.getItem(key) || 'null'); } catch (_) { return null; }
  }
  function uid() {
    var fb = safeJSON('zitlas_firebase_user');
    return fb && fb.uid;
  }
  function athleteName() {
    var fb = safeJSON('zitlas_firebase_user');
    return (fb && (fb.displayName || fb.name)) || 'User';
  }

  var _toastEl = null, _toastTimer = null;
  function toast(msg) {
    if (!_toastEl) {
      _toastEl = document.createElement('div');
      _toastEl.className = 'hs-toast';
      document.body.appendChild(_toastEl);
    }
    _toastEl.textContent = msg;
    _toastEl.classList.add('show');
    clearTimeout(_toastTimer);
    _toastTimer = setTimeout(function () { _toastEl.classList.remove('show'); }, 3200);
  }

  /* ══════════════════════════════════════════════
     DETERMINISTIC ADJUSTMENT ENGINE
  ══════════════════════════════════════════════ */
  function baseStepsGoal() {
    var calc = safeJSON('zitlas_calculations') || {};
    return calc.daily_steps_goal || 7000;
  }
  function hasCriticalCondition() {
    var prec = safeJSON('zitlas_precautions');
    return !!(prec && prec.directives && prec.directives.overall_severity === 'critical');
  }
  function hasAsthma() {
    var prec = safeJSON('zitlas_precautions');
    var labels = (prec && prec.conditions) || [];
    return labels.some(function (l) { return /asthma/i.test(l); });
  }

  /* Deterministic recovery-day meal templates (per spec: fever → soup/
     khichdi/electrolytes etc.). Rendered by diet.js in place of today's
     normal meals; clearly labeled as recovery meals, never as AI output. */
  function recoveryMeals(kind) {
    var M = function (name, time, foods, purpose, emoji) {
      return { meal_name: name, time: time, foods: foods, purpose: purpose,
        emoji: emoji, color: '#F59E0B', _recovery: true };
    };
    if (kind === 'fever') return [
      M('Breakfast', '8:00 AM', ['Moong dal khichdi', 'Curd'], 'Easy to digest · gentle protein', '🥣'),
      M('Mid-Morning', '11:00 AM', ['Coconut water', 'Orange or amla'], 'Electrolytes · Vitamin C', '🥥'),
      M('Lunch', '1:30 PM', ['Vegetable soup', 'Soft rice with dal'], 'Hydrating · light', '🍲'),
      M('Snacks', '4:30 PM', ['Banana', 'ORS / electrolyte drink'], 'Energy · hydration', '🍌'),
      M('Dinner', '7:30 PM', ['Light khichdi', 'Boiled vegetables'], 'Early, light dinner for recovery', '🥣'),
    ];
    if (kind === 'cold') return [
      M('Breakfast', '8:00 AM', ['Warm oats with honey', 'Ginger tea'], 'Warm & soothing', '🥣'),
      M('Mid-Morning', '11:00 AM', ['Warm lemon water', 'Citrus fruit'], 'Vitamin C', '🍋'),
      M('Lunch', '1:30 PM', ['Dal rice', 'Warm sabzi', 'Rasam or clear soup'], 'Warm, easy comfort food', '🍛'),
      M('Snacks', '4:30 PM', ['Ginger tea', 'Roasted makhana'], 'Avoid cold drinks today', '🫖'),
      M('Dinner', '7:30 PM', ['Vegetable soup', 'Soft roti + sabzi', 'Turmeric milk before bed'], 'Turmeric milk supports recovery overnight', '🍲'),
    ];
    if (kind === 'inflammation') return [
      M('Breakfast', '8:00 AM', ['Turmeric oats with berries', 'Walnuts'], 'Anti-inflammatory start', '🥣'),
      M('Mid-Morning', '11:00 AM', ['Ginger tea', 'Seasonal fruit'], 'Hydration + antioxidants', '🫖'),
      M('Lunch', '1:30 PM', ['Dal + rice', 'Leafy-green sabzi', 'Curd'], 'Greens + protein for repair', '🍛'),
      M('Snacks', '4:30 PM', ['Handful of almonds', 'Coconut water'], 'Magnesium + electrolytes', '🥥'),
      M('Dinner', '7:30 PM', ['Khichdi or dal + roti', 'Steamed vegetables'], 'Light, anti-inflammatory dinner', '🥗'),
    ];
    if (kind === 'sleep') return [
      M('Breakfast', '8:00 AM', ['Banana oats', 'Handful of almonds'], 'Magnesium-rich start', '🥣'),
      M('Mid-Morning', '11:00 AM', ['Fruit + pumpkin seeds'], 'Steady energy, no caffeine after 2 PM', '🎃'),
      M('Lunch', '1:30 PM', ['Rice + dal', 'Palak (spinach) sabzi', 'Curd'], 'Magnesium + comfortable carbs', '🍛'),
      M('Snacks', '4:30 PM', ['Roasted chana', 'Herbal tea (no caffeine)'], 'Light afternoon energy', '🫖'),
      M('Dinner', '7:00 PM', ['Light roti + sabzi', 'Warm milk before bed'], 'Earlier, lighter dinner for better sleep', '🥛'),
    ];
    if (kind === 'stress') return [
      M('Breakfast', '8:00 AM', ['Oats with flaxseed', 'Walnuts'], 'Complex carbs + omega-3 for mood', '🥣'),
      M('Mid-Morning', '11:00 AM', ['Fruit', 'Green tea (limit caffeine)'], 'Steady blood sugar', '🍎'),
      M('Lunch', '1:30 PM', ['Brown rice + dal', 'Vegetable sabzi', 'Salad'], 'Stable-energy lunch', '🍛'),
      M('Snacks', '4:30 PM', ['Dark roasted chana', 'Banana'], 'Avoid heavy caffeine today', '🍌'),
      M('Dinner', '7:30 PM', ['Roti + paneer or dal', 'Steamed vegetables'], 'Balanced, calming dinner', '🥗'),
    ];
    /* injury / default recovery */
    return [
      M('Breakfast', '8:00 AM', ['Eggs or paneer bhurji', 'Whole-grain toast'], 'Extra protein for tissue repair', '🍳'),
      M('Mid-Morning', '11:00 AM', ['Berries or citrus fruit', 'Walnuts'], 'Antioxidants + omega-3', '🫐'),
      M('Lunch', '1:30 PM', ['Dal + rice', 'Turmeric sabzi', 'Curd'], 'Anti-inflammatory + protein', '🍛'),
      M('Snacks', '4:30 PM', ['Sprouts chaat or roasted chana'], 'Protein top-up', '🥗'),
      M('Dinner', '7:30 PM', ['Roti + paneer/chicken', 'Leafy greens'], 'Repair-focused dinner', '🥘'),
    ];
  }

  function computeAdjustments(report) {
    var steps = baseStepsGoal();
    var adj = {
      date: todayKey(),
      status: report.status, symptoms: report.symptoms || [],
      severity: report.severity || null, painLevel: report.painLevel || null,
      sleepHours: report.sleepHours != null ? report.sleepHours : null,
      stressLevel: report.stressLevel || null,
      bodyParts: report.bodyParts || [], note: report.note || '',
      safety: false,
      workout: null, diet: null,
      stepsGoal: steps, oldStepsGoal: steps,
      createdAt: new Date().toISOString(),
    };
    var sym = adj.symptoms;
    function has(s) { return sym.indexOf(s) !== -1; }

    /* ── SAFETY GATE (checked first, overrides everything) ── */
    if (
      report.severity === 'severe' ||
      has('Chest Pain') || has('Difficulty Breathing') ||
      (report.status === 'injured' && (report.painLevel || 0) >= 8) ||
      (report.status === 'sick' && hasCriticalCondition())
    ) {
      adj.safety = true;
      adj.workout = { mode: 'none', title: '⚠ No workout today',
        items: ['Seek medical attention before exercising.', 'Rest and hydrate.',
          'Resume training only after you feel fully recovered or are cleared by a doctor.'] };
      adj.diet = { focus: 'Gentle recovery nutrition',
        items: ['Light, easy-to-digest meals (khichdi, soup)', 'Electrolytes / coconut water',
          'Small frequent portions', 'Plenty of water'], meals: recoveryMeals('fever') };
      adj.stepsGoal = 'Rest';
      return adj;
    }

    if (report.status === 'great') {
      adj.workout = null; adj.diet = null; /* normal plan, no overrides */
      return adj;
    }

    if (report.status === 'sick' || report.status === 'unwell' || report.status === 'other') {
      var feverish = has('Fever') || has('Vomiting') || has('Diarrhea') || has('Food Poisoning');
      var coldish  = has('Cold') || has('Cough') || has('Sore Throat');
      var weak     = has('Weakness') || has('Fatigue') || has('Body Pain');
      if (feverish || report.status === 'sick') {
        adj.workout = { mode: 'rest', title: 'Workout cancelled — Recovery Day',
          items: ['Complete rest', 'Hydration: 3+ litres through the day',
            'Deep breathing: 5 minutes, 3 times', 'Gentle full-body stretching: 10 minutes'] };
        adj.diet = { focus: 'Fever recovery — light & hydrating',
          items: ['Vegetable / chicken soup', 'Khichdi (easy to digest)',
            'Coconut water + electrolytes', 'Vitamin C fruits (orange, amla)',
            'Light protein (curd, dal, boiled eggs)'], meals: recoveryMeals('fever') };
        adj.stepsGoal = feverish && report.severity === 'moderate' ? 'Rest' : 2000;
      } else if (coldish) {
        adj.workout = { mode: 'reduced', title: 'Intensity reduced ~60%',
          items: ['Skip high-intensity work today', 'Easy walk or light mobility only',
            'Stop if breathing feels harder than usual'].concat(
              hasAsthma() ? ['Asthma: keep your inhaler nearby, train indoors'] : []) };
        adj.diet = { focus: 'Cold recovery — warm & soothing',
          items: ['Warm fluids through the day', 'Turmeric milk before bed',
            'Ginger tea', 'Warm soups', 'Avoid cold drinks / ice cream'], meals: recoveryMeals('cold') };
        adj.stepsGoal = Math.round(steps * 0.5);
      } else if (weak) {
        adj.workout = { mode: 'mobility', title: 'Mobility only',
          items: ['Gentle stretching: 15 minutes', 'Easy walk if energy allows',
            'No strength or cardio today'] };
        adj.diet = { focus: 'Anti-inflammatory + energy',
          items: ['Anti-inflammatory foods (turmeric, ginger, leafy greens)',
            'Balanced carbs for energy', 'Extra hydration'], meals: recoveryMeals('inflammation') };
        adj.stepsGoal = Math.round(steps * 0.4);
      } else {
        adj.workout = { mode: 'reduced', title: 'Take it easier today',
          items: ['Reduce intensity ~40%', 'Stop early if you feel worse'] };
        adj.diet = { focus: 'Light, regular meals', items: ['Stick to simple whole foods', 'Hydrate well'], meals: recoveryMeals('inflammation') };
        adj.stepsGoal = Math.round(steps * 0.6);
      }
      return adj;
    }

    if (report.status === 'injured') {
      var parts = adj.bodyParts.map(function (p) { return p.toLowerCase(); });
      var lower = parts.some(function (p) { return ['knee', 'ankle', 'foot', 'hip'].indexOf(p) !== -1; });
      var back  = parts.some(function (p) { return p.indexOf('back') !== -1; });
      var upper = parts.some(function (p) { return ['neck', 'shoulder', 'chest', 'elbow', 'wrist'].indexOf(p) !== -1; });
      var items = [];
      if (lower) items.push('Leg work removed — upper-body strength only (seated where possible)');
      if (back)  items.push('No deadlifts, no squats, no loaded spinal movement — core-safe work only (bird-dog, dead bug)');
      if (upper) items.push('Affected-arm/shoulder work removed — lower-body and walking focus');
      items.push('Stay strictly pain-free: sharp pain = stop immediately');
      adj.workout = { mode: 'modified', title: 'Workout modified around your injury', items: items };
      adj.diet = { focus: 'Injury recovery',
        items: ['Extra protein for tissue repair', 'Anti-inflammatory foods (omega-3, turmeric, berries)'], meals: recoveryMeals('injury') };
      adj.stepsGoal = lower ? 1500 : Math.round(steps * 0.7);
      return adj;
    }

    if (report.status === 'poor_sleep') {
      var hrs = report.sleepHours != null ? report.sleepHours : 5;
      if (hrs < 5) {
        adj.workout = { mode: 'reduced', title: 'Light recovery session only',
          items: ['Skip intense training on <5h sleep', '15-20 min easy walk',
            'Light stretching before bed tonight'] };
        adj.stepsGoal = Math.round(steps * 0.6);
      } else {
        adj.workout = { mode: 'reduced', title: 'Reduce intensity today',
          items: ['Drop ~30% of planned intensity/volume', 'Prioritise an earlier night tonight'] };
        adj.stepsGoal = Math.round(steps * 0.8);
      }
      adj.diet = { focus: 'Sleep support',
        items: ['Magnesium-rich foods (spinach, almonds, pumpkin seeds, banana)',
          'No caffeine after 2 PM', 'Lighter dinner, earlier'], meals: recoveryMeals('sleep') };
      return adj;
    }

    if (report.status === 'stress') {
      var lvl = report.stressLevel || 7;
      adj.workout = { mode: lvl >= 8 ? 'mobility' : 'reduced',
        title: lvl >= 8 ? 'Calming movement only' : 'Moderate session',
        items: lvl >= 8
          ? ['Yoga or gentle stretching: 20 minutes', 'Breathing exercises: 4-7-8 pattern, 5 minutes', 'Easy outdoor walk']
          : ['Moderate workout is fine — it helps stress', 'Finish with 5 minutes of slow breathing'] };
      adj.diet = { focus: 'Stress support',
        items: ['Complex carbs (oats, brown rice) for stable mood', 'Omega-3 sources (walnuts, flaxseed)',
          'Limit caffeine today'], meals: recoveryMeals('stress') };
      adj.stepsGoal = Math.round(steps * 0.9);
      return adj;
    }

    return adj;
  }

  /* ══════════════════════════════════════════════
     PERSIST + COACH ALERT
  ══════════════════════════════════════════════ */
  function saveToday(adj) {
    localStorage.setItem('zitlas_health_today', JSON.stringify(adj));
    var hist = safeJSON('zitlas_health_history') || [];
    hist = hist.filter(function (h) { return h.date !== adj.date; });
    hist.push({ date: adj.date, status: adj.status, severity: adj.severity, safety: adj.safety });
    if (hist.length > 60) hist = hist.slice(-60);
    localStorage.setItem('zitlas_health_history', JSON.stringify(hist));
  }
  function clearToday() {
    localStorage.removeItem('zitlas_health_today');
  }

  function alertCoach(adj) {
    if (typeof ZitlasDB === 'undefined') return;
    var myUid = uid();
    if (!myUid) return;
    ZitlasDB.collection('personal_coaching').doc(myUid).get().then(function (snap) {
      var rel = snap.exists ? snap.data() : null;
      if (!rel || rel.status !== 'active') return;
      var now = new Date().toISOString();
      var id = 'HA_' + Date.now();
      var summary = STATUS_LABEL[adj.status] +
        (adj.symptoms.length ? ' — ' + adj.symptoms.join(', ') : '') +
        (adj.bodyParts.length ? ' — ' + adj.bodyParts.join(', ') : '') +
        (adj.severity ? ' (' + adj.severity + ')' : '') +
        (adj.painLevel ? ' (pain ' + adj.painLevel + '/10)' : '');

      ZitlasDB.collection('health_alerts').doc(id).set({
        alertId: id, athleteId: myUid, athleteName: athleteName(),
        coachId: rel.coachId,
        status: adj.status, symptoms: adj.symptoms, severity: adj.severity,
        bodyParts: adj.bodyParts, painLevel: adj.painLevel,
        sleepHours: adj.sleepHours, stressLevel: adj.stressLevel,
        notes: adj.note, safety: adj.safety,
        newWorkout: adj.workout, newDiet: adj.diet,
        oldStepsGoal: adj.oldStepsGoal, newStepsGoal: adj.stepsGoal,
        createdAt: now,
      }).catch(function (e) { console.warn('[HEALTH] alert write failed', e); });

      var nid = 'CN_' + Date.now() + '_hs';
      ZitlasDB.collection('coaching_notifications').doc(nid).set({
        id: nid, toId: rel.coachId, fromId: myUid, fromName: athleteName(),
        text: '🚨 Health alert: ' + athleteName() + ' reported ' + summary + '.',
        type: 'health_alert', createdAt: now, read: false,
      }).catch(function () {});

      /* System-style message into the coaching chat */
      var chatId = 'chat_' + myUid + '_' + rel.coachId;
      var msg = {
        id: 'msg_' + Date.now() + '_hs',
        conversationId: chatId, senderId: myUid, senderType: 'athlete',
        text: '🩺 Health update — ' + summary + '.\n' +
          (adj.safety
            ? '⚠ Advised to seek medical attention before exercising.'
            : 'Today’s workout: ' + (adj.workout ? adj.workout.title : 'unchanged') +
              '. Diet: ' + (adj.diet ? adj.diet.focus : 'unchanged') +
              '. Steps: ' + adj.oldStepsGoal + ' → ' + adj.stepsGoal + '.') +
          (adj.note ? '\nNote: ' + adj.note : ''),
        type: 'text', imageUrl: null, timestamp: now,
      };
      ZitlasDB.collection('chat_rooms').doc(chatId).set({
        participants: [myUid, rel.coachId],
        athleteId: myUid, athleteName: athleteName(),
        expertId: rel.coachId, expertName: rel.coachName || 'Coach',
        lastMessage: msg.text.split('\n')[0], lastMessageAt: now,
      }, { merge: true }).then(function () {
        return ZitlasDB.collection('chat_rooms').doc(chatId).collection('messages').doc(msg.id).set(msg);
      }).catch(function (e) { console.warn('[HEALTH] chat message failed', e); });

      if (typeof ZitlasNotify !== 'undefined') {
        ZitlasNotify.send(rel.coachId, {
          title: '🚨 Health Alert — ' + athleteName(), message: summary,
          category: 'health', type: 'health_alert', action: 'expert_dashboard',
          priority: adj.safety ? 'critical' : 'high',
        });
      }

      console.log('[HEALTH] coach alerted:', rel.coachName, summary);
    }).catch(function (e) { console.warn('[HEALTH] rel lookup failed', e); });
  }

  /* Self-notification confirming today's plan was adjusted — visible in
     the athlete's own Notification Center even without a Personal Coach. */
  function notifySelf(adj) {
    if (typeof ZitlasNotify === 'undefined') return;
    var myUid = uid();
    if (!myUid) return;
    var title = adj.safety
      ? '⚠ Seek medical attention before exercising'
      : STATUS_LABEL[adj.status] + ' — today’s plan adjusted';
    var parts = [];
    if (adj.workout) parts.push('Workout: ' + adj.workout.title);
    if (adj.diet)    parts.push('Diet: ' + adj.diet.focus);
    ZitlasNotify.send(myUid, {
      title: title, message: parts.join(' · '),
      category: 'health', type: 'health_status_' + adj.status,
      action: 'dashboard', priority: adj.safety ? 'critical' : 'medium',
    });
  }

  /* ══════════════════════════════════════════════
     SHEET (report flow)
  ══════════════════════════════════════════════ */
  function ensureSheet() {
    var bd = $('hsSheetBackdrop');
    if (bd) return bd;
    bd = document.createElement('div');
    bd.id = 'hsSheetBackdrop';
    bd.className = 'hs-sheet-backdrop';
    bd.innerHTML = '<div class="hs-sheet" id="hsSheet"></div>';
    document.body.appendChild(bd);
    bd.addEventListener('click', function (e) { if (e.target === bd) closeSheet(); });
    return bd;
  }
  function openSheet(html) {
    var bd = ensureSheet();
    $('hsSheet').innerHTML = html;
    bd.style.display = 'flex';
    requestAnimationFrame(function () {
      requestAnimationFrame(function () { bd.classList.add('open'); });
    });
  }
  function closeSheet() {
    var bd = $('hsSheetBackdrop');
    if (!bd) return;
    bd.classList.remove('open');
    setTimeout(function () { bd.style.display = 'none'; }, 200);
  }

  var draft = null;

  function openReportSheet(statusKey) {
    draft = { status: statusKey, symptoms: [], bodyParts: [], severity: null,
      painLevel: 5, sleepHours: 6, stressLevel: 7, note: '' };

    if (statusKey === 'great') { submitReport(); return; }

    var html = '<p class="hs-sheet-title">' + esc(STATUS_LABEL[statusKey]) + '</p>';

    if (statusKey === 'sick' || statusKey === 'unwell' || statusKey === 'other') {
      html += '<p class="hs-sheet-sub">What are you experiencing? (select all that apply)</p>' +
        '<div class="hs-chip-grid">' + SYMPTOMS.map(function (s) {
          return '<button class="hs-chip" data-hs-sym="' + esc(s) + '">' + esc(s) + '</button>';
        }).join('') + '</div>' +
        '<span class="hs-label">Severity</span>' +
        '<div class="hs-severity-row">' +
          '<button class="hs-sev-btn" data-hs-sev="mild">Mild</button>' +
          '<button class="hs-sev-btn" data-hs-sev="moderate">Moderate</button>' +
          '<button class="hs-sev-btn" data-hs-sev="severe">Severe</button>' +
        '</div>';
    } else if (statusKey === 'injured') {
      html += '<p class="hs-sheet-sub">Which body part? (select all that apply)</p>' +
        '<div class="hs-chip-grid">' + BODY_PARTS.map(function (p) {
          return '<button class="hs-chip" data-hs-part="' + esc(p) + '">' + esc(p) + '</button>';
        }).join('') + '</div>' +
        '<span class="hs-label">Pain level: <span id="hsPainVal">5</span>/10</span>' +
        '<input type="range" class="hs-range" id="hsPain" min="1" max="10" value="5">';
    } else if (statusKey === 'poor_sleep') {
      html += '<span class="hs-label">Hours slept: <span id="hsSleepVal">6</span>h</span>' +
        '<input type="range" class="hs-range" id="hsSleep" min="0" max="12" step="0.5" value="6">';
    } else if (statusKey === 'stress') {
      html += '<span class="hs-label">Stress level: <span id="hsStressVal">7</span>/10</span>' +
        '<input type="range" class="hs-range" id="hsStress" min="1" max="10" value="7">';
    }

    html += '<span class="hs-label">Optional note</span>' +
      '<textarea class="hs-textarea" id="hsNote" placeholder="Describe how you’re feeling…"></textarea>' +
      '<div class="hs-actions">' +
        '<button class="hs-cancel" id="hsCancel">Cancel</button>' +
        '<button class="hs-confirm" id="hsSubmit">Update Today’s Plan</button>' +
      '</div>';

    openSheet(html);
    var sheet = $('hsSheet');
    sheet.querySelectorAll('[data-hs-sym]').forEach(function (b) {
      b.addEventListener('click', function () {
        var s = b.dataset.hsSym;
        var i = draft.symptoms.indexOf(s);
        if (i === -1) draft.symptoms.push(s); else draft.symptoms.splice(i, 1);
        b.classList.toggle('selected');
      });
    });
    sheet.querySelectorAll('[data-hs-part]').forEach(function (b) {
      b.addEventListener('click', function () {
        var p = b.dataset.hsPart;
        var i = draft.bodyParts.indexOf(p);
        if (i === -1) draft.bodyParts.push(p); else draft.bodyParts.splice(i, 1);
        b.classList.toggle('selected');
      });
    });
    sheet.querySelectorAll('[data-hs-sev]').forEach(function (b) {
      b.addEventListener('click', function () {
        draft.severity = b.dataset.hsSev;
        sheet.querySelectorAll('[data-hs-sev]').forEach(function (x) {
          x.className = 'hs-sev-btn';
        });
        b.classList.add('selected--' + draft.severity);
      });
    });
    var pain = $('hsPain');
    if (pain) pain.addEventListener('input', function () {
      draft.painLevel = parseInt(pain.value, 10);
      $('hsPainVal').textContent = pain.value;
    });
    var sleep = $('hsSleep');
    if (sleep) sleep.addEventListener('input', function () {
      draft.sleepHours = parseFloat(sleep.value);
      $('hsSleepVal').textContent = sleep.value;
    });
    var stress = $('hsStress');
    if (stress) stress.addEventListener('input', function () {
      draft.stressLevel = parseInt(stress.value, 10);
      $('hsStressVal').textContent = stress.value;
    });
    $('hsCancel').addEventListener('click', closeSheet);
    $('hsSubmit').addEventListener('click', function () {
      var note = $('hsNote');
      draft.note = (note && note.value.trim()) || '';
      submitReport();
    });
  }

  function submitReport() {
    var adj = computeAdjustments(draft);
    console.log('[HEALTH] report', draft, '→ adjustments', adj);
    if (adj.status === 'great') {
      clearToday();
      var hist = safeJSON('zitlas_health_history') || [];
      hist = hist.filter(function (h) { return h.date !== todayKey(); });
      hist.push({ date: todayKey(), status: 'great', severity: null, safety: false });
      localStorage.setItem('zitlas_health_history', JSON.stringify(hist));
      toast('😊 Great! Today’s plan runs as normal.');
    } else {
      saveToday(adj);
      alertCoach(adj);
      notifySelf(adj);
      toast(adj.safety
        ? '⚠ Plan paused — please consider medical attention.'
        : '✅ Today’s plan adjusted. Your coach has been notified if you have one.');
    }
    closeSheet();
    renderCard();
  }

  /* ══════════════════════════════════════════════
     CARD RENDER
  ══════════════════════════════════════════════ */
  function activeToday() {
    var t = safeJSON('zitlas_health_today');
    return (t && t.date === todayKey()) ? t : null;
  }
  function todayGreat() {
    var hist = safeJSON('zitlas_health_history') || [];
    return hist.some(function (h) { return h.date === todayKey() && h.status === 'great'; });
  }

  function renderCard() {
    var mount = $('healthStatusMount');
    if (!mount) return;
    var today = activeToday();
    var activeKey = today ? today.status : (todayGreat() ? 'great' : null);

    var btns = STATUSES.map(function (s) {
      var cls = 'hs-status-btn' + (activeKey === s.key ? ' ' + s.cls : '');
      return '<button class="' + cls + '" data-hs-status="' + s.key + '">' + s.label + '</button>';
    }).join('');
    /* Only ever appears alongside an active temporary status (sick/injured/
       poor_sleep/stress/unwell/other) — "great" never sets zitlas_health_
       today at all, so `today` is already the exact right condition. */
    if (today) {
      btns += '<button class="hs-status-btn hs-status-btn--clear" id="hsClearStatusChip">✕ Clear Status</button>';
    }

    var recovery = '';
    if (today) {
      var recCls = today.safety ? ' hs-recovery--danger' : '';
      recovery = '<div class="hs-recovery' + recCls + '">' +
        '<p class="hs-rec-title">🛟 Today’s Recovery Mode — ' + esc(STATUS_LABEL[today.status]) + '</p>' +
        (today.safety ? '<div class="hs-safety">⚠ Seek medical attention before exercising. Your coach has been notified.</div>' : '') +
        (today.workout
          ? '<div class="hs-rec-row"><b>Workout:</b> ' + esc(today.workout.title) + '</div>' +
            '<ul class="hs-rec-list">' + today.workout.items.map(function (i) {
              return '<li>' + esc(i) + '</li>';
            }).join('') + '</ul>'
          : '') +
        (today.diet
          ? '<div class="hs-rec-row" style="margin-top:6px"><b>Diet:</b> ' + esc(today.diet.focus) + ' (today’s meals adjusted on the Diet page)</div>'
          : '') +
        '<div class="hs-rec-row" style="margin-top:6px"><b>Steps:</b> ' +
          esc(String(today.oldStepsGoal)) + ' → <b style="color:#578A2C">' + esc(String(today.stepsGoal)) + '</b></div>' +
        '<div class="hs-rec-row"><b>Streak:</b> protected — today counts as a Recovery Day, not a miss.</div>' +
        '</div>';
    } else if (todayGreat()) {
      recovery = '<div class="hs-recovery hs-recovery--ok">' +
        '<p class="hs-rec-title">😊 Logged: feeling great — full plan active.</p></div>';
    }

    /* Recovery timeline + simple analytics (real history only) */
    var hist = safeJSON('zitlas_health_history') || [];
    var timeline = '';
    if (hist.length) {
      var recent = hist.slice(-7);
      var icon = { great: '😊', unwell: '😐', sick: '🤒', injured: '🤕',
        poor_sleep: '😴', stress: '😰', other: '➕' };
      var sickDays = hist.filter(function (h) { return h.status === 'sick' || h.status === 'unwell'; }).length;
      var injDays  = hist.filter(function (h) { return h.status === 'injured'; }).length;
      timeline = '<div class="hs-timeline">' +
        recent.map(function (h) {
          var d = new Date(h.date + 'T00:00:00');
          return '<span class="hs-tl-chip">' + (icon[h.status] || '•') + ' ' +
            d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' }) + '</span>';
        }).join('') +
        ((sickDays || injDays)
          ? '<span class="hs-tl-chip">Σ ' + sickDays + ' sick · ' + injDays + ' injured</span>'
          : '') +
        '</div>';
    }

    mount.innerHTML =
      '<section class="hs-card">' +
        '<p class="hs-title">❤️ How are you feeling today?</p>' +
        '<p class="hs-sub">Your AI and Personal Coach will adjust today’s plan accordingly.</p>' +
        '<div class="hs-btn-grid">' + btns + '</div>' +
        recovery + timeline +
      '</section>';

    mount.querySelectorAll('[data-hs-status]').forEach(function (b) {
      b.addEventListener('click', function () { openReportSheet(b.dataset.hsStatus); });
    });
    /* Clears only today's temporary status — clearToday() removes just the
       zitlas_health_today override, never touching assessment, profile,
       goals, or expert-reviewed plans. Removing it is what restores the
       original workout/diet/step goal: diet.js/weekly-plan.js/dashboard.js
       all fall back to the untouched AI (or expert) plan the moment this
       key is gone, and the Recovery Mode card disappears on the re-render
       below since activeToday() then returns null. */
    var clearChip = $('hsClearStatusChip');
    if (clearChip) clearChip.addEventListener('click', function () {
      clearToday();
      toast('Status cleared — today’s original plan is restored.');
      renderCard();
    });
  }

  /* ── Self-mount ── */
  function init() { renderCard(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();

  win.ZitlasHealthStatus = {
    activeToday: activeToday,
    refresh: renderCard,
  };
})(window);
