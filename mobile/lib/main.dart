import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app.dart';
import 'app/splash_gate.dart';
import 'core/config/firebase_bootstrap.dart';
import 'core/notifications/fcm_service.dart';
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
/// THIS is what draws the notification when the app is backgrounded or
/// terminated — the two states in which people actually read their tray.
///
/// It used to only log. The backend sent an FCM `notification` block, so the
/// FCM SDK drew those itself and the app never saw them: the ZITLAS icon,
/// tone, colour, expanded text and meal photo were all applied in
/// [FcmService.render], which only ran in the FOREGROUND. That is precisely
/// why the notification kept arriving looking like a stock Android one no
/// matter what was configured. Android now receives DATA-ONLY messages (see
/// push_service.send_to_token) so this handler runs for every message and
/// [FcmService.render] is the single renderer in all three states.
///
/// Still does NOT navigate: this is a separate Dart isolate with no widget
/// tree, so touching UI from here is invalid. The tap is handled later by
/// `onMessageOpenedApp`/`getInitialMessage` in the main isolate — see
/// NotificationRouter.
///
/// Firebase must be initialised here explicitly: a background isolate starts
/// cold and does not inherit `main()`'s initialisation.
@pragma('vm:entry-point')
Future<void> zitlasFirebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('[FCM] background message type=${message.data['type']}');
  // The shared bootstrap, not a second Firebase.initializeApp() — it already
  // swallows the duplicate-app case and keeps every entry point reading the
  // same native config.
  await bootstrapFirebase();
  try {
    await FcmService.render(message);
  } catch (e, st) {
    // Swallowed only at the very top of a background isolate, where an
    // uncaught error would take the isolate down with no user-visible signal
    // at all. The reason is logged rather than hidden.
    debugPrint('[ANDROID_NOTIFICATION] background render failed: $e\n$st');
  }
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

  // Zino's daily reminders are NOT scheduled here any more. Every slot
  // (breakfast, lunch, snack, dinner, steps, workout, motivation, wind-down)
  // is athlete-only, and at this point in startup no session has resolved
  // yet — so scheduling from main() sent meal reminders to experts, every
  // day, whether or not they had ever opened the athlete side.
  // `_ReminderBootstrap` in app/app.dart now schedules them once the
  // signed-in role is actually known, and cancels them for experts.

  runApp(ZitlasApp(firebaseReady: firebaseReady));
}
