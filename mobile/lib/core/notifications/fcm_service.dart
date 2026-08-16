import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../storage/device_identity.dart';
import '../storage/local_storage_service.dart';
import 'notification_payload.dart';

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
/// FOREGROUND DISPLAY — Android does NOT draw a notification tray entry for a
/// message that arrives while the app is in the foreground; FCM hands it to
/// `onMessage` instead. So [showForeground] re-publishes it through
/// flutter_local_notifications, which is what makes an in-app arrival look the
/// same as a backgrounded one. Background/closed delivery is drawn by the OS
/// from the `notification` block the backend sends — no Dart involved.
class FcmService {
  FcmService({
    FirebaseFirestore? firestore,
    FlutterLocalNotificationsPlugin? plugin,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FirebaseFirestore _db;
  final FlutterLocalNotificationsPlugin _plugin;

  static const _stateKey = 'zitlas_push_state'; // mirrors web's STATE_KEY
  static const _snoozeDays = 7;

  /// Channel IDs — these MUST match `push_service.py`'s constants exactly.
  /// Android silently DROPS a notification whose channel does not exist on the
  /// device, so a mismatch here is an invisible delivery failure.
  static const channelMessages = 'zitlas_messages';
  static const channelCoaching = 'zitlas_coaching';
  static const channelMealReviews = 'zitlas_meal_reviews';
  static const channelPlans = 'zitlas_plans';
  static const channelGeneral = 'zitlas_general';

  static const _channels = <AndroidNotificationChannel>[
    AndroidNotificationChannel(
      channelMessages,
      'Messages',
      description: 'Chat messages from your coach or athletes.',
      importance: Importance.high,
    ),
    AndroidNotificationChannel(
      channelCoaching,
      'Personal Coaching',
      description: 'Coaching requests, activation, payments and updates.',
      importance: Importance.defaultImportance,
    ),
    AndroidNotificationChannel(
      channelMealReviews,
      'Meal Reviews',
      description: 'Meal photos awaiting review, and your coach’s feedback.',
      importance: Importance.defaultImportance,
    ),
    AndroidNotificationChannel(
      channelPlans,
      'Diet & Workout',
      description: 'Updates to your diet and training plans.',
      importance: Importance.defaultImportance,
    ),
    AndroidNotificationChannel(
      channelGeneral,
      'General',
      description: 'Reminders, milestones and other ZITLAS updates.',
      importance: Importance.defaultImportance,
    ),
  ];

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
  Future<void> initLocalNotifications({
    void Function(NotificationPayload payload)? onTap,
  }) async {
    if (_localReady) return;
    _localReady = true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
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
      if (kDebugMode) debugPrint('[FCM] foreground notification suppressed (user is on this screen)');
      return;
    }
    final notification = message.notification;
    final data = message.data.cast<String, dynamic>();
    final payload = NotificationPayload.fromData(data);
    final title = notification?.title ?? 'ZITLAS';
    final body = notification?.body ?? '';
    if (title.isEmpty && body.isEmpty) return;

    await initLocalNotifications();
    final channelId = channelFor(payload.type);
    final channel = _channels.firstWhere(
      (c) => c.id == channelId,
      orElse: () => _channels.last,
    );
    // Stable per-conversation id so repeated messages from the same chat
    // REPLACE each other (grouped) instead of stacking N separate entries.
    final id = (payload.chatId ?? payload.mealId ?? payload.type).hashCode & 0x7fffffff;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            importance: channel.importance,
            priority: payload.type == 'chat_message'
                ? Priority.high
                : Priority.defaultPriority,
            styleInformation: const BigTextStyleInformation(''),
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

  /// Called once per app session after authentication resolves — NOT at
  /// splash. Silently no-ops if snoozed this week; never re-prompts once
  /// permanently denied.
  Future<void> initForUser(String uid) async {
    await initLocalNotifications();

    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    if (settings.authorizationStatus == AuthorizationStatus.denied && !kIsWeb) {
      // Already explicitly denied previously — Android won't re-show its own
      // dialog either way; nothing to do but stay usable.
      return;
    }
    if (settings.authorizationStatus == AuthorizationStatus.notDetermined) {
      if (_isSnoozed) return;
      final result = await FirebaseMessaging.instance
          .requestPermission(alert: true, badge: true, sound: true);
      if (result.authorizationStatus != AuthorizationStatus.authorized &&
          result.authorizationStatus != AuthorizationStatus.provisional) {
        await _setState('snoozed');
        return;
      }
    }
    await _setState('granted');
    await _registerToken(uid);
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      // A rotated token is a NEW document; the old one is removed so the
      // backend never keeps sending to a token FCM has retired.
      _storeToken(uid, token).catchError((Object e) {
        if (kDebugMode) debugPrint('[FCM] token refresh store failed: $e');
      });
    });
  }

  /// Enables notifications from ZITLAS Settings after an earlier decline —
  /// returns whether they are now permitted.
  Future<bool> enableFromSettings(String uid) async {
    final result = await FirebaseMessaging.instance
        .requestPermission(alert: true, badge: true, sound: true);
    final ok = result.authorizationStatus == AuthorizationStatus.authorized ||
        result.authorizationStatus == AuthorizationStatus.provisional;
    if (ok) {
      await _setState('granted');
      await _registerToken(uid);
    }
    return ok;
  }

  Future<void> _registerToken(String uid) async {
    try {
      // On iOS the APNs token must exist before an FCM token can be issued;
      // without this the first getToken() after a fresh install can return
      // null and the device would silently never register.
      if (!kIsWeb && Platform.isIOS) {
        await FirebaseMessaging.instance.getAPNSToken();
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await _storeToken(uid, token);
    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] token registration failed: $e');
    }
  }

  Future<void> _storeToken(String uid, String token) async {
    if (kDebugMode) {
      debugPrint('[FCM] registering device for $uid: '
          '${token.substring(0, token.length.clamp(0, 24))}…');
    }
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
    await _db.collection('device_tokens').doc(token).set({
      'fcmToken': token,
      'uid': uid,
      'platform': platform,
      'deviceId': deviceId,
      'enabled': true,
      'updatedAt': DateTime.now().toIso8601String(),
    });

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
  /// notifications there. Deleting the `device_tokens` doc (rather than just
  /// flipping `enabled`) also guarantees the next account's registration
  /// starts from a clean document.
  ///
  /// Best-effort by design: it runs during sign-out, so a failure here must
  /// never block logout. The token is ALSO re-owned on the next login, so a
  /// missed cleanup self-corrects the moment anyone signs in again.
  Future<void> unregisterDevice(String uid) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await _db.collection('device_tokens').doc(token).delete();
      await _db.collection('users').doc(uid).set({
        'pushTokens': FieldValue.arrayRemove([token]),
      }, SetOptions(merge: true));
      if (kDebugMode) debugPrint('[FCM] device unregistered from $uid');
    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] unregister failed (non-fatal): $e');
    }
  }
}
