import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/features/coaching/data/coaching_plan_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_checkin_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_photo_uploader.dart';
import 'package:zitlas_mobile/features/coaching/models/coach_diet_plan.dart';
import 'package:zitlas_mobile/features/diet/data/diet_repository.dart';
import 'package:zitlas_mobile/features/diet/diet_controller.dart';
import 'package:zitlas_mobile/features/expert_dashboard/models/expert_models.dart';
import 'package:zitlas_mobile/features/experts/data/experts_repository.dart';

/// A coach-authored DIET is active only while the coaching relationship is.
///
/// `activeCoachDiet` previously consulted only the plan document — never the
/// relationship — so once coaching ended the coach's diet kept rendering
/// forever and the athlete had no route back to their own AI/expert-reviewed
/// plan. The TRAINING side already gated on the relationship, which is exactly
/// why Training behaved correctly after coaching ended while Diet did not.
///
/// The `coaching_plans` document is never written or deleted by this path:
/// deactivation is a visibility decision, so history survives for audit.

class _FakeAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

CoachDietPlan _coachDiet({String? planId = 'plan-live'}) => CoachDietPlan(
      planId: planId,
      days: const [
        CoachDietDay(day: 'Monday', meals: [
          CoachMeal(id: 'breakfast', name: 'Breakfast', options: [
            CoachMealOption(name: 'COACH: paneer bhurji + roti', calories: 520),
          ]),
        ]),
      ],
    );

CoachingRelationship _rel(String status, {String planType = 'diet', DateTime? end}) =>
    CoachingRelationship(
      id: 'athlete-1',
      status: status,
      planType: planType,
      coachId: 'coach-9',
      athleteId: 'athlete-1',
      endDate: end,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DietController c;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final fake = FakeFirebaseFirestore();
    c = DietController(
      uid: 'athlete-1',
      repository: DietRepository(firestore: fake),
      coachingPlans: CoachingPlanRepository(firestore: fake),
      experts: ExpertsRepository(firestore: fake, auth: _FakeAuth()),
      mealCheckins: MealCheckinRepository(
        firestore: fake,
        uploader: MealPhotoUploader(auth: _FakeAuth()),
      ),
    );
  });
  tearDown(() => c.dispose());

  /// The controller attaches live Firestore listeners in its constructor, and
  /// the empty-collection snapshot lands AFTER setUp — clobbering any fixture
  /// assigned there. Yield once so those have fired, then seed.
  Future<void> seed({String? planId = 'plan-live'}) async {
    await Future<void>.delayed(Duration.zero);
    c.livePlanId = 'plan-live';
    c.coachPlan = CoachingPlanDoc(
      diet: _coachDiet(planId: planId), exists: true, coachId: 'coach-9');
  }

  group('ACTIVE coaching — coach diet is the active plan', () {
    test('active + diet shows the coach plan', () async {
      await seed();
      c.coachRelationship = _rel('active');
      expect(c.activeCoachDiet, isNotNull);
      expect(c.hasCoachDiet, isTrue);
      expect(c.activeCoachDiet!.days.single.meals.single.options.single.name,
          'COACH: paneer bhurji + roti');
    });

    test('active + complete (diet AND training) shows it', () async {
      await seed();
      c.coachRelationship = _rel('active', planType: 'complete');
      expect(c.activeCoachDiet, isNotNull);
    });

    test('active + TRAINING-only does not own the diet', () async {
      await seed();
      c.coachRelationship = _rel('active', planType: 'training');
      expect(c.activeCoachDiet, isNull);
    });
  });

  group('ENDED coaching — coach diet is NOT active (the reported bug)', () {
    test('ended hides the coach diet', () async {
      await seed();
      c.coachRelationship = _rel('ended');
      expect(c.activeCoachDiet, isNull);
      expect(c.hasCoachDiet, isFalse);
    });

    test('ended + complete hides it too', () async {
      await seed();
      c.coachRelationship = _rel('ended', planType: 'complete');
      expect(c.activeCoachDiet, isNull);
    });

    test('every non-active status hides it', () async {
      await seed();
      for (final s in ['ended', 'expired', 'reset', 'pending', 'declined', 'withdrawn']) {
        c.coachRelationship = _rel(s);
        expect(c.activeCoachDiet, isNull, reason: 'status=$s must not prescribe');
      }
    });

    test('an active status PAST its end date also hides it', () async {
      await seed();
      // isActive is status == 'active' AND not past endDate.
      c.coachRelationship =
          _rel('active', end: DateTime.now().subtract(const Duration(days: 1)));
      expect(c.activeCoachDiet, isNull);
    });

    test('NO relationship at all hides it', () async {
      await seed();
      c.coachRelationship = null;
      expect(c.activeCoachDiet, isNull);
    });
  });

  group('nothing is destroyed — history and the AI plan survive', () {
    test('the coaching_plans document is left fully intact', () async {
      await seed();
      c.coachRelationship = _rel('ended');
      expect(c.activeCoachDiet, isNull);
      // Deactivation is visibility only: the doc still holds the coach's work.
      expect(c.coachPlan, isNotNull);
      expect(c.coachPlan!.exists, isTrue);
      expect(c.coachPlan!.diet.hasDays, isTrue);
      expect(c.coachPlan!.diet.days.single.meals.single.options.single.name,
          'COACH: paneer bhurji + roti');
    });

    test('reading the gate repeatedly never mutates the plan', () async {
      await seed();
      c.coachRelationship = _rel('ended');
      for (var i = 0; i < 5; i++) {
        expect(c.activeCoachDiet, isNull);
      }
      expect(c.coachPlan!.diet.days.length, 1);
    });

    test('the athlete AI/expert plan wrapper is untouched by the gate', () async {
      await seed();
      // activeCoachDiet must never write dietStorage.
      final before = c.dietStorage;
      c.coachRelationship = _rel('ended');
      expect(c.activeCoachDiet, isNull);
      expect(c.dietStorage, same(before));
    });
  });

  group('resurrection is impossible — the gate is recomputed every read', () {
    test('re-delivering the plan doc after "reload" still refuses it', () async {
      await seed();
      // A page refresh, WebView reload and app restart all re-enter through
      // this same getter, so there is no cached "active" verdict to resurrect.
      c.coachRelationship = _rel('ended');
      expect(c.activeCoachDiet, isNull);
      c.coachPlan = CoachingPlanDoc(diet: _coachDiet(), exists: true, coachId: 'coach-9');
      expect(c.activeCoachDiet, isNull, reason: 're-delivering the doc must not revive it');
    });

    test('a NEW active engagement re-activates cleanly', () async {
      await seed();
      c.coachRelationship = _rel('ended');
      expect(c.activeCoachDiet, isNull);
      c.coachRelationship = _rel('active');
      expect(c.activeCoachDiet, isNotNull, reason: 'renewed coaching must work');
    });

    test('a stale-goal plan stays retired even while coaching is active', () async {
      await seed();
      // The planId guard is independent of relationship status.
      await seed(planId: 'plan-OLD');
      c.coachRelationship = _rel('active');
      expect(c.activeCoachDiet, isNull);
    });
  });
}
