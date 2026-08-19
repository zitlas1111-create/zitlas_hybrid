/* ══════════════════════════════════════════════
   ZITLAS — Expert Dashboard
   expert-dashboard.js
   ══════════════════════════════════════════════ */

'use strict';

/* ══════════════════════════════════════════════
   UTILITY
   ══════════════════════════════════════════════ */

function esc(s) {
  return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

/* Expert profile is loaded dynamically via ZitlasExpertProfile (expert-profile.js) */

/* ══════════════════════════════════════════════
   EXPERT PROFILE HELPERS
   ══════════════════════════════════════════════ */

function buildExpertFromFirebase(firebaseUser, firestoreData) {
  const nameParts = (firebaseUser.displayName || 'Expert').split(' ');
  const initials  = nameParts.map(function (p) { return p[0] || ''; }).slice(0, 2).join('').toUpperCase() || 'EX';
  return {
    id:          firebaseUser.uid,
    name:        firebaseUser.displayName || firestoreData.name || 'Expert',
    firstName:   nameParts[0] || 'Expert',
    role:        'Nutrition Expert',
    rating:      '5.0',
    reviewCount: 0,
    experience:  'ZITLAS Certified',
    achievement: 'ZITLAS Expert',
    initials:    initials,
    colorAccent: 'var(--primary)',
    fee:         199,
    duration:    '20 Min',
    photo:       firebaseUser.photoURL || firestoreData.photo_url || null,
    about:       'Expert nutritionist on the ZITLAS platform.',
    quote:       'Every step forward is progress.',
    stats: [
      { value: '0',    label: 'Sessions' },
      { value: '0',    label: 'Clients'  },
      { value: '100%', label: 'Success Rate' },
      { value: '1+',   label: 'Year' },
    ],
  };
}

function getExpert() {
  if (typeof ZitlasExpertProfile !== 'undefined') {
    return ZitlasExpertProfile.toInternal(ZitlasExpertProfile.getProfile(), {});
  }
  /* Fallback: build minimal profile from localStorage */
  var fbu = {};
  try { fbu = JSON.parse(localStorage.getItem('zitlas_firebase_user') || '{}'); } catch (_) {}
  var n = (fbu.name || fbu.displayName || 'Expert').split(/\s+/);
  return {
    id: (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) ? ZitlasAuth.currentUser.uid : (fbu.uid || ''),
    name: fbu.name || fbu.displayName || 'Expert',
    firstName: n[0] || 'Expert', role: 'Expert',
    rating: '5.0', reviewCount: 0, experience: 'ZITLAS Expert',
    achievement: 'ZITLAS Expert', initials: 'EX',
    colorAccent: 'var(--primary)', fee: 0, duration: '20 Min',
    about: '', quote: '',
    stats: [
      { value: '0', label: 'Sessions' }, { value: '0', label: 'Clients' },
      { value: '0%', label: 'Success Rate' }, { value: '0+', label: 'Years' },
    ],
  };
}

/* ══════════════════════════════════════════════
   CHAT PERSISTENCE HELPERS
   ══════════════════════════════════════════════ */

let _edChatConversationId = null;  /* active expert chat overlay conversation */
let _edCurrentReview      = null;  /* review linked to the currently open chat */
let _prInboxActiveTab     = 'pending'; /* which inbox tab is visible */

/* athleteId → personal_coaching doc, kept live by listenForMyAthletes.
   Lets the chat overlay lock a conversation read-only once that specific
   athlete's coaching relationship with this expert has ended. */
var _pcRelByAthlete = {};
function _pcChatIsReadOnlyFor(athleteId) {
  var rel = athleteId && _pcRelByAthlete[athleteId];
  return !!(rel && (rel.status === 'ended' || rel.status === 'expired'));
}

/* URL-based workspace identity — restore-on-refresh support (see
   _restorePendingWorkspace). Deliberately NOT localStorage: the task's own
   constraint is that frontend persistence is UX-only, and the URL is
   re-validated against Firestore at restore time rather than trusted, so a
   stale/tampered query string just fails to restore instead of granting
   anything. history.replaceState (never pushState) so tab clicks don't
   pollute the back-stack. */
function _cwSetUrlParams(athleteId, tab) {
  try {
    var url = new URL(window.location.href);
    url.searchParams.set('cwAthlete', athleteId);
    url.searchParams.set('cwTab', tab || 'overview');
    window.history.replaceState(window.history.state, '', url.toString());
  } catch (_) {}
}
function _cwClearUrlParams() {
  try {
    var url = new URL(window.location.href);
    url.searchParams.delete('cwAthlete');
    url.searchParams.delete('cwTab');
    window.history.replaceState(window.history.state, '', url.toString());
  } catch (_) {}
}

/* Open the shared Coaching Workspace (components/coaching-workspace.js) for
   an ACTIVE coaching client. Falls back to the normal chat overlay when the
   module is unavailable so the button never dead-ends. */
function openCoachWorkspace(rel, initialTab) {
  if (!rel) return;
  if (typeof ZitlasCoachingWorkspace === 'undefined') {
    openExpertChat('chat_' + rel.athleteId + '_' + rel.coachId, rel.athleteName || 'Athlete');
    return;
  }
  var tab = initialTab || 'overview';
  _cwSetUrlParams(rel.athleteId, tab);
  ZitlasCoachingWorkspace.open({
    role:        'coach',
    athleteId:   rel.athleteId,
    athleteName: rel.athleteName || 'Athlete',
    coachId:     rel.coachId,
    coachName:   rel.coachName || (_currentExpert ? _currentExpert.name : 'Coach'),
    planType:    rel.planType || 'complete',
    planLabel:   rel.planLabel || 'Personal Coaching',
    coachingType: rel.coachingType,
    trialDurationDays: rel.trialDurationDays,
    startDate:   rel.startDate,
    endDate:     rel.endDate,
    status:      rel.status,
    initialTab:  tab,
    onTabChange: function (t) { _cwSetUrlParams(rel.athleteId, t); },
    onClose:     function () { _cwClearUrlParams(); },
  });
}
function _applyExpertChatReadOnlyState() {
  var banner   = document.getElementById('edChatReadonlyBanner');
  var inputBar = document.getElementById('edChatInputBar');
  if (!banner || !inputBar || !_edChatConversationId) return;
  var conv = chatGetConversation(_edChatConversationId);
  var readOnly = _pcChatIsReadOnlyFor(conv ? conv.athleteId : null);
  banner.style.display   = readOnly ? 'block' : 'none';
  inputBar.style.display = readOnly ? 'none' : 'flex';
}

/*
 * Canonical status values:
 *   pending          — submitted, waiting for expert
 *   in_progress      — expert has opened/accepted
 *   review_completed — expert finished, plan delivered
 *   rejected         — expert rejected
 *
 * Legacy values are migrated on read — never written going forward.
 */
function _normalizeStatus(status) {
  switch (status) {
    case 'accepted':
    case 'expert_reviewing': return 'in_progress';
    case 'completed':
    case 'reviewed':         return 'review_completed';
    default:                 return status || 'pending';
  }
}

function chatLoadAll() {
  try { return JSON.parse(localStorage.getItem('zitlas_chats') || '{}'); } catch(_) { return {}; }
}

function chatSaveAll(all) {
  try { localStorage.setItem('zitlas_chats', JSON.stringify(all)); } catch(_) {}
}

function chatGetConversation(conversationId) {
  return chatLoadAll()[conversationId] || null;
}

function chatGetExpertConversations(expertId) {
  var all = chatLoadAll();
  return Object.values(all).filter(function(c) { return c.expertId === expertId; });
}

function chatSaveExpertReply(conversationId, expert, text, imageUrl) {
  var all  = chatLoadAll();
  var conv = all[conversationId];
  if (!conv) return null;
  var msg = {
    id:             'msg_' + Date.now() + '_' + Math.random().toString(36).slice(2, 5),
    conversationId: conversationId,
    senderId:       expert.id,
    senderType:     'expert',
    text:           text,
    type:           imageUrl ? 'image' : 'text',
    imageUrl:       imageUrl || null,
    timestamp:      new Date().toISOString(),
  };
  conv.messages.push(msg);
  conv.lastMessage   = imageUrl ? '📷 Image' : text;
  conv.lastMessageAt = msg.timestamp;
  chatSaveAll(all);
  console.log('Message Sent', msg);
  _edSyncChatMessageToFirestore(conversationId, expert.id, conv.athleteId, msg);
  return msg;
}

function chatAppendMessage(conversationId, msg) {
  var all  = chatLoadAll();
  var conv = all[conversationId];
  if (!conv) return; /* conversation not yet created; athlete must initiate first */
  conv.messages = conv.messages || [];
  conv.messages.push(msg);
  conv.lastMessage   = msg.text || '';
  conv.lastMessageAt = msg.timestamp || new Date().toISOString();
  chatSaveAll(all);
  _edSyncChatMessageToFirestore(conversationId, conv.expertId, conv.athleteId, msg);
}

/* Mirrors every chat message into Firestore so the other participant's
   device (a different browser/localStorage) actually receives it.
   localStorage above remains this device's read cache — untouched. */
function _edSyncChatMessageToFirestore(chatId, currentUid, otherUid, payload) {
  if (typeof ZitlasDB === 'undefined') {
    console.warn('[CHAT] ZitlasDB unavailable — message saved to localStorage only');
    return;
  }
  console.log('[CHAT] current uid', currentUid);
  console.log('[CHAT] other uid', otherUid);
  console.log('[CHAT] chatId', chatId);
  console.log('[CHAT] payload', payload);
  console.log('[CHAT] before firestore write');
  var participants = [currentUid, otherUid].filter(Boolean);
  var conv = chatGetConversation(chatId) || {};
  ZitlasDB.collection('chat_rooms').doc(chatId).set({
    participants:  participants,
    athleteId:     conv.athleteId   || otherUid || '',
    athleteName:   conv.athleteName || 'Athlete',
    expertId:      conv.expertId    || currentUid || '',
    expertName:    conv.expertName  || (_currentExpert ? _currentExpert.name : 'Expert'),
    lastMessage:   payload.text || '',
    lastMessageAt: payload.timestamp || new Date().toISOString(),
    updatedAt:     firebase.firestore.FieldValue.serverTimestamp(),
  }, { merge: true })
    .then(function() {
      /* doc(payload.id) not add() — idempotent re-sync, no duplicates */
      return ZitlasDB.collection('chat_rooms').doc(chatId).collection('messages').doc(payload.id).set(payload);
    })
    .then(function() { console.log('[CHAT] firestore write success'); })
    .catch(function(err) { console.error('[CHAT] firestore write failed', err); });
}

function chatClearUnread(conversationId) {
  var all = chatLoadAll();
  if (all[conversationId]) {
    all[conversationId].unreadByExpert = 0;
    chatSaveAll(all);
    console.log('Expert Inbox Updated — unread cleared for', conversationId);
  }
}

/* ══════════════════════════════════════════════
   DATA HELPERS
   ══════════════════════════════════════════════ */

function getReviewRequest() {
  try {
    const raw = localStorage.getItem('zitlas_review_request');
    return raw ? JSON.parse(raw) : null;
  } catch { return null; }
}

function formatDate(isoStr) {
  if (!isoStr) return '';
  const d = new Date(isoStr);
  const now = new Date();
  const diffMs = now - d;
  const diffH  = Math.floor(diffMs / 3600000);
  const diffD  = Math.floor(diffMs / 86400000);
  if (diffH < 1)  return 'just now';
  if (diffH < 24) return diffH + 'h ago';
  if (diffD < 7)  return diffD + 'd ago';
  return d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' });
}

function statusBadge(status) {
  const map = {
    pending:                { cls: 'status-pending',    label: 'Pending Review' },
    accepted:               { cls: 'status-accepted',   label: 'Accepted · In Review' },
    completed:              { cls: 'status-completed',  label: 'Review Complete' },
    review_completed:       { cls: 'status-completed',  label: 'Review Sent' },
    rejected:               { cls: 'status-rejected',   label: 'Rejected' },
    /* Legacy statuses kept for backwards compat */
    expert_reviewing:       { cls: 'status-accepted',   label: 'In Review' },
    changes_suggested:      { cls: 'status-completed',  label: 'Feedback Sent' },
    approved:               { cls: 'status-completed',  label: 'Approved' },
    revised_plan_published: { cls: 'status-published',  label: 'Synced to Athlete' },
  };
  return map[status] || { cls: 'status-pending', label: status || 'Pending' };
}

/* ══════════════════════════════════════════════
   RENDER HEADER
   ══════════════════════════════════════════════ */

function renderHeader(expert) {
  const avatar = document.getElementById('edAvatar');
  const name   = document.getElementById('edHeaderName');
  const role   = document.getElementById('edHeaderRole');
  if (avatar) {
    if (expert.photo) {
      avatar.innerHTML = `<img src="${expert.photo}" alt="${expert.name}" style="width:100%;height:100%;object-fit:cover;border-radius:50%;" />`;
      avatar.style.background = 'none';
      avatar.style.border     = 'none';
    } else {
      avatar.textContent  = expert.initials;
      avatar.style.background = hexToGlow(expert.colorAccent);
    }
  }
  if (name) name.textContent = expert.firstName;
  if (role) role.textContent = expert.role;
}

function hexToGlow(hex) {
  return `linear-gradient(135deg, ${hex}33, ${hex}22)`;
}

/* ══════════════════════════════════════════════
   RENDER DASHBOARD SECTION
   ══════════════════════════════════════════════ */

function renderDashboard(expert) {
  /* Profile card */
  const epcAvatar  = document.getElementById('epcAvatar');
  const epcName    = document.getElementById('epcName');
  const epcRole    = document.getElementById('epcRole');
  const epcRating  = document.getElementById('epcRating');
  const epcReviews = document.getElementById('epcReviews');
  const epcFee     = document.getElementById('epcFee');
  const epcExp     = document.getElementById('epcExp');

  if (epcAvatar)  { epcAvatar.textContent = expert.initials; epcAvatar.style.background = hexToGlow(expert.colorAccent); epcAvatar.style.borderColor = expert.colorAccent + '44'; }
  if (epcName)    epcName.textContent = expert.name;
  if (epcRole)    epcRole.textContent = expert.role;
  if (epcRating)  epcRating.textContent = expert.rating;
  if (epcReviews) epcReviews.textContent = expert.reviewCount + ' reviews';
  if (epcFee)     epcFee.textContent = '₹' + expert.fee;
  if (epcExp)     epcExp.textContent = String(expert.experience || '').replace(' Experience', '');

  /* Stats initialised to zero; listenForReviews() updates them once data loads */
  setStatText('statPending',  'statPendingLabel',  0, 'Pending Reviews', "🎉 You're all caught up.");
  setStatText('statMessages', 'statMessagesLabel', 0, 'New Messages',    'No new messages right now.');
  setText('statClients',  0);
  setText('statEarnings', '₹0');
}

function setText(id, val) {
  const el = document.getElementById(id);
  if (el) el.textContent = val;
}

/* Premium empty state: replaces "0 / Pending Reviews" with a single warm
   sentence instead of a bare zero. Purely presentational — does not change
   what is counted, only how a zero result is displayed. */
function setStatText(numId, labelId, count, defaultLabel, emptyMessage) {
  const numEl   = document.getElementById(numId);
  const labelEl = document.getElementById(labelId);
  const card    = numEl ? numEl.closest('.ed-stat-card') : null;
  const isEmpty = count === 0;
  if (card) card.classList.toggle('ed-stat-card--empty', isEmpty);
  if (numEl)   numEl.textContent = isEmpty ? '' : count;
  if (labelEl) labelEl.textContent = isEmpty ? emptyMessage : defaultLabel;
}

/* ══════════════════════════════════════════════
   PLAN CONTENT BUILDERS
   ══════════════════════════════════════════════ */

function buildDietPlanHTML(dietPlan) {
  if (!dietPlan || !Array.isArray(dietPlan.days) || !dietPlan.days.length) {
    return '<p class="erc-no-data">Diet plan data not available.</p>';
  }
  const days      = dietPlan.days;
  const dayLabels = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

  let pills = '<div class="erc-day-pills">';
  days.forEach(function(d, i) {
    pills += '<button class="erc-day-pill' + (i === 0 ? ' active' : '') +
      '" data-diet-day="' + i + '">' + esc(dayLabels[i] || 'D' + (i + 1)) + '</button>';
  });
  pills += '</div>';

  let mealsWrap = '<div class="erc-meals-wrap">';
  days.forEach(function(d, i) {
    mealsWrap += '<div class="erc-day-content" data-diet-content="' + i + '" style="display:' + (i === 0 ? 'block' : 'none') + '">';
    if (d.theme)          mealsWrap += '<div class="erc-day-theme">' + esc(d.theme) + '</div>';
    if (d.total_calories) mealsWrap += '<div class="erc-day-total">' + esc(String(d.total_calories)) + ' kcal total</div>';
    (d.meals || []).forEach(function(meal) {
      const foods = Array.isArray(meal.foods) && meal.foods.length ? meal.foods.join(', ') : (meal.food_items || '');
      const meta  = [meal.calories ? meal.calories + ' kcal' : '', meal.protein_g ? meal.protein_g + 'g protein' : ''].filter(Boolean).join(' · ');
      mealsWrap += '<div class="erc-meal-row">' +
        '<div class="erc-meal-hdr">' +
          '<span class="erc-meal-emoji">' + esc(meal.emoji || '🍽️') + '</span>' +
          '<span class="erc-meal-name">' + esc(meal.meal_name || 'Meal') + '</span>' +
          (meal.time ? '<span class="erc-meal-time">' + esc(meal.time) + '</span>' : '') +
        '</div>' +
        (foods ? '<div class="erc-meal-foods">' + esc(foods) + '</div>' : '') +
        (meta  ? '<div class="erc-meal-meta">' + esc(meta) + '</div>' : '') +
        '</div>';
    });
    mealsWrap += '</div>';
  });
  mealsWrap += '</div>';

  let sub = '';
  if (dietPlan.daily_calories_target)  sub += dietPlan.daily_calories_target + ' kcal/day';
  if (dietPlan.daily_protein_target_g) sub += (sub ? ' · ' : '') + dietPlan.daily_protein_target_g + 'g protein';

  return '<div class="erc-plan-header">' +
      '<span class="erc-plan-icon">🥗</span>' +
      '<div><div class="erc-plan-title">' + esc(dietPlan.plan_name || 'AI Diet Plan') + '</div>' +
      (sub ? '<div class="erc-plan-sub">' + esc(sub) + '</div>' : '') + '</div>' +
    '</div>' + pills + mealsWrap;
}

function buildWorkoutPlanHTML(workoutPlan) {
  if (!workoutPlan) return '<p class="erc-no-data">Workout plan data not available.</p>';
  const wDays = workoutPlan.weekly_plan || workoutPlan.days || [];
  if (!wDays.length) return '<p class="erc-no-data">Workout plan data not available.</p>';
  const dayLabels = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

  let grid = '<div class="erc-workout-grid">';
  wDays.forEach(function(d, i) {
    const activity = d.focus || d.theme || d.type || d.activity || 'Training';
    const duration = d.duration_minutes ? d.duration_minutes + ' min' : (d.totalTime || '');
    const isRest   = /rest|recovery/i.test(activity);
    grid += '<div class="erc-workout-day' + (isRest ? ' erc-workout-rest' : '') + '">' +
      '<span class="erc-wo-day">' + esc(dayLabels[i] || 'D' + (i + 1)) + '</span>' +
      '<span class="erc-wo-activity">' + esc(activity) + '</span>' +
      (duration ? '<span class="erc-wo-dur">' + esc(duration) + '</span>' : '') +
      '</div>';
  });
  grid += '</div>';

  return '<div class="erc-plan-header">' +
      '<span class="erc-plan-icon">💪</span>' +
      '<div><div class="erc-plan-title">' + esc(workoutPlan.plan_name || 'AI Workout Plan') + '</div>' +
      (workoutPlan.goal ? '<div class="erc-plan-sub">' + esc(workoutPlan.goal) + '</div>' : '') + '</div>' +
    '</div>' + grid;
}

/* ══════════════════════════════════════════════
   REVIEW CARD BUILDER
   ══════════════════════════════════════════════ */

function buildReviewCard(req, expert) {
  const ctx         = req.context || {};
  const assessment  = ctx.assessment || ctx.survey || {};
  const calc        = ctx.calculations || {};
  const sb          = statusBadge(req.status);
  const isPending   = !req.status || req.status === 'pending';

  const athleteName   = req.athlete_name || 'Athlete';
  const goal          = assessment.goal || calc.goal || '—';
  const currentWeight = assessment.weight_kg || assessment.currentWeight || '—';
  const targetWeight  = assessment.goal_weight_kg || assessment.targetWeight || '—';
  const targetCal     = calc.weight_loss_calories_kcal || calc.tdee || calc.targetCalories || '—';
  const protein       = calc.protein_target_g || calc.protein || '—';
  const bmi           = calc.bmi ? parseFloat(calc.bmi).toFixed(1) : '—';

  const swotOuter = ctx.swot || {};
  const swot = swotOuter.swot || swotOuter;

  const card = document.createElement('div');
  card.className = 'ed-review-card';
  card.dataset.reqId = req.id;

  /* ── Expanded content (hidden by default) ── */
  const hasAssessment = !!(ctx.assessment || ctx.calculations);

  let assessmentHTML = '';
  if (hasAssessment) {
    const age      = assessment.age      || '—';
    const gender   = assessment.gender   ? (assessment.gender.charAt(0).toUpperCase() + assessment.gender.slice(1)) : '—';
    const height   = assessment.height_cm ? assessment.height_cm + ' cm' : '—';
    const activity = assessment.activity_level ? String(assessment.activity_level).replace(/_/g, ' ') : '—';
    const diet     = assessment.diet_preference ? String(assessment.diet_preference).replace(/_/g, ' ') : '—';
    const workout  = assessment.workout_preference ? String(assessment.workout_preference).replace(/_/g, ' ') : '—';

    assessmentHTML =
      '<div class="erc-exp-section">' +
        '<div class="erc-exp-label">Assessment</div>' +
        '<div class="erc-exp-data-grid">' +
          '<span class="erc-exp-item"><b>Age</b> ' + esc(age) + '</span>' +
          '<span class="erc-exp-item"><b>Gender</b> ' + esc(gender) + '</span>' +
          '<span class="erc-exp-item"><b>Height</b> ' + esc(height) + '</span>' +
          '<span class="erc-exp-item"><b>Activity</b> ' + esc(activity) + '</span>' +
          '<span class="erc-exp-item"><b>Diet</b> ' + esc(diet) + '</span>' +
          (workout !== '—' ? '<span class="erc-exp-item"><b>Workout Pref</b> ' + esc(workout) + '</span>' : '') +
        '</div>';

    if (calc.bmi) {
      const bmr  = calc.bmr_kcal  ? Math.round(calc.bmr_kcal)  : '—';
      const tdee = calc.tdee_kcal ? Math.round(calc.tdee_kcal) : '—';
      const water = calc.water_target_liters ? calc.water_target_liters + 'L' : '—';
      const steps = calc.daily_steps_goal ? Number(calc.daily_steps_goal).toLocaleString() : '—';
      assessmentHTML +=
        '<div class="erc-exp-sublabel">Fitness Snapshot</div>' +
        '<div class="erc-exp-data-grid">' +
          '<span class="erc-exp-item"><b>BMI</b> ' + esc(bmi) + (calc.bmi_category ? ' · ' + esc(calc.bmi_category) : '') + '</span>' +
          '<span class="erc-exp-item"><b>BMR</b> ' + esc(String(bmr)) + ' kcal</span>' +
          '<span class="erc-exp-item"><b>TDEE</b> ' + esc(String(tdee)) + ' kcal</span>' +
          '<span class="erc-exp-item"><b>Target Cal</b> ' + esc(String(targetCal)) + ' kcal</span>' +
          '<span class="erc-exp-item"><b>Protein</b> ' + esc(String(protein)) + 'g</span>' +
          '<span class="erc-exp-item"><b>Water</b> ' + esc(water) + '</span>' +
          '<span class="erc-exp-item"><b>Steps Goal</b> ' + esc(steps) + '</span>' +
        '</div>';
    }
    assessmentHTML += '</div>';
  }

  let swotHTML = '';
  if (ctx.swot) {
    const quads = [
      { key: 'strengths',     icon: '💪', label: 'Strengths' },
      { key: 'weaknesses',    icon: '⚠️', label: 'Weaknesses' },
      { key: 'opportunities', icon: '🎯', label: 'Opportunities' },
      { key: 'threats',       icon: '🔴', label: 'Threats' },
    ];
    swotHTML = '<div class="erc-exp-section"><div class="erc-exp-label">SWOT Report</div><div class="erc-swot-grid">';
    quads.forEach(function(q) {
      const items = (swot[q.key] || []).slice(0, 2);
      if (!items.length) return;
      swotHTML += '<div class="erc-swot-quad"><div class="erc-swot-qlabel">' + q.icon + ' ' + esc(q.label) + '</div>' +
        '<ul>' + items.map(function(t) {
          var text = typeof t === 'object' ? (t.title || '') : String(t || '');
          return '<li>' + esc(text) + '</li>';
        }).join('') + '</ul></div>';
    });
    swotHTML += '</div></div>';
  }

  let noteHTML = '';
  if (req.note) {
    noteHTML = '<div class="erc-exp-section"><div class="erc-exp-label">Athlete Note</div>' +
      '<p class="erc-exp-note">' + esc(req.note) + '</p></div>';
  }

  let dietHTML = '';
  if (ctx.diet_plan) {
    var _ctxDiet = ctx.diet_plan;
    if (_ctxDiet.originalDietPlan || _ctxDiet.currentDietPlan) {
      _ctxDiet = _ctxDiet.currentDietPlan || _ctxDiet.originalDietPlan;
    }
    dietHTML = '<div class="erc-exp-section"><div class="erc-exp-label">AI Diet Plan</div>' +
      '<div class="erc-plan-wrap">' + buildDietPlanHTML(_ctxDiet) + '</div></div>';
  }

  let workoutHTML = '';
  if (ctx.workout_plan) {
    workoutHTML = '<div class="erc-exp-section"><div class="erc-exp-label">AI Workout Plan</div>' +
      '<div class="erc-plan-wrap">' + buildWorkoutPlanHTML(ctx.workout_plan) + '</div></div>';
  }

  const fileHTML = req.hasFile && req.fileName
    ? '<div class="erc-exp-section"><div class="erc-exp-label">Attached File</div>' +
      '<span class="erc-file-chip">📎 ' + esc(req.fileName) + '</span></div>'
    : '';

  /* ── Action buttons based on status ── */
  const isReviewing = req.status === 'expert_reviewing';
  const isDone      = req.status === 'approved' || req.status === 'revised_plan_published';

  const startReviewBtn = isPending
    ? '<button class="erc-btn erc-btn--secondary erc-start-review" data-req-id="' + esc(req.id) + '">▶ Start Review</button>'
    : '';
  const approveBtn = isReviewing
    ? '<button class="erc-btn erc-btn--approve erc-approve-plan" data-req-id="' + esc(req.id) + '">✅ Approve Plan</button>'
    : '';
  const modifyBtn = (isPending || isReviewing)
    ? '<a class="erc-btn erc-btn--secondary" href="../coaches/expert-review.html">✏️ Modify &amp; Send</a>'
    : '';
  const viewBtn = isDone
    ? '<a class="erc-btn erc-btn--secondary" href="../coaches/expert-review.html">View Review</a>'
    : '';

  card.innerHTML =
    /* Header */
    '<div class="erc-header">' +
      '<div class="erc-athlete-name">' + esc(athleteName) + '</div>' +
      '<span class="erc-badge ' + sb.cls + '">' + esc(sb.label) + '</span>' +
    '</div>' +
    '<div class="erc-meta-row">' +
      '<span class="erc-goal-type">' + esc(goal) + ' Goal</span>' +
      '<span class="erc-fee-time">₹' + expert.fee + ' · ' + formatDate(req.submittedAt) + '</span>' +
    '</div>' +
    /* Stats */
    '<div class="erc-stats-grid">' +
      (currentWeight !== '—' ? '<div class="erc-stat"><span class="erc-stat-label">Current Weight</span><span class="erc-stat-val">' + esc(String(currentWeight)) + ' kg</span></div>' : '') +
      (targetWeight  !== '—' ? '<div class="erc-stat"><span class="erc-stat-label">Target Weight</span><span class="erc-stat-val">' + esc(String(targetWeight))  + ' kg</span></div>' : '') +
      (targetCal     !== '—' ? '<div class="erc-stat"><span class="erc-stat-label">Calories</span><span class="erc-stat-val">' + esc(String(targetCal)) + ' kcal</span></div>' : '') +
      (protein       !== '—' ? '<div class="erc-stat"><span class="erc-stat-label">Protein Target</span><span class="erc-stat-val">' + esc(String(protein)) + 'g</span></div>' : '') +
    '</div>' +
    /* Document badges */
    '<div class="erc-docs-row">' +
      (hasAssessment     ? '<span class="erc-doc-chip">📊 Assessment</span>' : '') +
      (ctx.calculations  ? '<span class="erc-doc-chip">🏋️ Fitness</span>'   : '') +
      (ctx.swot          ? '<span class="erc-doc-chip">🔍 SWOT</span>'       : '') +
      (ctx.diet_plan     ? '<span class="erc-doc-chip">🥗 Diet Plan</span>'  : '') +
      (ctx.workout_plan  ? '<span class="erc-doc-chip">💪 Workout Plan</span>' : '') +
    '</div>' +
    /* Expert note (if already approved) */
    (req.expertNotes ? '<div class="erc-expert-note"><span class="erc-expert-note-label">Your Notes:</span> ' + esc(req.expertNotes) + '</div>' : '') +
    /* Expand toggle */
    '<button class="erc-expand-toggle">View Full Details ▼</button>' +
    /* Expanded content */
    '<div class="erc-expanded" style="display:none">' +
      assessmentHTML + swotHTML + noteHTML + dietHTML + workoutHTML + fileHTML +
    '</div>' +
    /* Actions */
    '<div class="erc-actions">' +
      startReviewBtn + approveBtn + modifyBtn + viewBtn +
    '</div>';

  return card;
}

/* Wire all interactive elements inside a review card */
function initCardInteractions(card, req, expert) {
  /* Expand toggle */
  const toggle   = card.querySelector('.erc-expand-toggle');
  const expanded = card.querySelector('.erc-expanded');
  if (toggle && expanded) {
    toggle.addEventListener('click', function() {
      const open = expanded.style.display !== 'none';
      expanded.style.display = open ? 'none' : 'block';
      toggle.textContent     = open ? 'View Full Details ▼' : 'Hide Details ▲';
    });
  }

  /* Diet plan day pills (event delegation within this card) */
  card.addEventListener('click', function(e) {
    const pill = e.target.closest('[data-diet-day]');
    if (pill && card.contains(pill)) {
      const dayIdx = parseInt(pill.dataset.dietDay, 10);
      card.querySelectorAll('[data-diet-day]').forEach(function(p) { p.classList.remove('active'); });
      pill.classList.add('active');
      card.querySelectorAll('[data-diet-content]').forEach(function(c) {
        c.style.display = parseInt(c.dataset.dietContent, 10) === dayIdx ? 'block' : 'none';
      });
    }

    /* Start Review button */
    const startBtn = e.target.closest('.erc-start-review');
    if (startBtn) {
      const reqId = startBtn.dataset.reqId;
      updateReviewStatus(reqId, 'expert_reviewing', card, expert);
      /* Swap Start Review button for Approve + Modify buttons */
      const actions = card.querySelector('.erc-actions');
      if (actions) {
        actions.innerHTML =
          '<button class="erc-btn erc-btn--approve erc-approve-plan" data-req-id="' + reqId + '">✅ Approve Plan</button>' +
          '<a class="erc-btn erc-btn--secondary" href="../coaches/expert-review.html">✏️ Modify &amp; Send</a>';
      }
    }

    /* Approve Plan button */
    const approveBtn = e.target.closest('.erc-approve-plan');
    if (approveBtn) {
      openApproveModal(approveBtn.dataset.reqId, card, expert);
    }
  });
}

/* Update review status in localStorage + Firestore */
function updateReviewStatus(reqId, newStatus, card, expert) {
  /* localStorage */
  try {
    const raw = localStorage.getItem('zitlas_review_request');
    if (raw) {
      const req = JSON.parse(raw);
      if (req.id === reqId) {
        req.status = newStatus;
        localStorage.setItem('zitlas_review_request', JSON.stringify(req));
      }
    }
  } catch (_) {}

  /* Firestore */
  if (typeof ZitlasDB !== 'undefined') {
    ZitlasDB.collection('review_requests').doc(reqId)
      .update({ status: newStatus })
      .catch(function(e) { console.warn('[ZITLAS] status update failed:', e); });
  }

  /* Update badge in card without full re-render */
  if (card) {
    const badge = card.querySelector('.erc-badge');
    const sb    = statusBadge(newStatus);
    if (badge) { badge.textContent = sb.label; badge.className = 'erc-badge ' + sb.cls; }
    const startBtn = card.querySelector('.erc-start-review');
    if (startBtn) startBtn.remove();
  }
}

/* ══════════════════════════════════════════════
   TOAST
   ══════════════════════════════════════════════ */

function edShowToast(msg, duration) {
  var existing = document.getElementById('edToast');
  if (existing) existing.remove();
  var t = document.createElement('div');
  t.id = 'edToast';
  t.textContent = msg;
  Object.assign(t.style, {
    position:       'fixed',
    bottom:         '100px',
    left:           '50%',
    transform:      'translateX(-50%)',
    background:     'var(--border)',
    color:          'var(--text-primary)',
    fontSize:       '13px',
    fontWeight:     '600',
    padding:        '10px 20px',
    borderRadius:   '40px',
    zIndex:         '10000',
    pointerEvents:  'none',
    boxShadow:      '0 4px 20px rgba(var(--black-rgb),0.5)',
    whiteSpace:     'nowrap',
    opacity:        '0',
    transition:     'opacity 0.22s',
  });
  document.body.appendChild(t);
  requestAnimationFrame(function() { t.style.opacity = '1'; });
  setTimeout(function() {
    t.style.opacity = '0';
    setTimeout(function() { t.remove(); }, 250);
  }, duration || 3000);
}

/* ══════════════════════════════════════════════
   APPROVE MODAL
   ══════════════════════════════════════════════ */

var _approveCtx = { reqId: null, card: null, expert: null };

function openApproveModal(reqId, card, expert) {
  _approveCtx = { reqId: reqId, card: card, expert: expert };
  var modal = document.getElementById('approveModal');
  var input = document.getElementById('approveNotesInput');
  if (!modal) return;
  if (input) input.value = '';
  modal.style.display = 'flex';
  setTimeout(function() { modal.classList.add('open'); }, 10);
  if (input) input.focus();
}

function closeApproveModal() {
  var modal = document.getElementById('approveModal');
  if (!modal) return;
  modal.classList.remove('open');
  setTimeout(function() { modal.style.display = 'none'; }, 220);
  _approveCtx = { reqId: null, card: null, expert: null };
}

function confirmApprove() {
  var notes  = (document.getElementById('approveNotesInput') || {}).value || '';
  var ctx    = _approveCtx;
  if (!ctx.reqId) return;

  /* Update localStorage */
  try {
    var raw = localStorage.getItem('zitlas_review_request');
    if (raw) {
      var req = JSON.parse(raw);
      if (req.id === ctx.reqId) {
        req.status      = 'approved';
        req.expertNotes = notes || null;
        req.approvedAt  = new Date().toISOString();
        req.expertId    = ctx.expert.id;
        req.expertName  = ctx.expert.name;
        localStorage.setItem('zitlas_review_request', JSON.stringify(req));
      }
    }
  } catch (_) {}

  /* Write expert review object so diet.html shows Expert Verified badge */
  try {
    var erObj = {
      status:      'APPROVED',
      reviewedBy:  ctx.expert.name,
      reviewedAt:  new Date().toISOString(),
      expertId:    ctx.expert.id,
      notes:       notes || null,
      planId:      null,
    };
    localStorage.setItem('zitlas_expert_review', JSON.stringify(erObj));
  } catch (_) {}

  /* Send to backend */
  fetch('/api/review/' + ctx.reqId + '/approve', {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({
      expertId:    ctx.expert.id,
      expertName:  ctx.expert.name,
      status:      'approved',
      expertNotes: notes || null,
    }),
  }).catch(function() {});

  /* Update card UI */
  if (ctx.card) {
    const badge = ctx.card.querySelector('.erc-badge');
    const sb    = statusBadge('approved');
    if (badge) { badge.textContent = sb.label; badge.className = 'erc-badge ' + sb.cls; }
    const actions = ctx.card.querySelector('.erc-actions');
    if (actions) {
      actions.innerHTML = '<span class="erc-approved-stamp">✅ Plan Approved</span>' +
        '<a class="erc-btn erc-btn--secondary" href="../coaches/expert-review.html">View Details</a>';
    }
    if (notes) {
      var noteEl = ctx.card.querySelector('.erc-expert-note');
      if (!noteEl) {
        var docsRow = ctx.card.querySelector('.erc-docs-row');
        if (docsRow) {
          var nd = document.createElement('div');
          nd.className = 'erc-expert-note';
          nd.innerHTML = '<span class="erc-expert-note-label">Your Notes:</span> ' + esc(notes);
          docsRow.insertAdjacentElement('afterend', nd);
        }
      } else {
        noteEl.innerHTML = '<span class="erc-expert-note-label">Your Notes:</span> ' + esc(notes);
      }
    }
  }

  closeApproveModal();
  edShowToast('✅ Plan approved! Athlete has been notified.');
}

function initApproveModal() {
  var closeBtn   = document.getElementById('approveModalClose');
  var cancelBtn  = document.getElementById('approveModalCancel');
  var confirmBtn = document.getElementById('approveModalConfirm');
  var overlay    = document.getElementById('approveModal');

  if (closeBtn)   closeBtn.addEventListener('click',   closeApproveModal);
  if (cancelBtn)  cancelBtn.addEventListener('click',  closeApproveModal);
  if (confirmBtn) confirmBtn.addEventListener('click', confirmApprove);
  if (overlay)    overlay.addEventListener('click', function(e) { if (e.target === overlay) closeApproveModal(); });
}

/* ══════════════════════════════════════════════
   FILTER TABS
   ══════════════════════════════════════════════ */

var _allRequests = [];
var _currentFilter = 'all';

function initFilterTabs() {
  var tabs = document.getElementById('ercFilterTabs');
  if (!tabs) return;
  tabs.addEventListener('click', function(e) {
    var tab = e.target.closest('.erc-filter-tab');
    if (!tab) return;
    tabs.querySelectorAll('.erc-filter-tab').forEach(function(t) { t.classList.remove('active'); });
    tab.classList.add('active');
    _currentFilter = tab.dataset.filter || 'all';
    applyFilter();
  });
}

function applyFilter() {
  var wrap = document.getElementById('reviewsListWrap') || document.getElementById('prInboxList');
  if (!wrap) return;
  wrap.querySelectorAll('.ed-review-card').forEach(function(card) {
    var status = card.dataset.status || '';
    var show = _currentFilter === 'all' || status === _currentFilter;
    card.style.display = show ? '' : 'none';
  });
}

/* ══════════════════════════════════════════════
   DASHBOARD STATS UPDATE
   ══════════════════════════════════════════════ */

function updateDashboardStats(requests, expert) {
  const pending  = requests.filter(function(r) { return !r.status || r.status === 'pending' || r.status === 'expert_reviewing'; });
  const clients  = requests.length;
  const approved = requests.filter(function(r) { return r.status === 'approved' || r.status === 'revised_plan_published'; });
  const earnings = approved.length * expert.fee;

  setStatText('statPending', 'statPendingLabel', pending.length, 'Pending Reviews', "🎉 You're all caught up.");
  setText('statClients',  clients);
  setText('statEarnings', earnings > 0 ? '₹' + earnings : '₹0');

  const badge = document.getElementById('navBadgeReviews');
  if (badge) {
    const pCount = requests.filter(function(r) { return !r.status || r.status === 'pending'; }).length;
    badge.textContent    = pCount;
    badge.style.display  = pCount > 0 ? 'flex' : 'none';
  }
}

/* ══════════════════════════════════════════════
   RENDER REVIEW REQUESTS SECTION
   ══════════════════════════════════════════════ */

function renderReviewsFromList(requests, expert) {
  const wrap  = document.getElementById('reviewsListWrap') || document.getElementById('prInboxList');
  const empty = document.getElementById('reviewsEmpty');
  if (!wrap) { console.error('[ZITLAS] No reviews container found (reviewsListWrap, prInboxList)'); return; }

  /* Cache latest request to localStorage so expert-review.html can read it */
  if (requests.length > 0) {
    try { localStorage.setItem('zitlas_review_request', JSON.stringify(requests[0])); } catch (_) {}
  }

  if (!requests.length) {
    wrap.innerHTML = '';
    if (empty) empty.style.display = '';
    return;
  }
  if (empty) empty.style.display = 'none';

  _allRequests = requests;
  wrap.innerHTML = '';
  requests.forEach(function(req) {
    const card = buildReviewCard(req, expert);
    card.dataset.status = req.status || 'pending';
    wrap.appendChild(card);
    initCardInteractions(card, req, expert);
  });
  applyFilter();
}

/* Firestore onSnapshot + localStorage fallback */
function listenForReviews(expert) {
  /* Always prefer the live Firebase uid — never trust a cached/computed id */
  const currentUid = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
    ? ZitlasAuth.currentUser.uid
    : expert.id;
  const queryId = currentUid || expert.id || '';

  console.log('CURRENT UID', currentUid);
  console.log('LOCAL EXPERT', expert);

  /*
   * Only use Firestore when there is an active Firebase authenticated session.
   * firebase-config.js always defines ZitlasDB (even with placeholder credentials),
   * so checking typeof alone is not enough — we must also confirm currentUser is set.
   */
  const hasFirebaseSession = (
    typeof ZitlasAuth !== 'undefined' &&
    ZitlasAuth.currentUser !== null
  );

  console.log('[ZITLAS] Firebase session active:', hasFirebaseSession, '| queryId:', queryId);

  if (hasFirebaseSession && typeof ZitlasDB !== 'undefined') {
    console.log('[ZITLAS] Using Firestore listener for reviews');
    let query;
    try {
      /* No orderBy — avoids composite index requirement. We sort client-side below. */
      query = ZitlasDB.collection('review_requests')
        .where('expertId', '==', queryId);
    } catch (err) {
      console.warn('[ZITLAS] Firestore query build failed, falling back:', err);
      fallbackLocalStorageReviews(expert);
      return;
    }

    query.onSnapshot(function(snapshot) {
      const requests = snapshot.docs
        .map(function(doc) { return doc.data(); })
        .sort(function(a, b) {
          /* Sort newest-first using submittedAt or createdAt */
          var ta = a.submittedAt || a.createdAt || '';
          var tb = b.submittedAt || b.createdAt || '';
          return tb > ta ? 1 : tb < ta ? -1 : 0;
        });
      const pendingReviews = requests.filter(function(r) { return r.status === 'pending'; });
      console.log('[REVIEWS] current expert uid', queryId);
      console.log('[REVIEWS] snapshot loaded', requests.length);
      requests.forEach(function(r) {
        console.log('[REVIEWS] review document', r);
        console.log('[REVIEWS] expertId in review', r.expertId);
      });
      console.log('[ZITLAS] Firestore snapshot — loaded reviews:', requests.length, '| pending:', pendingReviews.length);

      /* Sync Firestore reviews into expert_plan_reviews (cache).
         Always stamp expertId from live Firebase UID so getPlanReviews() filter matches.
         Normalize status to canonical values on the way in. */
      try {
        var local = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
        requests.forEach(function(req) {
          if (!req.id) return;
          var canonicalStatus = _normalizeStatus(req.status);
          var idx = local.findIndex(function(r) { return r.id === req.id; });
          if (idx === -1) {
            local.push(Object.assign({}, req, { expertId: queryId, status: canonicalStatus }));
          } else {
            /* Firestore is authoritative for all status transitions */
            local[idx] = Object.assign({}, local[idx], req, {
              expertId: queryId,
              status:   canonicalStatus,
            });
          }
        });
        localStorage.setItem('expert_plan_reviews', JSON.stringify(local));
        console.log('[REVIEW] fetched', requests.length, 'reviews; pending:', pendingReviews.length);
      } catch (_) {}

      /* renderInbox owns prInboxList — always call it after sync.
         Pass queryId so getPlanReviews always uses the live Firebase UID. */
      renderInbox(expert, queryId);
      renderChatsFromList(requests);
      updateDashboardStats(requests, expert);
    }, function(err) {
      console.warn('[ZITLAS] Firestore onSnapshot error, falling back to localStorage:', err);
      fallbackLocalStorageReviews(expert);
    });
  } else {
    console.log('[ZITLAS] No Firebase session — using localStorage fallback');
    fallbackLocalStorageReviews(expert);
  }
}

function fallbackLocalStorageReviews(expert) {
  function getLocalRequests() {
    const raw = localStorage.getItem('zitlas_review_request');
    console.log('[ZITLAS] localStorage zitlas_review_request raw:', raw ? raw.slice(0, 120) + '…' : 'null');
    let req = null;
    try { req = raw ? JSON.parse(raw) : null; } catch (e) { console.error('[ZITLAS] Failed to parse review request:', e); }
    if (!req) { console.log('[ZITLAS] No review request in localStorage'); return []; }
    console.log('[ZITLAS] Review expertId:', req.expertId, '| Expert id:', expert.id, '| Match:', req.expertId === expert.id);
    return (!req.expertId || req.expertId === expert.id) ? [req] : [];
  }

  const requests = getLocalRequests();
  console.log('[ZITLAS] Loaded reviews (localStorage):', requests.length, requests);
  renderReviewsFromList(requests, expert);
  renderChatsFromList(requests);
  updateDashboardStats(requests, expert);

  /* Pick up reviews submitted while the dashboard is open (cross-tab) */
  window.addEventListener('storage', function(e) {
    if (e.key === 'zitlas_review_request') {
      console.log('[ZITLAS] storage event fired — re-reading reviews');
      const updated = getLocalRequests();
      renderReviewsFromList(updated, expert);
      renderChatsFromList(updated);
      updateDashboardStats(updated, expert);
    }
  });
}

/* ══════════════════════════════════════════════
   RENDER CLIENT CHATS SECTION
   ══════════════════════════════════════════════ */

function renderChatsFromList(requests) {
  const wrap  = document.getElementById('chatsListWrap');
  const empty = document.getElementById('chatsEmpty');
  if (!wrap) return;

  const expert = getExpert();

  /* Real chat conversations from localStorage */
  var rawConvList = chatGetExpertConversations(expert.id);

  /* For each real conversation, compute the effective visible messages
     (those after the hiddenForExpert cutoff, if any). Discard the
     conversation entirely if no messages survive the cutoff. */
  var convList = [];
  rawConvList.forEach(function(conv) {
    var cutoff = conv.hiddenForExpert || null;
    var effectiveMsgs = (conv.messages || []).filter(function(m) {
      if (!cutoff) return true;
      if (!m.timestamp) return false;      /* no timestamp → predates cutoff, hide it */
      return m.timestamp > cutoff;
    });

    /* Drop conversations with no visible messages */
    if (effectiveMsgs.length === 0) return;

    /* Use the last visible message as the preview */
    var lastVisible = effectiveMsgs[effectiveMsgs.length - 1];
    convList.push(Object.assign({}, conv, {
      _effectiveMsgs:  effectiveMsgs,
      lastMessage:     lastVisible.text || conv.lastMessage || '',
      lastMessageAt:   lastVisible.timestamp || conv.lastMessageAt,
    }));
  });

  /* Global guard: never render conversations with no visible messages */
  convList = convList.filter(function(c) {
    return c._effectiveMsgs && c._effectiveMsgs.length > 0;
  });

  if (!convList.length) {
    wrap.innerHTML = '';
    if (empty) empty.style.display = '';
    return;
  }
  if (empty) empty.style.display = 'none';

  /* Sort: most recent visible message first */
  convList.sort(function(a, b) {
    var ta = a.lastMessageAt ? new Date(a.lastMessageAt).getTime() : 0;
    var tb = b.lastMessageAt ? new Date(b.lastMessageAt).getTime() : 0;
    return tb - ta;
  });

  wrap.innerHTML = '';

  convList.forEach(function(conv) {
    const athleteName = conv.athleteName || 'Athlete';
    const initials    = athleteName.split(' ').map(function(w) { return w[0]; }).join('').slice(0,2).toUpperCase();
    const lastMsg     = conv.lastMessage || 'No messages yet.';
    const timeStr     = formatDate(conv.lastMessageAt);
    const unread      = conv.unreadByExpert || 0;
    const status      = conv._reviewStatus || null;
    const sb          = status ? statusBadge(status) : null;

    const card = document.createElement('div');
    card.className = 'ed-chat-card';
    card.innerHTML =
      '<div class="ecc-header">' +
        '<div class="ecc-avatar">' + esc(initials) + '</div>' +
        '<div class="ecc-info">' +
          '<span class="ecc-name">' + esc(athleteName) + '</span>' +
          '<span class="ecc-sub">' + (conv.conversationId ? 'Client Chat' : 'Diet Plan Review') + '</span>' +
        '</div>' +
        '<div class="ecc-header-right">' +
          (timeStr ? '<span class="ecc-time">' + esc(timeStr) + '</span>' : '') +
          (unread > 0 ? '<span class="ecc-unread-badge">' + unread + '</span>' : '') +
        '</div>' +
      '</div>' +
      '<p class="ecc-preview">"' + esc(lastMsg.slice(0, 80)) + (lastMsg.length > 80 ? '…' : '') + '"</p>' +
      (sb ? '<div class="ecc-status-row"><span class="erc-badge ' + sb.cls + '">' + esc(sb.label) + '</span></div>' : '') +
      '<div class="ecc-actions">' +
        (conv.conversationId
          ? '<button class="erc-btn erc-btn--primary ecc-chat-btn" data-conv-id="' + esc(conv.conversationId) + '" data-athlete-name="' + esc(athleteName) + '">Open Chat</button>'
          : '') +
        '<a class="erc-btn erc-btn--secondary ecc-open-btn" href="../coaches/expert-review.html">Open Review →</a>' +
      '</div>';

    wrap.appendChild(card);
  });

  /* Wire "Open Chat" buttons */
  wrap.querySelectorAll('.ecc-chat-btn').forEach(function(btn) {
    btn.addEventListener('click', function() {
      openExpertChat(btn.dataset.convId, btn.dataset.athleteName);
    });
  });
}

/* ══════════════════════════════════════════════
   EXPERT CHAT OVERLAY
   ══════════════════════════════════════════════ */

function openExpertChat(conversationId, athleteName) {
  const overlay  = document.getElementById('edChatOverlay');
  const msgWrap  = document.getElementById('edChatMessages');
  const nameEl   = document.getElementById('edChatAthleteName');
  const avatarEl = document.getElementById('edChatAvatar');
  if (!overlay || !msgWrap) return;

  _edChatConversationId = conversationId;

  var name = athleteName || 'Athlete';
  if (nameEl) nameEl.textContent = name;
  if (avatarEl) {
    avatarEl.textContent = name.split(' ').map(function(w) { return w[0] || ''; }).join('').slice(0, 2).toUpperCase() || 'A';
  }

  chatClearUnread(conversationId);

  const conv = chatGetConversation(conversationId);

  /* Hide the review banner — we show the packet inline in messages instead */
  populateReviewBanner(null);

  renderExpertChatMessages(msgWrap, conversationId);
  startExpertChatMessagesListener(conversationId);
  startExpertIncomingCallListener(conversationId, conv ? conv.athleteId : null, name);
  _applyExpertChatReadOnlyState();

  overlay.classList.add('open');
  document.body.style.overflow = 'hidden';
  msgWrap.scrollTop = msgWrap.scrollHeight;

  const input = document.getElementById('edChatInput');
  if (input) setTimeout(function() { input.focus(); }, 280);
}

/* Renders conv.messages into msgWrap. Shared by the initial chat-open
   render and by the realtime Firestore listener below. */
function renderExpertChatMessages(msgWrap, conversationId) {
  const conv = chatGetConversation(conversationId);
  msgWrap.innerHTML = '';

  if (conv && conv.messages && conv.messages.length) {
    /* Only show messages AFTER the expert's clear point (if any) */
    var hiddenCutoff = conv.hiddenForExpert || null;
    var prevMsg = null;
    var prevDay = null;
    conv.messages.forEach(function(msg) {
      /* Skip messages at or before the clear timestamp */
      if (hiddenCutoff && msg.timestamp && msg.timestamp <= hiddenCutoff) return;

      /* Review packet — render full context cards inline */
      if (msg.type === 'review_packet') {
        if (!hiddenCutoff || (msg.timestamp && msg.timestamp > hiddenCutoff)) {
          renderReviewPacketIntoContainer(msg, msgWrap);
        }
        prevMsg = null;
        return;
      }

      var msgDay = msg.timestamp ? new Date(msg.timestamp).toDateString() : null;
      if (msgDay && msgDay !== prevDay) {
        msgWrap.appendChild(edBuildZcDaySep(msg.timestamp));
        prevDay = msgDay;
      }
      var grouped = edZcIsGrouped(prevMsg, msg);
      msgWrap.appendChild(buildExpertChatBubble(msg, conv.expertName || 'Expert', grouped));
      prevMsg = msg;
    });

    /* If everything is hidden, show the cleared state */
    if (!msgWrap.children.length) {
      var clearedEl = document.createElement('div');
      clearedEl.className = 'zc-empty';
      clearedEl.textContent = 'Chat cleared. New messages will appear here.';
      msgWrap.appendChild(clearedEl);
    }
  } else {
    var emptyEl = document.createElement('div');
    emptyEl.className = 'zc-empty';
    emptyEl.textContent = 'No messages yet. The athlete will see your reply instantly.';
    msgWrap.appendChild(emptyEl);
  }
}

/* ══════════════════════════════════════════════
   REALTIME CHAT — Firestore is the source of truth for cross-device
   delivery. localStorage remains the render cache; this listener keeps
   it in sync so a message sent from the athlete's device appears here
   without a refresh.
   ══════════════════════════════════════════════ */
var _edChatMsgListeners = {};  /* conversationId → true once a listener is attached */

function startExpertChatMessagesListener(conversationId) {
  if (typeof ZitlasDB === 'undefined' || !conversationId) return;
  if (_edChatMsgListeners[conversationId]) return; /* already listening */
  _edChatMsgListeners[conversationId] = true;

  ZitlasDB.collection('chat_rooms').doc(conversationId).collection('messages')
    .orderBy('timestamp')
    .onSnapshot(function(snapshot) {
      console.log('[CHAT] snapshot received', snapshot.size, 'messages for', conversationId);
      var incoming = snapshot.docs.map(function(d) { return d.data(); });

      var all  = chatLoadAll();
      var conv = all[conversationId];
      if (!conv) {
        /* Conversation was started on the athlete's device — it has never
           existed in this browser's localStorage. Seed it so messages have
           somewhere to land; metadata is refined by listenForChatRooms. */
        conv = all[conversationId] = {
          conversationId: conversationId,
          athleteId:      '',
          athleteName:    'Athlete',
          expertId:       (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) ? ZitlasAuth.currentUser.uid : '',
          expertName:     _currentExpert ? _currentExpert.name : 'Expert',
          messages:       [],
          lastMessage:    '',
          lastMessageAt:  null,
          unreadByExpert: 0,
        };
      }

      var localMsgs = conv.messages || [];
      var localIds  = {};
      localMsgs.forEach(function(m) { localIds[m.id] = true; });

      var added = false;
      incoming.forEach(function(m) {
        if (m.id && !localIds[m.id]) {
          localMsgs.push(m);
          localIds[m.id] = true;
          added = true;
        }
      });
      if (!added) return;

      localMsgs.sort(function(a, b) { return (a.timestamp || '') < (b.timestamp || '') ? -1 : 1; });
      conv.messages = localMsgs;
      var last = localMsgs[localMsgs.length - 1];
      if (last) {
        conv.lastMessage   = last.type === 'review_packet' ? '📋 Plan review packet' : (last.text || '');
        conv.lastMessageAt = last.timestamp;
      }
      chatSaveAll(all);

      /* Keep the Client Chats inbox previews live */
      renderChatsFromList([]);

      /* Re-render the thread only if this conversation's chat is currently open */
      var overlay = document.getElementById('edChatOverlay');
      var msgWrap = document.getElementById('edChatMessages');
      if (overlay && overlay.classList.contains('open') && _edChatConversationId === conversationId && msgWrap) {
        renderExpertChatMessages(msgWrap, conversationId);
        msgWrap.scrollTop = msgWrap.scrollHeight;
      }
    }, function(err) {
      console.error('[CHAT] messages listener error', err);
    });
}

/* ══════════════════════════════════════════════
   MY ATHLETES — personal coaching clients
   Reads personal_coaching where coachId == live uid (realtime). A doc's
   status/endDate decides activity; ended relationships simply drop out.
   ══════════════════════════════════════════════ */
function listenForMyAthletes(expert) {
  if (typeof ZitlasDB === 'undefined') return;
  var uid = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
    ? ZitlasAuth.currentUser.uid
    : (expert && expert.id);
  if (!uid) return;
  if (listenForMyAthletes._attachedFor === uid) return;
  listenForMyAthletes._attachedFor = uid;

  console.log('[COACHING] listening: personal_coaching.where(coachId ==', uid + ')');
  ZitlasDB.collection('personal_coaching')
    .where('coachId', '==', uid)
    .onSnapshot(function(snap) {
      var all = snap.docs.map(function(d) { return d.data(); });

      /* Keyed by athleteId so the chat overlay can tell whether the
         conversation it's showing belongs to an ended relationship and
         should be locked read-only — see _pcChatIsReadOnlyFor(). */
      _pcRelByAthlete = {};
      all.forEach(function(r) { if (r.athleteId) _pcRelByAthlete[r.athleteId] = r; });
      _applyExpertChatReadOnlyState();

      var rels = all.filter(function(r) {
        return typeof ZitlasCoachingGate !== 'undefined'
          ? ZitlasCoachingGate.evaluate(r).active
          : (r.status === 'active' && (!r.endDate || new Date(r.endDate) > new Date()));
      });
      console.log('[COACHING] active athletes:', rels.length);
      renderMyAthletes(rels, expert);
    }, function(err) { console.warn('[COACHING] athletes listener error', err); });
}

function renderMyAthletes(rels, expert) {
  var wrap  = document.getElementById('myAthletesList');
  var empty = document.getElementById('myAthletesEmpty');
  if (!wrap) return;

  if (!rels.length) {
    wrap.querySelectorAll('.ed-athlete-card').forEach(function(el) { el.remove(); });
    if (empty) empty.style.display = '';
    return;
  }
  if (empty) empty.style.display = 'none';
  wrap.querySelectorAll('.ed-athlete-card').forEach(function(el) { el.remove(); });

  rels.forEach(function(rel) {
    var daysLeft = (typeof ZitlasCoachingGate !== 'undefined')
      ? ZitlasCoachingGate.evaluate(rel).daysRemaining
      : (rel.endDate ? Math.max(0, Math.ceil((new Date(rel.endDate) - new Date()) / 86400000)) : null);
    var lowDays  = daysLeft !== null && daysLeft <= 7;
    var name     = rel.athleteName || 'Athlete';
    var initials = name.split(/\s+/).map(function(w) { return w[0] || ''; }).slice(0, 2).join('').toUpperCase();

    var _trialTag = rel.coachingType === 'FREE_TRIAL'
      ? ' <span style="background:linear-gradient(135deg,var(--ai-accent,#3B82F6),#2563EB);color:#fff;font-weight:800;border-radius:999px;padding:1px 8px;font-size:9px;letter-spacing:.04em;vertical-align:middle;">FREE TRIAL</span>'
      : '';
    var card = document.createElement('div');
    card.className = 'ed-athlete-card';
    card.innerHTML =
      '<div class="ed-athlete-av">' + esc(initials) + '</div>' +
      '<div class="ed-athlete-info">' +
        '<span class="ed-athlete-name">' + esc(name) + _trialTag + '</span>' +
        '<span class="ed-athlete-sub' + (lowDays ? ' ed-athlete-sub--warn' : '') + '">' +
          (lowDays ? '⚠ ' : '') + 'Coaching since ' +
          esc(new Date(rel.startDate).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })) +
          (daysLeft !== null ? ' · ' + daysLeft + (daysLeft === 1 ? ' day left' : ' days left') : '') + '</span>' +
      '</div>' +
      '<button class="erc-btn erc-btn--primary ed-athlete-chat">Open</button>';

    card.querySelector('.ed-athlete-chat').addEventListener('click', function() {
      openCoachWorkspace(rel, 'overview');
    });
    wrap.appendChild(card);
  });
}

/* ══════════════════════════════════════════════
   PERSONAL COACHING REQUESTS — expert inbox
   personal_coach_requests where expertId == live uid, realtime.
   Lifecycle: pending → accepted (expert) → active (athlete pays)
                      → declined (expert)
   Tabs: Pending = pending · Active = accepted + active ·
         Completed = declined/completed/ended
   ══════════════════════════════════════════════ */
var _pcRequests        = [];
var _pcActiveTab       = 'pending';

function listenForCoachingRequests(expert) {
  if (typeof ZitlasDB === 'undefined') return;
  var uid = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
    ? ZitlasAuth.currentUser.uid
    : (expert && expert.id);
  if (!uid) return;
  if (listenForCoachingRequests._attachedFor === uid) return;
  listenForCoachingRequests._attachedFor = uid;

  console.log('[COACHING] listening: personal_coach_requests.where(expertId ==', uid + ')');
  ZitlasDB.collection('personal_coach_requests')
    .where('expertId', '==', uid)
    .onSnapshot(function(snap) {
      _pcRequests = snap.docs.map(function(d) { return d.data(); })
        .sort(function(a, b) { return (b.createdAt || '') < (a.createdAt || '') ? -1 : 1; });
      console.log('[COACHING] requests:', _pcRequests.map(function(r) {
        return r.requestId + ':' + r.status;
      }));
      var pendingCount = _pcRequests.filter(function(r) { return r.status === 'pending'; }).length;
      var badge = document.getElementById('navBadgeCoaching');
      if (badge) {
        badge.textContent   = pendingCount;
        badge.style.display = pendingCount > 0 ? '' : 'none';
      }
      var tabBadge = document.getElementById('pcTabBadgePending');
      if (tabBadge) {
        tabBadge.textContent   = pendingCount;
        tabBadge.style.display = pendingCount > 0 ? '' : 'none';
      }
      renderCoachingRequests();
    }, function(err) { console.warn('[COACHING] requests listener error', err); });
}

function _initCoachingTabs() {
  var tabs = document.querySelectorAll('[data-coaching-tab]');
  tabs.forEach(function(tab) {
    tab.addEventListener('click', function() {
      _pcActiveTab = tab.dataset.coachingTab;
      tabs.forEach(function(t) { t.classList.remove('pr-inbox-tab--active'); });
      tab.classList.add('pr-inbox-tab--active');
      renderCoachingRequests();
    });
  });
}

var PC_PLAN_ICONS = { diet: '🥗', training: '💪', complete: '🏆' };

function renderCoachingRequests() {
  var wrap  = document.getElementById('pcRequestList');
  var empty = document.getElementById('pcEmpty');
  if (!wrap) return;

  var bucket = _pcRequests.filter(function(r) {
    if (_pcActiveTab === 'pending')   return r.status === 'pending';
    if (_pcActiveTab === 'active')    return r.status === 'active';
    return r.status === 'declined' || r.status === 'expired' || r.status === 'completed' ||
           r.status === 'ended' || r.status === 'withdrawn';
  });

  wrap.querySelectorAll('.pc-req-card').forEach(function(el) { el.remove(); });
  if (empty) empty.style.display = bucket.length ? 'none' : '';

  /* PRIORITY QUEUE: Premium athletes pin to the top (isPremium stamped
     server-side by routes/coaching.py from the athlete's user doc). */
  bucket = bucket.slice().sort(function(a, b) {
    var prem = (b.isPremium ? 1 : 0) - (a.isPremium ? 1 : 0);
    if (prem !== 0) return prem;
    return (b.createdAt || '') < (a.createdAt || '') ? -1 : 1;
  });

  bucket.forEach(function(req) {
    var icon = PC_PLAN_ICONS[req.planType] || '👨‍🏫';
    var name = req.athleteName || 'Athlete';
    var initials = name.split(/\s+/).map(function(w) { return w[0] || ''; }).slice(0, 2).join('').toUpperCase();
    var isTrialReq = req.requestType === 'FREE_TRIAL';
    /* 'expired' is overloaded: release_reservation_txn writes it for a
       request nobody ever accepted (48h no-response reservation release),
       while coaching_sweep's relationship-expiry sync (see
       backend/services/coaching_sweep.py _expire_one_relationship) now ALSO
       writes it for a request whose engagement ran its full course and
       ended. acceptedAt/activatedAt only ever get set by /accept, so their
       presence disambiguates "was ever active" without any schema change. */
    var wasEverActive = !!(req.acceptedAt || req.activatedAt);
    var statusLine =
      req.status === 'pending'  ? (isTrialReq ? '🟢 Free trial request — awaiting your response' : '🟢 Payment Reserved — awaiting your response') :
      req.status === 'active'   ? (isTrialReq ? '✅ Active free trial client' : '✅ Active coaching client') :
      req.status === 'declined' ? '❌ Declined' :
      req.status === 'expired'  ? (wasEverActive
                                     ? (isTrialReq ? '⌛ Free trial ended' : '⌛ Coaching term ended')
                                     : '⌛ Expired — reservation released') :
      req.status === 'ended'    ? 'Coaching ended by athlete' :
      req.status === 'withdrawn'? 'Withdrawn by athlete' : 'Completed';

    var _pcPremBadge = req.isPremium
      ? ' <span style="background:linear-gradient(135deg,#234B35,#2E5F47);color:#101010;font-weight:800;border-radius:999px;padding:1px 8px;font-size:9px;letter-spacing:.04em;vertical-align:middle;">⭐ PRIORITY</span>'
      : '';
    var card = document.createElement('div');
    card.className = 'ed-athlete-card pc-req-card' +
      (isTrialReq && req.status === 'pending' ? ' pc-req-card--trial' : '');
    card.innerHTML =
      '<div class="ed-athlete-av">' + esc(initials) + '</div>' +
      '<div class="ed-athlete-info">' +
        '<span class="ed-athlete-name">' + esc(name) + _pcPremBadge + '</span>' +
        '<span class="ed-athlete-sub">' + icon + ' ' +
          esc(isTrialReq ? 'Personal Coaching Free Trial' : (req.planLabel || req.planType)) +
          (isTrialReq ? '' : (' · ₹' + esc(String(req.price)) + '/mo')) + '</span>' +
        '<span class="ed-athlete-sub">' + esc(statusLine) + '</span>' +
      '</div>' +
      (req.status === 'pending'
        ? (isTrialReq
            ? '<div class="pc-req-actions pc-req-actions--trial">' +
                '<button class="erc-btn erc-btn--secondary pc-decline">Reject</button>' +
                '<button class="erc-btn erc-btn--primary pc-trial-dur" data-days="5">5 Days</button>' +
                '<button class="erc-btn erc-btn--primary pc-trial-dur" data-days="10">10 Days</button>' +
                '<button class="erc-btn erc-btn--primary pc-trial-dur" data-days="15">15 Days</button>' +
              '</div>'
            : '<div class="pc-req-actions">' +
                '<button class="erc-btn erc-btn--secondary pc-decline">Decline</button>' +
                '<button class="erc-btn erc-btn--primary pc-accept">Accept</button>' +
              '</div>')
        : ((req.status === 'active' || req.status === 'ended')
            ? '<button class="erc-btn erc-btn--primary pc-chat">' + (req.status === 'ended' ? 'View Chat' : 'Chat') + '</button>'
            : ''));

    var acceptBtn  = card.querySelector('.pc-accept');
    var declineBtn = card.querySelector('.pc-decline');
    var chatBtn    = card.querySelector('.pc-chat');
    var trialDurBtns = card.querySelectorAll('.pc-trial-dur');

    if (acceptBtn) acceptBtn.addEventListener('click', function() {
      _pcUpdateRequestStatus(req, 'accepted');
    });
    if (declineBtn) declineBtn.addEventListener('click', function() {
      _pcUpdateRequestStatus(req, 'declined');
    });
    /* One click both picks the duration AND accepts — matches the spec's
       mockup exactly ([5 DAYS] [10 DAYS] [15 DAYS] [REJECT] as 4 parallel
       buttons, not a picker + separate confirm step). */
    trialDurBtns.forEach(function(btn) {
      btn.addEventListener('click', function() {
        _pcUpdateRequestStatus(req, 'accepted', Number(btn.dataset.days));
      });
    });
    if (chatBtn) chatBtn.addEventListener('click', function() {
      if (req.status === 'active') {
        /* Active client → full Coaching Workspace (the relationship doc has
           the authoritative dates/planType; the request is the fallback). */
        var rel = _pcRelByAthlete[req.athleteId] || {
          athleteId: req.athleteId, athleteName: req.athleteName,
          coachId: req.expertId, coachName: req.expertName,
          planType: req.planType, planLabel: req.planLabel, status: 'active',
          coachingType: req.requestType === 'FREE_TRIAL' ? 'FREE_TRIAL' : 'PAID',
        };
        openCoachWorkspace(rel, 'overview');
      } else {
        /* Ended → history stays viewable in the normal (read-only) chat */
        openExpertChat('chat_' + req.athleteId + '_' + req.expertId, name);
      }
    });

    wrap.appendChild(card);
  });
}

/* Accept/Decline both go through the backend now (backend/routes/coaching.py)
   instead of a direct Firestore .update() — accepting auto-debits the
   athlete's reserved amount and activates coaching atomically server-side;
   declining releases the reservation. Neither is safe to enforce
   client-side (a spoofed .update() could activate coaching without ever
   actually charging anyone). */
function _pcUpdateRequestStatus(req, newStatus, durationDays) {
  if (typeof getIdToken !== 'function') { edShowToast('Connection unavailable — please try again.'); return; }
  var endpoint = newStatus === 'accepted' ? '/api/coaching/accept' : '/api/coaching/reject';
  var isTrialReq = req.requestType === 'FREE_TRIAL';
  console.log('[COACHING]', newStatus, '→', endpoint, req.requestId,
    durationDays ? ('durationDays=' + durationDays) : '');

  var body = { requestId: req.requestId };
  if (durationDays) body.durationDays = durationDays;

  getIdToken().then(function(token) {
    return fetch(endpoint, {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  }).then(function(res) {
    return res.json().catch(function() { return {}; }).then(function(data) {
      return { status: res.status, data: data };
    });
  }).then(function(result) {
    if (result.status === 200 && result.data.success) {
      edShowToast(newStatus === 'accepted'
        ? (isTrialReq ? '✅ Free trial started — no charge.' : '✅ Accepted — payment auto-debited, coaching is now active.')
        : (isTrialReq ? 'Free trial request declined.' : 'Request declined — reservation released.'));
    } else if (result.status === 409) {
      edShowToast('This request was already handled.');
    } else if (result.status === 400 && result.data.detail === 'invalid_trial_duration') {
      edShowToast('Please choose a valid trial duration.');
    } else {
      console.error('[COACHING] status update failed', result);
      edShowToast('Could not update the request — please try again.');
    }
  }).catch(function(err) {
    console.error('[COACHING] status update failed', err);
    edShowToast('Could not update the request — please try again.');
  });
}

/* ══════════════════════════════════════════════
   CHAT ROOM DISCOVERY — the fix for the empty Client Chats inbox.

   A conversation started on the athlete's device exists only in THAT
   browser's localStorage; this expert device has no local record of it,
   so renderChatsFromList (which reads localStorage) rendered nothing and
   no message/call listener was ever attached. This listener queries
   chat_rooms by participant uid, seeds each room into localStorage, and
   attaches the per-room message + incoming-call listeners — making
   Firestore the source of truth for which conversations exist.
   ══════════════════════════════════════════════ */
function listenForChatRooms(expert) {
  if (typeof ZitlasDB === 'undefined') return;
  var uid = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
    ? ZitlasAuth.currentUser.uid
    : (expert && expert.id);
  if (!uid) return;
  if (listenForChatRooms._attachedFor === uid) return; /* one listener per session */
  listenForChatRooms._attachedFor = uid;

  console.log('[CHAT] listening for chat_rooms where participants contains', uid);
  ZitlasDB.collection('chat_rooms')
    .where('participants', 'array-contains', uid)
    .onSnapshot(function(snap) {
      console.log('[CHAT] chat_rooms snapshot —', snap.size, 'room(s)');
      var all = chatLoadAll();
      var changed = false;

      snap.docs.forEach(function(doc) {
        var room   = doc.data();
        var chatId = doc.id;
        /* athleteId from room metadata; legacy rooms without it → parse
           from the chat_<athleteId>_<expertId> id shape */
        var athleteId = room.athleteId ||
          chatId.replace(/^chat_/, '').replace(new RegExp('_' + uid + '$'), '');

        if (!all[chatId]) {
          all[chatId] = {
            conversationId: chatId,
            athleteId:      athleteId,
            athleteName:    room.athleteName || 'Athlete',
            expertId:       uid,
            expertName:     room.expertName || (expert && expert.name) || 'Expert',
            messages:       [],
            lastMessage:    room.lastMessage   || '',
            lastMessageAt:  room.lastMessageAt || null,
            unreadByExpert: 0,
          };
          changed = true;
          console.log('[CHAT] discovered new conversation', chatId, 'athlete:', all[chatId].athleteName);
        } else {
          /* Refresh metadata from Firestore truth */
          if (room.athleteName && all[chatId].athleteName !== room.athleteName) { all[chatId].athleteName = room.athleteName; changed = true; }
          if (!all[chatId].athleteId && athleteId) { all[chatId].athleteId = athleteId; changed = true; }
          if (all[chatId].expertId !== uid) { all[chatId].expertId = uid; changed = true; }
        }

        /* Live message + incoming-call listeners for every discovered room —
           NOT just the one currently open. This is what makes cross-device
           delivery and the incoming-call popup work without the expert
           having to already be inside the right chat. */
        startExpertChatMessagesListener(chatId);
        startExpertIncomingCallListener(chatId, all[chatId].athleteId, all[chatId].athleteName);
      });

      if (changed) chatSaveAll(all);
      renderChatsFromList([]);
    }, function(err) {
      console.error('[CHAT] chat_rooms listener error', err);
    });
}

/* ══════════════════════════════════════════════
   VOICE CALL (WebRTC via assets/js/webrtc-call.js)
   Scoped to whichever chat conversation is currently open — same
   limitation as the athlete side: the expert must have this specific
   chat open to receive a call from that athlete.
   ══════════════════════════════════════════════ */
var _edCallSession           = null;
var _edPendingIncomingCall   = null;
var _edIncomingCallListeners = {};  /* conversationId → true once attached */

function startExpertIncomingCallListener(conversationId, athleteId, athleteName) {
  if (typeof ZitlasDB === 'undefined' || typeof ZitlasCall === 'undefined' || !conversationId) return;
  if (_edIncomingCallListeners[conversationId]) return; /* already listening */
  _edIncomingCallListeners[conversationId] = true;
  console.log('[CALL] listening for incoming calls on', conversationId);

  var myUid = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
    ? ZitlasAuth.currentUser.uid
    : (_currentExpert ? _currentExpert.id : '');

  ZitlasCall.listenForIncomingCalls({
    db: ZitlasDB, chatId: conversationId, myUid: myUid,
    onIncomingCall: function(callInfo) {
      if (_edCallSession || _edPendingIncomingCall) return; /* already on a call */
      _edPendingIncomingCall = callInfo;
      ZitlasCallUI.showIncoming({
        name:  athleteName || 'Athlete',
        role:  'Athlete',
        photo: null,
        onAccept: function() {
          if (_edPendingIncomingCall) _edAcceptIncomingCall(_edPendingIncomingCall);
        },
        onReject: function() {
          if (_edPendingIncomingCall) {
            ZitlasCall.declineCall({ db: ZitlasDB, chatId: _edPendingIncomingCall.chatId, callId: _edPendingIncomingCall.callId });
          }
          _edPendingIncomingCall = null;
          ZitlasCallUI.close();
        },
      });
    },
    onCallCancelled: function(callId) {
      /* Caller hung up while still ringing — dismiss the popup */
      if (_edPendingIncomingCall && _edPendingIncomingCall.callId === callId) {
        _edPendingIncomingCall = null;
        ZitlasCallUI.close({ message: 'Call ended' });
      }
    },
  });
}

function _edStartOutgoingCall(chatId, athleteId, athleteName) {
  var myUid = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
    ? ZitlasAuth.currentUser.uid
    : (_currentExpert ? _currentExpert.id : '');
  console.log('[CALL] current uid', myUid);
  console.log('[CALL] other uid', athleteId);
  console.log('[CALL] chatId', chatId);

  ZitlasCallUI.showOutgoing({
    name:  athleteName || 'Athlete',
    role:  'Athlete',
    photo: null,
    onHangup: function() {
      if (_edCallSession) _edCallSession.hangup();
      ZitlasCallUI.close({ message: 'Call ended' });
      _edEndCallUI();
    },
  });

  _edCallSession = ZitlasCall.startCall({
    db: ZitlasDB, chatId: chatId, myUid: myUid, otherUid: athleteId,
    onLocalStream:  function(stream) { ZitlasCallUI.setLocalStream(stream); },
    onRemoteStream: function(stream) { ZitlasCallUI.setRemoteStream(stream); },
    onStateChange:  function(state) {
      console.log('[CALL] state', state);
      if      (state === 'ringing')      ZitlasCallUI.setStatus('Ringing…');
      else if (state === 'accepted')     ZitlasCallUI.setStatus('Connecting…');
      else if (state === 'connecting')   ZitlasCallUI.setStatus('Connecting…');
      else if (state === 'connected')    ZitlasCallUI.setConnected();
      else if (state === 'disconnected') ZitlasCallUI.setStatus('Reconnecting…');
      else if (state === 'rejected')     { ZitlasCallUI.close({ message: 'Call declined' }); _edEndCallUI(); }
      else if (state === 'ended' || state === 'failed' || state === 'closed') {
        ZitlasCallUI.close({ message: state === 'failed' ? 'Could not connect' : 'Call ended' });
        _edEndCallUI();
      }
    },
  });
  var callBtn = document.getElementById('edChatCallBtn');
  if (callBtn) { callBtn.classList.add('zc-call-btn--calling'); callBtn.setAttribute('aria-label', 'End call'); }
}

function _edAcceptIncomingCall(callInfo) {
  _edPendingIncomingCall = null;
  ZitlasCallUI.setActive('Connecting…');
  _edCallSession = ZitlasCall.answerCall({
    db: ZitlasDB, chatId: callInfo.chatId, callId: callInfo.callId,
    myUid: (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) ? ZitlasAuth.currentUser.uid : (_currentExpert ? _currentExpert.id : ''),
    offer: callInfo.offer,
    onLocalStream:  function(stream) { ZitlasCallUI.setLocalStream(stream); },
    onRemoteStream: function(stream) { ZitlasCallUI.setRemoteStream(stream); },
    onStateChange:  function(state) {
      console.log('[CALL] state', state);
      if      (state === 'connecting')   ZitlasCallUI.setStatus('Connecting…');
      else if (state === 'connected')    ZitlasCallUI.setConnected();
      else if (state === 'disconnected') ZitlasCallUI.setStatus('Reconnecting…');
      else if (state === 'ended' || state === 'failed' || state === 'closed') {
        ZitlasCallUI.close({ message: state === 'failed' ? 'Could not connect' : 'Call ended' });
        _edEndCallUI();
      }
    },
  });
  /* Wire the End button for the now-active call */
  ZitlasCallUI.setHangup(function() {
    if (_edCallSession) _edCallSession.hangup();
    ZitlasCallUI.close({ message: 'Call ended' });
    _edEndCallUI();
  });
  var callBtn = document.getElementById('edChatCallBtn');
  if (callBtn) { callBtn.classList.add('zc-call-btn--calling'); callBtn.setAttribute('aria-label', 'End call'); }
}

function _edEndCallUI() {
  _edCallSession = null;
  var callBtn = document.getElementById('edChatCallBtn');
  if (callBtn) { callBtn.classList.remove('zc-call-btn--calling'); callBtn.setAttribute('aria-label', 'Voice call'); }
}

/* ══════════════════════════════════════════════
   REVIEW PACKET RENDERERS — expert chat side
   Mirrors the athlete-side rich card functions.
   ══════════════════════════════════════════════ */

function capitalize(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : ''; }

function edCreateCaseFileSummary(pCtx, note, pld) {
  var div = document.createElement('div');
  div.className = 'chat-msg chat-msg--review-confirm';
  var a = pCtx.assessment || pCtx.survey || {};
  var c = pCtx.calculations || {};
  var currentWeight = a.weight_kg, goalWeight = a.goal_weight_kg;
  var goalLabel = (currentWeight && goalWeight)
    ? (parseFloat(goalWeight) < parseFloat(currentWeight) ? 'Lose Weight' : 'Gain Weight')
    : 'Weight Management';
  var docItems = [
    { label: 'Assessment',       has: !!pCtx.assessment },
    { label: 'Fitness Snapshot', has: !!pCtx.calculations },
    { label: 'SWOT Report',      has: !!pCtx.swot },
    { label: 'AI Diet Plan',     has: !!pCtx.diet_plan },
    { label: 'AI Workout Plan',  has: !!pCtx.workout_plan },
  ].filter(function(i) { return i.has; });
  var docsHtml = docItems.map(function(i) {
    return '<div class="rcm-item"><span class="rcm-check">✅</span>' + esc(i.label) + '</div>';
  }).join('');
  var noteHtml = note ? '<div class="rcm-user-note">💬 &ldquo;' + esc(note) + '&rdquo;</div>' : '';
  var fee = pld.fee ? '₹' + pld.fee : '—';
  var athleteName = pld.athlete_name || 'Athlete';
  var statsHtml = [
    goalLabel     ? '<div class="rcm-stat"><span class="rcm-stat-label">Goal</span><span class="rcm-stat-val">' + esc(goalLabel) + '</span></div>' : '',
    currentWeight ? '<div class="rcm-stat"><span class="rcm-stat-label">Current Weight</span><span class="rcm-stat-val">' + esc(String(currentWeight)) + ' kg</span></div>' : '',
    goalWeight    ? '<div class="rcm-stat"><span class="rcm-stat-label">Target Weight</span><span class="rcm-stat-val">' + esc(String(goalWeight)) + ' kg</span></div>' : '',
    c.weight_loss_calories_kcal ? '<div class="rcm-stat"><span class="rcm-stat-label">Target Calories</span><span class="rcm-stat-val">' + esc(String(c.weight_loss_calories_kcal)) + ' kcal</span></div>' : '',
    c.protein_target_g ? '<div class="rcm-stat"><span class="rcm-stat-label">Protein</span><span class="rcm-stat-val">' + esc(String(c.protein_target_g)) + 'g</span></div>' : '',
  ].filter(Boolean).join('');
  div.innerHTML =
    '<div class="review-confirm-card">' +
      '<div class="rcm-header"><span class="rcm-icon">📋</span><div>' +
        '<div class="rcm-title">Review from ' + esc(athleteName) + '</div>' +
        '<div class="rcm-sub">Submitted for Expert Review</div>' +
      '</div></div>' +
      (statsHtml ? '<div class="rcm-user-stats">' + statsHtml + '</div>' : '') +
      '<div class="rcm-attach-label">Attached Documents:</div>' +
      '<div class="rcm-items">' + docsHtml + '</div>' +
      noteHtml +
      '<div class="rcm-divider"></div>' +
      '<div class="rcm-fee-row"><span class="rcm-fee-label">Review Fee</span><span class="rcm-fee-val">' + esc(fee) + '</span></div>' +
      '<div class="rcm-status-row"><span class="rcm-status-dot rcm-status--pending"></span><span class="rcm-status-text">Awaiting Your Review</span></div>' +
    '</div>';
  return div;
}

function edCreateFitnessCard(pCtx) {
  var div = document.createElement('div');
  div.className = 'chat-msg chat-msg--card';
  var a = pCtx.assessment || pCtx.survey || {};
  var c = pCtx.calculations || {};
  var age = a.age ? String(a.age) + ' yrs' : '';
  var gender = capitalize(a.gender || '');
  var height = a.height_cm ? a.height_cm + ' cm' : '';
  var weight = a.weight_kg ? a.weight_kg + ' kg' : '';
  var goal   = a.goal_weight_kg ? a.goal_weight_kg + ' kg' : '';
  var activity = a.activity_level ? capitalize(String(a.activity_level).replace(/_/g, ' ')) : '';
  var diet     = a.diet_preference ? capitalize(String(a.diet_preference).replace(/_/g, ' ')) : '';
  var bmi = c.bmi ? parseFloat(c.bmi).toFixed(1) : '';
  var bmr = c.bmr_kcal  ? Math.round(c.bmr_kcal) + ' kcal' : '';
  var tdee = c.tdee_kcal ? Math.round(c.tdee_kcal) + ' kcal' : '';
  var targetCal = c.weight_loss_calories_kcal ? c.weight_loss_calories_kcal + ' kcal' : '';
  var protein   = c.protein_target_g   ? c.protein_target_g + 'g' : '';
  var water     = c.water_target_liters ? c.water_target_liters + 'L' : '';
  var steps     = c.daily_steps_goal   ? Number(c.daily_steps_goal).toLocaleString() + '/day' : '';
  var statItems = [
    bmi       ? { val: bmi + (c.bmi_category ? ' · ' + c.bmi_category : ''), label: 'BMI',             accent: false } : null,
    bmr       ? { val: bmr,       label: 'BMR',             accent: false } : null,
    tdee      ? { val: tdee,      label: 'TDEE',            accent: false } : null,
    targetCal ? { val: targetCal, label: 'Target Calories', accent: true  } : null,
    protein   ? { val: protein,   label: 'Protein Target',  accent: true  } : null,
    water     ? { val: water,     label: 'Water Target',    accent: false } : null,
    steps     ? { val: steps,     label: 'Steps Goal',      accent: false } : null,
  ].filter(Boolean);
  var statsHtml = statItems.map(function(s) {
    return '<div class="cfc-stat' + (s.accent ? ' cfc-stat--accent' : '') + '"><span class="cfc-stat-val">' + esc(s.val) + '</span><span class="cfc-stat-label">' + esc(s.label) + '</span></div>';
  }).join('');
  var profileLine = [age, gender, height].filter(Boolean).join(' · ');
  var weightRow = weight && goal ? '⚖️ ' + weight + '  →  Goal: ' + goal : weight ? '⚖️ ' + weight : '';
  var metaTags = [activity, diet].filter(Boolean).map(function(t) { return '<span class="cfc-meta-tag">' + esc(t) + '</span>'; }).join('');
  div.innerHTML =
    '<div class="chat-content-card"><div class="ccc-header"><span class="ccc-icon">📊</span><div class="ccc-title-group"><span class="ccc-title">Fitness Snapshot</span>' + (profileLine ? '<span class="ccc-sub">' + esc(profileLine) + '</span>' : '') + '</div></div>' +
    (weightRow ? '<div class="cfc-weight-row">' + esc(weightRow) + '</div>' : '') +
    (metaTags  ? '<div class="cfc-meta-row">' + metaTags + '</div>' : '') +
    (statsHtml ? '<div class="cfc-stats-grid">' + statsHtml + '</div>' : '') +
    '</div>';
  return div;
}

function edCreateSwotCard(pCtx) {
  var div = document.createElement('div');
  div.className = 'chat-msg chat-msg--card';
  var swotOuter = pCtx.swot;
  if (!swotOuter) return div;
  var swot = swotOuter.swot || swotOuter;
  var quadrants = [
    { key: 'strengths',     icon: '💪', label: 'Strengths',     cls: 'csc-strength'    },
    { key: 'weaknesses',    icon: '⚠️', label: 'Weaknesses',    cls: 'csc-weakness'    },
    { key: 'opportunities', icon: '🎯', label: 'Opportunities', cls: 'csc-opportunity' },
    { key: 'threats',       icon: '🔴', label: 'Threats',       cls: 'csc-threat'      },
  ];
  var quadrantsHtml = quadrants.map(function(q) {
    var items = swot[q.key] || [];
    return '<div class="csc-quadrant ' + q.cls + '"><div class="csc-qlabel">' + q.icon + ' ' + esc(q.label) + '</div>' +
      '<ul class="csc-qlist">' +
        items.slice(0, 3).map(function(item) {
          var text = typeof item === 'object' ? (item.title || '') : String(item || '');
          return '<li>' + esc(text) + '</li>';
        }).join('') +
      '</ul></div>';
  }).join('');
  div.innerHTML =
    '<div class="chat-content-card"><div class="ccc-header"><span class="ccc-icon">🎯</span><div class="ccc-title-group"><span class="ccc-title">SWOT Analysis</span>' +
    (swotOuter.priority_action ? '<span class="ccc-sub">Priority: ' + esc(swotOuter.priority_action.slice(0, 80)) + '</span>' : '') +
    '</div></div><div class="csc-grid">' + quadrantsHtml + '</div></div>';
  return div;
}

function edCreateDietCard(dietPlan) {
  var div = document.createElement('div');
  div.className = 'chat-msg chat-msg--card';
  if (!dietPlan || !dietPlan.days) return div;
  var days = dietPlan.days;
  var calTarget  = dietPlan.daily_calories_target || '';
  var protTarget = dietPlan.daily_protein_target_g || '';
  var dayNames   = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  function getMealFoods(meal) {
    if (Array.isArray(meal.foods) && meal.foods.length > 0) return meal.foods.join(', ');
    if (meal.food_items) return String(meal.food_items);
    return '';
  }
  function renderDayMeals(dayData) {
    return (dayData.meals || []).map(function(meal) {
      var foods  = getMealFoods(meal);
      var calStr = meal.calories && meal.protein_g ? meal.calories + ' kcal · ' + meal.protein_g + 'g protein' : meal.calories ? meal.calories + ' kcal' : '';
      return '<div class="cdpc-meal-row">' +
        '<div class="cdpc-meal-hdr"><span class="cdpc-meal-emoji">' + esc(meal.emoji || '🍽️') + '</span><span class="cdpc-meal-name">' + esc(meal.meal_name || 'Meal') + '</span>' + (meal.time ? '<span class="cdpc-meal-time">' + esc(meal.time) + '</span>' : '') + '</div>' +
        (foods   ? '<div class="cdpc-meal-foods">' + esc(foods) + '</div>' : '') +
        (calStr  ? '<div class="cdpc-meal-meta">' + esc(calStr) + '</div>' : '') +
      '</div>';
    }).join('');
  }
  var pillsHtml = days.map(function(d, i) {
    return '<button class="cdpc-day-pill' + (i === 0 ? ' active' : '') + '" data-cdpc-day="' + i + '">' + esc(dayNames[i] || ('D' + (i + 1))) + '</button>';
  }).join('');
  var fullPlanHtml = days.map(function(d, i) {
    return '<div class="cdpc-full-day"><div class="cdpc-full-day-hdr"><span class="cdpc-full-day-name">' + esc(d.day || ('Day ' + (i + 1))) + '</span>' +
      (d.theme ? '<span class="cdpc-full-day-theme">' + esc(d.theme) + '</span>' : '') +
      (d.total_calories ? '<span class="cdpc-full-day-cal">' + d.total_calories + ' kcal</span>' : '') +
      '</div>' + renderDayMeals(d) + '</div>';
  }).join('<div class="cdpc-day-sep"></div>');
  var subText = '7-Day Plan' + (calTarget ? ' · ' + calTarget + ' kcal/day' : '') + (protTarget ? ' · ' + protTarget + 'g protein' : '');
  div.innerHTML =
    '<div class="chat-content-card"><div class="ccc-header"><span class="ccc-icon">🥗</span><div class="ccc-title-group"><span class="ccc-title">' + esc(dietPlan.plan_name || 'AI Diet Plan') + '</span><span class="ccc-sub">' + esc(subText) + '</span></div></div>' +
    '<div class="cdpc-day-pills">' + pillsHtml + '</div>' +
    '<div class="cdpc-day-meals">' + renderDayMeals(days[0]) + '</div>' +
    '<div class="cdpc-full-plan" style="display:none">' + fullPlanHtml + '</div>' +
    '<div class="ccc-actions"><button class="cpc-expand-btn" data-label-expand="View Full Plan ↓" data-label-collapse="Hide Full Plan ↑">View Full Plan ↓</button></div>' +
    '</div>';
  return div;
}

function edCreateWorkoutCard(workoutPlan) {
  var div = document.createElement('div');
  div.className = 'chat-msg chat-msg--card';
  if (!workoutPlan) return div;
  var wDays = workoutPlan.weekly_plan || workoutPlan.days || [];
  if (!wDays.length) return div;
  var dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  function getDayActivity(d) { return d.focus || d.theme || d.type || d.activity || 'Training'; }
  function getDayDuration(d) { return d.duration_minutes ? d.duration_minutes + ' min' : (d.totalTime || ''); }
  var gridHtml = wDays.map(function(d, i) {
    var activity = getDayActivity(d), duration = getDayDuration(d), isRest = /rest|recovery/i.test(activity);
    return '<div class="cwpc-day-cell' + (isRest ? ' cwpc-day-rest' : '') + '"><span class="cwpc-day-name">' + esc(dayNames[i] || ('D' + (i + 1))) + '</span><span class="cwpc-day-activity">' + esc(activity) + '</span>' + (duration ? '<span class="cwpc-day-dur">' + esc(duration) + '</span>' : '') + '</div>';
  }).join('');
  var fullHtml = wDays.map(function(d, i) {
    var exercises = d.exercises || d.drills || [], activity = getDayActivity(d), duration = getDayDuration(d), tip = d.daily_tip || d.tip || '';
    var exHtml = exercises.map(function(ex) {
      var name = ex.name || ex.drill_name || 'Exercise', sets = ex.sets ? ex.sets + ' sets' : '', reps = ex.reps_or_duration || ex.reps || ex.duration || '';
      var details = [sets, reps].filter(Boolean).join(' × ');
      return '<div class="cwpc-exercise"><span class="cwpc-ex-name">' + esc(name) + '</span>' + (details ? '<span class="cwpc-ex-detail">' + esc(details) + '</span>' : '') + '</div>';
    }).join('');
    return '<div class="cwpc-full-day"><div class="cwpc-full-day-hdr"><span class="cwpc-full-day-name">' + esc(d.day || ('Day ' + (i + 1))) + '</span><span class="cwpc-full-day-type">' + esc(activity + (duration ? ' · ' + duration : '')) + '</span></div>' +
      (exHtml || '<div class="cwpc-rest-label">Rest / Recovery Day</div>') +
      (tip ? '<div class="cwpc-day-tip">💡 ' + esc(tip) + '</div>' : '') +
      '</div>';
  }).join('<div class="cdpc-day-sep"></div>');
  div.innerHTML =
    '<div class="chat-content-card"><div class="ccc-header"><span class="ccc-icon">💪</span><div class="ccc-title-group"><span class="ccc-title">' + esc(workoutPlan.plan_name || 'AI Workout Plan') + '</span><span class="ccc-sub">7-Day Training Schedule</span></div></div>' +
    '<div class="cwpc-week-grid">' + gridHtml + '</div>' +
    '<div class="cwpc-full-plan" style="display:none">' + fullHtml + '</div>' +
    '<div class="ccc-actions"><button class="cpc-expand-btn" data-label-expand="View Full Plan ↓" data-label-collapse="Hide Full Plan ↑">View Full Plan ↓</button></div>' +
    '</div>';
  return div;
}

function wireEdReviewInteractions(container) {
  container.querySelectorAll('.cpc-expand-btn').forEach(function(btn) {
    btn.addEventListener('click', function() {
      var panel = btn.closest('.chat-content-card').querySelector('[style*="display:none"], .cdpc-full-plan, .cwpc-full-plan');
      if (!panel) return;
      var expanded = panel.style.display !== 'none';
      panel.style.display = expanded ? 'none' : 'block';
      btn.textContent = expanded ? (btn.dataset.labelExpand || 'View Full Plan ↓') : (btn.dataset.labelCollapse || 'Hide Full Plan ↑');
    });
  });
  container.querySelectorAll('.cdpc-day-pill').forEach(function(pill) {
    pill.addEventListener('click', function() {
      var card   = pill.closest('.chat-content-card');
      var meals  = card.querySelector('.cdpc-day-meals');
      var dayIdx = parseInt(pill.dataset.cdpcDay, 10);
      card.querySelectorAll('.cdpc-day-pill').forEach(function(p) { p.classList.remove('active'); });
      pill.classList.add('active');
      /* Re-render the selected day — we need to find the data; use a closure stored on the card */
      if (card._dietDays && meals) {
        var d = card._dietDays[dayIdx];
        if (d) {
          var dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
          function getMF(meal) { return Array.isArray(meal.foods) && meal.foods.length ? meal.foods.join(', ') : (meal.food_items ? String(meal.food_items) : ''); }
          meals.innerHTML = (d.meals || []).map(function(meal) {
            var foods = getMF(meal), calStr = meal.calories && meal.protein_g ? meal.calories + ' kcal · ' + meal.protein_g + 'g protein' : meal.calories ? meal.calories + ' kcal' : '';
            return '<div class="cdpc-meal-row"><div class="cdpc-meal-hdr"><span class="cdpc-meal-emoji">' + esc(meal.emoji || '🍽️') + '</span><span class="cdpc-meal-name">' + esc(meal.meal_name || 'Meal') + '</span>' + (meal.time ? '<span class="cdpc-meal-time">' + esc(meal.time) + '</span>' : '') + '</div>' + (foods ? '<div class="cdpc-meal-foods">' + esc(foods) + '</div>' : '') + (calStr ? '<div class="cdpc-meal-meta">' + esc(calStr) + '</div>' : '') + '</div>';
          }).join('');
        }
      }
    });
  });
}

function renderReviewPacketIntoContainer(msg, container) {
  var pld  = msg.payload || {};
  var pCtx = pld.context || {};
  container.appendChild(edCreateCaseFileSummary(pCtx, pld.note, pld));
  if (pCtx.assessment || pCtx.calculations) container.appendChild(edCreateFitnessCard(pCtx));
  if (pCtx.swot)         container.appendChild(edCreateSwotCard(pCtx));
  if (pCtx.diet_plan) {
    var dc = edCreateDietCard(pCtx.diet_plan);
    /* Attach day data for pill interaction */
    var card = dc.querySelector('.chat-content-card');
    if (card) card._dietDays = pCtx.diet_plan.days || [];
    container.appendChild(dc);
  }
  if (pCtx.workout_plan) container.appendChild(edCreateWorkoutCard(pCtx.workout_plan));
  wireEdReviewInteractions(container);
  console.log('[ZITLAS] Expert Review Packet', pld);
  console.log('[ZITLAS] Conversation Messages', container.childElementCount, 'elements rendered');
}

/* ── ZC helpers (mirrored from athlete side) ── */
function edBuildZcDaySep(timestamp) {
  var el = document.createElement('div');
  el.className = 'zc-day-sep';
  var d = timestamp ? new Date(timestamp) : new Date();
  var today = new Date(); today.setHours(0,0,0,0);
  var yest  = new Date(today); yest.setDate(yest.getDate() - 1);
  var day   = new Date(d); day.setHours(0,0,0,0);
  var label;
  if (day.getTime() === today.getTime())      label = 'Today';
  else if (day.getTime() === yest.getTime())  label = 'Yesterday';
  else label = d.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
  el.innerHTML = '<span class="zc-day-sep-lbl">' + label + '</span>';
  return el;
}

function edZcIsGrouped(prevMsg, currMsg) {
  if (!prevMsg || prevMsg.senderType !== currMsg.senderType) return false;
  if (!prevMsg.timestamp || !currMsg.timestamp) return false;
  return (new Date(currMsg.timestamp) - new Date(prevMsg.timestamp)) < 5 * 60 * 1000;
}

function edShowZcTyping(container, initials) {
  edHideZcTyping(container);
  var el = document.createElement('div');
  el.className = 'zc-typing'; el.id = 'edZcTypingEl';
  el.innerHTML =
    '<div class="zc-av">' + esc(initials || '?') + '</div>' +
    '<div class="zc-typing-bbl">' +
      '<span class="zc-typing-dot"></span><span class="zc-typing-dot"></span><span class="zc-typing-dot"></span>' +
    '</div>';
  container.appendChild(el);
  container.scrollTop = container.scrollHeight;
}

function edHideZcTyping(container) {
  var old = container ? container.querySelector('#edZcTypingEl') : document.getElementById('edZcTypingEl');
  if (old) old.remove();
}

function buildExpertChatBubble(msg, expertName, grouped) {
  if (msg.type === 'review_packet') return document.createDocumentFragment();
  const div = document.createElement('div');
  var isIn = msg.senderType === 'expert';
  div.className = 'zc-msg ' + (isIn ? 'zc-msg--in' : 'zc-msg--out') + ' ' + (grouped ? 'zc-msg--grouped' : 'zc-msg--first');
  div.dataset.msgId = msg.id;

  var ts = '';
  try { ts = new Date(msg.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); } catch(_) {}

  var isImage = msg.type === 'image' && msg.imageUrl;
  var contentHtml = isImage
    ? '<img class="chat-image" src="' + esc(msg.imageUrl) + '" alt="Image" onclick="ZitlasChatAttach.openViewer(this.src)">'
    : '<span class="zc-bbl-txt">' + esc(msg.text || '').replace(/\n/g, '<br>') + '</span>';
  var bblClass = 'zc-bbl' + (isImage ? ' zc-bbl--img' : '');

  if (isIn) {
    var initials = (expertName || 'E').split(' ').map(function(w) { return w[0] || ''; }).join('').slice(0, 2).toUpperCase();
    var avHtml = grouped ? '<div class="zc-av-ghost"></div>' : '<div class="zc-av">' + esc(initials) + '</div>';
    div.innerHTML =
      avHtml +
      '<div class="' + bblClass + '">' +
        contentHtml +
        (ts ? '<span class="zc-bbl-ts">' + esc(ts) + '</span>' : '') +
      '</div>';
  } else {
    div.innerHTML =
      '<div class="' + bblClass + '">' +
        contentHtml +
        (ts ? '<span class="zc-bbl-ts">' + esc(ts) + '</span>' : '') +
      '</div>';
  }
  return div;
}

function populateReviewBanner(req) {
  var banner = document.getElementById('edChatReviewBanner');
  if (!banner) return;
  if (!req) { banner.classList.remove('visible'); banner.innerHTML = ''; return; }
  var tags = [];
  if (req.assessment)   tags.push('Assessment ✓');
  if (req.swot)         tags.push('SWOT ✓');
  if (req.diet_plan)    tags.push('Diet Plan ✓');
  if (req.workout_plan) tags.push('Workout Plan ✓');
  var tagsHtml = tags.map(function(t) { return '<span class="zc-rb-tag">' + esc(t) + '</span>'; }).join('');
  banner.innerHTML =
    '<span class="zc-rb-icon">📋</span>' +
    '<div class="zc-rb-body">' +
      '<div class="zc-rb-title">Diet Plan Review Request</div>' +
      (tagsHtml ? '<div class="zc-rb-tags">' + tagsHtml + '</div>' : '') +
      (req.fee ? '<div class="zc-rb-fee">Review Fee ₹' + esc(String(req.fee)) + '</div>' : '') +
    '</div>';
  banner.classList.add('visible');
}

function initExpertChatOverlay() {
  const overlay  = document.getElementById('edChatOverlay');
  const closeBtn = document.getElementById('edChatClose');
  const input    = document.getElementById('edChatInput');
  const sendBtn  = document.getElementById('edChatSendBtn');
  const msgWrap  = document.getElementById('edChatMessages');
  if (!overlay) return;

  const expert = getExpert();

  /* Close */
  if (closeBtn) {
    closeBtn.addEventListener('click', function() {
      overlay.classList.remove('open');
      document.body.style.overflow = '';
      _edChatConversationId = null;
      /* Refresh inbox to clear unread badges */
      const req = getReviewRequest();
      renderChatsFromList(req ? [req] : []);
    });
  }
  overlay.addEventListener('click', function(e) { if (e.target === overlay) closeBtn.click(); });

  /* ── ⋮ Menu ── */
  var edMenuBtn    = document.getElementById('edChatMenuBtn');
  var edDropdown   = document.getElementById('edChatDropdown');
  var edClearBtn   = document.getElementById('edChatClearBtn');
  var edViewAthBtn = document.getElementById('edChatViewAthleteBtn');
  var edBackdrop   = document.getElementById('edChatClearBackdrop');
  var edCancelBtn  = document.getElementById('edChatClearCancel');
  var edConfirmBtn = document.getElementById('edChatClearConfirm');

  function closeEdDropdown() { edDropdown && edDropdown.classList.remove('open'); }

  if (edMenuBtn && edDropdown) {
    edMenuBtn.addEventListener('click', function(e) {
      e.stopPropagation();
      edDropdown.classList.toggle('open');
    });
    document.addEventListener('click', function(e) {
      if (!e.target.closest('#edChatMenuWrap')) closeEdDropdown();
    });
  }

  /* "View Athlete Profile" — open review request page for this athlete */
  if (edViewAthBtn) {
    edViewAthBtn.addEventListener('click', function() {
      closeEdDropdown();
      if (_edChatConversationId) {
        var conv = chatGetConversation(_edChatConversationId);
        if (conv && conv.athleteId) {
          var req = getReviewRequest();
          if (req && req.id) {
            window.location.href = 'expert-review.html?id=' + encodeURIComponent(req.id);
            return;
          }
        }
      }
      /* Fallback: close overlay */
      closeBtn.click();
    });
  }

  /* "Clear Chat" — show confirmation modal */
  if (edClearBtn && edBackdrop) {
    edClearBtn.addEventListener('click', function() {
      closeEdDropdown();
      edBackdrop.classList.add('open');
    });
  }
  if (edCancelBtn && edBackdrop) {
    edCancelBtn.addEventListener('click', function() { edBackdrop.classList.remove('open'); });
  }
  edBackdrop && edBackdrop.addEventListener('click', function(e) {
    if (e.target === edBackdrop) edBackdrop.classList.remove('open');
  });
  if (edConfirmBtn) {
    edConfirmBtn.addEventListener('click', function() {
      if (!_edChatConversationId) { edBackdrop.classList.remove('open'); return; }

      /* Delete the conversation entirely from localStorage so it disappears
         from the Chats list. The athlete's own zitlas_chats copy is keyed
         separately (athlete writes, expert reads) — removing the expert-side
         entry does not affect the athlete's history. If the athlete sends a
         new message the conversation is recreated via ensureConversation. */
      var all = chatLoadAll();
      delete all[_edChatConversationId];
      chatSaveAll(all);

      edBackdrop.classList.remove('open');

      /* Clear the open chat overlay */
      if (msgWrap) msgWrap.innerHTML = '';
      var emptyEl = document.createElement('div');
      emptyEl.className = 'zc-empty';
      emptyEl.textContent = 'Chat cleared. New messages will appear here.';
      if (msgWrap) msgWrap.appendChild(emptyEl);

      /* Close the chat overlay */
      overlay.classList.remove('open');
      _edChatConversationId = null;

      /* Re-render the Chats section so the card disappears immediately */
      var req = getReviewRequest();
      renderChatsFromList(req ? [req] : []);

      console.log('[CHAT] Expert cleared and removed conversation from localStorage');
    });
  }

  /* ── 📞 Call button — WebRTC voice call, signaled via Firestore
     (see assets/js/webrtc-call.js). STUN-only: no TURN server configured,
     so calls may fail to connect audio across restrictive NATs/firewalls
     even though signaling (ringing/accepted) succeeds. ── */
  var edCallBtn = document.getElementById('edChatCallBtn');
  if (edCallBtn) {
    edCallBtn.addEventListener('click', function() {
      console.log('[CALL] button clicked');
      if (_edCallSession) {
        console.log('[CALL] Expert ended call for', _edChatConversationId);
        _edCallSession.hangup();
        ZitlasCallUI.close({ message: 'Call ended' });
        _edEndCallUI();
      } else {
        if (!_edChatConversationId || typeof ZitlasDB === 'undefined' || typeof ZitlasCall === 'undefined') return;
        var conv = chatGetConversation(_edChatConversationId);
        if (!conv || !conv.athleteId) return;
        console.log('[CALL] Expert calling athlete on', _edChatConversationId);
        _edStartOutgoingCall(_edChatConversationId, conv.athleteId, conv.athleteName);
      }
    });
  }

  /* Accept/Decline/Hangup are owned by ZitlasCallUI (assets/js/call-ui.js);
     callbacks are wired in startExpertIncomingCallListener / _edStartOutgoingCall. */

  /* Send */
  function expertSend() {
    if (!input || !_edChatConversationId) return;
    var sendConv = chatGetConversation(_edChatConversationId);
    if (_pcChatIsReadOnlyFor(sendConv ? sendConv.athleteId : null)) return;
    const text = input.value.trim();
    if (!text) return;

    const now = new Date().toISOString();

    /* Determine grouping */
    var grouped = false;
    var conv = chatGetConversation(_edChatConversationId);
    if (conv && conv.messages && conv.messages.length) {
      var last = conv.messages[conv.messages.length - 1];
      grouped = edZcIsGrouped(last, { senderType: 'expert', timestamp: now });
    }

    const msg = chatSaveExpertReply(_edChatConversationId, expert, text);
    if (!msg) return;

    if (msgWrap) {
      var empty = msgWrap.querySelector('.zc-empty');
      if (empty) empty.remove();

      /* Day separator if needed */
      var daySeps = msgWrap.querySelectorAll('.zc-day-sep-lbl');
      var lastLabel = daySeps.length ? daySeps[daySeps.length - 1].textContent : null;
      var todayLabel = edBuildZcDaySep(now).querySelector('.zc-day-sep-lbl').textContent;
      if (!lastLabel || lastLabel !== todayLabel) {
        msgWrap.appendChild(edBuildZcDaySep(now));
      }

      msgWrap.appendChild(buildExpertChatBubble(msg, expert.name, grouped));
      msgWrap.scrollTop = msgWrap.scrollHeight;
    }

    input.value = '';
    input.style.height = 'auto';
  }

  if (sendBtn) sendBtn.addEventListener('click', expertSend);
  if (input) {
    input.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); expertSend(); }
    });
    input.addEventListener('input', function() {
      this.style.height = 'auto';
      this.style.height = Math.min(this.scrollHeight, 120) + 'px';
    });
  }

  /* Real-time: athlete messages arriving while expert chat is open */
  var _edTypingTimer = null;
  window.addEventListener('storage', function(e) {
    if (e.key !== 'zitlas_chats' || !_edChatConversationId) return;
    try {
      var all  = JSON.parse(e.newValue || '{}');
      var conv = all[_edChatConversationId];
      if (!conv || !conv.messages) return;
      if (!msgWrap) return;
      var rendered = new Set();
      msgWrap.querySelectorAll('[data-msg-id]').forEach(function(el) { rendered.add(el.dataset.msgId); });
      var newMsgs = conv.messages.filter(function(m) { return !rendered.has(m.id); });
      if (!newMsgs.length) return;

      var hasAthlete = newMsgs.some(function(m) { return m.senderType === 'athlete' && m.type !== 'review_packet'; });
      if (hasAthlete) {
        var athInitials = (conv.athleteName || 'A').split(' ').map(function(w) { return w[0] || ''; }).join('').slice(0, 2).toUpperCase();
        /* Show typing for outgoing (athlete) in expert's view as incoming */
        edShowZcTyping(msgWrap, athInitials);
        clearTimeout(_edTypingTimer);
        _edTypingTimer = setTimeout(function() {
          edHideZcTyping(msgWrap);
          edAppendNewMessages(msgWrap, newMsgs, conv, rendered, expert);
        }, 1200);
      } else {
        edAppendNewMessages(msgWrap, newMsgs, conv, rendered, expert);
      }
    } catch(_) {}
  });

  function edAppendNewMessages(container, newMsgs, conv, rendered, expert) {
    var allMsgEls = container.querySelectorAll('[data-msg-id]');
    var lastRenderedId = allMsgEls.length ? allMsgEls[allMsgEls.length - 1].dataset.msgId : null;
    var lastMsg = lastRenderedId ? conv.messages.find(function(m) { return m.id === lastRenderedId; }) : null;
    var daySeps = container.querySelectorAll('.zc-day-sep-lbl');
    var prevDay = daySeps.length ? daySeps[daySeps.length - 1].textContent : null;

    newMsgs.forEach(function(msg) {
      var empty = container.querySelector('.zc-empty');
      if (empty) empty.remove();
      if (msg.type === 'review_packet') {
        renderReviewPacketIntoContainer(msg, container);
        lastMsg = null;
        return;
      }
      var dayLabel = edBuildZcDaySep(msg.timestamp).querySelector('.zc-day-sep-lbl').textContent;
      if (dayLabel !== prevDay) {
        container.appendChild(edBuildZcDaySep(msg.timestamp));
        prevDay = dayLabel;
      }
      var grouped = edZcIsGrouped(lastMsg, msg);
      container.appendChild(buildExpertChatBubble(msg, expert.name, grouped));
      lastMsg = msg;
    });
    container.scrollTop = container.scrollHeight;
    chatClearUnread(_edChatConversationId);
  }

  /* ── wire image attach for expert ── */
  initExpertChatImageAttach(expert, msgWrap);
}

/* ══════════════════════════════════════════════
   EXPERT CHAT IMAGE ATTACH
   ══════════════════════════════════════════════ */

/* Compression + upload + preview + fullscreen viewer live in the shared
   module (assets/js/chat-attachments.js) so athlete and expert chat behave
   identically. This function owns only the expert-side flow:
   validate -> preview (Cancel/Send) -> spinner bubble -> upload ->
   persist, with a tappable Retry on failure. */
function expertSendImageMessage(file, expert, msgWrap) {
  if (!_edChatConversationId || typeof ZitlasChatAttach === 'undefined') return;

  var v = ZitlasChatAttach.validate(file);
  if (!v.ok) { edShowToast(v.reason); return; }

  ZitlasChatAttach.confirmPreview(file).then(function(send) {
    if (!send) return;
    var now = new Date().toISOString();

    /* Spinner placeholder while uploading */
    var placeholder = document.createElement('div');
    placeholder.className = 'zc-msg zc-msg--in zc-msg--first';
    placeholder.innerHTML =
      '<div class="zc-av">' + esc((expert.name || 'E')[0].toUpperCase()) + '</div>' +
      '<div class="zc-bbl zc-bbl--img">' +
        '<div class="zc-img-placeholder"><span class="zca-spinner"></span><span>Uploading…</span></div>' +
      '</div>';
    if (msgWrap) { msgWrap.appendChild(placeholder); msgWrap.scrollTop = msgWrap.scrollHeight; }

    ZitlasChatAttach.upload(file).then(function(url) {
      placeholder.remove();
      var conv = chatGetConversation(_edChatConversationId);
      var grouped = false;
      if (conv && conv.messages && conv.messages.length) {
        var last = conv.messages[conv.messages.length - 1];
        grouped = edZcIsGrouped(last, { senderType: 'expert', timestamp: now });
      }
      var msg = chatSaveExpertReply(_edChatConversationId, expert, '', url);
      if (!msg) return;
      if (msgWrap) {
        msgWrap.appendChild(buildExpertChatBubble(msg, expert.name, grouped));
        msgWrap.scrollTop = msgWrap.scrollHeight;
      }
    }).catch(function(err) {
      console.error('[ED CHAT IMAGE] Upload failed:', err);
      var inner = placeholder.querySelector('.zc-img-placeholder');
      if (inner) {
        inner.classList.add('zc-img-placeholder--retry');
        inner.innerHTML = '<span>❌</span><span>Upload failed</span><span class="zca-retry-label">Tap to retry</span>';
        inner.addEventListener('click', function() {
          placeholder.remove();
          expertSendImageMessage(file, expert, msgWrap);
        }, { once: true });
      }
    });
  });
}

function initExpertChatImageAttach(expert, msgWrap) {
  var attachBtn    = document.getElementById('edChatAttachBtn');
  var fileInput    = document.getElementById('edChatFileInput');
  var cameraInput  = document.getElementById('edChatCameraInput');
  var sheet        = document.getElementById('edChatImgSheet');
  var sheetCamera  = document.getElementById('edChatSheetCamera');
  var sheetGallery = document.getElementById('edChatSheetGallery');
  var sheetCancel  = document.getElementById('edChatSheetCancel');

  /* openExpertChat() calls this on EVERY chat open — without a guard the
     change listeners stack and one photo pick sends N duplicate messages.
     The context is refreshed each call; the listeners are wired once and
     read the latest context, so a naive early-return doesn't freeze the
     first expert/msgWrap either. */
  _edAttachCtx = { expert: expert, msgWrap: msgWrap };
  if (initExpertChatImageAttach._wired) return;
  initExpertChatImageAttach._wired = true;

  function openSheet()  { if (sheet) sheet.classList.add('open'); }
  function closeSheet() { if (sheet) sheet.classList.remove('open'); }

  if (attachBtn)    attachBtn.addEventListener('click', openSheet);
  if (sheetCancel)  sheetCancel.addEventListener('click', closeSheet);
  if (sheet)        sheet.addEventListener('click', function(e) { if (e.target === sheet) closeSheet(); });

  if (sheetCamera) {
    sheetCamera.addEventListener('click', function() {
      closeSheet();
      if (cameraInput) cameraInput.click();
    });
  }
  if (sheetGallery) {
    sheetGallery.addEventListener('click', function() {
      closeSheet();
      if (fileInput) fileInput.click();
    });
  }
  if (fileInput) {
    fileInput.addEventListener('change', function() {
      var f = fileInput.files[0];
      if (f && _edAttachCtx) expertSendImageMessage(f, _edAttachCtx.expert, _edAttachCtx.msgWrap);
      fileInput.value = '';
    });
  }
  if (cameraInput) {
    cameraInput.addEventListener('change', function() {
      var f = cameraInput.files[0];
      if (f && _edAttachCtx) expertSendImageMessage(f, _edAttachCtx.expert, _edAttachCtx.msgWrap);
      cameraInput.value = '';
    });
  }
}
var _edAttachCtx = null; /* latest {expert, msgWrap} for the attach listeners */

/* ══════════════════════════════════════════════
   EDIT PROFILE
   ══════════════════════════════════════════════ */

/* Module-level state — set in renderAll, referenced across functions */
let _currentExpert         = null;
let _baseExpert            = null;
let _epPhotoDataUrl        = undefined; /* undefined = no change; null = remove; string = new data URL */
let _epIsOnline            = true;
let _epEditListenersAdded  = false;

/* ── Identity cache sync: experts/{uid} → localStorage ──
   Runs on every dashboard load. Firestore fields always win; locally
   edited fields that haven't synced yet survive only for the same uid.
   A cache belonging to a different uid is cleared outright. */
function syncExpertIdentityCaches(uid, expertData) {
  var cachedUid = (localStorage.getItem('zitlas_expert_id') || '').trim();
  var cache = null;
  try { cache = JSON.parse(localStorage.getItem('zitlas_expert_profile') || 'null'); } catch (_) {}
  console.log('[EXPERT CACHE]', cache);

  var cacheUidMismatch =
    (cachedUid && cachedUid !== uid) ||
    (cache && cache.id && cache.id !== uid) ||
    (cache && cache.uid && cache.uid !== uid);
  if (cacheUidMismatch) {
    console.log('[ZITLAS] stale expert cache (uid mismatch) — clearing', { cachedUid: cachedUid, authUid: uid });
    ['zitlas_expert_profile', 'zitlas_experts', 'zitlas_expert_id'].forEach(function (k) { localStorage.removeItem(k); });
    cache = null;
  }

  localStorage.setItem('zitlas_expert_id', uid);

  /* Map experts/{uid} → canonical zitlas_expert_profile schema */
  var base = (cache && typeof cache === 'object') ? cache : {};
  var prof = Object.assign({
    name: '', initials: 'EX', specialization: '', title: '', bio: '', quote: '',
    sessions: '0', clients: '0', successRate: '0%', experience: '0+',
    reviewFee: 0, sessionDuration: 20, status: 'online', profilePhoto: null,
    colorAccent: 'var(--primary)', rating: '5.0', reviewCount: 0,
  }, base, { id: uid });
  delete prof.uid; delete prof.email; delete prof.role; /* strip login.js legacy-schema keys */

  if (expertData) {
    if (expertData.name)                  prof.name            = expertData.name;
    var _spec = expertData.specialization || expertData.speciality;
    if (_spec)                            prof.specialization  = _spec;
    if (expertData.title)                 prof.title           = expertData.title;
    if (expertData.bio)                   prof.bio             = expertData.bio;
    if (expertData.quote)                 prof.quote           = expertData.quote;
    if (expertData.sessions)              prof.sessions        = expertData.sessions;
    if (expertData.clients)               prof.clients         = expertData.clients;
    if (expertData.successRate)           prof.successRate     = expertData.successRate;
    if (expertData.experience)            prof.experience      = expertData.experience;
    if (expertData.fee !== undefined)     prof.reviewFee       = expertData.fee;
    if (expertData.sessionDuration)       prof.sessionDuration = expertData.sessionDuration;
    if (expertData.status)                prof.status          = expertData.status;
    var _photo = expertData.profilePhoto || expertData.photo;
    if (_photo)                           prof.profilePhoto    = _photo;
    if (expertData.rating)                prof.rating          = String(expertData.rating);
    if (expertData.reviews !== undefined) prof.reviewCount     = expertData.reviews;
  }
  if (prof.name) {
    prof.initials = prof.name.split(/\s+/).map(function (p) { return p[0] || ''; }).slice(0, 2).join('').toUpperCase() || 'EX';
  }
  try { localStorage.setItem('zitlas_expert_profile', JSON.stringify(prof)); } catch (_) {}

  /* zitlas_experts — overwrite this device's marketplace cache with fresh data */
  try {
    localStorage.setItem('zitlas_experts', JSON.stringify([{
      id:             uid,
      name:           prof.name || 'Expert',
      email:          (expertData && expertData.email) || '',
      role:           'expert',
      approved:       !!(expertData && expertData.approved),
      rating:         (expertData && expertData.rating) || 0,
      specialization: prof.specialization || '',
    }]));
  } catch (_) {}

  return prof;
}

function loadProfile(baseExpert) {
  /* Prefer the canonical ZitlasExpertProfile helper (loaded from expert-profile.js) */
  if (window.ZitlasExpertProfile) {
    try {
      const canonical = ZitlasExpertProfile.getProfile();
      return ZitlasExpertProfile.toInternal(canonical, baseExpert);
    } catch (_) {}
  }
  /* Fallback: old localStorage schema */
  try {
    const saved = JSON.parse(localStorage.getItem('zitlas_expert_profile') || 'null');
    if (!saved) return baseExpert;
    return _mergeProfile(baseExpert, saved);
  } catch (_) { return baseExpert; }
}

function _mergeProfile(expert, saved) {
  const merged = Object.assign({}, expert);

  if (saved.name && saved.name.trim()) {
    merged.name      = saved.name.trim();
    const parts      = merged.name.split(/\s+/);
    merged.firstName = parts[0] || merged.firstName;
    merged.initials  = parts.map(function (p) { return p[0] || ''; }).slice(0, 2).join('').toUpperCase() || merged.initials;
  }
  if (saved.role)     merged.role     = saved.role;
  if (saved.about)    merged.about    = saved.about;
  if (saved.quote)    merged.quote    = saved.quote;
  if (saved.duration) merged.duration = saved.duration;
  if (typeof saved.fee === 'number' && !isNaN(saved.fee)) merged.fee = saved.fee;
  if (saved.photo !== undefined) merged.photo = saved.photo || null;
  merged.isOnline = (saved.isOnline !== undefined) ? saved.isOnline : true;

  const base = expert.stats || [];
  merged.stats = [
    { value: saved.sessions   || (base[0] ? base[0].value : '-'), label: 'Sessions'     },
    { value: saved.clients    || (base[1] ? base[1].value : '-'), label: 'Clients'      },
    { value: saved.successRate|| (base[2] ? base[2].value : '-'), label: 'Success Rate' },
    { value: saved.years      || (base[3] ? base[3].value : '-'), label: 'Years'        },
  ];
  if (saved.years) merged.experience = saved.years + ' Years Experience';
  return merged;
}

function openEditModal() {
  const expert   = _currentExpert;
  if (!expert) return;
  const backdrop = document.getElementById('epModalBackdrop');
  if (!backdrop) return;

  /* Reset transient photo state */
  _epPhotoDataUrl = undefined;
  _epIsOnline     = (expert.isOnline !== false);

  /* Pre-fill text fields */
  _epSetVal('epFieldName',     expert.name        || '');
  _epSetVal('epFieldRole',     expert.role        || '');
  _epSetVal('epFieldTitle',    expert.achievement || '');
  _epSetVal('epFieldAbout',    expert.about       || '');
  _epSetVal('epFieldQuote',    expert.quote       || '');
  _epSetVal('epFieldDuration', expert.duration    || '');
  _epSetVal('epFieldFee',      expert.fee !== undefined ? String(expert.fee) : '');

  /* Stat fields come from the stats array */
  const s = expert.stats || [];
  _epSetVal('epFieldSessions', s[0] ? s[0].value : '');
  _epSetVal('epFieldClients',  s[1] ? s[1].value : '');
  _epSetVal('epFieldSuccess',  s[2] ? s[2].value : '');
  _epSetVal('epFieldYears',    s[3] ? s[3].value : '');

  /* Photo preview */
  _epRefreshPhotoPreview();

  /* Online/Offline toggle buttons */
  _epSetOnlineBtn(_epIsOnline);

  /* Clear any previous validation errors */
  _epClearErrors();

  backdrop.classList.add('open');
  document.body.style.overflow = 'hidden';

  /* Delay focus so animation completes first */
  setTimeout(function () {
    const f = document.getElementById('epFieldName');
    if (f) f.focus();
  }, 320);
}

function closeEditModal() {
  const backdrop = document.getElementById('epModalBackdrop');
  if (backdrop) backdrop.classList.remove('open');
  document.body.style.overflow = '';
  _epPhotoDataUrl = undefined;
}

function saveProfile() {
  const expert = _currentExpert;
  if (!expert) return;

  /* Collect raw values */
  const nameVal     = (_epGetVal('epFieldName')    || '').trim();
  const feeRaw      = _epGetVal('epFieldFee');
  const yearsRaw    = _epGetVal('epFieldYears');

  _epClearErrors();
  let valid = true;

  if (!nameVal) {
    _epShowError('epErrName', 'epFieldName');
    valid = false;
  }
  if (feeRaw !== '' && (isNaN(parseFloat(feeRaw)) || !isFinite(Number(feeRaw)))) {
    _epShowError('epErrFee', 'epFieldFee');
    valid = false;
  }
  /* Years: extract leading number; reject negative */
  if (yearsRaw !== '') {
    const yNum = parseFloat(yearsRaw);
    if (!isNaN(yNum) && yNum < 0) {
      _epShowError('epErrYears', 'epFieldYears');
      valid = false;
    }
  }

  if (!valid) return;

  /* Success rate: normalise — add % if missing */
  let successVal = _epGetVal('epFieldSuccess');
  if (successVal && !successVal.includes('%') && !isNaN(parseFloat(successVal))) {
    successVal = successVal + '%';
  }

  /* Duration: extract integer minutes from "25 Min" / "25" / "25min" */
  const durationRaw = _epGetVal('epFieldDuration');
  const durationNum = parseInt(durationRaw) || (expert.duration ? parseInt(expert.duration) : 25) || 25;

  /* Photo: undefined=no change, null=removed, string=new dataURL */
  const photoVal = _epPhotoDataUrl !== undefined ? _epPhotoDataUrl : (expert.photo || null);

  /* Build canonical updates for ZitlasExpertProfile */
  const canonicalUpdates = {
    name:            nameVal,
    specialization:  _epGetVal('epFieldRole')      || undefined,
    title:           _epGetVal('epFieldTitle')     || undefined,
    bio:             _epGetVal('epFieldAbout')      || undefined,
    quote:           _epGetVal('epFieldQuote')      || undefined,
    experience:      _epGetVal('epFieldYears')      || undefined,
    sessions:        _epGetVal('epFieldSessions')   || undefined,
    clients:         _epGetVal('epFieldClients')    || undefined,
    successRate:     successVal                     || undefined,
    reviewFee:       feeRaw !== '' ? Math.round(Number(feeRaw)) : expert.fee,
    sessionDuration: durationNum,
    status:          _epIsOnline ? 'online' : 'offline',
    profilePhoto:    photoVal,
  };

  /* Remove undefined keys so we don't overwrite valid stored values with undefined */
  Object.keys(canonicalUpdates).forEach(function (k) {
    if (canonicalUpdates[k] === undefined) delete canonicalUpdates[k];
  });

  if (window.ZitlasExpertProfile) {
    ZitlasExpertProfile.save(canonicalUpdates); /* also dispatches expertProfileUpdated */
  }

  /* Mirror edits to experts/{uid} — the single source of truth — so the
     coaches marketplace and cprofile render the same identity */
  if (typeof ZitlasDB !== 'undefined' && typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) {
    const _fsProfile = {
      name:            nameVal,
      specialization:  _epGetVal('epFieldRole')     || '',
      title:           _epGetVal('epFieldTitle')    || '',
      bio:             _epGetVal('epFieldAbout')    || '',
      quote:           _epGetVal('epFieldQuote')    || '',
      experience:      _epGetVal('epFieldYears')    || '',
      sessions:        _epGetVal('epFieldSessions') || '',
      clients:         _epGetVal('epFieldClients')  || '',
      successRate:     successVal                   || '',
      fee:             feeRaw !== '' ? Math.round(Number(feeRaw)) : (expert.fee || 0),
      sessionDuration: durationNum,
      status:          _epIsOnline ? 'online' : 'offline',
      updatedAt:       new Date().toISOString(),
    };
    /* Firestore doc cap is 1MB — skip oversized base64 photos */
    if (photoVal === null) _fsProfile.profilePhoto = '';
    else if (typeof photoVal === 'string' && photoVal.length < 900000) _fsProfile.profilePhoto = photoVal;
    ZitlasDB.collection('experts').doc(ZitlasAuth.currentUser.uid)
      .set(_fsProfile, { merge: true })
      .then(function () { console.log('[ZITLAS] experts/{uid} profile synced'); })
      .catch(function (e) { console.warn('[ZITLAS] experts/{uid} profile sync failed:', e); });
  }

  if (!window.ZitlasExpertProfile) {
    /* Fallback: old schema */
    try {
      localStorage.setItem('zitlas_expert_profile', JSON.stringify({
        name: canonicalUpdates.name, role: canonicalUpdates.specialization,
        about: canonicalUpdates.bio, quote: canonicalUpdates.quote,
        duration: durationNum + ' Min', fee: canonicalUpdates.reviewFee,
        years: canonicalUpdates.experience, sessions: canonicalUpdates.sessions,
        clients: canonicalUpdates.clients, successRate: canonicalUpdates.successRate,
        isOnline: _epIsOnline, photo: photoVal,
      }));
    } catch (e) { console.warn('[EP] localStorage save failed:', e); }
  }

  /* Rebuild merged expert and refresh all display surfaces */
  const newExpert  = loadProfile(_baseExpert || expert);
  _currentExpert   = newExpert;
  renderHeader(newExpert);
  renderDashboard(newExpert);
  renderProfile(newExpert);
  _epUpdateOnlineDots(newExpert.isOnline !== false);

  closeEditModal();
  _epToast('Profile updated!');
}

function renderProfile(expert) {
  const epfAvatar      = document.getElementById('epfAvatar');
  const epfName        = document.getElementById('epfName');
  const epfRole        = document.getElementById('epfRole');
  const epfAchievement = document.getElementById('epfAchievement');
  const epfAbout       = document.getElementById('epfAbout');
  const epfQuote       = document.getElementById('epfQuote');
  const epfFeeReview   = document.getElementById('epfFeeReview');
  const epfFeeDuration = document.getElementById('epfFeeDuration');

  if (epfAvatar) {
    if (expert.photo) {
      epfAvatar.innerHTML = `<img src="${expert.photo}" alt="${expert.name}" style="width:100%;height:100%;object-fit:cover;border-radius:50%;" />`;
      epfAvatar.style.background = 'none';
    } else {
      epfAvatar.textContent = expert.initials;
      epfAvatar.style.background = hexToGlow(expert.colorAccent);
      epfAvatar.style.borderColor = expert.colorAccent + '55';
    }
  }
  if (epfName)        epfName.textContent = expert.name;
  if (epfRole)        epfRole.textContent = expert.role;
  if (epfAchievement) epfAchievement.textContent = expert.achievement || '';
  if (epfAbout)       epfAbout.textContent = expert.about || '';
  if (epfQuote)       epfQuote.textContent = '"' + (expert.quote || '') + '"';
  if (epfFeeReview)   epfFeeReview.textContent = '₹' + expert.fee;
  if (epfFeeDuration) epfFeeDuration.textContent = expert.duration;

  if (expert.stats) {
    const ids = ['epfSessions', 'epfClients', 'epfSuccess', 'epfYears'];
    expert.stats.forEach((s, i) => setText(ids[i], s.value));
  }

  _epUpdateOnlineDots(expert.isOnline !== false);
}

/* ── Edit profile event wiring (called once from renderAll) ── */
function initEditProfile() {
  if (_epEditListenersAdded) return;
  _epEditListenersAdded = true;

  /* Pricing & Services */
  const pricingNav = document.getElementById('pricingNavCard');
  if (pricingNav) pricingNav.addEventListener('click', function () {
    window.location.href = 'pricing.html';
  });

  /* Open modal */
  const editBtn = document.getElementById('epEditProfileBtn');
  if (editBtn) editBtn.addEventListener('click', openEditModal);

  /* Close modal */
  ['epModalClose', 'epModalCancel'].forEach(function (id) {
    const btn = document.getElementById(id);
    if (btn) btn.addEventListener('click', closeEditModal);
  });

  /* Backdrop click */
  const backdrop = document.getElementById('epModalBackdrop');
  if (backdrop) {
    backdrop.addEventListener('click', function (e) {
      if (e.target === backdrop) closeEditModal();
    });
  }

  /* Save */
  const saveBtn = document.getElementById('epModalSave');
  if (saveBtn) saveBtn.addEventListener('click', saveProfile);

  /* Photo upload */
  const photoInput = document.getElementById('epPhotoInput');
  if (photoInput) {
    photoInput.addEventListener('change', function () {
      const file = photoInput.files[0];
      if (!file) return;
      /* Warn if image is very large (>2MB) */
      if (file.size > 2 * 1024 * 1024) {
        _epToast('Image too large — please use a smaller photo.');
        photoInput.value = '';
        return;
      }
      const reader = new FileReader();
      reader.onload = function (ev) {
        _epPhotoDataUrl = ev.target.result;
        _epRefreshPhotoPreview();
      };
      reader.readAsDataURL(file);
      photoInput.value = '';
    });
  }

  /* Photo remove */
  const removeBtn = document.getElementById('epPhotoRemove');
  if (removeBtn) {
    removeBtn.addEventListener('click', function () {
      _epPhotoDataUrl = null; /* explicit null = remove photo */
      _epRefreshPhotoPreview();
    });
  }

  /* Online / Offline toggle */
  const onBtn  = document.getElementById('epStatusOnline');
  const offBtn = document.getElementById('epStatusOffline');
  if (onBtn)  onBtn.addEventListener('click',  function () { _epSetOnlineBtn(true);  _epIsOnline = true;  });
  if (offBtn) offBtn.addEventListener('click', function () { _epSetOnlineBtn(false); _epIsOnline = false; });

  /* Escape key */
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    const bd = document.getElementById('epModalBackdrop');
    if (bd && bd.classList.contains('open')) closeEditModal();
  });
}

/* ══════════════════════════════════════════════
   PROFESSIONAL CERTIFICATION — Expert Verification System
   Upload -> AI validates + OCRs + scores (backend, no Firestore) -> this
   client persists the result to expert_certificates/{id} and recomputes
   experts/{uid}.verified. Multiple certificates per expert are supported
   by design (ACE, NASM, ISSA, Sports Nutrition, Yoga, ...), each with its
   own independent verificationStatus.
══════════════════════════════════════════════ */
var CERT_STATUS_LABEL = {
  verified: '✓ AI Passed', pending_review: '⏳ Manual Review Required', rejected: '✕ Rejected',
};
var CERT_STATUS_CLASS = {
  verified: 'cert-status-pill--verified', pending_review: 'cert-status-pill--pending', rejected: 'cert-status-pill--rejected',
};

function initCertificateUpload(expert) {
  if (initCertificateUpload._wired) return;
  initCertificateUpload._wired = true;
  if (typeof ZitlasCertificates === 'undefined') return;

  var btn   = document.getElementById('certUploadBtn');
  var input = document.getElementById('certFileInput');
  var prog  = document.getElementById('certUploadProgress');
  var progText = document.getElementById('certUploadProgressText');
  if (!btn || !input) return;

  btn.addEventListener('click', function () { input.click(); });
  input.addEventListener('change', function () {
    var file = input.files && input.files[0];
    input.value = '';
    if (!file) return;

    var expertId = (_currentExpert && _currentExpert.id) ||
      (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser && ZitlasAuth.currentUser.uid);
    if (!expertId) { ZitlasCertificates.toast('Could not identify your account — please reload.'); return; }

    btn.disabled = true;
    if (prog) prog.classList.add('show');
    function setPhaseText(t) { if (progText) progText.textContent = t; }
    setPhaseText('Analyzing certificate…');

    console.log('[CERT] STEP 0 file selected —', file.name, file.type, file.size + 'B');
    /* onPhase advances the spinner label so it never stays on "Analyzing…"
       through the (potentially slow) storage upload — the exact symptom
       that made this look hung. */
    ZitlasCertificates.uploadAndVerify(expertId, file, function (phaseKey) {
      if (phaseKey === 'uploading') setPhaseText('Uploading certificate…');
      else setPhaseText('Analyzing certificate…');
    })
      .then(function (result) {
        if (!result.accepted) {
          console.warn('[CERT] rejected by AI:', result.reason);
          ZitlasCertificates.toast('❌ ' + result.reason);
          return;
        }
        setPhaseText('Saving…');
        console.log('[CERT] STEP 5 firestore write started');
        return ZitlasCertificates.saveCertificate(expertId, _currentExpert && _currentExpert.name, result)
          .then(function () {
            console.log('[CERT] STEP 6 firestore write success');
            ZitlasCertificates.toast(result.verificationStatus === 'verified'
              ? '✅ Certificate verified! Your Verified Expert badge is now live.'
              : '📋 Certificate uploaded — pending manual review (AI confidence ' + result.verificationScore + '%).');
          });
      })
      .catch(function (err) {
        /* Every await in the chain funnels here — the message is already
           phase-specific (verify vs upload vs save), so the expert sees
           WHAT failed instead of a spinner that never resolves. */
        console.error('[CERT] pipeline failed at some step:', err);
        ZitlasCertificates.toast(err && err.message ? err.message : 'Could not process the certificate — please try again.');
      })
      .then(function () {
        console.log('[CERT] STEP 7 UI reset — spinner cleared');
        btn.disabled = false;
        if (prog) prog.classList.remove('show');
        setPhaseText('Analyzing certificate…'); // reset label for next attempt
      });
  });
}

function listenForMyCertificates(expert) {
  if (listenForMyCertificates._attachedFor) return;
  if (typeof ZitlasCertificates === 'undefined') return;
  var expertId = (expert && expert.id) ||
    (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser && ZitlasAuth.currentUser.uid);
  if (!expertId) return;
  listenForMyCertificates._attachedFor = expertId;
  ZitlasCertificates.listenForExpertCertificates(expertId, renderMyCertificates);
}

function renderMyCertificates(certs) {
  var wrap  = document.getElementById('certListWrap');
  var empty = document.getElementById('certEmpty');
  if (!wrap) return;
  wrap.querySelectorAll('.cert-card').forEach(function (el) { el.remove(); });
  if (!certs.length) { if (empty) empty.style.display = ''; return; }
  if (empty) empty.style.display = 'none';

  certs.forEach(function (cert) {
    var card = document.createElement('div');
    card.className = 'cert-card ' + (cert.verificationStatus === 'rejected' ? 'cert-card--rejected'
      : cert.verificationStatus === 'pending_review' ? 'cert-card--pending' : '');
    card.innerHTML =
      '<div class="cert-card-top">' +
        '<div class="cert-card-icon">🎓</div>' +
        '<div style="flex:1">' +
          '<div class="cert-card-title">' + esc(cert.certificateName || 'Certificate') + '</div>' +
          '<div class="cert-card-org">' + esc(cert.issuingOrganization || '') + '</div>' +
        '</div>' +
        '<span class="cert-status-pill ' + CERT_STATUS_CLASS[cert.verificationStatus] + '">' + CERT_STATUS_LABEL[cert.verificationStatus] + '</span>' +
      '</div>' +
      '<div class="cert-kv-row"><span>Certificate ID</span><b>' + esc(cert.certificateNumber || '—') + '</b></div>' +
      '<div class="cert-kv-row"><span>Issued</span><b>' + esc(cert.issuedDate || '—') + '</b></div>' +
      '<div class="cert-kv-row"><span>Expires</span><b>' + esc(cert.expiryDate || '—') + '</b></div>' +
      '<div class="cert-kv-row"><span>Verification Score</span><b>' + esc(String(cert.verificationScore)) + '%</b></div>' +
      (cert.verificationStatus === 'rejected' && cert.rejectionReason
        ? '<div class="cert-reject-note">Rejected: ' + esc(cert.rejectionReason) + '</div>' : '') +
      '<div class="cert-card-actions"><button class="cert-view-btn" data-cert-view>View Certificate</button></div>';
    card.querySelector('[data-cert-view]').addEventListener('click', function () {
      ZitlasCertificates.openViewCertificate(cert);
    });
    wrap.appendChild(card);
  });
}

/* ── Private helpers ── */

function _epRefreshPhotoPreview() {
  const preview = document.getElementById('epPhotoPreview');
  if (!preview) return;
  const expert = _currentExpert;

  /* Determine which photo to show */
  const src = _epPhotoDataUrl !== undefined
    ? _epPhotoDataUrl                                /* user just changed or removed it */
    : (expert ? expert.photo : null);

  if (src) {
    preview.innerHTML = `<img src="${src}" alt="Profile photo">`;
  } else {
    const inits = expert
      ? (expert.initials || (expert.name || 'EX').split(' ').map(function (p) { return p[0] || ''; }).slice(0, 2).join('').toUpperCase())
      : 'EX';
    preview.innerHTML = `<span style="font-size:22px;font-weight:900;color:var(--accent)">${inits}</span>`;
  }
}

function _epSetOnlineBtn(isOnline) {
  const onBtn  = document.getElementById('epStatusOnline');
  const offBtn = document.getElementById('epStatusOffline');
  if (onBtn)  onBtn.classList.toggle('active',  isOnline);
  if (offBtn) offBtn.classList.toggle('active', !isOnline);
}

function _epUpdateOnlineDots(isOnline) {
  /* Header dot + label */
  const dot   = document.querySelector('.ed-online-dot');
  const label = document.querySelector('.ed-online-label');
  if (dot) {
    dot.style.background = isOnline ? 'var(--success)' : '#ef4444';
    dot.style.boxShadow  = isOnline ? '0 0 6px rgba(var(--success-rgb),0.6)' : '0 0 6px rgba(239,68,68,0.5)';
  }
  if (label) {
    label.textContent = isOnline ? 'Online' : 'Offline';
    label.style.color = isOnline ? 'var(--success)' : '#ef4444';
  }
  /* Dashboard card status dot */
  const pcsDot = document.querySelector('.epc-status-dot');
  if (pcsDot) {
    pcsDot.style.background = isOnline ? 'var(--success)' : '#ef4444';
    pcsDot.style.boxShadow  = isOnline ? '0 0 6px rgba(var(--success-rgb),0.5)' : '0 0 6px rgba(239,68,68,0.5)';
  }
}

function _epGetVal(id) {
  const el = document.getElementById(id);
  return el ? el.value.trim() : '';
}

function _epSetVal(id, val) {
  const el = document.getElementById(id);
  if (el) el.value = val;
}

function _epShowError(errId, inputId) {
  const err = document.getElementById(errId);
  const inp = document.getElementById(inputId);
  if (err) err.classList.add('visible');
  if (inp) inp.classList.add('ep-input--error');
}

function _epClearErrors() {
  document.querySelectorAll('.ep-error').forEach(function (el) { el.classList.remove('visible'); });
  document.querySelectorAll('.ep-input--error').forEach(function (el) { el.classList.remove('ep-input--error'); });
}

function _epToast(msg) {
  let t = document.getElementById('edToast');
  if (!t) {
    t = document.createElement('div');
    t.id = 'edToast';
    document.body.appendChild(t);
  }
  t.textContent  = msg;
  t.style.opacity = '1';
  clearTimeout(t._t);
  t._t = setTimeout(function () { t.style.opacity = '0'; }, 2400);
}

/* ══════════════════════════════════════════════
   NAVIGATION
   ══════════════════════════════════════════════ */

function initNavigation() {
  const navItems = document.querySelectorAll('.ed-nav-item');
  const sections = document.querySelectorAll('.ed-section');

  navItems.forEach(btn => {
    btn.addEventListener('click', () => {
      const targetId = btn.dataset.section;
      navItems.forEach(n => n.classList.remove('active'));
      sections.forEach(s => s.classList.remove('active'));
      btn.classList.add('active');
      const target = document.getElementById(targetId);
      if (target) target.classList.add('active');
      document.getElementById('edMain').scrollTop = 0;
    });
  });

  /* Quick action buttons on dashboard */
  function wireQuick(btnId, sectionId) {
    const btn = document.getElementById(btnId);
    if (!btn) return;
    btn.addEventListener('click', () => {
      navItems.forEach(n => n.classList.remove('active'));
      sections.forEach(s => s.classList.remove('active'));
      const navTarget = document.querySelector(`[data-section="${sectionId}"]`);
      if (navTarget) navTarget.classList.add('active');
      const sec = document.getElementById(sectionId);
      if (sec) sec.classList.add('active');
    });
  }

  wireQuick('qaViewReviews', 'sectionReviews');
  wireQuick('qaViewChats',   'sectionChats');
}

/* ══════════════════════════════════════════════
   LOGOUT — Firebase signOut + clear storage
   ══════════════════════════════════════════════ */

async function logout() {
  /* ── 1. Stop EVERY Firestore listener BEFORE signing out ──────────────
     A snapshot listener that outlives the auth session immediately fires
     permission-denied, and a snapshot callback running against just-cleared
     storage was throwing "Cannot read properties of undefined (reading
     'replace')" mid-logout. So tear the coaching workspace down cleanly
     (chat, coaching status, meal/workout check-ins, activity, notifications),
     then terminate the Firestore client, which detaches ALL remaining
     snapshot listeners this page owns (roster, requests, chat rooms, active
     chat, coaching relationships, call signaling). */
  try {
    if (window.ZitlasCoachingWorkspace && typeof ZitlasCoachingWorkspace.close === 'function') {
      ZitlasCoachingWorkspace.close();
    }
  } catch (e) { console.warn('[ZITLAS] workspace close error:', e); }
  try {
    if (typeof firebase !== 'undefined' && firebase.firestore) {
      // Raced with a timeout so a pending write (e.g. offline) can never strand
      // the user on "Logging out…"; the listeners still detach as part of it.
      await Promise.race([
        firebase.firestore().terminate(),
        new Promise(function (r) { setTimeout(r, 2500); })
      ]);
      console.log('[ZITLAS] all Firestore listeners detached (terminate)');
    }
  } catch (e) { console.warn('[ZITLAS] firestore terminate error:', e); }

  /* ── 2. Now end the session — no live listener remains to reject. ────── */
  const uidBeforeLogout = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
    ? ZitlasAuth.currentUser.uid : null;
  console.log('[LOGOUT] Before logout UID:', uidBeforeLogout);
  try {
    if (typeof ZitlasAuth !== 'undefined') await ZitlasAuth.signOut();
  } catch (e) { console.warn('[ZITLAS] signOut error:', e); }
  console.log('[LOGOUT] After signOut currentUser:',
    (typeof ZitlasAuth !== 'undefined') ? ZitlasAuth.currentUser : 'ZitlasAuth undefined');

  /* ── 3. ONLY AFTER signOut completes: clear local storage. Clearing it
     while still signed in lets a mid-flight sync re-read or re-upload the
     account it was meant to wipe. ACCOUNT GUARD does the full user-cache
     purge; the list is the fallback for a cached page where it isn't loaded. */
  if (typeof ZitlasAccountGuard !== 'undefined') {
    ZitlasAccountGuard.clearUserCache();
  } else {
    ['zitlas_token','zitlas_user','user','zitlas_user_role','zitlas_expert_id',
     'zitlas_firebase_user','loggedIn','zitlas_expert_profile','currentUser',
     'zitlas_expert_applied','zitlas_experts'].forEach(function (k) {
      localStorage.removeItem(k);
    });
  }
  console.log('[LOGOUT] Cleared account cache: true');
  sessionStorage.removeItem('zitlas_guest');

  /* ── 4. Leave. Inside the Flutter WebView, hand logout to the native app
     (it owns the real session and its own login screen); navigating to the
     website login here would just hit the WebView's login-block and re-auth.
     In a normal browser, go to the website login. */
  if (window.ZitlasWebview && typeof window.ZitlasWebview.postMessage === 'function') {
    window.ZitlasWebview.postMessage('logout');
  } else {
    window.location.href = '../login/login.html';
  }
}

function initLogout() {
  const btn1 = document.getElementById('edLogoutBtn');
  const btn2 = document.getElementById('edLogoutFullBtn');
  if (btn1) btn1.addEventListener('click', logout);
  if (btn2) btn2.addEventListener('click', logout);
}

/* ══════════════════════════════════════════════
   PERMANENT ACCOUNT DELETION
   ══════════════════════════════════════════════ */

/* Reusable helper — batch-deletes every doc in `collectionName` where
   `field` == `value`. Firestore caps a single batch at 500 writes, so
   large result sets are chunked. Returns the number of docs deleted. */
async function deleteCollectionWhere(collectionName, field, value) {
  if (typeof ZitlasDB === 'undefined') return 0;
  var snap = await ZitlasDB.collection(collectionName).where(field, '==', value).get();
  if (snap.empty) return 0;
  var docs = snap.docs;
  for (var i = 0; i < docs.length; i += 450) {
    var batch = ZitlasDB.batch();
    docs.slice(i, i + 450).forEach(function (d) { batch.delete(d.ref); });
    await batch.commit();
  }
  return docs.length;
}

var _deaInProgress = false;

function initDeleteAccount() {
  if (initDeleteAccount._wired) return;

  var openBtn   = document.getElementById('edDeleteAccountBtn');
  var backdrop1 = document.getElementById('edDeleteAccountBackdrop');
  var cancel1   = document.getElementById('edDeleteAccountCancel');
  var next1     = document.getElementById('edDeleteAccountNext');
  var backdrop2 = document.getElementById('edDeleteAccountBackdrop2');
  var cancel2   = document.getElementById('edDeleteAccountCancel2');
  var confirm2  = document.getElementById('edDeleteAccountConfirm');
  if (!openBtn || !backdrop1 || !backdrop2) return;
  initDeleteAccount._wired = true;

  openBtn.addEventListener('click', function () {
    if (_deaInProgress) return;
    backdrop1.classList.add('open');
  });
  cancel1.addEventListener('click', function () { backdrop1.classList.remove('open'); });
  backdrop1.addEventListener('click', function (e) { if (e.target === backdrop1) backdrop1.classList.remove('open'); });

  /* First confirmation → second confirmation */
  next1.addEventListener('click', function () {
    backdrop1.classList.remove('open');
    backdrop2.classList.add('open');
  });

  cancel2.addEventListener('click', function () { backdrop2.classList.remove('open'); });
  backdrop2.addEventListener('click', function (e) { if (e.target === backdrop2) backdrop2.classList.remove('open'); });

  confirm2.addEventListener('click', function () {
    if (_deaInProgress) return;
    _deaDeleteAccountPermanently(backdrop2, confirm2, cancel2, openBtn);
  });
}

async function _deaDeleteAccountPermanently(backdrop2, confirmBtn, cancelBtn, openBtn) {
  var user = (typeof ZitlasAuth !== 'undefined') ? ZitlasAuth.currentUser : null;
  if (!user) { edShowToast('Not signed in.'); return; }
  var uid = user.uid;

  _deaInProgress = true;
  var origLabel = confirmBtn.textContent;
  confirmBtn.textContent = 'Deleting account…';
  confirmBtn.disabled = true;
  cancelBtn.disabled = true;
  openBtn.disabled = true;

  console.log('[DELETE EXPERT] start', uid);

  try {
    /* Safety gate — verify Firestore truth (never the cached in-memory
       profile) that this uid is really an expert account before touching
       anything. Athletes never reach this page, but this is the real guard. */
    var expertDoc = await ZitlasDB.collection('experts').doc(uid).get();
    if (!expertDoc.exists || expertDoc.data().role !== 'expert') {
      throw Object.assign(new Error('Not an expert account'), { code: 'zitlas/not-expert' });
    }

    /* Privileged Firestore offboarding now runs SERVER-SIDE (Admin SDK). The
       old client writes/deletes here (experts doc, users role/expert_status,
       review_requests/expert_reviews) are denied by production Security Rules
       (FIRESTORE_SECURITY_AUDIT.md V3). The backend deletes experts/{uid},
       downgrades users/{uid} (strips expert role, sets expert_status='none' —
       never deleting the shared athlete doc), and revokes the expert claim,
       while PRESERVING audit/referential data (expert_reviews, review_requests,
       certificates, chats). See routes/admin.py POST /experts/deactivate. */
    console.log('[DELETE EXPERT] server-side deactivation');
    var _tok  = await user.getIdToken();
    var _resp = await fetch('/api/admin/experts/deactivate', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + _tok, 'Content-Type': 'application/json' },
      body: JSON.stringify({ expertId: uid }),
    });
    var _data = await _resp.json().catch(function () { return {}; });
    if (!_resp.ok || !_data.success) {
      throw Object.assign(new Error((_data && _data.detail) || 'deactivation_failed'),
                          { code: 'zitlas/deactivation-failed' });
    }
    console.log('[DELETE EXPERT] server deactivation result', _data);

    /* Firebase Auth account deletion is a SEPARATE, explicitly-intended step
       of this "Delete Account" button — it is an Auth operation, not a
       Firestore write, so it is unaffected by the rules and is kept as-is. */
    console.log('[DELETE EXPERT] deleting auth account');
    await user.delete();

    _deaClearLocalStorage(uid);

    console.log('[DELETE EXPERT] success');
    backdrop2.classList.remove('open');
    edShowToast('Your expert account has been permanently deleted.');
    setTimeout(function () { window.location.href = '../login/login.html'; }, 1200);
  } catch (err) {
    console.error('[DELETE EXPERT]', err);
    if (err && err.code === 'auth/requires-recent-login') {
      backdrop2.classList.remove('open');
      alert('For security reasons, please log in again before deleting your account.');
      try { await ZitlasAuth.signOut(); } catch (_) {}
      window.location.href = '../login/login.html';
      return;
    }
    edShowToast('Failed to delete account. Please try again.');
    confirmBtn.textContent = origLabel;
    confirmBtn.disabled = false;
    cancelBtn.disabled = false;
    openBtn.disabled = false;
    _deaInProgress = false;
  }
}

function _deaClearLocalStorage(uid) {
  try {
    var chats = JSON.parse(localStorage.getItem('zitlas_chats') || '{}');
    if (chats && typeof chats === 'object') {
      delete chats[uid];
      localStorage.setItem('zitlas_chats', JSON.stringify(chats));
    }
  } catch (_) {}

  try {
    var reviews  = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
    var filtered = reviews.filter(function (r) { return r.expertId !== uid; });
    localStorage.setItem('expert_plan_reviews', JSON.stringify(filtered));
  } catch (_) {}

  ['zitlas_token', 'zitlas_user', 'user', 'zitlas_user_role', 'zitlas_expert_id',
   'zitlas_firebase_user', 'loggedIn', 'zitlas_expert_profile', 'currentUser',
   'zitlas_expert_applied', 'zitlas_experts'].forEach(function (k) { localStorage.removeItem(k); });

  Object.keys(localStorage).forEach(function (k) {
    if (k === 'expert_plan_reviews' || k === 'zitlas_chats') return; /* already handled above */
    if (k.indexOf('expert_') === 0 || k.indexOf('zitlas_expert_') === 0) localStorage.removeItem(k);
  });

  try {
    sessionStorage.removeItem('zitlas_guest');
    sessionStorage.removeItem('zitlas_modify_expert');
  } catch (_) {}
}

/* ══════════════════════════════════════════════
   PLAN REVIEWS (expert_plan_reviews)
   ══════════════════════════════════════════════ */

function getPlanReviews(expertId) {
  try {
    var all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
    console.log('[REVIEWS] current expert uid', expertId);
    /* UID-only exact match. Legacy field names (expert_id/expertUid) are
       read for old cached docs, but a review with NO expertId never
       matches — anything else leaks reviews across experts. */
    var filteredReviews = all.filter(function(r) {
      var rid = r.expertId || r.expert_id || r.expertUid || '';
      return rid === expertId;
    });
    console.log('[REVIEWS] filtered reviews', filteredReviews);
    return filteredReviews;
  } catch (_) { return []; }
}

function savePlanReviewStatus(reviewId, newStatus, extra) {
  try {
    var all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
    var idx = all.findIndex(function(r) { return r.id === reviewId; });
    if (idx !== -1) {
      all[idx] = Object.assign({}, all[idx], { status: newStatus }, extra || {});
      localStorage.setItem('expert_plan_reviews', JSON.stringify(all));
    }
  } catch (_) {}
}

var _prSuggestCtx = { reviewId: null, card: null };

/* ══════════════════════════════════════════════
   FITNESS TARGET SECTION BUILDER
   ══════════════════════════════════════════════ */
function buildFitnessTargetHTML(review) {
  var p  = review.profileBasics || {};
  var a  = (review.assessmentData || {}).assessment || {};
  var calc = (review.assessmentData || {}).calculations || {};

  function cap(s) {
    return s ? String(s).replace(/_/g,' ').replace(/\b\w/g, function(c){ return c.toUpperCase(); }) : '';
  }

  var rows = [];
  var goal = a.fitness_goal || p.fitness_goal || (a.transformation_goal ? 'Transformation' : null) || a.goal;
  if (goal) rows.push(['Goal', cap(goal)]);

  var dur = a.goal_duration_months || p.goal_duration_months;
  if (dur) rows.push(['Duration', dur + ' Month' + (dur > 1 ? 's' : '')]);

  var tw = a.goal_weight_kg || p.goal_weight_kg;
  if (tw) rows.push(['Target Weight', tw + ' kg']);

  var bf = a.target_body_fat_pct || p.target_body_fat_pct || a.body_fat_target;
  if (bf) rows.push(['Target Body Fat', bf + '%']);

  var ph = a.transformation_goal || p.transformation_goal;
  if (ph) rows.push(['Target Physique', cap(ph)]);

  var wp = a.workout_preference || p.workout_preference;
  if (wp) rows.push(['Training Preference', cap(wp)]);

  var exp = a.fitness_level || p.fitness_level || a.experience_level;
  if (exp) rows.push(['Experience Level', cap(exp)]);

  var str = a.biggest_struggle || p.biggest_struggle || a.struggle;
  if (str) rows.push(['Biggest Struggle', cap(str)]);

  var avail = a.available_time || p.available_time;
  if (avail) rows.push(['Training Days', cap(String(avail))]);

  if (!rows.length && !calc.bmi) return '';

  var html = '<div class="erc-exp-section ed-ft-section"><div class="erc-exp-label">🎯 Fitness Target</div><div class="ed-ft-grid">';
  rows.forEach(function(r) {
    html += '<div class="ed-ft-item"><span class="ed-ft-label">' + esc(r[0]) + '</span><span class="ed-ft-val">' + esc(r[1]) + '</span></div>';
  });
  html += '</div>';

  if (calc.bmi || calc.bmr_kcal || calc.tdee_kcal || calc.protein_target_g) {
    html += '<div class="ed-ft-divider"></div><div class="ed-ft-grid ed-ft-grid--sm">';
    if (calc.bmi)            html += '<div class="ed-ft-item"><span class="ed-ft-label">BMI</span><span class="ed-ft-val">' + parseFloat(calc.bmi).toFixed(1) + (calc.bmi_category ? ' · ' + esc(calc.bmi_category) : '') + '</span></div>';
    if (calc.bmr_kcal)       html += '<div class="ed-ft-item"><span class="ed-ft-label">BMR</span><span class="ed-ft-val">' + Math.round(calc.bmr_kcal) + ' kcal</span></div>';
    if (calc.tdee_kcal)      html += '<div class="ed-ft-item"><span class="ed-ft-label">TDEE</span><span class="ed-ft-val">' + Math.round(calc.tdee_kcal) + ' kcal/day</span></div>';
    if (calc.protein_target_g) html += '<div class="ed-ft-item"><span class="ed-ft-label">Protein Target</span><span class="ed-ft-val">' + esc(String(calc.protein_target_g)) + 'g/day</span></div>';
    html += '</div>';
  }

  html += '</div>';
  return html;
}

/* ══════════════════════════════════════════════
   EDITABLE DIET PLAN BUILDER (expert can modify)
   ══════════════════════════════════════════════ */
function _markPlanEdited(card) {
  card._hasEdits = true;
  if (card._saveChangesBtn) {
    card._saveChangesBtn.disabled = false;
    card._saveChangesBtn.classList.add('ed-save-active');
  }
}

function _updateDayTotalEl(el, day) {
  var total = (day.meals || []).reduce(function(s, m) { return s + (parseInt(m.calories, 10) || 0); }, 0);
  el.textContent = total > 0 ? total + ' kcal total' : '';
}

function buildEditableMealEl(meal, di, plan, card) {
  var mealEl = document.createElement('div');
  mealEl.className = 'erc-meal-row ed-meal-editable' + (meal._edited ? ' ed-meal-modified' : '');

  var foods = Array.isArray(meal.foods) ? meal.foods.join(', ') : (meal.food_items || '');
  var meta  = [meal.calories ? meal.calories + ' kcal' : '', meal.protein_g ? meal.protein_g + 'g protein' : ''].filter(Boolean).join(' · ');

  /* Header */
  var hdr = document.createElement('div');
  hdr.className = 'erc-meal-hdr';
  hdr.innerHTML =
    '<span class="erc-meal-emoji">' + esc(meal.emoji || '🍽️') + '</span>' +
    '<span class="erc-meal-name ed-disp-name">' + esc(meal.meal_name || 'Meal') + '</span>' +
    (meal.time ? '<span class="erc-meal-time ed-disp-time">' + esc(meal.time) + '</span>' : '<span class="erc-meal-time ed-disp-time" style="display:none"></span>') +
    '<span class="ed-meal-edited-badge"' + (meal._edited ? '' : ' style="display:none"') + '>✏ Edited by Expert</span>';
  mealEl.appendChild(hdr);

  var foodsEl = document.createElement('div');
  foodsEl.className = 'erc-meal-foods ed-disp-foods';
  foodsEl.textContent = foods;
  mealEl.appendChild(foodsEl);

  var metaEl = document.createElement('div');
  metaEl.className = 'erc-meal-meta ed-disp-meta';
  metaEl.textContent = meta;
  mealEl.appendChild(metaEl);

  var notesEl = document.createElement('div');
  notesEl.className = 'ed-disp-notes';
  notesEl.style.display = meal.notes ? '' : 'none';
  notesEl.textContent = meal.notes ? '📝 ' + meal.notes : '';
  mealEl.appendChild(notesEl);

  /* Action buttons */
  var actionsEl = document.createElement('div');
  actionsEl.className = 'ed-meal-actions';
  actionsEl.innerHTML =
    '<button class="ed-meal-action ed-action--edit" title="Edit meal">✏ Edit</button>' +
    '<button class="ed-meal-action ed-action--replace" title="Replace foods">🔄 Replace</button>' +
    '<button class="ed-meal-action ed-action--add" title="Add a food item">➕ Add Food</button>' +
    '<button class="ed-meal-action ed-action--delete" title="Delete this meal">🗑 Delete</button>';
  mealEl.appendChild(actionsEl);

  /* Add-food inline input */
  var addFoodForm = document.createElement('div');
  addFoodForm.className = 'ed-add-food-row';
  addFoodForm.style.display = 'none';
  addFoodForm.innerHTML =
    '<input class="ed-inline-input" placeholder="Food item, e.g. 2 Boiled Eggs">' +
    '<button class="ed-inline-btn ed-inline-confirm">Add</button>' +
    '<button class="ed-inline-btn ed-inline-cancel">✕</button>';
  mealEl.appendChild(addFoodForm);

  /* Full edit form */
  var editForm = document.createElement('div');
  editForm.className = 'ed-meal-edit-form';
  editForm.style.display = 'none';
  editForm.innerHTML =
    '<div class="ed-form-row"><label class="ed-form-label">Meal Name</label>' +
    '<input class="ed-form-input" data-f="meal_name" value="' + esc(meal.meal_name || '') + '"></div>' +
    '<div class="ed-form-row"><label class="ed-form-label">Time</label>' +
    '<input class="ed-form-input" data-f="time" value="' + esc(meal.time || '') + '"></div>' +
    '<div class="ed-form-row"><label class="ed-form-label">Foods (comma-separated)</label>' +
    '<textarea class="ed-form-textarea" data-f="foods">' + esc(foods) + '</textarea></div>' +
    '<div class="ed-form-2col">' +
      '<div class="ed-form-row"><label class="ed-form-label">Calories</label><input class="ed-form-input" type="number" data-f="calories" value="' + esc(String(meal.calories || '')) + '"></div>' +
      '<div class="ed-form-row"><label class="ed-form-label">Protein (g)</label><input class="ed-form-input" type="number" data-f="protein_g" value="' + esc(String(meal.protein_g || '')) + '"></div>' +
    '</div>' +
    '<div class="ed-form-row"><label class="ed-form-label">Expert Notes</label>' +
    '<textarea class="ed-form-textarea" data-f="notes" placeholder="Leave notes for this meal...">' + esc(meal.notes || '') + '</textarea></div>' +
    '<div class="ed-form-btns">' +
      '<button class="ed-form-save-btn">💾 Save Meal</button>' +
      '<button class="ed-form-cancel-btn">Cancel</button>' +
    '</div>';
  mealEl.appendChild(editForm);

  /* ── Wire actions ── */
  function toggleEditForm(focusField) {
    var open = editForm.style.display !== 'none';
    editForm.style.display = open ? 'none' : 'block';
    addFoodForm.style.display = 'none';
    if (!open && focusField) {
      var f = editForm.querySelector('[data-f="' + focusField + '"]');
      if (f) { f.focus(); if (f.select) f.select(); }
    }
  }

  actionsEl.querySelector('.ed-action--edit').addEventListener('click', function() { toggleEditForm('meal_name'); });
  actionsEl.querySelector('.ed-action--replace').addEventListener('click', function() { toggleEditForm('foods'); });

  actionsEl.querySelector('.ed-action--add').addEventListener('click', function() {
    addFoodForm.style.display = addFoodForm.style.display === 'none' ? 'flex' : 'none';
    editForm.style.display = 'none';
    var inp = addFoodForm.querySelector('.ed-inline-input');
    if (inp) inp.focus();
  });

  actionsEl.querySelector('.ed-action--delete').addEventListener('click', function() {
    var day = (plan.days || [])[di];
    if (day) {
      var mi = Array.from(mealEl.parentNode.querySelectorAll('.ed-meal-editable')).indexOf(mealEl);
      if (mi > -1) day.meals.splice(mi, 1);
      /* Update day total */
      var tEl = mealEl.closest('[data-day-el]');
      if (tEl) {
        var dtEl = tEl.querySelector('.ed-day-total-el');
        if (dtEl) _updateDayTotalEl(dtEl, day);
      }
    }
    _markPlanEdited(card);
    mealEl.style.transition = 'opacity .2s, transform .2s';
    mealEl.style.opacity = '0'; mealEl.style.transform = 'translateX(-12px)';
    setTimeout(function() { mealEl.remove(); }, 210);
  });

  /* Add-food confirm */
  addFoodForm.querySelector('.ed-inline-confirm').addEventListener('click', function() {
    var inp = addFoodForm.querySelector('.ed-inline-input');
    var val = (inp ? inp.value : '').trim();
    if (!val) return;
    meal.foods = Array.isArray(meal.foods) ? meal.foods : (meal.food_items ? [meal.food_items] : []);
    meal.foods.push(val);
    meal._edited = true;
    foodsEl.textContent = meal.foods.join(', ');
    /* Sync edit-form textarea */
    var ta = editForm.querySelector('[data-f="foods"]');
    if (ta) ta.value = meal.foods.join(', ');
    if (inp) inp.value = '';
    addFoodForm.style.display = 'none';
    mealEl.classList.add('ed-meal-modified');
    hdr.querySelector('.ed-meal-edited-badge').style.display = '';
    _markPlanEdited(card);
  });
  addFoodForm.querySelector('.ed-inline-cancel').addEventListener('click', function() {
    addFoodForm.style.display = 'none';
  });

  /* Edit-form save */
  editForm.querySelector('.ed-form-save-btn').addEventListener('click', function() {
    var g = function(f) { return (editForm.querySelector('[data-f="' + f + '"]') || {}).value || ''; };
    meal.meal_name = g('meal_name') || meal.meal_name;
    meal.time      = g('time');
    meal.foods     = g('foods').split(',').map(function(s){ return s.trim(); }).filter(Boolean);
    meal.calories  = parseInt(g('calories'), 10) || 0;
    meal.protein_g = parseInt(g('protein_g'), 10) || 0;
    meal.notes     = g('notes');
    meal._edited   = true;

    console.log("[EDITED PLAN]", plan);
    console.log("[BREAKFAST AFTER EDIT]", plan.days[0] && plan.days[0].meals);

    /* Update display */
    hdr.querySelector('.ed-disp-name').textContent = meal.meal_name;
    var tEl = hdr.querySelector('.ed-disp-time');
    if (tEl) { tEl.textContent = meal.time; tEl.style.display = meal.time ? '' : 'none'; }
    foodsEl.textContent = meal.foods.join(', ');
    metaEl.textContent  = [meal.calories ? meal.calories + ' kcal' : '', meal.protein_g ? meal.protein_g + 'g protein' : ''].filter(Boolean).join(' · ');
    notesEl.textContent = meal.notes ? '📝 ' + meal.notes : '';
    notesEl.style.display = meal.notes ? '' : 'none';

    mealEl.classList.add('ed-meal-modified');
    hdr.querySelector('.ed-meal-edited-badge').style.display = '';
    editForm.style.display = 'none';
    _markPlanEdited(card);

    /* Update day total */
    var dayEl = mealEl.closest('[data-day-el]');
    if (dayEl) {
      var dtEl = dayEl.querySelector('.ed-day-total-el');
      var dayIdx = parseInt(dayEl.dataset.dayEl, 10);
      if (dtEl && !isNaN(dayIdx)) _updateDayTotalEl(dtEl, (plan.days || [])[dayIdx]);
    }
  });
  editForm.querySelector('.ed-form-cancel-btn').addEventListener('click', function() {
    editForm.style.display = 'none';
  });

  return mealEl;
}

function buildEditableDietPlanEl(review, card) {
  console.log("review", review);
  console.log("review.reviewedDietPlan", review.reviewedDietPlan);
  console.log("review.context", review.context);
  console.log("review.context.diet_plan", review.context && review.context.diet_plan);

  /* Unwrap new schema {originalDietPlan, currentDietPlan, ...} → flat diet plan */
  var _rawPlanData = review.planData || {};
  if (_rawPlanData.originalDietPlan || _rawPlanData.currentDietPlan) {
    _rawPlanData = _rawPlanData.currentDietPlan || _rawPlanData.originalDietPlan;
  }

  var diet = review.reviewedDietPlan || (review.context && review.context.diet_plan) || review.planData;
  if (diet && (diet.originalDietPlan || diet.currentDietPlan)) {
    diet = diet.currentDietPlan || diet.originalDietPlan;
  }
  console.log("diet", diet);
  console.log("diet.days", diet && diet.days);
  console.log("days length", diet && diet.days && diet.days.length);

  var plan = JSON.parse(JSON.stringify(_rawPlanData));
  card._editedPlan = plan;
  card._hasEdits   = false;

  var days   = plan.days || [];
  var labels = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

  var wrap = document.createElement('div');
  wrap.className = 'ed-editable-plan-wrap';

  /* Plan header */
  var sub = '';
  if (plan.daily_calories_target)  sub += plan.daily_calories_target + ' kcal/day';
  if (plan.daily_protein_target_g) sub += (sub ? ' · ' : '') + plan.daily_protein_target_g + 'g protein';
  var hdrDiv = document.createElement('div');
  hdrDiv.className = 'erc-plan-header';
  hdrDiv.innerHTML = '<span class="erc-plan-icon">🥗</span><div><div class="erc-plan-title">' +
    esc(plan.plan_name || 'AI Diet Plan') + '</div>' +
    (sub ? '<div class="erc-plan-sub">' + esc(sub) + '</div>' : '') + '</div>';
  wrap.appendChild(hdrDiv);

  /* Day pills */
  var pillsDiv = document.createElement('div');
  pillsDiv.className = 'erc-day-pills';
  days.forEach(function(d, i) {
    var pill = document.createElement('button');
    pill.className = 'erc-day-pill' + (i === 0 ? ' active' : '');
    pill.dataset.epDayPill = i;
    pill.textContent = labels[i] || ('D' + (i + 1));
    pillsDiv.appendChild(pill);
  });
  wrap.appendChild(pillsDiv);

  /* Day content panels */
  var panelsDiv = document.createElement('div');
  panelsDiv.className = 'erc-meals-wrap';
  days.forEach(function(day, di) {
    var panel = document.createElement('div');
    panel.className = 'erc-day-content';
    panel.dataset.dayEl = di;
    panel.style.display = di === 0 ? 'block' : 'none';

    if (day.theme) {
      var themeEl = document.createElement('div');
      themeEl.className = 'erc-day-theme';
      themeEl.textContent = day.theme;
      panel.appendChild(themeEl);
    }

    var totalEl = document.createElement('div');
    totalEl.className = 'erc-day-total ed-day-total-el';
    _updateDayTotalEl(totalEl, day);
    panel.appendChild(totalEl);

    var mealsContainer = document.createElement('div');
    mealsContainer.className = 'ed-meals-container';
    (day.meals || []).forEach(function(meal) {
      mealsContainer.appendChild(buildEditableMealEl(meal, di, plan, card));
    });
    panel.appendChild(mealsContainer);

    /* Add Meal button */
    var addMealBtn = document.createElement('button');
    addMealBtn.className = 'ed-add-meal-btn';
    addMealBtn.textContent = '➕ Add New Meal';
    addMealBtn.addEventListener('click', function() {
      var newMeal = { meal_name: 'New Meal', emoji: '🍽️', time: '', foods: [], calories: 0, protein_g: 0, _edited: true };
      day.meals = day.meals || [];
      day.meals.push(newMeal);
      var mealEl = buildEditableMealEl(newMeal, di, plan, card);
      mealsContainer.appendChild(mealEl);
      /* Auto-open edit form */
      var ef = mealEl.querySelector('.ed-meal-edit-form');
      if (ef) { ef.style.display = 'block'; var inp = ef.querySelector('[data-f="meal_name"]'); if (inp) inp.focus(); }
      _markPlanEdited(card);
    });
    panel.appendChild(addMealBtn);
    panelsDiv.appendChild(panel);
  });
  wrap.appendChild(panelsDiv);

  /* Day pill switcher */
  pillsDiv.addEventListener('click', function(e) {
    var pill = e.target.closest('[data-ep-day-pill]');
    if (!pill) return;
    var idx = parseInt(pill.dataset.epDayPill, 10);
    pillsDiv.querySelectorAll('[data-ep-day-pill]').forEach(function(p) { p.classList.remove('active'); });
    pill.classList.add('active');
    panelsDiv.querySelectorAll('[data-day-el]').forEach(function(c) {
      c.style.display = parseInt(c.dataset.dayEl, 10) === idx ? 'block' : 'none';
    });
  });

  /* Save Changes button */
  var saveBtn = document.createElement('button');
  saveBtn.className = 'ed-save-changes-btn';
  saveBtn.textContent = '💾 Save Changes';
  saveBtn.disabled = true;
  card._saveChangesBtn = saveBtn;
  wrap.appendChild(saveBtn);

  return wrap;
}

/* Normalize foods to a plain string array for history storage */
function normalizeFoodsForHistory(foods) {
  if (!foods) return [];
  if (typeof foods === 'string') {
    return foods.split(/[,\n]/).map(function(f) { return f.trim(); }).filter(Boolean);
  }
  if (Array.isArray(foods)) {
    return foods.map(function(f) {
      if (typeof f === 'string') return f.trim();
      if (f && f.name) return f.name.trim();
      return String(f || '').trim();
    }).filter(Boolean);
  }
  return [];
}

/* Build mealChangeHistory by diffing original planData against the expert-edited plan */
function buildMealChangeHistory(origPlan, newPlan, expertName) {
  var history = [];
  var DAY_NAMES = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  var now = new Date().toISOString();
  if (!origPlan || !origPlan.days || !newPlan || !newPlan.days) return history;

  newPlan.days.forEach(function(day, di) {
    var origDay = origPlan.days[di];
    (day.meals || []).forEach(function(meal, mi) {
      if (!meal._edited) return;
      var origMeal = origDay ? (origDay.meals || [])[mi] : null;
      history.push({
        mealIndex:    mi,
        mealName:     meal.meal_name || ('Meal ' + (mi + 1)),
        dayIndex:     di,
        dayLabel:     DAY_NAMES[di] || ('Day ' + (di + 1)),
        oldFoods:     normalizeFoodsForHistory(origMeal ? origMeal.foods : null),
        newFoods:     normalizeFoodsForHistory(meal.foods),
        oldCalories:  origMeal ? (origMeal.calories  || 0) : 0,
        newCalories:  meal.calories  || 0,
        oldProtein:   origMeal ? (origMeal.protein_g || 0) : 0,
        newProtein:   meal.protein_g || 0,
        reason:       meal.notes || null,
        modifiedBy:   expertName,
        modifiedAt:   now,
      });
    });
  });
  return history;
}

/* ══════════════════════════════════════════════
   EDITABLE WORKOUT PLAN UI (mirrors diet editing)
   ══════════════════════════════════════════════ */

function buildEditableExerciseEl(exercise, day, plan, card) {
  var exEl = document.createElement('div');
  exEl.className = 'erc-exercise-row ed-exercise-editable' + (exercise._edited ? ' ed-meal-modified' : '');

  var hdr = document.createElement('div');
  hdr.className = 'ed-exercise-hdr erc-meal-hdr';
  hdr.innerHTML =
    '<span class="ed-ex-name ed-disp-name erc-meal-name">' + esc(exercise.name || 'Exercise') + '</span>' +
    '<span class="ed-ex-meta ed-disp-meta erc-meal-time">' +
      (exercise.sets ? exercise.sets + ' sets' : '') +
      (exercise.sets && exercise.reps_or_duration ? ' × ' : '') +
      esc(exercise.reps_or_duration || '') +
    '</span>' +
    '<span class="ed-meal-edited-badge"' + (exercise._edited ? '' : ' style="display:none"') + '>✏ Edited</span>';
  exEl.appendChild(hdr);

  var actionsEl = document.createElement('div');
  actionsEl.className = 'ed-meal-actions';
  actionsEl.innerHTML =
    '<button class="ed-meal-action ed-action--edit" title="Edit exercise">✏ Edit</button>' +
    '<button class="ed-meal-action ed-action--delete" title="Remove exercise">🗑 Remove</button>';
  exEl.appendChild(actionsEl);

  var editForm = document.createElement('div');
  editForm.className = 'ed-meal-edit-form';
  editForm.style.display = 'none';
  editForm.innerHTML =
    '<div class="ed-form-row"><label class="ed-form-label">Exercise Name</label>' +
    '<input class="ed-form-input" data-f="name" value="' + esc(exercise.name || '') + '"></div>' +
    '<div class="ed-form-2col">' +
      '<div class="ed-form-row"><label class="ed-form-label">Sets</label>' +
      '<input class="ed-form-input" type="number" data-f="sets" value="' + esc(String(exercise.sets || '')) + '"></div>' +
      '<div class="ed-form-row"><label class="ed-form-label">Reps / Duration</label>' +
      '<input class="ed-form-input" data-f="reps_or_duration" value="' + esc(exercise.reps_or_duration || '') + '"></div>' +
    '</div>' +
    '<div class="ed-form-row"><label class="ed-form-label">Coaching Notes</label>' +
    '<textarea class="ed-form-textarea" data-f="tip" placeholder="Tips for the athlete...">' + esc(exercise.tip || '') + '</textarea></div>' +
    '<div class="ed-form-btns">' +
      '<button class="ed-form-save-btn">💾 Save Exercise</button>' +
      '<button class="ed-form-cancel-btn">Cancel</button>' +
    '</div>';
  exEl.appendChild(editForm);

  actionsEl.querySelector('.ed-action--edit').addEventListener('click', function() {
    var open = editForm.style.display !== 'none';
    editForm.style.display = open ? 'none' : 'block';
    if (!open) { var f = editForm.querySelector('[data-f="name"]'); if (f) { f.focus(); if (f.select) f.select(); } }
  });

  actionsEl.querySelector('.ed-action--delete').addEventListener('click', function() {
    var mi = Array.from(exEl.parentNode.querySelectorAll('.ed-exercise-editable')).indexOf(exEl);
    if (mi > -1) (day.exercises = day.exercises || []).splice(mi, 1);
    day._edited = true;
    _markPlanEdited(card);
    exEl.style.transition = 'opacity .2s, transform .2s';
    exEl.style.opacity = '0'; exEl.style.transform = 'translateX(-12px)';
    setTimeout(function() { exEl.remove(); }, 210);
  });

  editForm.querySelector('.ed-form-save-btn').addEventListener('click', function() {
    var g = function(f) { return (editForm.querySelector('[data-f="' + f + '"]') || {}).value || ''; };
    exercise.name             = g('name') || exercise.name;
    exercise.sets             = parseInt(g('sets'), 10) || exercise.sets || 0;
    exercise.reps_or_duration = g('reps_or_duration') || exercise.reps_or_duration;
    exercise.tip              = g('tip');
    exercise._edited          = true;
    day._edited               = true;

    hdr.querySelector('.ed-disp-name').textContent = exercise.name;
    hdr.querySelector('.ed-disp-meta').textContent =
      (exercise.sets ? exercise.sets + ' sets' : '') +
      (exercise.sets && exercise.reps_or_duration ? ' × ' : '') +
      (exercise.reps_or_duration || '');
    hdr.querySelector('.ed-meal-edited-badge').style.display = '';
    exEl.classList.add('ed-meal-modified');
    editForm.style.display = 'none';
    _markPlanEdited(card);
  });

  editForm.querySelector('.ed-form-cancel-btn').addEventListener('click', function() {
    editForm.style.display = 'none';
  });

  return exEl;
}

function buildEditableWorkoutPlanEl(review, card) {
  var _rawPlanData = review.planData || {};
  if (_rawPlanData.originalWorkoutPlan || _rawPlanData.currentWorkoutPlan) {
    _rawPlanData = _rawPlanData.currentWorkoutPlan || _rawPlanData.originalWorkoutPlan;
  }

  var plan = JSON.parse(JSON.stringify(_rawPlanData));
  card._editedWorkoutPlan = plan;
  card._hasEdits          = false;

  var days   = plan.weekly_plan || plan.days || [];
  var labels = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

  var wrap = document.createElement('div');
  wrap.className = 'ed-editable-plan-wrap';

  var hdrDiv = document.createElement('div');
  hdrDiv.className = 'erc-plan-header';
  hdrDiv.innerHTML = '<span class="erc-plan-icon">💪</span><div><div class="erc-plan-title">' +
    esc(plan.plan_name || 'AI Workout Plan') + '</div>' +
    (plan.goal ? '<div class="erc-plan-sub">' + esc(plan.goal) + '</div>' : '') + '</div>';
  wrap.appendChild(hdrDiv);

  var pillsDiv = document.createElement('div');
  pillsDiv.className = 'erc-day-pills';
  days.forEach(function(d, i) {
    var pill = document.createElement('button');
    pill.className = 'erc-day-pill' + (i === 0 ? ' active' : '');
    pill.dataset.epWoDayPill = i;
    pill.textContent = labels[i] || ('D' + (i + 1));
    pillsDiv.appendChild(pill);
  });
  wrap.appendChild(pillsDiv);

  var panelsDiv = document.createElement('div');
  panelsDiv.className = 'erc-meals-wrap';

  days.forEach(function(day, di) {
    var panel = document.createElement('div');
    panel.className = 'erc-day-content';
    panel.dataset.woDayEl = di;
    panel.style.display = di === 0 ? 'block' : 'none';

    /* Day focus + duration inline editor */
    var dayHdrEl = document.createElement('div');
    dayHdrEl.className = 'ed-wo-day-hdr erc-day-theme';

    var focusDisp = document.createElement('div');
    focusDisp.className = 'ed-wo-focus-disp';
    focusDisp.innerHTML =
      '<span class="ed-wo-focus-val">' + esc(day.focus || day.type || '—') + '</span>' +
      '<span class="ed-wo-duration-val erc-meal-time">' +
        esc(day.duration_minutes ? ' · ' + day.duration_minutes + ' min' : '') + '</span>' +
      '<button class="ed-meal-action ed-action--edit" style="margin-left:8px">✏ Edit Day</button>';
    dayHdrEl.appendChild(focusDisp);

    var dayEditForm = document.createElement('div');
    dayEditForm.className = 'ed-meal-edit-form';
    dayEditForm.style.display = 'none';
    dayEditForm.innerHTML =
      '<div class="ed-form-row"><label class="ed-form-label">Workout Focus</label>' +
      '<input class="ed-form-input" data-wf="focus" value="' + esc(day.focus || day.type || '') + '"></div>' +
      '<div class="ed-form-row"><label class="ed-form-label">Duration (minutes)</label>' +
      '<input class="ed-form-input" type="number" data-wf="duration_minutes" value="' +
        esc(String(day.duration_minutes || '')) + '"></div>' +
      '<div class="ed-form-row"><label class="ed-form-label">Expert Notes for this Day</label>' +
      '<textarea class="ed-form-textarea" data-wf="daily_tip" placeholder="Tips for the athlete...">' +
        esc(day.daily_tip || '') + '</textarea></div>' +
      '<div class="ed-form-btns">' +
        '<button class="ed-form-save-btn">💾 Save</button>' +
        '<button class="ed-form-cancel-btn">Cancel</button>' +
      '</div>';
    dayHdrEl.appendChild(dayEditForm);

    focusDisp.querySelector('.ed-action--edit').addEventListener('click', function() {
      var open = dayEditForm.style.display !== 'none';
      dayEditForm.style.display = open ? 'none' : 'block';
      if (!open) { var f = dayEditForm.querySelector('[data-wf="focus"]'); if (f) f.focus(); }
    });

    dayEditForm.querySelector('.ed-form-save-btn').addEventListener('click', function() {
      var newFocus = (dayEditForm.querySelector('[data-wf="focus"]') || {}).value || '';
      var newDur   = parseInt((dayEditForm.querySelector('[data-wf="duration_minutes"]') || {}).value || '0', 10);
      var newTip   = (dayEditForm.querySelector('[data-wf="daily_tip"]') || {}).value || '';
      if (newFocus)   { day.focus = newFocus; day.type = newFocus; }
      if (newDur > 0) day.duration_minutes = newDur;
      if (newTip)     day.daily_tip = newTip;
      day._edited = true;
      focusDisp.querySelector('.ed-wo-focus-val').textContent    = day.focus || '—';
      focusDisp.querySelector('.ed-wo-duration-val').textContent =
        day.duration_minutes ? ' · ' + day.duration_minutes + ' min' : '';
      dayEditForm.style.display = 'none';
      _markPlanEdited(card);
    });

    dayEditForm.querySelector('.ed-form-cancel-btn').addEventListener('click', function() {
      dayEditForm.style.display = 'none';
    });

    panel.appendChild(dayHdrEl);

    var exLabel = document.createElement('div');
    exLabel.className = 'erc-exp-sublabel';
    exLabel.style.marginTop = '8px';
    exLabel.textContent = 'Exercises:';
    panel.appendChild(exLabel);

    var exContainer = document.createElement('div');
    exContainer.className = 'ed-meals-container';
    (day.exercises || []).forEach(function(exercise) {
      exContainer.appendChild(buildEditableExerciseEl(exercise, day, plan, card));
    });
    panel.appendChild(exContainer);

    var addExBtn = document.createElement('button');
    addExBtn.className = 'ed-add-meal-btn';
    addExBtn.textContent = '➕ Add Exercise';
    addExBtn.addEventListener('click', function() {
      var newEx = { name: 'New Exercise', sets: 3, reps_or_duration: '10 reps', _edited: true };
      day.exercises = day.exercises || [];
      day.exercises.push(newEx);
      day._edited = true;
      var exEl = buildEditableExerciseEl(newEx, day, plan, card);
      exContainer.appendChild(exEl);
      var ef = exEl.querySelector('.ed-meal-edit-form');
      if (ef) { ef.style.display = 'block'; var inp = ef.querySelector('[data-f="name"]'); if (inp) inp.focus(); }
      _markPlanEdited(card);
    });
    panel.appendChild(addExBtn);

    panelsDiv.appendChild(panel);
  });
  wrap.appendChild(panelsDiv);

  /* Day pill switcher */
  pillsDiv.addEventListener('click', function(e) {
    var pill = e.target.closest('[data-ep-wo-day-pill]');
    if (!pill) return;
    var idx = parseInt(pill.dataset.epWoDayPill, 10);
    pillsDiv.querySelectorAll('[data-ep-wo-day-pill]').forEach(function(p) { p.classList.remove('active'); });
    pill.classList.add('active');
    panelsDiv.querySelectorAll('[data-wo-day-el]').forEach(function(c) {
      c.style.display = parseInt(c.dataset.woDayEl, 10) === idx ? 'block' : 'none';
    });
  });

  var saveBtn = document.createElement('button');
  saveBtn.className = 'ed-save-changes-btn';
  saveBtn.textContent = '💾 Save Changes';
  saveBtn.disabled = true;
  card._saveChangesBtn = saveBtn;
  wrap.appendChild(saveBtn);

  return wrap;
}

/* Build workoutChangeHistory by diffing original plan against expert-edited plan */
function buildWorkoutChangeHistory(origPlan, newPlan, expertName) {
  var history  = [];
  var DAY_NAMES = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
  var now      = new Date().toISOString();

  var origDays = (origPlan && (origPlan.weekly_plan || origPlan.days)) || [];
  var newDays  = (newPlan  && (newPlan.weekly_plan  || newPlan.days))  || [];
  if (!newDays.length) return history;

  newDays.forEach(function(day, di) {
    if (!day._edited) return;
    var origDay = origDays[di];
    history.push({
      dayIndex:    di,
      dayLabel:    DAY_NAMES[di] || ('Day ' + (di + 1)),
      oldWorkout:  origDay ? {
        focus:             origDay.focus || origDay.type || '',
        duration_minutes:  origDay.duration_minutes || 0,
        exercises:         (origDay.exercises || []).map(function(e) {
          return { name: e.name, sets: e.sets, reps_or_duration: e.reps_or_duration };
        }),
      } : null,
      newWorkout:  {
        focus:             day.focus || day.type || '',
        duration_minutes:  day.duration_minutes || 0,
        exercises:         (day.exercises || []).map(function(e) {
          return { name: e.name, sets: e.sets, reps_or_duration: e.reps_or_duration };
        }),
      },
      modifiedBy: expertName,
      modifiedAt: now,
    });
  });
  return history;
}

async function savePlanEdits(reviewId, card, expert) {
  console.log('[REVIEW COMPLETE] clicked requestId=' + reviewId);

  var all = [];
  try { all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]'); } catch (_) {}
  var idx = all.findIndex(function(r) { return r.id === reviewId; });

  /* ROOT CAUSE OF "Complete Review does nothing": this used to be
     `if (idx === -1) return;` — a bare, silent return whenever the review was
     not in THIS device's localStorage cache. No log, no toast, no error: the
     expert clicked Complete Review and absolutely nothing happened.

     The cache is only populated by the dashboard's Firestore snapshot handler,
     so it is empty on a fresh device or session, after a storage clear, and in
     the Flutter WebView (which keeps its own separate storage). Firestore —
     not localStorage — is the authority for the review, so fall back to it
     instead of giving up. */
  if (idx === -1) {
    console.warn('[REVIEW COMPLETE] not in local cache — fetching from Firestore', reviewId);
    if (typeof ZitlasDB === 'undefined') {
      console.error('[REVIEW COMPLETE] FAILURE code=no_firestore message=review not cached and Firestore unavailable');
      edShowToast('⚠ Could not load this review. Check your connection and try again.');
      return;
    }
    try {
      var snap = await ZitlasDB.collection('review_requests').doc(reviewId).get();
      if (!snap.exists) {
        console.error('[REVIEW COMPLETE] FAILURE code=not_found message=review_requests/' + reviewId + ' does not exist');
        edShowToast('⚠ This review no longer exists.');
        return;
      }
      all.push(Object.assign({ id: snap.id }, snap.data()));
      idx = all.length - 1;
      console.log('[REVIEW COMPLETE] recovered review from Firestore', reviewId);
    } catch (e) {
      console.error('[REVIEW COMPLETE] FAILURE code=' + (e && e.code) + ' message=' + (e && e.message));
      edShowToast('⚠ Could not load this review. Check your connection and try again.');
      return;
    }
  }

  var _rev = all[idx];
  var _origForDiff = _rev.planData;

  /* Detect workout review — normalise: old reviews used planReviewType, new ones reviewType */
  var _revType = _rev.reviewType || _rev.planReviewType || '';
  var _isWorkoutReview = _revType === 'workout' ||
    (_revType === '' && card._editedWorkoutPlan !== undefined);

  console.log("SAVE PLAN EDITS CARD", card);
  console.log("EDITED WORKOUT", card._editedWorkoutPlan);
  console.log("REVIEW BEFORE SAVE", _rev);
  console.log("REVIEW OBJECT", _rev);
  console.log("[savePlanEdits] reviewType:", _rev.reviewType, "| planReviewType:", _rev.planReviewType, "| _revType:", _revType, "| _isWorkoutReview:", _isWorkoutReview);

  if (_isWorkoutReview) {
    if (_origForDiff && (_origForDiff.originalWorkoutPlan || _origForDiff.currentWorkoutPlan)) {
      _origForDiff = _origForDiff.originalWorkoutPlan || _origForDiff.currentWorkoutPlan;
    }
    var workoutChangeHistory = buildWorkoutChangeHistory(_origForDiff, card._editedWorkoutPlan, expert.name);
    console.log("WORKOUT HISTORY", workoutChangeHistory);
    _rev.reviewedWorkoutPlan  = card._editedWorkoutPlan || null;
    _rev.workoutChangeHistory = workoutChangeHistory;
  } else {
    if (_origForDiff && (_origForDiff.originalDietPlan || _origForDiff.currentDietPlan)) {
      _origForDiff = _origForDiff.originalDietPlan || _origForDiff.currentDietPlan;
    }
    var mealChangeHistory = buildMealChangeHistory(_origForDiff, card._editedPlan, expert.name);
    console.log("[REVIEW BEFORE SAVE]", _rev);
    console.log("[REVIEW planData]", _rev.planData);
    console.log("[REVIEW reviewedDietPlan]", card._editedPlan);
    console.log("[REVIEW mealChangeHistory]", mealChangeHistory);
    _rev.reviewedDietPlan  = card._editedPlan;
    _rev.mealChangeHistory = mealChangeHistory;
  }

  console.log('reviewId', reviewId);
  console.log('review', _rev);
  console.log('status before update', _rev.status);

  var _prevStatus = _rev.status;
  _rev.status      = 'review_completed';
  _rev.reviewedAt  = new Date().toISOString();
  _rev.completedAt = new Date().toISOString();
  _rev.expertId    = expert.id;
  _rev.expertName  = expert.name;

  try { localStorage.setItem('expert_plan_reviews', JSON.stringify(all)); } catch (_) {}

  /* Sync completed review to Firestore so athlete's device can pick up the update */
  if (typeof ZitlasDB !== 'undefined') {
    var _fsUpdate = {
      status:      'review_completed',
      reviewedAt:  _rev.reviewedAt,
      completedAt: _rev.completedAt,
      expertId:    _rev.expertId,
      expertName:  _rev.expertName,
    };
    if (_isWorkoutReview) {
      _fsUpdate.reviewedWorkoutPlan  = _rev.reviewedWorkoutPlan  || null;
      _fsUpdate.workoutChangeHistory = _rev.workoutChangeHistory || [];
    } else {
      _fsUpdate.reviewedDietPlan  = _rev.reviewedDietPlan  || null;
      _fsUpdate.mealChangeHistory = _rev.mealChangeHistory || [];
    }
    console.log('writing to firestore...');
    /* Temporary diagnostic — remove once the athlete-side stale-status
       investigation is closed. */
    console.log('[REVIEW COMPLETE]',
      'requestId=' + reviewId,
      'previousStatus=' + _prevStatus,
      'newStatus=' + _fsUpdate.status);
    console.log('[REVIEW COMPLETE] updating review status');
    try {
      /* `.update()` (not `.set()`) on purpose: it fails loudly if the document
         does not exist, rather than creating a partial review that no athlete
         listener would ever match. */
      await ZitlasDB.collection('review_requests').doc(reviewId).update(_fsUpdate);
      console.log('[REVIEW COMPLETE] status update success', reviewId);
    } catch (e) {
      /* ROOT CAUSE OF "expert changes never reach the athlete": this was
         caught, logged as a warning, and then the success toast fired anyway
         — so a rejected or failed write looked identical to a successful one.
         The expert saw "✅ Review saved" while the athlete's Diet never
         changed, because the only copy of the edit was in the expert's own
         localStorage. Fail visibly and leave the card actionable so the
         expert can retry. */
      console.error('[REVIEW COMPLETE] FAILURE code=' + (e && e.code) +
                    ' message=' + (e && e.message));
      _rev.status = _prevStatus;   // roll the local echo back
      try { localStorage.setItem('expert_plan_reviews', JSON.stringify(all)); } catch (_) {}
      edShowToast('⚠ Could not send the review — the athlete has NOT received it. Please retry.');
      if (card && card._saveChangesBtn) {
        card._saveChangesBtn.disabled = false;
        card._saveChangesBtn.textContent = 'Complete Review';
      }
      return;
    }
  } else {
    console.error('[REVIEW COMPLETE] FAILURE code=no_firestore ' +
                  'message=review saved locally only; the athlete will never receive it');
    edShowToast('⚠ Could not send the review — you appear to be offline.');
    return;
  }
  var _updatedReview = (JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]') || []).find(function(r) { return r.id === reviewId; }) || null;
  console.log("REVIEW AFTER SAVE", _updatedReview);
  console.log("[STORED REVIEW] reviewedWorkoutPlan present:", !!(_updatedReview && _updatedReview.reviewedWorkoutPlan));
  console.log("[STORED REVIEW] workoutChangeHistory length:", _updatedReview && _updatedReview.workoutChangeHistory ? _updatedReview.workoutChangeHistory.length : 0);

  edShowToast('✅ Review saved — athlete will be notified.');

  if (card) {
    var badge = card.querySelector('.erc-badge');
    var sb = statusBadge('review_completed');
    if (badge) { badge.textContent = sb.label; badge.className = 'erc-badge ' + sb.cls; }
    card.dataset.prStatus = 'review_completed';
    if (card._saveChangesBtn) {
      card._saveChangesBtn.textContent = '✅ Changes Saved';
      card._saveChangesBtn.disabled = true;
      card._saveChangesBtn.classList.remove('ed-save-active');
    }
  }
}

/* Completion UI for a workout review. Extracted so it can be called ONLY from
   the resolved Firestore write — see the call site. */
function _markWorkoutReviewSent(card) {
  if (!card) return;
  var badge = card.querySelector('.erc-badge');
  if (badge) { badge.textContent = 'Completed'; badge.className = 'erc-badge status-completed'; }
  var actions = card.querySelector('.erc-actions');
  if (actions) actions.innerHTML = '<span class="erc-approved-stamp">✅ Review Sent to Athlete</span>';
  card.dataset.prStatus = 'review_completed';
  edShowToast('✅ Review saved — athlete will be notified.');
}

function buildPlanReviewCard(review, expert) {
  var card = document.createElement('div');
  card.className = 'ed-review-card ed-pr-card';
  card.dataset.prId = review.id;
  card.dataset.prStatus = review.status || 'pending';

  /* Normalise: old reviews used planReviewType, new ones use reviewType */
  var _rtype    = review.reviewType || review.planReviewType || 'diet';
  var typeIcon  = _rtype === 'diet' ? '🥗' : '💪';
  var typeLabel = _rtype === 'diet' ? 'Diet Plan' : 'Workout Plan';
  var typeCls   = _rtype === 'diet' ? 'pr-type--diet' : 'pr-type--workout';
  var sb        = statusBadge(review.status);
  var submittedAt = review.createdAt ? formatDate(review.createdAt) : '';
  var notesHtml   = review.expertNotes
    ? '<div class="erc-expert-note"><span class="erc-expert-note-label">Your Feedback:</span> ' + esc(review.expertNotes) + '</div>'
    : '';

  var st = review.status || 'pending';
  var actionHtml = '';
  if (st === 'pending') {
    actionHtml =
      '<button class="erc-btn erc-btn--approve pr-accept-btn" data-pr-id="' + esc(review.id) + '">✅ Accept Request</button>' +
      '<button class="erc-btn erc-btn--reject pr-reject-btn"  data-pr-id="' + esc(review.id) + '">✕ Reject</button>';
  } else if (st === 'accepted') {
    actionHtml =
      '<button class="erc-btn erc-btn--secondary pr-suggest-btn" data-pr-id="' + esc(review.id) + '">✏️ Send Feedback</button>' +
      '<button class="erc-btn erc-btn--reject pr-reject-btn"    data-pr-id="' + esc(review.id) + '">✕ Reject</button>';
  } else if (st === 'review_completed') {
    actionHtml = '<span class="erc-approved-stamp">✅ Review Sent to Athlete</span>';
  } else if (st === 'completed') {
    actionHtml = '<span class="erc-approved-stamp">✅ Review Complete</span>';
  } else if (st === 'rejected') {
    actionHtml = '<span class="erc-approved-stamp" style="color:var(--primary-dark)">✕ Rejected</span>';
  } else {
    actionHtml =
      '<button class="erc-btn erc-btn--secondary pr-suggest-btn" data-pr-id="' + esc(review.id) + '">✏️ Send Feedback</button>';
  }

  /* Static card shell */
  card.innerHTML =
    '<div class="erc-header">' +
      '<div class="erc-athlete-name">Athlete Plan Request</div>' +
      '<span class="erc-badge ' + esc(sb.cls) + '">' + esc(sb.label) + '</span>' +
    '</div>' +
    '<div class="ed-pr-type-row">' +
      '<span class="ed-pr-type-badge ' + typeCls + '">' + typeIcon + ' ' + esc(typeLabel) + ' Review</span>' +
      (submittedAt ? '<span class="erc-fee-time">' + esc(submittedAt) + '</span>' : '') +
    '</div>' +
    notesHtml +
    '<button class="erc-expand-toggle">View Plan Details ▼</button>' +
    '<div class="erc-expanded" style="display:none"></div>' +
    '<div class="erc-actions">' + actionHtml + '</div>';

  /* Populate expanded section with DOM so we can append interactive elements */
  var expanded = card.querySelector('.erc-expanded');

  /* Part 1 — Fitness Target */
  var ftHtml = buildFitnessTargetHTML(review);
  if (ftHtml) {
    var ftEl = document.createElement('div');
    ftEl.innerHTML = ftHtml;
    while (ftEl.firstChild) expanded.appendChild(ftEl.firstChild);
  }

  /* Basic stats row */
  var p = review.profileBasics || {};
  if (p.age || p.gender || p.weight_kg || p.height_cm) {
    var statsEl = document.createElement('div');
    statsEl.className = 'erc-exp-section';
    statsEl.innerHTML = '<div class="erc-exp-sublabel">Athlete Stats</div><div class="erc-exp-data-grid">' +
      (p.age       ? '<span class="erc-exp-item"><b>Age</b> ' + esc(String(p.age)) + '</span>' : '') +
      (p.gender    ? '<span class="erc-exp-item"><b>Gender</b> ' + esc(String(p.gender).charAt(0).toUpperCase() + String(p.gender).slice(1)) + '</span>' : '') +
      (p.height_cm ? '<span class="erc-exp-item"><b>Height</b> ' + esc(String(p.height_cm)) + ' cm</span>' : '') +
      (p.weight_kg ? '<span class="erc-exp-item"><b>Weight</b> ' + esc(String(p.weight_kg)) + ' kg</span>' : '') +
      (p.diet_preference ? '<span class="erc-exp-item"><b>Diet Pref</b> ' + esc(String(p.diet_preference).replace(/_/g,' ')) + '</span>' : '') +
      '</div>';
    expanded.appendChild(statsEl);
  }

  /* Part 2 — Plan section (editable for diet, read-only for workout) */
  var planSection = document.createElement('div');
  planSection.className = 'erc-exp-section';
  var planLabelEl = document.createElement('div');
  planLabelEl.className = 'erc-exp-label';
  /* _rtype already normalised above */
  planLabelEl.textContent = _rtype === 'diet'
    ? (st === 'accepted' ? '✏ Edit Diet Plan Below' : 'Diet Plan to Review')
    : ((st === 'pending' || st === 'accepted') ? '✏ Edit Workout Plan Below' : 'Workout Plan to Review');
  planSection.appendChild(planLabelEl);

  if (_rtype === 'diet' && review.planData && (st === 'pending' || st === 'accepted')) {
    /* Editable plan */
    planSection.appendChild(buildEditableDietPlanEl(review, card));
  } else if (_rtype === 'diet' && review.planData) {
    /* Read-only for completed/rejected */
    var _roPlan = review.planData;
    if (_roPlan && (_roPlan.originalDietPlan || _roPlan.currentDietPlan)) {
      _roPlan = _roPlan.currentDietPlan || _roPlan.originalDietPlan;
    }
    var roWrap = document.createElement('div');
    roWrap.className = 'erc-plan-wrap';
    roWrap.innerHTML = buildDietPlanHTML(_roPlan);
    planSection.appendChild(roWrap);
  } else if (_rtype === 'workout') {
    /* Always render editable UI for pending/accepted — even when planData is null,
       buildEditableWorkoutPlanEl handles it with an empty plan so card._editedWorkoutPlan
       is always set, which savePlanEdits requires to detect workout vs diet review. */
    if (st === 'pending' || st === 'accepted') {
      planSection.appendChild(buildEditableWorkoutPlanEl(review, card));
    } else if (review.planData) {
      var woWrap = document.createElement('div');
      woWrap.className = 'erc-plan-wrap';
      woWrap.innerHTML = buildWorkoutPlanHTML(review.planData);
      planSection.appendChild(woWrap);
    }
  }

  expanded.appendChild(planSection);

  return card;
}

function initPlanReviewCardInteractions(card, review, expert) {
  var toggle   = card.querySelector('.erc-expand-toggle');
  var expanded = card.querySelector('.erc-expanded');
  if (toggle && expanded) {
    toggle.addEventListener('click', function() {
      var open = expanded.style.display !== 'none';
      expanded.style.display = open ? 'none' : 'block';
      toggle.textContent = open ? 'View Plan Details ▼' : 'Hide Details ▲';
    });
  }

  /* Wire Save Changes button */
  if (card._saveChangesBtn) {
    card._saveChangesBtn.addEventListener('click', function() {
      savePlanEdits(review.id, card, expert);
    });
  }

  card.addEventListener('click', function(e) {
    /* Accept Request */
    var acceptBtn = e.target.closest('.pr-accept-btn');
    if (acceptBtn) {
      var prId = acceptBtn.dataset.prId;
      savePlanReviewStatus(prId, 'accepted', { acceptedAt: new Date().toISOString(), expertId: expert.id });
      var badge = card.querySelector('.erc-badge');
      var sb = statusBadge('accepted');
      if (badge) { badge.textContent = sb.label; badge.className = 'erc-badge ' + sb.cls; }
      var actions = card.querySelector('.erc-actions');
      if (actions) {
        actions.innerHTML =
          '<button class="erc-btn erc-btn--approve pr-complete-btn" data-pr-id="' + esc(prId) + '">✅ Mark as Reviewed</button>' +
          '<button class="erc-btn erc-btn--secondary pr-suggest-btn" data-pr-id="' + esc(prId) + '">✏️ Send Feedback</button>' +
          '<button class="erc-btn erc-btn--reject pr-reject-btn" data-pr-id="' + esc(prId) + '">✕ Reject</button>';
      }
      card.dataset.prStatus = 'accepted';
      edShowToast('✅ Request accepted. Athlete can now chat with you.');
    }

    /* Mark as Reviewed — write workout fields DIRECTLY to avoid any branching bug */
    var completeBtn = e.target.closest('.pr-complete-btn');
    if (completeBtn) {
      var prId = completeBtn.dataset.prId;

      var _cAllRevs = [];
      try { _cAllRevs = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]'); } catch (_e) {}
      var _cIdx = _cAllRevs.findIndex(function(r) { return r.id === prId; });

      console.log("CARD EDITED WORKOUT", card._editedWorkoutPlan);
      console.log("CARD HISTORY", card._workoutChangeHistory);

      if (_cIdx !== -1) {
        var _cRev = _cAllRevs[_cIdx];
        var _cType = _cRev.reviewType || _cRev.planReviewType || '';

        console.log("REVIEW BEFORE SAVE", JSON.parse(JSON.stringify(_cRev)));

        if (_cType === 'workout') {
          /* Unwrap original plan for diff */
          var _cOrig = _cRev.planData || null;
          if (_cOrig && (_cOrig.originalWorkoutPlan || _cOrig.currentWorkoutPlan)) {
            _cOrig = _cOrig.originalWorkoutPlan || _cOrig.currentWorkoutPlan;
          }

          /* reviewedWorkoutPlan = what the expert produced; fall back to planData if no edits */
          var _cReviewedPlan = card._editedWorkoutPlan || _cOrig || null;
          var _cHistory = buildWorkoutChangeHistory(_cOrig, card._editedWorkoutPlan, expert.name);

          console.log("WORKOUT HISTORY", _cHistory);

          _cRev.reviewedWorkoutPlan  = _cReviewedPlan;
          _cRev.workoutChangeHistory = _cHistory;
          _cRev.athleteAccepted      = false;
        } else {
          /* Diet review — use the existing savePlanEdits path */
          savePlanEdits(prId, card, expert);
        }

        var _cPrevStatus = _cRev.status;
        _cRev.status      = 'review_completed';
        _cRev.reviewedAt  = new Date().toISOString();
        _cRev.completedAt = new Date().toISOString();
        _cRev.expertId    = expert.id;
        _cRev.expertName  = expert.name;

        try { localStorage.setItem('expert_plan_reviews', JSON.stringify(_cAllRevs)); } catch (_e) {}
        var _cUpdated = _cAllRevs[_cIdx];
        console.log('[REVIEW] completed (workout path)', prId);
        console.log("[STORED] reviewedWorkoutPlan present:", !!(_cUpdated && _cUpdated.reviewedWorkoutPlan));
        console.log("[STORED] workoutChangeHistory length:", _cUpdated && _cUpdated.workoutChangeHistory ? _cUpdated.workoutChangeHistory.length : 0);

        /* Sync review_completed to Firestore so athlete listener fires */
        if (typeof ZitlasDB !== 'undefined' && _cUpdated) {
          var _wFsUpdate = {
            status:               'review_completed',
            reviewedAt:           _cRev.reviewedAt,
            completedAt:          _cRev.completedAt,
            expertId:             _cRev.expertId,
            expertName:           _cRev.expertName,
            reviewedWorkoutPlan:  _cRev.reviewedWorkoutPlan  || null,
            workoutChangeHistory: _cRev.workoutChangeHistory || [],
          };
          /* Temporary diagnostic — remove once the athlete-side stale-status
             investigation is closed. */
          console.log('[REVIEW COMPLETE]',
            'requestId=' + prId,
            'previousStatus=' + _cPrevStatus,
            'newStatus=' + _wFsUpdate.status);
          /* Same fix as savePlanEdits: the completion UI must not run until
             the write actually lands. This previously fired "✅ Review Sent to
             Athlete" while the promise was still in flight, and swallowed any
             rejection into a console warning — so a failed workout review
             looked identical to a successful one. */
          ZitlasDB.collection('review_requests').doc(prId).update(_wFsUpdate)
            .then(function() {
              console.log('[REVIEW COMPLETE] status update success', prId);
              _markWorkoutReviewSent(card);
            })
            .catch(function(e) {
              console.error('[REVIEW COMPLETE] FAILURE code=' + (e && e.code) +
                            ' message=' + (e && e.message));
              edShowToast('⚠ Could not send the review — the athlete has NOT received it. Please retry.');
            });
        } else {
          console.error('[REVIEW COMPLETE] FAILURE code=no_firestore ' +
                        'message=workout review saved locally only; the athlete will never receive it');
          edShowToast('⚠ Could not send the review — you appear to be offline.');
        }
      }
    }

    /* Reject */
    var rejectBtn = e.target.closest('.pr-reject-btn');
    if (rejectBtn) {
      var prId = rejectBtn.dataset.prId;
      savePlanReviewStatus(prId, 'rejected');
      var badge = card.querySelector('.erc-badge');
      if (badge) { badge.textContent = 'Rejected'; badge.className = 'erc-badge status-rejected'; }
      var actions = card.querySelector('.erc-actions');
      if (actions) actions.innerHTML = '<span class="erc-approved-stamp" style="color:var(--primary-dark)">✕ Rejected</span>';
      card.dataset.prStatus = 'rejected';
      edShowToast('Plan review rejected.');
    }

    /* Send Feedback (Suggest Changes) */
    var suggestBtn = e.target.closest('.pr-suggest-btn');
    if (suggestBtn) {
      _prSuggestCtx = { reviewId: suggestBtn.dataset.prId, card: card };
      var modal = document.getElementById('prSuggestModal');
      var input = document.getElementById('prSuggestInput');
      if (!modal) return;
      if (input) input.value = '';
      modal.style.display = 'flex';
      setTimeout(function() { modal.classList.add('open'); }, 10);
      if (input) input.focus();
    }
  });
}

function wirePlanReviewPills(card) {
  card.querySelectorAll('[data-diet-day]').forEach(function(pill) {
    if (pill._wired) return;
    pill._wired = true;
    pill.addEventListener('click', function() {
      var dayIdx = parseInt(pill.dataset.dietDay, 10);
      card.querySelectorAll('[data-diet-day]').forEach(function(p) { p.classList.remove('active'); });
      pill.classList.add('active');
      card.querySelectorAll('[data-diet-content]').forEach(function(c) {
        c.style.display = parseInt(c.dataset.dietContent, 10) === dayIdx ? 'block' : 'none';
      });
    });
  });
}

function initPrSuggestModal() {
  var closeBtn   = document.getElementById('prSuggestClose');
  var cancelBtn  = document.getElementById('prSuggestCancel');
  var confirmBtn = document.getElementById('prSuggestConfirm');
  var overlay    = document.getElementById('prSuggestModal');

  function closePrModal() {
    if (!overlay) return;
    overlay.classList.remove('open');
    setTimeout(function() { overlay.style.display = 'none'; }, 220);
    _prSuggestCtx = { reviewId: null, card: null };
  }

  if (closeBtn)   closeBtn.addEventListener('click', closePrModal);
  if (cancelBtn)  cancelBtn.addEventListener('click', closePrModal);
  if (overlay)    overlay.addEventListener('click', function(e) { if (e.target === overlay) closePrModal(); });

  if (confirmBtn) {
    confirmBtn.addEventListener('click', function() {
      var notes = (document.getElementById('prSuggestInput') || {}).value || '';
      var ctx   = _prSuggestCtx;
      if (!ctx.reviewId) return;

      savePlanReviewStatus(ctx.reviewId, 'review_completed', { expertNotes: notes || null });
      if (typeof ZitlasDB !== 'undefined') {
        ZitlasDB.collection('review_requests').doc(ctx.reviewId)
          .update({ status: 'review_completed', expertNotes: notes || null, completedAt: new Date().toISOString() })
          .catch(function(e) { console.warn('[REVIEW] suggest-complete Firestore write failed:', e); });
      }

      if (ctx.card) {
        var badge = ctx.card.querySelector('.erc-badge');
        var sb = statusBadge('completed');
        if (badge) { badge.textContent = sb.label; badge.className = 'erc-badge ' + sb.cls; }
        var actions = ctx.card.querySelector('.erc-actions');
        if (actions) actions.innerHTML = '<span class="erc-approved-stamp" style="color:var(--ai-accent)">✏️ Feedback Sent</span>';
        ctx.card.dataset.prStatus = 'completed';
        if (notes) {
          var noteEl = ctx.card.querySelector('.erc-expert-note');
          if (!noteEl) {
            var typeRow = ctx.card.querySelector('.ed-pr-type-row');
            if (typeRow) {
              var nd = document.createElement('div');
              nd.className = 'erc-expert-note';
              nd.innerHTML = '<span class="erc-expert-note-label">Your Feedback:</span> ' + esc(notes);
              typeRow.insertAdjacentElement('afterend', nd);
            }
          } else {
            noteEl.innerHTML = '<span class="erc-expert-note-label">Your Feedback:</span> ' + esc(notes);
          }
        }
        ctx.card.dataset.prStatus = 'changes_suggested';
      }

      closePrModal();
      edShowToast('✏️ Feedback sent to athlete.');
    });
  }
}

/* ══════════════════════════════════════════════
   REVIEWS INBOX — tab-based, chat-first
   ══════════════════════════════════════════════ */

function renderInbox(expert, expertUid) {
  var list = document.getElementById('prInboxList');
  if (!list) return;

  /* Prefer live Firebase UID; fall back to expert.id from profile */
  var _eid = expertUid ||
    (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser ? ZitlasAuth.currentUser.uid : null) ||
    expert.id;

  var reviews = getPlanReviews(_eid);
  console.log('[REVIEW] rendering', reviews.length, 'reviews for', _eid);

  /* Normalize legacy statuses and bucket by canonical values */
  var pending    = reviews.filter(function(r) { return _normalizeStatus(r.status) === 'pending'; });
  var inProgress = reviews.filter(function(r) { return _normalizeStatus(r.status) === 'in_progress'; });
  var completed  = reviews.filter(function(r) {
    var s = _normalizeStatus(r.status);
    return s === 'review_completed' || s === 'rejected';
  });

  /* Update tab badges */
  var badgePending    = document.getElementById('prTabBadgePending');
  var badgeInProgress = document.getElementById('prTabBadgeInProgress');
  if (badgePending) {
    badgePending.textContent  = pending.length;
    badgePending.style.display = pending.length ? 'inline-flex' : 'none';
  }
  if (badgeInProgress) {
    badgeInProgress.textContent  = inProgress.length;
    badgeInProgress.style.display = inProgress.length ? 'inline-flex' : 'none';
  }

  /* Also update main nav badge */
  var navBadge = document.getElementById('navBadgeReviews');
  if (navBadge) {
    var total = pending.length + inProgress.length;
    navBadge.textContent  = total;
    navBadge.style.display = total ? 'inline-flex' : 'none';
  }

  /* Update dashboard stat cards from the canonical expert_plan_reviews source */
  var doneBucket = reviews.filter(function(r) {
    return r.status === 'review_completed' || r.status === 'completed' || r.status === 'approved';
  });
  var activeClients = reviews.filter(function(r) { return r.status !== 'rejected'; });
  setStatText('statPending', 'statPendingLabel', pending.length + inProgress.length, 'Pending Reviews', "🎉 You're all caught up.");
  setText('statClients',  activeClients.length);
  setText('statEarnings', doneBucket.length > 0 ? '₹' + (doneBucket.length * expert.fee) : '₹0');

  /* Pick the correct bucket for the active tab */
  var bucket;
  if (_prInboxActiveTab === 'in_progress') bucket = inProgress;
  else if (_prInboxActiveTab === 'completed') bucket = completed;
  else bucket = pending;

  /* Render cards */
  list.innerHTML = '';

  if (!bucket.length) {
    var emptyMsgs = {
      pending:     ['📋', 'No Pending Reviews', 'New athlete requests will appear here.'],
      in_progress: ['💬', 'No Active Reviews', 'Accepted reviews open here for consultation.'],
      completed:   ['✅', 'No Completed Reviews', 'Finished reviews are archived here.'],
    };
    var em = emptyMsgs[_prInboxActiveTab] || emptyMsgs.pending;
    list.innerHTML =
      '<div class="pr-inbox-empty">' +
        '<span class="pr-inbox-empty-icon">' + em[0] + '</span>' +
        '<p class="pr-inbox-empty-title">' + em[1] + '</p>' +
        '<p class="pr-inbox-empty-sub">' + em[2] + '</p>' +
      '</div>';
    return;
  }

  /* PRIORITY QUEUE: Premium athletes' requests pin to the top (stamped
     isPremium at request creation), then newest-first within each group. */
  bucket = bucket.slice().sort(function(a, b) {
    var prem = (b.isPremium ? 1 : 0) - (a.isPremium ? 1 : 0);
    if (prem !== 0) return prem;
    return new Date(b.createdAt || b.acceptedAt || 0) - new Date(a.createdAt || a.acceptedAt || 0);
  });

  bucket.forEach(function(review) {
    var card = _prBuildInboxCard(review, expert);
    list.appendChild(card);
  });

  /* Cross-tab live update */
  if (!list._storageWired) {
    list._storageWired = true;
    window.addEventListener('storage', function(e) {
      if (e.key === 'expert_plan_reviews') renderInbox(expert);
    });
  }
}

function _prBuildInboxCard(review, expert) {
  var card = document.createElement('div');
  card.className = 'pr-inbox-card';

  var rtype     = review.reviewType || review.planReviewType || 'diet';
  var isChatOnly = rtype === 'chat_only';
  var typeLabel = rtype === 'workout' ? '💪 Workout Plan Review' : isChatOnly ? '💬 Chat Consultation' : '🥗 Diet Plan Review';
  var nameInit  = ((review.athleteName || review.userName || 'A').split(' ')
                    .map(function(w) { return w[0] || ''; }).join('').slice(0, 2) || 'A').toUpperCase();
  var displayName = review.athleteName || review.userName || 'Athlete';
  var timeAgo     = review.createdAt ? _prTimeAgo(review.createdAt) : '';
  var priceTag    = (review.totalPrice !== undefined && review.totalPrice !== null) ? '₹' + review.totalPrice : '';

  var actionsHtml = '';
  var st = review.status || 'pending';

  if (st === 'pending' && review.bundleRole === 'secondary') {
    /* "Both" requests are two linked docs — only the primary (diet) takes
       the Accept/Reject action and the one-time charge; this card mirrors
       to in_progress/paid automatically once the primary is accepted. */
    actionsHtml = '<span class="pr-inbox-stamp">🔗 Bundled with Diet Review — accept that to start both</span>';
  } else if (st === 'pending') {
    actionsHtml =
      '<button class="pr-inbox-btn pr-inbox-btn--accept" data-pr-accept="' + esc(review.id) + '">✅ Accept' + (priceTag ? ' (' + priceTag + ')' : '') + '</button>' +
      '<button class="pr-inbox-btn pr-inbox-btn--reject" data-pr-reject="' + esc(review.id) + '">✕ Reject</button>';
  } else if (st === 'accepted' && review.paymentStatus === 'awaiting_payment') {
    actionsHtml = '<span class="pr-inbox-stamp">⏳ Awaiting Payment</span>';
  } else if (st === 'accepted' || st === 'in_progress') {
    actionsHtml =
      (isChatOnly ? '' : '<button class="pr-inbox-btn pr-inbox-btn--accept" data-pr-editplan="' + esc(review.id) + '">✏️ Edit Plan</button>') +
      '<button class="pr-inbox-btn pr-inbox-btn--chat" data-pr-openchat="' + esc(review.id) + '">💬 Chat</button>';
  } else if (st === 'completed' || st === 'review_completed') {
    actionsHtml = '<span class="pr-inbox-stamp pr-inbox-stamp--done">✅ Review Sent to Athlete</span>';
  } else if (st === 'rejected') {
    actionsHtml = '<span class="pr-inbox-stamp pr-inbox-stamp--rejected">✕ Rejected</span>';
  }

  /* Premium athletes' requests are pinned first (see renderInbox sort) —
     the badge tells the expert WHY this card outranks older ones. */
  var premiumBadge = review.isPremium
    ? '<span class="pr-inbox-stamp" style="background:linear-gradient(135deg,#234B35,#2E5F47);color:#101010;font-weight:800;border-radius:999px;padding:2px 10px;font-size:10px;letter-spacing:.04em;">⭐ PRIORITY · PREMIUM</span>'
    : '';

  card.innerHTML =
    '<div class="pr-inbox-card-top">' +
      '<div class="pr-inbox-avatar">' + esc(nameInit) + '</div>' +
      '<div class="pr-inbox-info">' +
        '<div class="pr-inbox-name">' + esc(displayName) + (premiumBadge ? ' ' + premiumBadge : '') + '</div>' +
        '<div class="pr-inbox-meta">' +
          '<span>' + typeLabel + '</span>' +
          (timeAgo ? '<span class="pr-inbox-meta-dot">·</span><span>' + esc(timeAgo) + '</span>' : '') +
        '</div>' +
      '</div>' +
    '</div>' +
    '<div class="pr-inbox-actions">' + actionsHtml + '</div>';

  /* Wire actions */
  card.addEventListener('click', function(e) {
    var acceptEl = e.target.closest('[data-pr-accept]');
    if (acceptEl) { _prAcceptReview(acceptEl.dataset.prAccept, review, expert); return; }

    var rejectEl = e.target.closest('[data-pr-reject]');
    if (rejectEl) { _prRejectReview(rejectEl.dataset.prReject, review, expert); return; }

    var editEl = e.target.closest('[data-pr-editplan]');
    if (editEl) {
      try { sessionStorage.setItem('zitlas_modify_expert', JSON.stringify(expert)); } catch (_) {}
      var rtype = review.reviewType || review.planReviewType || 'diet';
      window.location.href = rtype === 'workout'
        ? 'modify-workout.html?reviewId=' + encodeURIComponent(review.id)
        : 'modify-diet.html?reviewId='    + encodeURIComponent(review.id);
      return;
    }

    var chatEl = e.target.closest('[data-pr-openchat]');
    if (chatEl) { _prOpenReviewChat(review, expert); return; }
  });

  return card;
}

function _prAcceptReview(reviewId, review, expert) {
  var rtype      = review.reviewType || review.planReviewType || 'diet';
  var isChatOnly = rtype === 'chat_only';
  var convId     = expert.id;
  var _now       = new Date().toISOString();

  /* Requests created before per-service pricing existed have no totalPrice/
     serviceType at all — behave exactly as before for them (full price =
     expert.fee, chat always included), so old in-flight reviews are
     unaffected by this feature shipping. */
  var hasPricingFields = review.totalPrice !== undefined && review.totalPrice !== null;
  var amount        = hasPricingFields ? Number(review.totalPrice) : Number(expert.fee || 0);
  var chatIncluded  = review.serviceType
    ? (review.serviceType === 'chat' || review.serviceType === 'verification_chat')
    : true;

  function _finishAccept() {
    savePlanReviewStatus(reviewId, 'in_progress', { acceptedAt: _now, expertId: expert.id, chatId: convId });
    console.log('[REVIEW] accepted + paid', reviewId, '→ in_progress');
    try { sessionStorage.setItem('zitlas_modify_expert', JSON.stringify(expert)); } catch (_) {}
    if (isChatOnly) {
      edShowToast('✅ Payment received — chat unlocked.');
      renderInbox(expert);
      return;
    }
    window.location.href = rtype === 'workout'
      ? 'modify-workout.html?reviewId=' + encodeURIComponent(reviewId)
      : 'modify-diet.html?reviewId='    + encodeURIComponent(reviewId);
  }

  /* CLIENT_TRIAL_MODE / PLATFORM_CHARGES_FREE (backend/trial_config.py,
     mirrored here via ZitlasPayment.isTrialMode() — see payment-service.js's
     own doc comment: it's the effectiveFree flag, already ORs both).
     While either is on, every expert service is free platform-wide, so this
     acceptance can NEVER require a real charge — going through
     attemptCharge() -> POST /api/payment/charge anyway means the request
     only advances if the backend's Firestore Admin client is configured
     (FIREBASE_SERVICE_ACCOUNT_JSON/FILE), which has nothing to do with
     whether money moves. Write the SAME advance fields attemptCharge's
     onSuccessUpdate would have, directly from the client instead —
     firestore.rules already lets the assigned expert update review_requests
     (just never paymentStatus/walletTransactionId — see firestore.rules:
     170-173), so this is a real, rules-checked write, not a bypass of one.
     Nothing here ever sets paymentStatus/walletTransactionId (the rule
     forbids it, and this genuinely isn't a payment) — no faked charge, no
     fake wallet_transactions record. Paid mode (trial off) is completely
     unaffected below: it still calls attemptCharge() exactly as before. */
  if (typeof ZitlasPayment !== 'undefined' && ZitlasPayment.isTrialMode()) {
    if (typeof ZitlasDB !== 'undefined') {
      ZitlasDB.collection('review_requests').doc(reviewId)
        .update({ status: 'in_progress', acceptedAt: _now, expertId: expert.id, chatId: convId, chatUnlocked: chatIncluded })
        .catch(function(e) { console.warn('[REVIEW] trial-mode in_progress Firestore write failed:', e); });

      /* "Both" bundle: mirror the linked sibling doc to the same accepted
         outcome — same no-extra-check pattern _prRejectReview already uses
         for this exact sibling link a few lines below (both halves target
         the same expert by construction; nothing paid on either side). */
      if (review.siblingId) {
        ZitlasDB.collection('review_requests').doc(review.siblingId)
          .update({ status: 'in_progress', acceptedAt: _now, expertId: expert.id, chatId: convId, chatUnlocked: chatIncluded })
          .catch(function(e) { console.warn('[REVIEW] trial-mode sibling mirror failed:', e); });
      }
    }
    console.log('[REVIEW] accepted free (trial/platform-free mode) — no payment call', reviewId);
    _finishAccept();
    return;
  }

  if (typeof ZitlasPayment === 'undefined' || typeof ZitlasDB === 'undefined') {
    /* Payment engine unavailable (e.g. dev environment without the script) —
       fall back to the original no-payment behavior rather than blocking
       the whole review flow. */
    if (typeof ZitlasDB !== 'undefined') {
      ZitlasDB.collection('review_requests').doc(reviewId)
        .update({ status: 'in_progress', acceptedAt: _now, expertId: expert.id })
        .catch(function(e) { console.warn('[REVIEW] in_progress Firestore write failed:', e); });
    }
    _finishAccept();
    return;
  }

  edShowToast('Checking athlete wallet…');
  var serviceLabel = isChatOnly ? 'Expert Chat' : (rtype === 'workout' ? 'Workout Review' : 'Diet Review');

  /* The expert's decision (status: 'accepted') is written INSIDE
     attemptCharge's own transaction — both the insufficient-balance branch
     and the success branch (via onSuccessUpdate below) set it, so there is
     no separate out-of-transaction write that could race against the
     transaction's own write and land out of order. */
  ZitlasPayment.attemptCharge({
    userId: review.userId, expertId: expert.id, amount: amount,
    serviceType: isChatOnly ? 'chat' : 'review', serviceLabel: serviceLabel, expertName: expert.name,
    requestCollection: 'review_requests', requestId: reviewId,
    /* "Both" bundle sibling mirrored SERVER-SIDE by /api/payment/charge
       (no client paymentStatus:'paid' write). */
    siblingRequestId: review.siblingId || null,
    onSuccessUpdate: { status: 'in_progress', acceptedAt: _now, expertId: expert.id, chatId: convId, chatUnlocked: chatIncluded },
    notifyUser: {
      title: 'Expert accepted your request',
      message: (expert.name || 'Your expert') + ' accepted your request. ₹' + amount +
        ' has been deducted from your wallet. Your ' + serviceLabel.toLowerCase() + ' has started.',
    },
    notifyExpert: {
      title: 'Payment received',
      message: 'Payment received for ' + (review.athleteName || review.userName || 'an athlete') + "'s " +
        serviceLabel.toLowerCase() + '. You may now begin.',
    },
  }).then(function (result) {
    if (result.success) {
      /* "Both" bundle sibling is mirrored to the paid/in_progress outcome
         SERVER-SIDE by /api/payment/charge (charged once on the primary doc);
         no client paymentStatus:'paid' write remains. */
      _finishAccept();
      return;
    }
    if (result.error === 'insufficient_balance') {
      edShowToast('⏳ Awaiting athlete payment — ₹' + result.shortfall + ' short. They have been notified.');
      if (typeof ZitlasNotify !== 'undefined') {
        ZitlasNotify.send(review.userId, {
          title: 'Insufficient wallet balance', category: 'payment', type: 'awaiting_payment',
          message: 'You need ₹' + result.shortfall + ' more to start your ' + serviceLabel.toLowerCase() +
            ' with ' + (expert.name || 'your expert') + '. Recharge your wallet to continue — the expert has already accepted.',
          action: 'expert_profile', actionId: expert.id, priority: 'high',
        });
      }
      renderInbox(expert);
      return;
    }
    console.error('[REVIEW] accept payment failed', result);
    edShowToast('Could not process payment — please try again.');
  });
}

function _prRejectReview(reviewId, review, expert) {
  savePlanReviewStatus(reviewId, 'rejected');

  if (typeof ZitlasDB !== 'undefined') {
    ZitlasDB.collection('review_requests').doc(reviewId)
      .update({ status: 'rejected', rejectedAt: new Date().toISOString() })
      .catch(function(e) { console.warn('[REVIEW] rejected Firestore write failed:', e); });

    /* "Both" bundle: rejecting the primary also rejects the linked workout
       doc — no payment was ever taken for either half, so there's nothing
       to refund, just a status to keep in sync. */
    if (review.siblingId) {
      ZitlasDB.collection('review_requests').doc(review.siblingId)
        .update({ status: 'rejected', rejectedAt: new Date().toISOString() })
        .catch(function(e) { console.warn('[REVIEW] sibling reject mirror failed:', e); });
    }
  }

  console.log('[REVIEW] rejected', reviewId);
  edShowToast('Review rejected.');
  renderInbox(expert);
}

function _prOpenReviewChat(review, expert) {
  var convId      = review.chatId || expert.id;
  var athleteName = review.athleteName || review.userName || 'Athlete';
  _edCurrentReview = review;
  openExpertChat(convId, athleteName);
}

/* ── Review Tools (Modify Plan + Complete Review) ── */

function initReviewTools(expert) {
  /* Modify Plan button */
  var modifyBtn = document.getElementById('edRtModify');
  if (modifyBtn) {
    modifyBtn.addEventListener('click', function() {
      if (!_edCurrentReview) return;
      _prOpenEditSheet(_edCurrentReview, expert);
    });
  }

  /* Complete Review button → show confirmation */
  var completeBtn = document.getElementById('edRtComplete');
  var backdrop    = document.getElementById('edCompleteReviewBackdrop');
  var cancelBtn   = document.getElementById('edCompleteReviewCancel');
  var confirmBtn  = document.getElementById('edCompleteReviewConfirm');

  if (completeBtn && backdrop) {
    completeBtn.addEventListener('click', function() {
      if (!_edCurrentReview) return;
      backdrop.style.display = 'flex';
    });
  }
  if (cancelBtn && backdrop) {
    cancelBtn.addEventListener('click', function() { backdrop.style.display = 'none'; });
  }
  if (backdrop) {
    backdrop.addEventListener('click', function(e) {
      if (e.target === backdrop) backdrop.style.display = 'none';
    });
  }
  if (confirmBtn && backdrop) {
    confirmBtn.addEventListener('click', function() {
      backdrop.style.display = 'none';
      if (!_edCurrentReview) return;
      console.log('[COMPLETE REVIEW] button clicked');
      _prCompleteReviewFromChat(_edCurrentReview, expert);
    });
  }
}

function _prCompleteReviewFromChat(review, expert) {
  /* Re-read the review fresh — it may have been updated by the edit sheet */
  var all = [];
  try { all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]'); } catch (_) {}
  var fresh = all.find(function(r) { return r.id === review.id; }) || review;
  var idx   = all.findIndex(function(r) { return r.id === review.id; });
  if (idx === -1) return;

  var rtype = fresh.reviewType || fresh.planReviewType || '';
  if (rtype === 'workout') {
    /* Build workout change history from the edit card if one exists */
    if (_prEditCard && _prEditCard._editedWorkoutPlan) {
      var _origForDiff = fresh.planData || null;
      if (_origForDiff && (_origForDiff.originalWorkoutPlan || _origForDiff.currentWorkoutPlan)) {
        _origForDiff = _origForDiff.originalWorkoutPlan || _origForDiff.currentWorkoutPlan;
      }
      var wHistory = buildWorkoutChangeHistory(_origForDiff, _prEditCard._editedWorkoutPlan, expert.name);
      all[idx].reviewedWorkoutPlan  = _prEditCard._editedWorkoutPlan;
      all[idx].workoutChangeHistory = wHistory;
      all[idx].athleteAccepted      = false;
    }
  } else {
    if (_prEditCard && (_prEditCard._editedDietPlan || _prEditCard._hasEdits)) {
      savePlanEdits(review.id, _prEditCard, expert);
      /* savePlanEdits already writes to localStorage, re-read */
      try { all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]'); idx = all.findIndex(function(r) { return r.id === review.id; }); } catch (_) {}
    }
  }

  var _rcTs = new Date().toISOString();
  all[idx].status      = 'review_completed';
  all[idx].reviewedAt  = _rcTs;
  all[idx].completedAt = _rcTs;
  all[idx].expertName  = expert.name;
  all[idx].expertId    = expert.id;
  try { localStorage.setItem('expert_plan_reviews', JSON.stringify(all)); } catch (_) {}

  /* Firestore write — ensures athlete's onSnapshot listener fires */
  if (typeof ZitlasDB !== 'undefined') {
    var _fsRev = all[idx];
    var _fsPayload = {
      status:      'review_completed',
      reviewedAt:  _rcTs,
      completedAt: _rcTs,
      expertName:  expert.name,
      expertId:    expert.id,
    };
    if (rtype === 'workout') {
      _fsPayload.reviewedWorkoutPlan  = _fsRev.reviewedWorkoutPlan  || null;
      _fsPayload.workoutChangeHistory = _fsRev.workoutChangeHistory || [];
    } else {
      _fsPayload.reviewedDietPlan  = _fsRev.reviewedDietPlan  || null;
      _fsPayload.mealChangeHistory = _fsRev.mealChangeHistory || [];
    }
    console.log('[COMPLETE REVIEW] reviewId', fresh.id);
    console.log('[COMPLETE REVIEW] payload', _fsPayload);
    console.log('[COMPLETE REVIEW] before firestore update');
    ZitlasDB.collection('review_requests').doc(fresh.id).update(_fsPayload)
      .then(function() { console.log('[COMPLETE REVIEW] firestore update success'); })
      .catch(function(err) { console.error('[COMPLETE REVIEW] firestore update failed', err); });
  }

  /* Send completion message in chat */
  var convId    = fresh.chatId || expert.id;
  var rTypeLabel = rtype === 'workout' ? 'workout' : 'diet';
  chatAppendMessage(convId, {
    id:         'sys_complete_' + Date.now(),
    senderType: 'system',
    type:       'review_complete',
    text:       '✅ Review Completed — ' + expert.name + ' has finished reviewing your ' + rTypeLabel + ' plan. Open your plan to accept the changes.',
    timestamp:  new Date().toISOString(),
  });

  /* Hide review tools */
  var tools = document.getElementById('edReviewTools');
  if (tools) tools.style.display = 'none';
  _edCurrentReview = null;
  _prEditCard      = null;

  edShowToast('✅ Review sent to athlete.');
  renderInbox(expert);
}

/* ── Plan Edit Sheet (Modify Plan from chat) ── */

var _prEditCard = null; /* holds _editedWorkoutPlan / _editedDietPlan after expert edits */

function _prOpenEditSheet(review, expert) {
  var overlay = document.getElementById('prEditOverlay');
  var body    = document.getElementById('prEditBody');
  var titleEl = document.getElementById('prEditTitle');
  var backBtn = document.getElementById('prEditBack');
  if (!overlay || !body) return;

  var rtype = review.reviewType || review.planReviewType || 'diet';
  if (titleEl) titleEl.textContent = rtype === 'workout' ? 'Modify Workout Plan' : 'Modify Diet Plan';

  /* Build editable plan into a synthetic card object */
  _prEditCard = {};
  body.innerHTML = '';

  var planEl;
  if (rtype === 'workout') {
    planEl = buildEditableWorkoutPlanEl(review, _prEditCard);
  } else {
    planEl = buildEditableDietPlanEl(review, _prEditCard);
  }
  if (planEl) body.appendChild(planEl);

  overlay.style.display = 'flex';

  /* Back button */
  if (backBtn) {
    backBtn.onclick = function() { overlay.style.display = 'none'; };
  }

  /* Wire the bottom Save Changes button (built by plan builder) to close the overlay */
  if (_prEditCard._saveChangesBtn) {
    var _origClick = _prEditCard._saveChangesBtn.onclick;
    _prEditCard._saveChangesBtn.onclick = function(e) {
      if (_origClick) _origClick.call(this, e);
      overlay.style.display = 'none';
      edShowToast('Changes saved. Click "Complete Review" to send to athlete.');
    };
  }
}

/* ── Utility: relative time ── */

function _prTimeAgo(iso) {
  var d = new Date(iso);
  if (isNaN(d)) return '';
  var diff = (Date.now() - d.getTime()) / 1000;
  if (diff < 60)    return 'just now';
  if (diff < 3600)  return Math.floor(diff / 60) + ' min ago';
  if (diff < 86400) return Math.floor(diff / 3600) + ' hr ago';
  return Math.floor(diff / 86400) + ' days ago';
}

/* Legacy alias — kept so any lingering references don't crash */
function renderPlanReviews(expert) { renderInbox(expert); }

/* ══════════════════════════════════════════════
   RENDER ALL — shared between Firebase and legacy paths
   ══════════════════════════════════════════════ */

function renderAll(baseExpert) {
  /* Apply any saved profile overrides on top of the Firebase/EXPERT_DB base */
  _baseExpert    = baseExpert;
  const expert   = loadProfile(baseExpert);
  _currentExpert = expert;

  renderHeader(expert);
  renderDashboard(expert);
  renderProfile(expert);
  initNavigation();
  initLogout();
  initEditProfile();
  initCertificateUpload(expert);
  listenForMyCertificates(expert);
  if (typeof ZitlasNotify !== 'undefined' && !renderAll._bellWired) {
    renderAll._bellWired = true;
    ZitlasNotify.wireBell('edNotifBtn', 'edNotifDot', '../notifications/notifications.html');
  }
  initDeleteAccount();
  initExpertChatOverlay();
  initReviewTools(expert);
  _initInboxTabs(expert);
  renderInbox(expert);
  /* Live reviews + chats + stats (Firestore or localStorage fallback) */
  listenForReviews(expert);
  /* Discover chat conversations from Firestore (cross-device inbox + calls) */
  listenForChatRooms(expert);
  /* Personal coaching clients (realtime) */
  listenForMyAthletes(expert);
  /* Personal coaching requests inbox (realtime) */
  listenForCoachingRequests(expert);
  _initCoachingTabs(expert);
  /* Coaching notifications (athlete asked for meal alternatives, etc.) */
  if (typeof ZitlasCoachingWorkspace !== 'undefined') {
    var _cwUid = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
      ? ZitlasAuth.currentUser.uid : (expert && expert.id);
    if (_cwUid) ZitlasCoachingWorkspace.attachNotifications(_cwUid, edShowToast);
  }
  /* Auto-open chat when returning from a modify page after completing review */
  _prCheckPendingChatOpen(expert);
  /* Refresh-safe workspace restore — reopens the same athlete + tab a
     browser reload would otherwise have thrown the expert out of. */
  _restorePendingWorkspace(expert);

  /* Listen for cross-tab profile updates (another page called ZitlasExpertProfile.save) */
  if (!renderAll._profileListenerAdded) {
    renderAll._profileListenerAdded = true;
    window.addEventListener('expertProfileUpdated', function () {
      if (!_baseExpert) return;
      const refreshed  = loadProfile(_baseExpert);
      _currentExpert   = refreshed;
      renderHeader(refreshed);
      renderDashboard(refreshed);
      renderProfile(refreshed);
    });
  }
}

/* Reopens the Coaching Workspace on reload, restoring the same athlete +
   tab the expert was looking at. The URL (?cwAthlete=&cwTab=) is only an
   identity HINT written by openCoachWorkspace's onTabChange/onClose — it is
   never trusted for authorization. A fresh one-shot Firestore read
   re-validates ownership and current status at the moment of restore
   (Firestore stays the source of truth; the URL is UX-only), so a
   stale/tampered URL (doc gone, or coachId mismatch) just fails closed and
   is cleared silently instead of granting access to anything. Runs at most
   once per page load — later renderAll() calls (auth-state churn, fallback
   paths) must not reopen a workspace the expert already closed. */
function _restorePendingWorkspace(expert) {
  if (_restorePendingWorkspace._done) return;
  var url;
  try { url = new URL(window.location.href); } catch (_) { return; }
  var athleteId = url.searchParams.get('cwAthlete');
  if (!athleteId) return;
  _restorePendingWorkspace._done = true;

  var tab = url.searchParams.get('cwTab') || 'overview';
  var uid = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
    ? ZitlasAuth.currentUser.uid : (expert && expert.id);
  if (!uid || typeof ZitlasDB === 'undefined' || typeof ZitlasCoachingWorkspace === 'undefined') {
    _cwClearUrlParams();
    return;
  }

  ZitlasDB.collection('personal_coaching').doc(athleteId).get().then(function (snap) {
    if (!snap.exists) { _cwClearUrlParams(); return; }
    var rel = snap.data();
    var isActive = typeof ZitlasCoachingGate !== 'undefined'
      ? ZitlasCoachingGate.evaluate(rel).active
      : rel.status === 'active';
    /* Fail closed on ownership OR lifecycle mismatch — mirrors
       cprofile.js's _coachingWorkspaceFor() gate on the athlete side, so a
       relationship that expired between the original open() and this
       reload does not get a restore pathway the live "My Athletes" list
       (which is itself lifecycle-filtered) never offered in the first
       place. */
    if (rel.coachId !== uid || !isActive) { _cwClearUrlParams(); return; }
    openCoachWorkspace(rel, tab);
  }).catch(function (e) {
    console.warn('[CW] restore-on-refresh lookup failed', e);
    _cwClearUrlParams();
  });
}

function _prCheckPendingChatOpen(expert) {
  var pending = null;
  try { pending = JSON.parse(sessionStorage.getItem('ed_open_chat') || 'null'); } catch (_) {}
  if (!pending) return;
  try { sessionStorage.removeItem('ed_open_chat'); } catch (_) {}
  /* Switch to Chats section and open the conversation */
  setTimeout(function() {
    var chatsNav = document.querySelector('[data-section="chats"]');
    if (chatsNav) chatsNav.click();
    if (pending.convId) {
      setTimeout(function() { openExpertChat(pending.convId, pending.athleteName || 'Athlete'); }, 120);
    }
  }, 200);
}

function _initInboxTabs(expert) {
  var tabs = document.querySelectorAll('.pr-inbox-tab[data-inbox-tab]');
  tabs.forEach(function(tab) {
    tab.addEventListener('click', function() {
      _prInboxActiveTab = tab.dataset.inboxTab;
      tabs.forEach(function(t) { t.classList.remove('pr-inbox-tab--active'); });
      tab.classList.add('pr-inbox-tab--active');
      renderInbox(expert);
    });
  });
}

/* ══════════════════════════════════════════════
   INIT — Firebase auth guard with localStorage fallback
   ══════════════════════════════════════════════ */

(function init() {

  /* ── Firebase path ── */
  if (typeof ZitlasAuth !== 'undefined' && typeof ZitlasDB !== 'undefined') {

    ZitlasAuth.onAuthStateChanged(async function (firebaseUser) {

      if (!firebaseUser) {
        /* No Firebase session — check localStorage fallback (email/pw demo login) */
        const token = localStorage.getItem('zitlas_token');
        const role  = localStorage.getItem('zitlas_user_role');
        if (token && role === 'expert') {
          renderAll(getExpert());
        } else {
          window.location.href = '../login/login.html';
        }
        return;
      }

      /* Firebase user exists — verify role in Firestore */
      try {
        const uid = firebaseUser.uid;
        console.log('[AUTH UID]', uid);

        const doc = await ZitlasDB.collection('users').doc(uid).get();

        if (!doc.exists) {
          /* Auth user but no Firestore doc (e.g. deleted) */
          window.location.href = '../login/login.html';
          return;
        }

        const data = doc.data();
        console.log('[USER DOC]', data);

        const _roles       = Array.isArray(data.roles) ? data.roles : [];
        const _expertStatus = data.expert_status || '';
        const _legacyRole   = data.role || '';
        const isExpert =
          _roles.includes('expert')         ||
          _roles.includes('expert_pending') ||
          _expertStatus === 'approved'      ||
          _expertStatus === 'pending'       ||
          _legacyRole   === 'expert';
        console.log('[AUTH STATE] Firebase UID:', uid, ' Detected role:', isExpert ? 'expert' : 'athlete');
        if (!isExpert) {
          /* Athlete tried to access expert dashboard — same symmetric guard
             as dashboard.js's own check for an expert landing there. */
          console.log('[AUTH STATE] Redirect destination: ../dashboard/dashboard.html');
          window.location.href = '../dashboard/dashboard.html';
          return;
        }
        // Authoritative coach identity — compare this exact UID against a
        // meal record's coachId/expertId when tracing a "meal not visible"
        // report; never assume a display name is enough to confirm a match.
        console.log('[COACH AUTH] firebaseUid=' + uid + ' email=' + (firebaseUser.email || '') +
          ' expertId=' + uid + ' role=expert');

        /* ── IDENTITY: experts/{uid} is the single source of truth.
           users/{uid} is only consulted for the role check above. ── */
        let expertData = null;
        try {
          const eDoc = await ZitlasDB.collection('experts').doc(uid).get();
          expertData = eDoc.exists ? eDoc.data() : null;
        } catch (eFetchErr) {
          console.warn('[ZITLAS] experts/{uid} fetch failed:', eFetchErr);
        }
        console.log('[EXPERT DOC]', expertData);

        /* Heal accounts that predate the experts collection */
        if (!expertData) {
          expertData = {
            uid:      uid,
            email:    firebaseUser.email || data.email || '',
            name:     data.name || firebaseUser.displayName || 'Expert',
            role:     'expert',
            speciality: '',
            photo:    data.photo || firebaseUser.photoURL || '',
            /* verified/approved intentionally omitted — backend-only trust
               fields (Security Rules deny client writes to them). Absent reads
               as unverified/unapproved, the correct default. */
            rating: 0, reviews: 0,
            createdAt: firebase.firestore.FieldValue.serverTimestamp(),
          };
          try { await ZitlasDB.collection('experts').doc(uid).set(expertData, { merge: true }); } catch (_) {}
        }

        /* Overwrite localStorage caches with fresh Firestore truth;
           clears any stale cache left behind by a different uid */
        syncExpertIdentityCaches(uid, expertData);

        /* Sync localStorage for rest-of-app compatibility.
           Name comes from experts/{uid} — never displayName/users doc. */
        localStorage.setItem('zitlas_token',     'firebase_' + uid);
        localStorage.setItem('zitlas_user_role', 'expert');
        localStorage.setItem('zitlas_firebase_user', JSON.stringify({
          uid:   uid,
          name:  expertData.name || firebaseUser.displayName || data.name,
          email: firebaseUser.email,
          photo: expertData.profilePhoto || expertData.photo || firebaseUser.photoURL || null,
          role:  'expert',
        }));

        /* Build expert profile from Firebase user, then let experts/{uid} win */
        const expert = buildExpertFromFirebase(firebaseUser, data);
        if (expertData.name) {
          expert.name      = expertData.name;
          expert.firstName = expertData.name.split(/\s+/)[0] || expert.firstName;
          expert.initials  = expertData.name.split(/\s+/).map(function (p) { return p[0] || ''; }).slice(0, 2).join('').toUpperCase() || expert.initials;
        }
        if (expertData.profilePhoto || expertData.photo) expert.photo = expertData.profilePhoto || expertData.photo;

        renderAll(expert);

      } catch (e) {
        console.error('[ZITLAS] Expert Firestore auth error:', e);
        /* Degrade gracefully — use localStorage data if available */
        const token = localStorage.getItem('zitlas_token');
        const role  = localStorage.getItem('zitlas_user_role');
        if (token && role === 'expert') {
          renderAll(getExpert());
        } else {
          window.location.href = '../login/login.html';
        }
      }
    });

    return; /* Firebase is handling init — don't fall through to legacy */
  }

  /* ── Legacy path (no Firebase configured) ── */
  const token = localStorage.getItem('zitlas_token');
  const role  = localStorage.getItem('zitlas_user_role');
  if (!token || role !== 'expert') {
    window.location.href = '../login/login.html';
    return;
  }
  renderAll(getExpert());

}());
