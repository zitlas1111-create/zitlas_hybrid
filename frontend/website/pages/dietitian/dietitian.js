/* =============================================
   ZITLAS Experts Marketplace — dietitian.js
   ============================================= */

'use strict';

/* Expert data loaded from Firestore 'experts' collection (approved only) */
let _expertsData = [];

/* ── State ── */
const state = {
  activeFilters: { lang: 'all', mode: null, fee: null, sport: null },
  isElite: false,
};

/* ── DOM refs ── */
const dtList         = document.getElementById('dtList');
const dtEmpty        = document.getElementById('dtEmpty');
const dtCount        = document.getElementById('dtCount');
const activeFilters  = document.getElementById('activeFilters');
const eliteBanner    = document.getElementById('eliteBanner');
const dtNotifyBanner = document.getElementById('dtNotifyBanner');

/* ────────────────────────────────────────────
   PROFILE NAVIGATION
   ──────────────────────────────────────────── */
function goToProfile(id) {
  window.location.href = '../coaches/cprofile.html?id=' + id;
}

/* ────────────────────────────────────────────
   INIT
   ──────────────────────────────────────────── */
function loadExpertsFromFirebase() {
  if (typeof ZitlasDB === 'undefined') {
    renderCards(_expertsData);
    return;
  }
  ZitlasDB.collection('experts')
    .where('approved', '==', true)
    .get()
    .then(function(snapshot) {
      _expertsData = [];
      snapshot.forEach(function(doc) {
        var d = doc.data();
        var expYrs = parseInt(d.experience, 10) || 0;
        _expertsData.push({
          id:            doc.id,
          name:          d.name           || 'Expert',
          specialization:d.specialization || d.role || 'Expert',
          experience:    expYrs,
          rating:        parseFloat(d.rating) || 5.0,
          reviews:       parseInt(d.reviewCount, 10) || 0,
          languages:     Array.isArray(d.languages)  ? d.languages  : ['English'],
          sports:        Array.isArray(d.specialties) ? d.specialties.map(function(s){ return s.replace(/_/g,' ').replace(/\b\w/g,function(c){return c.toUpperCase();}); }) : [],
          fee:           parseInt(d.fee, 10) || 0,
          mode:          d.status === 'offline' ? ['offline'] : ['online'],
          initials:      d.initials || (d.name||'EX').split(/\s+/).map(function(w){return w[0]||'';}).slice(0,2).join('').toUpperCase(),
          color:         d.colorAccent || 'var(--primary)',
          verified:      true,
        });
      });
      renderCards(_expertsData);
    })
    .catch(function() {
      renderCards(_expertsData); // shows empty state
    });
}

function init() {
  var _nb = document.getElementById('zitlas-navbar');
  if (_nb) document.documentElement.style.setProperty('--nav-height', (window.innerHeight - _nb.getBoundingClientRect().top) + 'px');

  detectElite();
  renderCards(_expertsData); // shows empty state while loading
  loadExpertsFromFirebase();
  bindFilters();
  bindNav();

  if (window.ZitlasLang) window.ZitlasLang.applyTranslations();
}

function detectElite() {
  const profile = JSON.parse(localStorage.getItem('athlete_profile') || '{}');
  state.isElite = profile.athlete_tier === 'Elite';
  if (!state.isElite) {
    eliteBanner.style.display = 'none';
  }
}

/* ────────────────────────────────────────────
   RENDER CARDS
   ──────────────────────────────────────────── */
function renderCards(list) {
  dtList.innerHTML = '';

  if (list.length === 0) {
    /* If no experts exist at all (not a filter miss) show the notify banner */
    if (_expertsData.length === 0) {
      dtEmpty.style.display = 'none';
      dtNotifyBanner.style.display = 'flex';
      var titleEl = dtNotifyBanner.querySelector('.dt-notify-title');
      var subEl   = dtNotifyBanner.querySelector('.dt-notify-sub');
      if (titleEl) titleEl.textContent = 'No Experts Available';
      if (subEl)   subEl.textContent   = 'Experts will appear here once approved by the ZITLAS team.';
      var notifyBtn = dtNotifyBanner.querySelector('.dt-notify-btn');
      if (notifyBtn) {
        /* Expert onboarding is frozen — the CTA must not invite an
           application it cannot accept. */
        notifyBtn.textContent = 'Expert onboarding is closed';
        notifyBtn.disabled = true;
        notifyBtn.onclick = function() { window.location.href = '../login/login.html'; };
      }
    } else {
      dtEmpty.style.display = 'flex';
      dtNotifyBanner.style.display = 'none';
    }
    dtCount.textContent = '0 available';
    return;
  }

  dtEmpty.style.display = 'none';
  dtNotifyBanner.style.display = 'none';
  dtCount.textContent = `${list.length} available`;

  list.forEach(d => {
    const card = buildCard(d);
    dtList.appendChild(card);
  });
}

function buildCard(d) {
  /* Apply live profile data for the logged-in expert */
  if (window.ZitlasExpertProfile && d.id === ZitlasExpertProfile.getExpertId()) {
    d = ZitlasExpertProfile.applyToCard(d);
  }

  const isFreeForElite = state.isElite;

  const card = document.createElement('div');
  card.className = 'dt-card';
  card.dataset.id = d.id;
  card.style.cursor = 'pointer';

  const modesHtml = d.mode.map(m =>
    m === 'online'
      ? `<span class="dt-meta-chip"><span class="filter-dot filter-dot-green"></span>Online</span>`
      : `<span class="dt-meta-chip"><span class="filter-dot" style="background:var(--text-muted)"></span>Offline</span>`
  ).join('');

  const langsHtml = d.languages.map(l =>
    `<span class="dt-lang-tag">${l}</span>`
  ).join('');

  const sportsHtml = d.sports.map(s =>
    `<span class="dt-sport-tag">${s}</span>`
  ).join('');

  const verifiedSvg = d.verified
    ? `<svg class="dt-verified-badge" viewBox="0 0 24 24" fill="var(--ai-accent)"><path d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"/></svg>`
    : '';

  const freeTag = isFreeForElite
    ? `<span class="dt-free-badge">1 Free (Elite)</span>`
    : '';

  card.innerHTML = `
    <div class="dt-card-top">
      <div class="dt-avatar" style="background:${d.color}">
        <span class="dt-avatar-initials">${d.initials}</span>
        <span class="${d.mode.includes('online') ? 'dt-online-dot' : 'dt-offline-dot'}"></span>
      </div>
      <div class="dt-card-info">
        <div class="dt-card-name-row">
          <span class="dt-card-name">${d.name}</span>
          ${verifiedSvg}
        </div>
        <p class="dt-card-spec">${d.specialization}</p>
        <div class="dt-card-meta">
          <span class="dt-meta-chip"><span class="dt-meta-icon">🛡️</span>${d.experience} Yrs Exp</span>
          <span class="dt-rating">
            <span class="dt-rating-stars">★★★★★</span>
            <span class="dt-rating-val">${d.rating}</span>
          </span>
          ${modesHtml}
        </div>
      </div>
    </div>
    <div class="dt-card-langs">${langsHtml}</div>
    <div class="dt-card-sports">${sportsHtml}</div>
    <div class="dt-card-bottom">
      <div class="dt-fee-wrap">
        <span class="dt-fee-label">Expert Fee</span>
        <div>
          <span class="dt-fee-price">₹${d.fee}</span>
          <span class="dt-fee-session">/session</span>
        </div>
        ${freeTag}
      </div>
      <div class="dt-card-actions">
        <button class="dt-ask-btn" data-id="${d.id}">Ask Expert →</button>
        <button class="dt-verify-btn" data-id="${d.id}">Verify Plan</button>
      </div>
    </div>
  `;

  /* Whole card click → profile */
  card.addEventListener('click', () => goToProfile(d.id));

  /* Action buttons stop propagation and deep-link to modal */
  card.querySelector('.dt-ask-btn').addEventListener('click', (e) => {
    e.stopPropagation();
    window.location.href = '../coaches/cprofile.html?id=' + d.id + '&action=ask';
  });

  card.querySelector('.dt-verify-btn').addEventListener('click', (e) => {
    e.stopPropagation();
    window.location.href = '../coaches/cprofile.html?id=' + d.id + '&action=verify';
  });

  return card;
}

/* ────────────────────────────────────────────
   FILTERS
   ──────────────────────────────────────────── */
function bindFilters() {
  const pills = document.querySelectorAll('.filter-pill');

  pills.forEach(pill => {
    pill.addEventListener('click', () => {
      const filterType = pill.dataset.filter;
      const value      = pill.dataset.value;

      if (!filterType) return;

      if (filterType === 'lang') {
        document.querySelectorAll('[data-filter="lang"]').forEach(p => p.classList.remove('active'));
        pill.classList.add('active');
        state.activeFilters.lang = value;

      } else if (filterType === 'mode') {
        const wasActive = pill.classList.contains('active-mode-online') || pill.classList.contains('active-mode-offline');
        document.querySelectorAll('[data-filter="mode"]').forEach(p => {
          p.classList.remove('active-mode-online', 'active-mode-offline');
        });
        if (!wasActive) {
          pill.classList.add(value === 'online' ? 'active-mode-online' : 'active-mode-offline');
          state.activeFilters.mode = value;
        } else {
          state.activeFilters.mode = null;
        }

      } else if (filterType === 'fee') {
        const wasActive = pill.classList.contains('active');
        document.querySelectorAll('[data-filter="fee"]').forEach(p => p.classList.remove('active'));
        if (!wasActive) {
          pill.classList.add('active');
          state.activeFilters.fee = value;
        } else {
          state.activeFilters.fee = null;
        }

      } else if (filterType === 'sport') {
        const wasActive = pill.classList.contains('active');
        document.querySelectorAll('[data-filter="sport"]').forEach(p => p.classList.remove('active'));
        if (!wasActive) {
          pill.classList.add('active');
          state.activeFilters.sport = value;
        } else {
          state.activeFilters.sport = null;
        }
      }

      applyFilters();
      renderActiveFilterTags();
    });
  });

  document.getElementById('resetFiltersBtn').addEventListener('click', resetFilters);
}

function applyFilters() {
  const { lang, mode, fee, sport } = state.activeFilters;

  const filtered = _expertsData.filter(d => {
    if (lang && lang !== 'all') {
      const langs = d.languages.map(l => l.toLowerCase());
      if (!langs.includes(lang)) return false;
    }
    if (mode) {
      if (!d.mode.includes(mode)) return false;
    }
    if (fee) {
      if (fee === 'budget'  && d.fee >= 400) return false;
      if (fee === 'mid'     && (d.fee < 400 || d.fee > 600)) return false;
      if (fee === 'premium' && d.fee <= 600) return false;
    }
    if (sport) {
      /* Normalize filter value: 'weight_loss' → 'weight loss' */
      const normalSport = sport.replace(/_/g, ' ');
      const sports = d.sports.map(s => s.toLowerCase());
      if (!sports.includes(normalSport)) return false;
    }
    return true;
  });

  renderCards(filtered);
}

function resetFilters() {
  state.activeFilters = { lang: 'all', mode: null, fee: null, sport: null };
  document.querySelectorAll('.filter-pill').forEach(p => {
    p.classList.remove('active', 'active-mode-online', 'active-mode-offline');
  });
  document.querySelector('[data-filter="lang"][data-value="all"]').classList.add('active');
  renderCards(_expertsData);
  renderActiveFilterTags();
}

function renderActiveFilterTags() {
  const { lang, mode, fee, sport } = state.activeFilters;
  const tags = [];

  if (lang && lang !== 'all') tags.push({ key: 'lang', label: lang });
  if (mode) tags.push({ key: 'mode', label: mode === 'online' ? 'Online' : 'Offline' });
  if (fee) {
    const feeLabels = { budget: 'Under ₹400', mid: '₹400–₹600', premium: '₹600+' };
    tags.push({ key: 'fee', label: feeLabels[fee] });
  }
  if (sport) tags.push({ key: 'sport', label: sport.replace(/_/g, ' ') });

  if (tags.length === 0) {
    activeFilters.style.display = 'none';
    return;
  }

  activeFilters.style.display = 'flex';
  activeFilters.innerHTML = tags.map(t => `
    <span class="active-filter-tag">
      ${t.label}
      <button class="active-filter-remove" data-key="${t.key}" aria-label="Remove ${t.label} filter">×</button>
    </span>
  `).join('');

  activeFilters.querySelectorAll('.active-filter-remove').forEach(btn => {
    btn.addEventListener('click', () => removeFilter(btn.dataset.key));
  });
}

function removeFilter(key) {
  state.activeFilters[key] = key === 'lang' ? 'all' : null;

  if (key === 'lang') {
    document.querySelectorAll('[data-filter="lang"]').forEach(p => p.classList.remove('active'));
    document.querySelector('[data-filter="lang"][data-value="all"]').classList.add('active');
  } else if (key === 'mode') {
    document.querySelectorAll('[data-filter="mode"]').forEach(p => {
      p.classList.remove('active-mode-online', 'active-mode-offline');
    });
  } else if (key === 'fee') {
    document.querySelectorAll('[data-filter="fee"]').forEach(p => p.classList.remove('active'));
  } else if (key === 'sport') {
    document.querySelectorAll('[data-filter="sport"]').forEach(p => p.classList.remove('active'));
  }

  applyFilters();
  renderActiveFilterTags();
}

/* ────────────────────────────────────────────
   NAVIGATION
   ──────────────────────────────────────────── */
function bindNav() {
  document.getElementById('backBtn').addEventListener('click', () => {
    history.back();
  });

  document.getElementById('notifyMeBtn').addEventListener('click', () => {
    showToast('We\'ll notify you when an expert becomes available!');
  });
}

/* ────────────────────────────────────────────
   TOAST
   ──────────────────────────────────────────── */
function showToast(msg) {
  const toast = document.getElementById('toast');
  toast.textContent = msg;
  toast.classList.add('show');
  setTimeout(() => toast.classList.remove('show'), 2800);
}

/* ── Start ── */
document.addEventListener('DOMContentLoaded', init);
