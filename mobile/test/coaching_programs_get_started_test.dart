import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/coaching_programs/coaching_programs.dart';
import 'package:zitlas_mobile/features/coaching_programs/data/coaching_programs_repository.dart';
import 'package:zitlas_mobile/features/coaching_programs/models/program_offer.dart';
import 'package:zitlas_mobile/features/coaching_programs/presentation/coaching_programs_screen.dart';

/// GET STARTED — from each program card into the EXISTING program flow.
///
///     Get Started -> choose your expert (server list, server prices)
///       -> review -> POST /requests -> pending -> the expert accepts
///       -> Pay & Start (POST /requests/{id}/pay) -> active for 10/30/90 days
///
/// The dead end this pins: an app build from Phase 1 answered Get Started
/// with "Program selection is coming next.", and a screen opened without an
/// expert — or with one who doesn't offer a program — showed a disabled
/// button with no way to choose one.

const _json = {'content-type': 'application/json; charset=utf-8'};

http.Response _res(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _json);

/// Each expert's own server-side prices. coach-2 does not offer 3 months.
const _prices = {
  'coach-1': {'10_day': 499900, '1_month': 1299900, '3_month': 3499900},
  'coach-2': {'10_day': 399900, '1_month': 999900},
};
const _names = {'coach-1': 'Asha Rao', 'coach-2': 'Vikram Shah'};
const _days = {'10_day': 10, '1_month': 30, '3_month': 90};

/// /api/coaching-programs as the app sees it.
class _Server {
  /// The athlete's request, as the server has it.
  Map<String, dynamic>? request;
  int expertsStatus = 200;
  (int, Object?)? postOverride;
  bool postNetworkFailure = false;
  (int, Object?)? payOverride;

  /// "METHOD path", in order.
  final calls = <String>[];
  final posts = <Map<String, dynamic>>[];
  int pays = 0;

  Map<String, dynamic> req(String expertId, String programId, String status,
          {String paymentStatus = 'unpaid'}) =>
      {
        'requestId': 'CPR_1',
        'athleteId': 'me',
        'expertId': expertId,
        'expertName': _names[expertId],
        'programId': programId,
        'programTitle': 'Program',
        'programType': 'diet',
        'durationDays': _days[programId],
        'pricePaise': _prices[expertId]![programId],
        'currency': 'INR',
        'status': status,
        'paymentStatus': paymentStatus,
        'requestedAt': '2026-09-13T06:00:00+00:00',
      };

  late final CoachingProgramsRepository repo = CoachingProgramsRepository(
    apiClient: ApiClient(
      baseUrl: 'https://api.test',
      httpClient: MockClient((r) async {
        final path = r.url.path;
        final seg = r.url.pathSegments; // [api, coaching-programs, ...]
        calls.add('${r.method} $path');
        if (r.method == 'GET' && seg.length == 5 && seg[2] == 'programs' && seg[4] == 'experts') {
          if (expertsStatus != 200) return _res({'detail': 'firestore_unavailable'}, expertsStatus);
          final pid = seg[3];
          return _res({
            'programId': pid,
            'durationDays': _days[pid],
            'currency': 'INR',
            'experts': [
              for (final e in _prices.entries)
                if (e.value[pid] != null)
                  {
                    'expertId': e.key,
                    'expertName': _names[e.key],
                    'specialization': 'Sports Nutritionist',
                    'pricePaise': e.value[pid],
                  },
            ],
          });
        }
        if (r.method == 'GET' && seg.length == 4 && seg[2] == 'experts') {
          final id = seg[3];
          return _res({
            'expertId': id,
            'expertName': _names[id],
            'currency': 'INR',
            'programs': [
              for (final p in kCoachingPrograms)
                {
                  'programId': p.id,
                  'pricePaise': _prices[id]![p.id],
                  'available': _prices[id]![p.id] != null,
                },
            ],
            'request': request != null && request!['expertId'] == id ? request : null,
          });
        }
        if (r.method == 'POST' && path == '/api/coaching-programs/requests') {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          posts.add(body);
          if (postNetworkFailure) throw http.ClientException('Connection reset by peer');
          final override = postOverride;
          if (override != null) return _res(override.$2, override.$1);
          request = req(body['expertId'] as String, body['programId'] as String,
              'pending_expert_acceptance');
          return _res({'success': true, 'alreadyRequested': false, 'request': request});
        }
        if (r.method == 'POST' && path == '/api/coaching-programs/requests/CPR_1/pay') {
          pays++;
          final override = payOverride;
          if (override != null) return _res(override.$2, override.$1);
          // The SERVER decides the dates: startedAt + durationDays.
          final start = DateTime.now().toUtc();
          final days = request!['durationDays'] as int;
          request = {
            ...request!,
            'status': 'active',
            'paymentStatus': 'paid',
            'paidAt': start.toIso8601String(),
            'startedAt': start.toIso8601String(),
            'endsAt': start.add(Duration(days: days)).toIso8601String(),
            'amountPaidPaise': request!['pricePaise'],
          };
          return _res({'success': true, 'already': false, 'request': request, 'balance': 100.0});
        }
        return _res({'detail': 'not_found'}, 404);
      }),
    ),
  );
}

Future<void> _pump(WidgetTester tester, _Server server, {String? expertId}) async {
  tester.view.physicalSize = const Size(800, 7000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: CoachingProgramsScreen(expertId: expertId, repository: server.repo),
  ));
  await tester.pumpAndSettle();
}

Finder _start(String id) => find.byKey(Key('coachingProgramGetStarted_$id'));

Finder _inCard(String id, Finder f) =>
    find.descendant(of: find.byKey(Key('coachingProgram_$id')), matching: f);

final _picker = find.byKey(const Key('programExpertPicker'));
final _confirm = find.byKey(const Key('coachingProgramConfirm'));
final _send = find.byKey(const Key('coachingProgramConfirmSend'));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String expertId) =>
    _tap(tester, find.byKey(Key('programExpert_$expertId')));

void main() {
  group('Get Started opens the real program flow — for every program', () {
    for (final program in kCoachingPrograms) {
      testWidgets('${program.title}: choose an expert, review, request', (tester) async {
        final server = _Server();
        await _pump(tester, server);

        expect(_inCard(program.id, find.text(kProgramChooseExpertToPrice)), findsOneWidget);
        expect(tester.widget<FilledButton>(_start(program.id)).onPressed, isNotNull,
            reason: 'Get Started is never a dead end');
        expect(server.calls, isEmpty, reason: 'nothing is fetched until the athlete asks');

        await _tap(tester, _start(program.id));
        expect(_picker, findsOneWidget);
        expect(server.calls, ['GET /api/coaching-programs/programs/${program.id}/experts']);
        final price = _prices['coach-1']![program.id]!;
        expect(
          find.descendant(
            of: find.byKey(const Key('programExpert_coach-1')),
            matching: find.text(formatProgramPrice(price)),
          ),
          findsOneWidget,
          reason: "the expert's OWN server price for THIS program",
        );

        await _choose(tester, 'coach-1');
        expect(server.calls.last, 'GET /api/coaching-programs/experts/coach-1');
        expect(_confirm, findsOneWidget);
        expect(find.text('Request the ${program.title}?'), findsOneWidget);
        expect(find.textContaining('${formatProgramPrice(price)} · ${program.durationLabel}'),
            findsOneWidget);

        await _tap(tester, _send);

        expect(server.posts, [
          {'expertId': 'coach-1', 'programId': program.id},
        ], reason: 'the right program id, and never a price, status or duration');
        expect(find.text(kProgramRequestSent), findsOneWidget);
        expect(_inCard(program.id, find.text(kProgramPendingTitle)), findsOneWidget);
        expect(find.text('Your expert: Asha Rao'), findsOneWidget);
        expect(server.calls.every((c) => c.contains(' /api/coaching-programs/')), isTrue,
            reason: 'only the existing program endpoints — no second request system');
        expect(find.textContaining('coming next'), findsNothing);
      });
    }

    testWidgets('opened from an expert, Get Started goes straight to review', (tester) async {
      final server = _Server();
      await _pump(tester, server, expertId: 'coach-1');

      await _tap(tester, _start('1_month'));
      expect(_picker, findsNothing);
      expect(_confirm, findsOneWidget);
      await _tap(tester, _send);
      expect(server.posts, [
        {'expertId': 'coach-1', 'programId': '1_month'},
      ]);
    });

    testWidgets("an expert who doesn't offer a program: Choose Another Expert", (tester) async {
      final server = _Server();
      await _pump(tester, server, expertId: 'coach-2');

      expect(_inCard('3_month', find.text(kProgramUnavailable)), findsOneWidget);
      expect(_inCard('3_month', find.text(kProgramChooseAnotherExpert)), findsOneWidget);
      await _tap(tester, _start('3_month'));
      expect(_picker, findsOneWidget);
      expect(find.byKey(const Key('programExpert_coach-2')), findsNothing,
          reason: 'only experts who offer the program are listed');

      await _choose(tester, 'coach-1');
      await _tap(tester, _send);
      expect(server.posts, [
        {'expertId': 'coach-1', 'programId': '3_month'},
      ]);
      expect(find.text('Your expert: Asha Rao'), findsOneWidget);
    });

    testWidgets('cancelling the picker or the review sends nothing', (tester) async {
      final server = _Server();
      await _pump(tester, server);
      await _tap(tester, _start('10_day'));
      await tester.tapAt(const Offset(20, 20)); // outside the sheet
      await tester.pumpAndSettle();
      expect(_picker, findsNothing);

      await _tap(tester, _start('10_day'));
      await _choose(tester, 'coach-2');
      await _tap(tester, find.byKey(const Key('coachingProgramConfirmCancel')));
      expect(server.posts, isEmpty);
      expect(find.text(kProgramRequestSent), findsNothing);
    });
  });

  test('"Program selection is coming next" is gone from the app', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final f in files) {
      final src = f.readAsStringSync();
      expect(src.contains('coming next'), isFalse, reason: f.path);
      expect(src.contains('kProgramSelectionComingSoon'), isFalse, reason: f.path);
    }
  });

  group('failures are shown honestly — nothing claims success', () {
    testWidgets("the expert list can't load: the sheet says so, and Retry reloads", (tester) async {
      final server = _Server()..expertsStatus = 503;
      await _pump(tester, server);

      await _tap(tester, _start('10_day'));
      expect(find.byKey(const Key('programExpertPickerError')), findsOneWidget);
      expect(find.textContaining("Couldn't reach ZITLAS"), findsOneWidget);

      server.expertsStatus = 200;
      await _tap(tester, find.byKey(const Key('programExpertPickerRetry')));
      expect(find.byKey(const Key('programExpert_coach-1')), findsOneWidget);
      expect(server.posts, isEmpty);
    });

    for (final (label, status, detail, says) in <(String, int, Object?, String)>[
      ('another active coach (409)', 409, 'active_coaching_exists', 'active personal coach'),
      ('an open coaching request (409)', 409, 'open_request_exists', 'waiting for a response'),
      ('a withdrawn price (409)', 409, 'program_unavailable', "isn't available"),
      ('an expired session (401)', 401, 'invalid_token', 'sign in again'),
      ('a forbidden account (403)', 403, 'forbidden', 'sign in again'),
      ('the server is down (503)', 503, 'firestore_unavailable', "Couldn't reach ZITLAS"),
    ]) {
      testWidgets('a refused request — $label — says why, never "Request sent"', (tester) async {
        final server = _Server()..postOverride = (status, {'detail': detail});
        await _pump(tester, server, expertId: 'coach-1');

        await _tap(tester, _start('10_day'));
        await _tap(tester, _send);
        expect(find.textContaining(says), findsOneWidget);
        expect(find.text(kProgramRequestSent), findsNothing);
        expect(_inCard('10_day', find.text(kProgramPendingTitle)), findsNothing);
      });
    }

    testWidgets('no connection: the request is not reported as sent', (tester) async {
      final server = _Server()..postNetworkFailure = true;
      await _pump(tester, server, expertId: 'coach-1');

      await _tap(tester, _start('10_day'));
      await _tap(tester, _send);
      expect(find.textContaining("Couldn't reach ZITLAS"), findsOneWidget);
      expect(find.text(kProgramRequestSent), findsNothing);
    });
  });

  group('no duplicate requests', () {
    testWidgets('a double tap on Get Started opens ONE picker', (tester) async {
      final server = _Server();
      await _pump(tester, server);

      await tester.tap(_start('10_day'));
      await tester.tap(_start('10_day'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(_picker, findsOneWidget);
      expect(server.calls.where((c) => c.contains('/programs/')), hasLength(1));
    });

    testWidgets('choosing an expert already asked shows that request — no second one',
        (tester) async {
      final server = _Server();
      server.request = server.req('coach-1', '10_day', 'pending_expert_acceptance');
      await _pump(tester, server);

      await _tap(tester, _start('10_day'));
      await _choose(tester, 'coach-1');
      expect(_confirm, findsNothing);
      expect(server.posts, isEmpty);
      expect(find.text(kProgramAlreadyRequested), findsOneWidget);
      expect(_inCard('10_day', find.text(kProgramPendingTitle)), findsOneWidget);
    });

    testWidgets("a repeat the server answers with the waiting request is not a new one",
        (tester) async {
      final server = _Server();
      server.postOverride = (
        200,
        {
          'success': true,
          'alreadyRequested': true,
          'request': server.req('coach-1', '10_day', 'pending_expert_acceptance'),
        },
      );
      await _pump(tester, server, expertId: 'coach-1');

      await _tap(tester, _start('10_day'));
      await _tap(tester, _send);
      expect(find.text(kProgramAlreadyRequested), findsOneWidget);
      expect(find.text(kProgramRequestSent), findsNothing);
    });
  });

  group('after the expert accepts: the existing payment flow', () {
    for (final program in kCoachingPrograms) {
      testWidgets('${program.title}: Pay & Start -> active for ${_days[program.id]} days',
          (tester) async {
        final server = _Server();
        server.request =
            server.req('coach-1', program.id, 'accepted', paymentStatus: 'payment_required');
        await _pump(tester, server, expertId: 'coach-1');

        expect(_inCard(program.id, find.text(kProgramAcceptedTitle)), findsOneWidget);
        expect(find.text(kProgramStarted), findsNothing, reason: 'nothing is charged yet');

        await _tap(tester, find.byKey(Key('coachingProgramPay_${program.id}')));

        expect(server.pays, 1);
        expect(find.text(kProgramStarted), findsOneWidget);
        expect(_inCard(program.id, find.text(kProgramActiveTitle)), findsOneWidget);
        final start = DateTime.parse(server.request!['startedAt'] as String);
        final end = DateTime.parse(server.request!['endsAt'] as String);
        expect(end.difference(start).inDays, _days[program.id], reason: 'the server decides');
        expect(_inCard(program.id, find.textContaining('Ends ${formatProgramDate(end)}')),
            findsOneWidget, reason: "the app shows the server's end date — it never computes one");
      });
    }

    testWidgets('a short wallet shows Add Funds — nothing charged, no checkout opened',
        (tester) async {
      final server = _Server()
        ..payOverride = (
          402,
          {
            'detail': {
              'error': 'insufficient_wallet_balance',
              'required': 499900,
              'available': 100000,
              'currency': 'INR',
            },
          },
        );
      server.request = server.req('coach-1', '10_day', 'accepted', paymentStatus: 'payment_required');
      await _pump(tester, server, expertId: 'coach-1');

      await _tap(tester, find.byKey(const Key('coachingProgramPay_10_day')));
      expect(find.byKey(const Key('insufficientBalanceCard')), findsOneWidget);
      expect(find.text(kProgramStarted), findsNothing);
      expect(_inCard('10_day', find.text(kProgramActiveTitle)), findsNothing);
      expect(find.byType(BottomSheet), findsNothing,
          reason: 'Add Funds opens only when the athlete taps it — never Razorpay by itself');
    });
  });

  test('program durations are 10 / 30 / 90 days, and the app never computes the dates', () {
    expect({for (final p in kCoachingPrograms) p.id: p.durationLabel},
        {'10_day': '10 days', '1_month': '30 days', '3_month': '90 days'});
    for (final path in [
      'lib/features/coaching_programs/presentation/coaching_programs_screen.dart',
      'lib/features/coaching_programs/presentation/coaching_programs_controller.dart',
    ]) {
      expect(File(path).readAsStringSync().contains('Duration(days'), isFalse, reason: path);
    }
  });
}
