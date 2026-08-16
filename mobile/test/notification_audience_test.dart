import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/core/notifications/notification_audience.dart';
import 'package:zitlas_mobile/core/notifications/notification_payload.dart';
import 'package:zitlas_mobile/core/notifications/notification_router.dart';

/// Role isolation.
///
/// ZITLAS runs two completely different notification experiences on one
/// codebase and one device. The failure these guard against is concrete and
/// was live: every athlete reminder slot was scheduled from `main()` before
/// authentication resolved, so experts received breakfast, lunch, snack and
/// dinner reminders daily.

void main() {
  group('athletes get athlete notifications', () {
    const athleteTypes = [
      'meal_reminder', 'breakfast_reminder', 'lunch_reminder',
      'dinner_reminder', 'snack_reminder', 'pre_workout_meal',
      'post_workout_meal', 'water_reminder', 'workout_reminder',
      'workout_completed', 'step_goal', 'step_goal_achieved', 'streak',
      'milestone', 'motivation', 'diet_modified', 'workout_modified',
      'review_completed', 'expert_accepted', 'expert_message',
      'zino_message', 'health_status_sick', 'health_status_injured',
    ];

    test('every athlete type reaches an athlete', () {
      for (final t in athleteTypes) {
        expect(isForRole(t, 'athlete'), isTrue, reason: '$t should reach an athlete');
      }
    });

    test('NO athlete type reaches an expert', () {
      for (final t in athleteTypes) {
        expect(isForRole(t, 'expert'), isFalse, reason: '$t must NOT reach an expert');
      }
    });

    test('an expert is never told to eat breakfast', () {
      // The exact production bug, named.
      expect(isForRole('breakfast_reminder', 'expert'), isFalse);
      expect(isForRole('dinner_reminder', 'expert'), isFalse);
      expect(isForRole('workout_reminder', 'expert'), isFalse);
      expect(isForRole('step_goal', 'expert'), isFalse);
    });
  });

  group('experts get expert notifications', () {
    const expertTypes = [
      'expert_request', 'coaching_request', 'review_pending',
      'diet_review_pending', 'workout_review_pending', 'meal_review_pending',
      'meal_checkin', 'client_unwell', 'client_needs_attention',
      'consultation_reminder', 'consultation_requested', 'rating_received',
      'rating_updated', 'expert_verification', 'expert_approved',
      'expert_rejected', 'wellness_plan_adjusted',
    ];

    test('every expert type reaches an expert', () {
      for (final t in expertTypes) {
        expect(isForRole(t, 'expert'), isTrue, reason: '$t should reach an expert');
      }
    });

    test('NO expert type reaches an athlete', () {
      for (final t in expertTypes) {
        expect(isForRole(t, 'athlete'), isFalse, reason: '$t must NOT reach an athlete');
      }
    });

    test('an athlete is never told a client is waiting', () {
      expect(isForRole('review_pending', 'athlete'), isFalse);
      expect(isForRole('client_unwell', 'athlete'), isFalse);
      expect(isForRole('rating_received', 'athlete'), isFalse);
    });
  });

  group('shared types reach both roles', () {
    test('chat reaches whoever is signed in', () {
      // One event, two destinations — resolved by recipientRole in the
      // router, not by suppressing it for one side.
      expect(isForRole('chat_message', 'athlete'), isTrue);
      expect(isForRole('chat_message', 'expert'), isTrue);
    });

    test('account and security notices are never filtered out', () {
      for (final t in ['account_security', 'system']) {
        expect(isForRole(t, 'athlete'), isTrue);
        expect(isForRole(t, 'expert'), isTrue);
      }
    });
  });

  group('unknown and malformed types fail OPEN, not closed', () {
    test('an unrecognised type is shown to both roles', () {
      // A new backend event must never be silently swallowed by a client
      // that predates it — a missed notification is worse than a
      // mis-categorised one, and the server already targets by token.
      expect(isForRole('some_future_event', 'athlete'), isTrue);
      expect(isForRole('some_future_event', 'expert'), isTrue);
      expect(audienceFor('some_future_event'), NotificationAudience.both);
    });

    test('a null or empty type is shown rather than dropped', () {
      expect(isForRole(null, 'athlete'), isTrue);
      expect(isForRole('', 'expert'), isTrue);
    });

    test('an unknown ROLE is treated as an athlete', () {
      // Only 'expert' is ever produced for the expert side by
      // UserModel.resolvedRole; anything else is the athlete experience.
      expect(isForRole('meal_reminder', null), isTrue);
      expect(isForRole('review_pending', null), isFalse);
    });
  });

  group('no type is claimed by both roles at once', () {
    test('the registry never marks a type athlete AND expert', () {
      for (final entry in kNotificationAudience.entries) {
        final a = isForRole(entry.key, 'athlete');
        final e = isForRole(entry.key, 'expert');
        if (entry.value == NotificationAudience.both) {
          expect(a && e, isTrue, reason: '${entry.key} should reach both');
        } else {
          expect(a && e, isFalse, reason: '${entry.key} leaks across roles');
          expect(a || e, isTrue, reason: '${entry.key} reaches nobody');
        }
      }
    });
  });

  group('every classified type deep-links somewhere specific', () {
    String? destination(String type, {String? role}) => NotificationRouter.destinationFor(
          NotificationPayload.fromData({
            'type': type,
            if (role != null) 'recipientRole': role,
          }),
        );

    test('plan changes open the screen that changed', () {
      expect(destination('diet_modified'), '/diet');
      expect(destination('workout_modified'), '/training');
      // The coach-facing wellness alert belongs to the EXPERT, and lands on
      // the dashboard where they can open the client. The athlete's own
      // confirmation is a separate `health_status_*` notification.
      expect(destination('wellness_plan_adjusted', role: 'coach'), '/expert-dashboard');
      expect(destination('health_status_sick'), '/dashboard');
      expect(destination('health_status_injured'), '/dashboard');
    });

    test('reminders open where the athlete can act', () {
      expect(destination('meal_reminder'), '/diet');
      expect(destination('pre_workout_meal'), '/diet');
      expect(destination('workout_reminder'), '/training');
      expect(destination('step_goal_achieved'), '/dashboard');
      expect(destination('milestone'), '/dashboard');
    });

    test('expert work opens the expert dashboard', () {
      for (final t in [
        'expert_request', 'review_pending', 'client_unwell',
        'consultation_reminder', 'rating_received', 'expert_verification',
      ]) {
        expect(destination(t), '/expert-dashboard', reason: t);
      }
    });

    test('no classified type falls through to the home screen', () {
      // "Do not just open the app home screen for everything."
      for (final type in kNotificationAudience.keys) {
        final role = audienceFor(type) == NotificationAudience.expert ? 'coach' : null;
        final d = destination(type, role: role);
        expect(d, isNotNull, reason: '$type has no destination');
      }
    });
  });
}
