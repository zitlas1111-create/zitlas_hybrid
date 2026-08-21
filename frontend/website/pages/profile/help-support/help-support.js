/* =============================================
   ZITLAS Help & Support — help-support.js

   A real support inbox, not a contact form. Three views on one page:
     list  -> the athlete's conversations
     form  -> open a new one
     chat  -> the thread, with live support replies

   Reads come from a Firestore onSnapshot listener so a reply typed in the
   ZITLAS Gmail appears here on its own; firestore.rules allows the owner to
   READ support_conversations but denies every client write, so all sends go
   through the authenticated /api/support/* endpoints instead.
   ============================================= */

(function () {
  'use strict';

  /* ---- Theme ---- */
  (function applyTheme() {
    const saved = localStorage.getItem('zitlas_theme') || 'dark';
    const resolved = saved === 'system'
      ? (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
      : saved;
    document.documentElement.setAttribute('data-theme', resolved);
  })();

  /* ---- DOM ---- */
  const listView   = document.getElementById('listView');
  const formView   = document.getElementById('formView');
  const chatView   = document.getElementById('chatView');
  const convList   = document.getElementById('convList');
  const listEmpty  = document.getElementById('listEmpty');
  const newConvBtn = document.getElementById('newConvBtn');
  const backBtn    = document.getElementById('backBtn');
  const pageTitle  = document.getElementById('pageTitle');

  const form          = document.getElementById('supportForm');
  const subjectField  = document.getElementById('subjectField');
  const categoryField = document.getElementById('categoryField');
  const messageField  = document.getElementById('messageField');
  const charCountEl   = document.getElementById('charCount');
  const sendBtn       = document.getElementById('sendBtn');
  const sendBtnText   = document.getElementById('sendBtnText');

  const chatScroll   = document.getElementById('chatScroll');
  const chatSubject  = document.getElementById('chatSubject');
  const chatStatus   = document.getElementById('chatStatus');
  const chatComposer = document.getElementById('chatComposer');
  const chatInput    = document.getElementById('chatInput');
  const chatSend     = document.getElementById('chatSend');

  const formError       = document.getElementById('formError');
  const formErrorMsg    = document.getElementById('formErrorMsg');
  const formErrorDetail = document.getElementById('formErrorDetail');
  const formErrorCode   = document.getElementById('formErrorCode');
  const formErrorHint   = document.getElementById('formErrorHint');

  const successView    = document.getElementById('successView');
  const successViewBtn = document.getElementById('successViewBtn');
  const successBackBtn = document.getElementById('successBackBtn');

  const toastEl = document.getElementById('toast');

  /* ---- State ---- */
  const state = {
    view: 'list',
    conversations: [],
    activeId: null,
    unsubConv: null,
    unsubMsgs: null,
    // Guards against a double-submit: a disabled button alone does not stop a
    // second Enter keypress that is already queued, or a fast double-click
    // landing before the disable paints.
    submitting: false,
    lastCreatedId: null,
  };

  const STATUS_LABEL = {
    OPEN: 'Open',
    IN_PROGRESS: 'In progress',
    WAITING_FOR_USER: 'ZITLAS replied',
    WAITING_FOR_SUPPORT: 'Awaiting ZITLAS',
    RESOLVED: 'Resolved',
  };

  /* ---- Toast ---- */
  let toastTimer = null;
  function showToast(msg, type = '', duration = 3200) {
    if (!toastEl) return;
    toastEl.textContent = msg;
    toastEl.className = 'toast show' + (type ? ' ' + type : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.remove('show'); }, duration);
  }

  /* ---- Helpers ---- */
  function esc(v) {
    return String(v == null ? '' : v)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function fmtTime(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (isNaN(d)) return '';
    const now = new Date();
    const sameDay = d.toDateString() === now.toDateString();
    const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return sameDay ? time : d.toLocaleDateString([], { day: 'numeric', month: 'short' }) + ' · ' + time;
  }

  function authToken() {
    if (typeof getIdToken !== 'function') return Promise.resolve(null);
    return getIdToken().catch(function () { return null; });
  }

  function api(path, options) {
    return authToken().then(function (token) {
      if (!token) throw new Error('Please sign in to use Help & Support.');
      const opts = options || {};
      return fetch('/api/support' + path, {
        method: opts.method || 'GET',
        headers: Object.assign(
          { 'Authorization': 'Bearer ' + token },
          opts.body ? { 'Content-Type': 'application/json' } : {}
        ),
        body: opts.body ? JSON.stringify(opts.body) : undefined,
      }).then(function (res) {
        if (!res.ok) {
          return res.text().then(function (raw) {
            var parsed = null;
            try { parsed = JSON.parse(raw); } catch (_) { /* not JSON */ }
            var detail = parsed && parsed.detail;

            // FastAPI's detail is a STRING for validation/auth errors and an
            // OBJECT {message, code, stage, hint} for our classified delivery
            // failures. Both are preserved verbatim on the thrown error so the
            // UI can show the real cause rather than inventing one.
            var err = new Error(
              (detail && detail.message) ||
              (typeof detail === 'string' ? detail : '') ||
              statusMessage(res.status)
            );
            err.status = res.status;
            err.code   = (detail && detail.code) || ('http_' + res.status);
            err.hint   = (detail && detail.hint) || statusHint(res.status);
            // 422 carries an array of field errors — keep it readable.
            if (Array.isArray(detail)) {
              err.message = detail.map(function (d) {
                return (d.loc ? d.loc.join('.') + ': ' : '') + (d.msg || '');
              }).join('; ') || 'Validation failed.';
              err.code = 'validation_error';
            }
            if (!parsed && raw) err.hint = err.hint || raw.slice(0, 300);
            console.error('[HelpCenter] ' + res.status + ' from ' + path, {
              status: res.status, code: err.code, detail: detail, raw: raw
            });
            throw err;
          });
        }
        return res.json();
      }, function (networkErr) {
        // fetch() rejects only on a transport failure — DNS, offline, CORS,
        // or a dead server. That is a different problem from any HTTP status
        // and must not be reported as one.
        var err = new Error(
          'Could not reach the ZITLAS server. Check your connection.');
        err.status = 0;
        err.code = 'network_unreachable';
        err.hint = String(networkErr && networkErr.message || networkErr);
        console.error('[HelpCenter] network failure calling ' + path, networkErr);
        throw err;
      });
    });
  }

  // Plain-language meaning for the statuses this API can actually return.
  function statusMessage(status) {
    switch (status) {
      case 400: return 'The request was rejected as invalid.';
      case 401: return 'You are not signed in, or your session expired.';
      case 403: return 'You do not have permission to do that.';
      case 404: return 'The support endpoint was not found on the server.';
      case 422: return 'Some of the details you entered are not valid.';
      case 500: return 'The ZITLAS server hit an internal error.';
      case 502: return 'The server could not deliver the message.';
      case 503: return 'Support email is not configured on the server.';
      case 504: return 'The mail server did not respond in time.';
      default:  return 'Request failed (HTTP ' + status + ').';
    }
  }

  function statusHint(status) {
    switch (status) {
      case 401: return 'Sign out and sign back in, then try again.';
      case 404: return 'The backend may be running an older build — ' +
                       'POST /api/support/contact is missing.';
      case 500: return 'Check the backend terminal for the traceback.';
      default:  return '';
    }
  }

  /* ---- Error panel ---- */
  function showFormError(err) {
    if (!formError) return;
    formErrorMsg.textContent =
      err && err.message ? err.message : 'Unable to send your message.';

    var code = err && err.code;
    formErrorDetail.hidden = !code;
    if (code) {
      formErrorCode.textContent =
        code + (err.status ? '  (HTTP ' + err.status + ')' : '');
    }

    var hint = err && err.hint;
    formErrorHint.hidden = !hint;
    if (hint) formErrorHint.textContent = hint;

    formError.hidden = false;
    formError.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  function clearFormError() {
    if (formError) formError.hidden = true;
  }

  /* ---- View switching ---- */
  function setView(view) {
    state.view = view;
    listView.hidden    = view !== 'list';
    formView.hidden    = view !== 'form';
    successView.hidden = view !== 'success';
    chatView.hidden    = view !== 'chat';
    pageTitle.textContent =
      view === 'form'    ? 'New Conversation' :
      view === 'chat'    ? 'Conversation' :
      view === 'success' ? 'Message Sent' : 'Help & Support';
    if (view !== 'chat') detachThread();
  }

  // In-page back before leaving the page entirely, so the chat and the form
  // both return to the list rather than dumping the athlete on Profile.
  backBtn.addEventListener('click', function (e) {
    // 'form', 'success' and 'chat' all step back to the list rather than
    // leaving the page entirely.
    if (state.view !== 'list') {
      e.preventDefault();
      setView('list');
      loadConversations();
    }
  });

  newConvBtn.addEventListener('click', function () {
    clearFormError();
    subjectField.value = '';
    categoryField.value = '';
    messageField.value = '';
    charCountEl.textContent = '0';
    clearErrors();
    setView('form');
  });

  /* ---- Conversation list ---- */
  function statusPill(status) {
    const label = STATUS_LABEL[status] || status || 'Open';
    const cls = status === 'WAITING_FOR_USER' ? 'is-replied'
      : status === 'RESOLVED' ? 'is-resolved' : 'is-waiting';
    return '<span class="conv-status ' + cls + '">' + esc(label) + '</span>';
  }

  function renderList() {
    convList.innerHTML = '';
    const rows = state.conversations;
    listEmpty.hidden = rows.length > 0;

    rows.forEach(function (c) {
      const unread = Number(c.unreadByUser || 0);
      const item = document.createElement('button');
      item.type = 'button';
      item.className = 'conv-item' + (unread > 0 ? ' has-unread' : '');
      item.innerHTML =
        '<div class="conv-top">' +
          '<span class="conv-subject">' + esc(c.subject || 'Support request') + '</span>' +
          (unread > 0 ? '<span class="conv-badge">' + unread + '</span>' : '') +
        '</div>' +
        '<div class="conv-preview">' +
          (c.lastMessageBy === 'support' ? '<span class="conv-by">ZITLAS · </span>' : '') +
          esc(c.lastMessageText || 'No messages yet') +
        '</div>' +
        '<div class="conv-meta">' + statusPill(c.status) +
          '<span class="conv-time">' + esc(fmtTime(c.lastMessageAt)) + '</span>' +
        '</div>';
      item.addEventListener('click', function () { openThread(c.id); });
      convList.appendChild(item);
    });
  }

  function loadConversations() {
    return api('/conversations').then(function (data) {
      state.conversations = data.conversations || [];
      renderList();
    }).catch(function (e) {
      showToast(e.message, 'error');
      listEmpty.hidden = false;
    });
  }

  /* ---- New conversation ---- */
  function setError(id, msg) {
    const el = document.getElementById(id);
    if (el) el.textContent = msg || '';
  }
  function clearErrors() {
    ['subjectError', 'categoryError', 'messageError'].forEach(function (id) { setError(id, ''); });
  }

  if (messageField) {
    messageField.addEventListener('input', function () {
      charCountEl.textContent = messageField.value.length;
    });
  }

  function validate() {
    clearErrors();
    let ok = true;
    if (!subjectField.value.trim()) { setError('subjectError', 'Subject is required.'); ok = false; }
    if (!categoryField.value)       { setError('categoryError', 'Please choose a category.'); ok = false; }
    if (!messageField.value.trim()) { setError('messageError', 'Message is required.'); ok = false; }
    return ok;
  }

  form.addEventListener('submit', function (e) {
    e.preventDefault();

    // Duplicate-submit guard. The backend now only answers 2xx once the mail
    // has actually been accepted, so a resend is a genuinely duplicated
    // support ticket rather than a harmless retry.
    if (state.submitting) return;
    if (!validate()) return;

    // Success and error are mutually exclusive — clear the previous failure
    // before attempting, so a stale error can never sit next to a success.
    clearFormError();

    state.submitting = true;
    sendBtn.disabled = true;
    sendBtn.setAttribute('aria-busy', 'true');
    sendBtnText.textContent = 'Sending…';

    // name/email are REQUIRED by the contact schema and are read from the
    // signed-in Firebase user, not typed again — the athlete already
    // identified themselves by logging in. Omitting them is what produced
    // "Field required; Field required" (422) against the deployed backend.
    // The server still treats the verified ID token as authoritative for
    // identity; these are a display fallback only.
    var signedIn = (typeof ZitlasAuth !== 'undefined' && ZitlasAuth)
      ? ZitlasAuth.currentUser : null;

    api('/contact', {
      method: 'POST',
      body: {
        name: (signedIn && (signedIn.displayName || '').trim()) || 'ZITLAS User',
        email: (signedIn && (signedIn.email || '').trim()) || '',
        subject: subjectField.value.trim(),
        category: categoryField.value,
        message: messageField.value.trim(),
      },
    }).then(function (data) {
      // Reached ONLY on a 2xx — api() throws on every non-ok status, and the
      // backend reserves 2xx for mail the support inbox has accepted. So the
      // success panel can never appear for an undelivered message.
      state.lastCreatedId = data && data.conversationId;

      // Reset the form so a later "New Conversation" starts clean.
      subjectField.value = '';
      categoryField.value = '';
      messageField.value = '';
      charCountEl.textContent = '0';
      clearErrors();

      setView('success');
      window.scrollTo({ top: 0, behavior: 'smooth' });
      loadConversations();
    }).catch(function (err) {
      // Failure keeps the athlete on the form with their text intact, so a
      // retry costs nothing to retype. The panel shows the backend's own
      // classification; the toast is only a secondary cue.
      showFormError(err);
      showToast('We couldn\'t send your message. See the details above.', 'error');
    }).finally(function () {
      state.submitting = false;
      sendBtn.disabled = false;
      sendBtn.removeAttribute('aria-busy');
      sendBtnText.textContent = 'Send Message';
    });
  });

  successViewBtn.addEventListener('click', function () {
    if (state.lastCreatedId) openThread(state.lastCreatedId);
    else { setView('list'); loadConversations(); }
  });

  successBackBtn.addEventListener('click', function () {
    setView('list');
    loadConversations();
  });

  /* ---- Chat thread ---- */
  function detachThread() {
    if (state.unsubConv) { state.unsubConv(); state.unsubConv = null; }
    if (state.unsubMsgs) { state.unsubMsgs(); state.unsubMsgs = null; }
  }

  function renderThread(messages) {
    chatScroll.innerHTML = '';
    messages.forEach(function (m) {
      const mine = m.senderType === 'user';
      const row = document.createElement('div');
      row.className = 'bubble-row ' + (mine ? 'is-user' : 'is-support');
      row.innerHTML =
        (!mine ? '<div class="bubble-who">ZITLAS Support</div>' : '') +
        '<div class="bubble">' + esc(m.message).replace(/\n/g, '<br>') + '</div>' +
        '<div class="bubble-time">' + esc(fmtTime(m.createdAt)) +
          (mine ? '<span class="bubble-tick" title="Sent">✓</span>' : '') +
        '</div>';
      chatScroll.appendChild(row);
    });
    chatScroll.scrollTop = chatScroll.scrollHeight;
  }

  function renderChatHeader(conv) {
    chatSubject.textContent = conv.subject || 'Support request';
    chatStatus.innerHTML = statusPill(conv.status);
  }

  function openThread(cid) {
    if (!cid) return;
    state.activeId = cid;
    setView('chat');
    chatScroll.innerHTML = '<div class="chat-loading">Loading…</div>';

    // Seed from the API so the thread renders even if the listener is slow
    // or Firestore reads are blocked (e.g. an ad-blocker on the SDK).
    api('/conversations/' + encodeURIComponent(cid) + '/messages')
      .then(function (data) {
        renderChatHeader(data.conversation || {});
        renderThread(data.messages || []);
        attachLive(cid);
        return api('/conversations/' + encodeURIComponent(cid) + '/read', { method: 'POST' });
      })
      .then(function () { loadConversations(); })
      .catch(function (e) {
        chatScroll.innerHTML = '';
        showToast(e.message, 'error');
      });
  }

  function attachLive(cid) {
    detachThread();
    if (typeof ZitlasDB === 'undefined' || !ZitlasDB) return;

    const ref = ZitlasDB.collection('support_conversations').doc(cid);

    state.unsubConv = ref.onSnapshot(function (snap) {
      if (snap.exists) renderChatHeader(snap.data() || {});
    }, function () { /* rules denial or offline — the API seed still stands */ });

    state.unsubMsgs = ref.collection('messages').onSnapshot(function (snap) {
      const rows = [];
      snap.forEach(function (d) { rows.push(Object.assign({ id: d.id }, d.data())); });
      rows.sort(function (a, b) { return (a.createdAt || '') < (b.createdAt || '') ? -1 : 1; });
      if (rows.length) renderThread(rows);

      // A reply that arrives while the thread is open is already read.
      const hasUnreadSupport = rows.some(function (r) {
        return r.senderType === 'support' && !r.readByUser;
      });
      if (hasUnreadSupport) {
        api('/conversations/' + encodeURIComponent(cid) + '/read', { method: 'POST' })
          .catch(function () {});
      }
    }, function () { /* see above */ });
  }

  chatComposer.addEventListener('submit', function (e) {
    e.preventDefault();
    const text = chatInput.value.trim();
    if (!text || !state.activeId) return;

    if (state.submitting) return;
    state.submitting = true;
    chatSend.disabled = true;
    api('/conversations/' + encodeURIComponent(state.activeId) + '/messages', {
      method: 'POST',
      body: { message: text },
    }).then(function () {
      chatInput.value = '';
      chatInput.style.height = 'auto';
      return api('/conversations/' + encodeURIComponent(state.activeId) + '/messages');
    }).then(function (data) {
      renderThread(data.messages || []);
      renderChatHeader(data.conversation || {});
      loadConversations();
    }).catch(function (err) {
      // The text stays in the box so nothing is lost on a failed send.
      showToast(err.message || 'Could not send. Please try again.', 'error');
    }).finally(function () {
      state.submitting = false;
      chatSend.disabled = false;
    });
  });

  chatInput.addEventListener('input', function () {
    chatInput.style.height = 'auto';
    chatInput.style.height = Math.min(chatInput.scrollHeight, 140) + 'px';
  });

  chatInput.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      chatComposer.dispatchEvent(new Event('submit'));
    }
  });

  /* ---- Boot ---- */
  function boot() {
    setView('list');

    // Deep link from a push/notification: ?conversation=<id>
    const deepLink = new URLSearchParams(window.location.search).get('conversation');

    if (typeof ZitlasAuth === 'undefined' || !ZitlasAuth) {
      showToast('Please sign in to use Help & Support.', 'error');
      return;
    }
    ZitlasAuth.onAuthStateChanged(function (user) {
      if (!user) {
        showToast('Please sign in to use Help & Support.', 'error');
        listEmpty.hidden = false;
        return;
      }
      loadConversations().then(function () {
        if (deepLink) openThread(deepLink);
      });
    });
  }

  window.addEventListener('beforeunload', detachThread);

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
