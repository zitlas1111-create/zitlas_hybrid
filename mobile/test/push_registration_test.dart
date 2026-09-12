import 'dart:async';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/core/notifications/fcm_service.dart';
import 'package:zitlas_mobile/core/notifications/presentation/push_permission_banner.dart';
import 'package:zitlas_mobile/core/storage/local_storage_service.dart';

/// FCM device registration — for EXPERTS exactly as for athletes.
///
/// THE BUG THIS PINS. On Android, firebase_messaging reports a device that
/// has never been asked for POST_NOTIFICATIONS as `denied` (Android has no
/// "not determined"). `initForUser` treated `denied` as "the user said no"
/// and stopped, and the only other place that asks is the consent sheet in
/// the ATHLETE shell, which experts never enter. So no expert on Android 13+
/// was ever asked, and none was ever registered — production held zero
/// expert devices, and every "new client request" push reached nobody.
class FakeMessaging extends PushMessaging {
  FakeMessaging({
    this.status = AuthorizationStatus.denied,
    this.grantOnRequest = true,
    this.token = 'tok_phone',
  });

  AuthorizationStatus status;
  bool grantOnRequest;
  String? token;
  int requests = 0;
  int settingsOpened = 0;
  int subscriptions = 0;
  final _refresh = StreamController<String>.broadcast();

  /// FCM issuing this device a new token.
  void rotateTo(String next) {
    token = next;
    _refresh.add(next);
  }

  @override
  Future<AuthorizationStatus> permissionStatus() async => status;

  @override
  Future<AuthorizationStatus> requestPermission() async {
    requests++;
    if (grantOnRequest) status = AuthorizationStatus.authorized;
    return status;
  }

  @override
  Future<void> prepareForToken() async {}

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get onTokenRefresh {
    subscriptions++;
    return _refresh.stream;
  }

  @override
  Future<void> openNotificationSettings() async => settingsOpened++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFirebaseFirestore db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorageService.init();
    await FcmService.resetForTest();
    db = FakeFirebaseFirestore();
  });

  FcmService service(FakeMessaging m) => FcmService(firestore: db, messaging: m);

  Future<Map<String, dynamic>?> row(String token) async =>
      (await db.collection('device_tokens').doc(token).get()).data();

  Future<List<dynamic>> legacyArray(String uid) async =>
      ((await db.collection('users').doc(uid).get()).data()?['pushTokens']
          as List?) ??
      const [];

  Future<void> settle() => pumpEventQueue(times: 50);

  group('Experts are registered', () {
    test('a never-asked Android device reads "denied" — the expert is asked anyway',
        () async {
      final m = FakeMessaging(status: AuthorizationStatus.denied);
      await service(m).initForUser('expert_1', promptIfNeeded: true);

      expect(m.requests, 1,
          reason: 'nothing else in the app ever asks an expert');
      final r = await row('tok_phone');
      expect(r, isNotNull, reason: 'the expert device was never registered');
      expect(r!['uid'], 'expert_1');
      expect(r['enabled'], isTrue);
      expect(r['loggedIn'], isTrue);
      expect(r['rendersOwnNotifications'], isTrue);
      expect(await legacyArray('expert_1'), contains('tok_phone'));
      expect(FcmService.permissionState.value, PushPermissionState.granted);
    });

    test('an expert device is registered exactly like an athlete device', () async {
      await service(FakeMessaging(
              status: AuthorizationStatus.authorized, token: 'tok_athlete'))
          .initForUser('athlete_1');
      // A DIFFERENT phone: fresh local state as well as fresh FCM state.
      await FcmService.resetForTest();
      SharedPreferences.setMockInitialValues({});
      await LocalStorageService.init();
      await service(FakeMessaging(
              status: AuthorizationStatus.denied, token: 'tok_expert'))
          .initForUser('expert_1', promptIfNeeded: true);

      final athlete = (await row('tok_athlete'))!;
      final expert = (await row('tok_expert'))!;
      expect(expert.keys.toSet(), athlete.keys.toSet(),
          reason: 'an expert row must carry every field an athlete row does');
      for (final k in ['platform', 'enabled', 'loggedIn', 'rendersOwnNotifications']) {
        expect(expert[k], athlete[k], reason: '$k differs between the two');
      }
    });

    test('on a phone that has already been asked, the expert gets the banner, not a surprise dialog',
        () async {
      await service(FakeMessaging(status: AuthorizationStatus.authorized))
          .initForUser('athlete_1');
      await FcmService.resetForTest();
      final m = FakeMessaging(status: AuthorizationStatus.denied); // revoked since
      await service(m).initForUser('expert_1', promptIfNeeded: true);
      expect(m.requests, 0);
      expect(FcmService.permissionState.value, PushPermissionState.blocked);
    });

    test('an expert who refuses is not registered — and the app can say why',
        () async {
      final m = FakeMessaging(
          status: AuthorizationStatus.denied, grantOnRequest: false);
      await service(m).initForUser('expert_1', promptIfNeeded: true);

      expect(await row('tok_phone'), isNull);
      expect(FcmService.permissionState.value, PushPermissionState.blocked);
    });

    test('a refusal is not asked again inside the snooze window', () async {
      final m = FakeMessaging(
          status: AuthorizationStatus.denied, grantOnRequest: false);
      await service(m).initForUser('expert_1', promptIfNeeded: true);
      await service(m).initForUser('expert_1', promptIfNeeded: true);
      expect(m.requests, 1);
    });
  });

  group('Athletes are unchanged', () {
    test('an athlete with notifications allowed is registered, unprompted',
        () async {
      final m = FakeMessaging(status: AuthorizationStatus.authorized);
      await service(m).initForUser('athlete_1');
      expect((await row('tok_phone'))!['uid'], 'athlete_1');
      expect(m.requests, 0);
    });

    test('a "denied" athlete device is not prompted from here — the consent sheet asks',
        () async {
      final m = FakeMessaging(status: AuthorizationStatus.denied);
      await service(m).initForUser('athlete_1');
      expect(m.requests, 0);
      expect(await row('tok_phone'), isNull);
      expect(FcmService.permissionState.value, PushPermissionState.askable);
    });

    test('an undetermined permission (iOS) is still requested, whatever the role',
        () async {
      final m = FakeMessaging(status: AuthorizationStatus.notDetermined);
      await service(m).initForUser('athlete_1');
      expect(m.requests, 1);
      expect(await row('tok_phone'), isNotNull);
    });
  });

  group('Turning notifications back on', () {
    test('when the OS will not ask again, system settings open', () async {
      final m = FakeMessaging(
          status: AuthorizationStatus.denied, grantOnRequest: false);
      final result = await service(m).enableFromSettings('expert_1');
      expect(result, PushPermissionState.blocked);
      expect(m.settingsOpened, 1);
    });

    test('coming back from settings with notifications on registers the device',
        () async {
      final m = FakeMessaging(
          status: AuthorizationStatus.denied, grantOnRequest: false);
      final s = service(m);
      await s.initForUser('expert_1', promptIfNeeded: true);
      expect(await row('tok_phone'), isNull);

      m.status = AuthorizationStatus.authorized; // the user flipped the switch
      await s.touchActive('expert_1'); // ...and returned to the app

      expect((await row('tok_phone'))!['uid'], 'expert_1');
      expect(FcmService.permissionState.value, PushPermissionState.granted);
    });

    test('the foreground touch never registers a device that cannot notify',
        () async {
      final m = FakeMessaging(status: AuthorizationStatus.denied);
      await service(m).touchActive('expert_1');
      expect((await db.collection('device_tokens').get()).docs, isEmpty,
          reason: 'this used to write enabled:true on every foreground');
    });
  });

  group('Token rotation', () {
    test('the new token is registered and the old one retired', () async {
      final m = FakeMessaging(
          status: AuthorizationStatus.authorized, token: 'tok_old');
      await service(m).initForUser('expert_1');
      m.rotateTo('tok_new');
      await settle();

      expect((await row('tok_new'))!['uid'], 'expert_1');
      expect((await row('tok_new'))!['enabled'], isTrue);
      final old = (await row('tok_old'))!;
      expect(old['enabled'], isFalse);
      expect(old['retiredAt'], isNotNull);
      expect(await legacyArray('expert_1'), isNot(contains('tok_old')));
    });

    test('initialising again does not stack a second rotation listener',
        () async {
      final m = FakeMessaging(status: AuthorizationStatus.authorized);
      final s = service(m);
      await s.initForUser('expert_1');
      await s.initForUser('expert_1', promptIfNeeded: true); // role resolved late
      expect(m.subscriptions, 1);
    });

    test('after an account switch, a rotation registers the account signed in NOW',
        () async {
      final m = FakeMessaging(
          status: AuthorizationStatus.authorized, token: 'tok_a');
      final s = service(m);
      await s.initForUser('expert_1');
      await s.unregisterDevice('expert_1');
      await s.initForUser('athlete_2');

      m.rotateTo('tok_b');
      await settle();
      expect((await row('tok_b'))!['uid'], 'athlete_2');
    });
  });

  group('Logout', () {
    test('marks the device signed out and drops it from the legacy array',
        () async {
      final m = FakeMessaging(status: AuthorizationStatus.authorized);
      final s = service(m);
      await s.initForUser('expert_1');
      await s.unregisterDevice('expert_1');

      final r = (await row('tok_phone'))!;
      expect(r['enabled'], isFalse);
      expect(r['loggedIn'], isFalse);
      expect(await legacyArray('expert_1'), isNot(contains('tok_phone')));
    });

    test('a rotation after logout registers nobody', () async {
      final m = FakeMessaging(status: AuthorizationStatus.authorized);
      final s = service(m);
      await s.initForUser('expert_1');
      await s.unregisterDevice('expert_1');

      m.rotateTo('tok_after_logout');
      await settle();
      expect(await row('tok_after_logout'), isNull);
    });
  });

  group('Wiring', () {
    String source(String path) {
      final f = File(path);
      return f.existsSync() ? f.readAsStringSync() : '';
    }

    test('the app prompts experts from the FCM bootstrap', () {
      final src = source('lib/app/app.dart');
      expect(src.contains('promptIfNeeded: isExpert'), isTrue);
      expect(src.contains('_initializedAsExpert = false'), isTrue,
          reason: 'sign-out must reset the expert latch too');
    });

    test('the expert dashboard shows the notifications-off banner; the coach profile does not',
        () {
      final src = source('lib/features/coaching_webview/coaching_webview_screen.dart');
      final expertStart = src.indexOf('factory CoachingWebViewScreen.expertDashboard');
      final coachStart = src.indexOf('factory CoachingWebViewScreen.coachProfile');
      final expert = src.substring(expertStart);
      expect(expert.substring(0, expert.indexOf(');')).contains('showPushBanner: true'),
          isTrue);
      expect(src.substring(coachStart, expertStart).contains('showPushBanner'), isFalse);
    });
  });

  group('PushPermissionBanner', () {
    Future<void> pump(
      WidgetTester t,
      ValueNotifier<PushPermissionState> state,
      Future<void> Function() onEnable,
    ) =>
        t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: PushPermissionBanner(state: state, onEnable: onEnable),
          ),
        ));

    testWidgets('hidden while notifications work', (t) async {
      await pump(t, ValueNotifier(PushPermissionState.granted), () async {});
      expect(find.byKey(const Key('pushBannerEnable')), findsNothing);
    });

    testWidgets('offers "Turn on" while the app can still ask', (t) async {
      await pump(t, ValueNotifier(PushPermissionState.askable), () async {});
      expect(find.text('Turn on'), findsOneWidget);
    });

    testWidgets('offers "Open settings" once blocked, and the tap reaches the handler',
        (t) async {
      var taps = 0;
      await pump(t, ValueNotifier(PushPermissionState.blocked), () async {
        taps++;
      });
      expect(find.text('Open settings'), findsOneWidget);
      await t.tap(find.byKey(const Key('pushBannerEnable')));
      await t.pump();
      expect(taps, 1);
    });

    testWidgets('disappears the moment notifications are allowed', (t) async {
      final state = ValueNotifier(PushPermissionState.blocked);
      await pump(t, state, () async {});
      state.value = PushPermissionState.granted;
      await t.pump();
      expect(find.byKey(const Key('pushBannerEnable')), findsNothing);
    });

    testWidgets('can be dismissed for the session', (t) async {
      await pump(t, ValueNotifier(PushPermissionState.askable), () async {});
      await t.tap(find.byKey(const Key('pushBannerDismiss')));
      await t.pump();
      expect(find.byKey(const Key('pushBannerEnable')), findsNothing);
    });
  });
}
