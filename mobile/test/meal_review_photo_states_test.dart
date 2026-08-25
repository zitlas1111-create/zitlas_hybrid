import 'package:cached_network_image/cached_network_image.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_checkin_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_photo_uploader.dart';
import 'package:zitlas_mobile/features/coaching/presentation/screens/meal_review_screen.dart';

/// WHAT THE NUTRITIONIST SEES WHERE A MEAL PHOTO SHOULD BE.
///
/// The reported bug was a broken-image icon in Meal Reviews. The cause was
/// upstream (Firebase Storage was never provisioned, so uploads fell back to
/// the backend's ephemeral disk and every stored URL later 404'd), but the
/// screen made it worse by having only two outcomes: render the image, or
/// render nothing at all. A coach could not tell "the athlete skipped the
/// photo" from "the platform lost the photo".
///
/// There are THREE states and they must stay distinguishable:
///
///   a loadable URL      -> the photo
///   a URL that fails    -> "Photo unavailable"   (the athlete DID submit one)
///   no URL              -> "No photo submitted"  (they did not)
///
/// The middle case is not hypothetical. Three of the ten production
/// check-ins store a RELATIVE path (`/uploads/chat/…`) written by the website
/// before the fix. `isNetworkImageUrl` rejects those, so the naive version of
/// this screen would have labelled them "No photo submitted" — blaming the
/// athlete for a photo the platform lost.
void main() {
  const coachId = 'coach_1';

  Future<FakeFirebaseFirestore> dbWith(List<Map<String, dynamic>> checkins) async {
    final db = FakeFirebaseFirestore();
    for (var i = 0; i < checkins.length; i++) {
      final c = checkins[i];
      await db.collection('meal_checkins').doc('MCI_$i').set({
        'checkinId': 'MCI_$i',
        'athleteId': 'athlete_1',
        'athleteName': 'Alice',
        'coachId': coachId,
        'day': 'Monday',
        'mealType': c['mealType'],
        'mealName': c['mealName'] ?? c['mealType'],
        'status': 'pending',
        'timestamp': '2026-08-25T09:00:00.000Z',
        if (c.containsKey('imageUrl')) 'imageUrl': c['imageUrl'],
      });
    }
    return db;
  }

  Future<void> pump(WidgetTester tester, FakeFirebaseFirestore db) async {
    // The queue is a lazy ListView and each card is ~190px of photo area, so
    // on the default 600px test viewport a third card is never built and
    // findsNWidgets under-counts. Give it room rather than weakening the
    // assertion to whatever happened to be on screen.
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: MealReviewScreen(
        coachId: coachId,
        coachName: 'pratik',
        repository: MealCheckinRepository(
          firestore: db,
          // Injected so the screen can be built without a Firebase app.
          uploader: MealPhotoUploader(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('a photo that can load', () {
    testWidgets('renders the image, not a placeholder', (tester) async {
      final db = await dbWith([
        {
          'mealType': 'breakfast',
          'imageUrl': 'https://firebasestorage.googleapis.com/v0/b/'
              'zitlas-b8677.firebasestorage.app/o/meal_checkins%2Fathlete_1%2F1.jpg'
              '?alt=media&token=abc',
        },
      ]);
      await pump(tester, db);

      expect(find.byType(CachedNetworkImage), findsOneWidget);
      expect(find.text('No photo submitted'), findsNothing,
          reason: 'a real submitted photo must never be reported as missing');
    });
  });

  group('a photo that was submitted but cannot be shown', () {
    testWidgets('a legacy RELATIVE url says "Photo unavailable"', (tester) async {
      // Exactly the shape of 3 real production records.
      final db = await dbWith([
        {'mealType': 'lunch', 'imageUrl': '/uploads/chat/2d364f40.jpg'},
      ]);
      await pump(tester, db);

      expect(find.text('Photo unavailable'), findsOneWidget);
      expect(find.text('No photo submitted'), findsNothing,
          reason: 'the athlete did submit this photo — the platform lost it');
    });

    testWidgets('a dead absolute url is also "Photo unavailable"', (tester) async {
      final db = await dbWith([
        {'mealType': 'dinner', 'imageUrl': 'https://zitlas.com/uploads/chat/dead.jpg'},
      ]);
      await pump(tester, db);
      expect(find.text('No photo submitted'), findsNothing);
    });
  });

  group('no photo at all', () {
    testWidgets('a null url says "No photo submitted"', (tester) async {
      final db = await dbWith([
        {'mealType': 'dinner', 'imageUrl': null},
      ]);
      await pump(tester, db);

      expect(find.text('No photo submitted'), findsOneWidget);
      expect(find.text('Photo unavailable'), findsNothing);
    });

    testWidgets('an absent field says "No photo submitted"', (tester) async {
      final db = await dbWith([
        {'mealType': 'snack'},
      ]);
      await pump(tester, db);
      expect(find.text('No photo submitted'), findsOneWidget);
    });

    testWidgets('a blank string is not treated as a photo', (tester) async {
      final db = await dbWith([
        {'mealType': 'snack', 'imageUrl': '   '},
      ]);
      await pump(tester, db);
      expect(find.text('No photo submitted'), findsOneWidget,
          reason: 'whitespace is not a submitted photo');
    });
  });

  group('every meal type behaves the same', () {
    for (final meal in ['breakfast', 'lunch', 'dinner', 'snack']) {
      testWidgets('$meal: missing photo is labelled, not silently blank',
          (tester) async {
        final db = await dbWith([
          {'mealType': meal, 'mealName': meal},
        ]);
        await pump(tester, db);
        expect(find.text('No photo submitted'), findsOneWidget,
            reason: '$meal must not render an unexplained empty card');
      });

      testWidgets('$meal: a lost photo is labelled as lost', (tester) async {
        final db = await dbWith([
          {'mealType': meal, 'imageUrl': '/uploads/chat/$meal.jpg'},
        ]);
        await pump(tester, db);
        expect(find.text('Photo unavailable'), findsOneWidget);
      });
    }
  });

  group('the states never collide', () {
    testWidgets('a mixed queue labels each card independently', (tester) async {
      final db = await dbWith([
        {'mealType': 'breakfast', 'imageUrl': '/uploads/chat/lost.jpg'},
        {'mealType': 'lunch'},
        {'mealType': 'dinner', 'imageUrl': '/uploads/chat/lost2.jpg'},
      ]);
      await pump(tester, db);

      expect(find.text('Photo unavailable'), findsNWidgets(2));
      expect(find.text('No photo submitted'), findsOneWidget);
    });
  });
}
