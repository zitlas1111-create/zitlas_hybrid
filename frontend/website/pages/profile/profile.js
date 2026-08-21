/* =============================================
   ZITLAS Profile Page — profile.js
   ============================================= */

(function () {
  'use strict';

  /* ---- Theme ----
     ZITLAS uses ONE premium theme. Theme switching was removed; any stored
     preference is cleared so legacy devices don't carry stale state. */
  const html = document.documentElement;

  function loadTheme() {
    try { localStorage.removeItem('zitlas_theme'); } catch (_) {}
    html.setAttribute('data-theme', 'dark'); /* attribute is inert — both values map to the single theme */
    return 'dark';
  }

  /* ---- Modal Helpers ---- */
  function openModal(el) {
    el.classList.add('open');
    document.body.style.overflow = 'hidden';
    const firstFocusable = el.querySelector('button');
    if (firstFocusable) firstFocusable.focus();
  }

  function closeModal(el) {
    el.classList.remove('open');
    document.body.style.overflow = '';
  }

  function closeOnBackdrop(e, modal) {
    if (e.target === modal) closeModal(modal);
  }

  /* ---- Toast ---- */
  let toastTimer = null;
  function showToast(message, duration = 2600) {
    const toast = document.getElementById('toast');
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('show'), duration);
  }

  /* Appearance modal removed — ZITLAS uses one premium theme. */
  function initAppearanceModal() {}

  /* ---- Language Modal ---- */
  function initLanguageModal() {
    var modal   = document.getElementById('languageModal');
    var closeBtn = document.getElementById('langModalClose');
    var langItem = document.querySelector('.settings-item[data-action="language"]');
    if (!modal || !closeBtn) return;

    function updateLangChecks(lang) {
      modal.querySelectorAll('.lang-option').forEach(function (btn) {
        btn.classList.toggle('selected', btn.dataset.lang === lang);
      });
    }

    if (langItem) {
      langItem.addEventListener('click', function () {
        updateLangChecks(window.ZitlasLang ? ZitlasLang.getLang() : 'en');
        openModal(modal);
      });
    }

    closeBtn.addEventListener('click', function () { closeModal(modal); });
    modal.addEventListener('click', function (e) { closeOnBackdrop(e, modal); });
    modal.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeModal(modal); });

    modal.querySelectorAll('.lang-option').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var lang = btn.dataset.lang;
        if (window.ZitlasLang) {
          ZitlasLang.setLang(lang);
          updateLangChecks(lang);
          showToast(lang === 'hi' ? ZitlasLang.t('toast_lang_hi') : ZitlasLang.t('toast_lang_en'));
        }
        setTimeout(function () { closeModal(modal); }, 420);
      });
    });
  }

  /* ---- Settings Items ---- */
  function initSettingsItems() {
    document.querySelectorAll('.settings-item[data-action], .quick-action-item[data-action]').forEach(btn => {
      const action = btn.dataset.action;
      if (action === 'appearance' || action === 'language') return;

      btn.addEventListener('click', () => {
        if (action === 'personal') {
          window.location.href = './personal-info/personal-info.html';
          return;
        }
        if (action === 'help') {
          window.location.href = './help-support/help-support.html';
          return;
        }
        if (action === 'subscription') {
          window.location.href = './membership/membership.html';
          return;
        }
        const t = window.ZitlasLang ? ZitlasLang.t.bind(ZitlasLang) : (k => k);
        showToast(t('toast_coming_soon'));
      });
    });
  }

  /* ---- Logout Modal ---- */
  function initLogoutModal() {
    const logoutBtn  = document.getElementById('logoutBtn');
    const modal      = document.getElementById('logoutModal');
    const cancelBtn  = document.getElementById('logoutCancel');
    const confirmBtn = document.getElementById('logoutConfirm');
    if (!logoutBtn || !modal || !cancelBtn || !confirmBtn) return;

    logoutBtn.addEventListener('click', () => openModal(modal));
    cancelBtn.addEventListener('click', () => closeModal(modal));
    modal.addEventListener('click', (e) => closeOnBackdrop(e, modal));

    confirmBtn.addEventListener('click', async () => {
      confirmBtn.textContent = 'Logging out…';
      confirmBtn.disabled = true;

      /* Stop EVERY Firestore listener BEFORE signing out — a listener that
         outlives the session fires permission-denied. Tear the coaching
         workspace down cleanly, then terminate the client to detach the rest. */
      try {
        if (window.ZitlasCoachingWorkspace && typeof ZitlasCoachingWorkspace.close === 'function') {
          ZitlasCoachingWorkspace.close();
        }
      } catch (e) { console.warn('[ZITLAS] workspace close error:', e); }
      try {
        if (typeof firebase !== 'undefined' && firebase.firestore) {
          await Promise.race([
            firebase.firestore().terminate(),
            new Promise(function (r) { setTimeout(r, 2500); })
          ]);
        }
      } catch (e) { console.warn('[ZITLAS] firestore terminate error:', e); }

      /* Firebase sign-out — this MUST actually execute; clearing localStorage
         or navigating away is not a substitute (see the comment on
         _clearAuthLocalStorage() in login.js for why this specific ordering
         — signOut BEFORE the cache purge — matters). */
      const uidBeforeLogout = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
        ? ZitlasAuth.currentUser.uid : null;
      console.log('[LOGOUT] Before logout UID:', uidBeforeLogout);
      try {
        if (typeof ZitlasAuth !== 'undefined') await ZitlasAuth.signOut();
      } catch (e) { console.warn('[ZITLAS] signOut error:', e); }
      console.log('[LOGOUT] After signOut currentUser:',
        (typeof ZitlasAuth !== 'undefined') ? ZitlasAuth.currentUser : 'ZitlasAuth undefined');

      /* ACCOUNT GUARD — full user-cache purge (plans, goal, membership,
         wallet, reviews, chats… not just auth keys). The old partial
         clear was the multi-user data-leak root cause: the next account
         to sign in on this browser inherited everything the list missed.
         Fallback list kept for the cached-page case. */
      if (typeof ZitlasAccountGuard !== 'undefined') {
        ZitlasAccountGuard.clearUserCache();
      } else {
        ['zitlas_token','zitlas_user','zitlas_firebase_user','zitlas_user_role',
         'zitlas_expert_id','loggedIn','user','zitlas_expert_profile','currentUser',
         'zitlas_expert_applied','zitlas_experts'].forEach(k => localStorage.removeItem(k));
        ['zitlas_guest','zitlas_pending_action','user'].forEach(k => sessionStorage.removeItem(k));
      }
      console.log('[LOGOUT] Cleared account cache: true');

      window.location.replace('../login/login.html');
    });

    modal.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeModal(modal); });
  }

  /* ---- Share Profile ---- */
  function initShareProfile() {
    const btn = document.getElementById('shareProfileBtn');
    if (!btn) return;

    btn.addEventListener('click', async () => {
      const t = window.ZitlasLang ? ZitlasLang.t.bind(ZitlasLang) : (k => k);
      const shareData = {
        title: 'My ZITLAS Weight-Loss Profile',
        text: 'Check out my ZITLAS Weight-Loss Profile! | Pune, India',
        url: window.location.href,
      };

      if (navigator.share) {
        try {
          await navigator.share(shareData);
        } catch (err) {
          if (err.name !== 'AbortError') showToast(t('toast_share_fail'));
        }
      } else if (navigator.clipboard) {
        try {
          await navigator.clipboard.writeText(shareData.url);
          showToast(t('toast_link_copied'));
        } catch {
          showToast('Profile link: ' + shareData.url);
        }
      } else {
        showToast(t('toast_no_share'));
      }
    });
  }

  /* ---- Edit Profile ---- */
  function initEditProfile() {
    const btn = document.getElementById('editProfileBtn');
    if (!btn) return;
    btn.addEventListener('click', () => {
      window.location.href = './personal-info/personal-info.html';
    });
  }

  /* System theme watcher removed — single theme, nothing to switch. */
  function initSystemThemeWatcher() {}

  /* ---- Bottom nav ---- */
  function initNavItems() {
    document.querySelectorAll('.nav-item:not(.active)').forEach(item => {
      const href = item.getAttribute('href');
      if (!href || href === '#') {
        item.addEventListener('click', (e) => {
          e.preventDefault();
          showToast('Navigation — coming soon');
        });
      }
    });
  }

  /* ---- Load Athlete Profile from localStorage ---- */
  function loadAthleteProfile() {
    var info = {};
    try { info = JSON.parse(localStorage.getItem('zitlas_personal_info') || '{}'); } catch (_) {}
    var zUser = {};
    try { zUser = JSON.parse(localStorage.getItem('zitlas_user') || '{}'); } catch (_) {}
    var fbUser = {};
    try { fbUser = JSON.parse(localStorage.getItem('zitlas_firebase_user') || '{}'); } catch (_) {}
    var survey = {};
    try { survey = JSON.parse(localStorage.getItem('zitlas_survey') || '{}'); } catch (_) {}

    var name = (info.fullName || zUser.name || fbUser.displayName || fbUser.name || '').trim();
    var photo = info.photo || zUser.photo || fbUser.photoURL || fbUser.photo || null;

    var nameEl = document.querySelector('.player-name');
    if (nameEl && name) nameEl.textContent = name;

    var avatarImg = document.getElementById('avatarImg');
    if (avatarImg) {
      if (photo && (photo.startsWith('data:') || photo.startsWith('http'))) {
        avatarImg.src = photo;
        avatarImg.onerror = function () {
          if (!name) return;
          var _ini = name.split(/\s+/).slice(0, 2).map(function (w) { return w[0] || ''; }).join('').toUpperCase() || name[0].toUpperCase();
          avatarImg.onerror = null;
          avatarImg.src = 'data:image/svg+xml,' + encodeURIComponent(
            '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">' +
            '<rect width="120" height="120" rx="60" fill="#234B35"/>' +
            '<text x="50%" y="50%" dominant-baseline="central" text-anchor="middle" font-size="48" font-weight="bold" fill="white" font-family="system-ui">' + _ini + '</text></svg>'
          );
        };
      } else if (name) {
        var initials = name.split(/\s+/).slice(0, 2).map(function (w) { return w[0] || ''; }).join('').toUpperCase() || name[0].toUpperCase();
        avatarImg.src = 'data:image/svg+xml,' + encodeURIComponent(
          '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">' +
          '<rect width="120" height="120" rx="60" fill="#234B35"/>' +
          '<text x="50%" y="50%" dominant-baseline="central" text-anchor="middle" font-size="48" font-weight="bold" fill="white" font-family="system-ui">' + initials + '</text></svg>'
        );
      }
    }

    var goalData = {};
    try { goalData = JSON.parse(localStorage.getItem('zitlas_goal') || '{}'); } catch (_) {}
    var goalType = (goalData.type || survey.fitness_goal || '').replace(/_/g, ' ');
    var aiLabel = document.querySelector('.ai-label');
    if (aiLabel && goalType) {
      aiLabel.textContent = 'AI ' + goalType.replace(/\b\w/g, function (c) { return c.toUpperCase(); }) + ' Member';
    }

    /* Update membership badge and subscription item subtitle */
    var membership = {};
    try { membership = JSON.parse(localStorage.getItem('zitlas_membership') || '{}'); } catch (_) {}
    var isPremium = membership.plan === 'premium';

    var roleBadge = document.querySelector('.role-badge');
    if (roleBadge) {
      roleBadge.innerHTML = isPremium
        ? '<svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l2.09 6.26L20 9.27l-4.91 4.79L16.18 21 12 17.27 7.82 21l1.09-6.94L4 9.27l5.91-.01z"/></svg>Premium Member'
        : '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/></svg>Basic Member';
    }

    var subItem = document.querySelector('.settings-item[data-action="subscription"]');
    if (subItem) {
      var label = subItem.querySelector('.settings-label');
      if (label) {
        var existingSubtitle = label.querySelector('.settings-subtitle');
        if (!existingSubtitle) {
          existingSubtitle = document.createElement('span');
          existingSubtitle.className = 'settings-subtitle';
          label.style.cssText = 'flex:1;display:flex;flex-direction:column;gap:2px;';
          label.appendChild(existingSubtitle);
        }
        existingSubtitle.textContent = 'Current Plan: ' + (isPremium ? 'Premium' : 'Basic');
      }
    }
  }

  /* ---- Avatar fallback ---- */
  function initAvatarFallback() {
    const img = document.getElementById('avatarImg');
    if (!img) return;
    img.addEventListener('error', () => {
      img.src = 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120"%3E%3Crect width="120" height="120" rx="60" fill="%23FF8A00"/%3E%3Ctext x="50%25" y="50%25" dominant-baseline="central" text-anchor="middle" font-size="48" font-weight="bold" fill="white" font-family="system-ui"%3EAP%3C/text%3E%3C/svg%3E';
    });
  }

  /* ---- Expert Application Pending Banner ---- */
  /* Expert onboarding is CLOSED and nothing writes `zitlas_expert_applied`
     any more. An account that applied before the freeze would otherwise see
     "application pending" forever, for an application that can never be
     reviewed. The stale key is cleared and the banner stays hidden. */
  function initExpertAppliedBanner() {
    if (localStorage.getItem('zitlas_expert_applied')) {
      localStorage.removeItem('zitlas_expert_applied');
    }
    var banner = document.getElementById('expertAppliedBanner');
    if (banner) banner.style.display = 'none';
  }

  /* ---- INIT ---- */
  function init() {
    var _nb = document.getElementById('zitlas-navbar');
    if (_nb) document.documentElement.style.setProperty('--nav-height', (window.innerHeight - _nb.getBoundingClientRect().top) + 'px');

    loadTheme();
    initSystemThemeWatcher();
    loadAthleteProfile();
    initAppearanceModal();
    initLanguageModal();
    initSettingsItems();
    initLogoutModal();
    initShareProfile();
    initEditProfile();
    initNavItems();
    initAvatarFallback();
    initExpertAppliedBanner();
  }

  /* Cross-device sync: hydrate before the first render so a second device
     shows the same name/goal immediately, then re-render just the profile
     summary (never the whole init(), which would double-wire the modals/
     nav listeners) when another device changes something. */
  function boot() {
    if (typeof ZitlasAuth === 'undefined' || typeof ZitlasCloudSync === 'undefined') { init(); return; }
    ZitlasAuth.onAuthStateChanged(function (user) {
      if (!user) { init(); return; }
      ZitlasCloudSync.hydrateOnLoad(user.uid).then(function () {
        init();
        ZitlasCloudSync.attachRealtime(user.uid, loadAthleteProfile);
      });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
