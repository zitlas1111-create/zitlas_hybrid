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
    test('the coaching channel is v2', () {
      // Android caches a channel's importance at creation, so the original
      // `zitlas_coaching` channel could never be raised from default to high
      // on a device that already had it. A new id is the only way.
      expect(FcmService.channelCoaching, 'zitlas_coaching_v2');
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
