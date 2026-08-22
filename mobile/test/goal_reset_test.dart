import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/dashboard/data/dashboard_repository.dart';

/// A GOAL RESET MUST NOT LEAK THE OLD GOAL INTO THE NEW ONE — AND MUST NOT
/// DELETE THE ACCOUNT EITHER.
///
/// The website's reset (`cloud-sync.js clearGoalData()` +
/// `coaching-reset.js clearAll({relationshipStatus:'reset'})`) does three
/// things. Flutter's did only the first: it nulled the goal-scoped fields on
/// `users/{uid}` and stopped there.
///
/// So a reset performed IN THE APP left `personal_coaching/{uid}.status` at
/// `'active'`. Personal Coaching is served by the website (in a WebView on
/// mobile) and `diet.js`'s `_pcShowsCoachPlan()` gates purely on that status,
/// so the previous coach's plan went straight back over the freshly generated
/// AI plan — and `coaching_plans/{uid}.athleteContext` still held the old
/// goal's assessment and medical conditions for the coach to read.
void main() {
  const uid = 'athlete1';

  /// A user mid-transformation: a goal, plans, an active coach, published
  /// context — plus the permanent things a reset must never touch.
  Future<FakeFirebaseFirestore> seeded() async {
    final db = FakeFirebaseFirestore();
    await db.collection('users').doc(uid).set({
      // Goal-scoped — all of this must go.
      'goal': {'type': 'weight_loss'},
      'assessment': {'fitness_goal': 'weight_loss'},
      'survey': {'q1': 'a'},
      'calculations': {'tdee': 2400},
      'swot': {'strengths': []},
      'dietPlan': {'currentDietPlan': {}},
      'workoutPlan': {'currentWorkoutPlan': {}},
      'roadmap': {'days': []},
      'precautions': {'conditions': ['asthma']},
      'planGeneratedAt': '2026-01-01T00:00:00.000',
      'planId': 'plan_1',
      'dietPlanMaster': {'days': []},
      'workoutPlanMaster': {'weekly_plan': []},
      // Permanent — all of this must survive.
      'personalInfo': {'name': 'Test Athlete'},
      'wallet': {'balance': 500},
      'membership': {'plan': 'premium', 'active': true},
      'location': {'state': 'Maharashtra'},
      'fcmTokens': ['tok1'],
    });
    await db.collection('personal_coaching').doc(uid).set({
      'coachId': 'coach1',
      'status': 'active',
      'planType': 'complete',
      'startDate': '2026-01-01',
    });
    await db.collection('coaching_plans').doc(uid).set({
      'athleteContext': {'medicalConditions': ['asthma'], 'goal': 'weight_loss'},
      'athleteContextUpdatedAt': '2026-01-01T00:00:00.000',
      'diet': {'authoredByCoach': true},
      'training': {'authoredByCoach': true},
    });
    return db;
  }

  group('goal-scoped state is cleared', () {
    test('every goal-scoped field on the user doc is nulled', () async {
      final db = await seeded();
      await DashboardRepository(db).resetGoal(uid);

      final user = (await db.collection('users').doc(uid).get()).data()!;
      for (final field in const [
        'goal', 'assessment', 'survey', 'calculations', 'swot',
        'dietPlan', 'workoutPlan', 'roadmap', 'precautions',
        'planGeneratedAt', 'planId', 'dietPlanMaster', 'workoutPlanMaster',
      ]) {
        expect(user[field], isNull, reason: '$field survived the reset');
      }
    });

    test('the reset is stamped so other devices can see it happened',
        () async {
      final db = await seeded();
      await DashboardRepository(db).resetGoal(uid);
      final user = (await db.collection('users').doc(uid).get()).data()!;
      expect(user['goalResetAt'], isNotNull);
    });
  });

  group('coaching cannot survive into the new goal', () {
    test('the coaching relationship is retired to "reset"', () async {
      final db = await seeded();
      await DashboardRepository(db).resetGoal(uid);

      final rel = (await db.collection('personal_coaching').doc(uid).get()).data()!;
      expect(rel['status'], 'reset',
          reason: "left at 'active', the previous coach's plan overrides the "
              'brand-new AI plan the moment Personal Coaching opens');
      expect(rel['priorStatus'], 'active');
      expect(rel['resetAt'], isNotNull);
    });

    test('the relationship is retired, never deleted', () async {
      final db = await seeded();
      await DashboardRepository(db).resetGoal(uid);

      final snap = await db.collection('personal_coaching').doc(uid).get();
      expect(snap.exists, isTrue, reason: 'coaching history must survive');
      expect(snap.data()!['coachId'], 'coach1');
    });

    test('the published athlete context is removed', () async {
      final db = await seeded();
      await DashboardRepository(db).resetGoal(uid);

      final plan = (await db.collection('coaching_plans').doc(uid).get()).data()!;
      expect(plan.containsKey('athleteContext'), isFalse,
          reason: 'the coach would otherwise still see the PREVIOUS goal\'s '
              'assessment and medical conditions');
      expect(plan.containsKey('athleteContextUpdatedAt'), isFalse);
    });

    test("the coach's own authored plans are left alone — they are history",
        () async {
      final db = await seeded();
      await DashboardRepository(db).resetGoal(uid);

      final plan = (await db.collection('coaching_plans').doc(uid).get()).data()!;
      expect(plan['diet'], isNotNull);
      expect(plan['training'], isNotNull);
    });

    test('only the keys firestore.rules permits the athlete to change move',
        () async {
      // rules: changedOnly(['status','priorStatus','resetAt','endedAt',
      //                     'endedBy','reason']) && status in ['reset','ended']
      final db = await seeded();
      final before = (await db.collection('personal_coaching').doc(uid).get()).data()!;
      await DashboardRepository(db).resetGoal(uid);
      final after = (await db.collection('personal_coaching').doc(uid).get()).data()!;

      final changed = {
        ...after.keys.where((k) => before[k] != after[k]),
        ...before.keys.where((k) => !after.containsKey(k)),
      };
      expect(changed.difference({'status', 'priorStatus', 'resetAt'}), isEmpty,
          reason: 'a key outside the allowed set means the real write would '
              'be rejected with permission-denied');
    });
  });

  group('a reset is not an account deletion', () {
    test('identity, money, membership and devices all survive', () async {
      final db = await seeded();
      await DashboardRepository(db).resetGoal(uid);

      final user = (await db.collection('users').doc(uid).get()).data()!;
      expect(user['personalInfo'], isNotNull);
      expect(user['wallet'], isNotNull);
      expect(user['membership'], isNotNull,
          reason: 'a premium athlete must not be downgraded by resetting');
      expect(user['location'], isNotNull);
      expect(user['fcmTokens'], isNotNull);
    });
  });

  group('the reset is resilient', () {
    test('no coaching relationship at all is a normal reset, not a failure',
        () async {
      final db = FakeFirebaseFirestore();
      await db.collection('users').doc(uid).set({'goal': {'type': 'x'}});

      await DashboardRepository(db).resetGoal(uid);

      final user = (await db.collection('users').doc(uid).get()).data()!;
      expect(user['goal'], isNull);
    });

    test('resetting twice is idempotent', () async {
      final db = await seeded();
      final repo = DashboardRepository(db);
      await repo.resetGoal(uid);
      await repo.resetGoal(uid);

      final rel = (await db.collection('personal_coaching').doc(uid).get()).data()!;
      expect(rel['status'], 'reset');
      expect(rel['priorStatus'], 'active',
          reason: 'the second pass must not overwrite priorStatus with '
              '"reset" and lose what the relationship actually was');
    });
  });
}
