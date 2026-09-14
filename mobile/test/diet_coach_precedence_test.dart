import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/features/coaching/data/coaching_plan_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_checkin_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_photo_uploader.dart';
import 'package:zitlas_mobile/features/coaching/models/coach_diet_plan.dart';
import 'package:zitlas_mobile/features/diet/data/diet_repository.dart';
import 'package:zitlas_mobile/features/diet/diet_controller.dart';
import 'package:zitlas_mobile/features/diet/models/diet_storage.dart';
import 'package:zitlas_mobile/features/diet/presentation/screens/diet_screen.dart';
import 'package:zitlas_mobile/features/diet/presentation/widgets/coach_diet_card.dart';
import 'package:zitlas_mobile/features/diet/presentation/widgets/diet_empty_state.dart';
import 'package:zitlas_mobile/features/expert_dashboard/models/expert_models.dart';
import 'package:zitlas_mobile/features/experts/data/experts_repository.dart';

/// The controller applies THE shared precedence rule
/// (`lib/features/diet/diet_precedence.dart`, pinned against the website by
/// `tests/fixtures/diet_precedence_cases.json`). These pin the app-specific
/// consequences: a coached athlete WITHOUT an AI plan sees the coaching diet
/// (never "No Plan Yet"), a null planId never hides it, and when coaching
/// ends the accepted expert plan is the diet again.

class _FakeAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

CoachDietPlan _coachDiet({String? planId, bool withOptions = true}) => CoachDietPlan(
      planId: planId,
      days: [
        CoachDietDay(day: 'Monday', meals: [
          CoachMeal(
            id: 'breakfast',
            name: 'Breakfast',
            options: withOptions
                ? const [CoachMealOption(name: 'COACH: paneer bhurji', calories: 520)]
                : const [],
          ),
        ]),
      ],
    );

CoachingRelationship _rel({String status = 'active', String planType = 'diet', DateTime? end}) =>
    CoachingRelationship(
      id: 'athlete-1',
      status: status,
      planType: planType,
      coachId: 'coach-9',
      athleteId: 'athlete-1',
      endDate: end,
    );

DietStorage _expertPlan() => DietStorage.fromMap({
      'originalDietPlan': {
        'days': [
          {'day': 'Monday', 'meals': [{'meal_name': 'Breakfast', 'foods': ['Poha']}]},
        ],
      },
      'currentDietPlan': {
        'days': [
          {'day': 'Monday', 'meals': [{'meal_name': 'Breakfast', 'foods': ['Egg bhurji']}]},
        ],
      },
      'isExpertPlan': true,
      'planSource': 'expert_reviewed',
      'planId': 'plan-live',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DietController c;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final db = FakeFirebaseFirestore();
    c = DietController(
      uid: 'athlete-1',
      repository: DietRepository(firestore: db),
      coachingPlans: CoachingPlanRepository(firestore: db),
      experts: ExpertsRepository(firestore: db, auth: _FakeAuth()),
      mealCheckins: MealCheckinRepository(
        firestore: db,
        uploader: MealPhotoUploader(auth: _FakeAuth()),
      ),
    );
  });
  tearDown(() => c.dispose());

  /// The controller's listeners deliver their first (empty) snapshots after
  /// construction and would overwrite anything assigned earlier — so yield,
  /// then seed.
  Future<void> seed({
    String? livePlanId = 'plan-live',
    CoachDietPlan? diet,
    String planCoach = 'coach-9',
    CoachingRelationship? rel,
    DietStorage? storage,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    c.livePlanId = livePlanId;
    c.coachPlan = CoachingPlanDoc(
      diet: diet ?? _coachDiet(),
      exists: true,
      coachId: planCoach,
      coachName: 'Coach Rahul',
    );
    c.coachRelationship = rel ?? _rel();
    c.dietStorage = storage;
    c.loading = false;
  }

  Widget screen() => MaterialApp(
        home: Scaffold(body: DietContent(controller: c, userName: 'Rohit')),
      );

  group('coached WITHOUT an AI plan', () {
    test('the active coaching diet is the diet', () async {
      await seed();
      expect(c.effectivePlan, isNull, reason: 'no AI plan at all');
      expect(c.activeCoachDiet, isNotNull);
    });

    testWidgets('the Diet tab shows the coaching diet — never "No Plan Yet"', (tester) async {
      await tester.runAsync(() => seed());
      await tester.pumpWidget(screen());

      expect(find.byType(DietEmptyState), findsNothing);
      expect(find.byKey(const Key('dietCoachOnly')), findsOneWidget);
      expect(find.byType(CoachDietCard), findsOneWidget);
    });

    testWidgets('with no coaching and no AI plan, "No Plan Yet" is still right', (tester) async {
      await tester.runAsync(() => seed(rel: _rel(status: 'ended')));
      await tester.pumpWidget(screen());

      expect(find.byType(DietEmptyState), findsOneWidget);
      expect(find.byType(CoachDietCard), findsNothing);
    });
  });

  group('the plan-id safety rule — only two present, different ids disagree', () {
    test('a coaching diet with no planId shows under any live plan', () async {
      await seed(diet: _coachDiet(planId: null));
      expect(c.activeCoachDiet, isNotNull);
    });

    test('an athlete with no live planId still sees a stamped coaching diet', () async {
      await seed(diet: _coachDiet(planId: 'plan-live'), livePlanId: null);
      expect(c.activeCoachDiet, isNotNull);
    });

    test('a coaching diet stamped for a DIFFERENT plan is hidden', () async {
      await seed(diet: _coachDiet(planId: 'plan-old'));
      expect(c.activeCoachDiet, isNull);
    });

    test("a plan written by a previous coach is not the current coach's", () async {
      await seed(planCoach: 'coach-old');
      expect(c.activeCoachDiet, isNull);
    });

    test('a named meal counts as published, as on the website', () async {
      await seed(diet: _coachDiet(withOptions: false));
      expect(c.activeCoachDiet, isNotNull);
    });

    test('a coaching diet with no meals at all is not a diet', () async {
      await seed(diet: const CoachDietPlan(days: [CoachDietDay(day: 'Monday')]));
      expect(c.activeCoachDiet, isNull);
    });
  });

  group('the expert-reviewed plan is the fallback', () {
    test('when coaching ends, the accepted expert plan is the diet again', () async {
      await seed(rel: _rel(status: 'ended'), storage: _expertPlan());
      expect(c.activeCoachDiet, isNull);
      expect(c.effectivePlan!.days.single.meals.single.foods, ['Egg bhurji']);
    });

    test('past its end date, the same', () async {
      await seed(
        rel: _rel(end: DateTime.now().subtract(const Duration(minutes: 1))),
        storage: _expertPlan(),
      );
      expect(c.activeCoachDiet, isNull);
      expect(c.effectivePlan, isNotNull);
    });

    test('while coaching is active, the coaching diet is the one in force', () async {
      await seed(storage: _expertPlan());
      expect(c.activeCoachDiet, isNotNull);
      expect(c.effectivePlan, isNotNull, reason: 'the accepted plan is kept underneath, not deleted');
    });
  });

  group('from the real listeners', () {
    test("a coached athlete with no AI plan opens on today's coaching day", () async {
      // Everything arrives the way it does in production: the relationship
      // (personal_coaching/{uid}), the coach's week (coaching_plans/{uid}) and
      // a user doc with a planId but no diet plan.
      final db = FakeFirebaseFirestore();
      const week = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      await db.collection('users').doc('athlete-2').set({'planId': 'plan-live'});
      await db.collection('personal_coaching').doc('athlete-2').set({
        'status': 'active',
        'coachId': 'coach-9',
        'planType': 'complete',
        'athleteId': 'athlete-2',
      });
      await db.collection('coaching_plans').doc('athlete-2').set({
        'coachId': 'coach-9',
        'dietVersion': 1,
        'diet': CoachDietPlan(days: [
          for (final d in week)
            CoachDietDay(day: d, meals: const [
              CoachMeal(id: 'm0', name: 'Breakfast', options: [CoachMealOption(name: 'Poha')]),
            ]),
        ]).toMap(),
      });

      final coached = DietController(
        uid: 'athlete-2',
        repository: DietRepository(firestore: db),
        coachingPlans: CoachingPlanRepository(firestore: db),
        experts: ExpertsRepository(firestore: db, auth: _FakeAuth()),
        mealCheckins: MealCheckinRepository(
          firestore: db,
          uploader: MealPhotoUploader(auth: _FakeAuth()),
        ),
      );
      addTearDown(coached.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(coached.effectivePlan, isNull);
      expect(coached.activeCoachDiet, isNotNull);
      expect(coached.selectedDayIndex, DateTime.now().weekday - 1);
    });
  });
}
