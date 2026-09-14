import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart' show SetOptions;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/coaching/data/coaching_plan_repository.dart';
import 'package:zitlas_mobile/features/coaching/models/coach_diet_plan.dart';
import 'package:zitlas_mobile/features/coaching/models/protein_variety.dart';

/// Coach-authored plans.
///
/// A DIET publish is the backend's job: `POST /api/coaching-plans/{id}/diet`
/// (backend/routes/coaching_plans.py). Who may publish, the version check,
/// the transactional history and the athlete's notification are pinned in
/// backend/tests/test_coaching_plans.py. This file pins the app's half — the
/// exact request, that the app writes nothing itself, that every refusal is
/// an honest failure — and, against a stand-in for the endpoint, the read
/// side: history, restore, the live listener and the goal-reset guard.
void main() {
  const athlete = 'athlete_1';
  const coach = 'coach_1';

  CoachDietPlan planWith(Map<String, List<String>> dayToFoods) {
    return CoachDietPlan(
      days: [
        for (final entry in dayToFoods.entries)
          CoachDietDay(
            day: entry.key,
            meals: [
              for (var i = 0; i < entry.value.length; i++)
                CoachMeal(
                  id: 'meal_$i',
                  name: kCoachDefaultMeals[i % kCoachDefaultMeals.length],
                  options: [CoachMealOption(name: entry.value[i], calories: 400, protein: 25)],
                ),
            ],
          ),
      ],
    );
  }

  http.Response reply(Object? body, int status) => http.Response(jsonEncode(body), status);

  /// A repository whose backend is [respond]; every request is recorded.
  ({CoachingPlanRepository repo, List<http.Request> calls}) backed(
    FakeFirebaseFirestore db,
    Future<http.Response> Function(http.Request req) respond,
  ) {
    final calls = <http.Request>[];
    final api = ApiClient(
      httpClient: MockClient((req) {
        calls.add(req);
        return respond(req);
      }),
      baseUrl: 'https://api.test',
    );
    return (repo: CoachingPlanRepository(firestore: db, apiClient: api), calls: calls);
  }

  /// Stand-in for the endpoint's observable effects: the base-version check,
  /// then the plan and one version snapshot. (The real one also verifies the
  /// coach and notifies the athlete — tested on the backend.)
  Future<http.Response> Function(http.Request) endpoint(FakeFirebaseFirestore db) {
    return (req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final ref = db.collection('coaching_plans').doc(athlete);
      final current = ((await ref.get()).data()?['dietVersion'] as num?)?.toInt() ?? 0;
      if (body['baseVersion'] != current) {
        return reply({
          'detail': {'error': 'stale_version', 'baseVersion': body['baseVersion'], 'currentVersion': current},
        }, 409);
      }
      final version = current + 1;
      final savedAt = DateTime.utc(2026, 9, 13, 9, version).toIso8601String();
      await ref.set({
        'athleteId': athlete,
        'coachId': coach,
        'coachName': 'Coach Rahul',
        'planType': 'complete',
        'diet': body['diet'],
        'dietVersion': version,
        'dietUpdatedAt': savedAt,
      }, SetOptions(merge: true));
      await ref.collection('versions').doc('diet_${1789300000000 + version}_v$version').set({
        'type': 'diet',
        'data': body['diet'],
        'version': version,
        'savedAt': savedAt,
        'savedBy': 'Coach Rahul',
      });
      return reply({'success': true, 'dietVersion': version, 'dietUpdatedAt': savedAt, 'notified': true}, 200);
    };
  }

  Future<int> publish(CoachingPlanRepository repo, Map<String, List<String>> foods, int base) =>
      repo.saveDiet(athleteId: athlete, diet: planWith(foods), baseVersion: base);

  group('publishing a coach diet — through the backend', () {
    test('POSTs the diet and the version it started from to the authoritative endpoint', () async {
      final b = backed(FakeFirebaseFirestore(), (_) async => reply({'success': true, 'dietVersion': 4}, 200));

      final saved = await publish(b.repo, {'Monday': ['Paneer Bhurji']}, 3);

      expect(saved, 4);
      final req = b.calls.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://api.test/api/coaching-plans/athlete_1/diet');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body.keys, unorderedEquals(['diet', 'baseVersion']),
          reason: 'coach identity, the new version and the planId are decided by the server');
      expect(body['baseVersion'], 3);
      expect(body['diet']['days'][0]['meals'][0]['options'][0]['name'], 'Paneer Bhurji');
    });

    test('the app writes NOTHING itself — no plan, version, notification or AI-plan change', () async {
      final db = FakeFirebaseFirestore();
      await db.collection('users').doc(athlete).set({
        'dietPlan': {'originalDietPlan': {'days': ['ai-generated']}},
      });
      final b = backed(db, (_) async => reply({'success': true, 'dietVersion': 1}, 200));

      await publish(b.repo, {'Monday': ['Dal']}, 0);

      final plan = db.collection('coaching_plans').doc(athlete);
      expect((await plan.get()).exists, isFalse);
      expect((await plan.collection('versions').get()).docs, isEmpty);
      expect((await db.collection('notifications').get()).docs, isEmpty,
          reason: 'the server notifies the athlete, after its commit');
      final user = await db.collection('users').doc(athlete).get();
      expect(user.data()!['dietPlan']['originalDietPlan']['days'], ['ai-generated']);
    });

    test('409 — another device published first: a conflict carrying the current version', () async {
      final b = backed(FakeFirebaseFirestore(), (_) async => reply({
            'detail': {'error': 'stale_version', 'baseVersion': 2, 'currentVersion': 5},
          }, 409));

      await expectLater(
        publish(b.repo, {'Monday': ['Dal']}, 2),
        throwsA(isA<CoachPlanConflictException>()
            .having((e) => e.currentVersion, 'currentVersion', 5)
            .having((e) => e.message, 'message', contains('NOT published'))),
      );
    });

    for (final (status, detail, says, retryable) in <(int, Object?, String, bool)>[
      (403, 'not_assigned_coach', "not this athlete's active coach", false),
      (403, {'error': 'no_coaching_relationship'}, "not this athlete's active coach", false),
      (403, 'coaching_not_active', 'coaching has ended', false),
      (403, {'error': 'program_not_active'}, 'coaching has ended', false),
      (403, 'plan_does_not_cover_diet', "doesn't include diet", false),
      (401, 'Invalid token', 'session has expired', false),
      (400, 'invalid_diet_days', 'could not be published (invalid_diet_days)', false),
      (413, 'diet_too_large', 'could not be published (diet_too_large)', false),
      (500, null, "couldn't publish", true),
      (503, 'firestore_unavailable', "couldn't publish", true),
    ]) {
      test('HTTP $status $detail is an honest failure, never a publish', () async {
        final db = FakeFirebaseFirestore();
        final b = backed(db, (_) async => reply({'detail': detail}, status));

        await expectLater(
          publish(b.repo, {'Monday': ['Dal']}, 0),
          throwsA(isA<CoachPlanSaveException>()
              .having((e) => e.statusCode, 'statusCode', status)
              .having((e) => e.message, 'message', contains(says))
              .having((e) => e.isRetryable, 'isRetryable', retryable)),
        );
        expect((await db.collection('coaching_plans').doc(athlete).get()).exists, isFalse);
      });
    }

    test('no connection is an honest, retryable failure', () async {
      final api = ApiClient(
        httpClient: MockClient((_) async => throw http.ClientException('offline')),
        baseUrl: 'https://api.test',
      );
      final repo = CoachingPlanRepository(firestore: FakeFirebaseFirestore(), apiClient: api);

      await expectLater(
        publish(repo, {'Monday': ['Dal']}, 0),
        throwsA(isA<CoachPlanSaveException>()
            .having((e) => e.statusCode, 'statusCode', isNull)
            .having((e) => e.isRetryable, 'isRetryable', isTrue)
            .having((e) => e.message, 'message', contains('NOT published'))),
      );
    });

    test('a 200 that does not confirm the save is not reported as one', () async {
      final b = backed(FakeFirebaseFirestore(), (_) async => reply({'ok': true}, 200));
      await expectLater(
        publish(b.repo, {'Monday': ['Dal']}, 0),
        throwsA(isA<CoachPlanSaveException>().having((e) => e.code, 'code', 'unconfirmed')),
      );
    });

    test('training publishes are unchanged: written, versioned and notified from here', () async {
      final db = FakeFirebaseFirestore();
      final repo = CoachingPlanRepository(firestore: db);

      await repo.saveTraining(
        athleteId: athlete,
        athleteName: 'Rohit',
        coachId: coach,
        coachName: 'Coach Rahul',
        planType: 'complete',
        training: {
          'days': [
            {'day': 'Monday', 'focus': 'Push', 'exercises': []},
          ],
        },
      );

      final doc = await repo.fetch(athlete);
      expect(doc.trainingVersion, 1);
      expect(doc.hasTraining, isTrue);
      expect(doc.dietVersion, 0, reason: 'the two plans version independently');
      expect((await repo.watchVersions(athlete, type: 'training').first).length, 1);
      final types = (await db.collection('notifications').get())
          .docs
          .map((d) => d.data()['type'])
          .toList();
      expect(types, ['training_update']);
    });
  });

  group('version history — nothing is ever overwritten', () {
    test('every publish leaves a restorable snapshot, newest first', () async {
      final db = FakeFirebaseFirestore();
      final b = backed(db, endpoint(db));

      var v = await publish(b.repo, {'Monday': ['Original AI-based']}, 0);
      v = await publish(b.repo, {'Monday': ['Coach revision 1']}, v);
      v = await publish(b.repo, {'Monday': ['Coach revision 2']}, v);

      expect(v, 3);
      final versions = await b.repo.watchVersions(athlete, type: 'diet').first;
      expect(versions.length, 3);
      expect(versions.first.version, 3, reason: 'newest first');
      expect(versions.last.version, 1);
      expect(versions.every((x) => x.isDiet), isTrue);
      expect(versions.first.savedBy, 'Coach Rahul');
    });

    test('a restore is saved FORWARD, on top of the version stored now', () async {
      final db = FakeFirebaseFirestore();
      final b = backed(db, endpoint(db));
      final v = await publish(b.repo, {'Monday': ['Paneer Bhurji']}, 0);
      await publish(b.repo, {'Monday': ['Chicken Curry']}, v);

      final first = (await b.repo.watchVersions(athlete, type: 'diet').first)
          .firstWhere((x) => x.version == 1);
      await b.repo.restoreVersion(
        athleteId: athlete,
        athleteName: 'Rohit',
        coachId: coach,
        coachName: 'Coach Rahul',
        planType: 'complete',
        version: first,
      );

      expect((jsonDecode(b.calls.last.body) as Map)['baseVersion'], 2,
          reason: 'rebased on what is stored, not on the revision being restored');
      final doc = await b.repo.fetch(athlete);
      expect(doc.diet.days.first.meals.first.options.first.name, 'Paneer Bhurji');
      expect(doc.dietVersion, 3, reason: 'a rollback is itself an edit');

      // The revision that was rolled back is still in the history.
      final after = await b.repo.watchVersions(athlete, type: 'diet').first;
      expect(after.length, 3);
      expect(after.any((x) => x.version == 2), isTrue);
    });

    test('a restore from a stale view conflicts instead of overwriting', () async {
      final db = FakeFirebaseFirestore();
      final b = backed(db, endpoint(db));
      final v = await publish(b.repo, {'Monday': ['Paneer Bhurji']}, 0);
      await publish(b.repo, {'Monday': ['Chicken Curry']}, v);
      final first = (await b.repo.watchVersions(athlete, type: 'diet').first)
          .firstWhere((x) => x.version == 1);

      await expectLater(
        b.repo.restoreVersion(
          athleteId: athlete,
          athleteName: 'Rohit',
          coachId: coach,
          coachName: 'Coach Rahul',
          planType: 'complete',
          version: first,
          baseVersion: 1,
        ),
        throwsA(isA<CoachPlanConflictException>().having((e) => e.currentVersion, 'currentVersion', 2)),
      );

      final doc = await b.repo.fetch(athlete);
      expect(doc.dietVersion, 2);
      expect(doc.diet.days.first.meals.first.options.first.name, 'Chicken Curry');
    });

    test('diet and training histories can be read separately', () async {
      final db = FakeFirebaseFirestore();
      final b = backed(db, endpoint(db));
      await publish(b.repo, {'Monday': ['Dal']}, 0);
      await b.repo.saveTraining(
        athleteId: athlete,
        athleteName: 'Rohit',
        coachId: coach,
        coachName: 'Coach Rahul',
        planType: 'complete',
        training: {'days': []},
      );

      expect((await b.repo.watchVersions(athlete, type: 'diet').first).length, 1);
      expect((await b.repo.watchVersions(athlete, type: 'training').first).length, 1);
      expect((await b.repo.watchVersions(athlete).first).length, 2);
    });
  });

  group('goal-reset protection (fail closed)', () {
    /// A plan as the endpoint stores it: stamped with the athlete's planId of
    /// the moment it was published.
    Future<CoachingPlanDoc> stamped(String? planId) async {
      final db = FakeFirebaseFirestore();
      await db.collection('coaching_plans').doc(athlete).set({
        'coachId': coach,
        'planType': 'complete',
        'dietVersion': 1,
        'diet': planWith({'Monday': ['Dal']}).copyWith(planId: planId).toMap(),
      });
      return CoachingPlanRepository(firestore: db).fetch(athlete);
    }

    test('a plan authored against the current generation is live', () async {
      expect((await stamped('plan_v1')).isStaleFor('plan_v1'), isFalse);
    });

    test('a plan authored against an abandoned goal is stale', () async {
      // The athlete reset their goal, so users/{uid}.planId moved on. The
      // coach plan must retire rather than keep prescribing for a goal that
      // no longer exists.
      expect((await stamped('plan_v1')).isStaleFor('plan_v2'), isTrue);
    });

    test('an unstamped plan is not treated as stale', () async {
      // Plans written before the stamp existed must keep working.
      expect((await stamped(null)).isStaleFor('plan_v2'), isFalse);
    });
  });

  group('what the coach is allowed to edit', () {
    test('a diet-only engagement cannot rewrite training', () {
      const doc = CoachingPlanDoc(planType: 'diet');
      expect(doc.canEditDiet, isTrue);
      expect(doc.canEditTraining, isFalse);
    });

    test('a training-only engagement cannot rewrite food', () {
      const doc = CoachingPlanDoc(planType: 'training');
      expect(doc.canEditDiet, isFalse);
      expect(doc.canEditTraining, isTrue);
    });

    test('a complete engagement covers both', () {
      const doc = CoachingPlanDoc(planType: 'complete');
      expect(doc.canEditDiet, isTrue);
      expect(doc.canEditTraining, isTrue);
    });
  });

  group('the athlete sees changes without refreshing', () {
    test('a publish arrives on the live listener', () async {
      final db = FakeFirebaseFirestore();
      final b = backed(db, endpoint(db));
      final seen = <CoachingPlanDoc>[];
      final sub = b.repo.watch(athlete).listen(seen.add);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(seen.last.exists, isFalse);

      await publish(b.repo, {'Monday': ['Paneer Bhurji']}, 0);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(seen.last.exists, isTrue);
      expect(seen.last.diet.days.first.meals.first.options.first.name, 'Paneer Bhurji');
      await sub.cancel();
    });
  });

  group('the plan round-trips through the website\'s shape', () {
    test('a full week survives publish and reload unchanged', () async {
      final db = FakeFirebaseFirestore();
      final b = backed(db, endpoint(db));
      final original = CoachDietPlan(days: [
        CoachDietDay(day: 'Monday', meals: [
          const CoachMeal(id: 'meal_0', name: 'Breakfast', time: '08:00', options: [
            CoachMealOption(name: 'Paneer Bhurji', calories: 320, protein: 22, notes: 'Low oil'),
            CoachMealOption(name: 'Moong Dal Chilla', calories: 280, protein: 18),
          ]),
        ]),
      ]);

      await b.repo.saveDiet(athleteId: athlete, diet: original, baseVersion: 0);
      final reloaded = (await b.repo.fetch(athlete)).diet;

      final meal = reloaded.days.first.meals.first;
      expect(meal.id, 'meal_0');
      expect(meal.time, '08:00');
      expect(meal.options.length, 2);
      expect(meal.options.first.name, 'Paneer Bhurji');
      expect(meal.options.first.calories, 320);
      expect(meal.options.first.notes, 'Low oil');
    });

    test('a blank calorie stays blank rather than becoming zero', () {
      final parsed = CoachDietPlan.fromMap({
        'days': [
          {
            'day': 'Monday',
            'meals': [
              {'id': 'm0', 'name': 'Breakfast', 'options': [{'name': 'Poha'}]},
            ],
          },
        ],
      });
      expect(parsed.days.first.meals.first.options.first.calories, isNull);
    });

    test('malformed entries are skipped, not fatal', () {
      final parsed = CoachDietPlan.fromMap({
        'days': [
          {
            'day': 'Monday',
            'meals': [
              {'id': 'm0', 'name': 'Breakfast', 'options': [
                {'name': 'Poha'},
                {'calories': 100},
                'not a map',
              ]},
              'not a meal',
            ],
          },
        ],
      });
      expect(parsed.days.first.meals.length, 1);
      expect(parsed.days.first.meals.first.options.length, 1);
    });
  });

  _athleteView();
  _websiteTypeTolerance();

  group('protein variety', () {
    test('a genuinely varied week raises nothing', () {
      final plan = planWith({
        'Monday': ['Egg Bhurji', 'Rajma Chawal', 'Roasted Chana', 'Paneer Tikka'],
        'Tuesday': ['Moong Dal Chilla', 'Chicken Curry', 'Almonds', 'Fish Curry'],
      });
      final report = analyseProteinVariety(plan);

      expect(report.isLowVariety, isFalse);
      expect(report.warning, isNull);
      expect(report.distinctSources, greaterThanOrEqualTo(3));
    });

    test('chicken every day is flagged with real counts', () {
      final plan = planWith({
        'Monday': ['Chicken Curry', 'Chicken Salad'],
        'Tuesday': ['Grilled Chicken', 'Chicken Soup'],
        'Wednesday': ['Chicken Biryani', 'Chicken Roll'],
      });
      final report = analyseProteinVariety(plan);

      expect(report.isLowVariety, isTrue);
      expect(report.dominant!.source, ProteinSource.chicken);
      expect(report.dominant!.mealCount, 6);
      expect(report.warning, contains('Chicken'));
      expect(report.warning, contains('100%'));
    });

    test('the report names concrete alternatives from the recognised sources', () {
      final plan = planWith({
        'Monday': ['Chicken Curry', 'Chicken Salad'],
        'Tuesday': ['Grilled Chicken', 'Chicken Soup'],
      });
      final unused = analyseProteinVariety(plan).unusedSources;

      expect(unused, contains(ProteinSource.paneer));
      expect(unused, contains(ProteinSource.legume));
      expect(unused, isNot(contains(ProteinSource.chicken)));
    });

    test('several options of the SAME source count as one meal', () {
      // The athlete eats one option, not all three.
      final plan = CoachDietPlan(days: [
        CoachDietDay(day: 'Monday', meals: [
          const CoachMeal(id: 'm0', name: 'Lunch', options: [
            CoachMealOption(name: 'Chicken Curry'),
            CoachMealOption(name: 'Chicken Tikka'),
            CoachMealOption(name: 'Grilled Chicken'),
          ]),
        ]),
      ]);
      final report = analyseProteinVariety(plan);
      expect(report.usage.single.mealCount, 1);
      expect(report.mealsWithProtein, 1);
    });

    test('a meal offering different sources counts towards each', () {
      final plan = CoachDietPlan(days: [
        CoachDietDay(day: 'Monday', meals: [
          const CoachMeal(id: 'm0', name: 'Lunch', options: [
            CoachMealOption(name: 'Paneer Tikka'),
            CoachMealOption(name: 'Rajma'),
          ]),
        ]),
      ]);
      final report = analyseProteinVariety(plan);
      expect(report.usage.map((u) => u.source),
          containsAll([ProteinSource.paneer, ProteinSource.legume]));
    });

    test('a half-built week is not nagged about', () {
      final plan = planWith({'Monday': ['Chicken Curry', 'Chicken Salad']});
      expect(analyseProteinVariety(plan).isLowVariety, isFalse,
          reason: 'warning a coach mid-build is noise');
    });

    test('meals with no recognisable protein are reported separately', () {
      final plan = planWith({
        'Monday': ['Fruit Salad', 'Green Tea', 'Steamed Vegetables', 'Tomato Soup'],
      });
      final report = analyseProteinVariety(plan);
      expect(report.mealsWithProtein, 0);
      expect(report.mealsWithoutProtein, 4);
      expect(report.isLowVariety, isFalse, reason: 'nothing to be repetitive about yet');
    });

    group('classification', () {
      test('recognises common Indian protein dishes', () {
        expect(ProteinSource.classify('Paneer Bhurji'), ProteinSource.paneer);
        expect(ProteinSource.classify('Moong Dal Chilla'), ProteinSource.legume);
        expect(ProteinSource.classify('Anda Curry'), ProteinSource.egg);
        expect(ProteinSource.classify('Murgh Tikka'), ProteinSource.chicken);
        expect(ProteinSource.classify('Machli Fry'), ProteinSource.fish);
        expect(ProteinSource.classify('Soya Chunk Curry'), ProteinSource.soy);
        expect(ProteinSource.classify('Masala Chaas'), ProteinSource.dairy);
        expect(ProteinSource.classify('Rajma Chawal'), ProteinSource.legume);
      });

      test('egg is matched before chicken so it is not miscounted', () {
        expect(ProteinSource.classify('Egg Bhurji'), ProteinSource.egg);
      });

      test('paneer is not swallowed by dairy', () {
        expect(ProteinSource.classify('Paneer Tikka'), ProteinSource.paneer);
      });

      test('an unrecognised dish returns null rather than a guess', () {
        expect(ProteinSource.classify('Steamed Broccoli'), isNull);
      });
    });
  });
}

/// The athlete's view of a coach plan — the read half of the loop.
///
/// These are in this file rather than the diet suite because what they pin is
/// the coach-plan contract: when a coach's prescription is shown, and the two
/// independent conditions under which it must NOT be.
void _athleteView() {
  group('when the athlete is shown the coach plan', () {
    CoachingPlanDoc docWith({
      String? planId,
      bool withMeals = true,
      bool exists = true,
    }) {
      return CoachingPlanDoc(
        exists: exists,
        coachName: 'Coach Rahul',
        planType: 'complete',
        diet: CoachDietPlan(
          planId: planId,
          days: [
            CoachDietDay(
              day: 'Monday',
              meals: [
                CoachMeal(
                  id: 'meal_0',
                  name: 'Breakfast',
                  options: withMeals
                      ? const [CoachMealOption(name: 'Paneer Bhurji', calories: 320)]
                      : const [],
                ),
              ],
            ),
          ],
        ),
      );
    }

    test('a published plan for the current goal is live', () {
      expect(docWith(planId: 'plan_v1').isStaleFor('plan_v1'), isFalse);
      expect(docWith(planId: 'plan_v1').diet.hasDays, isTrue);
    });

    test('an empty plan is not shown — it must not blank the AI plan', () {
      // A coach who opened the editor but published nothing.
      expect(docWith(withMeals: false).diet.hasDays, isFalse);
    });

    test('a plan for an abandoned goal retires itself', () {
      expect(docWith(planId: 'plan_v1').isStaleFor('plan_v2'), isTrue);
    });

    test('no coach document at all means no card', () {
      expect(docWith(exists: false).exists, isFalse);
    });

    test('selections are keyed day:mealId, matching the website', () {
      const doc = CoachingPlanDoc(selections: {'Monday:meal_0': 1});
      expect(doc.selections['Monday:meal_0'], 1);
    });
  });
}

/// The website writes these documents too, and JS is not fussy about types.
/// A hard cast here threw on the real production document and took the whole
/// coach plan down with it — caught on device, not in the unit tests.
void _websiteTypeTolerance() {
  group('tolerates the types the website actually stores', () {
    test('a version stored as a string still parses', () {
      final doc = CoachingPlanDoc.fromMap({
        'dietVersion': '3',
        'trainingVersion': '1',
        'diet': {'days': []},
      });
      expect(doc.dietVersion, 3);
      expect(doc.trainingVersion, 1);
    });

    test('a selection index stored as a string still parses', () {
      final doc = CoachingPlanDoc.fromMap({
        'dietSelections': {'Monday:meal_0': '2'},
      });
      expect(doc.selections['Monday:meal_0'], 2);
    });

    test('string calories and protein still parse', () {
      final plan = CoachDietPlan.fromMap({
        'days': [
          {
            'day': 'Monday',
            'meals': [
              {'id': 'm0', 'name': 'Breakfast', 'options': [
                {'name': 'Poha', 'calories': '250', 'protein': '8'},
              ]},
            ],
          },
        ],
      });
      final option = plan.days.first.meals.first.options.first;
      expect(option.calories, 250);
      expect(option.protein, 8);
    });

    test('genuinely unusable values become null, not zero', () {
      final plan = CoachDietPlan.fromMap({
        'days': [
          {'day': 'Monday', 'meals': [
            {'id': 'm0', 'name': 'Breakfast', 'options': [
              {'name': 'Poha', 'calories': 'unknown'},
            ]},
          ]},
        ],
      });
      expect(plan.days.first.meals.first.options.first.calories, isNull);
    });

    test('a garbage document does not throw', () {
      expect(() => CoachingPlanDoc.fromMap({'dietVersion': {}, 'diet': 'nope'}), returnsNormally);
    });
  });
}
