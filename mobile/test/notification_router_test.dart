import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/core/notifications/notification_payload.dart';
import 'package:zitlas_mobile/core/notifications/notification_router.dart';

/// Proves the notification -> destination mapping, which is the part of the
/// push pipeline that decides whether a tap lands on the right screen.
/// `destinationFor` is deliberately pure so this needs no widget tree, no
/// Firebase, and no device.
void main() {
  String? dest(Map<String, dynamic> data) =>
      NotificationRouter.destinationFor(NotificationPayload.fromData(data));

  group('chat_message', () {
    test('athlete lands in their coach\'s Website workspace with chat open', () {
      expect(
        dest({
          'type': 'chat_message',
          'recipientRole': 'athlete',
          'counterpartId': 'coach9',
          'chatId': 'chat_a1_coach9',
        }),
        '/coach-profile/coach9?action=ask',
      );
    });

    test('coach lands on their dashboard — same message, different side', () {
      expect(
        dest({
          'type': 'chat_message',
          'recipientRole': 'coach',
          'counterpartId': 'athlete1',
          'chatId': 'chat_athlete1_c9',
        }),
        '/expert-dashboard',
      );
    });

    test('falls back to senderId when counterpartId is absent', () {
      expect(
        dest({'type': 'chat_message', 'recipientRole': 'athlete', 'senderId': 'coach7'}),
        '/coach-profile/coach7?action=ask',
      );
    });

    test('never dead-ends when no coach id can be resolved', () {
      expect(dest({'type': 'chat_message', 'recipientRole': 'athlete'}), '/experts');
    });
  });

  group('meal reviews', () {
    // A rated meal used to land on /diet, which shows the PLAN — not the
    // coach's feedback. The notification's whole content was the one thing
    // its destination did not contain. Both sides now open the Meal Reviews
    // tab of the coaching workspace, using the ?cwAthlete=/?cwTab= params
    // the deployed website already restores from.

    test('a completed review opens the meal reviews tab, not the diet plan',
        () {
      // Exactly what routes/notifications.py notify_meal_review sends.
      expect(
        dest({
          'type': 'meal_review_completed',
          'mealId': 'MCI_1',
          'coachId': 'COACH_9',
          'athleteId': 'ATH_1',
          'rating': '4.0',
        }),
        '/coach-profile/COACH_9?cwTab=checkins&cwCheckin=MCI_1',
      );
    });

    test('a pending meal opens that athlete in the expert workspace', () {
      expect(
        dest({
          'type': 'meal_review_pending',
          'mealId': 'MCI_1',
          'athleteId': 'ATH_1',
        }),
        '/expert-dashboard?cwAthlete=ATH_1&cwTab=checkins&cwCheckin=MCI_1',
      );
    });

    test('counterpartId works when the explicit id is absent', () {
      expect(dest({'type': 'meal_reviewed', 'counterpartId': 'COACH_9'}),
          '/coach-profile/COACH_9?cwTab=checkins');
      expect(dest({'type': 'meal_checkin', 'counterpartId': 'ATH_1'}),
          '/expert-dashboard?cwAthlete=ATH_1&cwTab=checkins');
    });

    test('an id-less payload still lands somewhere useful', () {
      // Older notification documents predate these fields. A deep link that
      // cannot be built must degrade, never dead-end.
      expect(dest({'type': 'meal_review_pending', 'mealId': 'MCI_1'}),
          '/expert-dashboard');
      expect(dest({'type': 'meal_review_completed', 'mealId': 'MCI_1'}),
          '/diet');
      expect(dest({'type': 'meal_checkin'}), '/expert-dashboard');
      expect(dest({'type': 'meal_reviewed'}), '/diet');
    });
  });

  group('plans stay native', () {
    test('diet_updated -> /diet', () {
      expect(dest({'type': 'diet_updated'}), '/diet');
    });
    test('workout_updated -> /training', () {
      expect(dest({'type': 'workout_updated'}), '/training');
    });
  });

  group('coaching lifecycle', () {
    test('athlete coaching event opens the Website coach profile, not a native screen', () {
      expect(
        dest({'type': 'coaching_accepted', 'recipientRole': 'athlete', 'coachId': 'c5'}),
        '/coach-profile/c5',
      );
    });
    test('coach-side coaching event opens the dashboard', () {
      expect(
        dest({'type': 'coaching_request_received', 'recipientRole': 'coach'}),
        '/expert-dashboard',
      );
    });
    test('payment events route like coaching events', () {
      expect(
        dest({'type': 'payment_success', 'recipientRole': 'athlete', 'coachId': 'c5'}),
        '/coach-profile/c5',
      );
    });
  });

  group('legacy notification-centre action keys', () {
    // These predate push; honouring them keeps a pushed notification and an
    // in-app tap landing on the SAME screen.
    test('action=diet / training / dashboard / coaches / profile', () {
      expect(dest({'type': 'x', 'action': 'diet'}), '/diet');
      expect(dest({'type': 'x', 'action': 'training'}), '/training');
      expect(dest({'type': 'x', 'action': 'dashboard'}), '/dashboard');
      expect(dest({'type': 'x', 'action': 'coaches'}), '/experts');
      expect(dest({'type': 'x', 'action': 'profile'}), '/profile');
    });
    test('action=expert_dashboard', () {
      expect(dest({'type': 'x', 'action': 'expert_dashboard'}), '/expert-dashboard');
    });
    test('action=expert_profile uses actionId', () {
      expect(
        dest({'type': 'x', 'action': 'expert_profile', 'actionId': 'e3'}),
        '/coach-profile/e3',
      );
    });
    test('action=chat opens the workspace with chat', () {
      expect(
        dest({'type': 'x', 'action': 'chat', 'actionId': 'e3'}),
        '/coach-profile/e3?action=ask',
      );
    });
  });

  group('fallbacks', () {
    test('zino_message -> /zino', () {
      expect(dest({'type': 'zino_message'}), '/zino');
    });
    test('unknown type with no action falls back to the Notification Centre', () {
      expect(dest({'type': 'something_new'}), '/notifications');
    });
    test('empty data is still safe (defaults to general -> /notifications)', () {
      expect(dest({}), '/notifications');
    });
  });

  group('payload parsing', () {
    test('round-trips through the local-notification payload string', () {
      const original = NotificationPayload(
        type: 'chat_message',
        chatId: 'chat_1_2',
        counterpartId: 'coach9',
        recipientRole: 'athlete',
      );
      final decoded = NotificationPayload.decode(original.encode());
      expect(decoded, isNotNull);
      expect(decoded!.type, 'chat_message');
      expect(decoded.chatId, 'chat_1_2');
      expect(decoded.counterpartId, 'coach9');
      expect(decoded.recipientRole, 'athlete');
    });

    test('FCM string values and null-ish placeholders are normalised', () {
      final p = NotificationPayload.fromData({
        'type': 'chat_message',
        'chatId': '',           // empty -> null
        'senderId': 'null',     // literal "null" from a stringified payload -> null
        'counterpartId': ' c9 ', // trimmed
      });
      expect(p.chatId, isNull);
      expect(p.senderId, isNull);
      expect(p.counterpartId, 'c9');
    });

    test('malformed local payload decodes to null instead of throwing', () {
      expect(NotificationPayload.decode('not json'), isNull);
      expect(NotificationPayload.decode(null), isNull);
      expect(NotificationPayload.decode(''), isNull);
    });
  });

  group('zitlas:// deep links', () {
    // The backend templates now send `deepLink`. It is TRANSLATED, never
    // followed verbatim — the same review opens in different places for the
    // athlete and the expert, which the server cannot know.

    test('the athlete side resolves to their coach workspace', () {
      expect(
        dest({
          'type': 'meal_review_completed',
          'deepLink': 'zitlas://meal-review/MCI_1',
          'coachId': 'COACH_9',
        }),
        '/coach-profile/COACH_9?cwTab=checkins',
      );
    });

    test('the SAME link resolves elsewhere for the expert', () {
      expect(
        dest({
          'type': 'meal_review_completed',
          'deepLink': 'zitlas://meal-review/MCI_1',
          'recipientRole': 'coach',
          'athleteId': 'ATH_1',
        }),
        '/expert-dashboard?cwAthlete=ATH_1&cwTab=checkins',
        reason: 'following the link verbatim would send the expert to the '
            'athlete-side screen',
      );
    });

    test('an unknown link shape falls through to the type switch', () {
      // Lets the backend ship a new link before the app that understands it.
      expect(
        dest({
          'type': 'meal_review_completed',
          'deepLink': 'zitlas://something-new/xyz',
          'coachId': 'COACH_9',
        }),
        '/coach-profile/COACH_9?cwTab=checkins',
      );
    });

    test('a foreign scheme is ignored, not navigated to', () {
      for (final link in [
        'https://evil.example.com/steal',
        'javascript:alert(1)',
        'zitlas:://malformed',
        '',
      ]) {
        final out = dest({
          'type': 'meal_review_completed',
          'deepLink': link,
          'coachId': 'COACH_9',
        });
        expect(out, '/coach-profile/COACH_9?cwTab=checkins',
            reason: '$link must not reach the navigator');
      }
    });

    test('a link with no usable ids still lands somewhere', () {
      expect(dest({'type': 'meal_review_completed',
                   'deepLink': 'zitlas://meal-review/MCI_1'}), '/diet');
    });
  });

  group('the exact meal opens, not just the list', () {
    // /diet showed the plan. The Meal Reviews TAB showed a list. Neither is
    // "the meal the notification was about" — the user still had to find it.
    // cwCheckin is what the website workspace holds until meal_checkins
    // loads, then opens that one sheet.

    test('the athlete lands on the reviewed meal', () {
      expect(
        dest({
          'type': 'meal_review_completed',
          'deepLink': 'zitlas://meal-review/MCI_1',
          'mealId': 'MCI_1',
          'coachId': 'COACH_9',
        }),
        '/coach-profile/COACH_9?cwTab=checkins&cwCheckin=MCI_1',
      );
    });

    test('the expert lands on the meal awaiting review', () {
      expect(
        dest({
          'type': 'meal_review_pending',
          'mealId': 'MCI_7',
          'athleteId': 'ATH_1',
        }),
        '/expert-dashboard?cwAthlete=ATH_1&cwTab=checkins&cwCheckin=MCI_7',
      );
    });

    test('a payload with no meal id still opens the tab', () {
      // Older notification documents predate mealId. Degrade, never dead-end.
      expect(
        dest({'type': 'meal_review_completed', 'coachId': 'COACH_9'}),
        '/coach-profile/COACH_9?cwTab=checkins',
      );
    });

    test('the id comes from the payload, not the link path', () {
      // The path is only as trustworthy as the string the server built;
      // mealId is the field every other consumer already reads.
      expect(
        dest({
          'type': 'meal_review_completed',
          'deepLink': 'zitlas://meal-review/SOMETHING_ELSE',
          'mealId': 'MCI_1',
          'coachId': 'COACH_9',
        }),
        '/coach-profile/COACH_9?cwTab=checkins&cwCheckin=MCI_1',
      );
    });
  });
}
