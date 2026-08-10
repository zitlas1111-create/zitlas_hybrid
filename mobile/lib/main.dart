import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app.dart';
import 'app/splash_gate.dart';
import 'core/config/firebase_bootstrap.dart';
import 'core/notifications/zino_notification_scheduler.dart';
import 'core/steps/step_background_worker.dart';
import 'core/storage/local_storage_service.dart';
import 'features/rest_timer/rest_timer_controller.dart';

/// FCM background/terminated message handler.
///
/// MUST be a top-level (or static) function annotated `@pragma('vm:entry-point')`
/// — Android spawns a SEPARATE Dart isolate to run it, and the annotation is
/// what stops tree-shaking from removing it in release builds. Without it,
/// release builds silently lose background handling.
///
/// Deliberately does almost nothing: this isolate has no widget tree, so
/// touching UI or navigating from here is invalid. The notification itself is
/// drawn by the OS from the `notification` block the backend sends, and the tap
/// is handled later by `onMessageOpenedApp`/`getInitialMessage` in the main
/// isolate — see NotificationRouter.
@pragma('vm:entry-point')
Future<void> zitlasFirebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('[FCM BG] ${message.messageId} type=${message.data['type']}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // True edge-to-edge on Android: Flutter draws full-bleed behind the
  // status/navigation bars instead of the OS reserving opaque space for
  // them. Without this (and the transparent bar colors below), the system
  // bars render as an opaque black strip on top of whatever Flutter draws —
  // that's the actual root cause of the black framing around the auth
  // screen, not a Scaffold/background/SafeArea issue.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // App-wide DEFAULT system bar style — transparent + light icons, matching
  // the dark app theme every screen except the auth flow uses. The auth
  // screens override this locally via `AnnotatedRegion<SystemUiOverlayStyle>`
  // (see login_screen.dart / expert_application_review_screen.dart) — this
  // is per-screen, not global, so it doesn't turn Dashboard/Diet/etc. cream.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
      systemStatusBarContrastEnforced: false,
    ),
  );

  // Starts the branded splash's minimum-duration clock NOW, so it runs
  // CONCURRENTLY with Firebase init and the session check below rather than
  // adding delay after them. See SplashGate.
  SplashGate.instance.start();

  await LocalStorageService.init();
  // Loads/reconciles the persisted Rest Timer snapshot (an in-flight timer
  // that expired while the app was closed resolves to "completed" here,
  // silently — see RestTimerController.init() for why) and attaches its
  // lifecycle observer. Must come after LocalStorageService per the same
  // dependency order every other storage-backed init in this file follows.
  await RestTimerController.instance.init();

  // Firebase isn't registered for com.zitlas.app yet — no
  // android/app/google-services.json exists (see
  // docs/MIGRATION_INVENTORY.md §4). Guarded so a missing/invalid config
  // degrades to a "Firebase not configured" auth screen instead of
  // crashing the app on startup; nothing here applies the Gradle
  // google-services plugin, so the build itself is unaffected either way.
  var firebaseReady = true;
  try {
    await bootstrapFirebase();
    // Registered immediately after Firebase init and BEFORE runApp — FCM
    // requires the background handler to be registered at startup, not lazily
    // once some screen mounts, or a message arriving while the app is
    // terminated has nothing to dispatch to.
    FirebaseMessaging.onBackgroundMessage(zitlasFirebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('[ZITLAS] Firebase unavailable, continuing without it: $e');
    firebaseReady = false;
  }

  // Best-effort periodic step-milestone check so a goal can be announced
  // while ZITLAS is closed. Registration is idempotent and never blocks
  // startup — see StepBackgroundWorker for the Android delivery limits this
  // is explicitly subject to.
  unawaited(StepBackgroundWorker.register());

  // (Re)schedule Zino's daily reminders on every launch. Idempotent — each
  // slot has a stable id, so this replaces rather than stacking duplicates,
  // and it repairs the schedule if Android ever dropped it.
  unawaited(ZinoNotificationScheduler().scheduleAll());

  runApp(ZitlasApp(firebaseReady: firebaseReady));
}
