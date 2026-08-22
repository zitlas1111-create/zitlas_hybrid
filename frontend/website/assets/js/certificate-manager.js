/*!
 * ZITLAS — Expert Certificate Verification (assets/js/certificate-manager.js)
 *
 * Shared logic used by expert-dashboard.js (upload + own certs), cprofile.js
 * (Verified Certificates + ZITLAS Verification modal), and the admin review
 * dashboard. Firestore-first architecture like the rest of this app — this
 * backend has no Firebase Admin SDK anywhere, so all Firestore writes happen
 * from the authenticated client, same as every other feature in ZITLAS.
 *
 * Firestore: expert_certificates/{certId}
 *   { certId, expertId, expertName, certificateUrl, fileType,
 *     storagePath, storageProvider ('firebase-storage'),
 *     coachName, certificateName, issuingOrganization, certificateNumber,
 *     issuedDate, expiryDate, verificationScore, verificationStatus
 *       ('verified' | 'pending_review' | 'rejected'),
 *     flags: {...}, analysisNotes,
 *     uploadedAt, reviewedBy, reviewedAt, rejectionReason }
 *
 * STORAGE: certificateUrl always points at Firebase Storage (permanent —
 * survives Render deploys), uploaded client-side in uploadAndVerify()
 * AFTER the backend's AI step accepts the file. The backend itself never
 * persists the file (see routes/certificates.py's docstring for the
 * ephemeral-local-disk bug this replaced).
 *
 * SECURITY NOTE: verificationStatus is only ever set by (a) the AI's own
 * computed result at upload time (backend-computed, client just persists —
 * never a user-editable field in any UI), or (b) the admin Approve/Reject
 * actions below. No UI anywhere lets an expert edit their own status. Real
 * enforcement ultimately needs Firestore security rules — flagged
 * repeatedly elsewhere in this project as a standing gap (currently
 * world-readable/writable) that should be closed before this ships wide.
 */
(function (win) {
  'use strict';

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function db() { return (typeof ZitlasDB !== 'undefined') ? ZitlasDB : null; }
  function storage() { return (typeof ZitlasStorage !== 'undefined') ? ZitlasStorage : null; }
  function newId() { return 'CERT_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8); }

  var _toastEl = null, _toastTimer = null;
  function toast(msg) {
    if (!_toastEl) {
      _toastEl = document.createElement('div');
      _toastEl.className = 'cert-toast';
      document.body.appendChild(_toastEl);
    }
    _toastEl.textContent = msg;
    _toastEl.classList.add('show');
    clearTimeout(_toastTimer);
    _toastTimer = setTimeout(function () { _toastEl.classList.remove('show'); }, 3600);
  }

  /* ── Storage: Firebase Storage, permanent — survives every Render
     deploy. (The backend's /api/certificates/verify used to write
     accepted files to a local "uploads/" folder and hand back a
     "/uploads/..." URL; that folder lives on Render's EPHEMERAL
     filesystem and is wiped on every deploy, so every certificate
     uploaded before a deploy 404'd forever after it — this replaces
     that with real permanent storage.) Runs only after the backend's AI
     step has already accepted the file, so nothing is ever stored here
     that failed verification. */
  function _uploadToStorage(expertId, file) {
    var s = storage();
    if (!s) return Promise.reject(new Error('Cloud storage is unavailable on this page — please reload and try again.'));
    /* Fail FAST. The SDK's default retry window is ~2 minutes, which is why
       a non-provisioned bucket left the UI stuck on a spinner for two full
       minutes before erroring. 25s is plenty for a real upload and turns a
       dead-bucket failure into a prompt, clear error instead of a hang. */
    try { s.setMaxUploadRetryTime(25000); s.setMaxOperationRetryTime(25000); } catch (_) {}
    var extMatch = /\.([a-z0-9]+)$/i.exec(file.name || '');
    var ext = extMatch ? extMatch[1].toLowerCase() : 'jpg';
    var path = 'certificates/' + expertId + '/' + newId() + '.' + ext;
    var ref = s.ref(path);
    console.log('[CERT] STEP 3 firebase upload started -> ' + path + ' (' + file.size + ' bytes)');
    return ref.put(file, { contentType: file.type || undefined })
      .then(function (snapshot) {
        console.log('[CERT] STEP 4 firebase upload success — fetching downloadURL');
        return snapshot.ref.getDownloadURL();
      })
      .then(function (url) {
        console.log('[CERT] STEP 4b downloadURL obtained — storageProvider=firebase-storage path=' + path + ' url=' + url);
        return { url: url, path: path };
      })
      .catch(function (e) {
        /* NEVER swallow this into a generic string without logging the raw
           SDK error first — that's the one thing that actually tells us
           WHICH of {bucket missing, rules blocking, Storage not enabled,
           network} we're looking at. e.code is the Firebase Storage error
           enum (storage/unauthorized, storage/unauthenticated,
           storage/object-not-found, storage/retry-limit-exceeded,
           storage/unknown, ...) — see
           https://firebase.google.com/docs/storage/web/handle-errors */
        console.error('[CERT] STEP 3/4 FAILED — raw Firebase error follows:');
        console.error('[CERT]   code=' + (e && e.code));
        console.error('[CERT]   message=' + (e && e.message));
        console.error('[CERT]   serverResponse=' + (e && e.serverResponse));
        console.error('[CERT]   name=' + (e && e.name));
        console.error('[CERT]   bucket=' + (s.app && s.app.options && s.app.options.storageBucket));
        console.error('[CERT]   full error object:', e);
        console.error('[CERT] Diagnosis: storage/retry-limit-exceeded or a bare network error with no HTTP ' +
                       'status usually means Cloud Storage was never enabled for this project (Firebase ' +
                       'Console -> Storage -> Get Started is a one-time step nobody has done yet, confirmed ' +
                       'separately by both bucket-name candidates 404ing on a raw REST probe). ' +
                       'storage/unauthorized or storage/unauthenticated means Storage IS enabled but its ' +
                       'security rules reject this write — that would be a DIFFERENT, easier fix (edit rules).');
        /* Include the raw code in the user-facing message too (not just the
           console) — the whole point of this pass is "never show a generic
           message without the real exception being visible". */
        var code = (e && e.code) || 'unknown';
        throw new Error('Could not upload the certificate — cloud storage error [' + code + ']. Please try again shortly.');
      });
  }

  /* ── Startup probe: confirms Storage is actually reachable the moment
     the SDK initializes, not just when an expert happens to upload. Cheap
     (fails on a nonexistent path either way) and safe (no write). Logs
     immediately on page load so the diagnosis is visible in the console
     before anyone touches the upload button. */
  function _probeStorageOnInit() {
    var s = storage();
    if (!s) { console.warn('[CERT] storage probe skipped — ZitlasStorage not initialized on this page (firebase-storage-compat.js not loaded here, or firebase.storage is not a function).'); return; }
    var bucket = (s.app && s.app.options && s.app.options.storageBucket) || '(unknown)';
    console.log('[CERT] storage probe — getStorage() returned an instance, bucket=' + bucket);
    s.ref('_probe/init_check.txt').getDownloadURL()
      .then(function () {
        console.log('[CERT] storage probe — unexpected success (a file exists at _probe/init_check.txt); bucket is definitely reachable and authorized.');
      })
      .catch(function (e) {
        if (e && e.code === 'storage/object-not-found') {
          console.log('[CERT] storage probe — code=storage/object-not-found. This is GOOD: it means the ' +
                      'bucket exists and rules allowed the read request through to the server, which then ' +
                      'correctly said "no such file". Uploads should work.');
        } else {
          console.error('[CERT] storage probe — code=' + (e && e.code) + ' message=' + (e && e.message) +
                        '. This is NOT storage/object-not-found, which means we could not even reach the ' +
                        'bucket to ask about the file. Likely cause: Cloud Storage is not enabled for this ' +
                        'project, or the bucket name in firebase-config.js (' + bucket + ') is wrong.');
        }
      });
  }

  /* ── Upload + AI verification (backend), then permanent storage ──
     onPhase(phaseKey) is an optional callback the caller uses to advance
     its own progress UI: 'verifying' -> 'uploading'. Every async boundary
     also logs a STEP marker so the whole pipeline is traceable in the
     console (STEP 1/2 here, STEP 3/4 in _uploadToStorage, STEP 5/6 at the
     saveCertificate call site, STEP 7 when the caller resets its UI). */
  function uploadAndVerify(expertId, file, onPhase) {
    function phase(p) { try { if (onPhase) onPhase(p); } catch (_) {} }
    var fd = new FormData();
    fd.append('expertId', expertId);
    fd.append('file', file);
    phase('verifying');
    console.log('[CERT] STEP 1 verify started — ' + (file.name || '(unnamed)') + ' ' + file.type + ' ' + file.size + 'B');
    return fetch('/api/certificates/verify', { method: 'POST', body: fd })
      .then(function (r) {
        if (!r.ok) return r.json().catch(function () { return null; }).then(function (e) {
          throw new Error((e && e.detail) || ('Verification failed (' + r.status + ')'));
        });
        return r.json();
      })
      .then(function (result) {
        console.log('[CERT] STEP 2 verify success — accepted=' + result.accepted +
                    ' status=' + result.verificationStatus + ' score=' + result.verificationScore);
        if (!result.accepted) return result;  // rejected by AI — no upload, no storage write
        phase('uploading');
        return _uploadToStorage(expertId, file).then(function (stored) {
          result.certificateUrl = stored.url;
          result.storagePath = stored.path;
          result.storageProvider = 'firebase-storage';
          return result;
        });
      });
  }

  /* ── Persist an accepted result as a new certificate doc ── */
  function saveCertificate(expertId, expertName, result) {
    var d = db();
    if (!d) return Promise.reject(new Error('Database unavailable'));
    var id = newId();
    var doc = {
      certId: id, expertId: expertId, expertName: expertName || 'Expert',
      certificateUrl: result.certificateUrl, fileType: result.fileType,
      storagePath: result.storagePath || null,
      storageProvider: result.storageProvider || null,
      coachName: result.coachName, certificateName: result.certificateName,
      issuingOrganization: result.issuingOrganization,
      certificateNumber: result.certificateNumber,
      issuedDate: result.issuedDate, expiryDate: result.expiryDate,
      verificationScore: result.verificationScore,
      /* The client NEVER asserts a verified badge. Regardless of the AI's
         verdict, a freshly-uploaded cert is stored as 'pending_review' and
         only an admin (backend, Admin SDK) can promote it to 'verified'
         (FIRESTORE_SECURITY_AUDIT.md V4; the create rule enforces this). The
         AI's own verdict is preserved as advisory context for the admin. */
      aiVerificationStatus: result.verificationStatus,
      verificationStatus: 'pending_review',
      flags: result.flags || {}, analysisNotes: result.analysisNotes || '',
      uploadedAt: new Date().toISOString(),
      reviewedBy: null, reviewedAt: null, rejectionReason: null,
    };
    console.log('[CERT] saving certId=' + id + ' firestorePath=expert_certificates/' + id +
                ' certificateUrl=' + doc.certificateUrl + ' storageProvider=' + doc.storageProvider);
    /* Note: no recomputeVerifiedFlag() here anymore. experts/{uid}.verified
       and .verification are backend-authoritative (set only by the admin
       approval endpoint via the Admin SDK) — a client write to them is now
       denied by Security Rules, and a freshly-uploaded PENDING certificate
       never changes verified status anyway. The badge is recomputed
       server-side when an admin approves. */
    return d.collection('expert_certificates').doc(id).set(doc)
      .then(function () { return doc; });
  }

  /* ── Verified-badge recompute — MOVED SERVER-SIDE ──
     experts/{uid}.verification / .verified are the badge's source of truth and
     are now BACKEND-ONLY (Security Rules deny client writes, per
     FIRESTORE_SECURITY_AUDIT.md V4). The recompute (derive verified from the
     expert's certificates and persist it) runs in the Admin SDK on the
     backend: automatically inside POST /api/admin/certificates/{approve,reject}
     and on demand via POST /api/admin/experts/recompute-verification (used by
     the admin cert-audit page). This client function is retained only as a
     no-op guard so any legacy caller resolves cleanly instead of attempting a
     now-denied Firestore write. */
  function recomputeVerifiedFlag(expertId) {
    console.warn('[CERT] recomputeVerifiedFlag is a no-op — verification is recomputed ' +
                 'server-side (/api/admin/experts/recompute-verification). expertId=' + expertId);
    return Promise.resolve();
  }

  /* ── Realtime listener: all certs for one expert ── */
  function listenForExpertCertificates(expertId, cb) {
    var d = db();
    if (!d || !expertId) return function () {};
    return d.collection('expert_certificates').where('expertId', '==', expertId)
      .onSnapshot(function (snap) {
        var certs = snap.docs.map(function (x) { return x.data(); })
          .sort(function (a, b) { return (b.uploadedAt || '') < (a.uploadedAt || '') ? -1 : 1; });
        cb(certs);
      }, function (e) { console.warn('[CERT] listener error', e); });
  }

  /* ── Admin: all pending_review certs across every expert ── */
  function listenForPendingCertificates(cb) {
    var d = db();
    if (!d) return function () {};
    return d.collection('expert_certificates').where('verificationStatus', '==', 'pending_review')
      .onSnapshot(function (snap) {
        var certs = snap.docs.map(function (x) { return x.data(); })
          .sort(function (a, b) { return (a.uploadedAt || '') < (b.uploadedAt || '') ? -1 : 1; });
        cb(certs);
      }, function (e) { console.warn('[CERT] pending listener error', e); });
  }

  /* ── Admin actions — now SERVER-authoritative ──
     verificationStatus / experts.verified used to be written straight from
     the admin's browser, gated only by a client-writable users/{uid}.role
     (FIRESTORE_SECURITY_AUDIT.md V3/V4 — trivially spoofable, and blocked
     outright by production Security Rules). They now go through
     POST /api/admin/certificates/{approve,reject}, which re-checks the caller
     is a real admin (custom claim / ZITLAS_ADMIN_UIDS) and writes via the
     Admin SDK, and ALSO grants/revokes the expert's Firebase custom claim so
     Security Rules recognize them. The admin UI is unchanged — same function
     signatures, same returned promise. */
  function _adminFetch(path, payload) {
    var auth = (typeof ZitlasAuth !== 'undefined') ? ZitlasAuth : null;
    var user = auth && auth.currentUser;
    if (!user || typeof user.getIdToken !== 'function') {
      return Promise.reject(new Error('Not signed in'));
    }
    return user.getIdToken().then(function (token) {
      return fetch(path, {
        method: 'POST',
        headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (res.status !== 200 || !data.success) {
          throw new Error((data && data.detail) || ('request_failed_' + res.status));
        }
        return data;
      });
    });
  }
  function approveCertificate(cert /*, adminUid (server derives from token) */) {
    return _adminFetch('/api/admin/certificates/approve', { certId: cert.certId });
  }
  function rejectCertificate(cert, adminUid, reason) {
    return _adminFetch('/api/admin/certificates/reject', { certId: cert.certId, reason: reason });
  }

  var REJECT_REASONS = [
    'Fake Certificate', 'Image Too Blurry', 'Document Not Readable',
    'Wrong Document Uploaded', 'Expired Certificate', 'Edited Certificate', 'Other',
  ];

  /* ══════════════════════════════════════════════
     SHARED MODALS
  ══════════════════════════════════════════════ */
  function ensureModal() {
    var bd = document.getElementById('certModalBackdrop');
    if (bd) return bd;
    bd = document.createElement('div');
    bd.id = 'certModalBackdrop'; bd.className = 'cert-modal-backdrop';
    bd.innerHTML = '<div class="cert-modal" id="certModal"></div>';
    document.body.appendChild(bd);
    bd.addEventListener('click', function (e) { if (e.target === bd) closeModal(); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && bd.classList.contains('open')) closeModal();
    });
    return bd;
  }
  function closeModal() {
    var bd = document.getElementById('certModalBackdrop');
    if (!bd) return;
    bd.classList.remove('open', 'cert-modal-backdrop--fullscreen');
    var modal = document.getElementById('certModal');
    if (modal) modal.classList.remove('cert-modal--viewer', 'cert-modal--fullscreen');
    if (_zoomPanCleanup) { _zoomPanCleanup(); _zoomPanCleanup = null; }
    setTimeout(function () { bd.style.display = 'none'; }, 200);
  }
  function openModalHtml(html) {
    var bd = ensureModal();
    var modal = document.getElementById('certModal');
    modal.classList.remove('cert-modal--viewer', 'cert-modal--fullscreen');
    modal.innerHTML = html;
    bd.style.display = 'flex';
    requestAnimationFrame(function () { requestAnimationFrame(function () { bd.classList.add('open'); }); });
    return modal;
  }

  /* Every openViewCertificate() call attaches fresh window-level drag
     listeners (below) for the new image — without tearing down the
     previous pair first, each certificate viewed in one session would
     leak another permanent 'mousemove'/'mouseup' listener on `window`
     (the stage/img-scoped listeners die naturally with their DOM nodes,
     but window itself never goes away). One module-level cleanup slot,
     invoked at the top of every new attach, keeps it to at most one. */
  var _zoomPanCleanup = null;

  /* ── Pan/zoom controller for the certificate image — pinch (touch),
     mouse-wheel (desktop), double-tap/double-click toggle, and drag-to-pan
     once zoomed in. No external library — this app has no bundler. ── */
  function _attachZoomPan(img, stage) {
    if (_zoomPanCleanup) { _zoomPanCleanup(); _zoomPanCleanup = null; }
    var scale = 1, tx = 0, ty = 0;
    var MIN = 1, MAX = 4;

    function clampPan() {
      if (!stage || !img.naturalWidth) return;
      var stageRect = stage.getBoundingClientRect();
      var w = img.clientWidth * scale, h = img.clientHeight * scale;
      var maxX = Math.max(0, (w - stageRect.width) / 2);
      var maxY = Math.max(0, (h - stageRect.height) / 2);
      tx = Math.max(-maxX, Math.min(maxX, tx));
      ty = Math.max(-maxY, Math.min(maxY, ty));
    }
    function render(withTransition) {
      img.style.transition = withTransition ? 'transform 0.22s ease' : 'none';
      img.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
      img.classList.toggle('cert-modal-img--zoomed', scale > 1.01);
    }
    function setScale(next, withTransition) {
      scale = Math.max(MIN, Math.min(MAX, next));
      if (scale === MIN) { tx = 0; ty = 0; }
      clampPan();
      render(withTransition);
    }

    /* Desktop: mouse-wheel zoom */
    stage.addEventListener('wheel', function (e) {
      e.preventDefault();
      setScale(scale - e.deltaY * 0.0016, false);
    }, { passive: false });

    /* Double-click (desktop) / double-tap (mobile) toggle */
    var lastTap = 0;
    function toggleZoom() {
      setScale(scale > 1.01 ? 1 : 2.5, true);
    }
    img.addEventListener('dblclick', function (e) { e.preventDefault(); toggleZoom(); });
    img.addEventListener('touchend', function () {
      var now = Date.now();
      if (now - lastTap < 320) toggleZoom();
      lastTap = now;
    });

    /* Pinch-to-zoom + single-finger pan (touch) */
    var pinchStartDist = 0, pinchStartScale = 1;
    var panStartX = 0, panStartY = 0, panOriginX = 0, panOriginY = 0, isPanning = false;
    function touchDist(t) {
      var dx = t[0].clientX - t[1].clientX, dy = t[0].clientY - t[1].clientY;
      return Math.sqrt(dx * dx + dy * dy);
    }
    stage.addEventListener('touchstart', function (e) {
      if (e.touches.length === 2) {
        pinchStartDist = touchDist(e.touches);
        pinchStartScale = scale;
        isPanning = false;
      } else if (e.touches.length === 1 && scale > 1.01) {
        isPanning = true;
        panStartX = e.touches[0].clientX; panStartY = e.touches[0].clientY;
        panOriginX = tx; panOriginY = ty;
      }
    }, { passive: true });
    stage.addEventListener('touchmove', function (e) {
      if (e.touches.length === 2 && pinchStartDist) {
        e.preventDefault();
        setScale(pinchStartScale * (touchDist(e.touches) / pinchStartDist), false);
      } else if (isPanning && e.touches.length === 1) {
        e.preventDefault();
        tx = panOriginX + (e.touches[0].clientX - panStartX);
        ty = panOriginY + (e.touches[0].clientY - panStartY);
        clampPan();
        render(false);
      }
    }, { passive: false });
    stage.addEventListener('touchend', function (e) {
      if (e.touches.length === 0) { pinchStartDist = 0; isPanning = false; }
    });

    /* Desktop: drag-to-pan once zoomed in */
    var mouseDown = false;
    img.addEventListener('mousedown', function (e) {
      if (scale <= 1.01) return;
      e.preventDefault();
      mouseDown = true;
      panStartX = e.clientX; panStartY = e.clientY;
      panOriginX = tx; panOriginY = ty;
      img.style.cursor = 'grabbing';
    });
    function onMouseMove(e) {
      if (!mouseDown) return;
      tx = panOriginX + (e.clientX - panStartX);
      ty = panOriginY + (e.clientY - panStartY);
      clampPan();
      render(false);
    }
    function onMouseUp() {
      mouseDown = false;
      img.style.cursor = scale > 1.01 ? 'grab' : 'zoom-in';
    }
    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('mouseup', onMouseUp);
    _zoomPanCleanup = function () {
      window.removeEventListener('mousemove', onMouseMove);
      window.removeEventListener('mouseup', onMouseUp);
    };

    render(false);
  }

  /* "View Certificate" — a professional, LinkedIn/Practo-style viewer:
     always-visible close button, loading spinner, error state with retry,
     pinch/wheel/double-tap zoom, drag-to-pan, and full-screen. No download
     — certificates are viewable, not exportable, by product decision. */
  function openViewCertificate(cert) {
    var isPdf = (cert.fileType || '').indexOf('pdf') !== -1 || /\.pdf($|\?)/i.test(cert.certificateUrl || '');
    console.log('[CERT VIEW] certId=' + (cert.certId || '(none)') +
                ' firestorePath=' + (cert.certId ? 'expert_certificates/' + cert.certId : '(unknown)') +
                ' url=' + (cert.certificateUrl || '(missing)') +
                ' storageProvider=' + (cert.storageProvider || '(unknown — likely a pre-migration /uploads/ record)'));

    var modal = openModalHtml(
      '<div class="cert-viewer">' +
        '<div class="cert-viewer-header">' +
          '<div class="cert-viewer-titles">' +
            '<p class="cert-modal-title">📄 ' + esc(cert.certificateName || 'Certificate') + '</p>' +
            '<p class="cert-modal-sub">' + esc(cert.issuingOrganization || '') + '</p>' +
          '</div>' +
          '<button class="cert-viewer-close" id="certViewerCloseBtn" aria-label="Close">' +
            '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>' +
          '</button>' +
        '</div>' +
        '<div class="cert-viewer-stage" id="certViewerStage">' +
          (isPdf
            ? '<div class="cert-viewer-pdf">' +
                '<span class="cert-viewer-pdf-icon">📄</span>' +
                '<p class="cert-modal-sub">This certificate was uploaded as a PDF and can\'t be previewed inline.</p>' +
                '<a class="cert-viewer-action cert-viewer-action--primary" href="' + esc(cert.certificateUrl) + '" target="_blank" rel="noopener">Open PDF in New Tab</a>' +
              '</div>'
            : '<div class="cert-viewer-loading" id="certViewerLoading"><span class="cert-spinner cert-spinner--lg"></span><span>Loading certificate...</span></div>' +
              '<div class="cert-viewer-error" id="certViewerError" style="display:none">' +
                '<span class="cert-viewer-error-icon">⚠️</span>' +
                '<p id="certViewerErrorText">Certificate unavailable.</p>' +
                '<button class="cert-viewer-action" id="certViewerRetryBtn">Try Again</button>' +
              '</div>' +
              '<img class="cert-modal-img" id="certViewerImg" alt="Certificate" draggable="false" style="opacity:0">'
          ) +
        '</div>' +
        '<div class="cert-viewer-footer">' +
          (isPdf ? '' : '<button class="cert-viewer-action cert-viewer-action--primary" id="certFullscreenBtn">⤢ View Full Screen</button>') +
        '</div>' +
      '</div>'
    );
    modal.classList.add('cert-modal--viewer');

    document.getElementById('certViewerCloseBtn').addEventListener('click', closeModal);
    var fsBtn = document.getElementById('certFullscreenBtn');
    if (fsBtn) fsBtn.addEventListener('click', function () {
      var isFs = modal.classList.toggle('cert-modal--fullscreen');
      var bd = document.getElementById('certModalBackdrop');
      if (bd) bd.classList.toggle('cert-modal-backdrop--fullscreen', isFs);
      fsBtn.innerHTML = isFs ? '⤡ Exit Full Screen' : '⤢ View Full Screen';
    });

    if (isPdf) return; // no image stage to wire up

    var imgEl      = document.getElementById('certViewerImg');
    var loadingEl  = document.getElementById('certViewerLoading');
    var errorEl    = document.getElementById('certViewerError');
    var errorTextEl = document.getElementById('certViewerErrorText');
    var stageEl    = document.getElementById('certViewerStage');

    function showError(reason) {
      loadingEl.style.display = 'none';
      errorEl.style.display = 'flex';
      errorTextEl.textContent = 'Certificate unavailable.';
      console.error('[CERT VIEW] failed to load — url=' + (cert.certificateUrl || '(missing)') + ' reason=' + reason);
    }

    function loadImage(bust) {
      loadingEl.style.display = 'flex';
      errorEl.style.display = 'none';
      imgEl.style.opacity = '0';

      if (!cert.certificateUrl) { showError('no certificateUrl on this record'); return; }

      /* STEP 3: validate the URL exists BEFORE trying to render it, and
         log the exact HTTP status — a bare <img onerror> can't tell us
         WHY it failed (404 vs CORS vs network), which this fetch does. */
      var checkUrl = bust
        ? cert.certificateUrl + (cert.certificateUrl.indexOf('?') === -1 ? '?' : '&') + '_r=' + Date.now()
        : cert.certificateUrl;
      fetch(checkUrl, { method: 'GET', cache: bust ? 'no-store' : 'default' })
        .then(function (r) {
          console.log('[CERT VIEW] existence check -> status=' + r.status + ' url=' + checkUrl);
          if (!r.ok) { showError('HTTP ' + r.status); return; }
          imgEl.onload = function () {
            loadingEl.style.display = 'none';
            imgEl.style.opacity = '1';
            imgEl.style.cursor = 'zoom-in';
            _attachZoomPan(imgEl, stageEl);
          };
          imgEl.onerror = function () { showError('image decode failed after a 200 response'); };
          imgEl.src = checkUrl;
        })
        .catch(function (e) { showError('fetch threw: ' + e.message); });
    }
    var retryBtn = document.getElementById('certViewerRetryBtn');
    if (retryBtn) retryBtn.addEventListener('click', function () { loadImage(true); });
    loadImage(false);
  }

  /* "ZITLAS Verification" — tapped from the Verified Expert badge */
  function openVerificationInfo(expertName, cert) {
    if (!cert) {
      openModalHtml(
        '<p class="cert-modal-title">🛡️ ZITLAS Verification</p>' +
        '<p class="cert-modal-sub">' + esc(expertName || 'This expert') + ' has not been verified yet.</p>' +
        '<button class="cert-modal-close" id="certModalCloseBtn">Close</button>'
      );
      document.getElementById('certModalCloseBtn').addEventListener('click', closeModal);
      return;
    }
    function fmtDate(iso) {
      try { return new Date(iso).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }); }
      catch (_) { return iso || '—'; }
    }
    openModalHtml(
      '<p class="cert-modal-title">🛡️ ZITLAS Verification</p>' +
      '<p class="cert-modal-sub">' + esc(expertName || 'Expert') + '</p>' +
      '<div class="cert-verify-row"><span class="cert-verify-check">✓</span><span class="cert-verify-label">Identity Verified</span></div>' +
      '<div class="cert-verify-row"><span class="cert-verify-check">✓</span><span class="cert-verify-label">Certificate Verified</span></div>' +
      '<div class="cert-detail-row"><span>AI Verification Score</span><b><span class="cert-score-badge">' + esc(String(cert.verificationScore)) + '%</span></b></div>' +
      '<div class="cert-detail-row"><span>Issuing Organization</span><b>' + esc(cert.issuingOrganization || '—') + '</b></div>' +
      '<div class="cert-detail-row"><span>Verification Date</span><b>' + esc(fmtDate(cert.uploadedAt)) + '</b></div>' +
      '<div class="cert-detail-row"><span>Certificate Number</span><b>' + esc(cert.certificateNumber || '—') + '</b></div>' +
      '<div class="cert-detail-row"><span>Status</span><b style="color:#578A2C">✓ Verified</b></div>' +
      '<button class="cert-modal-close" id="certModalCloseBtn">Close</button>'
    );
    document.getElementById('certModalCloseBtn').addEventListener('click', closeModal);
  }

  win.ZitlasCertificates = {
    uploadAndVerify: uploadAndVerify,
    saveCertificate: saveCertificate,
    recomputeVerifiedFlag: recomputeVerifiedFlag,
    listenForExpertCertificates: listenForExpertCertificates,
    listenForPendingCertificates: listenForPendingCertificates,
    approveCertificate: approveCertificate,
    rejectCertificate: rejectCertificate,
    REJECT_REASONS: REJECT_REASONS,
    openViewCertificate: openViewCertificate,
    openVerificationInfo: openVerificationInfo,
    closeModal: closeModal,
    toast: toast,
    probeStorage: _probeStorageOnInit, // callable from the console for a fresh check any time
  };

  /* NOT run automatically any more. This is a DIAGNOSTIC: it fired a real
     Firebase Storage request on every page load that includes this script —
     one wasted round trip per page view, and the source of the Storage CORS
     error in the production console. It stays available on demand as
     ZitlasCertificates.probeStorage() for the next time it's needed. */
})(window);
