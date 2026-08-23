import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/core/notifications/notification_onboarding.dart';
import 'package:zitlas_mobile/core/notifications/notification_preferences.dart';
import 'package:zitlas_mobile/core/notifications/zino_notification_scheduler.dart';
import 'package:zitlas_mobile/core/storage/local_storage_service.dart';

/// The first-launch permission ask.
///
/// Android shows its POST_NOTIFICATIONS dialog exactly once per install. The
/// failure that costs an athlete every reminder they'd have got is spending
/// that single dialog badly — cold, or repeatedly after a decline — so the
/// gate around it is worth testing more carefully than the sheet itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalStorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await LocalStorageService.init();
  });

  NotificationOnboarding subject(_FakeScheduler scheduler) =>
      NotificationOnboarding(storage: storage, scheduler: scheduler, isAndroid: true);

  test('a fresh install with no permission gets the pitch', () async {
    final scheduler = _FakeScheduler(enabled: false);
    expect(await subject(scheduler).shouldPrompt(), isTrue);
  });

  test('the pitch is shown once, never again — even if still denied', () async {
    final scheduler = _FakeScheduler(enabled: false);
    final onboarding = subject(scheduler);

    expect(await onboarding.shouldPrompt(), isTrue);
    await onboarding.declineWithoutAsking();

    expect(await onboarding.shouldPrompt(), isFalse,
        reason: 'Android would silently deny a second ask — re-pitching is pure noise');
  });

  test('already-granted permission skips the sheet and repairs the schedule', () async {
    // Android 12 and below auto-grant; so does a reinstall-over-grant.
    final scheduler = _FakeScheduler(enabled: true);
    final onboarding = subject(scheduler);

    expect(await onboarding.shouldPrompt(), isFalse);
    expect(scheduler.scheduleAllCalls, 1,
        reason: 'granted-but-unscheduled is exactly the state that looks broken');
    expect(onboarding.hasPrompted, isTrue);
  });

  test('accepting requests the OS permission and then schedules', () async {
    final scheduler = _FakeScheduler(enabled: false, grantOnRequest: true);
    final onboarding = subject(scheduler);

    expect(await onboarding.requestAfterConsent(), isTrue);
    expect(scheduler.requestCalls, 1);
    expect(scheduler.scheduleAllCalls, 1);
    expect(onboarding.hasPrompted, isTrue);
  });

  test('a denied OS request schedules nothing but still counts as asked', () async {
    final scheduler = _FakeScheduler(enabled: false, grantOnRequest: false);
    final onboarding = subject(scheduler);

    expect(await onboarding.requestAfterConsent(), isFalse);
    expect(scheduler.requestCalls, 1);
    expect(scheduler.scheduleAllCalls, 0);
    expect(await onboarding.shouldPrompt(), isFalse);
  });

  test('the ask is Android-only', () async {
    final scheduler = _FakeScheduler(enabled: false);
    final onboarding = NotificationOnboarding(
      storage: storage,
      scheduler: scheduler,
      isAndroid: false,
    );
    expect(await onboarding.shouldPrompt(), isFalse);
  });

  test('an unreadable permission state never pops a sheet', () async {
    // Better to stay quiet than to throw a modal at someone because a
    // platform channel misbehaved.
    final scheduler = _FakeScheduler(enabled: false, throwOnAreEnabled: true);
    expect(await subject(scheduler).shouldPrompt(), isFalse);
  });

  test('the prompted flag is device-scoped and survives a restart', () async {
    await subject(_FakeScheduler(enabled: false)).declineWithoutAsking();

    // Simulate a relaunch: same SharedPreferences backing store, new service.
    final reloaded = await LocalStorageService.init();
    expect(
      NotificationOnboarding(
        storage: reloaded,
        scheduler: _FakeScheduler(enabled: false),
        isAndroid: true,
      ).hasPrompted,
      isTrue,
    );
  });
}

/// Stands in for the real scheduler so the gate can be tested without a
/// platform channel. Only the three methods the onboarding flow calls.
class _FakeScheduler extends ZinoNotificationScheduler {
  _FakeScheduler({
    required this.enabled,
    this.grantOnRequest = false,
    this.throwOnAreEnabled = false,
  });

  final bool enabled;
  final bool grantOnRequest;
  final bool throwOnAreEnabled;

  int requestCalls = 0;
  int scheduleAllCalls = 0;

  @override
  Future<bool> areEnabled() async {
    if (throwOnAreEnabled) throw StateError('platform channel unavailable');
    return enabled;
  }

  @override
  Future<bool> requestPermission() async {
    requestCalls++;
    return grantOnRequest;
  }

  @override
  Future<bool> scheduleAll({NotificationPreferences? preferences}) async {
    // Returns whether anything was ACTUALLY scheduled — the real
    // implementation now refuses when POST_NOTIFICATIONS is missing, and a
    // caller must be able to tell the difference between "scheduled" and
    // "silently did nothing".
    scheduleAllCalls++;
    return true;
  }
}
