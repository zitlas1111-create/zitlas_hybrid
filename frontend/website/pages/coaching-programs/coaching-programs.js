/*!
 * ZITLAS — Personal Coaching Programs page
 * (pages/coaching-programs/coaching-programs.js)
 *
 * Renders assets/js/coaching-programs-flow.js: the same programs, rules and
 * messages as the app's native Programs screen, on the same backend. Nothing
 * is shown as sent, paid or started unless the server said so.
 */
(function () {
  'use strict';

  var F = window.ZitlasProgramsFlow;
  var M = F ? F.MESSAGES : {};
  var ctl = null;
  var flowOpen = false;   // one Get Started flow at a time (double clicks)
  var loadedFor = null;   // the uid the page last loaded for

  function $(id) { return document.getElementById(id); }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  var toastTimer = null;
  function toast(msg) {
    if (!msg) return;
    var t = $('cpgToast');
    if (!t) return;
    t.textContent = msg;
    t.classList.add('cpg-toast--show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.classList.remove('cpg-toast--show'); }, 4500);
  }

  function row(label, value, key) {
    return '<div class="cpg-row"' + (key ? ' data-row="' + esc(key) + '"' : '') + '>' +
      '<span>' + esc(label) + '</span><strong>' + esc(value) + '</strong></div>';
  }

  function initials(name) {
    return String(name || '').trim().split(/\s+/).filter(Boolean).slice(0, 2)
      .map(function (w) { return w.charAt(0).toUpperCase(); }).join('') || '?';
  }

  /* ── One program card ───────────────────────────────────────────────── */

  /* The expert's price — or, when there is none, WHY (the flow decides). */
  function priceLine(p, card) {
    return '<div class="cpg-price' + (card.price === null ? ' cpg-price--muted' : '') +
      '" data-price="' + esc(p.id) + '" data-availability="' + esc(card.availability) + '">' +
      esc(card.priceText) + '</div>';
  }

  /* Accepted: the price the SERVER recorded, and Pay & Start. */
  function paymentPanel(p, req, st) {
    var price = req.pricePaise;
    var html = '<div class="cpg-panel cpg-panel--accepted" data-payment="' + esc(p.id) + '">' +
      '<div class="cpg-panel-title">✅ ' + esc(M.acceptedTitle) + '</div>' +
      row('Program', p.title) +
      row('Amount', price === null ? '—' : F.formatPrice(price), 'amount') +
      '<p class="cpg-panel-body">' + esc(M.acceptedBody) + '</p>' +
      '<button class="cpg-btn cpg-btn--primary cpg-btn--block" type="button" data-pay="' + esc(p.id) + '"' +
        ((st.paying || price === null) ? ' disabled' : '') + '>' +
        (st.paying ? 'Paying…' : esc(M.payLabel)) + '</button>';
    var short = st.shortfall;
    if (short) {
      var need = Math.max(0, short.requiredPaise - short.availablePaise);
      html += '<div class="cpg-short" data-shortfall>' +
        '<div class="cpg-short-title">Insufficient wallet balance</div>' +
        row('Required', F.formatPrice(short.requiredPaise), 'required') +
        row('Available', F.formatPrice(short.availablePaise), 'available') +
        row('Need', F.formatPrice(need), 'need') +
        '<p class="cpg-panel-body">' + esc(M.shortfall) + '</p>' +
        '<button class="cpg-btn cpg-btn--secondary cpg-btn--block" type="button" data-add-funds>Add Funds</button>' +
      '</div>';
    }
    return html + '</div>';
  }

  /* Waiting, declined, or a paid program with the SERVER's details. */
  function statusPanel(p, req, st) {
    var running = F.isRunning(req, ctl.now());
    var completed = req.status === F.STATUS.COMPLETED;
    var paidProgram = req.status === F.STATUS.ACTIVE || completed;
    var icon, title, body = '', tone;
    if (req.status === F.STATUS.ACTIVE && running) {
      icon = '▶️'; title = M.activeTitle; tone = 'active';
    } else if (paidProgram) {
      icon = '🏁'; title = completed ? M.completedTitle : M.endedTitle; body = 'You can start a new program.'; tone = 'muted';
    } else if (req.status === F.STATUS.DECLINED) {
      icon = '❌'; title = M.declinedTitle; body = M.declinedBody; tone = 'declined';
    } else if (req.status === F.STATUS.PENDING) {
      icon = '⏳'; title = M.pendingTitle; body = M.pendingBody; tone = 'pending';
    } else {
      icon = '❔'; title = M.statusUnknownTitle; body = M.statusUnknownBody; tone = 'muted';
    }
    var html = '<div class="cpg-panel cpg-panel--' + tone + '" data-status="' + esc(p.id) + '">' +
      '<div class="cpg-panel-title">' + icon + ' ' + esc(title) + '</div>' +
      (body ? '<p class="cpg-panel-body">' + esc(body) + '</p>' : '');
    if (req.status === F.STATUS.PENDING && req.pricePaise !== null) {
      html += '<p class="cpg-panel-body" data-row="pending-price">Program price: ' + esc(F.formatPrice(req.pricePaise)) + '</p>';
    }
    if (paidProgram) {
      var expertName = req.expertName || (st.offer && st.offer.expertName) || '—';
      html += row('Program', p.title) +
        row('Expert', expertName) +
        row('Amount Paid', req.amountPaidPaise === null ? '—' : F.formatPrice(req.amountPaidPaise), 'paid') +
        row('Start Date', F.formatDate(req.startedAt), 'start') +
        row('End Date', F.formatDate(req.endsAt), 'end') +
        row('Status', running ? 'Active' : (completed ? 'Completed' : 'Ended'), 'status');
    }
    return html + '</div>';
  }

  function cardHtml(p, st) {
    var busy = st.submitting !== null || st.paying || flowOpen;
    var card = ctl.cardFor(p.id, busy);
    var req = card.request;

    var html = '<article class="cpg-card" data-program="' + esc(p.id) + '">' +
      '<img class="cpg-art" src="' + esc(p.image) + '" alt="' + esc(p.title) + ' artwork" />' +
      '<div class="cpg-card-body">' +
        '<div class="cpg-card-head"><h2>' + esc(p.title) + '</h2>' +
          '<span class="cpg-chip">🕒 ' + esc(p.durationLabel) + '</span></div>' +
        priceLine(p, card) +
        '<p class="cpg-desc">' + esc(p.description) + '</p>' +
        '<div class="cpg-eyebrow">WHAT YOU GET</div>' +
        '<ul class="cpg-checks">' + p.highlights.map(function (h) { return '<li>' + esc(h) + '</li>'; }).join('') + '</ul>';
    if (req) html += F.awaitingPayment(req) ? paymentPanel(p, req, st) : statusPanel(p, req, st);
    if (card.showStart) {
      if (card.blockedBy) {
        html += '<p class="cpg-note">' + esc(card.blockedBy.status === F.STATUS.ACTIVE ? M.otherRunning : M.otherRequestOpen) + '</p>';
      }
      // Always "Get Started" — it never switches experts behind the athlete's back.
      html += '<button class="cpg-btn cpg-btn--primary cpg-btn--block" type="button" data-start="' + esc(p.id) + '"' +
        (card.startEnabled ? '' : ' disabled') + '>' +
        (st.submitting === p.id ? 'Sending…' : 'Get Started →') + '</button>';
      if (card.showChooseAnother) {
        html += '<button class="cpg-btn cpg-btn--secondary cpg-btn--block cpg-btn--stacked" type="button" ' +
          'data-choose-another="' + esc(p.id) + '"' + (card.chooseAnotherEnabled ? '' : ' disabled') + '>' +
          esc(M.chooseAnotherExpert) + '</button>';
      }
    }
    return html + '</div></article>';
  }

  function render() {
    if (!ctl) return;
    var st = ctl.state();
    var line = $('cpgExpert');
    if (line) line.innerHTML = st.offer ? '👤 Your expert: <strong>' + esc(st.offer.expertName) + '</strong>' : '';
    var notice = $('cpgNotice');
    if (notice) {
      notice.innerHTML = st.state === 'failed'
        ? '<div class="cpg-error" data-load-error>Couldn\'t load this expert\'s prices. ' +
          '<button class="cpg-link" id="cpgRetry" type="button">Retry</button></div>'
        : '';
    }
    var list = $('cpgList');
    if (!list) return;
    list.innerHTML = F.PROGRAMS.map(function (p) { return cardHtml(p, st); }).join('');
    var retry = $('cpgRetry');
    if (retry) retry.addEventListener('click', function () { ctl.load(); });
    Array.prototype.forEach.call(list.querySelectorAll('[data-start]'), function (b) {
      b.addEventListener('click', function () { getStarted(b.getAttribute('data-start')); });
    });
    Array.prototype.forEach.call(list.querySelectorAll('[data-choose-another]'), function (b) {
      b.addEventListener('click', function () { getStarted(b.getAttribute('data-choose-another'), true); });
    });
    Array.prototype.forEach.call(list.querySelectorAll('[data-pay]'), function (b) {
      b.addEventListener('click', pay);
    });
    Array.prototype.forEach.call(list.querySelectorAll('[data-add-funds]'), function (b) {
      b.addEventListener('click', addFunds);
    });
  }

  /* ── Choose your expert ─────────────────────────────────────────────── */

  function expertRowHtml(x) {
    return '<div class="cpg-expert" data-expert="' + esc(x.expertId) + '">' +
      '<div class="cpg-avatar-wrap"><span class="cpg-avatar">' + esc(initials(x.expertName)) + '</span>' +
        (x.photoUrl ? '<img class="cpg-avatar cpg-avatar--photo" src="' + esc(x.photoUrl) + '" alt="" onerror="this.remove()" />' : '') +
      '</div>' +
      '<div class="cpg-expert-info"><strong>' + esc(x.expertName) + '</strong>' +
        (x.specialization ? '<span>' + esc(x.specialization) + '</span>' : '') +
        (x.expertise.length ? '<span class="cpg-expert-areas">' + esc(x.expertise.slice(0, 3).join(' · ')) + '</span>' : '') +
        '<span class="cpg-expert-price">' + esc(F.formatPrice(x.pricePaise)) + '</span></div>' +
      '<button class="cpg-btn cpg-btn--primary cpg-btn--small" type="button" data-select="' + esc(x.expertId) + '">Select</button>' +
    '</div>';
  }

  function openPicker(p) {
    return new Promise(function (resolve) {
      var overlay = $('cpgPicker');
      var body = $('cpgPickerBody');
      var close = $('cpgPickerClose');
      $('cpgPickerSub').textContent = p.title + ' · ' + p.durationLabel +
        ". You'll review the price before anything is sent.";
      overlay.hidden = false;
      var done = false;
      function finish(value) {
        if (done) return;
        done = true;
        overlay.hidden = true;
        overlay.removeEventListener('click', onOverlay);
        close.removeEventListener('click', onClose);
        document.removeEventListener('keydown', onKey);
        resolve(value);
      }
      function onOverlay(e) { if (e.target === overlay) finish(null); }
      function onClose() { finish(null); }
      function onKey(e) { if (e.key === 'Escape') finish(null); }
      overlay.addEventListener('click', onOverlay);
      close.addEventListener('click', onClose);
      document.addEventListener('keydown', onKey);

      function loadList() {
        body.innerHTML = '<div class="cpg-loading">Loading experts…</div>';
        ctl.expertsFor(p.id).then(function (experts) {
          if (done) return;
          if (!experts.length) {
            body.innerHTML = '<p class="cpg-empty" data-picker-empty>' + esc(M.noExperts) + '</p>';
            return;
          }
          body.innerHTML = experts.map(expertRowHtml).join('');
          Array.prototype.forEach.call(body.querySelectorAll('[data-select]'), function (b) {
            b.addEventListener('click', function () {
              var id = b.getAttribute('data-select');
              finish(experts.filter(function (x) { return x.expertId === id; })[0] || null);
            });
          });
        }, function (err) {
          if (done) return;
          body.innerHTML = '<p class="cpg-error" data-picker-error>' + esc((err && err.message) || M.expertsLoadFailed) + '</p>' +
            '<button class="cpg-btn cpg-btn--secondary" type="button" data-picker-retry>Retry</button>';
          body.querySelector('[data-picker-retry]').addEventListener('click', loadList);
        });
      }
      loadList();
    });
  }

  /* ── Review, then send ──────────────────────────────────────────────── */

  function openReview(p, price) {
    return new Promise(function (resolve) {
      var overlay = $('cpgReview');
      var send = $('cpgReviewSend');
      var cancel = $('cpgReviewCancel');
      var offer = ctl.state().offer;
      var expertName = (offer && offer.expertName) || 'your expert';
      $('cpgReviewTitle').textContent = 'Request the ' + p.title + '?';
      $('cpgReviewBody').textContent = F.formatPrice(price) + ' · ' + p.durationLabel + '\n\n' +
        "You won't be charged now. " + expertName + ' will review your request first.';
      overlay.hidden = false;
      var done = false;
      function finish(value) {
        if (done) return;
        done = true;
        overlay.hidden = true;
        send.removeEventListener('click', onSend);
        cancel.removeEventListener('click', onCancel);
        overlay.removeEventListener('click', onOverlay);
        resolve(value);
      }
      function onSend() { finish(true); }
      function onCancel() { finish(false); }
      function onOverlay(e) { if (e.target === overlay) finish(false); }
      send.addEventListener('click', onSend);
      cancel.addEventListener('click', onCancel);
      overlay.addEventListener('click', onOverlay);
    });
  }

  /* A refresh restores this expert (the app keeps them on screen too). */
  function rememberExpert(id) {
    try {
      var url = new URL(window.location.href);
      url.searchParams.set('expertId', id);
      window.history.replaceState(null, '', url.pathname + url.search);
    } catch (_) { /* old browser: /requests/me still restores it */ }
  }

  /* GET STARTED — choose an expert (only when none is chosen yet) -> review
     at that expert's SERVER price -> send. `chooseAnother` is the card's
     separate "Choose Another Expert" button: the athlete asked to switch, so
     the list opens although an expert is chosen. Get Started itself never
     switches experts. */
  function getStarted(programId, chooseAnother) {
    if (flowOpen) return;
    var p = F.programById(programId);
    if (!p) return;
    var needExpert = !!chooseAnother || !ctl.state().expertId;
    // With an expert, Get Started works only when THEY price this program
    // (the button is disabled otherwise) — this guards a stale click.
    if (!needExpert && ctl.availabilityFor(programId) !== 'available') return;
    flowOpen = true;
    render();
    var chain = Promise.resolve(null);
    if (needExpert) {
      chain = openPicker(p).then(function (chosen) {
        if (!chosen) return 'stop';
        return ctl.selectExpert(chosen.expertId).then(function () {
          rememberExpert(chosen.expertId);
          if (ctl.state().state !== 'ready') { toast(M.expertLoadFailed); return 'stop'; }
          // A request already waiting (or running) with that expert is shown
          // on its card — never duplicated.
          var open = ctl.openRequest();
          if (open) {
            if (open.programId === programId) toast(F.isOpen(open) ? M.alreadyRequested : M.otherRunning);
            else toast(open.status === F.STATUS.ACTIVE ? M.otherRunning : M.otherRequestOpen);
            return 'stop';
          }
          return null;
        });
      });
    }
    chain.then(function (stop) {
      if (stop === 'stop') return null;
      var price = ctl.priceFor(programId);
      if (price === null) {
        var offer = ctl.state().offer;
        toast(((offer && offer.expertName) || 'This expert') + " doesn't offer the " + p.title +
          ' right now. Choose another expert.');
        return null;
      }
      return openReview(p, price).then(function (send) {
        if (!send) return null;
        return ctl.requestProgram(programId).then(function (out) { toast(out.message); });
      });
    }).catch(function (e) {
      if (window.console) console.error('[PROGRAMS] Get Started failed', e);
      toast('Could not send your request. Please try again.');
    }).then(function () {
      flowOpen = false;
      render();
    });
  }

  function pay() {
    ctl.payAndStart().then(function (out) { if (out && out.message) toast(out.message); });
  }

  /* The EXISTING wallet Add Funds. Nothing is paid automatically afterwards:
     the athlete taps Pay & Start Program again and the server decides. */
  function addFunds() {
    if (window.ZitlasWallet && typeof window.ZitlasWallet.openAddFunds === 'function') {
      window.ZitlasWallet.openAddFunds();
      toast('After adding funds, tap Pay & Start Program — nothing is charged automatically.');
    } else {
      toast('Open your ZITLAS Wallet to add funds, then tap Pay & Start Program.');
    }
  }

  function showSignIn() {
    var list = $('cpgList');
    if (!list) return;
    list.innerHTML = '<div class="cpg-panel cpg-panel--muted" data-signin>' +
      '<div class="cpg-panel-title">Please sign in</div>' +
      '<p class="cpg-panel-body">Sign in to see Personal Coaching Programs and your requests.</p>' +
      '<a class="cpg-btn cpg-btn--primary" href="/">Sign in</a></div>';
  }

  document.addEventListener('DOMContentLoaded', function () {
    var back = $('cpgBack');
    if (back) {
      back.addEventListener('click', function () {
        if (window.history.length > 1) window.history.back();
        else window.location.href = '/';
      });
    }
    if (!F) {
      var list = $('cpgList');
      if (list) list.innerHTML = '<div class="cpg-error">Programs could not load. Please refresh the page.</div>';
      return;
    }
    var params = new URLSearchParams(window.location.search);
    ctl = F.createController({
      expertId: params.get('expertId') || null,
      fetch: function (url, init) { return window.fetch(url, init); },
      getIdToken: function () {
        return (typeof getIdToken === 'function') ? getIdToken() : Promise.reject(new Error('not_signed_in'));
      }
    });
    ctl.subscribe(render);
    render();
    if (typeof ZitlasAuth === 'undefined' || typeof ZitlasAuth.onAuthStateChanged !== 'function') {
      showSignIn();
      return;
    }
    ZitlasAuth.onAuthStateChanged(function (user) {
      if (!user) {
        loadedFor = null;
        showSignIn();
        return;
      }
      if (loadedFor === user.uid) return;
      loadedFor = user.uid;
      ctl.load();
    });
  });
})();
