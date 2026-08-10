import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Schedules the ONE Rest Timer completion alert.
///
/// Deliberately its own small service rather than a method bolted onto
/// [ZinoNotificationScheduler] (`core/notifications/zino_notification_scheduler.dart`)
/// or [FcmService] (`core/notifications/fcm_service.dart`): those two already
/// each own an independent `FlutterLocalNotificationsPlugin` instance and
/// channel set for their own concern, and this mirrors that exact,
/// already-established pattern for a third, unrelated concern — not a
/// competing notification system. `flutter_local_notifications` is the SAME
/// package both of them use; nothing new is added to `pubspec.yaml`.
///
/// USES `zonedSchedule` — same mechanism/reasoning as Zino's daily reminders:
/// handed to the Android Alarm Manager, so it fires with the app closed,
/// minimised, or the screen locked, and its sound/vibration are delivered by
/// the OS without any Dart code needing to run. That is what makes
/// "completion while backgrounded/locked" reliable rather than best-effort.
class RestTimerNotificationService {
  RestTimerNotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    DateTime Function()? clock,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _now = clock ?? DateTime.now;

  final FlutterLocalNotificationsPlugin _plugin;
  final DateTime Function() _now;

  static const channelId = 'rest_timer';
  static const channelName = 'Rest Timer';
  static const channelDescription = 'Alerts you when your set rest period is over.';

  /// Stable id — only one Rest Timer can be active (see the controller), so
  /// scheduling always REPLACES rather than stacking duplicates, same as
  /// every stable-id notification elsewhere in the app.
  static const _notificationId = 9001;

  bool _ready = false;

  /// Never throws. A platform-channel failure here (missing plugin
  /// registration, an OEM quirk, a test environment with no channel mock)
  /// must not take the core countdown down with it — spec §39, "if a
  /// secondary feature fails, the core countdown must continue". Callers can
  /// tell initialization genuinely failed because [_ready] stays false and
  /// every subsequent call is then also a safe no-op.
  Future<void> init() async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      try {
        final name = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(name.identifier));
      } catch (e) {
        if (kDebugMode) debugPrint('[REST TIMER] timezone lookup failed, using UTC: $e');
      }
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            AndroidNotificationChannel(
              channelId,
              channelName,
              description: channelDescription,
              importance: Importance.high,
              enableVibration: true,
              // A short, deliberate two-pulse pattern — NOT a loop (spec:
              // "do not create an annoying vibration loop"). Only used for
              // the native/background delivery path; the foreground path
              // uses HapticFeedback instead (see the controller) since the
              // app is already running and can time it precisely against
              // the chime.
              vibrationPattern: Int64List.fromList([0, 260, 120, 260]),
            ),
          );
      _ready = true;
    } catch (e) {
      if (kDebugMode) debugPrint('[REST TIMER] notification init failed (non-fatal): $e');
    }
  }

  /// Schedules the completion alert for [endTime]. Safe to call repeatedly —
  /// the stable id means a re-schedule (e.g. on Resume, with a new end time)
  /// replaces the previous one rather than firing twice.
  Future<void> scheduleCompletion(DateTime endTime) async {
    await init();
    final when = tz.TZDateTime.from(endTime, tz.local);
    // Already in the past (can happen if Resume is pressed a beat after the
    // stored end time) — nothing to schedule; the controller's own
    // foreground completion path has already fired or will on its next tick.
    if (!when.isAfter(tz.TZDateTime.from(_now(), tz.local))) return;

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
        enableVibration: true,
        vibrationPattern: null, // uses the channel's pattern (set above)
      ),
    );
    try {
      await _plugin.zonedSchedule(
        id: _notificationId,
        title: 'Rest Timer Complete',
        body: 'Your rest period is over. Get ready for your next set.',
        scheduledDate: when,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    } on PlatformException catch (e) {
      if (e.code == 'exact_alarms_not_permitted') {
        // Same graceful degrade as Zino: a windowed alarm still arrives, just
        // not necessarily to the exact second — far better than a silent
        // failure to complete the ONE thing this service exists to do.
        await _plugin.zonedSchedule(
          id: _notificationId,
          title: 'Rest Timer Complete',
          body: 'Your rest period is over. Get ready for your next set.',
          scheduledDate: when,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      } else {
        if (kDebugMode) debugPrint('[REST TIMER] schedule failed (non-fatal): $e');
      }
    } catch (e) {
      // Never let a notification-scheduling failure take the countdown down
      // with it — the core timer must keep working with or without this.
      if (kDebugMode) debugPrint('[REST TIMER] schedule failed (non-fatal): $e');
    }
  }

  /// Cancels the pending completion alert — called on Pause, Reset, and right
  /// before showing the in-app completion state (so a foregrounded
  /// completion never ALSO pops a system notification for the screen the
  /// athlete is already looking at).
  Future<void> cancel() async {
    try {
      await init();
      await _plugin.cancel(id: _notificationId);
    } catch (e) {
      if (kDebugMode) debugPrint('[REST TIMER] cancel failed (non-fatal): $e');
    }
  }
}
