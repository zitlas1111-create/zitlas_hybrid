/* =============================================
   ZITLAS Nutritionist Profile — cprofile.js
   ============================================= */

(function () {
  'use strict';

  /* Expert profiles are loaded from Firestore — no hardcoded database */



  /* ══════════════════════════════════════════
     THEME
  ══════════════════════════════════════════ */
  const THEME_KEY = 'zitlas_theme';
  const html = document.documentElement;

  function getSystemTheme() {
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  function applyTheme(pref) {
    const resolved = pref === 'system' ? getSystemTheme() : pref;
    html.setAttribute('data-theme', resolved);
  }

  function loadTheme() {
    applyTheme(localStorage.getItem(THEME_KEY) || 'dark');
  }

  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if ((localStorage.getItem(THEME_KEY) || 'dark') === 'system') applyTheme('system');
  });

  /* ══════════════════════════════════════════
     TOAST
  ══════════════════════════════════════════ */
  let toastTimer = null;

  function showToast(msg, duration = 2800) {
    const el = document.getElementById('toast');
    if (!el) return;
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), duration);
  }

  /* ══════════════════════════════════════════
     GET COACH ID FROM URL
  ══════════════════════════════════════════ */
  function getCoachId() {
    const params = new URLSearchParams(window.location.search);
    return (params.get('id') || 'rahul').toLowerCase().trim();
  }

  /* ══════════════════════════════════════════
     RENDER HELPER — safe set text/attr
  ══════════════════════════════════════════ */
  function setText(id, text) {
    const el = document.getElementById(id);
    if (el) el.textContent = text;
  }

  function setAttr(id, attr, val) {
    const el = document.getElementById(id);
    if (el) el.setAttribute(attr, val);
  }

  /* ══════════════════════════════════════════
     HEX → RGBA
  ══════════════════════════════════════════ */
  function hexToRgba(hex, alpha) {
    var r = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
    return r
      ? 'rgba(' + parseInt(r[1],16) + ',' + parseInt(r[2],16) + ',' + parseInt(r[3],16) + ',' + alpha + ')'
      : 'rgba(var(--primary-rgb),' + alpha + ')';
  }

  /* ══════════════════════════════════════════
     FALLBACK SVG for broken images
  ══════════════════════════════════════════ */
  function makeFallbackSVG(initials, color, size) {
    return `data:image/svg+xml,${encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
        <rect width="${size}" height="${size}" fill="${color}"/>
        <text x="50%" y="52%" dominant-baseline="central" text-anchor="middle"
              font-size="${Math.round(size * 0.35)}" font-weight="800" fill="white"
              font-family="-apple-system,sans-serif">${initials}</text>
      </svg>`
    )}`;
  }

  /* ══════════════════════════════════════════
     VERIFIED CERTIFICATES (Expert Verification System)
     Only certificates with verificationStatus === 'verified' are ever
     shown to athletes — pending/rejected certs stay expert/admin-only.
  ══════════════════════════════════════════ */
  var _bestVerifiedCert = null; /* highest-score verified cert, backs the badge's tap-to-view modal */

  function initVerifiedCertificates(coach) {
    if (typeof ZitlasCertificates === 'undefined' || typeof ZitlasDB === 'undefined') return;
    ZitlasDB.collection('expert_certificates')
      .where('expertId', '==', coach.id)
      .where('verificationStatus', '==', 'verified')
      .onSnapshot(function(snap) {
        var certs = snap.docs.map(function(d) { return d.data(); })
          .sort(function(a, b) { return (b.verificationScore || 0) - (a.verificationScore || 0); });
        _bestVerifiedCert = certs[0] || null;
        renderVerifiedCertificates(certs);
      }, function(err) { console.warn('[CERT] verified-certs listener error', err); });
  }

  function renderVerifiedCertificates(certs) {
    var section = document.getElementById('verifiedCertsSection');
    var list    = document.getElementById('verifiedCertsList');
    if (!section || !list) return;
    if (!certs.length) { section.style.display = 'none'; return; }
    section.style.display = '';

    list.innerHTML = certs.map(function(cert) {
      return '<div class="cert-card">' +
        '<div class="cert-card-top">' +
          '<div class="cert-card-icon">🎓</div>' +
          '<div style="flex:1">' +
            '<div class="cert-card-title">✓ ' + esc(cert.certificateName || 'Certificate') + '</div>' +
            '<div class="cert-card-org">Issued by: ' + esc(cert.issuingOrganization || '—') + '</div>' +
          '</div>' +
          '<span class="cert-status-pill cert-status-pill--verified">✓ Verified</span>' +
        '</div>' +
        '<div class="cert-kv-row"><span>Certificate ID</span><b>' + esc(cert.certificateNumber || '—') + '</b></div>' +
        '<div class="cert-kv-row"><span>Issued</span><b>' + esc(cert.issuedDate || '—') + '</b></div>' +
        '<div class="cert-kv-row"><span>Expires</span><b>' + esc(cert.expiryDate || '—') + '</b></div>' +
        '<div class="cert-kv-row"><span>Verification Score</span><b>' + esc(String(cert.verificationScore)) + '%</b></div>' +
        '<div class="cert-card-actions"><button class="cert-view-btn" data-cert-id="' + esc(cert.certId) + '">View Certificate</button></div>' +
      '</div>';
    }).join('');

    list.querySelectorAll('[data-cert-id]').forEach(function(btn) {
      btn.addEventListener('click', function() {
        var cert = certs.find(function(c) { return c.certId === btn.dataset.certId; });
        if (cert) ZitlasCertificates.openViewCertificate(cert);
      });
    });
  }

  /* ══════════════════════════════════════════
     SECTION RENDERERS
  ══════════════════════════════════════════ */
  function renderMetrics(coach) {
    var grid = document.getElementById('statsGrid');
    if (!grid) return;
    var icons = ['🏆', '👥', '✅', '⏳'];
    grid.innerHTML = coach.stats.map(function(s, i) {
      return '<div class="cp-metric-card">' +
        '<span class="cp-metric-val">' + esc(s.value) + '</span>' +
        '<span class="cp-metric-lbl">' + esc(s.label) + '</span>' +
        '<span class="cp-metric-icon">' + (icons[i] || '★') + '</span>' +
      '</div>';
    }).join('');
  }

  function renderExpertise(coach) {
    var wrap = document.getElementById('expertiseGrid');
    if (!wrap) return;
    wrap.innerHTML = coach.expertise.map(function(e) {
      return '<span class="cp-tag"><span class="cp-tag-icon">' + e.icon + '</span>' + esc(e.label) + '</span>';
    }).join('');
  }

  function renderReviews(coach) {
    var list = document.getElementById('reviewsList');
    if (!list) return;
    (coach.reviews || []).slice(0, 3).forEach(function(r) {
      var stars = '★'.repeat(Math.round(r.rating)) + '☆'.repeat(5 - Math.round(r.rating));
      var card = document.createElement('div');
      card.className = 'cp-review-card';
      card.innerHTML =
        '<div class="cp-review-header">' +
          '<div class="cp-review-avatar" style="background:' + r.color + '">' + esc(r.initials) + '</div>' +
          '<div class="cp-review-meta">' +
            '<span class="cp-review-name">' + esc(r.name) + '</span>' +
            '<div class="cp-review-info-row">' +
              '<span class="cp-review-stars">' + stars + '</span>' +
              '<span class="cp-review-date">' + esc(r.date || '2 weeks ago') + '</span>' +
            '</div>' +
          '</div>' +
        '</div>' +
        '<p class="cp-review-text">' + esc(r.text) + '</p>';
      list.appendChild(card);
    });
  }

  function renderRatingBars(coach) {
    var el = document.getElementById('ratingBars');
    if (!el) return;
    var total = coach.reviewCount || 1;
    var dist = coach.ratingDist || [
      Math.round(total * 0.72),
      Math.round(total * 0.18),
      Math.round(total * 0.06),
      Math.round(total * 0.03),
      Math.round(total * 0.01),
    ];
    var labels = ['5 ★', '4 ★', '3 ★', '2 ★', '1 ★'];
    el.innerHTML = dist.map(function(count, i) {
      var pct = Math.round((count / total) * 100);
      return '<div class="cp-rbar-row">' +
        '<span class="cp-rbar-label">' + labels[i] + '</span>' +
        '<div class="cp-rbar-track"><div class="cp-rbar-fill" style="width:' + pct + '%"></div></div>' +
        '<span class="cp-rbar-count">' + count + '</span>' +
      '</div>';
    }).join('');
  }

  function renderGallery(coach) {
    var el = document.getElementById('galleryScroll');
    if (!el) return;
    var gallery = coach.gallery || [
      { before: '89 kg', after: '72 kg', duration: '3 months', note: 'Sustainable fat loss with Indian meal plan' },
      { before: '78 kg', after: '65 kg', duration: '2.5 months', note: 'No gym — home workouts only' },
      { before: '95 kg', after: '81 kg', duration: '4 months', note: 'Hostel-friendly diet + consistency' },
      { before: '67 kg', after: '58 kg', duration: '2 months', note: 'Office worker, minimal time investment' },
    ];
    el.innerHTML = gallery.map(function(card) {
      return '<div class="cp-gallery-card">' +
        '<div class="cp-gallery-ba">' +
          '<div class="cp-gallery-stat"><span class="cp-gallery-stat-lbl">Before</span><span class="cp-gallery-stat-val before">' + esc(card.before) + '</span></div>' +
          '<span class="cp-gallery-arrow">→</span>' +
          '<div class="cp-gallery-stat"><span class="cp-gallery-stat-lbl">After</span><span class="cp-gallery-stat-val after">' + esc(card.after) + '</span></div>' +
        '</div>' +
        '<span class="cp-gallery-duration">' + esc(card.duration) + '</span>' +
        '<p class="cp-gallery-note">' + esc(card.note) + '</p>' +
      '</div>';
    }).join('');
  }

  function renderServices(coach) {
    var el = document.getElementById('servicesList');
    if (!el) return;
    var chatRate = coach.chatRate || coach.fee;
    var callRate = coach.callRate || (coach.fee + 30);
    var services = [
      { icon: '💬', name: 'Chat Consultation', desc: 'Text-based, async — ideal for quick questions and plan updates', price: '₹' + chatRate, unit: '/min' },
      { icon: '📞', name: 'Voice Call', desc: 'Real-time audio for detailed plan discussions and motivation', price: '₹' + callRate, unit: '/min' },
      { icon: '🎥', name: 'Video Consultation', desc: 'Face-to-face video for form correction and in-depth review', price: '₹' + (callRate + 20), unit: '/min' },
    ];
    el.innerHTML = services.map(function(s) {
      return '<div class="cp-service-card">' +
        '<div class="cp-service-icon-wrap">' + s.icon + '</div>' +
        '<div class="cp-service-info">' +
          '<span class="cp-service-name">' + esc(s.name) + '</span>' +
          '<span class="cp-service-desc">' + esc(s.desc) + '</span>' +
        '</div>' +
        '<div class="cp-service-right">' +
          '<span class="cp-service-price">' + esc(s.price) + '</span>' +
          '<span class="cp-service-unit">' + esc(s.unit) + '</span>' +
          '<button class="cp-service-btn serviceBookBtn">Book</button>' +
        '</div>' +
      '</div>';
    }).join('');
    el.querySelectorAll('.serviceBookBtn').forEach(function(btn) {
      btn.addEventListener('click', function() {
        var chatBtn = document.getElementById('inlineChatBtn');
        if (chatBtn) chatBtn.click();
      });
    });
  }

  function renderAvailability(coach) {
    var el = document.getElementById('cpAvailSection');
    if (!el) return;
    var avail = coach.availability || { isAvailableToday: true, slots: ['9:00 AM', '11:00 AM', '2:00 PM', '4:30 PM', '7:00 PM'] };
    var isOnline = avail.isAvailableToday !== false;
    var slots = avail.slots || [];
    el.innerHTML =
      '<div class="cp-avail-header">' +
        '<div class="cp-avail-status' + (isOnline ? '' : ' busy') + '">' +
          '<span class="cp-avail-status-dot"></span>' +
          (isOnline ? 'Online Now' : 'Away') +
        '</div>' +
      '</div>' +
      '<div class="cp-slots-grid">' +
        slots.map(function(slot) {
          return '<button class="cp-slot available">' + esc(slot) + '</button>';
        }).join('') +
      '</div>';
    el.querySelectorAll('.cp-slot').forEach(function(btn) {
      btn.addEventListener('click', function() {
        var chatBtn = document.getElementById('inlineChatBtn');
        if (chatBtn) chatBtn.click();
      });
    });
  }

  /* ══════════════════════════════════════════
     POPULATE PAGE
  ══════════════════════════════════════════ */
  function populatePage(coach) {
    document.title = 'ZITLAS — ' + coach.name;

    /* Hero image */
    var heroImg      = document.getElementById('coachImg');
    var heroInitials = document.getElementById('cpHeroInitials');
    if (heroImg) {
      heroImg.src = coach.image;
      heroImg.alt = coach.name;
      heroImg.addEventListener('error', function() {
        heroImg.style.display = 'none';
        if (heroInitials) heroInitials.classList.add('show');
      });
    }
    if (heroInitials) {
      heroInitials.textContent = coach.initials ||
        (coach.name || 'E').split(' ').map(function(w) { return w[0] || ''; }).join('').slice(0, 2).toUpperCase();
    }

    /* Hero gradient & ring tint */
    var heroGrad = document.getElementById('cpHeroGradient');
    if (heroGrad) {
      heroGrad.style.background =
        'radial-gradient(ellipse at 50% 0%, ' + hexToRgba(coach.colorAccent || 'var(--primary)', 0.28) + ' 0%, transparent 68%),' +
        'linear-gradient(180deg, #0f0800 0%, var(--bg-primary) 100%)';
    }
    var ring = document.getElementById('cpProfileRing');
    if (ring) ring.style.borderColor = coach.colorAccent || 'var(--primary)';

    /* Text fields */
    setText('coachName',    coach.name);
    setText('coachRole',    coach.role);
    setText('coachRating',  coach.rating);
    setText('coachReviews', '(' + coach.reviewCount + ' reviews)');
    setText('coachExp',     coach.experience);
    setText('cpHdrName',    coach.firstName || (coach.name || '').split(' ')[0]);
    setText('cpLang',       coach.languages || 'EN, HI');
    setText('cpChatRate',   '₹' + (coach.chatRate || coach.fee));
    setText('cpCallRate',   '₹' + (coach.callRate || (coach.fee + 30)));
    setText('cpStickyAmt',  '₹' + (coach.chatRate || coach.fee) + '/min');
    setText('cpRbVal',      coach.rating);
    setText('reviewTotalCount', String(coach.reviewCount));
    setText('aboutText',    coach.about);

    /* Pricing display — from this expert's Pricing & Services page, or
       today's platform defaults if they haven't set custom prices yet. */
    var _pd = _getPricing(coach);
    setText('pdDietReview',    '₹' + _pd.dietReviewPrice);
    setText('pdWorkoutReview', '₹' + _pd.workoutReviewPrice);
    setText('pdBothReview',    '₹' + _pd.bothReviewPrice);
    setText('pdChat',          '₹' + _pd.chatPrice);
    /* CLIENT TRIAL MODE — this "Starting ₹X/mo" summary reads the exact
       same coaching prices the plan-selection modal shows; keeping it in
       sync avoids a mismatch elsewhere on the same profile page. Real
       prices (_pd.coaching*Price) are untouched — only this display
       collapses to 0 while the trial flag is on. */
    var _coachingIsFreeTrial = typeof ZitlasPayment !== 'undefined' &&
      typeof ZitlasPayment.isTrialMode === 'function' && ZitlasPayment.isTrialMode();
    setText('pdCoaching', _coachingIsFreeTrial
      ? 'Starting ₹0/mo'
      : 'Starting ₹' + Math.min(_pd.coachingDietPrice, _pd.coachingTrainingPrice, _pd.coachingCompletePrice) + '/mo');

    /* Stars */
    var fullStar = Math.round(parseFloat(coach.rating));
    setText('coachStars', '★'.repeat(fullStar) + '☆'.repeat(5 - fullStar));

    /* Availability pill */
    var avail       = coach.availability;
    var availToday  = !avail || avail.isAvailableToday !== false;
    var availPill   = document.getElementById('cpAvailPill');
    var availText   = document.getElementById('cpAvailText');
    if (availPill && availText) {
      if (availToday) {
        availText.textContent = 'Available Today';
        availPill.classList.remove('busy');
      } else {
        availText.textContent = 'Next: ' + (avail && avail.nextSlot ? avail.nextSlot : 'Tomorrow');
        availPill.classList.add('busy');
      }
    }

    /* Verified Expert badge — real, driven by experts/{id}.verification
       (only true once at least one certificate passes AI verification or
       admin approval). Never hardcoded. Two surfaces:
       - #coachNameBadge, right next to the name — the standard ZitlasBadge
         (hover tooltip on desktop, tap bottom-sheet on mobile), same
         component every other page uses.
       - #cpVerifiedBadge, the pill lower in the hero — the pre-existing,
         richer "tap for full verification details" CTA (cert score, org,
         issue date, cert number), kept as-is since it already does more
         than the generic bottom sheet. */
    var nameBadgeEl = document.getElementById('coachNameBadge');
    var captionEl   = document.getElementById('coachVerifiedCaption');
    if (nameBadgeEl && typeof ZitlasBadge !== 'undefined') {
      nameBadgeEl.innerHTML = ZitlasBadge.render(coach, { size: 'lg' });
    }
    if (captionEl && typeof ZitlasBadge !== 'undefined') {
      captionEl.innerHTML = ZitlasBadge.renderCaption(coach);
    }
    var verifiedBadge = document.getElementById('cpVerifiedBadge');
    if (verifiedBadge) {
      verifiedBadge.style.display = coach.verified ? '' : 'none';
      verifiedBadge.addEventListener('click', function() {
        if (typeof ZitlasCertificates === 'undefined') return;
        ZitlasCertificates.openVerificationInfo(coach.name, _bestVerifiedCert);
      });
    }

    /* Sections */
    renderMetrics(coach);
    renderExpertise(coach);
    renderReviews(coach);
    renderRatingBars(coach);
    renderGallery(coach);
    renderServices(coach);
    renderAvailability(coach);

    /* Context modal */
    var modalImg = document.getElementById('modalCoachImg');
    if (modalImg) {
      modalImg.src = coach.image;
      modalImg.alt = coach.name;
      modalImg.addEventListener('error', function() {
        modalImg.src = makeFallbackSVG(coach.initials, coach.colorAccent, 52);
      });
    }
    setText('modalCoachTag',  'with ' + coach.name);
    setText('modalCoachName', coach.name);
    setText('modalCoachRole', coach.role);

    var ctxFeeEl = document.getElementById('ctxFeeVal');
    if (ctxFeeEl) ctxFeeEl.textContent = '₹' + coach.fee;

    /* Chat overlay header */
    setText('chatHdrName', coach.name);
    setText('chatHdrRole', coach.role);
    var chatBadgeEl = document.getElementById('chatHdrBadge');
    if (chatBadgeEl && typeof ZitlasBadge !== 'undefined') chatBadgeEl.innerHTML = ZitlasBadge.render(coach, { size: 'sm' });
    var av = document.getElementById('chatHdrAvatar');
    if (av) av.textContent = (coach.name || 'E').split(' ').map(function(w) { return w[0] || ''; }).join('').slice(0, 2).toUpperCase();
  }

  /* ══════════════════════════════════════════
     STAT CARD COUNT-UP
  ══════════════════════════════════════════ */
  function countUp(el, target, suffix, duration = 900) {
    const start   = performance.now();
    const isFloat = target % 1 !== 0;

    function tick(now) {
      const p       = Math.min((now - start) / duration, 1);
      const eased   = 1 - Math.pow(1 - p, 3);
      const current = isFloat
        ? (target * eased).toFixed(1)
        : Math.round(target * eased);
      el.textContent = current + suffix;
      if (p < 1) requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }

  function initStatCountUp(coach) {
    setTimeout(function() {
      document.querySelectorAll('.cp-metric-val').forEach(function(el, i) {
        var raw    = coach.stats[i] ? coach.stats[i].value : '';
        var num    = parseFloat(raw.replace(/[^0-9.]/g, ''));
        var suffix = raw.replace(/[0-9.]/g, '');
        if (!isNaN(num)) {
          el.textContent = '0' + suffix;
          setTimeout(function() { countUp(el, num, suffix, 800); }, 100 + i * 80);
        }
      });
    }, 400);
  }

  /* ══════════════════════════════════════════
     HTML ESCAPE HELPER
  ══════════════════════════════════════════ */
  function esc(str) {
    return String(str || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }

  function capitalize(str) {
    if (!str) return '';
    return str.charAt(0).toUpperCase() + str.slice(1);
  }

  /* ══════════════════════════════════════════
     BUILD CONTEXT PACKAGE FROM LOCALSTORAGE
  ══════════════════════════════════════════ */
  function buildContextPackage() {
    const ctx = {};
    const keys = {
      assessment:   'zitlas_assessment',
      calculations: 'zitlas_calculations',
      swot:         'zitlas_swot',
      diet_plan:    'zitlas_diet_plan',
      workout_plan: 'zitlas_workout_plan',
      survey:       'zitlas_survey',
    };
    Object.keys(keys).forEach((k) => {
      try { ctx[k] = JSON.parse(localStorage.getItem(keys[k]) || 'null'); } catch(_) {}
    });

    /* zitlas_diet_plan / zitlas_workout_plan are stored in the expert-
       modification wrapper schema ({originalDietPlan, currentDietPlan, ...}).
       Every chat/review card renderer (athlete AND expert side) expects the
       flat plan with .days / .weekly_plan — attaching the wrapper is why
       experts saw "Diet Plan Attached" with no actual meals inside. */
    if (ctx.diet_plan && (ctx.diet_plan.currentDietPlan || ctx.diet_plan.originalDietPlan)) {
      ctx.diet_plan = ctx.diet_plan.currentDietPlan || ctx.diet_plan.originalDietPlan;
    }
    if (ctx.workout_plan && (ctx.workout_plan.currentWorkoutPlan || ctx.workout_plan.originalWorkoutPlan)) {
      ctx.workout_plan = ctx.workout_plan.currentWorkoutPlan || ctx.workout_plan.originalWorkoutPlan;
    }
    console.log('[ATTACHMENT] context package', {
      assessment:   !!ctx.assessment,
      calculations: !!ctx.calculations,
      swot:         !!ctx.swot,
      diet_days:    ctx.diet_plan && ctx.diet_plan.days ? ctx.diet_plan.days.length : 0,
      workout_days: ctx.workout_plan ? ((ctx.workout_plan.weekly_plan || ctx.workout_plan.days || []).length) : 0,
    });
    return ctx;
  }

  /* ══════════════════════════════════════════
     BUILD SYSTEM MESSAGE TEXT
  ══════════════════════════════════════════ */
  function buildSystemMessage(ctx, question) {
    const lines = ['📋 User Profile Shared\n'];
    const a = ctx.assessment || ctx.survey || {};
    const c = ctx.calculations || {};

    if (a.age)              lines.push('Age: ' + a.age);
    if (a.gender)           lines.push('Gender: ' + capitalize(a.gender));
    if (a.height_cm)        lines.push('Height: ' + a.height_cm + ' cm');
    if (a.weight_kg)        lines.push('Weight: ' + a.weight_kg + ' kg');
    if (a.goal_weight_kg)   lines.push('Goal Weight: ' + a.goal_weight_kg + ' kg');
    if (a.activity_level)   lines.push('Activity: ' + capitalize(String(a.activity_level).replace(/_/g,' ')));
    if (a.diet_preference)  lines.push('Diet: ' + capitalize(String(a.diet_preference).replace(/_/g,' ')));
    if (a.workout_preference) lines.push('Workout: ' + capitalize(String(a.workout_preference).replace(/_/g,' ')));

    if (c.bmi) {
      lines.push('\n📊 Fitness Snapshot');
      lines.push('BMI: ' + parseFloat(c.bmi).toFixed(1));
      if (c.bmi_category)                 lines.push('Category: ' + c.bmi_category);
      if (c.bmr_kcal)                     lines.push('BMR: ' + Math.round(c.bmr_kcal) + ' kcal');
      if (c.tdee_kcal)                    lines.push('TDEE: ' + Math.round(c.tdee_kcal) + ' kcal');
      if (c.weight_loss_calories_kcal)    lines.push('Target Calories: ' + c.weight_loss_calories_kcal + ' kcal');
      if (c.protein_target_g)             lines.push('Protein Target: ' + c.protein_target_g + 'g');
      if (c.water_target_liters)          lines.push('Water Target: ' + c.water_target_liters + 'L');
      if (c.daily_steps_goal)             lines.push('Steps Goal: ' + Number(c.daily_steps_goal).toLocaleString());
    }

    if (ctx.swot) {
      const s = ctx.swot.swot || ctx.swot;
      function swotText(item) { return typeof item === 'object' ? (item.title || '') : String(item || ''); }
      lines.push('\n🎯 SWOT Summary');
      if (s.strengths    && s.strengths[0])      lines.push('Strength: '    + swotText(s.strengths[0]));
      if (s.weaknesses   && s.weaknesses[0])     lines.push('Weakness: '    + swotText(s.weaknesses[0]));
      if (s.opportunities && s.opportunities[0]) lines.push('Opportunity: '+ swotText(s.opportunities[0]));
      if (s.threats      && s.threats[0])        lines.push('Threat: '      + swotText(s.threats[0]));
    }

    if (ctx.diet_plan)    lines.push('\n🥗 Diet Plan Attached');
    if (ctx.workout_plan) lines.push('\n💪 Workout Plan Attached');

    if (question) lines.push('\n💬 User Question:\n"' + question + '"');

    return lines.join('\n');
  }

  /* ══════════════════════════════════════════
     REVIEW CHAT CARDS
     All posted automatically in 'review' mode.
  ══════════════════════════════════════════ */

  /* ── 1. Case file header summary ── */
  function createCaseFileSummary(ctx, note, coach) {
    const div = document.createElement('div');
    div.className = 'chat-msg chat-msg--review-confirm';

    const a = ctx.assessment || ctx.survey || {};
    const c = ctx.calculations || {};

    const currentWeight = a.weight_kg;
    const goalWeight    = a.goal_weight_kg;
    const goalLabel     = (currentWeight && goalWeight)
      ? (parseFloat(goalWeight) < parseFloat(currentWeight) ? 'Lose Weight' : 'Gain Weight')
      : 'Weight Management';

    const docItems = [
      { label: 'Assessment',       has: !!ctx.assessment },
      { label: 'Fitness Snapshot', has: !!ctx.calculations },
      { label: 'SWOT Report',      has: !!ctx.swot },
      { label: 'AI Diet Plan',     has: !!ctx.diet_plan },
      { label: 'AI Workout Plan',  has: !!ctx.workout_plan },
    ].filter(function(i) { return i.has; });

    const docsHtml = docItems.map(function(i) {
      return '<div class="rcm-item"><span class="rcm-check">✅</span>' + esc(i.label) + '</div>';
    }).join('');

    const noteHtml = note
      ? '<div class="rcm-user-note">💬 &ldquo;' + esc(note) + '&rdquo;</div>'
      : '';

    const fee        = coach && coach.fee ? '₹' + coach.fee : '—';
    const expertName = coach && coach.name ? coach.name : 'Expert';

    const statsHtml = [
      goalLabel     ? '<div class="rcm-stat"><span class="rcm-stat-label">Goal</span><span class="rcm-stat-val">' + esc(goalLabel) + '</span></div>' : '',
      currentWeight ? '<div class="rcm-stat"><span class="rcm-stat-label">Current Weight</span><span class="rcm-stat-val">' + esc(String(currentWeight)) + ' kg</span></div>' : '',
      goalWeight    ? '<div class="rcm-stat"><span class="rcm-stat-label">Target Weight</span><span class="rcm-stat-val">' + esc(String(goalWeight)) + ' kg</span></div>' : '',
      c.weight_loss_calories_kcal ? '<div class="rcm-stat"><span class="rcm-stat-label">Target Calories</span><span class="rcm-stat-val">' + esc(String(c.weight_loss_calories_kcal)) + ' kcal</span></div>' : '',
      c.protein_target_g ? '<div class="rcm-stat"><span class="rcm-stat-label">Protein</span><span class="rcm-stat-val">' + esc(String(c.protein_target_g)) + 'g</span></div>' : '',
    ].filter(Boolean).join('');

    div.innerHTML =
      '<div class="review-confirm-card">' +
        '<div class="rcm-header">' +
          '<span class="rcm-icon">📋</span>' +
          '<div>' +
            '<div class="rcm-title">Diet Plan Review Request</div>' +
            '<div class="rcm-sub">Shared with ' + esc(expertName) + '</div>' +
          '</div>' +
        '</div>' +
        (statsHtml ? '<div class="rcm-user-stats">' + statsHtml + '</div>' : '') +
        '<div class="rcm-attach-label">Attached Documents:</div>' +
        '<div class="rcm-items">' + docsHtml + '</div>' +
        noteHtml +
        '<div class="rcm-divider"></div>' +
        '<div class="rcm-fee-row">' +
          '<span class="rcm-fee-label">Review Fee</span>' +
          '<span class="rcm-fee-val">' + esc(fee) + '</span>' +
        '</div>' +
        '<div class="rcm-status-row">' +
          '<span class="rcm-status-dot rcm-status--pending"></span>' +
          '<span class="rcm-status-text">Waiting for Expert Review</span>' +
        '</div>' +
      '</div>';

    return div;
  }

  /* ── 2. Fitness Snapshot + Assessment card ── */
  function createFitnessCard(ctx) {
    const div = document.createElement('div');
    div.className = 'chat-msg chat-msg--card';
    div.id = 'chatFitnessCard';

    const a = ctx.assessment || ctx.survey || {};
    const c = ctx.calculations || {};

    const age      = a.age    ? String(a.age) + ' yrs' : '';
    const gender   = capitalize(a.gender || '');
    const height   = a.height_cm ? a.height_cm + ' cm' : '';
    const weight   = a.weight_kg ? a.weight_kg + ' kg' : '';
    const goal     = a.goal_weight_kg ? a.goal_weight_kg + ' kg' : '';
    const activity = a.activity_level  ? capitalize(String(a.activity_level).replace(/_/g, ' '))  : '';
    const diet     = a.diet_preference ? capitalize(String(a.diet_preference).replace(/_/g, ' ')) : '';

    const bmi       = c.bmi ? parseFloat(c.bmi).toFixed(1) : '';
    const bmiCat    = c.bmi_category || '';
    const bmr       = c.bmr_kcal  ? Math.round(c.bmr_kcal) + ' kcal'  : '';
    const tdee      = c.tdee_kcal ? Math.round(c.tdee_kcal) + ' kcal' : '';
    const targetCal = c.weight_loss_calories_kcal ? c.weight_loss_calories_kcal + ' kcal' : '';
    const protein   = c.protein_target_g   ? c.protein_target_g + 'g'   : '';
    const water     = c.water_target_liters ? c.water_target_liters + 'L' : '';
    const steps     = c.daily_steps_goal   ? Number(c.daily_steps_goal).toLocaleString() + '/day' : '';

    const statItems = [
      bmi       ? { val: bmi + (bmiCat ? ' · ' + bmiCat : ''), label: 'BMI',             accent: false } : null,
      bmr       ? { val: bmr,       label: 'BMR',             accent: false } : null,
      tdee      ? { val: tdee,      label: 'TDEE',            accent: false } : null,
      targetCal ? { val: targetCal, label: 'Target Calories', accent: true  } : null,
      protein   ? { val: protein,   label: 'Protein Target',  accent: true  } : null,
      water     ? { val: water,     label: 'Water Target',    accent: false } : null,
      steps     ? { val: steps,     label: 'Steps Goal',      accent: false } : null,
    ].filter(Boolean);

    const statsHtml = statItems.map(function(s) {
      return '<div class="cfc-stat' + (s.accent ? ' cfc-stat--accent' : '') + '">' +
        '<span class="cfc-stat-val">' + esc(s.val) + '</span>' +
        '<span class="cfc-stat-label">' + esc(s.label) + '</span>' +
      '</div>';
    }).join('');

    const profileLine = [age, gender, height].filter(Boolean).join(' · ');
    const weightRow   = weight && goal ? '⚖️ ' + weight + '  →  Goal: ' + goal
                        : weight ? '⚖️ ' + weight : '';
    const metaTags    = [activity, diet].filter(Boolean).map(function(t) {
      return '<span class="cfc-meta-tag">' + esc(t) + '</span>';
    }).join('');

    div.innerHTML =
      '<div class="chat-content-card">' +
        '<div class="ccc-header">' +
          '<span class="ccc-icon">📊</span>' +
          '<div class="ccc-title-group">' +
            '<span class="ccc-title">Fitness Snapshot</span>' +
            (profileLine ? '<span class="ccc-sub">' + esc(profileLine) + '</span>' : '') +
          '</div>' +
        '</div>' +
        (weightRow  ? '<div class="cfc-weight-row">' + esc(weightRow) + '</div>' : '') +
        (metaTags   ? '<div class="cfc-meta-row">' + metaTags + '</div>' : '') +
        (statsHtml  ? '<div class="cfc-stats-grid">' + statsHtml + '</div>' : '') +
      '</div>';

    return div;
  }

  /* ── 3. SWOT card ── */
  function createSwotChatCard(ctx) {
    const div = document.createElement('div');
    div.className = 'chat-msg chat-msg--card';
    div.id = 'chatSwotCard';

    const swotOuter = ctx.swot;
    if (!swotOuter) return div;
    const swot = swotOuter.swot || swotOuter;

    const quadrants = [
      { key: 'strengths',     icon: '💪', label: 'Strengths',     cls: 'csc-strength'    },
      { key: 'weaknesses',    icon: '⚠️', label: 'Weaknesses',    cls: 'csc-weakness'    },
      { key: 'opportunities', icon: '🎯', label: 'Opportunities', cls: 'csc-opportunity' },
      { key: 'threats',       icon: '🔴', label: 'Threats',       cls: 'csc-threat'      },
    ];

    const quadrantsHtml = quadrants.map(function(q) {
      const items = swot[q.key] || [];
      return '<div class="csc-quadrant ' + q.cls + '">' +
        '<div class="csc-qlabel">' + q.icon + ' ' + esc(q.label) + '</div>' +
        '<ul class="csc-qlist">' +
          items.slice(0, 3).map(function(item) {
            var text = typeof item === 'object' ? (item.title || '') : String(item || '');
            return '<li>' + esc(text) + '</li>';
          }).join('') +
        '</ul>' +
      '</div>';
    }).join('');

    div.innerHTML =
      '<div class="chat-content-card">' +
        '<div class="ccc-header">' +
          '<span class="ccc-icon">🎯</span>' +
          '<div class="ccc-title-group">' +
            '<span class="ccc-title">SWOT Analysis</span>' +
            (swotOuter.priority_action
              ? '<span class="ccc-sub">Priority: ' + esc(swotOuter.priority_action.slice(0, 80)) + (swotOuter.priority_action.length > 80 ? '…' : '') + '</span>'
              : '') +
          '</div>' +
        '</div>' +
        '<div class="csc-grid">' + quadrantsHtml + '</div>' +
      '</div>';

    return div;
  }

  /* ── 4. Diet Plan card ── */
  function createDietPlanChatCard(dietPlan) {
    const div = document.createElement('div');
    div.className = 'chat-msg chat-msg--card';
    div.id = 'chatDietCard';

    if (!dietPlan || !dietPlan.days) return div;

    const days       = dietPlan.days;
    const calTarget  = dietPlan.daily_calories_target || '';
    const protTarget = dietPlan.daily_protein_target_g || '';
    const dayNames   = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    function getMealFoods(meal) {
      if (Array.isArray(meal.foods) && meal.foods.length > 0) return meal.foods.join(', ');
      if (meal.food_items) return String(meal.food_items);
      return '';
    }

    function renderDayMeals(dayData) {
      return (dayData.meals || []).map(function(meal) {
        const foods  = getMealFoods(meal);
        const calStr = meal.calories && meal.protein_g
          ? meal.calories + ' kcal · ' + meal.protein_g + 'g protein'
          : meal.calories ? meal.calories + ' kcal' : '';
        return '<div class="cdpc-meal-row">' +
          '<div class="cdpc-meal-hdr">' +
            '<span class="cdpc-meal-emoji">' + esc(meal.emoji || '🍽️') + '</span>' +
            '<span class="cdpc-meal-name">' + esc(meal.meal_name || 'Meal') + '</span>' +
            (meal.time ? '<span class="cdpc-meal-time">' + esc(meal.time) + '</span>' : '') +
          '</div>' +
          (foods   ? '<div class="cdpc-meal-foods">' + esc(foods) + '</div>' : '') +
          (calStr  ? '<div class="cdpc-meal-meta">' + esc(calStr) + '</div>' : '') +
        '</div>';
      }).join('');
    }

    const pillsHtml = days.map(function(d, i) {
      return '<button class="cdpc-day-pill' + (i === 0 ? ' active' : '') + '" data-cdpc-day="' + i + '">' +
        esc(dayNames[i] || ('D' + (i + 1))) +
      '</button>';
    }).join('');

    const fullPlanHtml = days.map(function(d, i) {
      return '<div class="cdpc-full-day">' +
        '<div class="cdpc-full-day-hdr">' +
          '<span class="cdpc-full-day-name">' + esc(d.day || ('Day ' + (i + 1))) + '</span>' +
          (d.theme ? '<span class="cdpc-full-day-theme">' + esc(d.theme) + '</span>' : '') +
          (d.total_calories ? '<span class="cdpc-full-day-cal">' + d.total_calories + ' kcal</span>' : '') +
        '</div>' +
        renderDayMeals(d) +
      '</div>';
    }).join('<div class="cdpc-day-sep"></div>');

    var subText = '7-Day Plan';
    if (calTarget)  subText += ' · ' + calTarget + ' kcal/day';
    if (protTarget) subText += ' · ' + protTarget + 'g protein';

    div.innerHTML =
      '<div class="chat-content-card">' +
        '<div class="ccc-header">' +
          '<span class="ccc-icon">🥗</span>' +
          '<div class="ccc-title-group">' +
            '<span class="ccc-title">' + esc(dietPlan.plan_name || 'AI Diet Plan') + '</span>' +
            '<span class="ccc-sub">' + esc(subText) + '</span>' +
          '</div>' +
        '</div>' +
        '<div class="cdpc-day-pills" id="cdpcPills">' + pillsHtml + '</div>' +
        '<div class="cdpc-day-meals" id="cdpcMeals">' + renderDayMeals(days[0]) + '</div>' +
        '<div class="cdpc-full-plan" id="cdpcFull" style="display:none">' + fullPlanHtml + '</div>' +
        '<div class="ccc-actions">' +
          '<button class="cpc-expand-btn" data-target="cdpcFull" data-label-expand="View Full Plan ↓" data-label-collapse="Hide Full Plan ↑">View Full Plan ↓</button>' +
        '</div>' +
      '</div>';

    return div;
  }

  /* ── 5. Workout Plan card ── */
  function createWorkoutPlanChatCard(workoutPlan) {
    const div = document.createElement('div');
    div.className = 'chat-msg chat-msg--card';
    div.id = 'chatWorkoutCard';

    if (!workoutPlan) return div;

    const planName = workoutPlan.plan_name || 'AI Workout Plan';
    const wDays    = workoutPlan.weekly_plan || workoutPlan.days || [];
    if (!wDays.length) return div;

    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    function getDayActivity(d) {
      return d.focus || d.theme || d.type || d.activity || 'Training';
    }
    function getDayDuration(d) {
      return d.duration_minutes ? d.duration_minutes + ' min' : (d.totalTime || '');
    }

    const gridHtml = wDays.map(function(d, i) {
      const activity = getDayActivity(d);
      const duration = getDayDuration(d);
      const isRest   = /rest|recovery/i.test(activity);
      return '<div class="cwpc-day-cell' + (isRest ? ' cwpc-day-rest' : '') + '">' +
        '<span class="cwpc-day-name">' + esc(dayNames[i] || ('D' + (i + 1))) + '</span>' +
        '<span class="cwpc-day-activity">' + esc(activity) + '</span>' +
        (duration ? '<span class="cwpc-day-dur">' + esc(duration) + '</span>' : '') +
      '</div>';
    }).join('');

    const fullHtml = wDays.map(function(d, i) {
      const exercises = d.exercises || d.drills || [];
      const activity  = getDayActivity(d);
      const duration  = getDayDuration(d);
      const tip       = d.daily_tip || d.tip || '';

      const exHtml = exercises.map(function(ex) {
        const name    = ex.name || ex.drill_name || 'Exercise';
        const sets    = ex.sets ? ex.sets + ' sets' : '';
        const reps    = ex.reps_or_duration || ex.reps || ex.duration || '';
        const details = [sets, reps].filter(Boolean).join(' × ');
        return '<div class="cwpc-exercise">' +
          '<span class="cwpc-ex-name">' + esc(name) + '</span>' +
          (details ? '<span class="cwpc-ex-detail">' + esc(details) + '</span>' : '') +
        '</div>';
      }).join('');

      return '<div class="cwpc-full-day">' +
        '<div class="cwpc-full-day-hdr">' +
          '<span class="cwpc-full-day-name">' + esc(d.day || d.dayName || ('Day ' + (i + 1))) + '</span>' +
          '<span class="cwpc-full-day-type">' + esc(activity + (duration ? ' · ' + duration : '')) + '</span>' +
        '</div>' +
        (exHtml || '<div class="cwpc-rest-label">Rest / Recovery Day</div>') +
        (tip ? '<div class="cwpc-day-tip">💡 ' + esc(tip) + '</div>' : '') +
      '</div>';
    }).join('<div class="cdpc-day-sep"></div>');

    div.innerHTML =
      '<div class="chat-content-card">' +
        '<div class="ccc-header">' +
          '<span class="ccc-icon">💪</span>' +
          '<div class="ccc-title-group">' +
            '<span class="ccc-title">' + esc(planName) + '</span>' +
            '<span class="ccc-sub">7-Day Training Schedule</span>' +
          '</div>' +
        '</div>' +
        '<div class="cwpc-week-grid">' + gridHtml + '</div>' +
        '<div class="cwpc-full-plan" id="cwpcFull" style="display:none">' + fullHtml + '</div>' +
        '<div class="ccc-actions">' +
          '<button class="cpc-expand-btn" data-target="cwpcFull" data-label-expand="View Full Plan ↓" data-label-collapse="Hide Full Plan ↑">View Full Plan ↓</button>' +
        '</div>' +
      '</div>';

    return div;
  }

  /* ── Wire all review-chat interactions ── */
  function wireReviewChatInteractions(container) {
    /* Expand / collapse toggles */
    container.querySelectorAll('.cpc-expand-btn').forEach(function(btn) {
      btn.addEventListener('click', function() {
        const targetId = btn.dataset.target;
        const target   = document.getElementById(targetId);
        if (!target) return;
        const expanded = target.style.display !== 'none';
        target.style.display = expanded ? 'none' : 'block';
        btn.textContent = expanded ? btn.dataset.labelExpand : btn.dataset.labelCollapse;
      });
    });

    /* Diet day-pill switching */
    const pillsWrap = document.getElementById('cdpcPills');
    const mealsWrap = document.getElementById('cdpcMeals');
    if (pillsWrap && mealsWrap) {
      pillsWrap.addEventListener('click', function(e) {
        const pill = e.target.closest('[data-cdpc-day]');
        if (!pill) return;
        const dayIdx = parseInt(pill.dataset.cdpcDay, 10);
        pillsWrap.querySelectorAll('.cdpc-day-pill').forEach(function(p) {
          p.classList.toggle('active', p === pill);
        });
        /* Pull meal HTML from the matching full-plan day */
        const fullDays = document.querySelectorAll('#cdpcFull .cdpc-full-day');
        if (fullDays[dayIdx]) {
          const cloned = Array.from(fullDays[dayIdx].querySelectorAll('.cdpc-meal-row'));
          mealsWrap.innerHTML = '';
          cloned.forEach(function(m) { mealsWrap.appendChild(m.cloneNode(true)); });
        }
      });
    }

    /* Badge clicks → scroll to card */
    const badgeMap = {
      badgeAssessment: 'chatFitnessCard',
      badgeFitness:    'chatFitnessCard',
      badgeSwot:       'chatSwotCard',
      badgeDiet:       'chatDietCard',
      badgeWorkout:    'chatWorkoutCard',
    };
    Object.keys(badgeMap).forEach(function(badgeId) {
      const badge = document.getElementById(badgeId);
      if (!badge) return;
      badge.style.cursor = 'pointer';
      badge.title = 'Tap to view';
      badge.onclick = function() {
        const card = document.getElementById(badgeMap[badgeId]);
        if (card) card.scrollIntoView({ behavior: 'smooth', block: 'start' });
      };
    });
  }

  /* ══════════════════════════════════════════
     ZC CHAT HELPERS — day separators, grouping, typing
  ══════════════════════════════════════════ */
  function buildZcDaySep(timestamp) {
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

  function zcIsGrouped(prevMsg, currMsg) {
    if (!prevMsg || prevMsg.senderType !== currMsg.senderType) return false;
    if (!prevMsg.timestamp || !currMsg.timestamp) return false;
    return (new Date(currMsg.timestamp) - new Date(prevMsg.timestamp)) < 5 * 60 * 1000;
  }

  function showZcTyping(container, initials) {
    hideZcTyping(container);
    var el = document.createElement('div');
    el.className = 'zc-typing'; el.id = 'zcTypingEl';
    el.innerHTML =
      '<div class="zc-av">' + esc(initials || '?') + '</div>' +
      '<div class="zc-typing-bbl">' +
        '<span class="zc-typing-dot"></span><span class="zc-typing-dot"></span><span class="zc-typing-dot"></span>' +
      '</div>';
    container.appendChild(el);
    container.scrollTop = container.scrollHeight;
  }

  function hideZcTyping(container) {
    var old = container ? container.querySelector('#zcTypingEl') : document.getElementById('zcTypingEl');
    if (old) old.remove();
  }

  /* ══════════════════════════════════════════
     CHAT MESSAGE FACTORIES
  ══════════════════════════════════════════ */
  function createSystemMsg(text) {
    const div = document.createElement('div');
    div.className = 'zc-system-card';
    div.innerHTML = '<span class="zc-sys-text">' + esc(text).replace(/\n/g, '<br>') + '</span>';
    return div;
  }

  function createUserMsg(text, timestamp, grouped, imageUrl) {
    const div = document.createElement('div');
    div.className = 'zc-msg zc-msg--out ' + (grouped ? 'zc-msg--grouped' : 'zc-msg--first');
    var ts = '';
    try { if (timestamp) ts = new Date(timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); } catch(_) {}
    var contentHtml = imageUrl
      ? '<img class="chat-image" src="' + esc(imageUrl) + '" alt="Image" onclick="ZitlasChatAttach.openViewer(this.src)">'
      : '<span class="zc-bbl-txt">' + esc(text).replace(/\n/g, '<br>') + '</span>';
    div.innerHTML =
      '<div class="zc-bbl' + (imageUrl ? ' zc-bbl--img' : '') + '">' +
        contentHtml +
        (ts ? '<span class="zc-bbl-ts">' + esc(ts) + '</span>' : '') +
      '</div>';
    return div;
  }

  function createExpertReplyMsg(text, expertName, timestamp, grouped, imageUrl) {
    const div = document.createElement('div');
    div.className = 'zc-msg zc-msg--in ' + (grouped ? 'zc-msg--grouped' : 'zc-msg--first');
    var initials = (expertName || 'E').split(' ').map(function(w) { return w[0] || ''; }).join('').slice(0, 2).toUpperCase();
    var ts = '';
    try { if (timestamp) ts = new Date(timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); } catch(_) {}
    var avHtml = grouped ? '<div class="zc-av-ghost"></div>' : '<div class="zc-av">' + esc(initials) + '</div>';
    var contentHtml = imageUrl
      ? '<img class="chat-image" src="' + esc(imageUrl) + '" alt="Image" onclick="ZitlasChatAttach.openViewer(this.src)">'
      : '<span class="zc-bbl-txt">' + esc(text).replace(/\n/g, '<br>') + '</span>';
    div.innerHTML =
      avHtml +
      '<div class="zc-bbl' + (imageUrl ? ' zc-bbl--img' : '') + '">' +
        contentHtml +
        (ts ? '<span class="zc-bbl-ts">' + esc(ts) + '</span>' : '') +
      '</div>';
    return div;
  }

  /* ══════════════════════════════════════════
     CHAT PERSISTENCE HELPERS
  ══════════════════════════════════════════ */

  let _currentChatCoach = null;

  /* personal_coaching/{uid} doc, kept live by initPersonalCoaching's listener.
     Shared at module scope so the chat overlay (opened for any coach) can
     tell whether the coach it's currently talking to is a PAST coach whose
     relationship has ended, and lock the conversation read-only. */
  var _pcRelationship = null;
  function _chatIsReadOnlyFor(coach) {
    return !!(coach && _pcRelationship &&
      _pcRelationship.coachId === coach.id && _pcRelationship.status === 'ended');
  }

  /* Active (non-expired) Personal Coaching with THIS coach → chat/coach
     buttons route into the dedicated Coaching Workspace instead of the
     normal chat overlay. Uses the canonical gate (assets/js/coaching-gate.js)
     — this used to check status only, letting an athlete open the paid
     Workspace after their subscription's endDate passed but before the
     backend sweep or a refresh caught up. */
  function _coachingWorkspaceFor(coach) {
    return !!(coach && _pcRelationship && window.ZitlasCoachingWorkspace &&
      _pcRelationship.coachId === coach.id &&
      typeof ZitlasCoachingGate !== 'undefined' && ZitlasCoachingGate.evaluate(_pcRelationship).active);
  }
  function _openCoachingWorkspace(coach, tab) {
    var rel = _pcRelationship;
    ZitlasCoachingWorkspace.open({
      role:        'athlete',
      athleteId:   rel.athleteId || _getMyUserId(),
      athleteName: rel.athleteName || getAthleteName(),
      coachId:     rel.coachId,
      coachName:   rel.coachName || (coach && coach.name) || 'Coach',
      coachVerification: (typeof ZitlasBadge !== 'undefined') ? ZitlasBadge.normalize(coach) : null,
      planType:    rel.planType || 'complete',
      planLabel:   rel.planLabel || 'Personal Coaching',
      startDate:   rel.startDate,
      endDate:     rel.endDate,
      status:      rel.status,
      initialTab:  tab || 'overview',
    });
  }
  function _applyChatReadOnlyState() {
    var banner = document.getElementById('chatReadonlyBanner');
    var inputBar = document.getElementById('chatInputBar');
    if (!banner || !inputBar) return;
    var readOnly = _chatIsReadOnlyFor(_currentChatCoach);
    banner.style.display = readOnly ? 'block' : 'none';
    inputBar.style.display = readOnly ? 'none' : 'flex';
  }

  function getAthleteId() {
    var id = localStorage.getItem('zitlas_athlete_id');
    if (id) return id;
    try {
      var fb = JSON.parse(localStorage.getItem('zitlas_firebase_user') || 'null');
      if (fb && fb.uid) { localStorage.setItem('zitlas_athlete_id', fb.uid); return fb.uid; }
    } catch(_) {}
    id = 'athlete_' + Date.now().toString(36);
    localStorage.setItem('zitlas_athlete_id', id);
    return id;
  }

  function getAthleteName() {
    try {
      var fb = JSON.parse(localStorage.getItem('zitlas_firebase_user') || 'null');
      if (fb && fb.name) return fb.name;
    } catch(_) {}
    return 'Athlete';
  }

  function getConversationId(coachId) {
    return 'chat_' + getAthleteId() + '_' + coachId;
  }

  function loadConversation(conversationId) {
    try {
      var all = JSON.parse(localStorage.getItem('zitlas_chats') || '{}');
      return all[conversationId] || null;
    } catch(_) { return null; }
  }

  function ensureConversation(coachId, coachName) {
    var conversationId = getConversationId(coachId);
    try {
      var all = JSON.parse(localStorage.getItem('zitlas_chats') || '{}');
      if (!all[conversationId]) {
        all[conversationId] = {
          conversationId:  conversationId,
          athleteId:       getAthleteId(),
          athleteName:     getAthleteName(),
          expertId:        coachId,
          expertName:      coachName,
          messages:        [],
          lastMessage:     '',
          lastMessageAt:   null,
          unreadByExpert:  0,
        };
        localStorage.setItem('zitlas_chats', JSON.stringify(all));
      }
    } catch(_) {}
    return conversationId;
  }

  function persistReviewPacket(conversationId, request) {
    try {
      var all  = JSON.parse(localStorage.getItem('zitlas_chats') || '{}');
      var conv = all[conversationId];
      if (!conv) return null;
      if (conv.messages && conv.messages.some(function(m) { return m.type === 'review_packet'; })) return null;
      var packet = {
        id:             'msg_review_' + Date.now(),
        conversationId: conversationId,
        type:           'review_packet',
        payload:        request,
        timestamp:      request.submittedAt || new Date().toISOString(),
      };
      conv.messages = [packet].concat(conv.messages || []);
      localStorage.setItem('zitlas_chats', JSON.stringify(all));
      console.log('[ZITLAS] Review packet injected into conversation:', packet.id);
      console.log('[ZITLAS] Athlete Review Packet', packet.payload);
      return packet;
    } catch(e) { console.error('[ZITLAS] persistReviewPacket failed:', e); return null; }
  }

  function persistChatMessage(conversationId, senderType, text, imageUrl) {
    var athleteId = getAthleteId();
    var msg = {
      id:             'msg_' + Date.now() + '_' + Math.random().toString(36).slice(2, 5),
      conversationId: conversationId,
      senderId:       senderType === 'athlete' ? athleteId : (_currentChatCoach ? _currentChatCoach.id : 'expert'),
      senderType:     senderType,
      text:           text,
      type:           imageUrl ? 'image' : 'text',
      imageUrl:       imageUrl || null,
      timestamp:      new Date().toISOString(),
    };
    console.log("ATHLETE SAVING TO", conversationId);
    console.log("ATHLETE MESSAGE", msg);
    var _otherUid = _currentChatCoach ? _currentChatCoach.id : null;
    try {
      var all = JSON.parse(localStorage.getItem('zitlas_chats') || '{}');
      if (!all[conversationId]) {
        console.warn("ATHLETE: conversation missing in localStorage for key", conversationId);
        return msg;
      }
      _otherUid = all[conversationId].expertId || _otherUid;
      all[conversationId].messages.push(msg);
      all[conversationId].lastMessage    = text;
      all[conversationId].lastMessageAt  = msg.timestamp;
      if (senderType === 'athlete') {
        all[conversationId].unreadByExpert = (all[conversationId].unreadByExpert || 0) + 1;
      }
      localStorage.setItem('zitlas_chats', JSON.stringify(all));
    } catch(_) {}
    console.log('Message Sent', msg);
    _cpSyncChatMessageToFirestore(conversationId, athleteId, _otherUid, msg);
    return msg;
  }

  /* Mirrors every chat message into Firestore so the other participant's
     device (a different browser/localStorage) actually receives it.
     localStorage above remains this device's read cache — untouched.

     The room doc carries participant metadata (athleteId/Name, expertId/Name,
     lastMessage) — that is what the expert dashboard's chat_rooms discovery
     listener uses to build its Client Chats inbox on a device where the
     conversation never existed in localStorage. */
  function _cpSyncChatMessageToFirestore(chatId, currentUid, otherUid, payload) {
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
    var conv = loadConversation(chatId) || {};
    var roomDoc = {
      participants:  participants,
      athleteId:     conv.athleteId   || currentUid,
      athleteName:   conv.athleteName || getAthleteName(),
      expertId:      conv.expertId    || otherUid,
      expertName:    conv.expertName  || (_currentChatCoach ? _currentChatCoach.name : 'Expert'),
      lastMessage:   payload.type === 'review_packet' ? '📋 Plan review packet' : (payload.text || ''),
      lastMessageAt: payload.timestamp || new Date().toISOString(),
      updatedAt:     firebase.firestore.FieldValue.serverTimestamp(),
    };
    ZitlasDB.collection('chat_rooms').doc(chatId).set(roomDoc, { merge: true })
      .then(function() {
        /* doc(payload.id) not add() — idempotent, so re-syncing the same
           message (e.g. review packet re-shared) never creates duplicates */
        return ZitlasDB.collection('chat_rooms').doc(chatId).collection('messages').doc(payload.id).set(payload);
      })
      .then(function() { console.log('[CHAT] firestore write success'); })
      .catch(function(err) { console.error('[CHAT] firestore write failed', err); });
  }

  /* ══════════════════════════════════════════
     UPDATE CHIP PRESENCE (green if data exists)
     containerId: 'ctxChips' or 'verifyCtxChips'
  ══════════════════════════════════════════ */
  function updateChipPresence(ctx, containerId) {
    const map = {
      assessment: !!ctx.assessment,
      fitness:    !!ctx.calculations,
      swot:       !!ctx.swot,
      diet:       !!ctx.diet_plan,
      workout:    !!ctx.workout_plan,
      goal:       !!(ctx.survey || ctx.assessment),
    };
    const id = containerId || 'ctxChips';
    document.querySelectorAll('#' + id + ' .ctx-chip').forEach((el) => {
      const key = el.dataset.key;
      if (key) el.classList.toggle('present', !!map[key]);
    });
  }

  /* ══════════════════════════════════════════
     CONTEXT MODAL
  ══════════════════════════════════════════ */
  function initContextModal(coach) {
    const modal   = document.getElementById('contextModal');
    const openBtn = document.getElementById('bookNowBtn');
    const closeBtn = document.getElementById('closeModal');
    const sendBtn  = document.getElementById('sendExpertBtn');
    if (!modal) return;

    function openModal() {
      updateChipPresence(buildContextPackage(), 'ctxChips');
      modal.classList.add('open');
      document.body.style.overflow = 'hidden';
    }
    function closeModal() {
      modal.classList.remove('open');
      document.body.style.overflow = '';
    }

    if (openBtn)  openBtn.addEventListener('click', openModal);
    if (closeBtn) closeBtn.addEventListener('click', closeModal);
    modal.addEventListener('click', (e) => { if (e.target === modal) closeModal(); });
    modal.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeModal(); });

    if (sendBtn) {
      sendBtn.addEventListener('click', () => {
        const question = (document.getElementById('userQuestion')?.value || '').trim();
        const ctx = buildContextPackage();
        closeModal();

        /* buildSystemMessage() below only renders a LOCAL preview bubble —
           "Diet Plan Attached" text with no data behind it. Persist a real
           review_packet message (same shape/renderer as the formal "Send for
           Review" flow) so the expert actually receives the attached plan,
           assessment, and SWOT data instead of plain text. */
        if (ctx.diet_plan || ctx.workout_plan || ctx.assessment || ctx.swot) {
          let athleteName = 'Athlete';
          try {
            const fbUser = JSON.parse(localStorage.getItem('zitlas_firebase_user') || 'null');
            if (fbUser && fbUser.name) athleteName = fbUser.name;
          } catch (_) {}

          const chatPacketRequest = {
            id:           'REQ_CHAT_' + Date.now(),
            athlete_name: athleteName,
            expertId:     coach.id,
            expertName:   coach.name,
            expertRole:   coach.role,
            expertImg:    coach.image,
            submittedAt:  new Date().toISOString(),
            note:         question,
            context: {
              assessment:   ctx.assessment,
              calculations: ctx.calculations,
              swot:         ctx.swot,
              diet_plan:    ctx.diet_plan,
              workout_plan: ctx.workout_plan,
              survey:       ctx.survey,
            },
          };

          const chatConvId = ensureConversation(coach.id, coach.name);
          let packet = persistReviewPacket(chatConvId, chatPacketRequest);
          if (!packet) {
            /* A packet already exists locally — it may predate Firestore
               chat sync and never have left this device. Re-sync it; the
               doc(id).set() write is idempotent so this can't duplicate. */
            const conv = loadConversation(chatConvId);
            packet = ((conv && conv.messages) || []).find(function(m) { return m.type === 'review_packet'; }) || null;
          }
          if (packet) {
            console.log('[ATTACHMENT] syncing review packet to Firestore', packet.id);
            _cpSyncChatMessageToFirestore(chatConvId, getAthleteId(), coach.id, packet);
          }
        }

        openChatOverlay(question, ctx, 'chat', coach);
      });
    }
  }

  /* ══════════════════════════════════════════
     OPEN EXPERT CHAT OVERLAY
     mode: 'chat' (default) | 'review'
  ══════════════════════════════════════════ */
  function openChatOverlay(question, ctx, mode, coach) {
    const overlay = document.getElementById('chatOverlay');
    if (!overlay) return;

    /* Track which expert we're chatting with */
    _currentChatCoach = coach || null;

    const badgeMap = {
      badgeAssessment: !!ctx.assessment,
      badgeFitness:    !!ctx.calculations,
      badgeSwot:       !!ctx.swot,
      badgeDiet:       !!ctx.diet_plan,
      badgeWorkout:    !!ctx.workout_plan,
    };
    Object.keys(badgeMap).forEach((id) => {
      const el = document.getElementById(id);
      if (el) el.classList.toggle('visible', badgeMap[id]);
    });

    /* Review status badge in header */
    const reviewStatusEl = document.getElementById('chatReviewStatus');
    if (reviewStatusEl) {
      if (mode === 'review') {
        reviewStatusEl.textContent = '🟡 Under Review';
        reviewStatusEl.className = 'chat-review-status chat-review-status--pending';
        reviewStatusEl.style.display = 'inline-flex';
      } else {
        reviewStatusEl.style.display = 'none';
      }
    }

    const container = document.getElementById('chatMessages');
    container.innerHTML = '';

    if (mode === 'chat') {
      container.appendChild(createSystemMsg(buildSystemMessage(ctx, question)));
    }
    /* review cards come from the review_packet message injected into conv.messages below */

    /* Load persisted chat messages (text messages only, not the context cards above) */
    if (coach) {
      renderConversationMessages(container, coach);
      startChatMessagesListener(coach);
      startIncomingCallListener(coach);
    }

    /* Hide the bottom navbar so chat is truly full-screen */
    const navbar = document.getElementById('zitlas-navbar');
    if (navbar) navbar.style.display = 'none';

    _applyChatReadOnlyState();

    overlay.classList.add('open');
    document.body.style.overflow = 'hidden';
    container.scrollTop = container.scrollHeight;

    setTimeout(() => {
      const input = document.getElementById('chatInput');
      if (input) input.focus();
    }, 380);
  }

  /* Renders conv.messages (persisted text/image/review-packet messages) into
     the given container. Shared by the initial chat-open render and by the
     realtime Firestore listener so an incoming message re-renders identically. */
  function renderConversationMessages(container, coach) {
    const conversationId = ensureConversation(coach.id, coach.name);
    const conv = loadConversation(conversationId);
    container.innerHTML = '';
    if (!conv || !conv.messages || !conv.messages.length) return;

    console.log('Conversation Loaded', conv);
    var hiddenCutoff = conv.hiddenForAthlete || null;
    var prevMsg = null;
    var prevDay = null;
    conv.messages.forEach(function(msg) {
      /* Skip messages at or before the clear timestamp */
      if (hiddenCutoff && msg.timestamp && msg.timestamp <= hiddenCutoff) return;
      /* Review packet — render full context cards */
      if (msg.type === 'review_packet') {
        var pld  = msg.payload || {};
        var pCtx = pld.context || {};
        var pCoach = { id: pld.expertId, name: pld.expertName, fee: pld.fee };
        container.appendChild(createCaseFileSummary(pCtx, pld.note, pCoach));
        if (pCtx.assessment || pCtx.calculations) container.appendChild(createFitnessCard(pCtx));
        if (pCtx.swot)         container.appendChild(createSwotChatCard(pCtx));
        if (pCtx.diet_plan)    container.appendChild(createDietPlanChatCard(pCtx.diet_plan));
        if (pCtx.workout_plan) container.appendChild(createWorkoutPlanChatCard(pCtx.workout_plan));
        wireReviewChatInteractions(container);
        console.log('[ZITLAS] Athlete Review Packet', pld);
        prevMsg = null;
        return;
      }

      var msgDay = msg.timestamp ? new Date(msg.timestamp).toDateString() : null;
      if (msgDay && msgDay !== prevDay) {
        container.appendChild(buildZcDaySep(msg.timestamp));
        prevDay = msgDay;
      }
      var grouped = zcIsGrouped(prevMsg, msg);
      var el = msg.senderType === 'athlete'
        ? createUserMsg(msg.text, msg.timestamp, grouped, msg.imageUrl)
        : createExpertReplyMsg(msg.text, conv.expertName, msg.timestamp, grouped, msg.imageUrl);
      el.dataset.msgId = msg.id;
      container.appendChild(el);
      prevMsg = msg;
    });

    /* If everything was filtered out, show the cleared state */
    if (!container.children.length) {
      var clearedEl = document.createElement('div');
      clearedEl.className = 'zc-empty';
      clearedEl.textContent = 'Chat cleared. New messages will appear here.';
      container.appendChild(clearedEl);
    }
  }

  /* ══════════════════════════════════════════
     REALTIME CHAT — Firestore is the source of truth for cross-device
     delivery. localStorage remains the render cache; this listener keeps
     it in sync so a message sent from the expert's device appears here
     without a refresh.
  ══════════════════════════════════════════ */
  var _chatMsgListenerConvId = null;

  function startChatMessagesListener(coach) {
    if (typeof ZitlasDB === 'undefined' || !coach) return;
    var conversationId = getConversationId(coach.id);
    if (_chatMsgListenerConvId === conversationId) return; /* already listening */
    _chatMsgListenerConvId = conversationId;

    ZitlasDB.collection('chat_rooms').doc(conversationId).collection('messages')
      .orderBy('timestamp')
      .onSnapshot(function(snapshot) {
        console.log('[CHAT] snapshot received', snapshot.size, 'messages for', conversationId);
        var incoming = snapshot.docs.map(function(d) { return d.data(); });

        var all = {};
        try { all = JSON.parse(localStorage.getItem('zitlas_chats') || '{}'); } catch(_) {}
        if (!all[conversationId]) return; /* conversation not initialized locally yet */

        var localMsgs = all[conversationId].messages || [];
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
        all[conversationId].messages = localMsgs;
        var last = localMsgs[localMsgs.length - 1];
        if (last) {
          all[conversationId].lastMessage   = last.text || '';
          all[conversationId].lastMessageAt = last.timestamp;
        }
        try { localStorage.setItem('zitlas_chats', JSON.stringify(all)); } catch(_) {}

        /* Re-render only if this conversation's chat is currently open */
        var overlay = document.getElementById('chatOverlay');
        if (overlay && overlay.classList.contains('open') && _currentChatCoach && _currentChatCoach.id === coach.id) {
          var container = document.getElementById('chatMessages');
          if (container) {
            renderConversationMessages(container, coach);
            container.scrollTop = container.scrollHeight;
          }
        }
      }, function(err) {
        console.error('[CHAT] messages listener error', err);
      });
  }

  /* ══════════════════════════════════════════
     VOICE CALL (WebRTC via assets/js/webrtc-call.js)
  ══════════════════════════════════════════ */
  var _callSession           = null;  /* active ZitlasCall session handle, or null */
  var _pendingIncomingCall   = null;  /* {callId, chatId, callerId, offer}, or null */
  var _incomingCallListenerConvId = null;

  function startIncomingCallListener(coach) {
    if (typeof ZitlasDB === 'undefined' || typeof ZitlasCall === 'undefined' || !coach) return;
    var conversationId = getConversationId(coach.id);
    if (_incomingCallListenerConvId === conversationId) return; /* already listening */
    _incomingCallListenerConvId = conversationId;

    ZitlasCall.listenForIncomingCalls({
      db: ZitlasDB, chatId: conversationId, myUid: getAthleteId(),
      onIncomingCall: function(callInfo) {
        if (_callSession || _pendingIncomingCall) return; /* already on a call */
        _pendingIncomingCall = callInfo;
        ZitlasCallUI.showIncoming({
          name:  coach.name  || 'Your Coach',
          role:  coach.role  || 'Expert',
          photo: coach.image || null,
          onAccept: function() {
            if (_pendingIncomingCall) _acceptIncomingCall(_pendingIncomingCall);
          },
          onReject: function() {
            if (_pendingIncomingCall) {
              ZitlasCall.declineCall({ db: ZitlasDB, chatId: _pendingIncomingCall.chatId, callId: _pendingIncomingCall.callId });
            }
            _pendingIncomingCall = null;
            ZitlasCallUI.close();
          },
        });
      },
      onCallCancelled: function(callId) {
        /* Caller hung up while we were still ringing — dismiss the popup */
        if (_pendingIncomingCall && _pendingIncomingCall.callId === callId) {
          _pendingIncomingCall = null;
          ZitlasCallUI.close({ message: 'Call ended' });
        }
      },
    });
  }

  function _startOutgoingCall(coach) {
    var chatId = getConversationId(coach.id);
    console.log('[CALL] current uid', getAthleteId());
    console.log('[CALL] other uid', coach.id);
    console.log('[CALL] chatId', chatId);

    ZitlasCallUI.showOutgoing({
      name:  coach.name  || 'Your Coach',
      role:  coach.role  || 'Expert',
      photo: coach.image || null,
      onHangup: function() {
        if (_callSession) _callSession.hangup();
        ZitlasCallUI.close({ message: 'Call ended' });
        _endCallUI();
      },
    });

    _callSession = ZitlasCall.startCall({
      db: ZitlasDB, chatId: chatId, myUid: getAthleteId(), otherUid: coach.id,
      onLocalStream:  function(stream) { ZitlasCallUI.setLocalStream(stream); },
      onRemoteStream: function(stream) { ZitlasCallUI.setRemoteStream(stream); },
      onStateChange:  function(state) {
        console.log('[CALL] state', state);
        if      (state === 'ringing')      ZitlasCallUI.setStatus('Ringing…');
        else if (state === 'accepted')     ZitlasCallUI.setStatus('Connecting…');
        else if (state === 'connecting')   ZitlasCallUI.setStatus('Connecting…');
        else if (state === 'connected')    ZitlasCallUI.setConnected();
        else if (state === 'disconnected') ZitlasCallUI.setStatus('Reconnecting…');
        else if (state === 'rejected')     { ZitlasCallUI.close({ message: 'Call declined' }); _endCallUI(); }
        else if (state === 'ended' || state === 'failed' || state === 'closed') {
          ZitlasCallUI.close({ message: state === 'failed' ? 'Could not connect' : 'Call ended' });
          _endCallUI();
        }
      },
    });
    var callBtn = document.getElementById('chatCallBtn');
    if (callBtn) { callBtn.classList.add('zc-call-btn--calling'); callBtn.setAttribute('aria-label', 'End call'); }
  }

  function _acceptIncomingCall(callInfo) {
    _pendingIncomingCall = null;
    ZitlasCallUI.setActive('Connecting…');
    _callSession = ZitlasCall.answerCall({
      db: ZitlasDB, chatId: callInfo.chatId, callId: callInfo.callId, myUid: getAthleteId(), offer: callInfo.offer,
      onLocalStream:  function(stream) { ZitlasCallUI.setLocalStream(stream); },
      onRemoteStream: function(stream) { ZitlasCallUI.setRemoteStream(stream); },
      onStateChange:  function(state) {
        console.log('[CALL] state', state);
        if      (state === 'connecting')   ZitlasCallUI.setStatus('Connecting…');
        else if (state === 'connected')    ZitlasCallUI.setConnected();
        else if (state === 'disconnected') ZitlasCallUI.setStatus('Reconnecting…');
        else if (state === 'ended' || state === 'failed' || state === 'closed') {
          ZitlasCallUI.close({ message: state === 'failed' ? 'Could not connect' : 'Call ended' });
          _endCallUI();
        }
      },
    });
    /* Wire the End button for the now-active call */
    ZitlasCallUI.setHangup(function() {
      if (_callSession) _callSession.hangup();
      ZitlasCallUI.close({ message: 'Call ended' });
      _endCallUI();
    });
    var callBtn = document.getElementById('chatCallBtn');
    if (callBtn) { callBtn.classList.add('zc-call-btn--calling'); callBtn.setAttribute('aria-label', 'End call'); }
  }

  function _endCallUI() {
    _callSession = null;
    var callBtn = document.getElementById('chatCallBtn');
    if (callBtn) { callBtn.classList.remove('zc-call-btn--calling'); callBtn.setAttribute('aria-label', 'Voice call'); }
  }

  /* ══════════════════════════════════════════
     VERIFY DIET PLAN MODAL
  ══════════════════════════════════════════ */
  function initVerifyModal(coach) {
    const modal    = document.getElementById('verifyModal');
    const openBtn  = document.getElementById('verifyDietBtn');
    const closeBtn = document.getElementById('closeVerifyModal');
    const sendBtn  = document.getElementById('sendReviewBtn');
    const fileInput = document.getElementById('verifyFileInput');
    const fileName  = document.getElementById('verifyFileName');
    const feeEl     = document.getElementById('verifyFeeVal');
    if (!modal) return;

    if (feeEl) feeEl.textContent = '₹' + coach.fee;
    setText('verifyCoachTag', 'Review by ' + coach.name);

    function openModal() {
      updateChipPresence(buildContextPackage(), 'verifyCtxChips');
      modal.classList.add('open');
      document.body.style.overflow = 'hidden';
    }
    function closeModal() {
      modal.classList.remove('open');
      document.body.style.overflow = '';
    }

    if (openBtn)  openBtn.addEventListener('click', openModal);
    if (closeBtn) closeBtn.addEventListener('click', closeModal);
    modal.addEventListener('click', (e) => { if (e.target === modal) closeModal(); });
    modal.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeModal(); });

    if (fileInput) {
      fileInput.addEventListener('change', () => {
        const f = fileInput.files[0];
        if (fileName) fileName.textContent = f ? f.name : '';
      });
    }

    if (sendBtn) {
      sendBtn.addEventListener('click', () => {
        console.log('[ZITLAS] Review submit clicked — coach:', coach.id, coach.name);
        const ctx = buildContextPackage();
        const note = (document.getElementById('verifyNote')?.value || '').trim();

        console.log('[ZITLAS] Context package keys:', Object.keys(ctx).filter(function(k) { return !!ctx[k]; }));

        if (!ctx.diet_plan) {
          showToast('⚠️ No AI diet plan found. Generate your plan first.');
          console.warn('[ZITLAS] Blocked: no diet plan in context');
          return;
        }

        /* Resolve athlete name from Firebase session or localStorage */
        let athleteName = 'Athlete';
        try {
          const fbUser = JSON.parse(localStorage.getItem('zitlas_firebase_user') || 'null');
          if (fbUser && fbUser.name) athleteName = fbUser.name;
        } catch (_) {}

        const request = {
          id:           'REQ_' + Date.now(),
          athlete_name: athleteName,
          expertId:     coach.id,
          expertName:   coach.name,
          expertRole:   coach.role,
          expertImg:    coach.image,
          submittedAt:  new Date().toISOString(),
          status:       'pending',
          note:         note,
          hasFile:      !!(fileInput?.files[0]),
          fileName:     fileInput?.files[0]?.name || '',
          planId:       localStorage.getItem('zitlas_plan_id') || null,
          context: {
            assessment:   ctx.assessment,
            calculations: ctx.calculations,
            swot:         ctx.swot,
            diet_plan:    ctx.diet_plan,
            workout_plan: ctx.workout_plan,
            survey:       ctx.survey,
          },
          modifiedPlan: null,
          expertNotes:  '',
          changeCount:  0,
          approvedAt:   null,
        };

        console.log('[ZITLAS] reviewPayload:', request);

        /* Submitting a new review request invalidates any prior expert approval —
           the expert review only belongs to the exact plan version it reviewed. */
        [
          'zitlas_expert_review', 'zitlas_plan_versions',
          'expert_review', 'expert_diet_override', 'reviewed_diet_plan',
          'modifiedBy', 'expertApproval',
          'expertDiet', 'expertOverride', 'dietOverride', 'reviewStatus',
          'expertReviewedPlan', 'approvedPlan', 'expertWorkoutOverride',
        ].forEach(function (k) { localStorage.removeItem(k); });
        console.log('[ZITLAS] New review request — prior expert modifications cleared');

        try {
          localStorage.setItem('zitlas_review_request', JSON.stringify(request));
          console.log('[ZITLAS] Saved to localStorage key: zitlas_review_request');
        } catch(e) {
          console.error('[ZITLAS] localStorage save failed:', e);
        }

        /* Inject the review packet as msg[0] of the conversation so both sides share it */
        var reviewConvId = ensureConversation(coach.id, coach.name);
        var _reviewPacket = persistReviewPacket(reviewConvId, request);
        if (_reviewPacket) {
          console.log('[ATTACHMENT] syncing review packet to Firestore', _reviewPacket.id);
          _cpSyncChatMessageToFirestore(reviewConvId, getAthleteId(), coach.id, _reviewPacket);
        }

        /* Also persist to Firestore for real-time cross-device sync */
        if (typeof ZitlasDB !== 'undefined') {
          try {
            const firestoreDoc = Object.assign({}, request, {
              created_at: firebase.firestore.FieldValue.serverTimestamp(),
            });
            ZitlasDB.collection('review_requests').doc(request.id).set(firestoreDoc)
              .catch(function(e) { console.warn('[ZITLAS] Firestore review save failed:', e); });
          } catch (_) {}
        }

        sendBtn.textContent = 'Sent ✓';
        sendBtn.disabled = true;
        setTimeout(() => {
          closeModal();
          sendBtn.textContent = 'Send for Review →';
          sendBtn.disabled = false;
          showToast('Your plan has been sent for expert review.');
        }, 900);
      });
    }
  }

  /* ══════════════════════════════════════════
     DIET STORAGE HELPERS (new schema)
  ══════════════════════════════════════════ */
  function _cpMealKey(name) {
    return (name || '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '_');
  }

  /* See diet.js's _mealsToArray — days[].meals is canonically an array,
     but reviews saved by modify-diet.js before its schema fix stored an
     object keyed by meal name. Normalize defensively so this listener
     (which runs automatically on every Firestore snapshot) never throws. */
  function _cpMealsToArray(meals) {
    if (Array.isArray(meals)) return meals;
    if (meals && typeof meals === 'object') return Object.values(meals);
    return [];
  }

  function _cpFindMealByKey(meals, mealKey) {
    var arr = _cpMealsToArray(meals);
    for (var i = 0; i < arr.length; i++) {
      var m = arr[i];
      if ((m._mealKey || _cpMealKey(m.meal_name || m.name)) === mealKey) return m;
    }
    return null;
  }

  function isNewDietSchema(obj) {
    return !!(obj && obj.originalDietPlan && obj.currentDietPlan);
  }

  function _cpSaveDietStorage(storage) {
    try { localStorage.setItem('zitlas_diet_plan', JSON.stringify(storage)); } catch (_) {}
  }

  /* Build the {originalDietPlan, currentDietPlan, expertModifications, isExpertPlan} schema
     from an expert review object. Uses mealChangeHistory if present; falls back to _edited flags. */
  function _buildDietStorageFromReview(review) {
    var _expName    = review.expertName || review.expert_name || 'Expert';
    var _reviewedAt = review.reviewedAt || new Date().toISOString();

    /* Resolve original plan — unwrap if it was stored in new-schema format */
    var _contextPlan = review.planData || null;
    if (_contextPlan && (_contextPlan.originalDietPlan || _contextPlan.currentDietPlan)) {
      _contextPlan = _contextPlan.originalDietPlan || _contextPlan.currentDietPlan;
    }
    var _originalPlan = _contextPlan || null;

    /* Build expertModifications */
    var _mods    = {};
    var _history = review.mealChangeHistory || review.meal_change_history || [];

    if (_history.length > 0) {
      _history.forEach(function (change) {
        var _dk      = String(change.dayIndex != null ? change.dayIndex : (change.day_index != null ? change.day_index : 0));
        var _rawName = change.mealName || change.meal_name || change.name || '';
        var _mk      = _cpMealKey(_rawName);
        if (!_mods[_dk]) _mods[_dk] = {};
        _mods[_dk][_mk] = {
          modified:   true,
          modifiedBy: change.modifiedBy || change.modified_by || _expName,
          modifiedAt: change.modifiedAt || change.modified_at || _reviewedAt,
          oldMeal: { foods: change.oldFoods || change.old_foods || [], calories: change.oldCalories || null, protein_g: change.oldProtein || null },
          newMeal: { foods: change.newFoods || change.new_foods || [], calories: change.newCalories || null, protein_g: change.newProtein || null },
        };
      });
    }

    /* Always scan reviewedDietPlan for _edited meals.
       Creates entries for meals missed by mealChangeHistory, and fixes empty newFoods
       from history entries (reviewedDietPlan is authoritative for what the expert changed). */
    if (review.reviewedDietPlan) {
      var reviewedPlan = review.reviewedDietPlan;
      console.log('[REVIEWED PLAN]', reviewedPlan);
      var _revDays  = reviewedPlan.days || [];
      var _origDays = _originalPlan ? (_originalPlan.days || []) : [];
      _revDays.forEach(function (revDay, dayIdx) {
        console.log('[DAY]', revDay);
        console.log('[MEALS]', revDay.meals);
        console.log('[TYPE]', typeof revDay.meals);
        console.log('[IS ARRAY]', Array.isArray(revDay.meals));
        var _revMealsArr = _cpMealsToArray(revDay.meals);
        _revMealsArr.forEach(function (revMeal) {
          if (!revMeal._edited) return;
          var _mealName = revMeal.meal_name || revMeal.name || '';
          var _dk       = String(dayIdx);
          var _mk       = revMeal._mealKey || _cpMealKey(_mealName);
          var _origDay  = _origDays[dayIdx];
          var _origMeal = _origDay ? _cpFindMealByKey(_origDay.meals, _mk) : null;
          if (!_mods[_dk]) _mods[_dk] = {};
          if (!_mods[_dk][_mk]) {
            /* Entry not built from history — create from _edited flag */
            _mods[_dk][_mk] = {
              modified:   true,
              modifiedBy: _expName,
              modifiedAt: _reviewedAt,
              oldMeal: _origMeal
                ? { foods: _origMeal.foods || [], calories: _origMeal.calories || null, protein_g: _origMeal.protein_g || null }
                : { foods: [] },
              newMeal: { foods: revMeal.foods || [], calories: revMeal.calories || null, protein_g: revMeal.protein_g || null },
            };
          } else {
            /* Entry exists from history — fix foods if history had empty newFoods */
            if (!_mods[_dk][_mk].newMeal) _mods[_dk][_mk].newMeal = {};
            if (!_mods[_dk][_mk].newMeal.foods || !_mods[_dk][_mk].newMeal.foods.length) {
              _mods[_dk][_mk].newMeal.foods = revMeal.foods || [];
            }
            if (!_mods[_dk][_mk].newMeal.calories && revMeal.calories) {
              _mods[_dk][_mk].newMeal.calories = revMeal.calories;
            }
            if (!_mods[_dk][_mk].newMeal.protein_g && revMeal.protein_g) {
              _mods[_dk][_mk].newMeal.protein_g = revMeal.protein_g;
            }
          }
        });
      });
    }

    return {
      originalDietPlan:    _originalPlan || review.reviewedDietPlan,
      currentDietPlan:     _originalPlan || review.reviewedDietPlan,
      expertModifications: _mods,
      isExpertPlan:        true,
      expertName:          _expName,
      expertId:            review.expertId || null,
      expertNotes:         review.expertNotes || null,
      reviewedAt:          _reviewedAt,
      reviewStatus:        'completed',
      planSource:          'expert_reviewed',
      reviewId:            review.id || null,
      version:             review.version || 1,
      lastUpdated:         new Date().toISOString(),
      /* Goal-identity stamp — diet.js refuses to render an expert layer
         that can't prove it belongs to the current plan generation. */
      planId:              review.planId || localStorage.getItem('zitlas_plan_id') || null,
    };
  }

  function _cpSaveWorkoutStorage(storage) {
    console.log("[_cpSaveWorkoutStorage] workoutModifications", storage.workoutModifications);
    try {
      localStorage.setItem('zitlas_workout_plan', JSON.stringify(storage));
    } catch (saveErr) {
      console.error("[_cpSaveWorkoutStorage] SAVE FAILED", saveErr);
    }
    var _savedWp = JSON.parse(localStorage.getItem('zitlas_workout_plan') || 'null');
    console.log("[_cpSaveWorkoutStorage] AFTER SAVE workoutModifications", _savedWp ? _savedWp.workoutModifications : undefined);
  }

  /* Build {originalWorkoutPlan, currentWorkoutPlan, workoutModifications} from a workout review */
  function _buildWorkoutStorageFromReview(review) {
    /* Migrate: if reviewedWorkoutPlan is missing, fall back to planData */
    if (!review.reviewedWorkoutPlan && review.planData) {
      review.reviewedWorkoutPlan = review.planData;
    }
    if (!review.workoutChangeHistory) {
      review.workoutChangeHistory = [];
    }

    console.log("REVIEW OBJECT", review);
    console.log("WORKOUT HISTORY", review.workoutChangeHistory);
    console.log("[BUILD WORKOUT STORAGE] reviewedWorkoutPlan present:", !!review.reviewedWorkoutPlan);

    var _expName    = review.expertName || review.expert_name || 'Expert';
    var _reviewedAt = review.reviewedAt || new Date().toISOString();

    /* Resolve original plan */
    var _contextPlan = review.planData || null;
    if (_contextPlan && (_contextPlan.originalWorkoutPlan || _contextPlan.currentWorkoutPlan)) {
      _contextPlan = _contextPlan.originalWorkoutPlan || _contextPlan.currentWorkoutPlan;
    }
    var _originalPlan = _contextPlan || null;
    console.log("[BUILD WORKOUT STORAGE] _originalPlan", _originalPlan);

    /* Build workoutModifications from workoutChangeHistory */
    var _mods    = {};
    var _history = review.workoutChangeHistory || [];

    _history.forEach(function(change) {
      var _dk = String(change.dayIndex != null ? change.dayIndex : 0);
      _mods[_dk] = {
        modified:   true,
        modifiedBy: change.modifiedBy || _expName,
        modifiedAt: change.modifiedAt || _reviewedAt,
        oldWorkout: change.oldWorkout || null,
        newWorkout: change.newWorkout || null,
      };
    });

    /* Always also scan reviewedWorkoutPlan for _edited days */
    if (review.reviewedWorkoutPlan) {
      var _revDays  = review.reviewedWorkoutPlan.weekly_plan || review.reviewedWorkoutPlan.days || [];
      var _origDays = _originalPlan ? (_originalPlan.weekly_plan || _originalPlan.days || []) : [];
      _revDays.forEach(function(revDay, dayIdx) {
        if (!revDay._edited) return;
        var _dk     = String(dayIdx);
        var origDay = _origDays[dayIdx];
        if (!_mods[_dk]) {
          _mods[_dk] = {
            modified:   true,
            modifiedBy: _expName,
            modifiedAt: _reviewedAt,
            oldWorkout: origDay ? {
              focus: origDay.focus || origDay.type || '',
              duration_minutes: origDay.duration_minutes || 0,
              exercises: (origDay.exercises || []).map(function(e) {
                return { name: e.name, sets: e.sets, reps_or_duration: e.reps_or_duration };
              }),
            } : null,
            newWorkout: {
              focus: revDay.focus || revDay.type || '',
              duration_minutes: revDay.duration_minutes || 0,
              exercises: (revDay.exercises || []).map(function(e) {
                return { name: e.name, sets: e.sets, reps_or_duration: e.reps_or_duration };
              }),
            },
          };
        } else {
          /* Fix empty exercises in existing history entry */
          if (!_mods[_dk].newWorkout) _mods[_dk].newWorkout = {};
          if (!_mods[_dk].newWorkout.exercises || !_mods[_dk].newWorkout.exercises.length) {
            _mods[_dk].newWorkout.exercises = (revDay.exercises || []).map(function(e) {
              return { name: e.name, sets: e.sets, reps_or_duration: e.reps_or_duration };
            });
          }
        }
      });
    }

    console.log("[BUILD WORKOUT STORAGE] _mods built from history", _mods);
    console.log("[BUILD WORKOUT STORAGE] workoutChangeHistory length", _history.length);
    console.log("[BUILD WORKOUT STORAGE] reviewedWorkoutPlan days with _edited",
      review.reviewedWorkoutPlan
        ? (review.reviewedWorkoutPlan.weekly_plan || review.reviewedWorkoutPlan.days || [])
            .filter(function(d) { return d._edited; }).length
        : 0);

    return {
      originalWorkoutPlan:  _originalPlan || review.reviewedWorkoutPlan,
      currentWorkoutPlan:   _originalPlan || review.reviewedWorkoutPlan,
      workoutModifications: _mods,
      isExpertPlan:         true,
      expertName:           _expName,
      reviewedAt:           _reviewedAt,
      /* Goal-identity stamp — weekly-plan.js/day.js refuse to render an
         expert layer that can't prove it belongs to the current plan. */
      planId:               review.planId || localStorage.getItem('zitlas_plan_id') || null,
    };
  }

  /* HTML comparison view for workout plans */
  function buildWorkoutComparisonPlanHTML(plan, originalPlan) {
    if (!plan) return '<p class="rc-no-data">Workout plan not available.</p>';
    /* Unwrap new schema {originalWorkoutPlan, currentWorkoutPlan, ...} so we can reach the day array */
    if (plan.originalWorkoutPlan || plan.currentWorkoutPlan) {
      plan = plan.currentWorkoutPlan || plan.originalWorkoutPlan;
    }
    if (originalPlan && (originalPlan.originalWorkoutPlan || originalPlan.currentWorkoutPlan)) {
      originalPlan = originalPlan.currentWorkoutPlan || originalPlan.originalWorkoutPlan;
    }
    var days = plan.weekly_plan || plan.days || [];
    if (!days.length) return '<p class="rc-no-data">No workout data.</p>';
    var origDays = originalPlan ? (originalPlan.weekly_plan || originalPlan.days || []) : [];
    var labels = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

    var pills = '<div class="erc-day-pills">';
    days.forEach(function(d, i) {
      pills += '<button class="erc-day-pill' + (i === 0 ? ' active' : '') +
        '" data-rc-day-pill="' + i + '">' + (labels[i] || 'D'+(i+1)) + '</button>';
    });
    pills += '</div>';

    var content = '';
    days.forEach(function(day, di) {
      var origDay   = origDays[di] || {};
      var isEdited  = !!day._edited;
      var focus     = day.focus || day.type || 'Training';
      var origFocus = origDay.focus || origDay.type || '';
      var duration  = day.duration_minutes ? day.duration_minutes + ' min' : '';
      content += '<div data-rc-day-content="' + di + '" style="display:' + (di === 0 ? 'block' : 'none') + '">';
      content += '<div class="erc-day-theme' + (isEdited ? ' rc-meal-edited' : '') + '">' +
        (isEdited && origFocus && origFocus !== focus
          ? '<span style="text-decoration:line-through;opacity:.6">' + esc(origFocus) + '</span> → ' : '') +
        esc(focus) +
        (duration ? ' <span class="erc-meal-time">· ' + esc(duration) + '</span>' : '') +
        (isEdited ? '<span class="rc-edited-badge">✏ Edited by Expert</span>' : '') +
      '</div>';
      (day.exercises || []).forEach(function(ex) {
        var exEdited = !!ex._edited;
        content += '<div class="erc-meal-row' + (exEdited ? ' rc-meal-edited' : '') + '">' +
          '<div class="erc-meal-hdr">' +
            '<span class="erc-meal-name">💪 ' + esc(ex.name || 'Exercise') + '</span>' +
            (ex.sets ? '<span class="erc-meal-time">' + esc(String(ex.sets)) + ' sets' +
              (ex.reps_or_duration ? ' × ' + esc(ex.reps_or_duration) : '') + '</span>' : '') +
            (exEdited ? '<span class="rc-edited-badge">✏ Edited</span>' : '') +
          '</div>' +
          (ex.tip ? '<div class="erc-meal-foods">📝 ' + esc(ex.tip) + '</div>' : '') +
        '</div>';
      });
      content += '</div>';
    });

    return pills + content;
  }

  /* ══════════════════════════════════════════
     REVIEW COMPARISON SHEET (athlete side)
  ══════════════════════════════════════════ */
  function openReviewComparisonSheet(coach, reviewOverride) {
    var sheet = document.getElementById('rcSheet');
    if (!sheet) return;

    /* Always re-fetch the review from localStorage FIRST.
       reviewOverride is a closure var captured at render-time — it will be stale if the expert
       saved reviewedWorkoutPlan / workoutChangeHistory after this page was loaded.
       Using the stale object means _displayReviewedPlan, _isWorkout, and the accept handler
       all operate on wrong data. */
    var _rcAllFreshRevs = [];
    try { _rcAllFreshRevs = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]'); } catch (_e) {}
    var review;
    if (reviewOverride && reviewOverride.id) {
      review = _rcAllFreshRevs.find(function(r) { return r.id === reviewOverride.id; }) || reviewOverride;
    } else {
      review = _getMyLatestPlanReview(coach);
    }

    /* Diagnosis logs */
    console.log("[openRC] fresh review", review);
    console.log("[openRC] reviewedWorkoutPlan present:", !!(review && review.reviewedWorkoutPlan));
    console.log("[openRC] workoutChangeHistory", review && review.workoutChangeHistory);
    var _wpRaw = JSON.parse(localStorage.getItem("zitlas_workout_plan") || 'null');
    console.log("[openRC] zitlas_workout_plan.workoutModifications", _wpRaw ? _wpRaw.workoutModifications : undefined);

    /* Detect workout reviews — normalise planReviewType (old) vs reviewType (new) */
    var _effectiveType = review && (review.reviewType || review.planReviewType || '');
    var _isWorkout = _effectiveType === 'workout' ||
      (_effectiveType === '' && !!(review && review.reviewedWorkoutPlan));
    /* Fall back to planData when expert marked as reviewed without explicitly saving
       (covers old reviews completed via "Mark as Reviewed" before the fix) */
    var _reviewedPlan = _isWorkout
      ? (review && (review.reviewedWorkoutPlan || review.planData))
      : (review && (review.reviewedDietPlan   || review.planData));
    console.log("ACCEPT WORKOUT REVIEW — review", review);
    console.log("ACCEPT WORKOUT REVIEW — _isWorkout", _isWorkout, "| _reviewedPlan", !!_reviewedPlan);
    if (!review || !_reviewedPlan) {
      showToast('Expert review is not available yet.');
      return;
    }

    var expertName = review.expertName || 'Expert';
    var reviewType = review.reviewType || review.planReviewType || 'diet';

    /* ── Populate tabs ── */
    var originalTab  = document.getElementById('rcTabOriginal');
    var reviewedTab  = document.getElementById('rcTabReviewed');
    var originalPane = document.getElementById('rcPaneOriginal');
    var reviewedPane = document.getElementById('rcPaneReviewed');
    var titleEl      = document.getElementById('rcTitle');
    var acceptBtn    = document.getElementById('rcAcceptBtn');

    console.log('[RC SETUP] acceptBtn found:', !!acceptBtn, '| _isWorkout:', _isWorkout);

    if (titleEl) titleEl.textContent = expertName + '\'s Review';

    var _displayReviewedPlan = _isWorkout
      ? (review.reviewedWorkoutPlan || review.planData)
      : (review.reviewedDietPlan   || review.planData);

    /* Build HTML inside its own try/catch — a rendering crash must NOT prevent acceptBtn wiring */
    try {
      if (originalPane) {
        originalPane.innerHTML = _isWorkout
          ? buildWorkoutComparisonPlanHTML(review.planData, null)
          : buildComparisonPlanHTML(review.planData, null, reviewType);
      }
      if (reviewedPane) {
        reviewedPane.innerHTML = _isWorkout
          ? buildWorkoutComparisonPlanHTML(_displayReviewedPlan, review.planData)
          : buildComparisonPlanHTML(_displayReviewedPlan, review.planData, reviewType);
      }
    } catch (_renderErr) {
      console.error('[RC SETUP] HTML build crashed — acceptBtn will still be wired:', _renderErr);
      if (originalPane) originalPane.innerHTML = '<p class="rc-no-data">Preview unavailable.</p>';
      if (reviewedPane) reviewedPane.innerHTML = '<p class="rc-no-data">Preview unavailable.</p>';
    }

    /* Tab switching */
    function setTab(tab) {
      [originalTab, reviewedTab].forEach(function(t) { if (t) t.classList.remove('rc-tab--active'); });
      [originalPane, reviewedPane].forEach(function(p) { if (p) p.style.display = 'none'; });
      if (tab === 'original') {
        if (originalTab) originalTab.classList.add('rc-tab--active');
        if (originalPane) originalPane.style.display = '';
      } else {
        if (reviewedTab) reviewedTab.classList.add('rc-tab--active');
        if (reviewedPane) reviewedPane.style.display = '';
      }
    }
    if (originalTab) originalTab.onclick = function() { setTab('original'); };
    if (reviewedTab) reviewedTab.onclick = function() { setTab('reviewed'); };
    setTab('reviewed');

    /* Day-pill wiring inside each pane */
    [originalPane, reviewedPane].forEach(function(pane) {
      if (!pane) return;
      pane.querySelectorAll('[data-rc-day-pill]').forEach(function(pill) {
        pill.addEventListener('click', function() {
          var idx = parseInt(pill.dataset.rcDayPill, 10);
          pane.querySelectorAll('[data-rc-day-pill]').forEach(function(p) { p.classList.remove('active'); });
          pill.classList.add('active');
          pane.querySelectorAll('[data-rc-day-content]').forEach(function(c) {
            c.style.display = parseInt(c.dataset.rcDayContent, 10) === idx ? 'block' : 'none';
          });
        });
      });
    });

    /* Accept Changes */
    console.log('[RC SETUP] wiring acceptBtn.onclick now');
    if (acceptBtn) {
      acceptBtn.onclick = function() {
        console.log("RC ACCEPT CLICKED");
        console.log("ACCEPTING WORKOUT REVIEW", review);
        console.log("HISTORY", review.workoutChangeHistory);
        console.log("STORAGE BEFORE", JSON.parse(localStorage.getItem("zitlas_workout_plan") || 'null'));

        if (_isWorkout) {
          try {
            /* Unwrap new schema if planData was saved in new format */
            var _rawPlanData = review.planData || null;
            if (_rawPlanData && (_rawPlanData.originalWorkoutPlan || _rawPlanData.currentWorkoutPlan)) {
              _rawPlanData = _rawPlanData.currentWorkoutPlan || _rawPlanData.originalWorkoutPlan;
            }

            var workoutMods = {};
            (review.workoutChangeHistory || []).forEach(function(change) {
              if (change.dayIndex == null) return;
              workoutMods[String(change.dayIndex)] = {
                modified:   true,
                modifiedBy: change.modifiedBy || review.expertName || 'Expert',
                modifiedAt: change.modifiedAt || review.reviewedAt || new Date().toISOString(),
                oldWorkout: change.oldWorkout || null,
                newWorkout: change.newWorkout || null,
              };
            });

            console.log("NEW MODS", workoutMods);

            var _storage = {
              originalWorkoutPlan:  _rawPlanData || review.reviewedWorkoutPlan || null,
              currentWorkoutPlan:   _rawPlanData || review.reviewedWorkoutPlan || null,
              workoutModifications: workoutMods,
              workoutChangeHistory: review.workoutChangeHistory || [],
              isExpertPlan:         true,
              expertName:           review.expertName || 'Expert',
              reviewedAt:           review.reviewedAt || new Date().toISOString(),
              planId:               review.planId || localStorage.getItem('zitlas_plan_id') || null,
            };

            localStorage.setItem('zitlas_workout_plan', JSON.stringify(_storage));
            console.log("STORAGE AFTER", JSON.parse(localStorage.getItem("zitlas_workout_plan") || 'null'));
          } catch (_err) {
            console.error("WORKOUT ACCEPT ERROR", _err);
          }
        } else {
          var _builtStorage = _buildDietStorageFromReview(review);
          _cpSaveDietStorage(_builtStorage);
        }

        /* Mark athlete_accepted — always runs */
        var _all = [];
        try { _all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]'); } catch (_) {}
        var _ai = _all.findIndex(function(r) { return r.id === review.id; });
        if (_ai !== -1) {
          _all[_ai].athleteAccepted = true;
          _all[_ai].acceptedAt      = _all[_ai].acceptedAt || new Date().toISOString();
          try { localStorage.setItem('expert_plan_reviews', JSON.stringify(_all)); } catch (_) {}
        }

        closeComparisonSheet();
        showToast(_isWorkout
          ? '✅ Expert\'s workout plan has been applied!'
          : '✅ Expert\'s plan has been applied to your profile.');
        updateVerifyBtnState(coach);
      };
    } else {
      console.error('[RC SETUP] rcAcceptBtn not found in DOM — onclick cannot be wired');
    }

    function closeComparisonSheet() {
      sheet.classList.remove('open');
      document.body.style.overflow = '';
    }

    var closeBtn = document.getElementById('rcCloseBtn');
    if (closeBtn) closeBtn.onclick = closeComparisonSheet;
    sheet.addEventListener('click', function(e) { if (e.target === sheet) closeComparisonSheet(); });

    sheet.classList.add('open');
    document.body.style.overflow = 'hidden';
  }

  function buildComparisonPlanHTML(plan, originalPlan, reviewType) {
    if (!plan) return '<p class="rc-no-data">Plan not available.</p>';
    var days = plan.days || [];
    if (!days.length) return '<p class="rc-no-data">No plan data.</p>';
    var origDays = (originalPlan && originalPlan.days) || [];
    var labels = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

    var pills = '<div class="erc-day-pills">';
    days.forEach(function(d, i) {
      pills += '<button class="erc-day-pill' + (i === 0 ? ' active' : '') + '" data-rc-day-pill="' + i + '">' + (labels[i] || 'D'+(i+1)) + '</button>';
    });
    pills += '</div>';

    var content = '';
    days.forEach(function(day, di) {
      content += '<div data-rc-day-content="' + di + '" style="display:' + (di === 0 ? 'block' : 'none') + '">';
      if (day.total_calories) content += '<div class="erc-day-total">' + day.total_calories + ' kcal total</div>';
      var origMeals = (origDays[di] && origDays[di].meals) || [];
      (day.meals || []).forEach(function(meal, mi) {
        var wasEdited = meal._edited;
        var origMeal  = origMeals[mi];
        var foods = Array.isArray(meal.foods) ? meal.foods.join(', ') : (meal.food_items || '');
        var meta  = [meal.calories ? meal.calories + ' kcal' : '', meal.protein_g ? meal.protein_g + 'g protein' : ''].filter(Boolean).join(' · ');

        content += '<div class="erc-meal-row' + (wasEdited ? ' rc-meal-edited' : '') + '">';
        content += '<div class="erc-meal-hdr">';
        content += '<span class="erc-meal-emoji">' + esc(meal.emoji || '🍽️') + '</span>';
        content += '<span class="erc-meal-name">' + esc(meal.meal_name || 'Meal') + '</span>';
        if (meal.time) content += '<span class="erc-meal-time">' + esc(meal.time) + '</span>';
        if (wasEdited) content += '<span class="rc-edited-badge">✏ Edited by Expert</span>';
        content += '</div>';
        if (foods) content += '<div class="erc-meal-foods">' + esc(foods) + '</div>';
        if (meta)  content += '<div class="erc-meal-meta">' + esc(meta) + '</div>';
        if (meal.notes) content += '<div class="rc-meal-notes">📝 ' + esc(meal.notes) + '</div>';
        content += '</div>';
      });
      content += '</div>';
    });

    return pills + content;
  }

  /* ══════════════════════════════════════════
     VERIFY PLAN — status-aware button + bottom sheet
  ══════════════════════════════════════════ */

  /*
   * Canonical review statuses (athlete-side mirror of expert-dashboard):
   *   pending          — submitted, waiting for expert
   *   in_progress      — expert has opened/accepted
   *   review_completed — expert finished, plan delivered
   *   rejected         — expert rejected
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

  /* SVG icons shared between updateVerifyBtnState and the button */
  var VP_SVG = {
    check:   '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/></svg>',
    clock:   '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>',
    chat:    '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>',
    fileDoc: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/></svg>',
  };

  function _getMyUserId() {
    /* Live Firebase session is authoritative — cached uid can be stale */
    if (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) {
      return ZitlasAuth.currentUser.uid;
    }
    var uid = null;
    try {
      var fbUser = JSON.parse(localStorage.getItem('zitlas_firebase_user') || 'null');
      if (fbUser && fbUser.uid) uid = fbUser.uid;
    } catch (_) {}
    return uid || localStorage.getItem('zitlas_athlete_id') || null;
  }

  /* ══════════════════════════════════════════
     VERIFICATION STATE — SINGLE SOURCE OF TRUTH
     The Verify Plan button (and its withdraw / re-request companions)
     derive their state EXCLUSIVELY from: current user uid + current
     expert uid + the newest review_request's status, interpreted by the
     explicit whitelist below. Document existence alone never means
     anything, and no status outside the whitelist may ever produce a
     blocking/"Under Review" UI.

     Status machine (spec: the ONLY allowed states):
       ACTIVE   — pending / accepted / in_progress / expert_reviewing
                  → blocking UI (Review Requested / Chat / Reviewing…)
       TERMINAL-RENDERABLE — completed / review_completed / rejected
                  → informational UI WITH a re-request path
       EVERYTHING ELSE — withdrawn, superseded, dismissed, declined,
                  expired, cancelled, ended, or any unknown/missing
                  status → treated as NO REQUEST → "Request Review".

     THE BUG THIS FIXES: the old fallback here was a BLOCKLIST
     (`status !== 'superseded' && status !== 'withdrawn'`) — every other
     historical/terminal status fell through to updateVerifyBtnState's
     catch-all branch, which rendered a permanently disabled "Under
     Review" with no re-request path. The killer instance: Goal Reset
     (assets/js/coaching-reset.js) marks every live review_requests doc
     'dismissed' — a status introduced AFTER this blocklist was written —
     so any athlete who had ever had a review/chat request and then reset
     their goal saw "Under Review" forever, on every refresh, with no
     verification request active at all (the doc re-synced from Firestore
     into the expert_plan_reviews cache on every page load, so clearing
     localStorage couldn't help either). A blocklist can never be correct
     here: any NEW terminal status ever written by any other feature
     recreates the bug. Hence the whitelist. */
  var _VP_ACTIVE_STATUSES   = ['pending', 'accepted', 'in_progress', 'expert_reviewing'];
  var _VP_TERMINAL_RENDERED = ['completed', 'review_completed', 'rejected'];

  function _getAllMyPlanReviews(coach) {
    var reviews = [];
    try { reviews = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]'); } catch (_) {}
    var uid = _getMyUserId();
    /* Fail-closed identity: no signed-in uid, or a cached doc without a
       userId stamp, matches NOTHING — a stale cache entry from another
       account/session on a shared device must never drive this UI. */
    if (!uid) return [];
    return reviews.filter(function(r) {
      return r && r.expertId === coach.id && r.userId === uid;
    });
  }

  /* Returns the single newest review whose status is renderable (active OR
     terminal) — used for DISPLAY. THE BUG THIS FIXES: this used to do two
     separate .find() passes — "any active review, any vintage" first, THEN
     fall back to terminal — so an OLDER review still sitting in an active
     status (most commonly a "Both" bundle's ₹0 workout sibling, which mirrors
     to an active status on accept but is only marked review_completed
     separately from its diet sibling) could shadow a NEWER review that had
     already reached review_completed. The athlete would see "Expert
     Reviewing…" forever even though their most recent request was actually
     done — this is the exact same class of non-determinism bug the sort
     below already fixed once (an old doc winning over a newer one), just
     reintroduced by prioritizing "any active" over "newest" instead of
     prioritizing document order over recency. One pass, by recency, across
     the full renderable set, matches this function's own name: the LATEST
     review, whatever its status. */
  function _getMyLatestPlanReview(coach) {
    var all = _getAllMyPlanReviews(coach);
    if (!all.length) return null;
    /* Newest-first — .find() on Firestore's unordered snapshot echo was
       the same non-determinism bug the Personal Coaching button had:
       whichever doc happened to sit first in the array won, letting an
       old doc shadow the request's real, newer lifecycle state. */
    var sorted = all.slice().sort(function(a, b) {
      return new Date(b.createdAt || b.submittedAt || 0) -
             new Date(a.createdAt || a.submittedAt || 0);
    });
    var _renderable = _VP_ACTIVE_STATUSES.concat(_VP_TERMINAL_RENDERED);
    /* Everything else (withdrawn, superseded, dismissed, declined, expired,
       cancelled, ended, unknown/missing) is dead history — "no request". */
    return sorted.find(function(r) {
      return _renderable.indexOf(r.status) !== -1;
    }) || null;
  }

  /* Retry entry point for a review the expert already accepted but whose
     wallet check failed at that moment — same shared, idempotent
     ZitlasPayment.attemptCharge() transaction as the expert's own
     auto-attempt, just re-run from the athlete's own session after they've
     recharged. */
  function _retryReviewPayment(review, coach) {
    if (typeof ZitlasPayment === 'undefined') {
      showToast('Unable to process payment — please try again.');
      return;
    }
    var uid       = _getMyUserId();
    var amount    = Number(review.totalPrice) || 0;
    var isChatOnly = review.reviewType === 'chat_only';
    var chatIncluded = review.serviceType
      ? (review.serviceType === 'chat' || review.serviceType === 'verification_chat')
      : true;
    var serviceLabel = isChatOnly ? 'Expert Chat' : (review.reviewType === 'workout' ? 'Workout Review' : 'Diet Review');

    showToast('Processing payment…');
    ZitlasPayment.attemptCharge({
      userId: uid, expertId: review.expertId, amount: amount,
      serviceType: isChatOnly ? 'chat' : 'review', serviceLabel: serviceLabel, expertName: review.expertName,
      requestCollection: 'review_requests', requestId: review.id,
      /* "Both" bundle sibling is mirrored to the paid outcome SERVER-SIDE by
         /api/payment/charge (no client paymentStatus:'paid' write — that flag
         is now backend-only on review_requests). */
      siblingRequestId: review.siblingId || null,
      onSuccessUpdate: { status: 'in_progress', chatUnlocked: chatIncluded },
      notifyUser: { title: 'Payment successful', message: 'Your ' + serviceLabel.toLowerCase() + ' has started.' },
      notifyExpert: { title: 'Payment received', message: (review.userName || 'An athlete') + "'s payment succeeded — you may begin." },
    }).then(function (result) {
      if (result.success) {
        showToast('✅ Payment successful!');
        updateVerifyBtnState(coach);
      } else if (result.error === 'insufficient_balance') {
        ZitlasPayment.showLowBalancePopup({ balance: result.balance, required: result.required, walletDocStatus: result.walletDocStatus });
      } else {
        console.error('[REVIEW] retry payment failed', result);
        showToast('Could not process payment — please try again.');
      }
    });
  }

  function updateVerifyBtnState(coach) {
    var btn          = document.getElementById('verifyPlanBtn');
    var againWrap    = document.getElementById('verifyAgainWrap');
    var withdrawWrap = document.getElementById('withdrawWrap');
    var prevSection  = document.getElementById('prevReviewsSection');
    if (!btn) return;

    var allRevs = _getAllMyPlanReviews(coach);
    var review  = _getMyLatestPlanReview(coach);

    /* Reset secondary elements */
    if (againWrap)    againWrap.style.display    = 'none';
    if (withdrawWrap) withdrawWrap.style.display = 'none';
    if (prevSection)  prevSection.style.display  = 'none';
    btn.disabled = false;

    /* Step-4 debug trace — states exactly which document and status drove
       this render, or why the idle state was chosen. */
    console.log('[VERIFY BTN DEBUG]',
      '\n  Current User:', _getMyUserId(),
      '\n  Current Expert:', coach.id,
      '\n  Source: localStorage expert_plan_reviews (echo of Firestore review_requests where userId==uid)',
      '\n  Cached docs for this expert:', allRevs.length,
      allRevs.map(function(r) { return (r.id || '?') + ':' + (r.status || 'NO_STATUS'); }),
      '\n  Selected:', review ? (review.id + ' status=' + review.status) : 'none',
      '\n  Reason:', review
        ? 'newest doc whose status is in the active/terminal whitelist'
        : 'no doc in an active or renderable-terminal status — idle "Request Review"');

    if (!review) {
      btn.dataset.vpStatus = '';
      btn.className = 'cp-cta cp-cta--verify';
      btn.innerHTML = VP_SVG.check + ' Request Review';
      return;
    }

    var st = review.status;
    btn.dataset.vpStatus = st;

    /* Temporary diagnostic — remove once the athlete-side stale-status
       investigation is closed. review_requests/{id}.status is the ONLY
       field driving this render; requestId/expertId/athleteId identify
       exactly which doc and pairing produced it. */
    console.log('[REVIEW STATUS]',
      'requestId=' + review.id,
      'firestoreStatus=' + review.status,
      'expertId=' + review.expertId,
      'athleteId=' + review.userId,
      'resolvedUiStatus=' + st);

    if (st === 'pending') {
      btn.disabled  = true;
      btn.className = 'cp-cta cp-cta--verify cp-cta--vp-pending';
      btn.innerHTML = VP_SVG.clock + ' Review Requested';
      /* Pending is the ONLY state that offers withdrawal (explicit 'block' —
         the stylesheet class is display:none) */
      if (withdrawWrap) withdrawWrap.style.display = 'block';
    } else if (st === 'accepted' && review.paymentStatus === 'awaiting_payment') {
      /* Expert already accepted, but the wallet check failed at that
         moment — same recovery pattern as Personal Coaching: a visible
         "Complete Payment" action the athlete can retry after recharging. */
      btn.className = 'cp-cta cp-cta--verify cp-cta--vp-accepted';
      btn.innerHTML = VP_SVG.check + ' Complete Payment ₹' + (review.totalPrice || 0);
    } else if (st === 'accepted') {
      /* backward-compat: reviews created before per-service pricing have no
         chatUnlocked field at all — treat that as chat-allowed (unchanged
         behavior). Only an explicit false (verification-only purchase)
         blocks chat. */
      var _chatOk = review.chatUnlocked !== false;
      btn.className = 'cp-cta cp-cta--verify cp-cta--vp-accepted';
      if (_chatOk) {
        btn.innerHTML = VP_SVG.chat + ' Chat with Expert';
      } else {
        btn.disabled  = true;
        btn.innerHTML = VP_SVG.check + ' Accepted — Review in Progress';
      }
    } else if (st === 'in_progress' || st === 'expert_reviewing') {
      btn.disabled  = true;
      btn.className = 'cp-cta cp-cta--verify cp-cta--vp-pending';
      btn.innerHTML = VP_SVG.clock + ' Expert Reviewing…';
    } else if (st === 'completed' || st === 'review_completed') {
      btn.disabled  = true;
      btn.className = 'cp-cta cp-cta--verify cp-cta--vp-done';
      btn.innerHTML = VP_SVG.check + ' Expert Reviewed';
      /* Terminal state: the main button is a status label (disabled by
         design). "Request Another Review" is the re-request path.
         MUST be an explicit 'block': the stylesheet class itself is
         display:none (cprofile.css .cp-verify-again-wrap), so clearing
         the inline style with '' falls back to hidden — which is exactly
         how this button stayed invisible on production even after the
         reveal code ran. */
      if (againWrap) againWrap.style.display = 'block';
    } else if (st === 'rejected') {
      btn.disabled  = true;
      btn.className = 'cp-cta cp-cta--verify cp-cta--vp-rejected';
      btn.innerHTML = VP_SVG.clock + ' Review Rejected';
      /* A rejected athlete must also be able to re-request */
      if (againWrap) againWrap.style.display = 'block';
    } else {
      /* Unreachable by design: _getMyLatestPlanReview only returns
         whitelisted statuses, every one of which has an explicit branch
         above. This is fail-closed defense in depth — an unknown status
         must NEVER produce a blocking "Under Review" (the old behavior
         here, which is how dismissed/declined/expired historical docs
         froze the button forever). Default to the idle state instead. */
      console.warn('[VERIFY BTN] unhandled status "' + st + '" (doc ' + review.id +
        ') reached the renderer — failing closed to idle "Request Review"');
      btn.dataset.vpStatus = '';
      btn.className = 'cp-cta cp-cta--verify';
      btn.innerHTML = VP_SVG.check + ' Request Review';
    }

    /* Show "View Previous Reviews" link when any review has been completed.
       Sort newest-first so the athlete clicks the correct (latest) review. */
    var doneRevs = allRevs
      .filter(function(r) { return r.status === 'completed' || r.status === 'review_completed'; })
      .sort(function(a, b) {
        return new Date(b.reviewedAt || b.completedAt || b.createdAt || 0) -
               new Date(a.reviewedAt || a.completedAt || a.createdAt || 0);
      });
    if (prevSection && doneRevs.length > 0) {
      renderPrevReviews(doneRevs, coach);
      /* explicit 'block' — .cp-prev-reviews is display:none in the
         stylesheet, so '' would fall back to hidden (same trap as the
         Request Another Review wrap) */
      prevSection.style.display = 'block';
    }
  }

  /* ── Render previous completed reviews list ── */
  function renderPrevReviews(reviews, coach) {
    var section = document.getElementById('prevReviewsSection');
    if (!section) return;

    var total = reviews.length;
    section.innerHTML =
      '<button class="cp-prev-toggle" id="prevReviewsToggle">' +
        '<span class="cp-prev-label">View Previous Reviews (' + total + ')</span>' +
        '<svg class="cp-prev-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>' +
      '</button>' +
      '<div class="cp-prev-list" id="prevReviewsList" style="display:none">' +
        reviews.map(function(r) {
          var typeLabel  = (r.reviewType || r.planReviewType || 'diet') === 'diet' ? '🥗 Diet' : '💪 Workout';
          var ver        = r.version ? 'Review #' + r.version : 'Review';
          var date       = r.createdAt
            ? new Date(r.createdAt).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })
            : '';
          var stLabel    = r.status === 'review_completed' ? 'Expert Reviewed' : 'Completed';
          return '<button class="cp-prev-item" data-prev-rid="' + esc(r.id) + '">' +
            '<div class="cp-prev-item-left">' +
              '<span class="cp-prev-item-ver">' + esc(ver) + '</span>' +
              '<span class="cp-prev-item-type">' + typeLabel + '</span>' +
            '</div>' +
            '<div class="cp-prev-item-right">' +
              '<span class="cp-prev-item-date">' + esc(date) + '</span>' +
              '<span class="cp-prev-item-status">' + esc(stLabel) + '</span>' +
            '</div>' +
            '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg>' +
          '</button>';
        }).join('') +
      '</div>';

    /* Wire toggle */
    var toggle = section.querySelector('#prevReviewsToggle');
    var list   = section.querySelector('#prevReviewsList');
    if (toggle && list) {
      toggle.addEventListener('click', function() {
        var open = list.style.display !== 'none';
        list.style.display = open ? 'none' : '';
        toggle.classList.toggle('cp-prev-toggle--open', !open);
      });
    }

    /* Wire item clicks */
    if (list) {
      list.querySelectorAll('[data-prev-rid]').forEach(function(btn) {
        btn.addEventListener('click', function() {
          var rid = btn.dataset.prevRid;
          var rev = reviews.find(function(r) { return r.id === rid; });
          if (!rev) return;
          var _revDone = rev.status === 'review_completed' || rev.status === 'completed';
          var _hasplan = rev.reviewedDietPlan || rev.reviewedWorkoutPlan || rev.planData;
          if (_revDone && _hasplan) {
            openReviewComparisonSheet(coach, rev);
          } else {
            openChatOverlay('', buildContextPackage(), 'chat', coach);
          }
        });
      });
    }
  }

  function initVerifyPlanBtn(coach) {
    var openBtn      = document.getElementById('verifyPlanBtn');
    var verifyAgain  = document.getElementById('verifyAgainBtn');
    var sheet        = document.getElementById('vpSheet');
    var cancelBtn    = document.getElementById('vpCancelBtn');
    var submitBtn    = document.getElementById('vpSubmitBtn');
    var optDiet      = document.getElementById('vpOptDiet');
    var optWorkout   = document.getElementById('vpOptWorkout');
    var optBoth      = document.getElementById('vpOptBoth');
    var svcVerify    = document.getElementById('vpSvcVerify');
    var svcChat      = document.getElementById('vpSvcChat');
    var svcBoth      = document.getElementById('vpSvcBoth');
    var reviewTypeWrap  = document.getElementById('vpReviewTypeOptions');
    var reviewTypeLabel = document.getElementById('vpReviewTypeLabel');
    var priceRow     = document.getElementById('vpPriceRow');
    var totalPriceEl = document.getElementById('vpTotalPrice');
    if (!sheet || !openBtn) return;

    var reviewTypeBtns = [optDiet, optWorkout, optBoth];
    var svcBtns = [svcVerify, svcChat, svcBoth];

    var _selectedType    = null;  // 'diet' | 'workout' | 'both'
    var _selectedService = null;  // 'verification' | 'chat' | 'verification_chat'

    function _hasDietPlan() {
      return !!(
        localStorage.getItem('zitlas_diet_plan') ||
        localStorage.getItem('zitlas_current_diet') ||
        localStorage.getItem('zitlas_generated_diet') ||
        localStorage.getItem('zitlas_meal_plan')
      );
    }

    function _needsReviewType() {
      return _selectedService === 'verification' || _selectedService === 'verification_chat';
    }

    function _pcvIsPremium() {
      return typeof ZitlasPayment !== 'undefined' &&
        typeof ZitlasPayment.isPremiumMember === 'function' && ZitlasPayment.isPremiumMember();
    }

    function _computeTotalPrice() {
      /* PLATFORM_CHARGES_FREE policy: review + expert-chat fees are ₹0
         for EVERYONE — the only paid feature in ZITLAS is the Premium
         subscription. The zero is also recorded as the request's
         totalPrice, so the expert-side auto-charge attempts ₹0
         (attemptCharge is additionally zero-gated by the same policy
         inside the transaction — this display value is never the
         authority). Premium check kept as a fallback trigger. */
      if (typeof ZitlasPayment !== 'undefined' &&
          typeof ZitlasPayment.isTrialMode === 'function' && ZitlasPayment.isTrialMode()) return 0;
      if (_pcvIsPremium()) return 0;
      var pricing = _getPricing(coach);
      var total = 0;
      if (_needsReviewType()) {
        if (_selectedType === 'diet')    total += pricing.dietReviewPrice;
        else if (_selectedType === 'workout') total += pricing.workoutReviewPrice;
        else if (_selectedType === 'both')    total += pricing.bothReviewPrice;
      }
      if (_selectedService === 'chat' || _selectedService === 'verification_chat') {
        total += pricing.chatPrice;
      }
      return total;
    }

    function _refreshSubmitState() {
      var ready = !!_selectedService && (!_needsReviewType() || !!_selectedType);
      if (submitBtn) submitBtn.disabled = !ready;
      if (totalPriceEl) totalPriceEl.textContent = '₹' + (ready ? _computeTotalPrice() : 0);
    }

    function openSheet() {
      var pricing = _getPricing(coach);
      _selectedType    = null;
      _selectedService = null;
      reviewTypeBtns.forEach(function(b) { if (b) b.classList.remove('selected'); });
      svcBtns.forEach(function(b) { if (b) b.classList.remove('selected'); });
      if (submitBtn) { submitBtn.disabled = true; submitBtn.textContent = 'Send Request →'; }
      if (reviewTypeWrap)  reviewTypeWrap.style.display  = 'none';
      if (reviewTypeLabel) reviewTypeLabel.style.display = 'none';
      if (priceRow) priceRow.style.display = 'none';

      /* Price sub-labels reflect this expert's actual pricing */
      var subVerify = document.getElementById('vpSvcVerifySub');
      var subChat   = document.getElementById('vpSvcChatSub');
      var subBoth   = document.getElementById('vpSvcBothSub');
      if (subVerify) subVerify.textContent = 'Expert reviews your plan · from ₹' + Math.min(pricing.dietReviewPrice, pricing.workoutReviewPrice);
      if (subChat)   subChat.textContent   = 'Unlimited chat until the expert closes it · ₹' + pricing.chatPrice;
      if (subBoth)   subBoth.textContent   = 'Review, then unlimited chat';

      /* Disable diet option and show message when no plan exists */
      if (optDiet) {
        var hasDiet = _hasDietPlan();
        optDiet.classList.toggle('vp-option--unavailable', !hasDiet);
        var subEl = optDiet.querySelector('.vp-opt-sub');
        if (subEl) {
          subEl.textContent = hasDiet
            ? 'Expert reviews your 7-day meal plan'
            : 'No diet plan found. Generate your AI diet plan first.';
        }
      }

      var navbar = document.getElementById('zitlas-navbar');
      if (navbar) {
        var navOffset = window.innerHeight - navbar.getBoundingClientRect().top;
        sheet.style.setProperty('--sheet-nav-offset', navOffset + 'px');
      }
      sheet.classList.add('open');
      document.body.style.overflow = 'hidden';
    }
    function closeSheet() {
      sheet.classList.remove('open');
      sheet.style.removeProperty('--sheet-nav-offset');
      document.body.style.overflow = '';
    }

    /* "Verify Again" button always opens the review-type selector sheet */
    if (verifyAgain) {
      verifyAgain.addEventListener('click', function() {
        console.log('Expert Review button clicked (Verify Again)');
        openSheet();
      });
    }

    /* ── Withdraw Request (pending state only) ── */
    var withdrawBtn        = document.getElementById('withdrawBtn');
    var withdrawBackdrop   = document.getElementById('withdrawBackdrop');
    var withdrawCancelBtn  = document.getElementById('withdrawCancelBtn');
    var withdrawConfirmBtn = document.getElementById('withdrawConfirmBtn');

    /* display is JS-driven (inline none in the HTML) so a stale cached
       stylesheet can never expose the dialog inline; .open drives the
       200ms fade + scale(0.95 → 1) animation. */
    function openWithdrawModal() {
      if (!withdrawBackdrop) return;
      withdrawBackdrop.style.display = 'flex';
      requestAnimationFrame(function() {
        requestAnimationFrame(function() { withdrawBackdrop.classList.add('open'); });
      });
    }
    function closeWithdrawModal() {
      if (!withdrawBackdrop) return;
      withdrawBackdrop.classList.remove('open');
      setTimeout(function() { withdrawBackdrop.style.display = 'none'; }, 200);
    }

    if (withdrawBtn && withdrawBackdrop) {
      withdrawBtn.addEventListener('click', function() {
        console.log('[WITHDRAW] button clicked');
        openWithdrawModal();
      });
      withdrawBackdrop.addEventListener('click', function(e) {
        if (e.target === withdrawBackdrop) closeWithdrawModal();
      });
    }
    if (withdrawCancelBtn) withdrawCancelBtn.addEventListener('click', closeWithdrawModal);

    if (withdrawConfirmBtn) {
      withdrawConfirmBtn.addEventListener('click', function() {
        var review = _getMyLatestPlanReview(coach);
        /* Safety rule: only a PENDING request may be withdrawn */
        if (!review || review.status !== 'pending') {
          console.error('[WITHDRAW] blocked — no pending review to withdraw (status:',
            review && review.status, ')');
          closeWithdrawModal();
          showToast('This request can no longer be withdrawn.');
          updateVerifyBtnState(coach);
          return;
        }
        if (typeof ZitlasDB === 'undefined') {
          console.error('[WITHDRAW] Firestore unavailable');
          showToast('Unable to withdraw request. Please try again.');
          return;
        }

        withdrawConfirmBtn.disabled = true;
        var docRef = ZitlasDB.collection('review_requests').doc(review.id);
        console.log('[WITHDRAW] withdrawing', review.id, '(expert:', review.expertId + ')');

        /* Transaction: re-check status INSIDE Firestore so a withdrawal can
           never stomp a review the expert accepted moments earlier. The doc
           is updated (status:'withdrawn'), never deleted — completed reviews
           and history are untouched, and the expert's pending tab drops it
           in realtime because that tab filters status === 'pending'. */
        ZitlasDB.runTransaction(function(tx) {
          return tx.get(docRef).then(function(snap) {
            if (!snap.exists) throw new Error('not_found');
            if (snap.data().status !== 'pending') throw new Error('not_pending');
            tx.update(docRef, { status: 'withdrawn', withdrawnAt: new Date().toISOString() });
          });
        }).then(function() {
          console.log('[WITHDRAW] success —', review.id, 'is now withdrawn');
          /* "Both" bundle: withdrawing the primary also withdraws the linked
             workout doc — nothing was ever charged for either half. */
          if (review.siblingId) {
            ZitlasDB.collection('review_requests').doc(review.siblingId)
              .update({ status: 'withdrawn', withdrawnAt: new Date().toISOString() })
              .catch(function(e) { console.warn('[WITHDRAW] sibling mirror failed', e); });
          }
          /* Update local cache so the button flips immediately (the
             Firestore listener will confirm moments later) */
          try {
            var all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
            var idx = all.findIndex(function(r) { return r.id === review.id; });
            if (idx !== -1) {
              all[idx].status = 'withdrawn';
              all[idx].withdrawnAt = new Date().toISOString();
              localStorage.setItem('expert_plan_reviews', JSON.stringify(all));
            }
          } catch (_) {}
          closeWithdrawModal();
          showToast('Review request withdrawn.');
          updateVerifyBtnState(coach);
        }).catch(function(err) {
          console.error('[WITHDRAW] failed:', err && err.message);
          closeWithdrawModal();
          if (err && err.message === 'not_pending') {
            showToast('The expert has already started this review — it can no longer be withdrawn.');
            updateVerifyBtnState(coach);
          } else {
            showToast('Unable to withdraw request. Please try again.');
          }
        }).then(function() {
          withdrawConfirmBtn.disabled = false;
        });
      });
    }

    /* Main button click — only accepted goes to chat, everything else opens
       the review sheet. NOTE: in pending/under-review/completed/rejected
       states the button is disabled BY DESIGN (it is a status label) and
       the browser fires no click event at all — re-requests go through the
       "Verify Again" button that appears under it in terminal states. */
    openBtn.addEventListener('click', function() {
      console.log('Expert Review button clicked — state:', openBtn.dataset.vpStatus || '(new)');
      var st = openBtn.dataset.vpStatus || '';
      if (st === 'accepted') {
        var _rev = _getMyLatestPlanReview(coach);
        if (_rev && _rev.paymentStatus === 'awaiting_payment') {
          _retryReviewPayment(_rev, coach);
          return;
        }
        if (_rev && _rev.chatUnlocked !== false) {
          openChatOverlay('', buildContextPackage(), 'chat', coach);
        }
        return;
      }
      if (!openBtn.disabled) openSheet();
    });

    if (cancelBtn) cancelBtn.addEventListener('click', closeSheet);
    sheet.addEventListener('click', function(e) { if (e.target === sheet) closeSheet(); });

    svcBtns.forEach(function(btn) {
      if (!btn) return;
      btn.addEventListener('click', function() {
        _selectedService = btn.dataset.svc;
        svcBtns.forEach(function(b) { if (b) b.classList.remove('selected'); });
        btn.classList.add('selected');

        var showReviewType = _needsReviewType();
        if (reviewTypeWrap)  reviewTypeWrap.style.display  = showReviewType ? '' : 'none';
        if (reviewTypeLabel) reviewTypeLabel.style.display = showReviewType ? '' : 'none';
        if (priceRow) priceRow.style.display = '';
        if (!showReviewType) {
          _selectedType = null;
          reviewTypeBtns.forEach(function(b) { if (b) b.classList.remove('selected'); });
        }
        _refreshSubmitState();
      });
    });

    reviewTypeBtns.forEach(function(btn) {
      if (!btn) return;
      btn.addEventListener('click', function() {
        if ((btn === optDiet || btn === optBoth) && !_hasDietPlan()) {
          showToast('No diet plan found. Generate your AI diet plan first.');
          return;
        }
        _selectedType = btn.dataset.type;
        reviewTypeBtns.forEach(function(b) { if (b) b.classList.remove('selected'); });
        btn.classList.add('selected');
        _refreshSubmitState();
      });
    });

    if (submitBtn) {
      submitBtn.addEventListener('click', function() {
        console.log('[VERIFY] button clicked', { service: _selectedService, type: _selectedType });
        if (!_selectedService || (_needsReviewType() && !_selectedType)) return;

        /* ── Lifecycle guard: only ONE active review per athlete↔expert ──
           Rules: pending → block; in_progress/expert_reviewing/accepted →
           block; completed/rejected → allowed. Without this, the sheet
           (reachable via "Request Another Review") could create a second
           request while one is still open. Deliberately NOT
           _getMyLatestPlanReview here — this needs "does ANY active review
           exist, of any vintage" (e.g. a "Both" bundle's ₹0 workout sibling
           that's still active even though its diet sibling just completed),
           not "what's my single newest review's status". */
        var _activeStatuses = ['pending', 'accepted', 'in_progress', 'expert_reviewing'];
        var _activeReview = _getAllMyPlanReviews(coach).find(function(r) {
          return _activeStatuses.indexOf(r.status) !== -1;
        });
        if (_activeReview) {
          console.error('[VERIFY] blocked — active review already exists:',
            _activeReview.id, 'status:', _activeReview.status);
          showToast(_activeReview.status === 'pending'
            ? 'Your previous request is still pending.'
            : 'The expert is already handling an active request from you.');
          closeSheet();
          updateVerifyBtnState(coach);
          return;
        }

        var ctx        = buildContextPackage();
        var userId     = _getMyUserId();
        var totalPrice = _computeTotalPrice();
        var a          = ctx.assessment || ctx.survey || {};
        var isChatOnly = _selectedService === 'chat';

        /* Build the 1 or 2 request docs this submission needs. "Both" is
           two ordinary, linked review_requests docs (bundleId/siblingId) —
           NOT a new combined schema — so the existing per-type rendering,
           editing, and completion flows on the expert's side (modify-diet.
           html / modify-workout.html) need no changes at all. The bundle's
           full price lives on the primary doc only; the secondary carries
           ₹0 and mirrors status once the primary is paid (see
           expert-dashboard.js _prAcceptReview). */
        var specs = [];
        if (isChatOnly) {
          specs.push({ reviewType: 'chat_only', planData: null, price: totalPrice });
        } else if (_selectedType === 'both') {
          var dietPlan = ctx.diet_plan;
          if (!dietPlan) {
            var _rawD = localStorage.getItem('zitlas_current_diet') ||
                        localStorage.getItem('zitlas_generated_diet') ||
                        localStorage.getItem('zitlas_meal_plan');
            try { dietPlan = _rawD ? JSON.parse(_rawD) : null; } catch (_) { dietPlan = null; }
          }
          var workoutPlan = ctx.workout_plan;
          if (!dietPlan)    { showToast('No diet plan found. Generate your plan first.'); return; }
          if (!workoutPlan) { showToast('No workout plan found. Generate your plan first.'); return; }
          var bundleId = 'BND_' + Date.now();
          specs.push({ reviewType: 'diet',    planData: dietPlan,    price: totalPrice, bundleId: bundleId, bundleRole: 'primary' });
          specs.push({ reviewType: 'workout', planData: workoutPlan, price: 0,          bundleId: bundleId, bundleRole: 'secondary' });
        } else {
          var planData;
          if (_selectedType === 'diet') {
            planData = ctx.diet_plan;
            if (!planData) {
              var _raw = localStorage.getItem('zitlas_current_diet') ||
                         localStorage.getItem('zitlas_generated_diet') ||
                         localStorage.getItem('zitlas_meal_plan');
              try { planData = _raw ? JSON.parse(_raw) : null; } catch (_) { planData = null; }
            }
          } else {
            planData = ctx.workout_plan;
          }
          if (!planData) {
            showToast('No ' + (_selectedType === 'diet' ? 'diet' : 'workout') + ' plan found. Generate your plan first.');
            return;
          }
          specs.push({ reviewType: _selectedType, planData: planData, price: totalPrice });
        }

        specs.forEach(function(s, i) { s.id = 'PR_' + Date.now() + '_' + i + '_' + Math.random().toString(36).slice(2, 6); });
        if (specs.length === 2) {
          specs[0].siblingId = specs[1].id;
          specs[1].siblingId = specs[0].id;
        }

        var now = new Date().toISOString();
        /* Athlete display name — the expert's Modify pages render
           review.athleteName/userName; without this every review showed
           the generic "Reviewing plan for Athlete". */
        var _fbUsr = {};
        try { _fbUsr = JSON.parse(localStorage.getItem('zitlas_firebase_user') || '{}') || {}; } catch (_) {}
        var _athleteNm = _fbUsr.name || _fbUsr.displayName || 'Athlete';
        /* Goal-identity stamp for the request docs. THE PAID FLOW NEVER
           STAMPED planId ON THE REVIEW DOCS THEMSELVES (only on the local
           anchor) — so every PR_ review was unstamped, the expert-side
           auto-apply couldn't verify it, and the athlete-side fail-closed
           banner couldn't validate its completion. Fallback to the plan
           wrapper's own planId covers a device where zitlas_plan_id
           hasn't hydrated yet (this page historically didn't load
           cloud-sync at all). */
        var _reqPlanId = localStorage.getItem('zitlas_plan_id') ||
          (ctx.diet_plan && ctx.diet_plan.planId) || null;
        var profileBasics = {
          age:                  a.age                  || null,
          gender:               a.gender               || null,
          weight_kg:            a.weight_kg            || null,
          height_cm:            a.height_cm            || null,
          goal_weight_kg:       a.goal_weight_kg       || null,
          activity_level:       a.activity_level       || null,
          diet_preference:      a.diet_preference      || null,
          workout_preference:   a.workout_preference   || null,
          fitness_goal:         a.fitness_goal         || null,
          transformation_goal:  a.transformation_goal  || null,
          goal_duration_months: a.goal_duration_months || null,
          fitness_level:        a.fitness_level        || null,
          stress_level:         a.stress_level         || null,
          available_time:       a.available_time       || null,
          target_body_fat_pct:  a.target_body_fat_pct  || null,
          biggest_struggle:     a.biggest_struggle     || a.struggle || null,
        };

        var reviewDocs = specs.map(function(s) {
          var allForType = _getAllMyPlanReviews(coach).filter(function(r) {
            return (r.reviewType || r.planReviewType) === s.reviewType;
          });
          var maxVersion = allForType.reduce(function(max, r) { return Math.max(max, r.version || 0); }, 0);
          return {
            id:         s.id,
            userId:     userId,
            athleteName: _athleteNm,
            userName:    _athleteNm,
            expertId:   coach.id,
            expertName: coach.name,
            expertRole: coach.role,
            reviewType: s.reviewType,
            version:    maxVersion + 1,
            planId:     _reqPlanId,
            planData:   s.planData,
            assessmentData: {
              assessment:   ctx.assessment   || null,
              calculations: ctx.calculations || null,
              swot:         ctx.swot         || null,
            },
            profileBasics:  profileBasics,
            serviceType:    _selectedService,
            totalPrice:     s.price,
            isPremium:      _pcvIsPremium(),
            paymentStatus:  'unpaid',
            bundleId:       s.bundleId   || null,
            bundleRole:     s.bundleRole || null,
            siblingId:      s.siblingId  || null,
            status:      'pending',
            createdAt:   now,
            submittedAt: now,
            completedAt: null,
          };
        });

        console.log('[VERIFY] payload', reviewDocs);

        /* Only remove currently-pending requests to avoid duplicates.
           Completed/rejected reviews are kept as permanent history. */
        var existing = [];
        try { existing = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]'); } catch (_) {}
        var _staleIds = [];
        var newTypes  = reviewDocs.map(function(r) { return r.reviewType; });
        existing = existing.filter(function(r) {
          var isStalePending = r.userId === userId && r.expertId === coach.id &&
                   newTypes.indexOf(r.reviewType || r.planReviewType) !== -1 &&
                   r.status === 'pending';
          if (isStalePending && r.id) _staleIds.push(r.id);
          return !isStalePending;
        });
        reviewDocs.forEach(function(r) { existing.unshift(r); });
        try { localStorage.setItem('expert_plan_reviews', JSON.stringify(existing)); } catch (_) {}

        /* Active-request anchor — the SAME key diet.js's
           getCompletedPlanReview() matches on, so the Diet page banner can
           surface THIS request's completed review (and never a stale one
           from a different expert). Points at the diet-type doc when the
           bundle has one, since the Diet page is where it gets consumed. */
        try {
          var _anchorDoc = reviewDocs.find(function(r) { return r.reviewType === 'diet'; }) || reviewDocs[0];
          if (_anchorDoc) {
            localStorage.setItem('zitlas_review_request', JSON.stringify({
              id: _anchorDoc.id, expertId: coach.id,
              planId: _reqPlanId,
              status: 'pending',
            }));
          }
        } catch (_) {}

        /* Supersede the same stale pendings IN FIRESTORE too. Previously
           only the localStorage copy was pruned — the old pending document
           stayed 'pending' in Firestore forever, which is exactly how
           orphaned duplicate requests accumulated. Update, never delete:
           history is preserved and every transition is auditable. */
        if (typeof ZitlasDB !== 'undefined' && _staleIds.length) {
          _staleIds.forEach(function(staleId) {
            console.log('[VERIFY] superseding stale pending review', staleId, '→ replaced by', reviewDocs[0].id);
            ZitlasDB.collection('review_requests').doc(staleId)
              .update({ status: 'superseded', supersededBy: reviewDocs[0].id, supersededAt: new Date().toISOString() })
              .catch(function(e) { console.error('[VERIFY] supersede failed for', staleId, e && e.code); });
          });
        }

        /* Write to Firestore so the expert's dashboard inbox receives it.
           Money is NEVER touched here — only on the expert's Accept. */
        if (typeof ZitlasDB !== 'undefined') {
          var writes = reviewDocs.map(function(r) {
            var firestoreReview = Object.assign({}, r, {
              serverTimestamp: firebase.firestore.FieldValue.serverTimestamp(),
            });
            console.log('[FIRESTORE] Writing review_requests/' + r.id);
            return ZitlasDB.collection('review_requests').doc(r.id).set(firestoreReview);
          });
          Promise.all(writes)
            .then(function() { console.log('[VERIFY] review document(s) created', reviewDocs.map(function(r) { return r.id; })); })
            .catch(function(e) {
              console.error('[FIRESTORE] review_requests write FAILED', e);
              showToast('Could not send request — please check your connection and try again.');
            });
        } else {
          console.warn('[FIRESTORE] ZitlasDB not available — request saved to localStorage only');
        }

        submitBtn.textContent = 'Sent ✓';
        submitBtn.disabled    = true;

        setTimeout(function() {
          closeSheet();
          showToast(totalPrice > 0
            ? 'Request sent — ₹' + totalPrice + ' will be deducted from your wallet once the expert accepts.'
            : 'Your request has been sent.');
          updateVerifyBtnState(coach);
        }, 700);
      });
    }

    /* Detect expert accepting or first message arriving (cross-tab via storage) */
    window.addEventListener('storage', function(e) {
      if (e.key === 'expert_plan_reviews') updateVerifyBtnState(coach);
      if (e.key === 'zitlas_chats') {
        /* If a chat message from this expert arrives while in pending state,
           treat it as an implicit accept so the button unlocks */
        var review = _getMyLatestPlanReview(coach);
        if (!review || review.status !== 'pending') return;
        try {
          var chats = JSON.parse(e.newValue || '{}');
          var convoKey = 'chat_' + (review.userId || '') + '_' + coach.id;
          var msgs = (chats[convoKey] && chats[convoKey].messages) || [];
          var hasExpertMsg = msgs.some(function(m) { return m.senderType === 'expert' || m.sender === 'expert'; });
          if (hasExpertMsg) {
            var all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
            var idx = all.findIndex(function(r) { return r.id === review.id; });
            if (idx !== -1 && _normalizeStatus(all[idx].status) === 'pending') {
              all[idx].status = 'in_progress';
              localStorage.setItem('expert_plan_reviews', JSON.stringify(all));
              /* Mirror to Firestore */
              if (typeof ZitlasDB !== 'undefined') {
                ZitlasDB.collection('review_requests').doc(review.id)
                  .update({ status: 'in_progress' })
                  .catch(function(e) { console.warn('[REVIEW] implicit in_progress write failed:', e); });
              }
            }
          }
        } catch (_) {}
      }
    });

    /* Set initial button state on page load */
    updateVerifyBtnState(coach);

    /* ── Maintenance: safely resolve orphaned pending reviews ──
       Marks the current user's 'pending' reviews as 'superseded' (never
       deletes) when (a) the target expert no longer exists in Firestore, or
       (b) a newer request to the same expert+type exists. Run manually from
       the console: zitlasCleanupStalePendingReviews() */
    window.zitlasCleanupStalePendingReviews = function() {
      if (typeof ZitlasDB === 'undefined') { console.error('[CLEANUP] Firestore unavailable'); return; }
      var uid = _getMyUserId();
      if (!uid) { console.error('[CLEANUP] no signed-in user'); return; }
      ZitlasDB.collection('review_requests')
        .where('userId', '==', uid).get()
        .then(function(snap) {
          var docs = snap.docs.map(function(d) { return d.data(); });
          var pendings = docs.filter(function(r) { return r.status === 'pending'; });
          console.log('[CLEANUP]', pendings.length, 'pending review(s) found');
          pendings.forEach(function(p) {
            var newer = docs.find(function(o) {
              return o.id !== p.id && o.expertId === p.expertId &&
                (o.reviewType || 'diet') === (p.reviewType || 'diet') &&
                (o.createdAt || '') > (p.createdAt || '');
            });
            var resolve = function(reason) {
              console.log('[CLEANUP] superseding', p.id, '— reason:', reason);
              ZitlasDB.collection('review_requests').doc(p.id)
                .update({ status: 'superseded', supersededReason: reason, supersededAt: new Date().toISOString() })
                .then(function() { console.log('[CLEANUP] done:', p.id); })
                .catch(function(e) { console.error('[CLEANUP] failed:', p.id, e); });
            };
            if (newer) { resolve('newer_request_exists:' + newer.id); return; }
            ZitlasDB.collection('experts').doc(p.expertId).get().then(function(eDoc) {
              if (!eDoc.exists) resolve('expert_not_found:' + p.expertId);
              else console.log('[CLEANUP] keeping', p.id, '— expert exists, no newer request; genuinely awaiting review');
            });
          });
        })
        .catch(function(e) { console.error('[CLEANUP] query failed', e); });
    };

    /* Auto-run once per browser session: orphaned pendings (addressed to a
       deleted expert, or superseded by a newer request) otherwise sit in
       Firestore forever and are invisible to every expert dashboard. The
       helper is conservative — a genuinely-awaiting review is never touched
       (it logs "keeping" instead). Delayed so auth is settled first. */
    try {
      if (!sessionStorage.getItem('zitlas_review_cleanup_ran')) {
        sessionStorage.setItem('zitlas_review_cleanup_ran', '1');
        setTimeout(function() { window.zitlasCleanupStalePendingReviews(); }, 4000);
      }
    } catch (_) {}

    /* Listen for expert completing review in Firestore — single source of truth.
       Syncs canonical status into expert_plan_reviews (cache) and auto-applies
       the reviewed plan to zitlas_diet_plan / zitlas_workout_plan. */
    if (typeof ZitlasDB !== 'undefined') {
      var _reviewUid = _getMyUserId();
      if (_reviewUid) {
        console.log('[REVIEW] athlete query: review_requests.where(userId ==', _reviewUid + ') | this page\'s expert:', coach.id);
        ZitlasDB.collection('review_requests')
          .where('userId', '==', _reviewUid)
          .onSnapshot(function(snapshot) {
            console.log('[REVIEW] athlete snapshot —', snapshot.size, 'doc(s):',
              snapshot.docs.map(function(d) {
                var x = d.data();
                return { reviewId: x.id, status: x.status, expertId: x.expertId, athleteId: x.userId,
                         forThisExpert: x.expertId === coach.id };
              }));
            var changed = false;
            snapshot.docs.forEach(function(doc) {
              var data = doc.data();
              if (!data.id) return;

              try {
                var all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
                var idx = all.findIndex(function(r) { return r.id === data.id; });
                var prevRaw = idx !== -1 ? (all[idx].status || '') : '';
                var newRaw  = data.status || '';
                /* Trigger plan auto-apply on either status value used for completion */
                var wasCompleted = prevRaw === 'completed' || prevRaw === 'review_completed';
                var isCompleted  = newRaw  === 'completed' || newRaw  === 'review_completed';
                var justCompleted = !wasCompleted && isCompleted;
                var isInProgress  = newRaw  === 'in_progress' || newRaw  === 'expert_reviewing';
                var justAccepted  = prevRaw === 'pending' && isInProgress;

                /* Deduped via the same localStorage flags review-sync.js
                   uses — the diet/dashboard pages run their own listener
                   now, and the same milestone must never notify twice. */
                if (typeof ZitlasNotify !== 'undefined' && prevRaw) {
                  if (justAccepted && !localStorage.getItem('zitlas_review_note_' + data.id + '_accepted')) {
                    try { localStorage.setItem('zitlas_review_note_' + data.id + '_accepted', new Date().toISOString()); } catch (_) {}
                    ZitlasNotify.send(_reviewUid, {
                      title: '👨‍⚕️ ' + (data.expertName || 'Expert') + ' accepted your review request',
                      message: 'They’re now reviewing your ' + (data.reviewType || 'plan') + '.',
                      category: 'review', type: 'review_accepted',
                      action: 'expert_profile', actionId: data.expertId,
                    });
                  } else if (justCompleted && !localStorage.getItem('zitlas_review_note_' + data.id + '_completed')) {
                    try { localStorage.setItem('zitlas_review_note_' + data.id + '_completed', new Date().toISOString()); } catch (_) {}
                    ZitlasNotify.send(_reviewUid, {
                      title: '⭐ ' + (data.expertName || 'Expert') + ' completed your review',
                      message: 'Open their profile to see the changes.',
                      category: 'review', type: 'review_completed',
                      action: 'expert_profile', actionId: data.expertId, priority: 'high',
                    });
                  }
                }

                console.log('[REVIEW] athlete listener', data.id, 'prev:', prevRaw, '→ new:', newRaw);
                console.log('status', newRaw);
                if (isCompleted) console.log('firestore review after completion', data);

                /* Merge Firestore data into cache; preserve raw status (no normalization) */
                var _merged = Object.assign({}, idx !== -1 ? all[idx] : {}, data);
                if (idx === -1) {
                  all.push(_merged);
                } else {
                  all[idx] = _merged;
                }
                localStorage.setItem('expert_plan_reviews', JSON.stringify(all));

                console.log('zitlas_workout_plan', JSON.parse(localStorage.getItem('zitlas_workout_plan')));
                console.log('zitlas_diet_plan',    JSON.parse(localStorage.getItem('zitlas_diet_plan')));
                changed = true;

                /* Auto-apply expert plan to source-of-truth keys on first completion */
                if (justCompleted) {
                  var _rtype = _merged.reviewType || _merged.planReviewType || 'diet';
                  if (_rtype === 'workout' && (_merged.reviewedWorkoutPlan || _merged.planData)) {
                    try {
                      console.log('build workout input', _merged);
                      var _wSt = _buildWorkoutStorageFromReview(_merged);
                      _cpSaveWorkoutStorage(_wSt);
                      console.log('[REVIEW] workout applied');
                    } catch (e) { console.warn('[REVIEW] workout auto-apply failed', e); }
                  } else if (_rtype !== 'workout' && (_merged.reviewedDietPlan || _merged.planData)) {
                    try {
                      console.log('build diet input', _merged);
                      var _dSt = _buildDietStorageFromReview(_merged);
                      _cpSaveDietStorage(_dSt);
                      console.log('[REVIEW] diet applied');
                    } catch (e) { console.warn('[REVIEW] diet auto-apply failed', e); }
                  }
                }
              } catch (_) {}
            });
            if (changed) updateVerifyBtnState(coach);
          }, function(err) {
            console.warn('[REVIEW] athlete listener error:', err);
          });
      }
    }
  }

  /* ══════════════════════════════════════════
     CHAT INPUT WIRING
  ══════════════════════════════════════════ */
  function initChatInput() {
    const overlay  = document.getElementById('chatOverlay');
    const backBtn  = document.getElementById('chatBackBtn');
    const input    = document.getElementById('chatInput');
    const sendBtn  = document.getElementById('chatSendBtn');

    if (backBtn) {
      backBtn.addEventListener('click', () => {
        overlay.classList.remove('open');
        document.body.style.overflow = '';
        const navbar = document.getElementById('zitlas-navbar');
        if (navbar) navbar.style.display = '';
        /* Navigate back to the Experts listing */
        window.location.href = 'coaches.html';
      });
    }

    /* ── ⋮ Menu ── */
    const menuBtn   = document.getElementById('chatMenuBtn');
    const dropdown  = document.getElementById('chatDropdown');
    const clearBtn  = document.getElementById('chatClearBtn');
    const viewCoach = document.getElementById('chatViewCoachBtn');
    const backdrop  = document.getElementById('chatClearBackdrop');
    const cancelBtn = document.getElementById('chatClearCancel');
    const confirmBtn = document.getElementById('chatClearConfirm');

    function closeDropdown() { dropdown && dropdown.classList.remove('open'); }

    if (menuBtn && dropdown) {
      menuBtn.addEventListener('click', function(e) {
        e.stopPropagation();
        dropdown.classList.toggle('open');
      });
      /* Close when clicking outside the menu */
      document.addEventListener('click', function(e) {
        if (!e.target.closest('#chatMenuWrap')) closeDropdown();
      });
    }

    /* "View Coach Profile" — close chat overlay (already on the coach profile page) */
    if (viewCoach) {
      viewCoach.addEventListener('click', function() {
        closeDropdown();
        overlay.classList.remove('open');
        document.body.style.overflow = '';
        const navbar = document.getElementById('zitlas-navbar');
        if (navbar) navbar.style.display = '';
        window.scrollTo({ top: 0, behavior: 'smooth' });
      });
    }

    /* "Clear Chat" — show confirmation modal */
    if (clearBtn && backdrop) {
      clearBtn.addEventListener('click', function() {
        closeDropdown();
        backdrop.classList.add('open');
      });
    }
    if (cancelBtn && backdrop) {
      cancelBtn.addEventListener('click', function() { backdrop.classList.remove('open'); });
    }
    backdrop && backdrop.addEventListener('click', function(e) {
      if (e.target === backdrop) backdrop.classList.remove('open');
    });

    if (confirmBtn) {
      confirmBtn.addEventListener('click', function() {
        if (!_currentChatCoach) { backdrop.classList.remove('open'); return; }
        var conversationId = getConversationId(_currentChatCoach.id);
        /* Stamp hiddenForAthlete — never delete actual messages */
        try {
          var all = JSON.parse(localStorage.getItem('zitlas_chats') || '{}');
          if (all[conversationId]) {
            all[conversationId].hiddenForAthlete = new Date().toISOString();
            localStorage.setItem('zitlas_chats', JSON.stringify(all));
          }
        } catch(_) {}
        backdrop.classList.remove('open');
        /* Re-render chat showing only messages after the clear point */
        var container = document.getElementById('chatMessages');
        if (container) container.innerHTML = '';
        console.log('[CHAT] Athlete cleared chat for', conversationId);
      });
    }

    /* ── 📞 Call button — WebRTC voice call, signaled via Firestore
       (see assets/js/webrtc-call.js). STUN-only: no TURN server configured,
       so calls may fail to connect audio across restrictive NATs/firewalls
       even though signaling (ringing/accepted) succeeds. ── */
    var callBtn = document.getElementById('chatCallBtn');
    if (callBtn) {
      callBtn.addEventListener('click', function() {
        console.log('[CALL] button clicked');
        if (_callSession) {
          console.log('[CALL] Athlete ended call with', _currentChatCoach ? _currentChatCoach.name : 'coach');
          _callSession.hangup();
          ZitlasCallUI.close({ message: 'Call ended' });
          _endCallUI();
        } else {
          if (!_currentChatCoach || typeof ZitlasDB === 'undefined' || typeof ZitlasCall === 'undefined') return;
          console.log('[CALL] Athlete calling', _currentChatCoach.name);
          _startOutgoingCall(_currentChatCoach);
        }
      });
    }

    /* Accept/Decline/Hangup are owned by ZitlasCallUI (assets/js/call-ui.js);
       callbacks are wired in startIncomingCallListener / _startOutgoingCall. */

    function sendMessage() {
      if (_chatIsReadOnlyFor(_currentChatCoach)) return;
      const text = (input?.value || '').trim();
      if (!text) return;
      const container = document.getElementById('chatMessages');
      const now = new Date().toISOString();

      /* Determine grouping against last persisted message */
      var grouped = false;
      if (_currentChatCoach) {
        var conv = loadConversation(getConversationId(_currentChatCoach.id));
        if (conv && conv.messages && conv.messages.length) {
          var last = conv.messages[conv.messages.length - 1];
          grouped = zcIsGrouped(last, { senderType: 'athlete', timestamp: now });
        }
      }

      /* Day separator if needed */
      var lastDaySep = container.querySelector('.zc-day-sep:last-of-type');
      var lastDayLabel = lastDaySep ? lastDaySep.querySelector('.zc-day-sep-lbl') : null;
      var todayLabel = buildZcDaySep(now).querySelector('.zc-day-sep-lbl').textContent;
      if (!lastDayLabel || lastDayLabel.textContent !== todayLabel) {
        container.appendChild(buildZcDaySep(now));
      }

      const msgEl = createUserMsg(text, now, grouped);
      container.appendChild(msgEl);
      input.value = '';
      input.style.height = 'auto';
      container.scrollTop = container.scrollHeight;

      /* Persist to localStorage */
      if (_currentChatCoach) {
        const conversationId = getConversationId(_currentChatCoach.id);
        const msg = persistChatMessage(conversationId, 'athlete', text);
        if (msg) msgEl.dataset.msgId = msg.id;
      }
    }

    if (sendBtn) sendBtn.addEventListener('click', sendMessage);

    if (input) {
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
      });
      input.addEventListener('input', function() {
        this.style.height = 'auto';
        this.style.height = Math.min(this.scrollHeight, 120) + 'px';
      });
    }

    /* Real-time: receive expert replies via storage event (cross-tab / cross-window) */
    var _zcTypingTimer = null;
    window.addEventListener('storage', function(e) {
      if (e.key !== 'zitlas_chats' || !_currentChatCoach) return;
      try {
        var all  = JSON.parse(e.newValue || '{}');
        var conv = all[getConversationId(_currentChatCoach.id)];
        if (!conv || !conv.messages) return;
        var container = document.getElementById('chatMessages');
        if (!container) return;

        var rendered = new Set();
        container.querySelectorAll('[data-msg-id]').forEach(function(el) { rendered.add(el.dataset.msgId); });
        var newMsgs = conv.messages.filter(function(m) { return !rendered.has(m.id); });
        if (!newMsgs.length) return;

        /* Show typing for expert messages */
        var hasExpert = newMsgs.some(function(m) { return m.senderType !== 'athlete'; });
        if (hasExpert) {
          var expertInitials = (conv.expertName || 'E').split(' ').map(function(w) { return w[0] || ''; }).join('').slice(0, 2).toUpperCase();
          showZcTyping(container, expertInitials);
          clearTimeout(_zcTypingTimer);
          _zcTypingTimer = setTimeout(function() {
            hideZcTyping(container);
            appendNewMessages(container, newMsgs, conv, rendered);
          }, 1200);
        } else {
          appendNewMessages(container, newMsgs, conv, rendered);
        }
      } catch(_) {}
    });

    function appendNewMessages(container, newMsgs, conv, rendered) {
      var allMsgEls = container.querySelectorAll('[data-msg-id]');
      var lastRenderedId = allMsgEls.length ? allMsgEls[allMsgEls.length - 1].dataset.msgId : null;
      var lastMsg = lastRenderedId ? conv.messages.find(function(m) { return m.id === lastRenderedId; }) : null;
      var prevDay = null;
      /* Track last known day from already-rendered separators */
      var daySeps = container.querySelectorAll('.zc-day-sep-lbl');
      if (daySeps.length) prevDay = daySeps[daySeps.length - 1].textContent;

      newMsgs.forEach(function(msg) {
        var msgDay = msg.timestamp ? new Date(msg.timestamp).toDateString() : null;
        var dayLabel = buildZcDaySep(msg.timestamp).querySelector('.zc-day-sep-lbl').textContent;
        if (msgDay && dayLabel !== prevDay) {
          container.appendChild(buildZcDaySep(msg.timestamp));
          prevDay = dayLabel;
        }
        var grouped = zcIsGrouped(lastMsg, msg);
        var el = msg.senderType === 'athlete'
          ? createUserMsg(msg.text, msg.timestamp, grouped, msg.imageUrl)
          : createExpertReplyMsg(msg.text, conv.expertName, msg.timestamp, grouped, msg.imageUrl);
        el.dataset.msgId = msg.id;
        container.appendChild(el);
        lastMsg = msg;
      });
      container.scrollTop = container.scrollHeight;
    }

    initChatImageAttach();
  }

  /* ══════════════════════════════════════════
     CHAT IMAGE ATTACH
  ══════════════════════════════════════════ */

  /* Compression + upload + preview + viewer live in the shared module
     (assets/js/chat-attachments.js) so athlete and expert chat behave
     identically. This function owns only the athlete-side flow:
     validate -> preview (Cancel/Send) -> spinner bubble -> upload ->
     persist, with a tappable Retry on failure. */
  function sendImageMessage(file) {
    var container = document.getElementById('chatMessages');
    if (!container || typeof ZitlasChatAttach === 'undefined') return;

    var v = ZitlasChatAttach.validate(file);
    if (!v.ok) { showToast(v.reason); return; }

    ZitlasChatAttach.confirmPreview(file).then(function(send) {
      if (!send) return;
      var now = new Date().toISOString();

      /* Spinner placeholder while uploading */
      var placeholder = document.createElement('div');
      placeholder.className = 'zc-msg zc-msg--out zc-msg--first';
      placeholder.innerHTML =
        '<div class="zc-bbl zc-bbl--img">' +
          '<div class="zc-img-placeholder"><span class="zca-spinner"></span><span>Uploading…</span></div>' +
        '</div>';
      container.appendChild(placeholder);
      container.scrollTop = container.scrollHeight;

      ZitlasChatAttach.upload(file).then(function(url) {
        placeholder.remove();
        var grouped = false;
        if (_currentChatCoach) {
          var conv = loadConversation(getConversationId(_currentChatCoach.id));
          if (conv && conv.messages && conv.messages.length) {
            var last = conv.messages[conv.messages.length - 1];
            grouped = zcIsGrouped(last, { senderType: 'athlete', timestamp: now });
          }
        }
        var msgEl = createUserMsg('', now, grouped, url);
        container.appendChild(msgEl);
        container.scrollTop = container.scrollHeight;
        if (_currentChatCoach) {
          var conversationId = getConversationId(_currentChatCoach.id);
          var msg = persistChatMessage(conversationId, 'athlete', '', url);
          if (msg) msgEl.dataset.msgId = msg.id;
        }
      }).catch(function(err) {
        console.error('[CHAT IMAGE] Upload failed:', err);
        var inner = placeholder.querySelector('.zc-img-placeholder');
        if (inner) {
          inner.classList.add('zc-img-placeholder--retry');
          inner.innerHTML = '<span>❌</span><span>Upload failed</span><span class="zca-retry-label">Tap to retry</span>';
          inner.addEventListener('click', function() {
            placeholder.remove();
            sendImageMessage(file); /* fresh attempt, preview already confirmed? re-preview keeps it simple + safe */
          }, { once: true });
        }
      });
    });
  }

  function initChatImageAttach() {
    /* openChatOverlay() calls this on EVERY chat open — without this guard
       the change listeners stack and one photo pick sends N duplicate
       messages after N chat opens. */
    if (initChatImageAttach._wired) return;
    initChatImageAttach._wired = true;

    var attachBtn    = document.getElementById('chatAttachBtn');
    var fileInput    = document.getElementById('chatFileInput');
    var cameraInput  = document.getElementById('chatCameraInput');
    var sheet        = document.getElementById('chatImgSheet');
    var sheetCamera  = document.getElementById('chatSheetCamera');
    var sheetGallery = document.getElementById('chatSheetGallery');
    var sheetCancel  = document.getElementById('chatSheetCancel');

    function openSheet() {
      if (!sheet) return;
      var navbar = document.getElementById('zitlas-navbar');
      if (navbar) {
        var navOffset = window.innerHeight - navbar.getBoundingClientRect().top;
        sheet.style.setProperty('--sheet-nav-offset', navOffset + 'px');
      }
      sheet.classList.add('open');
    }
    function closeSheet() {
      if (!sheet) return;
      sheet.classList.remove('open');
      sheet.style.removeProperty('--sheet-nav-offset');
    }

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
        if (f) sendImageMessage(f);
        fileInput.value = '';
      });
    }
    if (cameraInput) {
      cameraInput.addEventListener('change', function() {
        var f = cameraInput.files[0];
        if (f) sendImageMessage(f);
        cameraInput.value = '';
      });
    }
  }

  /* ══════════════════════════════════════════
     HEADER BUTTONS
  ══════════════════════════════════════════ */
  function initHeader() {
    var backBtn = document.getElementById('backBtn');
    if (backBtn) {
      backBtn.addEventListener('click', function() {
        if (document.referrer && document.referrer.includes('coaches')) {
          history.back();
        } else {
          window.location.href = 'coaches.html';
        }
      });
    }
  }

  /* ══════════════════════════════════════════
     VIEW ALL BUTTONS
  ══════════════════════════════════════════ */
  function initViewAlls() {
    var reviewsBtn = document.getElementById('viewAllReviews');
    if (reviewsBtn) reviewsBtn.addEventListener('click', function() { showToast('All reviews — coming soon'); });
  }

  /* ══════════════════════════════════════════
     BOTTOM NAV — block placeholder links
  ══════════════════════════════════════════ */
  function initBottomNav() {
    document.querySelectorAll('.nav-item:not(.active)').forEach((item) => {
      const href = item.getAttribute('href');
      if (!href || href === '#') {
        item.addEventListener('click', (e) => {
          e.preventDefault();
          showToast('Navigation — coming soon');
        });
      }
    });
  }

  /* ══════════════════════════════════════════
     READ MORE TOGGLE
  ══════════════════════════════════════════ */
  function initReadMore() {
    var btn  = document.getElementById('readMoreBtn');
    var text = document.getElementById('aboutText');
    if (!btn || !text) return;
    var expanded = false;
    btn.addEventListener('click', function() {
      expanded = !expanded;
      text.classList.toggle('expanded', expanded);
      btn.textContent = expanded ? 'Read Less ▴' : 'Read More ▾';
    });
  }

  /* ══════════════════════════════════════════
     STICKY BOTTOM BAR
  ══════════════════════════════════════════ */
  function initStickyBottom() {
    var bar   = document.getElementById('cpStickyBottom');
    var ctas  = document.getElementById('cpPrimaryCtas');
    if (!bar || !ctas) return;
    var obs = new IntersectionObserver(function(entries) {
      entries.forEach(function(entry) {
        bar.classList.toggle('visible', !entry.isIntersecting);
      });
    }, { threshold: 0 });
    obs.observe(ctas);
  }

  /* ══════════════════════════════════════════
     SCROLL HEADER (add .scrolled class)
  ══════════════════════════════════════════ */
  function initScrollHeader() {
    var header = document.getElementById('cpHeader');
    if (!header) return;
    window.addEventListener('scroll', function() {
      header.classList.toggle('scrolled', window.scrollY > 50);
    }, { passive: true });
  }

  /* ══════════════════════════════════════════
     MORE MENU
  ══════════════════════════════════════════ */
  function initMoreMenu() {
    var menuBtn = document.getElementById('menuBtn');
    var menu    = document.getElementById('cpMoreMenu');
    var overlay = document.getElementById('cpMoreOverlay');
    if (!menuBtn || !menu) return;

    function openMenu()  { menu.classList.add('open');    if (overlay) overlay.classList.add('active'); }
    function closeMenu() { menu.classList.remove('open'); if (overlay) overlay.classList.remove('active'); }

    menuBtn.addEventListener('click', function(e) {
      e.stopPropagation();
      menu.classList.contains('open') ? closeMenu() : openMenu();
    });
    if (overlay) overlay.addEventListener('click', closeMenu);

    var shareBtn = document.getElementById('shareProfileBtn');
    if (shareBtn) {
      shareBtn.addEventListener('click', function() {
        closeMenu();
        if (navigator.share) {
          navigator.share({ title: document.title, url: window.location.href }).catch(function() {});
        } else if (navigator.clipboard) {
          navigator.clipboard.writeText(window.location.href).then(function() { showToast('Profile link copied'); });
        } else {
          showToast('Share — coming soon');
        }
      });
    }
    var saveBtn = document.getElementById('saveExpertBtn');
    if (saveBtn) {
      saveBtn.addEventListener('click', function() { closeMenu(); showToast('Expert saved to your list'); });
    }
  }

  /* ══════════════════════════════════════════
     CTA BUTTONS
  ══════════════════════════════════════════ */
  function initCTAs(coach) {
    function openChatModal() {
      /* Active Personal Coaching → the workspace IS the chat */
      if (_coachingWorkspaceFor(coach)) { _openCoachingWorkspace(coach, 'chat'); return; }
      updateChipPresence(buildContextPackage(), 'ctxChips');
      var modal = document.getElementById('contextModal');
      if (modal) { modal.classList.add('open'); document.body.style.overflow = 'hidden'; }
    }

    ['inlineChatBtn', 'stickyChatBtn'].forEach(function(id) {
      var btn = document.getElementById(id);
      if (btn) btn.addEventListener('click', openChatModal);
    });
    /* The old Call Now buttons here were always a stub toast — real calling
       lives in the chat header. They are now the Personal Coaching entry. */
    initPersonalCoaching(coach);
  }

  /* ══════════════════════════════════════════
     PERSONAL COACHING
     Firestore: personal_coaching/{athleteUid}
       { coachId, coachName, athleteId, athleteName, startDate, endDate,
         status, subscriptionId, paymentId, fee }
     Doc id = athlete uid → structurally ONE relationship doc per athlete;
     a transaction guards against replacing a different coach's active
     subscription. Ended/expired relationships flip status, never delete.
  ══════════════════════════════════════════ */
  /* Delegates to the canonical gate (assets/js/coaching-gate.js) — kept as
     a thin wrapper since this name is used at many call sites in this file. */
  function _coachingIsActive(rel) {
    return typeof ZitlasCoachingGate !== 'undefined' ? ZitlasCoachingGate.evaluate(rel).active
      : !!(rel && rel.status === 'active' && (!rel.endDate || new Date(rel.endDate) > new Date()));
  }

  /* Lifecycle: plan sheet → personal_coach_requests doc (pending) →
     expert Accepts (accepted) → athlete pays → personal_coaching
     relationship (active). Declines notify the athlete; no payment
     happens before expert acceptance. */
  function initPersonalCoaching(coach) {
    var backdrop    = document.getElementById('coachingBackdrop');
    var stepPlans   = document.getElementById('coachingStepPlans');
    var stepSummary = document.getElementById('coachingStepSummary');
    var cancelBtn   = document.getElementById('coachingCancelBtn');
    var backBtn     = document.getElementById('coachingBackBtn');
    var sendBtn     = document.getElementById('coachingSendBtn');
    var buttons     = ['personalCoachBtn', 'stickyCoachBtn']
      .map(function(id) { return document.getElementById(id); })
      .filter(Boolean);
    var endWrap        = document.getElementById('endCoachingWrap');
    var endBtn         = document.getElementById('endCoachingBtn');
    var endBackdrop    = document.getElementById('endCoachingBackdrop');
    var endCancelBtn   = document.getElementById('endCoachingCancelBtn');
    var endConfirmBtn  = document.getElementById('endCoachingConfirmBtn');
    var pcWithdrawWrap    = document.getElementById('pcWithdrawWrap');
    var pcWithdrawBtn     = document.getElementById('pcWithdrawBtn');
    var pcWithdrawBackdrop    = document.getElementById('pcWithdrawBackdrop');
    var pcWithdrawCancelBtn   = document.getElementById('pcWithdrawCancelBtn');
    var pcWithdrawConfirmBtn  = document.getElementById('pcWithdrawConfirmBtn');

    /* Prices come from the expert's own Pricing & Services page (unlimited
       — spec's "No pricing limit, expert decides"); experts who haven't set
       custom pricing yet see today's defaults (499/699/999), unchanged.
       .price ALWAYS holds this real, unmodified price — never zeroed —
       so "the original prices return automatically" the instant
       CLIENT_TRIAL_MODE goes off requires no code change here. Display
       reads go through _coachingDisplayPrice(key) below instead of
       .price directly, so the ₹0 override lives in exactly one place. */
    var _pricing = _getPricing(coach);
    var COACHING_PLANS = {
      diet:     { label: 'Diet Coaching',           icon: '🥗', price: _pricing.coachingDietPrice },
      training: { label: 'Training Coaching',       icon: '💪', price: _pricing.coachingTrainingPrice },
      complete: { label: 'Complete Transformation', icon: '🏆', price: _pricing.coachingCompletePrice },
    };
    /* CLIENT TRIAL MODE (backend/trial_config.py, mirrored client-side by
       ZitlasPayment.isTrialMode() — see assets/js/payment-service.js) —
       single read point for "is coaching free right now", re-evaluated
       live on every call (never cached at init time) so the modal is
       always correct even if the trial flag's one-time /api/system/
       trial-mode fetch resolves after this page has already loaded. */
    function _coachingTrialActive() {
      return typeof ZitlasPayment !== 'undefined' &&
        typeof ZitlasPayment.isTrialMode === 'function' && ZitlasPayment.isTrialMode();
    }
    function _coachingDisplayPrice(key) {
      return _coachingTrialActive() ? 0 : COACHING_PLANS[key].price;
    }

    var _myCoaching   = null;  /* personal_coaching/{uid} doc */
    var _myRequests   = [];    /* all my personal_coach_requests */
    var _selectedPlan = null;
    var _prevReqStatuses = {}; /* requestId → last seen status (for decline/accept toasts) */

    /* ══════════════════════════════════════════
       SINGLE SOURCE OF TRUTH — Personal Coaching request/relationship
       state. Every button/wrap in this file reads "is there a live
       pending request" ONLY through _openRequestFor()/_anyOpenRequest()
       below — never a raw "does a matching doc exist" check.

       THE BUG THIS FIXES: the old _openRequestFor did
         _myRequests.find(r => r.expertId === expertId && r.status === 'pending')
       — Array.find() returns the FIRST match in whatever order Firestore
       delivered the onSnapshot docs, which has NO guaranteed temporal
       ordering without an explicit .orderBy() on the query (there isn't
       one here). So once an athlete had cycled through more than one
       personal_coach_requests doc for the same expert (declined-then-
       retried, or in this codebase's history before the current
       "at most one open request platform-wide" backend guard existed),
       an OLD orphaned 'pending' doc could be matched by .find() even
       though a NEWER doc for the same relationship had already correctly
       progressed to 'active' and then 'ended' — exactly the reported
       symptom: personal_coach_requests shows status:'ended' and
       personal_coaching shows endedBy/endedAt, yet the button still says
       "Under Review" forever, because .find() was reading a different,
       older document than the one that actually got ended.

       FIX: always resolve to the MOST RECENT request per expert (sorted
       by createdAt) — never "any doc that happens to match" — and, as
       explicit defense-in-depth for spec rule 4/5 ("ignore ALL ended
       relationships"), a request is additionally treated as stale/
       superseded whenever this expert's relationship has already
       concluded (status ended/expired, or endedBy/endedAt present) at or
       after that request was created. Missing timestamps fail CLOSED
       (treated as stale) rather than risk resurrecting a dead request. */
    function _latestRequestFor(expertId) {
      var mine = _myRequests.filter(function(r) { return r.expertId === expertId; });
      if (!mine.length) return null;
      mine.sort(function(a, b) {
        return new Date(b.createdAt || b.reservedAt || b.submittedAt || 0) -
               new Date(a.createdAt || a.reservedAt || a.submittedAt || 0);
      });
      return mine[0];
    }
    /* True only when _myCoaching is THIS expert's relationship AND that
       relationship has definitively concluded — never inferred from mere
       document existence. */
    function _relationshipEndedFor(expertId) {
      if (!_myCoaching || _myCoaching.coachId !== expertId) return false;
      return _myCoaching.status === 'ended' || _myCoaching.status === 'expired' ||
        !!_myCoaching.endedBy || !!_myCoaching.endedAt;
    }
    /* 'accepted' is no longer an observable status — accept debits and
       activates atomically server-side (routes/coaching.py), so a request
       goes straight from 'pending' to 'active' with nothing in between. */
    function _openRequestFor(expertId) {
      var req = _latestRequestFor(expertId);
      if (!req || req.status !== 'pending') return null;
      if (_relationshipEndedFor(expertId)) {
        var reqCreatedAt = req.createdAt || req.reservedAt || req.submittedAt || null;
        var relEndedAt   = _myCoaching.endedAt || null;
        var requestIsNewerThanEnd = !!(reqCreatedAt && relEndedAt &&
          new Date(reqCreatedAt) > new Date(relEndedAt));
        /* A genuinely NEW request made AFTER ending (renewal) still shows
           Under Review, per spec: "The athlete should be able to request
           coaching again after ending it." Anything else — including
           missing timestamps — is treated as a stale leftover. */
        if (!requestIsNewerThanEnd) return null;
      }
      return req;
    }
    function _anyOpenRequest() {
      var candidates = _myRequests.filter(function(r) { return r.status === 'pending'; });
      for (var i = 0; i < candidates.length; i++) {
        var live = _openRequestFor(candidates[i].expertId);
        if (live) return live;
      }
      return null;
    }

    var COACH_SVG = '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>';

    function updateCoachButtons() {
      var gate = (typeof ZitlasCoachingGate !== 'undefined')
        ? ZitlasCoachingGate.evaluate(_myCoaching) : { active: false, expired: false, daysRemaining: null };
      var relMine    = gate.active && _myCoaching.coachId === coach.id;
      var expiredMine = gate.expired && _myCoaching && _myCoaching.coachId === coach.id;
      var req        = _openRequestFor(coach.id);
      buttons.forEach(function(btn) {
        btn.classList.toggle('cp-coach-active', relMine || !!req);
        if (relMine)          btn.innerHTML = COACH_SVG + ' Your Coach ✓';
        else if (expiredMine) btn.innerHTML = COACH_SVG + ' 🔄 Renew Personal Coach';
        else if (req)         btn.innerHTML = COACH_SVG + ' ⏳ Under Review';
        else                  btn.innerHTML = COACH_SVG + ' Personal Coach';
      });
      if (endWrap) endWrap.style.display = relMine ? 'block' : 'none';
      /* Withdraw Request — visible ONLY while a request to THIS expert is
         genuinely pending. req is already status==='pending'-filtered by
         _openRequestFor, so on its own this would hide automatically the
         instant the request leaves 'pending' (declined/expired/withdrawn).
         The explicit `&& !relMine` guard additionally covers the accept
         path: personal_coaching (relMine) and personal_coach_requests
         (req) are two SEPARATE onSnapshot listeners updated by the same
         atomic server-side transaction, but Firestore delivers their
         snapshots to the client independently — relMine can flip true a
         tick before req flips to non-pending. Without this guard, Case 3
         ("never show Withdraw once accepted") could flash-fail for one
         render. */
      if (pcWithdrawWrap) pcWithdrawWrap.style.display = (req && !relMine) ? 'block' : 'none';

      /* <7 days warning + days-remaining, computed once per relationship
         from the canonical gate — reused for both the athlete-facing
         banner here and the coach-side roster in expert-dashboard.js. */
      var expiryWrap = document.getElementById('coachingExpiryWrap');
      if (expiryWrap) {
        if (relMine && gate.daysRemaining !== null) {
          expiryWrap.style.display = '';
          expiryWrap.innerHTML = gate.daysRemaining <= 7
            ? '⚠️ Your Personal Coaching expires in ' + gate.daysRemaining + (gate.daysRemaining === 1 ? ' day' : ' days') + '.'
            : gate.daysRemaining + ' days remaining';
          expiryWrap.classList.toggle('cp-expiry-warning', gate.daysRemaining <= 7);
        } else {
          expiryWrap.style.display = 'none';
        }
      }
    }

    function showStep(which) {
      if (stepPlans)   stepPlans.style.display   = which === 'plans'   ? '' : 'none';
      if (stepSummary) stepSummary.style.display = which === 'summary' ? '' : 'none';
    }
    function openCoachingSheet() {
      if (!backdrop) return;
      _selectedPlan = null;
      showStep('plans');
      /* Plan cards ship with static ₹499/699/999 markup — overwrite with
         this expert's actual pricing (or ₹0 during the trial) every time
         the sheet opens, so it's always current even if trial mode
         flips between opens. */
      Object.keys(COACHING_PLANS).forEach(function(key) {
        var priceEl = backdrop.querySelector('.cp-plan-card[data-plan="' + key + '"] .cp-plan-price');
        if (priceEl) priceEl.innerHTML = '₹' + _coachingDisplayPrice(key) + '<em>/mo</em>';
      });
      backdrop.style.display = 'flex';
      requestAnimationFrame(function() {
        requestAnimationFrame(function() { backdrop.classList.add('open'); });
      });
    }
    function closeCoachingSheet() {
      if (!backdrop) return;
      backdrop.classList.remove('open');
      setTimeout(function() { backdrop.style.display = 'none'; }, 200);
    }

    /* Plan card selection → summary */
    if (backdrop) {
      backdrop.querySelectorAll('.cp-plan-card').forEach(function(card) {
        card.addEventListener('click', function() {
          var key  = card.dataset.plan;
          var plan = COACHING_PLANS[key];
          if (!plan) return;
          _selectedPlan = key;
          var se = document.getElementById('pcSummaryExpert');
          var sp = document.getElementById('pcSummaryPlan');
          var sr = document.getElementById('pcSummaryPrice');
          if (se) se.textContent = coach.name || 'Expert';
          if (sp) sp.textContent = plan.icon + ' ' + plan.label;
          if (sr) sr.textContent = '₹' + _coachingDisplayPrice(key) + ' / month';
          showStep('summary');
        });
      });
      backdrop.addEventListener('click', function(e) {
        if (e.target === backdrop) closeCoachingSheet();
      });
    }
    if (cancelBtn) cancelBtn.addEventListener('click', closeCoachingSheet);
    if (backBtn)   backBtn.addEventListener('click', closeCoachingSheet);

    /* Entry buttons */
    buttons.forEach(function(btn) {
      btn.addEventListener('click', function() {
        console.log('[COACHING] button clicked');
        if (_coachingIsActive(_myCoaching)) {
          if (_myCoaching.coachId === coach.id) {
            if (window.ZitlasCoachingWorkspace) _openCoachingWorkspace(coach, 'overview');
            else openChatOverlay('', buildContextPackage(), 'chat', coach);
          } else {
            showToast('You already have an active coach: ' + (_myCoaching.coachName || 'another expert') + '. One coach at a time.');
          }
          return;
        }
        var req = _openRequestFor(coach.id);
        if (req) { showToast('Your coaching request is awaiting ' + (coach.name || 'the expert') + "'s response."); return; }
        var other = _anyOpenRequest();
        if (other) {
          showToast('You already have a coaching request with ' + (other.expertName || 'another expert') + '.');
          return;
        }
        openCoachingSheet();
      });
    });

    /* Send Coaching Request — reserves (locks) the plan price server-side
       the instant this is sent (backend/routes/coaching.py POST /request).
       Nothing is spent until the expert accepts — see accept_request,
       which auto-debits and activates atomically, no manual payment step.
       The client-side balance check below is a fast, DISPLAY-ONLY
       pre-check; the backend re-validates authoritatively inside its own
       transaction and is the only party that can actually move money. */
    if (sendBtn) {
      sendBtn.addEventListener('click', function() {
        if (!_selectedPlan) return;
        var uid = _getMyUserId();
        if (!uid) { showToast('Please sign in first.'); return; }
        if (typeof getIdToken !== 'function') { showToast('Connection unavailable — please try again.'); return; }

        var plan = COACHING_PLANS[_selectedPlan];
        /* CLIENT TRIAL MODE (backend/trial_config.py) — coach hiring is
           free: skip the wallet pre-check entirely; the backend reserves
           ₹0. When the trial flag is off this check is live again. */
        var _coachingTrial = (typeof ZitlasPayment !== 'undefined' &&
          typeof ZitlasPayment.isTrialMode === 'function' && ZitlasPayment.isTrialMode());
        if (!_coachingTrial) {
          var w = {};
          try { w = JSON.parse(localStorage.getItem('zitlas_wallet') || '{}') || {}; } catch (_) {}
          var available = Number(w.balance || 0) - Number(w.reserved || 0);
          if (available < plan.price) {
            if (typeof ZitlasPayment !== 'undefined') {
              ZitlasPayment.showLowBalancePopup({ balance: available, required: plan.price });
            } else {
              showToast('Insufficient wallet balance — please recharge.');
            }
            return;
          }
        }

        sendBtn.disabled = true;
        sendBtn.textContent = 'Sending…';

        getIdToken().then(function(token) {
          return fetch('/api/coaching/request', {
            method: 'POST',
            headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
            body: JSON.stringify({ expertId: coach.id, planType: _selectedPlan }),
          });
        }).then(function(res) {
          return res.json().catch(function() { return {}; }).then(function(data) {
            return { status: res.status, data: data };
          });
        }).then(function(result) {
          if (result.status === 200 && result.data.success) {
            console.log('[COACHING] request reserved — personal_coach_requests/' + result.data.requestId);
            closeCoachingSheet();
            showToast(Number(result.data.amount) > 0
              ? '📨 Request sent — ₹' + result.data.amount + ' reserved. You’ll only be charged if ' + (coach.name || 'the expert') + ' accepts.'
              : '📨 Request sent — no charge. ' + (coach.name || 'The expert') + ' will confirm your coaching shortly.');
            return;
          }
          if (result.status === 402) {
            var detail = result.data.detail || {};
            if (typeof ZitlasPayment !== 'undefined') {
              ZitlasPayment.showLowBalancePopup({ balance: detail.available, required: detail.required });
            }
          } else if (result.status === 409) {
            showToast('You already have an open coaching request.');
          } else {
            console.error('[COACHING] request failed', result);
            showToast('Could not send request — please try again.');
          }
        }).catch(function(err) {
          console.error('[COACHING] request failed', err);
          showToast(err && err.message === 'not_signed_in' ? 'Please sign in first.' : 'Could not send request — please try again.');
        }).then(function() {
          sendBtn.disabled = false;
          sendBtn.textContent = 'Send Coaching Request';
        });
      });
    }

    /* End Coaching — athlete-initiated. Only flips the relationship's
       status; diet/training plans, chat history and coach notes are never
       touched — the athlete simply keeps using the last coach-created
       plan until they regenerate AI or hire another coach. */
    function openEndCoachingModal() {
      if (!endBackdrop) return;
      endBackdrop.style.display = 'flex';
      requestAnimationFrame(function() {
        requestAnimationFrame(function() { endBackdrop.classList.add('open'); });
      });
    }
    function closeEndCoachingModal() {
      if (!endBackdrop) return;
      endBackdrop.classList.remove('open');
      setTimeout(function() { endBackdrop.style.display = 'none'; }, 200);
    }
    if (endBtn)       endBtn.addEventListener('click', openEndCoachingModal);
    if (endCancelBtn) endCancelBtn.addEventListener('click', closeEndCoachingModal);
    if (endBackdrop)  endBackdrop.addEventListener('click', function(e) {
      if (e.target === endBackdrop) closeEndCoachingModal();
    });
    if (endConfirmBtn) {
      endConfirmBtn.addEventListener('click', function() {
        var uid = _getMyUserId();
        if (!uid || !_myCoaching) { closeEndCoachingModal(); return; }
        if (typeof getIdToken !== 'function') { showToast('Connection unavailable — please try again.'); return; }
        var requestId = _myCoaching.requestId;
        console.log('[COACHING] ending via POST /api/coaching/end — athlete=' + uid);

        endConfirmBtn.disabled = true;
        endConfirmBtn.textContent = 'Ending…';
        var _endedAtIso = new Date().toISOString();

        /* SINGLE SOURCE OF TRUTH / CLIENT PARITY: end the relationship through
           the shared backend endpoint — identical to the Flutter client
           (ExpertsRepository.endCoaching -> POST /api/coaching/end). The
           backend flips personal_coaching -> 'ended', closes the originating
           personal_coach_request, and notifies BOTH parties inside one
           transaction (routes/coaching.py end_coaching). This replaces the
           website's previous direct Firestore writes + client-side
           notification, which duplicated business logic across clients and
           skipped the request-closure/notification steps the backend owns. */
        getIdToken().then(function(token) {
          return fetch('/api/coaching/end', {
            method: 'POST',
            headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
          });
        }).then(function(res) {
          return res.json().catch(function() { return {}; }).then(function(data) {
            return { status: res.status, data: data };
          });
        }).then(function(result) {
          // 200 = ended now; 404 = already ended / no active relationship —
          // both mean "you no longer have an active coach", so converge the UI.
          if ((result.status === 200 && result.data.success) || result.status === 404) {
            /* Optimistic local update — flips every Personal Coaching button
               back to "Personal Coach" immediately; the personal_coaching
               onSnapshot listener confirms moments later and remains the
               source of truth. */
            _myCoaching = Object.assign({}, _myCoaching, {
              status: 'ended', endedAt: _endedAtIso, endedBy: 'athlete', reason: 'athlete',
            });
            if (requestId) {
              var _idx = _myRequests.findIndex(function(r) { return r.requestId === requestId; });
              if (_idx !== -1) _myRequests[_idx] = Object.assign({}, _myRequests[_idx], { status: 'ended' });
            }
            updateCoachButtons();
            /* Dismisses any cached Diet/Workout Review (the SEPARATE, older
               one-off-review system) so it can't keep showing an interactive
               "your nutritionist updated your plan" banner after coaching
               ends — the plan itself stays visible, only the pending-review
               association is retired. */
            if (typeof ZitlasCoachingReset !== 'undefined') ZitlasCoachingReset.clearAll({});
            closeEndCoachingModal();
            showToast('Personal coaching ended. Your existing plans remain unchanged.');
          } else {
            console.error('[COACHING] end failed', result);
            showToast('Could not end coaching — please try again.');
          }
        }).catch(function(err) {
          console.error('[COACHING] end coaching failed', err);
          showToast('Could not end coaching — please try again.');
        }).then(function() {
          endConfirmBtn.disabled = false;
          endConfirmBtn.textContent = 'End Coaching';
        });
      });
    }

    /* Withdraw Personal Coaching Request — athlete-initiated cancellation
       of their OWN pending request. Mirrors End Coaching's modal pattern
       exactly (JS-driven display + .open animation, 200ms close delay).
       The actual release happens server-side (POST /api/coaching/withdraw,
       routes/coaching.py) inside the same kind of Firestore transaction
       /reject uses — the reserved amount is released back to `available`
       atomically, never a client-side wallet write. */
    function openPcWithdrawModal() {
      if (!pcWithdrawBackdrop) return;
      pcWithdrawBackdrop.style.display = 'flex';
      requestAnimationFrame(function() {
        requestAnimationFrame(function() { pcWithdrawBackdrop.classList.add('open'); });
      });
    }
    function closePcWithdrawModal() {
      if (!pcWithdrawBackdrop) return;
      pcWithdrawBackdrop.classList.remove('open');
      setTimeout(function() { pcWithdrawBackdrop.style.display = 'none'; }, 200);
    }
    if (pcWithdrawBtn)      pcWithdrawBtn.addEventListener('click', openPcWithdrawModal);
    if (pcWithdrawCancelBtn) pcWithdrawCancelBtn.addEventListener('click', closePcWithdrawModal);
    if (pcWithdrawBackdrop) pcWithdrawBackdrop.addEventListener('click', function(e) {
      if (e.target === pcWithdrawBackdrop) closePcWithdrawModal();
    });
    if (pcWithdrawConfirmBtn) {
      pcWithdrawConfirmBtn.addEventListener('click', function() {
        var reqToWithdraw = _openRequestFor(coach.id);
        /* Safety rule: only a PENDING request may be withdrawn — same
           guard the review-withdraw flow uses. Covers the race where the
           expert accepts/declines in the moments between opening this
           modal and clicking Confirm. */
        if (!reqToWithdraw) {
          console.error('[COACHING WITHDRAW] blocked — no pending request to withdraw');
          closePcWithdrawModal();
          showToast('This request can no longer be withdrawn.');
          updateCoachButtons();
          return;
        }
        if (typeof getIdToken !== 'function') {
          showToast('Connection unavailable — please try again.');
          return;
        }

        pcWithdrawConfirmBtn.disabled = true;
        pcWithdrawConfirmBtn.textContent = 'Withdrawing…';
        console.log('[COACHING WITHDRAW] withdrawing', reqToWithdraw.requestId, '(expert:', coach.id + ')');

        getIdToken().then(function(token) {
          return fetch('/api/coaching/withdraw', {
            method: 'POST',
            headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId: reqToWithdraw.requestId }),
          });
        }).then(function(res) {
          return res.json().catch(function() { return {}; }).then(function(data) {
            return { status: res.status, data: data };
          });
        }).then(function(result) {
          if (result.status === 200 && result.data.success) {
            console.log('[COACHING WITHDRAW] success —', reqToWithdraw.requestId);
            /* Optimistic local update — flips the button back to "Personal
               Coach" and hides the Withdraw action immediately, without
               waiting for the Firestore listener (which confirms moments
               later and is the eventual source of truth). */
            var idx = _myRequests.findIndex(function(r) { return r.requestId === reqToWithdraw.requestId; });
            if (idx !== -1) {
              _myRequests[idx] = Object.assign({}, _myRequests[idx], { status: 'withdrawn' });
            }
            closePcWithdrawModal();
            updateCoachButtons();
            showToast('Request withdrawn. Any reserved amount has been released.');
          } else if (result.status === 409) {
            showToast('This request can no longer be withdrawn.');
            closePcWithdrawModal();
          } else if (result.status === 403 || result.status === 404) {
            showToast('This request is no longer available.');
            closePcWithdrawModal();
          } else {
            console.error('[COACHING WITHDRAW] failed', result);
            showToast('Could not withdraw request — please try again.');
          }
        }).catch(function(err) {
          console.error('[COACHING WITHDRAW] failed', err);
          showToast(err && err.message === 'not_signed_in' ? 'Please sign in first.' : 'Could not withdraw request — please try again.');
        }).then(function() {
          pcWithdrawConfirmBtn.disabled = false;
          pcWithdrawConfirmBtn.textContent = 'Withdraw Request';
        });
      });
    }

    /* Realtime listeners */
    if (typeof ZitlasDB !== 'undefined') {
      var uid = _getMyUserId();
      if (uid) {
        /* Coaching notifications ("Coach updated your diet", replies, etc.)
           surface as toasts on this page even before the workspace opens. */
        if (window.ZitlasCoachingWorkspace) {
          ZitlasCoachingWorkspace.attachNotifications(uid, showToast);
        }
        ZitlasDB.collection('personal_coaching').doc(uid).onSnapshot(function(snap) {
          _myCoaching = snap.exists ? snap.data() : null;
          _pcRelationship = _myCoaching;
          console.log('[COACHING] relationship:', _myCoaching
            ? _myCoaching.status + ' with ' + _myCoaching.coachName : 'none');
          updateCoachButtons();
          _applyChatReadOnlyState();
        }, function(err) { console.warn('[COACHING] relationship listener error', err); });

        ZitlasDB.collection('personal_coach_requests')
          .where('athleteId', '==', uid)
          .onSnapshot(function(snap) {
            _myRequests = snap.docs.map(function(d) { return d.data(); });
            console.log('[COACHING] my requests:', _myRequests.map(function(r) {
              return r.requestId + ':' + r.status;
            }));
            /* Status-transition toasts. Notification DOCS are now written
               server-side (backend/routes/coaching.py accept/reject,
               services/coaching_sweep.py expiry) — this only drives an
               immediate in-session toast for an athlete already on this
               page, without sending a second duplicate notification. */
            _myRequests.forEach(function(r) {
              var prev = _prevReqStatuses[r.requestId];
              if (prev && prev !== r.status) {
                if (r.status === 'declined') {
                  showToast('Your coaching request was declined. Reserved amount released.');
                } else if (r.status === 'expired') {
                  showToast('Your coaching request expired. Reserved amount released.');
                } else if (r.status === 'active') {
                  showToast('🎉 ' + (r.expertName || 'The expert') + ' accepted — coaching started!');
                }
              }
              _prevReqStatuses[r.requestId] = r.status;
            });
            updateCoachButtons();
          }, function(err) { console.warn('[COACHING] requests listener error', err); });
      }
    }
  }

  /* ══════════════════════════════════════════
     SCROLL ANIMATIONS
  ══════════════════════════════════════════ */
  function initScrollAnimations() {
    if (!('IntersectionObserver' in window)) return;
    var observer = new IntersectionObserver(function(entries) {
      entries.forEach(function(entry) {
        if (entry.isIntersecting) {
          entry.target.style.opacity = '1';
          entry.target.style.transform = 'translateY(0)';
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.1 });

    ['.cp-tag', '.cp-review-card', '.cp-metric-card', '.cp-service-card', '.cp-gallery-card', '.cp-trust-item'].forEach(function(sel) {
      document.querySelectorAll(sel).forEach(function(el, i) {
        el.style.opacity = '0';
        el.style.transform = 'translateY(10px)';
        el.style.transition = 'opacity 0.35s ease ' + (0.05 * i) + 's, transform 0.4s ease ' + (0.05 * i) + 's';
        observer.observe(el);
      });
    });
  }

  /* ══════════════════════════════════════════
     INIT
  ══════════════════════════════════════════ */
  /* Refresh only the fields that can change when a profile is saved */
  function _refreshProfileOverlay(baseCoach) {
    if (!window.ZitlasExpertProfile) return;
    var p = ZitlasExpertProfile.getProfile();
    if (!p) return;

    if (p.name) {
      setText('coachName',      p.name);
      setText('cpHdrName',      (p.name.split(/\s+/)[0] || p.name));
      setText('chatHdrName',    p.name);
      setText('modalCoachName', p.name);
    }
    if (p.specialization) {
      setText('coachRole',      p.specialization);
      setText('chatHdrRole',    p.specialization);
      setText('modalCoachRole', p.specialization);
    }
    if (p.bio)          setText('aboutText', p.bio);
    if (p.experience)   setText('coachExp',  p.experience + '+ Years Experience');

    if (p.reviewFee !== undefined) {
      setText('cpChatRate',  '₹' + p.reviewFee);
      setText('cpCallRate',  '₹' + (p.reviewFee + 30));
      setText('cpStickyAmt', '₹' + p.reviewFee + '/min');
      var ctxFeeEl = document.getElementById('ctxFeeVal');
      if (ctxFeeEl) ctxFeeEl.textContent = '₹' + p.reviewFee;
    }

    if (p.initials) {
      var heroInitialsEl = document.getElementById('cpHeroInitials');
      if (heroInitialsEl && !p.profilePhoto) heroInitialsEl.textContent = p.initials;
      var chatAvEl = document.getElementById('chatHdrAvatar');
      if (chatAvEl && !p.profilePhoto) chatAvEl.textContent = p.initials;
    }

    if (p.profilePhoto) {
      var heroImgEl = document.getElementById('coachImg');
      if (heroImgEl) { heroImgEl.src = p.profilePhoto; heroImgEl.style.display = ''; }
      var heroInitialsEl2 = document.getElementById('cpHeroInitials');
      if (heroInitialsEl2) heroInitialsEl2.classList.remove('show');
      var chatAvEl2 = document.getElementById('chatHdrAvatar');
      if (chatAvEl2) chatAvEl2.innerHTML = '<img src="' + p.profilePhoto + '" style="width:100%;height:100%;object-fit:cover;border-radius:50%;">';
    }

    if (baseCoach) renderMetrics(ZitlasExpertProfile.applyToCoach(baseCoach));
  }

  function _initWithCoach(coach, params) {
    populatePage(coach);
    initVerifiedCertificates(coach);
    initContextModal(coach);
    initVerifyModal(coach);
    initVerifyPlanBtn(coach);
    initChatInput();
    initHeader();
    initMoreMenu();
    initCTAs(coach);
    initReadMore();
    initStickyBottom();
    initScrollHeader();
    initViewAlls();
    initBottomNav();
    initStatCountUp(coach);

    var action = params.get('action');
    if (action === 'ask') {
      setTimeout(function() {
        var btn = document.getElementById('inlineChatBtn');
        if (btn) btn.click();
      }, 450);
    } else if (action === 'verify') {
      setTimeout(function() {
        var btn = document.getElementById('verifyPlanBtn');
        if (btn) btn.click();
      }, 450);
    } else if (action === 'coach') {
      /* From the Experts listing's "Personal Coach" button — same deep-
         link pattern as action=ask/verify above. */
      setTimeout(function() {
        var btn = document.getElementById('personalCoachBtn');
        if (btn) btn.click();
      }, 450);
    }

    requestAnimationFrame(function() { initScrollAnimations(); });
  }

  function _normalizeExpertToCoach(doc) {
    var d = doc.data();
    var nameParts = (d.name || 'Expert').split(/\s+/);
    return {
      id:           doc.id,
      name:         d.name            || 'Expert',
      firstName:    nameParts[0]      || 'Expert',
      role:         d.specialization  || d.speciality || d.role || 'Expert',
      initials:     nameParts.map(function(w){ return w[0]||''; }).slice(0,2).join('').toUpperCase() || 'EX',
      image:        d.profilePhoto    || d.photo || d.image || '',
      colorAccent:  d.colorAccent     || 'var(--primary)',
      rating:       parseFloat(d.rating)          || 5.0,
      reviewCount:  parseInt(d.reviews, 10)       || parseInt(d.reviewCount, 10) || 0,
      experience:   d.experience      || '1+ yr',
      fee:          parseInt(d.fee, 10)            || 0,
      chatRate:     parseInt(d.chatRate, 10)       || parseInt(d.fee, 10) || 0,
      callRate:     parseInt(d.callRate, 10)       || ((parseInt(d.fee, 10) || 0) + 30),
      about:        d.about           || d.bio || '',
      quote:        d.quote           || '',
      languages:    Array.isArray(d.languages) ? d.languages.join(', ') : (d.languages || 'EN'),
      expertise:    Array.isArray(d.specialties) ? d.specialties : (d.speciality ? [d.speciality] : []),
      availability: d.availability    || { isAvailableToday: true, slots: [] },
      stats:        Array.isArray(d.stats) ? d.stats : [],
      reviews:      Array.isArray(d.clientReviews) ? d.clientReviews : [],
      gallery:      Array.isArray(d.gallery) ? d.gallery : [],
      verified:     d.verified === true,
      verification: d.verification || null,
      pricing:      d.pricing || null,
    };
  }

  /* Every screen that shows or charges a price reads through this one
     function — experts who haven't opened Pricing & Services yet still work
     exactly as before (today's fixed defaults), and any expert who HAS set
     custom pricing has it respected everywhere consistently. */
  var PRICING_DEFAULTS = {
    dietReviewPrice: 49, workoutReviewPrice: 59, bothReviewPrice: 99, chatPrice: 149,
    coachingDietPrice: 499, coachingTrainingPrice: 699, coachingCompletePrice: 999,
  };
  function _getPricing(coach) {
    return Object.assign({}, PRICING_DEFAULTS, (coach && coach.pricing) || {});
  }

  function _findLocalExpert(expertId) {
    var list = [];
    try {
      var _p = JSON.parse(localStorage.getItem('zitlas_experts'));
      if (Array.isArray(_p)) list = _p;
    } catch(_) {}
    var e = list.find(function(x) { return String(x.id) === String(expertId); });
    if (!e) return null;
    var nameParts = (e.name || 'Expert').split(/\s+/);
    return {
      id:           e.id,
      name:         e.name           || 'Expert',
      firstName:    nameParts[0]     || 'Expert',
      role:         e.specialization || e.role || 'Expert',
      initials:     nameParts.map(function(w){ return w[0]||''; }).slice(0,2).join('').toUpperCase() || 'EX',
      image:        e.image          || '',
      colorAccent:  'var(--primary)',
      rating:       parseFloat(e.rating) || 5.0,
      reviewCount:  0,
      experience:   '1+ yr',
      fee:          parseInt(e.fee, 10)  || 0,
      chatRate:     parseInt(e.fee, 10)  || 0,
      callRate:     (parseInt(e.fee, 10) || 0) + 30,
      about:        '',
      quote:        '',
      languages:    'EN',
      expertise:    e.specialization ? [e.specialization] : [],
      availability: { isAvailableToday: true, slots: [] },
      stats:        [],
      reviews:      [],
      gallery:      [],
      verified:     false,
    };
  }

  function init() {
    loadTheme();

    var _nb = document.getElementById('zitlas-navbar');
    if (_nb) document.documentElement.style.setProperty('--nav-height', (window.innerHeight - _nb.getBoundingClientRect().top) + 'px');

    var params   = new URLSearchParams(window.location.search);
    var expertId = params.get('expertId') || params.get('id');

    console.log('[EXPERT PROFILE] Loading expert:', expertId);

    if (!expertId) {
      window.location.href = 'coaches.html';
      return;
    }

    if (typeof ZitlasDB === 'undefined') {
      var _local = _findLocalExpert(expertId);
      if (_local) { _initWithCoach(_local, params); return; }
      showToast('Could not connect to database. Please try again.');
      setTimeout(function() { window.location.href = 'coaches.html'; }, 1800);
      return;
    }

    ZitlasDB.collection('experts').doc(expertId).get().then(function(doc) {
      if (!doc.exists) {
        /* Expert definitively does not exist in Firestore — do NOT fall
           back to the local zitlas_experts cache. A review sent to a
           nonexistent uid is a black hole (no dashboard ever queries it). */
        console.warn('[EXPERT PROFILE] experts/' + expertId + ' not found — stale link or deleted expert');
        showToast('Expert profile not found.');
        setTimeout(function() { window.location.href = 'coaches.html'; }, 1800);
        return;
      }
      var coach = _normalizeExpertToCoach(doc);
      console.log('[EXPERT PROFILE] Firebase expert:', coach);
      _initWithCoach(coach, params);
    }).catch(function(err) {
      console.warn('[EXPERT PROFILE] Firebase error:', err);
      var _local = _findLocalExpert(expertId);
      if (_local) { _initWithCoach(_local, params); return; }
      showToast('Failed to load expert profile.');
      setTimeout(function() { window.location.href = 'coaches.html'; }, 1800);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
