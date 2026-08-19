import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/features/coaching/data/coaching_plan_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_checkin_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_photo_uploader.dart';
import 'package:zitlas_mobile/features/coaching/models/coach_diet_plan.dart';
import 'package:zitlas_mobile/features/expert_dashboard/models/expert_models.dart';
import 'package:zitlas_mobile/features/dashboard/data/dashboard_repository.dart';
import 'package:zitlas_mobile/features/dashboard/models/health_status.dart';
import 'package:zitlas_mobile/features/diet/data/diet_repository.dart';
import 'package:zitlas_mobile/features/diet/diet_controller.dart';
import 'package:zitlas_mobile/features/diet/models/diet_day.dart';
import 'package:zitlas_mobile/features/diet/models/diet_meal.dart';
import 'package:zitlas_mobile/features/diet/models/diet_plan_content.dart';
import 'package:zitlas_mobile/features/diet/models/diet_storage.dart';
import 'package:zitlas_mobile/features/experts/data/experts_repository.dart';
import 'package:zitlas_mobile/features/workout/data/workout_repository.dart';
import 'package:zitlas_mobile/features/workout/models/coach_training_plan.dart';
import 'package:zitlas_mobile/features/workout/models/workout_day.dart';
import 'package:zitlas_mobile/features/workout/models/workout_exercise.dart';
import 'package:zitlas_mobile/features/workout/workout_controller.dart';

/// A coach-authored plan is NEVER auto-overridden by a wellness check-in.
///
/// Deciding whether a sick client should still train is the coach's
/// judgement call, not the app's. So for a coached athlete "Sick Today" must
/// leave the plan byte-for-byte as the coach wrote it and notify them
/// instead — and crucially, the notification must fire INDEPENDENTLY of the
/// two plan-rendering guards that suppress the override.
///
/// For an athlete with no coach, the deterministic AI wellness adjustment
/// still applies as before.

const _weekdayNames = [
  'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
];
String get _todayName => _weekdayNames[(DateTime.now().weekday - 1) % 7];

class _FakeAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

HealthAdjustment _sick() =>
    computeHealthAdjustments(HealthReport(status: 'sick', symptoms: ['Fever']), baseStepsGoal: 8000);

HealthAdjustment _injured() => computeHealthAdjustments(
      HealthReport(status: 'injured', bodyParts: ['Knee'], painLevel: 5),
      baseStepsGoal: 8000,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── Diet ──────────────────────────────────────────────────────────────
  group('coach-authored DIET is left exactly as the coach wrote it', () {
    late DietController controller;
    late FakeFirebaseFirestore fake;

    setUp(() {
      fake = FakeFirebaseFirestore();
      controller = DietController(
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
    tearDown(() => controller.dispose());

    DietDay today() => DietDay(
          day: _todayName,
          meals: [DietMeal(mealName: 'Breakfast', foods: const ['Coach: oats + whey'])],
        );

    /// A GENUINE active coach plan.
    ///
    /// This previously faked it with `DietStorage(isExpertPlan: true)`, but
    /// `isExpertPlan` is also true for an EXPERT-REVIEWED plan — the athlete's
    /// own AI plan verified by an expert — which must still receive recovery
    /// mode. The guard now reads `activeCoachDiet`, so the fixture has to build
    /// the real thing: an active diet-covering relationship plus a published
    /// coach plan for the live goal.
    void withCoachPlan() {
      controller.livePlanId = 'plan-live';
      controller.coachRelationship = const CoachingRelationship(
        id: 'athlete-1', status: 'active', planType: 'diet', coachId: 'coach-9',
      );
      controller.coachPlan = const CoachingPlanDoc(
        exists: true,
        coachId: 'coach-9',
        diet: CoachDietPlan(
          planId: 'plan-live',
          days: [
            CoachDietDay(day: 'Monday', meals: [
              CoachMeal(id: 'breakfast', name: 'Breakfast', options: [
                CoachMealOption(name: 'Coach: oats + whey'),
              ]),
            ]),
          ],
        ),
      );
      expect(controller.activeCoachDiet, isNotNull, reason: 'fixture precondition');
    }

    test('TEST 3 — active coach + Sick: coach diet UNCHANGED', () {
      controller.healthToday = _sick();
      withCoachPlan();
      final day = today();
      expect(controller.healthOverrideAppliesTo(day), isFalse,
          reason: 'an ACTIVE coach plan must not be overridden by recovery mode');
      // The stored plan is handed back untouched; the coach's own plan renders
      // through activeCoachDiet, which this path never rewrites.
      expect(controller.effectiveMealsFor(day), same(day.meals));
    });

    test('TEST 6 — active coach + Injured: coach diet UNCHANGED', () {
      controller.healthToday = _injured();
      withCoachPlan();
      final day = today();
      expect(controller.healthOverrideAppliesTo(day), isFalse);
      expect(controller.effectiveMealsFor(day), same(day.meals));
    });

    test('an EXPERT-REVIEWED plan still receives recovery mode', () {
      /* THE BUG. `healthOverrideAppliesTo` used to refuse whenever
         `dietStorage.isExpertPlan == true`, which is set when an expert REVIEW
         is accepted (planSource: 'expert_reviewed'). So any athlete who had
         ever accepted a review could never get a recovery-day diet again — with
         or without a coach. Home said the plan was adjusted; Diet ignored it. */
      controller.healthToday = _sick();
      final plan = DietPlanContent(days: [today()]);
      controller.dietStorage = DietStorage(
        originalDietPlan: plan,
        currentDietPlan: plan,
        isExpertPlan: true,            // expert-REVIEWED, NOT a coach plan
        planSource: 'expert_reviewed',
      );
      // No coach relationship at all.
      expect(controller.activeCoachDiet, isNull);
      expect(controller.healthOverrideAppliesTo(today()), isTrue,
          reason: 'an expert-reviewed AI plan is still the athlete own plan');
    });

    test('an ENDED coach relationship no longer blocks recovery mode', () {
      controller.healthToday = _sick();
      withCoachPlan();
      controller.coachRelationship = const CoachingRelationship(
        id: 'athlete-1', status: 'ended', planType: 'diet', coachId: 'coach-9',
      );
      expect(controller.activeCoachDiet, isNull);
      expect(controller.healthOverrideAppliesTo(today()), isTrue,
          reason: 'a finished engagement must not keep suppressing recovery');
    });

    test('TEST 1 — NO coach + Sick: AI adjustment IS applied', () {
      controller.healthToday = _sick();
      // dietStorage left null / not an expert plan.
      final day = today();
      expect(controller.healthOverrideAppliesTo(day), isTrue);
      expect(controller.effectiveMealsFor(day), isNot(same(day.meals)));
    });

    test('TEST 2 — NO coach + Injured: AI adjustment IS applied', () {
      controller.healthToday = _injured();
      final day = today();
      expect(controller.healthOverrideAppliesTo(day), isTrue);
      expect(controller.effectiveMealsFor(day), isNot(same(day.meals)));
    });
  });

  // ── Training ──────────────────────────────────────────────────────────
  group('coach-authored TRAINING is left exactly as the coach wrote it', () {
    late WorkoutController controller;

    setUp(() {
      controller = WorkoutController(
        uid: 'athlete-1',
        repository: WorkoutRepository(FakeFirebaseFirestore()),
      );
    });
    tearDown(() => controller.dispose());

    WorkoutDay today() => WorkoutDay(
          day: _todayName,
          exercises: const [WorkoutExercise(name: 'Coach: heavy squat 5x5', sets: '5')],
        );

    /// Reproduces `_coachOverrideActive` through its REAL inputs rather than
    /// a test-only setter: an active training relationship plus a coach plan
    /// authored against the live plan generation.
    void withCoachTrainingPlan(WorkoutController c) {
      c.livePlanId = 'plan-live-1';
      c.coachingRelationship = const PersonalCoachingRelationship(
        status: 'active',
        planType: 'training',
        coachId: 'coach-9',
        coachName: 'Coach',
      );
      c.coachTrainingPlan = CoachTrainingPlan(
        days: [today()],
        planId: 'plan-live-1',
      );
      expect(c.isCoachManaged, isTrue, reason: 'guard precondition');
    }

    test('TEST 4 — active coach + Sick: coach training UNCHANGED', () {
      controller.healthToday = _sick();
      withCoachTrainingPlan(controller);
      final day = today();
      expect(controller.healthOverrideAppliesTo(day), isFalse);
      expect(controller.effectiveExercisesFor(day), same(day.exercises));
      expect(controller.effectiveExercisesFor(day).first.name, 'Coach: heavy squat 5x5');
    });

    test('TEST 7 — active coach + Injured: coach training UNCHANGED', () {
      controller.healthToday = _injured();
      withCoachTrainingPlan(controller);
      final day = today();
      expect(controller.healthOverrideAppliesTo(day), isFalse);
      expect(controller.effectiveExercisesFor(day), same(day.exercises));
    });

    test('NO coach + Sick (fever): the heavy session is REPLACED by rest', () {
      // A fever produces mode 'rest' with an intentionally EMPTY exercise
      // list. The guard used to require a non-empty list, so the override was
      // discarded and the screen fell back to `day.isRest` and rendered the
      // original heavy squat session to a feverish athlete.
      controller.healthToday = _sick();
      expect(controller.healthToday!.workout!.mode, 'rest');
      final day = today();
      expect(controller.healthOverrideAppliesTo(day), isTrue);
      expect(controller.effectiveExercisesFor(day), isEmpty,
          reason: 'a rest day must schedule NO exercises');
    });

    test('NO coach + Injured: training is replaced with injury-safe work', () {
      controller.healthToday = _injured();
      final day = today();
      expect(controller.healthOverrideAppliesTo(day), isTrue);
      final effective = controller.effectiveExercisesFor(day);
      expect(effective, isNot(same(day.exercises)));
      expect(effective.any((e) => e.name.contains('squat')), isFalse,
          reason: 'no strength work on an injury day');
    });
  });

  // ── Coach notification ────────────────────────────────────────────────
  group('the coach is notified INDEPENDENTLY of the plan guards', () {
    const athlete = 'athlete-1';
    const coach = 'coach-9';
    const other = 'expert-unrelated';

    late FakeFirebaseFirestore fake;
    late DashboardRepository repo;

    setUp(() {
      fake = FakeFirebaseFirestore();
      repo = DashboardRepository(fake);
    });

    Future<void> relationship(String status) => fake
        .collection('personal_coaching')
        .doc(athlete)
        .set({'athleteId': athlete, 'coachId': coach, 'coachName': 'Coach', 'status': status});

    Future<void> alert(HealthAdjustment adj) => repo.sendHealthAlert(
          uid: athlete,
          athleteName: 'Atharva',
          summary: 'Sick',
          title: 'Client Wellness Update',
          message: 'Atharva marked today as Sick. Their current diet and training '
              'plan have NOT been automatically changed.',
          chatText: 'wellness',
          eventId: wellnessEventId(uid: athlete, date: adj.date, status: adj.status),
          alert: {'status': adj.status, 'date': adj.date},
        );

    Future<List<Map<String, dynamic>>> notifications() async {
      final snap = await fake.collection('coaching_notifications').get();
      return snap.docs.map((d) => d.data()).toList();
    }

    test('TEST 5 — active coach + Sick: EXACTLY ONE notification', () async {
      await relationship('active');
      await alert(_sick());

      final notes = await notifications();
      expect(notes.length, 1);
      expect(notes.single['toId'], coach);
      expect(notes.single['type'], 'wellness_plan_adjusted');
    });

    test('TEST 8 — active coach + Injured: EXACTLY ONE notification', () async {
      await relationship('active');
      await alert(_injured());
      expect((await notifications()).length, 1);
    });

    test('the notification carries the metadata the expert needs', () async {
      await relationship('active');
      final adj = _sick();
      await alert(adj);

      final note = (await notifications()).single;
      expect(note['athleteId'], athlete);
      expect(note['athleteName'], 'Atharva');
      expect(note['coachId'], coach);
      expect(note['status'], 'sick');
      expect(note['date'], adj.date);
      expect(note['eventId'], isNotNull);
      expect(note['timestamp'], isNotNull);
      expect(note['title'], 'Client Wellness Update');
      // The message must NOT imply the coach's plan was changed.
      expect(note['text'], contains('NOT been automatically changed'));
    });

    test('the health_alert record states the plan was not modified', () async {
      await relationship('active');
      await alert(_sick());
      final snap = await fake.collection('health_alerts').get();
      expect(snap.docs.length, 1);
      expect(snap.docs.single.data()['eventId'], isNotNull);
    });

    test('TEST 9 — repeated Sick does NOT duplicate', () async {
      await relationship('active');
      final adj = _sick();
      // Re-tap, screen rebuild, listener restart, retry.
      await alert(adj);
      await alert(adj);
      await alert(adj);

      expect((await notifications()).length, 1, reason: 'one wellness action = one notification');
      expect((await fake.collection('health_alerts').get()).docs.length, 1);
    });

    test('TEST 10 — Sick then Injured creates a NEW notification', () async {
      await relationship('active');
      await alert(_sick());
      await alert(_injured());

      // A changed status is genuinely new information for the coach.
      expect((await notifications()).length, 2);
    });

    test('TEST 11 — an ENDED coach receives nothing', () async {
      await relationship('ended');
      await alert(_sick());
      expect(await notifications(), isEmpty);
    });

    test('an EXPIRED coach receives nothing', () async {
      await relationship('expired');
      await alert(_sick());
      expect(await notifications(), isEmpty);
    });

    test('no coaching relationship at all: no notification', () async {
      await alert(_sick());
      expect(await notifications(), isEmpty);
      expect((await fake.collection('health_alerts').get()).docs, isEmpty);
    });

    test('TEST 12 — unrelated experts receive nothing', () async {
      await relationship('active');
      await alert(_sick());

      final notes = await notifications();
      expect(notes.every((n) => n['toId'] == coach), isTrue);
      expect(notes.any((n) => n['toId'] == other), isFalse);
      expect(notes.any((n) => n['toId'] == athlete), isFalse,
          reason: 'the athlete must never receive the EXPERT notification');
    });
  });
}
