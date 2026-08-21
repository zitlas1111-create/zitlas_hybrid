/* ── ZITLAS Nutritionist Marketplace ── */
'use strict';

// ─── STATE ─────────────────────────────────────────────────────────────────

let _expertsData     = [];
let _loadingExperts  = true;

let currentSort      = 'rated';
let currentSpecialty = 'all';
let searchQuery      = '';

// drawer pending selections (applied on "Apply")
let pendingSort      = 'rated';
let pendingSpecialty = 'all';

// ─── DOM REFS ──────────────────────────────────────────────────────────────

const coachesList        = document.getElementById('coachesList');
const resultsCount       = document.getElementById('resultsCount');
const searchInput        = document.getElementById('searchInput');
const searchClearBtn     = document.getElementById('searchClearBtn');
const filterPills        = document.getElementById('filterPills');
const menuBtn            = document.getElementById('menuBtn');
const sortToggleBtn      = document.getElementById('sortToggleBtn');
const sideDrawer         = document.getElementById('sideDrawer');
const drawerOverlay      = document.getElementById('drawerOverlay');
const drawerCloseBtn     = document.getElementById('drawerCloseBtn');
const drawerApplyBtn     = document.getElementById('drawerApplyBtn');
const drawerSortGroup    = document.getElementById('drawerSortGroup');
const drawerSpecialtyGroup = document.getElementById('drawerSpecialtyGroup');
const toast              = document.getElementById('toast');

// ─── RENDER ────────────────────────────────────────────────────────────────

function avatarBg(n) {
  return `background:${n.color}22;color:${n.color};`;
}

/* Mirrors cprofile.js's PRICING_DEFAULTS/_getPricing exactly — experts who
   haven't opened Pricing & Services yet still show today's fixed defaults,
   and anyone who HAS customized pricing sees it here too. Kept as its own
   copy (not a shared import) because this codebase has no build step /
   module system — every page is a standalone <script>. */
const PRICING_DEFAULTS = { dietReviewPrice: 49, coachingCompletePrice: 999 };

function reviewPriceFor(pricing) {
  var v = pricing && pricing.dietReviewPrice;
  return (v === 0 || (v != null && !isNaN(v))) ? v : PRICING_DEFAULTS.dietReviewPrice;
}

function renderNutritionistCard(n) {
  /* Apply live profile data for the logged-in expert */
  if (window.ZitlasExpertProfile && n.id === ZitlasExpertProfile.getExpertId()) {
    n = ZitlasExpertProfile.applyToCard(n);
  }

  const availClass = n.available ? 'avail-tag--now' : 'avail-tag--later';
  const availText  = n.available ? '🟢 Available Today' : '⏰ Available Tomorrow';
  const langStr    = n.lang.join(', ');

  return `<article class="nutri-card" role="button" tabindex="0" data-id="${n.id}" aria-label="${n.name}, ${n.role}">
  <div class="nutri-left">
    <div class="nutri-avatar-wrap">
      <div class="nutri-avatar" style="${avatarBg(n)}">
        <img src="${n.image}" alt="${n.name}" class="nutri-avatar-img" onerror="this.style.display='none'" />
        <span class="nutri-initials" aria-hidden="true">${n.initials}</span>
      </div>
      ${n.available ? '<span class="avail-dot" title="Available today"></span>' : ''}
    </div>
  </div>
  <div class="nutri-body">
    <div class="nutri-name-row">
      <span class="nutri-name">${n.name}</span>
      ${window.ZitlasBadge ? ZitlasBadge.render(n, { size: 'md' }) : ''}
    </div>
    <span class="nutri-role">${n.role}</span>
    <div class="nutri-rating-row">
      <span class="n-star">★</span>
      <span class="n-score">${n.rating}</span>
      <span class="n-reviews">(${n.reviews})</span>
      <span class="n-sep">·</span>
      <span class="n-exp">${n.exp} yrs</span>
      <span class="n-sep">·</span>
      <span class="n-lang">${langStr}</span>
    </div>
    <div class="nutri-avail-row">
      <span class="avail-tag ${availClass}">${availText}</span>
    </div>

    <!-- Two clearly separate services — never one bare price with no
         context (Priority 2): this page is mostly used for diet review,
         and the old single "₹1000 / 60 Min" line was actually the
         personal-coaching rate, which read as the review price. -->
    <div class="nutri-pricing-row">
      <div class="price-chip price-chip--review">
        <span class="price-chip-label">Diet Review</span>
        <span class="price-chip-value">₹${n.reviewFee}<small>one-time</small></span>
      </div>
      <div class="price-chip price-chip--coaching">
        <span class="price-chip-label">Coaching</span>
        <span class="price-chip-value">₹${n.fee}<small>/ ${n.duration}</small></span>
      </div>
    </div>

    <!-- Two rows, not one cramped row: "Personal Coach" truncated to
         "Personal Coac…" when all three actions shared one line even on a
         standard 390px phone — a full-width primary action plus a second
         row for coach+chat guarantees no label is ever clipped. -->
    <div class="nutri-actions-row nutri-actions-row--primary">
      <button class="nutri-action-btn nutri-action-btn--primary" data-id="${n.id}" data-action="verify" aria-label="Request a diet/workout review from ${n.name}">
        Request Review
      </button>
    </div>
    <div class="nutri-actions-row">
      <button class="nutri-action-btn nutri-action-btn--secondary" data-id="${n.id}" data-action="coach" aria-label="Get personal coaching from ${n.name}">
        Personal Coach
      </button>
      <button class="nutri-action-btn nutri-action-btn--chat" data-id="${n.id}" data-action="ask" aria-label="Chat with ${n.name}">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/>
        </svg>
      </button>
    </div>
  </div>
</article>`;
}

function renderNoExpertsState() {
  var isExpert = localStorage.getItem('zitlas_user_role') === 'expert';
  return `<div class="empty-state">
  <div class="empty-icon">🧑‍⚕️</div>
  <h3 class="empty-heading">No Experts Available</h3>
  <p class="empty-desc">Experts will appear here once approved by the ZITLAS team.</p>
  ${isExpert ? '' : `<p class="empty-desc" style="margin-top:12px;opacity:0.85;">Expert onboarding is currently closed.</p>`}
</div>`;
}

function renderEmptyState() {
  return `<div class="empty-state">
  <div class="empty-icon">🧑‍⚕️</div>
  <h3 class="empty-heading">No experts found</h3>
  <p class="empty-desc">${searchQuery ? `No results for "${searchQuery}". Try a different search.` : 'Try changing your filter or specialty.'}</p>
</div>`;
}

// ─── FILTER + SORT ─────────────────────────────────────────────────────────

function getFiltered() {
  let list = _expertsData.slice();

  if (currentSpecialty !== 'all') {
    list = list.filter(n => n.specialties.includes(currentSpecialty));
  }

  if (searchQuery) {
    const q = searchQuery.toLowerCase();
    list = list.filter(n =>
      n.name.toLowerCase().includes(q) ||
      n.role.toLowerCase().includes(q) ||
      n.specialties.some(s => s.replace(/_/g, ' ').includes(q))
    );
  }

  if (currentSort === 'price') {
    list.sort((a, b) => a.fee - b.fee);
  } else if (currentSort === 'available') {
    list.sort((a, b) => {
      if (a.available !== b.available) return a.available ? -1 : 1;
      return b.rating - a.rating;
    });
  } else {
    list.sort((a, b) => b.rating - a.rating || b.reviews - a.reviews);
  }

  return list;
}

function updateList() {
  if (_loadingExperts) {
    coachesList.innerHTML = '<div class="empty-state"><p class="empty-desc">Loading experts...</p></div>';
    resultsCount.textContent = '...';
    return;
  }
  if (_expertsData.length === 0) {
    coachesList.innerHTML = renderNoExpertsState();
    resultsCount.textContent = '0 Experts';
    return;
  }
  const list = getFiltered();
  if (list.length === 0) {
    coachesList.innerHTML = renderEmptyState();
    resultsCount.textContent = '0 Experts';
    return;
  }
  coachesList.innerHTML = list.map(renderNutritionistCard).join('');
  const n = list.length;
  resultsCount.textContent = `${n} Expert${n === 1 ? '' : 's'}`;
}

// ─── FIREBASE LOADING ──────────────────────────────────────────────────────

function _normalizeInitials(name) {
  return (name || 'EX').split(/\s+/).map(function(w){return w[0]||'';}).slice(0,2).join('').toUpperCase() || 'EX';
}

function _mergeLocalExperts() {
  var stored = [];
  try {
    var _p = JSON.parse(localStorage.getItem('zitlas_experts'));
    if (Array.isArray(_p)) stored = _p;
  } catch(_) {}
  console.log('[EXPERTS]', stored);
  stored.forEach(function(e) {
    if (!e.id || _expertsData.find(function(x) { return x.id === e.id; })) return;
    _expertsData.push({
      id:         e.id,
      name:       e.name || 'Expert',
      role:       e.specialization || 'Expert',
      image:      '',
      initials:   _normalizeInitials(e.name),
      color:      'var(--primary)',
      rating:     parseFloat(e.rating) || 5.0,
      reviews:    0,
      exp:        '1+',
      fee:        0,
      duration:   '20 Min',
      reviewFee:  reviewPriceFor(e.pricing),
      available:  true,
      specialties:[],
      lang:       ['EN'],
      verified:     e.verified === true,
      verification: e.verification || null,
    });
  });
}

function loadExpertsFromFirebase() {
  if (typeof ZitlasDB === 'undefined') {
    _mergeLocalExperts();
    _loadingExperts = false;
    updateList();
    return;
  }
  ZitlasDB.collection('experts')
    .get()
    .then(function(snapshot) {
      _expertsData = [];
      snapshot.forEach(function(doc) {
        var d = doc.data();
        // MISSING marketplace visibility gate. Signup writes
        // `approved: false` and tells the applicant "your application is
        // under review" (login.js), and /api/admin/experts/approve flips it —
        // but this read lists every document regardless, which is how
        // unapproved self-signups and test accounts appear publicly.
        //
        // The one-line fix is `if (d.approved === false) return;` — held
        // back until it is confirmed that the live experts actually carry
        // approved:true, since otherwise it would empty the marketplace
        // instead of cleaning it. Note `=== false`, never `!== true`: a
        // document predating the field has no `approved` key and must stay
        // listed.
        _expertsData.push({
          id:         doc.id,
          name:       d.name             || 'Expert',
          role:       d.specialization   || d.role || 'Expert',
          image:      d.profilePhoto     || d.image || '',
          initials:   d.initials         || _normalizeInitials(d.name),
          color:      d.colorAccent      || 'var(--primary)',
          rating:     parseFloat(d.rating) || 5.0,
          reviews:    parseInt(d.reviewCount, 10) || 0,
          exp:        d.experience       || '1+',
          fee:        parseInt(d.fee, 10) || 0,
          duration:   d.sessionDuration  ? (d.sessionDuration + ' Min') : '20 Min',
          reviewFee:  reviewPriceFor(d.pricing),
          available:  d.status !== 'offline',
          specialties: Array.isArray(d.specialties) ? d.specialties : [],
          lang:       Array.isArray(d.languages)    ? d.languages   : ['EN'],
          verified:   d.verified === true,
          verification: d.verification || null, // ZitlasBadge.render() falls back to .verified if this is absent
        });
      });
      /* Firestore is the single source of truth for the expert list.
         The zitlas_experts localStorage cache is only merged when
         Firestore is unreachable — merging it here resurrects stale or
         deleted experts, and reviews sent to them are never received. */
      _loadingExperts = false;
      updateList();
    })
    .catch(function() {
      _mergeLocalExperts();
      _loadingExperts = false;
      updateList();
    });
}

// ─── PILL SYNC ─────────────────────────────────────────────────────────────

function syncPills() {
  filterPills.querySelectorAll('.cat-pill').forEach(btn => {
    const sameSort      = btn.dataset.sort === currentSort;
    const sameSpecialty = btn.dataset.specialty === currentSpecialty;
    btn.classList.toggle('active', sameSort && sameSpecialty);
  });
}

function syncDrawerPills() {
  drawerSortGroup.querySelectorAll('.drawer-pill').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.sort === pendingSort);
  });
  drawerSpecialtyGroup.querySelectorAll('.drawer-pill').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.specialty === pendingSpecialty);
  });
}

// ─── DRAWER ────────────────────────────────────────────────────────────────

function openDrawer() {
  pendingSort      = currentSort;
  pendingSpecialty = currentSpecialty;
  syncDrawerPills();
  sideDrawer.classList.add('open');
  drawerOverlay.classList.add('active');
  sideDrawer.setAttribute('aria-hidden', 'false');
}

function closeDrawer() {
  sideDrawer.classList.remove('open');
  drawerOverlay.classList.remove('active');
  sideDrawer.setAttribute('aria-hidden', 'true');
}

function applyDrawer() {
  currentSort      = pendingSort;
  currentSpecialty = pendingSpecialty;
  syncPills();
  updateList();
  closeDrawer();
}

// ─── EVENTS ────────────────────────────────────────────────────────────────

menuBtn.addEventListener('click', openDrawer);
sortToggleBtn.addEventListener('click', openDrawer);
drawerCloseBtn.addEventListener('click', closeDrawer);
drawerOverlay.addEventListener('click', closeDrawer);
drawerApplyBtn.addEventListener('click', applyDrawer);

drawerSortGroup.addEventListener('click', e => {
  const btn = e.target.closest('[data-sort]');
  if (!btn) return;
  pendingSort = btn.dataset.sort;
  syncDrawerPills();
});

drawerSpecialtyGroup.addEventListener('click', e => {
  const btn = e.target.closest('[data-specialty]');
  if (!btn) return;
  pendingSpecialty = btn.dataset.specialty;
  syncDrawerPills();
});

filterPills.addEventListener('click', e => {
  const btn = e.target.closest('.cat-pill');
  if (!btn) return;
  currentSort      = btn.dataset.sort;
  currentSpecialty = btn.dataset.specialty;
  pendingSort      = currentSort;
  pendingSpecialty = currentSpecialty;
  syncPills();
  updateList();
});

searchInput.addEventListener('input', () => {
  searchQuery = searchInput.value.trim();
  searchClearBtn.style.display = searchQuery ? '' : 'none';
  updateList();
});

searchClearBtn.addEventListener('click', () => {
  searchInput.value = '';
  searchQuery = '';
  searchClearBtn.style.display = 'none';
  searchInput.focus();
  updateList();
});

coachesList.addEventListener('click', e => {
  /* Request Review / Personal Coach / Chat — each deep-links into the
     profile page's EXISTING action handlers (action=verify/coach/ask),
     so the actual review-request / coaching / chat flows are unchanged;
     only the entry point moved onto the listing card. */
  const actionBtn = e.target.closest('.nutri-action-btn');
  if (actionBtn && actionBtn.dataset.id) {
    console.log('[EXPERT CARD] action', actionBtn.dataset.action, '->', actionBtn.dataset.id);
    window.location.href = `cprofile.html?expertId=${actionBtn.dataset.id}&action=${actionBtn.dataset.action}`;
    return;
  }
  const askBtn = e.target.closest('.ask-btn');
  /* data-id guard: the empty-state "Become an Expert" <a> reuses the
     .ask-btn class but has no data-id — without the guard this handler
     hijacked it to cprofile.html?expertId=undefined instead of letting
     its own href (login page) navigate. */
  if (askBtn && askBtn.dataset.id) {
    console.log('[ASK EXPERT] navigating to expert', askBtn.dataset.id);
    window.location.href = `cprofile.html?expertId=${askBtn.dataset.id}`;
    return;
  }
  if (askBtn) return; /* .ask-btn without data-id (e.g. a real link) — let it be */
  const card = e.target.closest('.nutri-card');
  if (card && card.dataset.id) {
    console.log('[ASK EXPERT] navigating to expert (card)', card.dataset.id);
    window.location.href = `cprofile.html?expertId=${card.dataset.id}`;
  }
});

coachesList.addEventListener('keydown', e => {
  if (e.key !== 'Enter' && e.key !== ' ') return;
  const card = e.target.closest('.nutri-card');
  if (card && card.dataset.id) {
    e.preventDefault();
    window.location.href = `cprofile.html?expertId=${card.dataset.id}`;
  }
});

if (typeof ZitlasNotify !== 'undefined') {
  ZitlasNotify.wireBell('notifBtn', 'notifDot', '../notifications/notifications.html');
} else {
  document.getElementById('notifBtn').addEventListener('click', () => {
    showToast('🔔 No new notifications');
  });
}

// ─── TOAST ─────────────────────────────────────────────────────────────────

let _toastTimer;
function showToast(msg) {
  clearTimeout(_toastTimer);
  toast.textContent = msg;
  toast.classList.add('show');
  _toastTimer = setTimeout(() => toast.classList.remove('show'), 2800);
}

// ─── INIT ──────────────────────────────────────────────────────────────────

(function init() {
  const t = localStorage.getItem('zitlas_theme') || 'dark';
  document.documentElement.setAttribute('data-theme', t);

  searchClearBtn.style.display = 'none';
  updateList(); // shows loading state immediately
  loadExpertsFromFirebase();

  if (window.ZitlasLang) window.ZitlasLang.applyTranslations();
})();

// Set --nav-h after navbar.js injects the element (DOMContentLoaded fires after all scripts run)
document.addEventListener('DOMContentLoaded', function () {
  var _nb = document.getElementById('zitlas-navbar');
  if (_nb) {
    var _h = window.innerHeight - _nb.getBoundingClientRect().top;
    document.documentElement.style.setProperty('--nav-h', _h + 'px');
  }
});
