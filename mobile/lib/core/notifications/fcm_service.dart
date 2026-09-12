import 'dart:async';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../storage/device_identity.dart';
import '../storage/local_storage_service.dart';
import 'notification_payload.dart';

/// Whether ZITLAS may show notifications on this device.
enum PushPermissionState {
  /// Not checked yet in this session.
  unknown,

  /// Allowed, and this device is registered for push.
  granted,

  /// Not allowed, and never asked on this device — an in-app request will
  /// still show the system dialog.
  askable,

  /// Refused, or the ask was dismissed. The app may still try once, but only
  /// the system settings screen is guaranteed to turn notifications on.
  blocked,
}

/// The slice of Firebase Messaging that device registration depends on.
///
/// A seam, not an abstraction for its own sake: without it, the rules that
/// decide whether an expert is ever asked — and whether a device gets
/// registered at all — could only be checked on a physical phone.
abstract class PushMessaging {
  const PushMessaging();

  Future<AuthorizationStatus> permissionStatus();
  Future<AuthorizationStatus> requestPermission();

  /// iOS needs an APNs token before FCM will issue one.
  Future<void> prepareForToken();
  Future<String?> getToken();
  Stream<String> get onTokenRefresh;

  /// Opens this app's page in the system settings, where notifications are
  /// switched on once the OS will no longer ask.
  Future<void> openNotificationSettings();
}

/// [PushMessaging] backed by the real Firebase Messaging plugin.
class FirebasePushMessaging extends PushMessaging {
  const FirebasePushMessaging();

  FirebaseMessaging get _m => FirebaseMessaging.instance;

  @override
  Future<AuthorizationStatus> permissionStatus() async =>
      (await _m.getNotificationSettings()).authorizationStatus;

  @override
  Future<AuthorizationStatus> requestPermission() async =>
      (await _m.requestPermission(alert: true, badge: true, sound: true))
          .authorizationStatus;

  @override
  Future<void> prepareForToken() async {
    if (!kIsWeb && Platform.isIOS) await _m.getAPNSToken();
  }

  @override
  Future<String?> getToken() => _m.getToken();

  @override
  Stream<String> get onTokenRefresh => _m.onTokenRefresh;

  @override
  Future<void> openNotificationSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      debugPrint('[FCM] could not open system settings: $e');
    }
  }
}

/// FCM token management + foreground notification display.
///
/// TOKEN STORAGE — `device_tokens/{fcmToken}`, keyed BY THE TOKEN ITSELF.
/// That key choice is what makes account switching safe. A physical device has
/// exactly one FCM token, so the document can only ever name ONE owning uid:
/// when account B signs in on a device that was account A's, [initForUser]
/// OVERWRITES the same document with `uid: B`. The backend resolves a user's
/// devices with `device_tokens.where(uid == ...)`, so A's notifications can
/// never again be delivered to that device. A uid-keyed subcollection could
/// not guarantee this — A's stale copy would survive and keep receiving.
///
/// `users/{uid}.pushTokens` (the legacy array the website writes) is kept in
/// sync so a mixed web/mobile account keeps working; the backend reads both.
///
/// RENDERING — on Android, ZITLAS draws EVERY notification itself, in every
/// app state, through [render]. The backend sends Android a DATA-ONLY message
/// for exactly this reason (see push_service.send_to_token): a message with an
/// FCM `notification` block is drawn by the SDK whenever the app is not in the
/// foreground, and the app never sees it — so all of the styling here applied
/// only while the user was already looking at the app, and every notification
/// they actually read in the tray came out looking stock.
///
/// One renderer for foreground, background and terminated also means there is
/// no second display path to accidentally fire alongside the first, so
/// duplicate notifications are prevented structurally rather than by care.
///
/// Web and iOS still receive an FCM `notification` block: the website's
/// service worker reads `payload.notification`, and iOS has no equivalent
/// background rendering hook.
class FcmService {
  FcmService({
    FirebaseFirestore? firestore,
    FlutterLocalNotificationsPlugin? plugin,
    PushMessaging? messaging,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _messaging = messaging ?? const FirebasePushMessaging();

  final FirebaseFirestore _db;
  final FlutterLocalNotificationsPlugin _plugin;
  final PushMessaging _messaging;

  static const _stateKey = 'zitlas_push_state'; // mirrors web's STATE_KEY
  static const _snoozeDays = 7;

  /// The ZITLAS notification tone, `res/raw/zitlas_tone.wav`.
  ///
  /// Named WITHOUT its extension because that is how both Android resource
  /// lookup and FCM's `android.notification.sound` field refer to it; the
  /// backend sends this exact string, so the two must not drift.
  ///
  /// Regenerate with `python tool/generate_notification_sound.py`.
  static const soundResource = 'zitlas_tone';

  /// Channel IDs — these MUST match `push_service.py`'s constants exactly.
  /// Android silently DROPS a notification whose channel does not exist on the
  /// device, so a mismatch here is an invisible delivery failure.
  ///
  /// WHY THEY ALL CARRY A VERSION SUFFIX. Android freezes a channel's
  /// importance AND its sound at the moment the channel is first created, and
  /// an app may never raise either afterwards — that restriction is the whole
  /// point of channels, so the user's own choices cannot be overridden. So
  /// giving these channels the ZITLAS tone is NOT a matter of editing them:
  /// every existing install would have kept the stock Android sound forever.
  /// A new id is the only mechanism there is. Existing installs pick up the
  /// new channels on next launch; the old ones stop being used and linger in
  /// system settings until the app is reinstalled, which is the unavoidable
  /// cost of the change.
  ///
  /// A user who has customised one of the old channels loses that
  /// customisation. That is why the id must NOT be bumped casually — only for
  /// a change that genuinely cannot be made any other way.
  static const channelMessages = 'zitlas_messages_v2';
  /// Was bumped to v2 once already, to raise importance from default to high
  /// (a coaching approval was not showing a heads-up banner). v3 adds the
  /// tone.
  static const channelCoaching = 'zitlas_coaching_v3';
  static const channelMealReviews = 'zitlas_meal_reviews_v2';
  static const channelPlans = 'zitlas_plans_v2';
  static const channelGeneral = 'zitlas_general_v2';

  /// Every channel plays [soundResource] and vibrates — one recognisable
  /// ZITLAS sound, the audible half of the app's identity. Both flags are
  /// explicit rather than implied so that turning either off later is a
  /// visible edit here, not an accident.
  ///
  /// Vibration matters as much as the sound: a phone is usually in a pocket or
  /// face-down, where a silent heads-up banner is simply never seen. Like
  /// importance and sound, it is frozen at channel creation — which is why
  /// adding it needed the version-suffixed ids above.
  static const _zitlasTone = RawResourceAndroidNotificationSound(soundResource);

  /// ZITLAS green — must equal `@color/zitlas_notification` in
  /// android/app/src/main/res/values/colors.xml, which the manifest hands to
  /// FCM for OS-drawn notifications. Both paths tint the same silhouette, so
  /// they have to agree or a foreground notification is a different colour
  /// from the same event backgrounded.
  static const _brandColor = Color(0xFF16A34A);

  static const _channels = <AndroidNotificationChannel>[
    AndroidNotificationChannel(
      channelMessages,
      'Messages',
      description: 'Chat messages from your coach or users.',
      importance: Importance.high,
      playSound: true,
      sound: _zitlasTone,
      enableVibration: true,
    ),
    AndroidNotificationChannel(
      channelCoaching,
      'Personal Coaching',
      description: 'Coaching requests, activation, payments and updates.',
      // HIGH so a coaching approval actually shows a heads-up banner. The
      // channel id had to change to make this land: Android caches a
      // channel's importance at creation, so editing the old channel would
      // have left every existing install silent.
      importance: Importance.high,
      playSound: true,
      sound: _zitlasTone,
      enableVibration: true,
    ),
    AndroidNotificationChannel(
      channelMealReviews,
      'Meal Reviews',
      description: 'Meal photos awaiting review, and your coach’s feedback.',
      importance: Importance.defaultImportance,
      playSound: true,
      sound: _zitlasTone,
      enableVibration: true,
    ),
    AndroidNotificationChannel(
      channelPlans,
      'Diet & Workout',
      description: 'Updates to your diet and training plans.',
      importance: Importance.defaultImportance,
      playSound: true,
      sound: _zitlasTone,
      enableVibration: true,
    ),
    AndroidNotificationChannel(
      channelGeneral,
      'General',
      description: 'Reminders, milestones and other ZITLAS updates.',
      importance: Importance.defaultImportance,
      playSound: true,
      sound: _zitlasTone,
      enableVibration: true,
    ),
  ];

  /// Non-empty string, or null. FCM data values arrive as strings, and an
  /// empty one must not beat a real fallback.
  static String? _str(Object? v) {
    final s = v?.toString().trim();
    return (s == null || s.isEmpty || s == 'null') ? null : s;
  }

  static String channelFor(String? type) {
    switch (type) {
      case 'chat_message':
        return channelMessages;
      case 'meal_review_pending':
      case 'meal_checkin':
      case 'meal_review_completed':
      case 'meal_reviewed':
        return channelMealReviews;
      case 'diet_updated':
      case 'workout_updated':
        return channelPlans;
      case 'zino_message':
        return channelGeneral;
      default:
        if (type != null &&
            (type.startsWith('coaching') || type.startsWith('payment'))) {
          return channelCoaching;
        }
        return channelGeneral;
    }
  }

  bool _localReady = false;

  /// `route()`'s `perm === 'default'` snooze gate (push-notifications.js:236),
  /// ported so the OS permission dialog isn't re-shown every app open.
  bool get _isSnoozed {
    final raw = LocalStorageService.instance.getString(_stateKey);
    if (raw == null) return false;
    try {
      final parts = raw.split('|'); // "status|epochMillis"
      if (parts.length != 2 || parts[0] != 'snoozed') return false;
      final ts = int.tryParse(parts[1]) ?? 0;
      return (DateTime.now().millisecondsSinceEpoch - ts) / 86400000 < _snoozeDays;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setState(String status) {
    return LocalStorageService.instance
        .setString(_stateKey, '$status|${DateTime.now().millisecondsSinceEpoch}');
  }

  /// Stable per-install id, so a device's registration is recognisable across
  /// token rotations (FCM tokens change; this does not).
  ///
  /// Shared with presence via [DeviceIdentity] — both subsystems must agree
  /// on what "this device" means.
  Future<String> _deviceId() => DeviceIdentity.get();

  /// Creates the Android channels and wires the local-notification tap
  /// handler. Safe to call repeatedly.
  /// Creates the ZITLAS channels on [p]. Safe to call repeatedly and from any
  /// isolate — `createNotificationChannel` is idempotent, and channels are
  /// app-wide rather than per-isolate.
  ///
  /// The background isolate MUST do this too: it is a cold Dart isolate that
  /// has never run `initLocalNotifications`, so without it the channel may
  /// not exist yet on a device whose first ever notification arrives while
  /// the app is terminated — and Android silently drops a notification
  /// posted to a channel that does not exist.
  static Future<void> _prepare(FlutterLocalNotificationsPlugin p) async {
    try {
      await p.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_zitlas'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      final android = p.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        for (final channel in _channels) {
          await android.createNotificationChannel(channel);
        }
      }
    } catch (e) {
      debugPrint('[ANDROID_NOTIFICATION] channel prepare failed: $e');
    }
  }

  Future<void> initLocalNotifications({
    void Function(NotificationPayload payload)? onTap,
  }) async {
    if (_localReady) return;
    _localReady = true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          // NOT the launcher icon. Android reduces a small icon to its alpha
          // channel and re-tints it; ic_launcher is a fully opaque square, so
          // it renders as a white blob. ic_stat_zitlas is authored alpha-only.
          android: AndroidInitializationSettings('ic_stat_zitlas'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (NotificationResponse r) {
          final payload = NotificationPayload.decode(r.payload);
          if (payload != null && onTap != null) onTap(payload);
        },
      );
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        for (final channel in _channels) {
          await android.createNotificationChannel(channel);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] local notifications init failed: $e');
    }
  }

  /// Draws a notification for a message that arrived while the app was in the
  /// FOREGROUND (which the OS does not draw itself).
  ///
  /// `suppress` lets the caller skip the tray entry when the user is already
  /// looking at exactly this conversation — the messaging-app behaviour of not
  /// notifying you about the screen you are reading.
  Future<void> showForeground(RemoteMessage message, {bool suppress = false}) async {
    if (suppress) {
      debugPrint('[ANDROID_NOTIFICATION] suppressed — user is on this screen');
      return;
    }
    await render(message, plugin: _plugin);
  }

  /// Draws [message] as a ZITLAS notification. THE one renderer.
  ///
  /// Called from three places, and it has to be the same code in all three or
  /// the same event looks like a different app depending on what the user was
  /// doing when it arrived:
  ///
  ///   * `onMessage`      — app in the foreground
  ///   * the BACKGROUND handler — app backgrounded or terminated
  ///   * (web/iOS keep FCM's own rendering; see push_service.send_to_token)
  ///
  /// Android now receives DATA-ONLY messages precisely so this runs in every
  /// state. Previously the backend sent a `notification` block, which the FCM
  /// SDK renders itself whenever the app is not in the foreground — the app
  /// never saw those, so none of the styling below applied in the two states
  /// where people actually read notifications. That is why they looked stock.
  ///
  /// `static` because the background isolate has no FcmService instance and
  /// cannot reach one: it is a separate Dart isolate with its own memory.
  static Future<void> render(
    RemoteMessage message, {
    FlutterLocalNotificationsPlugin? plugin,
  }) async {
    final notification = message.notification;
    final data = message.data.cast<String, dynamic>();
    final payload = NotificationPayload.fromData(data);

    // Title/body come from `data` on Android (there is no notification block
    // in a data-only message) and from the notification block on the
    // platforms that still get one.
    final title = _str(data['title']) ?? notification?.title ?? 'ZITLAS';
    final body = _str(data['body']) ?? notification?.body ?? '';
    debugPrint('[ANDROID_NOTIFICATION] render type=${payload.type} '
        'channel=${channelFor(payload.type)} hasImage=${data['imageUrl'] != null}');
    if (title.isEmpty && body.isEmpty) return;

    final p = plugin ?? FlutterLocalNotificationsPlugin();
    await _prepare(p);

    // The meal photo, when there is one. A meal-review notification showing
    // the actual plate is the difference between "you have a notification"
    // and something worth opening.
    //
    // Best effort on purpose: this runs in a background isolate on a phone
    // that may be on a bad connection, so it is capped tightly and ANY
    // failure falls through to the text-only notification rather than
    // costing the user the notification altogether.
    final imageFile = await _cacheImage(_str(data['imageUrl']));
    final channelId = channelFor(payload.type);
    final channel = _channels.firstWhere(
      (c) => c.id == channelId,
      orElse: () => _channels.last,
    );
    // ONE EVENT -> ONE NOTIFICATION.
    //
    // `notificationId` is minted per event by the backend
    // (notification_service.persist), so redelivering the SAME push — an FCM
    // retry, a reconnect, a rebuild that re-attaches the listener — reuses
    // the same tray id and replaces the entry instead of stacking a second
    // copy. Two DIFFERENT coaching events still get two ids and show
    // separately, which keying on `type` alone would have collapsed.
    //
    // Chat keeps its per-conversation grouping ahead of that: a thread should
    // show one live entry, not one per message.
    final id = (payload.chatId ??
            payload.mealId ??
            payload.notificationId ??
            payload.type)
        .hashCode &
        0x7fffffff;
    try {
      await p.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            importance: channel.importance,
            // On Android 8+ the CHANNEL's sound wins and this is ignored; it
            // matters on 7 and below, where there are no channels and the
            // per-notification sound is the only one there is.
            playSound: true,
            sound: _zitlasTone,
            enableVibration: true,
            // The OS reads these from the manifest for messages IT draws;
            // a locally-drawn one has to name them itself, or a foreground
            // notification looks different from a backgrounded one.
            icon: 'ic_stat_zitlas',
            color: _brandColor,
            // PUBLIC so the notification is readable on the lock screen —
            // the whole point of a heads-up alert is that it is seen without
            // unlocking. Safe here because the BODY is deliberately
            // non-sensitive: notification_templates.py keeps it to the meal
            // name, the coach's display name and their feedback. Nothing
            // medical, financial, or identifying goes in a body, and that is
            // the constraint that lets this stay public.
            visibility: NotificationVisibility.public,
            priority: payload.type == 'chat_message'
                ? Priority.high
                : Priority.defaultPriority,
            // The BODY, not ''. An empty BigTextStyleInformation marks the
            // notification expandable and then renders nothing when expanded
            // — which is how a coach's written feedback vanished at the exact
            // moment the user pulled the notification down to read it.
            // Collapsed, the photo sits on the right as the large icon;
            // expanded, it fills the notification. Falls back to expanded
            // text when there is no photo or the fetch failed.
            largeIcon:
                imageFile == null ? null : FilePathAndroidBitmap(imageFile),
            styleInformation: imageFile != null
                ? BigPictureStyleInformation(
                    FilePathAndroidBitmap(imageFile),
                    contentTitle: title,
                    summaryText: body,
                    htmlFormatContentTitle: false,
                    htmlFormatSummaryText: false,
                    // Keeps the thumbnail while collapsed and drops it once
                    // expanded, so the big picture is not shown twice.
                    hideExpandedLargeIcon: true,
                  )
                : BigTextStyleInformation(
                    body,
                    contentTitle: title,
                    htmlFormatBigText: false,
                    htmlFormatContentTitle: false,
                  ),
            // Same tag the backend sets, so a foreground-drawn notification and
            // an OS-drawn one for the same conversation collapse together.
            tag: payload.chatId ?? payload.mealId,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        payload: payload.encode(),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] foreground show failed: $e');
    }
  }

  /// Downloads [url] to a temp file for use as a notification image, or null.
  ///
  /// Returns null for ANY problem — no url, a non-image, a slow network, a
  /// dead link, no temp directory. A notification that fails to arrive
  /// because its picture would not load is far worse than a text one.
  static Future<String?> _cacheImage(String? url) async {
    if (url == null || !url.startsWith('https://')) return null;
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        debugPrint('[ANDROID_NOTIFICATION] image fetch status=${res.statusCode}');
        return null;
      }
      // Android rejects an oversized bitmap outright; a meal photo well past
      // this is not going to render usefully in a tray entry anyway.
      if (res.bodyBytes.length > 2 * 1024 * 1024) {
        debugPrint('[ANDROID_NOTIFICATION] image too large '
            '(${res.bodyBytes.length ~/ 1024}KB) — text only');
        return null;
      }
      final dir = await getTemporaryDirectory();
      // Named by the url hash so redelivery of the same event reuses the
      // file instead of filling the cache directory with copies.
      final file = File('${dir.path}/zitlas_notif_${url.hashCode & 0x7fffffff}.img');
      await file.writeAsBytes(res.bodyBytes);
      return file.path;
    } catch (e) {
      debugPrint('[ANDROID_NOTIFICATION] image unavailable, sending text only: $e');
      return null;
    }
  }

  /// Whether ZITLAS may show notifications on this device right now, so the
  /// UI can say so and offer the fix (see `PushPermissionBanner`).
  ///
  /// Static: the OS permission belongs to the DEVICE, not to an instance, and
  /// the banner that reads it has no instance of its own.
  static final ValueNotifier<PushPermissionState> permissionState =
      ValueNotifier<PushPermissionState>(PushPermissionState.unknown);

  /// The ONE token-rotation subscription in this process.
  ///
  /// `onTokenRefresh` is process-wide. Each sign-in used to attach another
  /// listener and none was ever removed, so after an account switch the
  /// PREVIOUS account's listener was still attached, trying to re-register
  /// the device under the account that had signed out.
  static StreamSubscription<String>? _rotationSub;

  /// Who a rotation registers for — read when the token rotates, not
  /// captured when the listener was attached, so it always names the account
  /// signed in NOW (null once signed out).
  static String? _rotationUid;

  /// The token this process has fully registered, and for whom. Lets
  /// [touchActive] tell "already registered" from "permission was only just
  /// granted and nobody has registered this device yet".
  static String? _registeredToken;
  static String? _registeredUid;

  static bool _granted(AuthorizationStatus s) =>
      s == AuthorizationStatus.authorized ||
      s == AuthorizationStatus.provisional;

  /// Whether this device has EVER put the question to its user — the stored
  /// state exists. Separates Android's never-asked `denied` from a refusal.
  bool get _askedBefore =>
      LocalStorageService.instance.getString(_stateKey) != null;

  PushPermissionState _blockedOrAskable() =>
      _askedBefore ? PushPermissionState.blocked : PushPermissionState.askable;

  /// Clears the process-wide registration state between tests.
  @visibleForTesting
  static Future<void> resetForTest() async {
    await _rotationSub?.cancel();
    _rotationSub = null;
    _rotationUid = null;
    _registeredToken = null;
    _registeredUid = null;
    permissionState.value = PushPermissionState.unknown;
  }

  /// Called once per app session after authentication resolves — NOT at
  /// splash. Registers this device for [uid] when notifications are allowed,
  /// and otherwise records why not in [permissionState].
  ///
  /// [promptIfNeeded] asks even though the OS reports `denied`, and exists
  /// for EXPERTS. On Android, firebase_messaging reports a device that has
  /// never been asked for POST_NOTIFICATIONS as `denied` — Android has no
  /// "not determined" (FlutterFirebaseMessagingPlugin.getPermissions maps
  /// "not granted" to 0). The rule used to be "denied → stop", and the only
  /// other place that asks is the consent sheet in the ATHLETE shell, which
  /// an expert never enters. So an expert on Android 13+ was never asked and
  /// never registered: production held zero expert devices. Athletes keep
  /// the consent sheet as their prompt and pass false — unchanged.
  ///
  /// Silently no-ops while snoozed this week, and a permanently refused
  /// request just comes back `denied` without showing a dialog.
  Future<void> initForUser(String uid, {bool promptIfNeeded = false}) async {
    await initLocalNotifications();

    var status = await _messaging.permissionStatus();
    if (!_granted(status) && !_isSnoozed) {
      final mayAsk = status == AuthorizationStatus.notDetermined ||
          (promptIfNeeded &&
              status == AuthorizationStatus.denied &&
              !_askedBefore);
      if (mayAsk) {
        status = await _messaging.requestPermission();
        if (!_granted(status)) await _setState('snoozed');
      }
    }
    if (!_granted(status)) {
      permissionState.value = _blockedOrAskable();
      debugPrint('[FCM] notifications not allowed for $uid '
          '(${permissionState.value.name}) — device not registered');
      return;
    }
    await _setState('granted');
    permissionState.value = PushPermissionState.granted;
    await _registerToken(uid);
    _watchRotation(uid);
  }

  /// Attaches the single rotation listener, or just repoints it at [uid].
  void _watchRotation(String uid) {
    _rotationUid = uid;
    _rotationSub ??= _messaging.onTokenRefresh.listen((token) {
      final current = _rotationUid;
      if (current == null) return; // signed out — nobody to register for
      // A rotated token is a NEW document. The comment here used to claim the
      // old one was removed — it was not. `_storeToken` only ever wrote the
      // new row, so every rotation left the previous token behind with
      // `enabled: true`, and it stayed in `users/{uid}.pushTokens` forever.
      // That is how one phone accumulated three "active" tokens and why a
      // send reported tokens=3 for a user with one device.
      _rotateToken(current, token).catchError((Object e) {
        debugPrint('[FCM] token refresh failed: $e');
      });
    });
  }

  /// The token FCM last issued us, so a rotation knows what it replaced.
  ///
  /// `onTokenRefresh` hands over only the NEW token; the old one is not
  /// recoverable from the SDK afterwards, so it has to be remembered here.
  static const _lastTokenKey = 'zitlas_fcm_last_token';

  /// Replaces [uid]'s previous token with [token], retiring the old row.
  ///
  /// Retiring rather than deleting, for the same reason logout tombstones:
  /// the backend treats a token with no registry row as an unverifiable
  /// device, so a deleted row is weaker than one that says `enabled: false`.
  Future<void> _rotateToken(String uid, String token) async {
    final previous = LocalStorageService.instance.getString(_lastTokenKey);
    await _storeToken(uid, token);
    if (previous == null || previous.isEmpty || previous == token) return;
    try {
      await _db.collection('device_tokens').doc(previous).set({
        'fcmToken': previous,
        'uid': uid,
        'enabled': false,
        'retiredAt': DateTime.now().toIso8601String(),
        'retiredFor': _short(token),
      }, SetOptions(merge: true));
      await _db.collection('users').doc(uid).set({
        'pushTokens': FieldValue.arrayRemove([previous]),
      }, SetOptions(merge: true));
      debugPrint('[FCM] token rotated for $uid: ${_short(previous)} retired, '
          '${_short(token)} active');
    } catch (e) {
      // Non-fatal: the new token is already registered, so push works. The
      // stale row is inert (the backend prunes on UNREGISTERED) and the next
      // rotation tries again.
      debugPrint('[FCM] retiring old token failed (non-fatal): $e');
    }
  }

  /// Runs every time the app returns to the foreground.
  ///
  /// Two jobs. It keeps `lastActiveAt` current on this device's registry row,
  /// and it notices notifications being ALLOWED after [initForUser] already
  /// ran — switched on in system settings, or granted through the athlete
  /// consent sheet — and registers the device then, instead of at the next
  /// cold start.
  ///
  /// It no longer marks a device `enabled: true` when it cannot show
  /// notifications. It used to, on every foreground, which created
  /// half-registered rows (no platform, no capability flag) for devices whose
  /// owner had refused permission — the backend then counted pushes to them
  /// as sent while nothing ever appeared.
  Future<void> touchActive(String uid) async {
    try {
      final status = await _messaging.permissionStatus();
      if (!_granted(status)) {
        permissionState.value = _blockedOrAskable();
        return;
      }
      permissionState.value = PushPermissionState.granted;
      final token = await _messaging.getToken();
      if (token == null) return;
      if (token != _registeredToken || uid != _registeredUid) {
        await _setState('granted');
        await _storeToken(uid, token);
        _watchRotation(uid);
        return;
      }
      await _db.collection('device_tokens').doc(token).set({
        'fcmToken': token,
        'uid': uid,
        'enabled': true,
        'lastActiveAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[FCM] foreground touch failed (non-fatal): $e');
    }
  }

  /// "Turn on notifications" — for the banner on the expert dashboard, or any
  /// other surface explaining why nothing is arriving.
  ///
  /// Asks in-app first: iOS shows its dialog once, and Android 13+ shows it
  /// again unless the user has refused twice. When the OS will not ask, this
  /// opens the app's system settings — the only place the switch can then be
  /// flipped — and the next [touchActive], on return to the app, registers
  /// the device.
  Future<PushPermissionState> enableFromSettings(String uid) async {
    final status = await _messaging.requestPermission();
    if (_granted(status)) {
      await _setState('granted');
      permissionState.value = PushPermissionState.granted;
      await _registerToken(uid);
      _watchRotation(uid);
      return PushPermissionState.granted;
    }
    await _setState('snoozed');
    permissionState.value = PushPermissionState.blocked;
    await _messaging.openNotificationSettings();
    return PushPermissionState.blocked;
  }

  Future<void> _registerToken(String uid) async {
    try {
      // On iOS the APNs token must exist before an FCM token can be issued;
      // without this the first getToken() after a fresh install can return
      // null and the device would silently never register.
      await _messaging.prepareForToken();
      final token = await _messaging.getToken();
      if (token == null) {
        debugPrint('[FCM] no token issued — device not registered');
        return;
      }
      await _storeToken(uid, token);
    } catch (e) {
      debugPrint('[FCM] token registration failed: $e');
    }
  }

  Future<void> _storeToken(String uid, String token) async {
    // Logged on RELEASE builds too. Push failures get reported from real
    // phones running release APKs, and a debug-only line is invisible exactly
    // when it is needed. Only a token PREFIX is ever printed.
    debugPrint('[FCM] registering device for $uid (token ${_short(token)})');
    final platform = kIsWeb
        ? 'web'
        : Platform.isAndroid
            ? 'android'
            : Platform.isIOS
                ? 'ios'
                : 'other';
    final deviceId = await _deviceId();

    // Keyed by token — see the class doc. A .set() (not merge) so a device that
    // used to belong to another account is fully re-owned, with no leftover
    // fields from the previous owner.
    final now = DateTime.now().toIso8601String();
    await _db.collection('device_tokens').doc(token).set({
      'fcmToken': token,
      'uid': uid,
      'platform': platform,
      'deviceId': deviceId,
      'enabled': true,
      'updatedAt': now,
      // When this device was last known to be signed in and running, kept
      // current by [touchActive] on every foreground. A row whose
      // lastActiveAt is ancient is a phone that was wiped, uninstalled or
      // simply abandoned; the token is usually dead, but FCM does not always
      // say so, and without a timestamp that is indistinguishable from a
      // device which is merely quiet.
      'lastActiveAt': now,
      // CAPABILITY FLAG — the migration lever for data-only messages.
      //
      // The backend sends Android a data-only message so this app can render
      // it (see push_service.send_to_token). A build that predates
      // FcmService.render CANNOT render one: its background handler only
      // logs, so a data-only message produces NO notification at all. Since a
      // backend deploy does not upgrade anyone's phone, sending data-only to
      // every Android device would silence every user who has not updated.
      //
      // So the DEVICE declares what it can do, and the backend keeps sending
      // the old `notification` block to anything that does not claim this.
      // Old installs keep working exactly as they do today, this build gets
      // the branded notification, and backend and app can ship in either
      // order. Remove this only once no un-upgraded installs remain.
      'rendersOwnNotifications': true,
      // `loggedIn` is the session fact; `enabled` is the delivery switch.
      // They are the same today, but a user muting ZITLAS in Settings must
      // be able to clear `enabled` WITHOUT the backend concluding they
      // signed out, so the two are recorded separately from the start.
      'loggedIn': true,
      // NO merge — see above. That is also what clears a `signedOutAt`
      // tombstone left by the previous sign-out on this device: the whole
      // document is replaced, so signing back in cannot leave a stale
      // "signed out" marker sitting beside `enabled: true`.
    });

    // Remembered so `onTokenRefresh` can retire this token when FCM rotates
    // it — the SDK hands over only the new value at that point.
    await LocalStorageService.instance.setString(_lastTokenKey, token);
    _registeredToken = token;
    _registeredUid = uid;

    // Legacy array the website also writes; the backend reads both.
    await _db.collection('users').doc(uid).set({
      'pushTokens': FieldValue.arrayUnion([token]),
      'pushTokensUpdatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  /// Detaches THIS device from `uid` at logout.
  ///
  /// Without this the previous account keeps a live token for a phone somebody
  /// else is now using, and the backend would keep delivering their
  /// notifications there.
  ///
  /// WHY A TOMBSTONE AND NOT A DELETE. This used to `delete()` the row. But
  /// `users/{uid}.pushTokens` — the legacy array the website also writes — can
  /// still list the token afterwards (the arrayRemove below is a separate
  /// write that can fail, and the website appends to it independently). The
  /// backend treats a token with NO registry row as an unverifiable
  /// website-only device and still delivers to it, so deleting the row turned
  /// a signed-out phone back into a valid target. Writing `enabled: false`
  /// instead leaves a POSITIVE record that this device is signed out, which
  /// the backend already honours — logout becomes something the registry can
  /// state, rather than something it merely fails to mention.
  ///
  /// Nothing is leaked by keeping the row: it holds a token and a uid this
  /// device already had, and the next login `.set()`s it outright, so a new
  /// owner still starts from a clean document.
  ///
  /// Best-effort by design: it runs during sign-out, so a failure here must
  /// never block logout. The token is ALSO re-owned on the next login, so a
  /// missed cleanup self-corrects the moment anyone signs in again.
  Future<void> unregisterDevice(String uid) async {
    // Stop re-registering this device for the account that is leaving — see
    // [_rotationSub]. Cleared first, so a rotation racing the sign-out cannot
    // resurrect the session being ended.
    _rotationUid = null;
    await _rotationSub?.cancel();
    _rotationSub = null;
    _registeredToken = null;
    _registeredUid = null;
    permissionState.value = PushPermissionState.unknown;
    try {
      final token = await _messaging.getToken();
      if (token == null) {
        debugPrint('[FCM] unregister skipped: no token on this device');
        return;
      }
      // uid + fcmToken are restated because the security rule validates the
      // POST-merge document; a merge that omitted them would pass only by
      // accident of what happens to be stored already.
      await _db.collection('device_tokens').doc(token).set({
        'fcmToken': token,
        'uid': uid,
        'enabled': false,
        'loggedIn': false,
        'signedOutAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));
      await _db.collection('users').doc(uid).set({
        'pushTokens': FieldValue.arrayRemove([token]),
      }, SetOptions(merge: true));
      debugPrint('[FCM] user logout uid=$uid token=${_short(token)}');
      debugPrint('[FCM] notification session disabled');
    } catch (e) {
      debugPrint('[FCM] unregister failed (non-fatal): $e');
    }
  }

  /// First 12 characters of a token — enough to correlate two log lines, never
  /// enough to send with. A full FCM token is a credential: anyone holding it
  /// can push to that device, so it must not reach a log.
  static String _short(String token) =>
      token.length <= 12 ? token : '${token.substring(0, 12)}…';
}
