import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../storage/local_storage_service.dart';
import 'notification_preferences.dart';
import 'zino_messages.dart';

/// A fixed point in the athlete's day that Zino speaks at.
///
/// Times are DEFAULTS, deliberately not user-configurable: asking someone to
/// pick eight reminder times before they have used the app is a setup wall,
/// and these hours are when the reminder is actually useful. What the athlete
/// CAN control is which categories they hear from at all.
enum ZinoSlot {
  morningMotivation(1001, 7, 30, NotificationCategory.motivation, 'Good Morning'),
  breakfast(1002, 9, 0, NotificationCategory.meals, '🍳 Breakfast Time!'),
  lunch(1003, 13, 0, NotificationCategory.meals, '🥗 Lunch Time!'),
  snack(1004, 17, 0, NotificationCategory.meals, '🍎 Snack Time'),
  steps(1005, 18, 0, NotificationCategory.steps, '🚶 Keep Going!'),
  workout(1006, 19, 0, NotificationCategory.workout, '💪 Workout Time!'),
  dinner(1007, 20, 30, NotificationCategory.meals, '🍽 Dinner Time!'),
  night(1008, 22, 0, NotificationCategory.motivation, '🌙 Rest Well');

  const ZinoSlot(this.id, this.hour, this.minute, this.category, this.heading);

  /// Stable notification id. Reusing the same id per slot means rescheduling
  /// REPLACES rather than stacking duplicates.
  final int id;
  final int hour;
  final int minute;
  final NotificationCategory category;
  final String heading;

  /// The body for [date]. Deterministic per day so a notification scheduled
  /// days in advance shows the same text it was scheduled with.
  String bodyFor(DateTime date) => switch (this) {
        ZinoSlot.morningMotivation => pickForDay(kMotivationQuotes, date),
        ZinoSlot.breakfast => pickForDay(kBreakfastMessages, date),
        ZinoSlot.lunch => pickForDay(kLunchMessages, date),
        ZinoSlot.snack => pickForDay(kSnackMessages, date),
        ZinoSlot.dinner => pickForDay(kDinnerMessages, date),
        ZinoSlot.night => pickForDay(kNightMessages, date),
        ZinoSlot.workout => pickForDay(kWorkoutMessages, date),
        // Replaced at fire time with real step numbers — see
        // StepNotifications / the background worker. This is only the text
        // used if that dynamic path never runs.
        ZinoSlot.steps => 'Check your step progress for today.',
      };

  /// True when the slot's content depends on live data, and a static schedule
  /// would risk saying something untrue ("finish your steps" to someone who
  /// already finished, "do your workout" to someone who already did).
  bool get isContextual => this == ZinoSlot.steps || this == ZinoSlot.workout;
}

/// Schedules Zino's daily notifications.
///
/// USES `zonedSchedule` + `DateTimeComponents.time`, which hands the schedule
/// to the ANDROID ALARM MANAGER rather than keeping a Dart timer alive. That
/// is what makes these fire with the app closed, minimised, or the screen
/// locked — nothing of ours needs to be running. Combined with the plugin's
/// boot receiver (declared in AndroidManifest), they also survive a reboot.
class ZinoNotificationScheduler {
  ZinoNotificationScheduler({
    FlutterLocalNotificationsPlugin? plugin,
    LocalStorageService? storage,
    DateTime Function()? clock,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _storage = storage,
        _now = clock ?? DateTime.now;

  final FlutterLocalNotificationsPlugin _plugin;
  final LocalStorageService? _storage;
  final DateTime Function() _now;

  static const channelId = 'zino_daily';
  static const channelName = 'Zino Reminders';
  static const channelDescription =
      'Meal, workout, step and motivation reminders from your AI coach.';

  /// Shown as the notification title on every Zino reminder.
  static const appTitle = 'Zino • Your AI Fitness Coach';

  bool _ready = false;

  LocalStorageService? get _prefs {
    if (_storage != null) return _storage;
    try {
      return LocalStorageService.instance;
    } catch (_) {
      return null;
    }
  }

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      // The device's real zone, not UTC — a 09:00 breakfast reminder must mean
      // 09:00 where the athlete actually is, and must follow them if they
      // travel or the region changes DST.
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name.identifier));
    } catch (e) {
      if (kDebugMode) debugPrint('[NOTIF] timezone lookup failed, using UTC: $e');
    }

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            channelId,
            channelName,
            description: channelDescription,
            importance: Importance.defaultImportance,
          ),
        );
    _ready = true;
  }

  /// Requests POST_NOTIFICATIONS (required from Android 13) and, where the OS
  /// demands it, exact-alarm permission.
  ///
  /// Returns whether notifications can be shown. A refusal is never fatal —
  /// the app is fully usable without reminders.
  Future<bool> requestPermission() async {
    await init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    final granted = await android.requestNotificationsPermission() ?? false;
    if (granted) {
      // Android 14 restricts exact alarms. Without this, schedules silently
      // drift or are dropped, which looks like "notifications don't work".
      try {
        await android.requestExactAlarmsPermission();
        // The answer just changed — re-probe on the next schedule pass.
        _exactAlarms = null;
      } catch (e) {
        if (kDebugMode) debugPrint('[NOTIF] exact alarm request unavailable: $e');
      }
    }
    return granted;
  }

  Future<bool> areEnabled() async {
    await init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? false;
  }

  /// (Re)schedules every enabled slot. Safe to call on every launch — stable
  /// ids mean this replaces rather than duplicates.
  ///
  /// RETURNS whether anything was actually scheduled. Callers must not assume
  /// success: on Android 13+ an alarm registers perfectly happily without
  /// POST_NOTIFICATIONS and then fires into nothing, which is exactly how
  /// meal reminders came to "just not appear" with no error anywhere.
  Future<bool> scheduleAll({NotificationPreferences? preferences}) async {
    await init();
    final prefs = preferences ?? NotificationPreferences.load(_prefs);

    if (!prefs.masterEnabled) {
      await cancelAll();
      if (kDebugMode) debugPrint('[NOTIF] master switch off — all cancelled');
      return false;
    }

    // PERMISSION FIRST. Android 13+ silently discards every notification from
    // an app without POST_NOTIFICATIONS — the alarms fire, nothing shows, and
    // nothing logs. Scheduling into that void is worse than not scheduling:
    // it produces a "scheduled successfully" state that is simply untrue.
    if (!await areEnabled()) {
      await cancelAll();
      if (kDebugMode) {
        debugPrint('[NOTIF] NOT SCHEDULED — POST_NOTIFICATIONS is not granted. '
            'Reminders would fire into a void. The consent sheet '
            '(NotificationOnboarding) must be accepted first; scheduling '
            'resumes automatically on the next launch after that.');
      }
      return false;
    }

    var scheduled = 0;
    for (final slot in ZinoSlot.values) {
      if (!prefs.isEnabled(slot.category)) {
        await _plugin.cancel(id: slot.id);
        continue;
      }
      await _scheduleSlot(slot);
      scheduled++;
    }
    if (kDebugMode) {
      debugPrint('[NOTIF] scheduled $scheduled/${ZinoSlot.values.length} daily reminders '
          '(exactAlarms=${_exactAlarms ?? 'unknown'})');
    }
    return scheduled > 0;
  }

  Future<void> _scheduleSlot(ZinoSlot slot) async {
    final when = _nextOccurrence(slot.hour, slot.minute);
    // exactAllowWhileIdle punches through Doze. Without it a 09:00 reminder
    // can arrive at 11:00 on an idle phone, which is worse than not sending.
    // But SCHEDULE_EXACT_ALARM is refusable from Android 12, and asking for an
    // exact alarm without it throws — so degrade to a windowed alarm rather
    // than losing the reminder entirely.
    final mode = await _exactAllowed()
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
    try {
      await _zonedSchedule(slot, when, mode);
    } on PlatformException catch (e) {
      if (mode == AndroidScheduleMode.exactAllowWhileIdle &&
          e.code == 'exact_alarms_not_permitted') {
        // Permission was revoked between the check and the call.
        _exactAlarms = false;
        await _zonedSchedule(slot, when, AndroidScheduleMode.inexactAllowWhileIdle);
        return;
      }
      rethrow;
    }
  }

  Future<void> _zonedSchedule(
    ZinoSlot slot,
    tz.TZDateTime when,
    AndroidScheduleMode mode,
  ) {
    return _plugin.zonedSchedule(
      id: slot.id,
      title: appTitle,
      body: '${slot.heading}\n${slot.bodyFor(when.toLocal())}',
      scheduledDate: when,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          styleInformation: BigTextStyleInformation(''),
        ),
      ),
      androidScheduleMode: mode,
      // Repeat daily at this wall-clock time.
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  bool? _exactAlarms;

  /// Whether the OS will honour a to-the-minute alarm.
  ///
  /// False means reminders still arrive, but inside a batching window Android
  /// chooses (an hour wide on the devices tested). Surfaced in settings so a
  /// late 09:00 breakfast nudge has a visible explanation and a fix.
  Future<bool> canScheduleExactly() {
    _exactAlarms = null;
    return _exactAllowed();
  }

  /// Sends the athlete to the OS screen that grants exact alarms. There is no
  /// in-app dialog for this one — Android only accepts it from Settings.
  Future<void> requestExactAlarms() async {
    await init();
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestExactAlarmsPermission();
      _exactAlarms = null;
    } catch (e) {
      if (kDebugMode) debugPrint('[NOTIF] exact alarm request unavailable: $e');
    }
  }

  /// Cached per [scheduleAll] pass — eight identical platform round-trips per
  /// launch would be wasteful, and the answer cannot change mid-pass.
  Future<bool> _exactAllowed() async {
    final cached = _exactAlarms;
    if (cached != null) return cached;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      return _exactAlarms = await android?.canScheduleExactNotifications() ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('[NOTIF] exact-alarm capability unknown: $e');
      return _exactAlarms = false;
    }
  }

  /// Next occurrence of h:m, rolling to tomorrow if today's time has passed.
  tz.TZDateTime _nextOccurrence(int hour, int minute) {
    final now = tz.TZDateTime.from(_now(), tz.local);
    var when = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
    return when;
  }

  /// Fires a contextual reminder immediately, with real numbers.
  ///
  /// Called from the background worker, which is why the step and workout
  /// slots carry only placeholder static text: a schedule fixed hours earlier
  /// cannot know whether the goal was met, and telling someone to finish steps
  /// they already finished is exactly the kind of thing that gets an app
  /// muted.
  Future<void> showContextual({
    required ZinoSlot slot,
    required String body,
  }) async {
    await init();
    await _plugin.show(
      id: slot.id,
      title: appTitle,
      body: '${slot.heading}\n$body',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          styleInformation: BigTextStyleInformation(''),
        ),
      ),
    );
  }

  Future<void> cancelAll() async {
    await init();
    for (final slot in ZinoSlot.values) {
      await _plugin.cancel(id: slot.id);
    }
  }

  /// Diagnostic — what the OS actually has queued.
  Future<List<PendingNotificationRequest>> pending() async {
    await init();
    return _plugin.pendingNotificationRequests();
  }
}
