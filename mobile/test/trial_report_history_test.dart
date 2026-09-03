import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/trial_report/data/trial_report_repository.dart';
import 'package:zitlas_mobile/features/trial_report/models/trial_report.dart';
import 'package:zitlas_mobile/features/trial_report/presentation/screens/trial_report_history_screen.dart';
import 'package:zitlas_mobile/features/trial_report/presentation/screens/trial_report_screen.dart';

/// Trial Report History (Step 3.1) + the Step 3 detail screen it opens.
///
/// THE PROPERTY THESE TESTS PROTECT: the app displays what the backend
/// stored and derives nothing. The detail tests feed a report whose
/// percentage would be trivially recomputable (18/30) and assert the UI uses
/// the backend's own figure; the unavailable metrics assert an explanation
/// rather than a fabricated zero.

const _kSummaries = [
  {
    'requestId': 'req_newest',
    'coachId': 'coach_1',
    'coachName': 'Coach Anita',
    'coachingType': 'FREE_TRIAL',
    'startDate': '2026-03-02T09:00:00Z',
    'endDate': '2026-03-12T09:00:00Z',
    'trialDurationDays': 10,
    'engagementStatus': 'expired',
    'reportVersion': '1.0',
    'generatedAt': '2026-03-12T10:00:00Z',
    'storedAt': '2026-03-12T10:00:00Z',
  },
  {
    'requestId': 'req_older',
    'coachId': 'coach_2',
    'coachName': 'Coach Ravi',
    'coachingType': 'PAID',
    'startDate': '2025-11-01T09:00:00Z',
    'endDate': '2025-12-01T09:00:00Z',
    'trialDurationDays': null,
    'engagementStatus': 'ended',
    'reportVersion': '1.0',
    'generatedAt': '2025-12-01T10:00:00Z',
    'storedAt': '2025-12-01T10:00:00Z',
  },
];

Map<String, dynamic> _fullReport() => {
      'requestId': 'req_newest',
      'athleteId': 'athlete_1',
      'coachId': 'coach_1',
      'coachName': 'Coach Anita',
      'coachingType': 'FREE_TRIAL',
      'reportVersion': '1.0',
      'generatedAt': '2026-03-12T10:00:00Z',
      'status': 'generated',
      'period': {'durationDays': 10, 'elapsedDays': 10},
      'plan': <String, dynamic>{},
      'activity': <String, dynamic>{},
      'dataQuality': {'warnings': <String>[]},
      'metrics': {
        'mealFollowThrough': {
          'available': true,
          'submitted': 18,
          'expected': 30,
          'percent': 60.0,
        },
        'mealQuality': {'available': false, 'reason': 'no_reviewed_meals'},
        'planEvolution': {
          'wording': 'coach_customized_ai_plan',
          'aiPlanApplied': true,
          'coachCustomizedPlanApplied': true,
          'customizationConfirmed': true,
          'modifications': 6,
          'planSaves': 7,
          'segments': <dynamic>[],
        },
        'workoutAdherence': {'available': 'partial'},
        'progress': <String, dynamic>{},
        'followUp': {
          'available': false,
          'reason': 'follow_up_completion_not_tracked',
        },
        'overall': {
          'available': false,
          'reason': 'scoring_model_not_finalized',
        },
      },
    };

http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status, headers: {'content-type': 'application/json'});

TrialReportRepository _repo(MockClient mock) => TrialReportRepository(
    apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'));

/// Every request the app makes in these tests, so a test can assert which
/// endpoint was hit and that nothing else was.
class _Recorder {
  final paths = <String>[];

  MockClient client({List<Object>? history, Object? report, int status = 200}) =>
      MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/api/trial-reports') {
          if (status != 200) return http.Response('boom', status);
          return _json({'reports': history ?? const [], 'count':
              (history ?? const []).length});
        }
        if (request.url.path.startsWith('/api/trial-report/')) {
          return report == null
              ? http.Response('{}', 404)
              : _json(report);
        }
        return http.Response('{}', 404);
      });
}

/// The history screen inside a router that also owns the detail route, so a
/// tap can be followed all the way through.
Future<GoRouter> _pumpHistory(
  WidgetTester tester,
  TrialReportRepository repository,
) async {
  final router = GoRouter(
    initialLocation: '/trial-reports',
    routes: [
      GoRoute(
        path: '/trial-reports',
        builder: (_, _) => TrialReportHistoryScreen(repository: repository),
      ),
      GoRoute(
        path: '/trial-report/:requestId',
        builder: (_, state) => TrialReportScreen(
          requestId: state.pathParameters['requestId']!,
          repository: repository,
        ),
      ),
    ],
  );
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  return router;
}

void main() {
  group('TrialReportRepository.fetchHistory', () {
    test('parses summaries in the order the backend returned them', () async {
      final rows = await _repo(_Recorder().client(history: _kSummaries))
          .fetchHistory();
      expect(rows.map((r) => r.requestId), ['req_newest', 'req_older']);
      expect(rows.first.coachName, 'Coach Anita');
      expect(rows.first.isFreeTrial, isTrue);
      expect(rows.last.isFreeTrial, isFalse);
      expect(rows.first.trialDurationDays, 10);
      expect(rows.last.engagementStatus, 'ended');
    });

    test('an empty history is an empty list, not an error', () async {
      expect(await _repo(_Recorder().client(history: const [])).fetchHistory(),
          isEmpty);
    });

    test('rows without a requestId are dropped rather than half-rendered',
        () async {
      final rows = await _repo(_Recorder().client(history: [
        {'coachName': 'No id here'},
        _kSummaries.first,
      ])).fetchHistory();
      expect(rows.map((r) => r.requestId), ['req_newest']);
    });

    test('a history row carries no metrics a screen could render', () async {
      final row =
          (await _repo(_Recorder().client(history: _kSummaries)).fetchHistory())
              .first;
      // TrialReportSummary has no metrics API at all, so a history row cannot
      // display "0 meals" for data that was never fetched.
      expect(row, isA<TrialReportSummary>());
    });

    test('a listing failure propagates rather than looking empty', () async {
      expect(
        () => _repo(_Recorder().client(status: 500)).fetchHistory(),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('TrialReportHistoryScreen', () {
    testWidgets('shows a loading indicator on the first frame', (tester) async {
      await _pumpHistory(tester, _repo(_Recorder().client(history: const [])));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets("renders each report's metadata", (tester) async {
      await _pumpHistory(tester, _repo(_Recorder().client(history: _kSummaries)));
      await tester.pumpAndSettle();

      expect(find.text('Coach Anita'), findsOneWidget);
      expect(find.text('Coach Ravi'), findsOneWidget);
      expect(find.text('Trial'), findsOneWidget); // FREE_TRIAL
      expect(find.text('Coaching'), findsOneWidget); // PAID
      expect(find.text('2 Mar 2026 – 12 Mar 2026'), findsOneWidget);
      expect(find.textContaining('10 days'), findsOneWidget);
      expect(find.textContaining('Completed'), findsOneWidget); // expired
      expect(find.textContaining('Ended early'), findsOneWidget); // ended
    });

    testWidgets('preserves the backend ordering, newest first', (tester) async {
      await _pumpHistory(tester, _repo(_Recorder().client(history: _kSummaries)));
      await tester.pumpAndSettle();
      final anita = tester.getTopLeft(find.text('Coach Anita')).dy;
      final ravi = tester.getTopLeft(find.text('Coach Ravi')).dy;
      expect(anita, lessThan(ravi));
    });

    testWidgets('shows an empty state when there are no reports',
        (tester) async {
      await _pumpHistory(tester, _repo(_Recorder().client(history: const [])));
      await tester.pumpAndSettle();
      expect(find.text('No reports yet'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows an error state with a working retry', (tester) async {
      var attempt = 0;
      final mock = MockClient((request) async {
        attempt++;
        if (attempt == 1) return http.Response('boom', 500);
        return _json({'reports': _kSummaries, 'count': 2});
      });
      await _pumpHistory(tester, _repo(mock));
      await tester.pumpAndSettle();

      expect(find.text('Could not load your reports'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Coach Anita'), findsOneWidget);
      expect(attempt, 2);
    });

    testWidgets('tapping a row opens that exact requestId', (tester) async {
      final recorder = _Recorder();
      await _pumpHistory(
          tester,
          _repo(recorder.client(
              history: _kSummaries, report: _fullReport())));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Coach Ravi'));
      await tester.pumpAndSettle();

      // The detail screen fetched the SECOND row's engagement, not the
      // first — proving the tapped row's own requestId was carried through.
      expect(recorder.paths, contains('/api/trial-report/req_older'));
      expect(recorder.paths, isNot(contains('/api/trial-report/req_newest')));
    });

    testWidgets('never reads coaching documents to rebuild a report',
        (tester) async {
      final recorder = _Recorder();
      await _pumpHistory(
          tester,
          _repo(recorder.client(
              history: _kSummaries, report: _fullReport())));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Coach Anita'));
      await tester.pumpAndSettle();

      // Only the two report endpoints were used — no coaching, plan, or
      // check-in data was fetched to reconstruct anything.
      expect(recorder.paths.toSet(), {
        '/api/trial-reports',
        '/api/trial-report/req_newest',
      });
    });
  });

  group('TrialReportScreen still works (Step 3 regression)', () {
    /// The report body is a lazy ListView, so a tall surface is needed for
    /// the whole page to be built and findable in one pass.
    Future<void> pumpReport(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: TrialReportScreen(
          requestId: 'req_newest',
          repository: _repo(_Recorder().client(report: _fullReport())),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('renders the backend figures without recomputing them',
        (tester) async {
      await pumpReport(tester);
      expect(find.text('18'), findsOneWidget); // submitted, verbatim
      expect(find.text('30'), findsOneWidget); // expected, verbatim
      expect(find.text('60%'), findsOneWidget); // the backend's own percent
      expect(find.text('6'), findsOneWidget); // coach modifications
    });

    testWidgets('unavailable metrics are explained, never shown as 0%',
        (tester) async {
      await pumpReport(tester);
      expect(find.text('Follow-up'), findsOneWidget);
      expect(find.text('Overall ZITLAS Score'), findsOneWidget);
      expect(find.text('Not available yet'), findsNWidgets(2));
      // The critical assertion: no fabricated zero anywhere on the page.
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('an absent report reads as pending, not as a failure',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TrialReportScreen(
          requestId: 'req_missing',
          repository: _repo(_Recorder().client()),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Report not ready'), findsOneWidget);
    });

    test('parsing takes the stored numbers verbatim', () {
      final parsed = TrialReport.fromMap(_fullReport())!;
      expect(parsed.mealFollowThrough.percent, 60.0);
      expect(parsed.mealFollowThrough.integer('submitted'), 18);
      expect(parsed.mealFollowThrough.integer('expected'), 30);
      expect(parsed.planEvolution.modifications, 6);
      expect(parsed.elapsedDays, 10);
      // Unavailable stays unavailable, with no derived percentage.
      expect(parsed.followUp.isAvailable, isFalse);
      expect(parsed.followUp.percent, isNull);
      expect(parsed.overall.percent, isNull);
    });

    test('never claims the coach created the plan', () {
      final parsed = TrialReport.fromMap(_fullReport())!;
      expect(parsed.planEvolution.wording, 'coach_customized_ai_plan');
      expect(parsed.planEvolution.aiPlanApplied, isTrue);
      expect(parsed.planEvolution.customizationConfirmed, isTrue);
    });
  });
}
