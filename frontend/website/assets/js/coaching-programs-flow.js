/*!
 * ZITLAS — Personal Coaching Programs: the website's flow
 * (assets/js/coaching-programs-flow.js)
 *
 * ONE PRODUCT, TWO CLIENTS. Every rule, status and message here is the app's
 * (mobile/lib/features/coaching_programs/), and both call the SAME backend —
 * /api/coaching-programs (backend/routes/coaching_programs.py). The server
 * decides everything that matters: which experts offer a program, the price,
 * the request and its status, the payment and the start/end dates. Nothing
 * here prices, dates or activates anything. tests/js/coaching-programs-web.test.mjs
 * pins the parity with the app.
 *
 *   Get Started -> choose your expert, only if none is chosen yet
 *     (GET /programs/{id}/experts)
 *     -> review -> POST /requests -> pending -> the expert accepts
 *     -> Pay & Start Program (POST /requests/{id}/pay) -> active
 *
 * DOM-free: pages/coaching-programs/coaching-programs.js renders it.
 */
(function (root) {
  'use strict';

  var API = '/api/coaching-programs';

  /* Copy and artwork only — the same three programs, words and order as the
     app's kCoachingPrograms. No price, and no duration arithmetic. */
  var PROGRAMS = [
    {
      id: '10_day',
      title: '10-Day Program',
      durationLabel: '10 days',
      description: 'Kick-start your transformation with focused expert guidance for 10 days.',
      highlights: [
        'Expert creates or customizes your diet plan',
        'Expert reviews and rates your meal photos',
        'Expert can adjust your diet when needed',
        'Regular diet review during the program',
        'Detailed Personal Coaching Report at the end'
      ],
      image: '/assets/images/programs/10-day-program.png'
    },
    {
      id: '1_month',
      title: '1-Month Program',
      durationLabel: '30 days',
      description: 'Build consistent habits with expert guidance throughout your 30-day journey.',
      highlights: [
        'Personalized diet guidance',
        'Meal photo review by your expert',
        'Diet adjustments when needed',
        'Regular diet review',
        'Progress guidance',
        'Personal Coaching Report at completion'
      ],
      image: '/assets/images/programs/1-month-program.png'
    },
    {
      id: '3_month',
      title: '3-Month Program',
      durationLabel: '90 days',
      description: 'Build lasting habits and make meaningful progress with longer-term expert guidance.',
      highlights: [
        'Personalized nutrition guidance',
        'Meal photo review',
        'Expert diet adjustments',
        'Regular plan reviews',
        'Progress guidance',
        'Personal Coaching Report at completion'
      ],
      image: '/assets/images/programs/3-month-program.png'
    }
  ];

  var STATUS = {
    PENDING: 'pending_expert_acceptance',
    ACCEPTED: 'accepted',
    DECLINED: 'declined',
    ACTIVE: 'active',
    COMPLETED: 'completed'
  };

  /* The app's words (coaching_programs.dart), key for key. */
  var MESSAGES = {
    notOffered: "Your expert hasn't set a price for this program yet.",
    expertUnavailable: "Your expert isn't taking program requests right now.",
    priceLoadFailed: "Couldn't load the price.",
    chooseExpertToPrice: 'Choose an expert to see their price',
    chooseAnotherExpert: 'Choose Another Expert',
    pickExpertTitle: 'Choose your expert',
    noExperts: 'No expert offers this program right now. Please check back soon.',
    expertsLoadFailed: "Couldn't load experts for this program. Please try again.",
    expertLoadFailed: "Couldn't load this expert's prices. Please try again.",
    requestSent: "Request sent to your expert. You won't be charged unless they accept and you pay.",
    alreadyRequested: "You've already requested this program.",
    otherRequestOpen: 'You already have a program request with this expert.',
    otherRunning: 'You already have a program running with this expert.',
    paymentUnconfirmed: "We couldn't confirm your payment. Tap Pay & Start Program again — you won't be charged twice.",
    pendingTitle: 'Pending expert acceptance',
    pendingBody: 'Your request has been sent. Your expert will accept or decline it.',
    acceptedTitle: 'Your expert accepted the program',
    acceptedBody: 'Pay from your ZITLAS Wallet to start your program.',
    payLabel: 'Pay & Start Program',
    activeTitle: 'Program active',
    endedTitle: 'Program ended',
    completedTitle: 'Program completed',
    statusUnknownTitle: 'Status unavailable',
    statusUnknownBody: "We couldn't read this request's status. Please refresh.",
    started: 'Payment successful — your program has started.',
    alreadyPaid: 'This program is already paid for.',
    shortfall: 'Programs are paid in full from your ZITLAS Wallet. Add funds to continue — nothing has been charged.',
    fundsAddedReady: 'Funds added. Tap Pay & Start Program to pay from your wallet.',
    fundsAddedShort: 'Funds added, but your wallet is still short — add a little more to continue.',
    declinedTitle: 'Expert declined',
    declinedBody: 'Your expert declined this request. You can send a new one.',
    walletFrozen: "Wallet is temporarily unavailable. It's coming in a future update — your balance and transaction history are safe."
  };

  /* The server's refusal codes -> the app's words
     (CoachingProgramsRepository.messageFor). */
  var CODE_MESSAGES = {
    program_unavailable: "This program isn't available from this expert right now.",
    program_request_exists: 'You already have a program request with this expert.',
    open_request_exists: 'You already have a coaching request waiting for a response.',
    active_coaching_exists: 'You already have an active personal coach.',
    expert_not_found: "This coach isn't available right now. Please choose another.",
    cannot_request_self: "You can't request your own program.",
    invalid_program: 'That program is no longer offered.',
    not_accepted: "Your expert hasn't accepted this program yet.",
    not_payable: 'This program can no longer be paid for.',
    request_invalid: "This program can't be paid right now. Please contact support — nothing was charged.",
    payment_already_recorded: "This program can't be paid right now. Please contact support — nothing was charged.",
    program_payments_disabled: 'Program payments are not available right now. Nothing was charged.'
  };
  var SIGN_IN_AGAIN = 'Please sign in again to continue.';
  var UNREACHABLE = "Couldn't reach ZITLAS. Please try again in a moment.";
  var GENERIC_REQUEST_FAILURE = 'Could not send your request. Please try again.';

  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  function programById(id) {
    for (var i = 0; i < PROGRAMS.length; i++) if (PROGRAMS[i].id === id) return PROGRAMS[i];
    return null;
  }

  /* Only a positive whole number of paise is a price: 0, negatives,
     fractions and strings are "no price" — never ₹0. */
  function positivePaise(v) {
    return (typeof v === 'number' && isFinite(v) && Math.floor(v) === v && v > 0) ? v : null;
  }

  function toInt(v) {
    return (typeof v === 'number' && isFinite(v)) ? Math.round(v) : 0;
  }

  function toDate(v) {
    if (typeof v !== 'string' || !v) return null;
    var d = new Date(v);
    return isNaN(d.getTime()) ? null : d;
  }

  function statusOf(raw) {
    for (var k in STATUS) if (STATUS[k] === raw) return raw;
    return 'unknown';
  }

  /* One request, as the server reported it — or null when it is not one. */
  function parseRequest(j) {
    if (!j || typeof j !== 'object') return null;
    if (typeof j.requestId !== 'string' || !j.requestId ||
        typeof j.expertId !== 'string' || typeof j.programId !== 'string') return null;
    var days = j.durationDays;
    return {
      requestId: j.requestId,
      expertId: j.expertId,
      expertName: typeof j.expertName === 'string' ? j.expertName : null,
      programId: j.programId,
      durationDays: (typeof days === 'number' && days > 0 && Math.floor(days) === days) ? days : null,
      pricePaise: positivePaise(j.pricePaise),
      status: statusOf(j.status),
      paymentStatus: typeof j.paymentStatus === 'string' ? j.paymentStatus : null,
      requestedAt: toDate(j.requestedAt),
      paidAt: toDate(j.paidAt),
      startedAt: toDate(j.startedAt),
      endsAt: toDate(j.endsAt),
      amountPaidPaise: positivePaise(j.amountPaidPaise)
    };
  }

  /* An expert's server-side prices plus the athlete's request with them. */
  function parseOffer(j) {
    j = j || {};
    var prices = {};
    (Array.isArray(j.programs) ? j.programs : []).forEach(function (p) {
      if (!p || p.available !== true) return;
      var price = positivePaise(p.pricePaise);
      if (typeof p.programId === 'string' && price !== null) prices[p.programId] = price;
    });
    return {
      expertId: typeof j.expertId === 'string' ? j.expertId : '',
      expertName: (typeof j.expertName === 'string' && j.expertName) ? j.expertName : 'your expert',
      // false only when the server says this expert takes no program requests;
      // an older server that doesn't send it means "available".
      expertAvailable: j.expertAvailable !== false,
      prices: prices,
      request: parseRequest(j.request)
    };
  }

  /* "Choose your expert": approved experts who offer the program. */
  function parseExperts(j) {
    var out = [];
    (Array.isArray(j && j.experts) ? j.experts : []).forEach(function (e) {
      if (!e || typeof e.expertId !== 'string' || !e.expertId) return;
      var price = positivePaise(e.pricePaise);
      if (price === null) return;
      var name = typeof e.expertName === 'string' ? e.expertName.trim() : '';
      var spec = typeof e.specialization === 'string' ? e.specialization.trim() : '';
      var photo = typeof e.photoUrl === 'string' && /^https?:\/\//i.test(e.photoUrl) ? e.photoUrl : null;
      out.push({
        expertId: e.expertId,
        expertName: name || 'Expert',
        specialization: spec || null,
        photoUrl: photo,
        expertise: (Array.isArray(e.expertise) ? e.expertise : [])
          .filter(function (a) { return typeof a === 'string' && a.trim(); })
          .map(function (a) { return a.trim(); }),
        pricePaise: price
      });
    });
    return out;
  }

  /* Still waiting — on the expert (pending) or on payment (accepted). */
  function isOpen(r) {
    return !!r && (r.status === STATUS.PENDING || r.status === STATUS.ACCEPTED);
  }

  function awaitingPayment(r) {
    return !!r && r.status === STATUS.ACCEPTED && r.paymentStatus !== 'paid';
  }

  /* A paid program that has not reached its end date. */
  function isRunning(r, now) {
    return !!r && r.status === STATUS.ACTIVE &&
      (!r.endsAt || r.endsAt.getTime() > (now || new Date()).getTime());
  }

  function codeOf(data) {
    var d = data && data.detail;
    if (typeof d === 'string') return d;
    if (d && typeof d.error === 'string') return d.error;
    return null;
  }

  /* A refusal in words an athlete can act on — the app's messageFor. */
  function messageFor(status, data) {
    var code = codeOf(data);
    if (code && Object.prototype.hasOwnProperty.call(CODE_MESSAGES, code)) return CODE_MESSAGES[code];
    if (status === 401 || status === 403) return SIGN_IN_AGAIN;
    if (!status || status >= 500) return UNREACHABLE;
    return GENERIC_REQUEST_FAILURE;
  }

  /* The expert list's failures — the app's fetchProgramExperts. */
  function expertsMessageFor(status, data) {
    var code = codeOf(data);
    var known = code === 'invalid_program' || status === 401 || status === 403 ||
      !status || status >= 500;
    return known ? messageFor(status, data) : MESSAGES.expertsLoadFailed;
  }

  /* 499900 -> ₹4,999 · 49950 -> ₹499.50 (Indian grouping, like the app). */
  function formatPrice(paise) {
    var rupees = Math.floor(paise / 100);
    var cents = paise % 100;
    var digits = String(rupees);
    var grouped;
    if (digits.length <= 3) {
      grouped = digits;
    } else {
      var last3 = digits.slice(-3);
      var head = digits.slice(0, -3);
      var groups = [];
      while (head.length > 2) {
        groups.unshift(head.slice(-2));
        head = head.slice(0, -2);
      }
      if (head) groups.unshift(head);
      grouped = groups.join(',') + ',' + last3;
    }
    return cents === 0 ? '₹' + grouped : '₹' + grouped + '.' + (cents < 10 ? '0' : '') + cents;
  }

  /* 23 Sep 2026, in the viewer's local time. */
  function formatDate(d) {
    if (!d) return '—';
    return d.getDate() + ' ' + MONTHS[d.getMonth()] + ' ' + d.getFullYear();
  }

  /* The Programs page's state — the app's CoachingProgramsController:
     the expert's server-side prices, the athlete's request with them,
     sending a request, and paying for an accepted one. */
  function createController(opts) {
    opts = opts || {};
    var fetchImpl = opts.fetch;
    var tokenFn = opts.getIdToken;
    var clock = opts.now || function () { return new Date(); };
    var listeners = [];
    var s = {
      expertId: opts.expertId || null,
      state: 'loading',   // loading | ready | failed
      offer: null,
      submitting: null,   // the program id while its request is being sent
      paying: false,
      shortfall: null     // {requiredPaise, availablePaise} after a 402
    };

    function emit() {
      listeners.slice().forEach(function (fn) {
        try { fn(s); } catch (e) { if (root.console) root.console.error('[PROGRAMS]', e); }
      });
    }

    /* Resolves {status, data}. No connection -> status 0; no session -> 401. */
    function call(path, method, body) {
      var token;
      try { token = tokenFn(); } catch (e) { token = Promise.reject(e); }
      return Promise.resolve(token).then(function (t) {
        var init = { method: method || 'GET', headers: { 'Authorization': 'Bearer ' + t } };
        if (body !== undefined) {
          init.headers['Content-Type'] = 'application/json';
          init.body = JSON.stringify(body);
        }
        return Promise.resolve().then(function () { return fetchImpl(API + path, init); }).then(function (res) {
          return Promise.resolve().then(function () { return res.json(); })
            .catch(function () { return {}; })
            .then(function (data) { return { status: res.status, data: data }; });
        }, function () { return { status: 0, data: null }; });
      }, function () { return { status: 401, data: { detail: 'not_signed_in' } }; });
    }

    function request() { return s.offer ? s.offer.request : null; }

    function requestFor(programId) {
      var r = request();
      return r && r.programId === programId ? r : null;
    }

    /* Waiting or running with this expert — nothing else can start. */
    function openRequest() {
      var r = request();
      return r && (isOpen(r) || isRunning(r, clock())) ? r : null;
    }

    function priceFor(programId) {
      if (s.state !== 'ready' || !s.offer) return null;
      return Object.prototype.hasOwnProperty.call(s.offer.prices, programId) ? s.offer.prices[programId] : null;
    }

    /* What ONE program card is, as one explicit state — the app's
       CoachingProgramsController.availabilityFor:
         loading · failed · choose_expert · available · not_offered · expert_unavailable
       Get Started works in choose_expert and available only — the two states
       in which the server can create the request. A missing price is never a
       catch-all "unavailable": the card says WHY. */
    function availabilityFor(programId) {
      if (s.state === 'loading') return 'loading';
      if (s.state === 'failed') return 'failed';
      if (!s.expertId || !s.offer) return 'choose_expert';
      if (priceFor(programId) !== null) return 'available';
      return s.offer.expertAvailable ? 'not_offered' : 'expert_unavailable';
    }

    var PRICE_TEXT = {
      loading: 'Loading price…',
      failed: MESSAGES.priceLoadFailed,
      choose_expert: MESSAGES.chooseExpertToPrice,
      not_offered: MESSAGES.notOffered,
      expert_unavailable: MESSAGES.expertUnavailable
    };

    /* Everything one card shows, decided here so the page only renders it.
       `busy` is the page's own "a flow is already open". */
    function cardFor(programId, busy) {
      var availability = availabilityFor(programId);
      var price = priceFor(programId);
      var req = requestFor(programId);
      var open = openRequest();
      var blockedBy = open && open.programId !== programId ? open : null;
      var working = !!busy || s.submitting !== null || s.paying;
      // Nothing to start while this program waits (on the expert or on
      // payment) or runs.
      var showStart = !(req && (isOpen(req) || isRunning(req, clock())));
      var startable = availability === 'available' || availability === 'choose_expert';
      return {
        availability: availability,
        price: price,
        priceText: price !== null ? formatPrice(price) : (PRICE_TEXT[availability] || ''),
        request: req,
        blockedBy: blockedBy,
        showStart: showStart,
        startEnabled: showStart && startable && !blockedBy && !working,
        // Switching experts is the athlete's explicit choice — its own button,
        // offered when this expert doesn't offer the program or declined it.
        showChooseAnother: showStart && !blockedBy && !!s.expertId &&
          (availability === 'not_offered' || availability === 'expert_unavailable' ||
           (!!req && req.status === STATUS.DECLINED)),
        chooseAnotherEnabled: !working
      };
    }

    function loadOffer(id) {
      s.state = 'loading';
      emit();
      return call('/experts/' + encodeURIComponent(id)).then(function (r) {
        if (r.status === 200 && r.data && typeof r.data === 'object') {
          s.offer = parseOffer(r.data);
          s.state = 'ready';
          if (!awaitingPayment(s.offer.request)) {
            s.shortfall = null;
            s.paying = false;
          }
        } else {
          s.state = 'failed';
        }
        emit();
      });
    }

    /* With an expert: their prices and request. Without one: restore the
       athlete's current program from the server (a refresh never hides it). */
    function load() {
      if (s.expertId) return loadOffer(s.expertId);
      s.state = 'loading';
      emit();
      return call('/requests/me').then(function (r) {
        var current = (r.status === 200 && r.data) ? parseRequest(r.data.current) : null;
        if (current && current.expertId) {
          s.expertId = current.expertId;
          return loadOffer(current.expertId);
        }
        s.offer = null;
        s.state = 'ready';
        emit();
      });
    }

    function selectExpert(id) {
      id = String(id || '').trim();
      if (!id) return Promise.resolve();
      if (id === s.expertId && s.state === 'ready' && s.offer) return Promise.resolve();
      s.expertId = id;
      s.offer = null;
      s.shortfall = null;
      s.paying = false;
      return loadOffer(id);
    }

    function expertsFor(programId) {
      return call('/programs/' + encodeURIComponent(programId) + '/experts').then(function (r) {
        if (r.status === 200 && r.data && Array.isArray(r.data.experts)) return parseExperts(r.data);
        throw new Error(expertsMessageFor(r.status, r.data));
      });
    }

    /* Sends ONLY the expert and the program. The server decides the price. */
    function requestProgram(programId) {
      if (!s.expertId || s.submitting !== null) {
        return Promise.resolve({ ok: false, message: s.expertId ? '' : MESSAGES.chooseExpertToPrice });
      }
      var expertId = s.expertId;
      s.submitting = programId;
      emit();
      return call('/requests', 'POST', { expertId: expertId, programId: programId }).then(function (r) {
        var req = (r.status === 200 && r.data && r.data.success) ? parseRequest(r.data.request) : null;
        if (req) {
          if (s.offer) s.offer.request = req;
          return { ok: true, message: r.data.alreadyRequested ? MESSAGES.alreadyRequested : MESSAGES.requestSent };
        }
        if (r.status === 200) return { ok: false, message: GENERIC_REQUEST_FAILURE };
        var code = codeOf(r.data);
        var out = { ok: false, message: messageFor(r.status, r.data) };
        if (code === 'program_unavailable' || code === 'program_request_exists') {
          // The server knows something this page does not — reload the truth.
          s.submitting = null;
          return loadOffer(expertId).then(function () { return out; });
        }
        return out;
      }).then(function (out) {
        s.submitting = null;
        emit();
        return out;
      });
    }

    /* PAY & START PROGRAM — the accepted request, in full, at the price the
       SERVER recorded. Only the request id is sent; a repeat is answered with
       the same paid program and never charged again. A short wallet sets
       `shortfall` and charges nothing — no checkout is ever opened here. */
    function payAndStart() {
      var r0 = request();
      if (!r0 || !awaitingPayment(r0) || s.paying) return Promise.resolve({ ok: false, message: '' });
      var expertId = s.expertId;
      s.paying = true;
      emit();
      return call('/requests/' + encodeURIComponent(r0.requestId) + '/pay', 'POST').then(function (r) {
        if (r.status === 200 && r.data && r.data.success) {
          var req = parseRequest(r.data.request);
          if (req && req.paymentStatus === 'paid') {
            if (s.offer) s.offer.request = req;
            s.shortfall = null;
            return { ok: true, message: r.data.already ? MESSAGES.alreadyPaid : MESSAGES.started };
          }
          s.paying = false;
          return loadOffer(expertId).then(function () {
            return { ok: false, message: MESSAGES.paymentUnconfirmed };
          });
        }
        var d = r.data && r.data.detail;
        if (r.status === 402 && d && typeof d === 'object') {
          s.shortfall = { requiredPaise: toInt(d.required), availablePaise: toInt(d.available) };
          return { ok: false, message: '' };
        }
        var code = codeOf(r.data);
        if (r.status === 503 && code === 'wallet_frozen') {
          // The app's WalletFrozenException words — the same text the server sends.
          return { ok: false, message: MESSAGES.walletFrozen };
        }
        var unconfirmed = !code && (!r.status || r.status >= 500);
        s.paying = false;
        return loadOffer(expertId).then(function () {
          return { ok: false, message: unconfirmed ? MESSAGES.paymentUnconfirmed : messageFor(r.status, r.data) };
        });
      }).then(function (out) {
        s.paying = false;
        emit();
        return out;
      });
    }

    function subscribe(fn) {
      listeners.push(fn);
      return function () {
        var i = listeners.indexOf(fn);
        if (i !== -1) listeners.splice(i, 1);
      };
    }

    return {
      state: function () { return s; },
      now: clock,
      priceFor: priceFor,
      availabilityFor: availabilityFor,
      cardFor: cardFor,
      requestFor: requestFor,
      openRequest: openRequest,
      load: load,
      selectExpert: selectExpert,
      expertsFor: expertsFor,
      requestProgram: requestProgram,
      payAndStart: payAndStart,
      subscribe: subscribe
    };
  }

  root.ZitlasProgramsFlow = {
    API: API,
    PROGRAMS: PROGRAMS,
    STATUS: STATUS,
    MESSAGES: MESSAGES,
    CODE_MESSAGES: CODE_MESSAGES,
    programById: programById,
    parseRequest: parseRequest,
    parseOffer: parseOffer,
    parseExperts: parseExperts,
    isOpen: isOpen,
    awaitingPayment: awaitingPayment,
    isRunning: isRunning,
    codeOf: codeOf,
    messageFor: messageFor,
    expertsMessageFor: expertsMessageFor,
    formatPrice: formatPrice,
    formatDate: formatDate,
    createController: createController
  };
})(typeof window !== 'undefined' ? window : this);
