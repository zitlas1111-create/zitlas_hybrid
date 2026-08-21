import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/notifications/fcm_service.dart';
import '../core/notifications/notification_audience.dart';
import '../core/notifications/notification_payload.dart';
import '../core/notifications/notification_router.dart';
import '../core/notifications/notification_preferences.dart';
import '../core/notifications/zino_notification_scheduler.dart';
import '../core/presence/presence_service.dart';
import '../features/auth/auth_state.dart';
import '../features/auth/data/auth_repository.dart';
import 'router.dart';
import 'splash_gate.dart';
import 'theme.dart';

class ZitlasApp extends StatelessWidget {
  const ZitlasApp({super.key, required this.firebaseReady});

  /// Whether `Firebase.initializeApp()` succeeded in `main.dart`. False
  /// until the Android/iOS Firebase apps are registered and
  /// google-services.json/GoogleService-Info.plist are in place — see
  /// docs/MIGRATION_INVENTORY.md §4. [AuthRepository] degrades gracefully
  /// when this is false rather than crashing.
  final bool firebaseReady;

  @override
  Widget build(BuildContext context) {
    final repository = AuthRepository(
      auth: firebaseReady ? FirebaseAuth.instance : null,
      firestore: firebaseReady ? FirebaseFirestore.instance : null,
    );

    return ChangeNotifierProvider(
      create: (_) => AuthState(repository),
      child: Consumer<AuthState>(
        builder: (context, authState, _) {
          if (firebaseReady) {
            _FcmBootstrap.maybeInit(authState);
            _PresenceBootstrap.sync(authState);
          }
          // Role-gated, so it runs with or without Firebase.
          _ReminderBootstrap.sync(authState);
          return MaterialApp.router(
            title: 'ZITLAS',
            debugShowCheckedModeBanner: false,
            theme: ZitlasTheme.dark,
            darkTheme: ZitlasTheme.dark,
            themeMode: ThemeMode.dark,
            routerConfig: buildRouter(authState),
          );
        },
      ),
    );
  }
}

/// Schedules Zino's daily reminders ONLY for a signed-in athlete.
///
/// This used to run from `main()`, before any session resolved, so all eight
/// athlete slots — breakfast, lunch, snack, dinner, steps, workout, morning
/// motivation, wind-down — were also delivered to experts. Every slot is
/// athlete-only, so for an expert the correct schedule is no schedule.
///
/// Cancelling on expert/logout matters as much as scheduling on athlete:
/// `flutter_local_notifications` alarms outlive the process, so a device
/// that once held an athlete session would keep firing meal reminders long
/// after that account signed out unless they are explicitly cancelled.
abstract final class _ReminderBootstrap {
  static String? _appliedFor;

  static void sync(AuthState authState) {
    final role = authState.status == AuthStatus.authenticated
        ? authState.profile?.resolvedRole
        : null;
    // Key on uid+role so an account switch always re-applies, even between
    // two accounts that happen to share a role.
    final key = role == null ? null : '${authState.profile?.uid}:$role';
    if (key == _appliedFor) return;
    _appliedFor = key;

    final scheduler = ZinoNotificationScheduler();
    final Future<void> work = role == 'user'
        ? scheduler.scheduleAll(preferences: NotificationPreferences.load())
        : scheduler.cancelAll();

    work.catchError((Object e) {
      if (kDebugMode) debugPrint('[NOTIF] reminder sync failed: $e');
    });
  }
}

/// Keeps [PresenceService] following the session, for BOTH athletes and
/// experts — one implementation, keyed only on uid, because "is this person
/// reachable right now" means the same thing whichever role they hold.
///
/// Mirrors [_FcmBootstrap]'s latch so the `Consumer` rebuilding on every
/// [AuthState] change doesn't restart the heartbeat. Sign-out is handled in
/// [AuthState.signOut] rather than here: the offline write needs a live auth
/// context, which is already gone by the time this rebuilds.
abstract final class _PresenceBootstrap {
  static String? _startedForUid;

  static void sync(AuthState authState) {
    final uid = authState.status == AuthStatus.authenticated
        ? authState.profile?.uid
        : null;
    if (uid == _startedForUid) return;
    _startedForUid = uid;
    if (uid == null) {
      PresenceService.instance.stop().catchError((Object e) {
        if (kDebugMode) debugPrint('[PRESENCE] stop failed: $e');
      });
      return;
    }
    PresenceService.instance.start(uid).catchError((Object e) {
      if (kDebugMode) debugPrint('[PRESENCE] start failed: $e');
    });
  }
}

/// Fires `FcmService.initForUser()` exactly once per newly-authenticated
/// uid — NOT at splash, only once [AuthState] actually resolves to
/// `authenticated` — mirroring `push-notifications.js`'s "only after login"
/// gate. A static latch (not per-widget state) survives the `Consumer`
/// rebuilding on every [AuthState] change without re-triggering.
///
/// Also wires the three message lifecycles exactly once per process:
///   * `onMessage`          — app FOREGROUND: the OS draws nothing, so
///     [FcmService.showForeground] republishes it locally.
///   * `onMessageOpenedApp`  — app was BACKGROUNDED and the user tapped the
///     OS notification.
///   * `getInitialMessage()` — app was TERMINATED and launched BY the tap.
///     Cannot navigate yet (no router), so it is remembered and consumed once
///     authentication resolves.
abstract final class _FcmBootstrap {
  static String? _initializedForUid;

  /// The signed-in role, kept current so the ONE foreground listener can
  /// drop a mis-targeted push. Client-side containment: the server should
  /// already target the right token, and this makes a mistake invisible
  /// rather than merely rare.
  static String? _role;
  static bool _listenersAttached = false;
  static final FcmService _service = FcmService(firestore: FirebaseFirestore.instance);

  static void maybeInit(AuthState authState) {
    _attachListeners();
    if (authState.status != AuthStatus.authenticated) {
      _role = null;
      return;
    }
    _role = authState.profile?.resolvedRole;
    final uid = authState.profile?.uid;
    if (uid == null || uid == _initializedForUid) return;
    _initializedForUid = uid;
    _service.initForUser(uid).catchError((Object e) {
      if (kDebugMode) debugPrint('[FCM] init failed: $e');
    });
    // A cold start FROM a notification can only navigate once the session is
    // real AND the splash has released the route.
    if (NotificationRouter.hasPending) _consumePendingWhenReady();
  }

  /// Waits for the splash gate before routing a cold-start notification.
  ///
  /// Without this the payload would be LOST: while the gate still holds,
  /// router.redirect() forces every location back to `/splash`, so a push to
  /// the notification's destination would be redirected away — and the pending
  /// payload is cleared when consumed, so there would be nothing left to retry.
  static void _consumePendingWhenReady() {
    void consume() => WidgetsBinding.instance
        .addPostFrameCallback((_) => NotificationRouter.consumePending());

    if (SplashGate.instance.isReady) {
      consume();
      return;
    }
    void listener() {
      if (!SplashGate.instance.isReady) return;
      SplashGate.instance.removeListener(listener);
      consume();
    }
    SplashGate.instance.addListener(listener);
  }

  static void _attachListeners() {
    if (_listenersAttached) return;
    _listenersAttached = true;

    // Local-notification taps (a foreground notification we drew ourselves)
    // route through the SAME NotificationRouter as OS notification taps.
    _service.initLocalNotifications(onTap: NotificationRouter.route);

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final type = message.data['type']?.toString();
      if (kDebugMode) debugPrint('[FCM] foreground $type');
      // Role isolation, second layer. An expert must never see a breakfast
      // reminder surface over their dashboard.
      final wrongRole = !isForRole(type, _role);
      if (wrongRole && kDebugMode) {
        debugPrint('[FCM] dropped $type - not for role $_role');
      }
      _service.showForeground(
        message,
        suppress: wrongRole || _isViewingChat(message),
      );
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      NotificationRouter.route(
        NotificationPayload.fromData(message.data.cast<String, dynamic>()),
      );
    });

    // Terminated-state launch. Remembered rather than routed: the router does
    // not exist yet at this point in startup.
    FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
      if (message == null) return;
      NotificationRouter.remember(
        NotificationPayload.fromData(message.data.cast<String, dynamic>()),
      );
    });
  }

  /// True when the user is already looking at exactly the conversation this
  /// message belongs to — a tray entry for the screen you are reading is the
  /// noise real messaging apps deliberately avoid.
  static bool _isViewingChat(RemoteMessage message) {
    if (message.data['type'] != 'chat_message') return false;
    final context = rootNavigatorKey.currentContext;
    if (context == null) return false;
    try {
      final location = GoRouterState.of(context).uri.toString();
      final counterpart = message.data['counterpartId']?.toString();
      final chatId = message.data['chatId']?.toString();
      // The coaching chat lives in the Website WebView, reached via
      // /coach-profile/<coachId>; the native chat route is /chat/<roomId>.
      if (counterpart != null && location.contains('/coach-profile/$counterpart')) return true;
      if (chatId != null && location.contains('/chat/$chatId')) return true;
      return false;
    } catch (_) {
      return false;
    }
  }
}
