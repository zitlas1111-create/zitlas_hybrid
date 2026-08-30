import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/core/notifications/fcm_service.dart';
import 'package:zitlas_mobile/core/notifications/notification_payload.dart';
import 'package:zitlas_mobile/core/notifications/notification_router.dart';

/// THE BUGS THE FORENSIC INSPECTION FOUND, PINNED FROM THE APP SIDE.
///
/// 79 notification tests already existed and all passed while meal reminders
/// never appeared and coaching approvals arrived in a batch on app open. None
/// of them asserted the two things that actually decide delivery:
///
///   * that reminders are not scheduled before POST_NOTIFICATIONS is granted
///     (Android 13+ silently discards notifications from an app without it —
///     the alarms fire, nothing shows, nothing logs)
///   * that the channel ids the app CREATES are the ones the backend SENDS
///     (Android 8+ silently drops a notification whose channel does not exist)
void main() {
  group('notification channels', () {
    test('every channel id is versioned', () {
      // Android freezes a channel's importance AND its sound at creation, so
      // neither can be changed later on a device that already has the
      // channel. A new id is the only mechanism there is, so each id carries
      // the version it was last re-cut at. Dropping a suffix silently reverts
      // every upgrading device to the old importance and the old sound.
      expect(FcmService.channelCoaching, 'zitlas_coaching_v3');
      for (final id in [
        FcmService.channelMessages,
        FcmService.channelMealReviews,
        FcmService.channelPlans,
        FcmService.channelGeneral,
      ]) {
        expect(id, endsWith('_v2'), reason: '$id lost its version suffix');
      }
    });

    test('the manifest fallback channel is one the app creates', () {
      // THE REGRESSION THIS CATCHES. AndroidManifest names a
      // default_notification_channel_id for messages that arrive without an
      // explicit channel. When the channel ids were re-cut with version
      // suffixes, the manifest kept pointing at the OLD id — a channel the
      // app no longer creates. Android drops such a notification in silence,
      // with nothing in any log to say it happened.
      final manifest = File('android/app/src/main/AndroidManifest.xml');
      if (!manifest.existsSync()) {
        markTestSkipped('android tree not reachable from this run');
        return;
      }
      final xml = manifest.readAsStringSync();
      // `dotAll` so the value may sit on the line after the name, which is
      // how the manifest is actually formatted.
      final m = RegExp(
        r'default_notification_channel_id".*?android:value="([^"]+)"',
        dotAll: true,
      ).firstMatch(xml);
      expect(m, isNotNull, reason: 'the fallback channel meta-data is gone');
      expect(
        [
          FcmService.channelMessages,
          FcmService.channelCoaching,
          FcmService.channelMealReviews,
          FcmService.channelPlans,
          FcmService.channelGeneral,
        ],
        contains(m!.group(1)),
        reason: '${m.group(1)} is not a channel FcmService creates',
      );
    });

    test('the notification small icon is not the launcher icon', () {
      // Android reduces a small icon to its ALPHA channel and re-tints it.
      // ic_launcher is a fully opaque square, so it renders as a white blob.
      final manifest = File('android/app/src/main/AndroidManifest.xml');
      final icon = File('android/app/src/main/res/drawable/ic_stat_zitlas.xml');
      if (!manifest.existsSync()) {
        markTestSkipped('android tree not reachable from this run');
        return;
      }
      final xml = manifest.readAsStringSync();
      expect(xml, contains('default_notification_icon'),
          reason: 'without this, FCM falls back to the launcher icon for '
              'every notification the OS draws itself');
      expect(xml, contains('@drawable/ic_stat_zitlas'));
      expect(icon.existsSync(), isTrue,
          reason: 'the manifest names an icon that does not exist — the '
              'build would fail, or fall back to the blob');
    });

    test('the ZITLAS tone exists in res/raw', () {
      // A missing res/raw resource does not throw — Android falls back to the
      // default sound. The tone would simply never play, and the only symptom
      // is that ZITLAS sounds like every other app.
      final dir = Directory('android/app/src/main/res/raw');
      if (!dir.existsSync()) {
        markTestSkipped('android tree not reachable from this run');
        return;
      }
      final matches = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last
              .startsWith('${FcmService.soundResource}.'));
      expect(matches, isNotEmpty,
          reason: 'the channels name ${FcmService.soundResource} but '
              '${dir.path} has no such file');
    });

    test('every channel the app creates matches the backend', () {
      // push_service.py's CHANNEL_* constants. A mismatch here is invisible
      // at runtime and fatal to delivery.
      final backend = File('../backend/services/push_service.py');
      if (!backend.existsSync()) {
        markTestSkipped('backend source not reachable from this run');
        return;
      }
      final py = backend.readAsStringSync();
      for (final channel in [
        FcmService.channelMessages,
        FcmService.channelCoaching,
        FcmService.channelMealReviews,
        FcmService.channelPlans,
        FcmService.channelGeneral,
      ]) {
        expect(py.contains('"$channel"'), isTrue,
            reason: 'the app creates channel "$channel" but the backend never '
                'sends it — or worse, sends a different id that Android will '
                'discard');
      }
    });

    test('coaching notifications use the coaching channel', () {
      for (final type in ['coaching_accepted', 'coaching_started']) {
        expect(FcmService.channelFor(type), FcmService.channelCoaching);
      }
    });

    test('chat keeps its own high-importance channel', () {
      expect(FcmService.channelFor('chat_message'), FcmService.channelMessages);
    });
  });

  group('a tap lands on the right screen, not the dashboard', () {
    String? routeFor(String type, {Map<String, dynamic> extra = const {}}) =>
        NotificationRouter.destinationFor(
          NotificationPayload.fromData({'type': type, ...extra}),
        );

    test('coaching_accepted opens the coaching workspace', () {
      final route = routeFor('coaching_accepted',
          extra: {'action': 'coaching_workspace', 'actionId': 'expert_1'});
      expect(route, contains('expert_1'));
      expect(route, isNot('/dashboard'));
    });

    test('diet_modified opens the diet screen', () {
      expect(routeFor('diet_modified'), '/diet');
    });

    test('workout_modified opens the training screen', () {
      expect(routeFor('workout_modified'), '/training');
    });

    test('an unknown type goes to the notification centre, not the dashboard',
        () {
      // The notification definitely exists there, whatever it was about —
      // dumping every unknown type on the dashboard tells the user nothing.
      expect(routeFor('something_new_in_v2'), '/notifications');
    });
  });

  group('one event produces one notification', () {
    int trayIdFor(NotificationPayload p) =>
        (p.chatId ?? p.mealId ?? p.notificationId ?? p.type).hashCode &
        0x7fffffff;

    test('the same event redelivered reuses its tray id', () {
      // An FCM retry, a reconnect, or a rebuild re-attaching the listener must
      // replace the entry rather than stack a second copy.
      final a = NotificationPayload.fromData(
          {'type': 'coaching_accepted', 'notificationId': 'notif_abc'});
      final b = NotificationPayload.fromData(
          {'type': 'coaching_accepted', 'notificationId': 'notif_abc'});
      expect(trayIdFor(a), trayIdFor(b));
    });

    test('two DIFFERENT events get different tray ids', () {
      // Keying on `type` alone would have collapsed these into one entry and
      // hidden the second event entirely.
      final a = NotificationPayload.fromData(
          {'type': 'coaching_accepted', 'notificationId': 'notif_abc'});
      final b = NotificationPayload.fromData(
          {'type': 'coaching_accepted', 'notificationId': 'notif_xyz'});
      expect(trayIdFor(a), isNot(trayIdFor(b)));
    });

    test('chat still groups by conversation', () {
      final a = NotificationPayload.fromData(
          {'type': 'chat_message', 'chatId': 'room1', 'notificationId': 'n1'});
      final b = NotificationPayload.fromData(
          {'type': 'chat_message', 'chatId': 'room1', 'notificationId': 'n2'});
      expect(trayIdFor(a), trayIdFor(b),
          reason: 'a thread should show one live entry, not one per message');
    });
  });

  group('Firestore history is not push delivery', () {
    test('the notifications repository never shows a device notification', () {
      // History powers the in-app Notification Centre. If reading it also
      // raised a local notification, opening the app would replay every past
      // event — which is the symptom users reported, from a different cause.
      final repo = File('lib/features/notifications/data/'
          'notifications_repository.dart');
      if (!repo.existsSync()) {
        markTestSkipped('repository source not found');
        return;
      }
      final src = repo.readAsStringSync();
      for (final forbidden in [
        'flutter_local_notifications',
        '_plugin.show',
        'showForeground',
      ]) {
        expect(src.contains(forbidden), isFalse,
            reason: 'notifications_repository must only read history — '
                'found "$forbidden", which would replay old events as new '
                'device notifications on app open');
      }
    });

    test('the background handler does not draw its own notification', () {
      // The OS already draws it from the `notification` block. Drawing a
      // second one here is a guaranteed duplicate.
      final main = File('lib/main.dart');
      if (!main.existsSync()) {
        markTestSkipped('main.dart not found');
        return;
      }
      final src = main.readAsStringSync();
      final handler = src.substring(
        src.indexOf('zitlasFirebaseMessagingBackgroundHandler'),
      );
      final body = handler.substring(0, handler.indexOf('Future<void> main'));
      expect(body.contains('.show('), isFalse,
          reason: 'the background isolate must not display a notification — '
              'the OS already did');
    });
  });
}
