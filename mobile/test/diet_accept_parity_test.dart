import 'dart:convert';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/features/coaching/data/coaching_plan_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_checkin_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_photo_uploader.dart';
import 'package:zitlas_mobile/features/diet/data/diet_repository.dart';
import 'package:zitlas_mobile/features/diet/diet_controller.dart';
import 'package:zitlas_mobile/features/diet/models/diet_review_request.dart';
import 'package:zitlas_mobile/features/experts/data/experts_repository.dart';

/// Lossless expert-review Accept — the app side.
///
/// `tests/fixtures/diet_accept_case.json` (repository root) is the SAME case
/// the website runs through `buildAcceptedStorage()` in
/// `tests/js/diet-review.test.mjs`: a renamed, an added and a deleted meal,
/// carbs/fats/timing/notes, day- and plan-level fields, and an older review
/// whose meals are an object. Both clients must store exactly its
/// `expected.currentDietPlan` and `expected.expertModifications` in
/// `users/{uid}.dietPlan` — so an Accept made on either survives on the other.
/// `tests/fixtures/diet_history_cases.json` pins review history the same way.

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('../tests/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

final _case = _fixture('diet_accept_case.json');
final _history = _fixture('diet_history_cases.json');

Map<String, dynamic> _clone(Object? v) => (jsonDecode(jsonEncode(v)) as Map).cast<String, dynamic>();

class _FakeAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uid = 'athlete-1';
  final expected = _case['expected'] as Map<String, dynamic>;
  final planData = (_case['review'] as Map)['planData'];

  late FakeFirebaseFirestore db;
  final open = <DietController>[];

  DietController controller() {
    final c = DietController(
      uid: uid,
      repository: DietRepository(firestore: db),
      coachingPlans: CoachingPlanRepository(firestore: db),
      experts: ExpertsRepository(firestore: db, auth: _FakeAuth()),
      mealCheckins: MealCheckinRepository(
        firestore: db,
        uploader: MealPhotoUploader(auth: _FakeAuth()),
      ),
    );
    open.add(c);
    return c;
  }

  /// Lets the controller's Firestore listeners deliver.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  DietReviewRequest review([Map<String, dynamic> overrides = const {}]) {
    final raw = _clone(_case['review'])..addAll(overrides);
    return DietReviewRequest.fromMap(raw['id'] as String, raw);
  }

  Future<Map<String, dynamic>?> stored() async =>
      ((await db.collection('users').doc(uid).get()).data()?['dietPlan'] as Map?)?.cast<String, dynamic>();

  List<List<String>> mealNames(DietController c) => [
        for (final d in c.effectivePlan!.days) [for (final m in d.meals) m.mealName],
      ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = FakeFirebaseFirestore();
    await db.collection('users').doc(uid).set({'planId': _case['livePlanId']});
    final r = _clone(_case['review']);
    await db.collection('review_requests').doc(r['id'] as String).set(r);
  });

  tearDown(() {
    for (final c in open) {
      c.dispose();
    }
    open.clear();
  });

  group('lossless Accept — the shared fixture (identical on the website)', () {
    test('stores the COMPLETE reviewed plan, exactly', () async {
      final c = controller();
      await settle();

      await c.acceptExpertReview(review());

      final w = (await stored())!;
      expect(w['currentDietPlan'], expected['currentDietPlan']);
      expect(w['expertModifications'], expected['expertModifications']);
      expect(w['planId'], expected['planId']);
      expect(w['isExpertPlan'], isTrue);
      expect(w['planSource'], 'expert_reviewed');
      expect(w['originalDietPlan'], planData);
      final r = await db.collection('review_requests').doc('rev_accept_1').get();
      expect(r.data()!['athleteAccepted'], isTrue);
    });

    test('renamed, added and deleted meals survive the listener refresh, field for field', () async {
      final c = controller();
      await settle();
      await c.acceptExpertReview(review());
      await settle();

      expect(c.dietStorage, isNotNull, reason: 'a stamped accepted plan is never discarded');
      expect(mealNames(c), expected['effectiveMealNames']);
      final monday = c.effectivePlan!.days[0].meals;
      expect(monday.map((m) => m.mealName), isNot(contains('Snack')), reason: 'deleted stays deleted');
      expect(monday[0].carbsG, 30);
      expect(monday[0].fatG, 16);
      expect(monday[0].time, '08:00');
      expect(monday[0].notes, 'Swap poha for eggs');
      expect(monday[0].expertModified, isTrue);
      expect(monday[1].expertModified, isFalse, reason: 'an unchanged meal gets no badge');
      expect(monday[3].notes, 'Within 30 minutes of training');
      // What the listener parsed re-saves without losing anything.
      expect(c.dietStorage!.toMap()['currentDietPlan'], expected['currentDietPlan']);
    });

    test('survives an app restart', () async {
      final first = controller();
      await settle();
      await first.acceptExpertReview(review());
      first.dispose();
      open.remove(first);

      final second = controller();
      await settle();
      expect(mealNames(second), expected['effectiveMealNames']);
      expect(second.dietStorage!.isExpertPlan, isTrue);
    });

    test('website → app: the wrapper the website writes renders the same plan', () async {
      await db.collection('users').doc(uid).set({
        'planId': 'plan-live',
        'dietPlan': {
          'originalDietPlan': planData,
          'currentDietPlan': expected['currentDietPlan'],
          'expertModifications': expected['expertModifications'],
          'isExpertPlan': true,
          'expertName': 'Dr. Meera',
          'planSource': 'expert_reviewed',
          'reviewId': 'rev_accept_1',
          'planId': 'plan-live',
          'acceptedPlanFormat': 'complete_v1',
        },
      });

      final c = controller();
      await settle();

      expect(mealNames(c), expected['effectiveMealNames']);
      final tuesdayLunch = c.effectivePlan!.days[1].meals[1];
      expect(tuesdayLunch.proteinG, 26);
      expect(tuesdayLunch.foods, ['Rajma', 'Brown rice', 'Curd']);
      expect(tuesdayLunch.expertModified, isTrue);
    });

    test('the plan the athlete already had stays the original; the content is still the review', () async {
      final aiPlan = {
        'planId': 'plan-live',
        'days': [
          {
            'day': 'Monday',
            'meals': [
              {'meal_name': 'Breakfast', 'foods': ['Idli'], 'calories': 200, 'protein_g': 6},
            ],
          },
        ],
      };
      await db.collection('users').doc(uid).set({
        'planId': 'plan-live',
        'dietPlan': {'originalDietPlan': aiPlan, 'currentDietPlan': aiPlan, 'planId': 'plan-live'},
      });
      final c = controller();
      await settle();

      await c.acceptExpertReview(review());

      final w = (await stored())!;
      expect(w['currentDietPlan'], expected['currentDietPlan']);
      expect(w['originalDietPlan'], aiPlan);
    });

    test('a review for a previous plan is refused and writes nothing', () async {
      final c = controller();
      await settle();

      await expectLater(
        c.acceptExpertReview(review({'planId': 'plan-old'})),
        throwsA(isA<DietAcceptException>()),
      );
      expect(await stored(), isNull);
      final r = await db.collection('review_requests').doc('rev_accept_1').get();
      expect(r.data()!['athleteAccepted'], isNull);
    });

    test('a plan that cannot be stamped is refused — not written and then discarded', () async {
      await db.collection('users').doc(uid).set({});
      final c = controller();
      await settle();

      await expectLater(
        c.acceptExpertReview(review({'planId': null})),
        throwsA(isA<DietAcceptException>()),
      );
      expect(await stored(), isNull);
    });

    test('a review with no reviewed plan is refused', () async {
      final c = controller();
      await settle();
      await expectLater(
        c.acceptExpertReview(review({'reviewedDietPlan': null})),
        throwsA(isA<DietAcceptException>()),
      );
      expect(await stored(), isNull);
    });
  });

  group('review history — every stored shape reads the same (shared fixture)', () {
    final want = _history['expected'] as Map<String, dynamic>;
    final labels = (_history['labels'] as List).cast<String>();
    final records = (_history['records'] as List).cast<Map<String, dynamic>>();

    for (var i = 0; i < records.length; i++) {
      test(labels[i], () {
        final e = MealChangeEntry.fromMap(records[i]);
        expect(e.dayIndex, want['dayIndex']);
        expect(e.dayLabel, want['dayLabel']);
        expect(e.mealName, want['mealName']);
        expect(e.mealKey, want['mealKey']);
        expect(e.oldFoods, want['oldFoods']);
        expect(e.newFoods, want['newFoods']);
        expect(e.oldCalories, want['oldCalories']);
        expect(e.newCalories, want['newCalories']);
        expect(e.oldProtein, want['oldProtein']);
        expect(e.newProtein, want['newProtein']);
        expect(e.reason, want['reason']);
        expect(e.modifiedBy, want['modifiedBy']);
        expect(e.modifiedAt, want['modifiedAt']);
      });
    }

    test('a present flat list wins over the nested meal, even when empty', () {
      final e = MealChangeEntry.fromMap({
        'mealName': 'Dinner',
        'newFoods': <String>[],
        'newMeal': {'foods': ['Something else']},
      });
      expect(e.newFoods, isEmpty);
    });

    test('one review may carry both shapes', () {
      final r = DietReviewRequest.fromMap('r1', {
        'status': 'review_completed',
        'mealChangeHistory': records,
      });
      expect(r.mealChangeHistory, hasLength(records.length));
      expect(r.mealChangeHistory.map((e) => e.newFoods), everyElement(want['newFoods']));
    });
  });
}
