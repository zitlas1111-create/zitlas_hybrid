/*!
 * ZITLAS — Firebase Cloud Messaging service worker (firebase-messaging-sw.js)
 *
 * MUST live at the site root (frontend/ is mounted at "/" by FastAPI), so
 * its scope covers every page. Registered by assets/js/push-notifications.js.
 *
 * Handles PUSH MESSAGES WHILE NO ZITLAS TAB IS FOCUSED (background/closed):
 * shows a system notification and, on tap, focuses an existing ZITLAS tab
 * or opens the dashboard. Foreground messages are handled in-page by
 * push-notifications.js's onMessage instead — the SW never double-notifies
 * because FCM only routes to onBackgroundMessage when no client has focus.
 */

/* Same SDK version the pages use (firebase-*-compat 10.7.1) */
importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-messaging-compat.js');

/* Keep in sync with assets/js/firebase-config.js (a SW cannot importScripts
   that file because it references `window`). */
firebase.initializeApp({
  apiKey:            'AIzaSyAR4Q0Ldur2Y2N8iHwsAmPS4V2cWCvf_pg',
  authDomain:        'zitlas-b8677.firebaseapp.com',
  projectId:         'zitlas-b8677',
  storageBucket:     'zitlas-b8677.firebasestorage.app',
  messagingSenderId: '203730393646',
  appId:             '1:203730393646:web:f1f4776d8b0d1134bf1dbf',
});

var messaging = firebase.messaging();

/* One browser notification per EVENT. MUST equal web_tag() in
   backend/services/push_service.py — which sets this same tag on the webpush
   notification — and zitlasTag() in assets/js/push-notifications.js.

   A notification message is displayed by the FCM SDK itself AND passed to
   the handler below. With identical tags the browser REPLACES the first with
   the second rather than stacking a duplicate; a tag per event (instead of
   one per category) also keeps two different events from overwriting each
   other. Chat groups per conversation and re-alerts on each new message. */
function zitlasTag(data) {
  data = data || {};
  if (data.chatId) return 'zitlas-chat-' + data.chatId;
  var key = data.eventId || data.notificationId;
  return 'zitlas-' + (key || data.type || data.category || 'general');
}

messaging.onBackgroundMessage(function (payload) {
  var n     = payload.notification || {};
  var data  = payload.data || {};
  var title = n.title || data.title || 'ZITLAS';
  var body  = n.body  || data.body || data.message || '';

  self.registration.showNotification(title, {
    body: body,
    icon: '/assets/zino.png',
    badge: '/assets/zino.png',
    tag: zitlasTag(data),
    renotify: !!data.chatId,
    data: { url: data.url || '/pages/notifications/notifications.html' },
  });
});

/* Tap -> focus an open ZITLAS tab (and navigate it) or open a new one */
self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  var url = (event.notification.data && event.notification.data.url) || '/pages/dashboard/dashboard.html';
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
      for (var i = 0; i < list.length; i++) {
        if ('focus' in list[i]) {
          list[i].navigate(url).catch(function () {});
          return list[i].focus();
        }
      }
      if (clients.openWindow) return clients.openWindow(url);
    })
  );
});
