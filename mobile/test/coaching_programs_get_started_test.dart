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
import 'package:zitlas_mobile/features/coaching_programs/presentation/coaching_programs_controller.dart';
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
/// button with no way to choose one. On open the screen also restores the
/// athlete's current program from the server (GET /requests/me), so an app
/// restart never hides a request that is waiting or a program that runs.

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
  int meStatus = 200;
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

  /// A running program's server fields, as POST /pay writes them.
  Map<String, dynamic> paid(Map<String, dynamic> base, DateTime start, {String status = 'active'}) {
    final days = base['durationDays'] as int;
    return {
      ...base,
      'status': status,
      'paymentStatus': 'paid',
      'paidAt': start.toIso8601String(),
      'startedAt': start.toIso8601String(),
      'endsAt': start.add(Duration(days: days)).toIso8601String(),
      'amountPaidPaise': base['pricePaise'],
    };
  }

  /// Waiting (on the expert or on payment) or still running — what
  /// GET /requests/me reports as `current`.
  static bool _isCurrent(Map<String, dynamic> r) {
    final s = r['status'];
    if (s == 'pending_expert_acceptance' || s == 'accepted') return true;
    if (s != 'active') return false;
    final ends = DateTime.tryParse('${r['endsAt'] ?? ''}');
    return ends == null || ends.isAfter(DateTime.now());
  }

  late final CoachingProgramsRepository repo = CoachingProgramsRepository(
    apiClient: ApiClient(
      baseUrl: 'https://api.test',
      httpClient: MockClient((r) async {
        final path = r.url.path;
        final seg = r.url.pathSegments; // [api, coaching-programs, ...]
        calls.add('${r.method} $path');
        if (r.method == 'GET' && path == '/api/coaching-programs/requests/me') {
          if (meStatus != 200) return _res({'detail': 'firestore_unavailable'}, meStatus);
          final current = request;
          return _res({
            'requests': [?current],
            'current': current != null && _isCurrent(current) ? current : null,
          });
        }
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
                    'expertise': e.key == 'coach-1' ? ['Fat loss', 'Muscle gain'] : <String>[],
                    'photoUrl': e.key == 'coach-2' ? 'https://images.test/vikram.jpg' : null,
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
          request = paid(request!, DateTime.now().toUtc());
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

Finder _detail(String key, String text) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.text(text));

final _picker = find.byKey(const Key('programExpertPicker'));
final _confirm = find.byKey(const Key('coachingProgramConfirm'));
final _send = find.byKey(const Key('coachingProgramConfirmSend'));
const _me = 'GET /api/coaching-programs/requests/me';

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
        expect(server.calls, [_me], reason: "on open, only the athlete's current program is restored");

        await _tap(tester, _start(program.id));
        expect(_picker, findsOneWidget);
        expect(server.calls.last, 'GET /api/coaching-programs/programs/${program.id}/experts');
        final price = _prices['coach-1']![program.id]!;
        final row = find.byKey(const Key('programExpert_coach-1'));
        expect(find.descendant(of: row, matching: find.text(formatProgramPrice(price))), findsOneWidget,
            reason: "the expert's OWN server price for THIS program");
        expect(find.descendant(of: row, matching: find.text('Fat loss · Muscle gain')), findsOneWidget,
            reason: 'their expertise, from their profile');

        await _tap(tester, find.byKey(const Key('programExpertSelect_coach-1')));
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

      expect(server.calls, ['GET /api/coaching-programs/experts/coach-1']);
      await _tap(tester, _start('1_month'));
      expect(_picker, findsNothing);
      expect(_confirm, findsOneWidget);
      await _tap(tester, _send);
      expect(server.posts, [
        {'expertId': 'coach-1', 'programId': '1_month'},
      ]);
    });

    testWidgets(
        "an expert who doesn't offer a program: it says so, and Choose Another Expert is the athlete's choice",
        (tester) async {
      final server = _Server();
      await _pump(tester, server, expertId: 'coach-2');

      expect(_inCard('3_month', find.text(kProgramNotOffered)), findsOneWidget);
      expect(_inCard('3_month', find.text('Get Started')), findsOneWidget);
      expect(tester.widget<FilledButton>(_start('3_month')).onPressed, isNull,
          reason: 'Get Started only when the server can create the request');
      expect(find.text('Your expert: Vikram Shah'), findsOneWidget, reason: 'never switched automatically');
      await _tap(tester, find.byKey(const Key('coachingProgramChooseAnother_3_month')));
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

    testWidgets('after a decline: the decline is shown, Get Started can ask again, and another expert can be chosen',
        (tester) async {
      final server = _Server();
      server.request = server.req('coach-1', '10_day', 'declined');
      await _pump(tester, server, expertId: 'coach-1');

      expect(_inCard('10_day', find.text(kProgramDeclinedTitle)), findsOneWidget);
      expect(tester.widget<FilledButton>(_start('10_day')).onPressed, isNotNull);
      await _tap(tester, find.byKey(const Key('coachingProgramChooseAnother_10_day')));
      expect(_picker, findsOneWidget);
      await _choose(tester, 'coach-2');
      await _tap(tester, _send);
      expect(server.posts, [
        {'expertId': 'coach-2', 'programId': '10_day'},
      ]);
      expect(find.text('Your expert: Vikram Shah'), findsOneWidget);
    });

    testWidgets("an expert's photo is shown when they have one — a broken one falls back",
        (tester) async {
      final server = _Server();
      await _pump(tester, server);
      await _tap(tester, _start('10_day'));

      final avatar = tester.widget<CircleAvatar>(find.descendant(
        of: find.byKey(const Key('programExpert_coach-2')),
        matching: find.byType(CircleAvatar),
      ));
      expect((avatar.foregroundImage as NetworkImage?)?.url, 'https://images.test/vikram.jpg');
      expect(find.descendant(of: find.byKey(const Key('programExpert_coach-1')), matching: find.text('AR')),
          findsOneWidget, reason: 'no photo: initials');
      expect(tester.takeException(), isNull, reason: 'an image that fails to load never breaks the sheet');
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

  group('restored from the server — an app restart never hides a program', () {
    testWidgets('a request waiting on the expert comes back, with its expert', (tester) async {
      final server = _Server();
      server.request = server.req('coach-1', '10_day', 'pending_expert_acceptance');
      await _pump(tester, server);

      expect(server.calls, [_me, 'GET /api/coaching-programs/experts/coach-1']);
      expect(_inCard('10_day', find.text(kProgramPendingTitle)), findsOneWidget);
      expect(find.text('Your expert: Asha Rao'), findsOneWidget);
      expect(_start('10_day'), findsNothing, reason: 'nothing to start while it waits');
    });

    testWidgets('an accepted request comes back with Pay & Start — before and after a restart',
        (tester) async {
      final server = _Server();
      server.request = server.req('coach-1', '1_month', 'accepted', paymentStatus: 'payment_required');
      await _pump(tester, server);
      expect(_inCard('1_month', find.text(kProgramAcceptedTitle)), findsOneWidget);
      expect(find.byKey(const Key('coachingProgramPay_1_month')), findsOneWidget);

      // Restart: the screen is thrown away and opened again from nothing.
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, server);
      expect(find.byKey(const Key('coachingProgramPay_1_month')), findsOneWidget);
      expect(server.pays, 0, reason: 'opening the screen never pays');
    });

    testWidgets('a running program comes back with its server details', (tester) async {
      final server = _Server();
      final start = DateTime.now().toUtc().subtract(const Duration(days: 2));
      server.request = server.paid(server.req('coach-1', '3_month', 'active'), start);
      await _pump(tester, server);

      final end = DateTime.parse(server.request!['endsAt'] as String);
      expect(_inCard('3_month', find.text(kProgramActiveTitle)), findsOneWidget);
      expect(_detail('coachingProgramStart_3_month', formatProgramDate(start)), findsOneWidget);
      expect(_detail('coachingProgramEnd_3_month', formatProgramDate(end)), findsOneWidget);
      expect(_detail('coachingProgramPaid_3_month', '₹34,999'), findsOneWidget);
      expect(_detail('coachingProgramState_3_month', 'Active'), findsOneWidget);
    });

    testWidgets('a completed program shows as completed, and a new one can start', (tester) async {
      final server = _Server();
      final start = DateTime.now().toUtc().subtract(const Duration(days: 12));
      server.request = server.paid(server.req('coach-1', '10_day', 'active'), start, status: 'completed');
      await _pump(tester, server, expertId: 'coach-1');

      expect(_inCard('10_day', find.text(kProgramCompletedTitle)), findsOneWidget);
      expect(_detail('coachingProgramState_10_day', 'Completed'), findsOneWidget);
      expect(find.text(kProgramPendingTitle), findsNothing,
          reason: 'a completed program is never shown as waiting');
      for (final p in kCoachingPrograms) {
        expect(tester.widget<FilledButton>(_start(p.id)).onPressed, isNotNull, reason: p.id);
      }
    });
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

    testWidgets('if the current program cannot be restored, Get Started still works', (tester) async {
      final server = _Server()..meStatus = 503;
      await _pump(tester, server);
      expect(_inCard('10_day', find.text(kProgramChooseExpertToPrice)), findsOneWidget);
      await _tap(tester, _start('10_day'));
      expect(_picker, findsOneWidget);
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

    test('two sends at the same moment make ONE request', () async {
      final server = _Server();
      final c = CoachingProgramsController(expertId: 'coach-1', repository: server.repo);
      await c.load();
      final results = await Future.wait([c.requestProgram('10_day'), c.requestProgram('10_day')]);
      expect(server.posts, hasLength(1));
      expect(results.where((r) => r.ok), hasLength(1));
      c.dispose();
    });

    testWidgets('choosing an expert already asked shows that request — no second one',
        (tester) async {
      // Even when the restore on open fails, the expert's own answer carries
      // the request that is already waiting.
      final server = _Server()..meStatus = 503;
      server.request = server.req('coach-1', '10_day', 'pending_expert_acceptance');
      await _pump(tester, server);

      await _tap(tester, _start('10_day'));
      await _choose(tester, 'coach-1');
      expect(_confirm, findsNothing);
      expect(server.posts, isEmpty);
      expect(find.text(kProgramAlreadyRequested), findsOneWidget);
      expect(_inCard('10_day', find.text(kProgramPendingTitle)), findsOneWidget);
    });

    testWidgets('a repeat the server answers with the waiting request is not a new one',
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
        expect(_detail('coachingProgramEnd_${program.id}', formatProgramDate(end)), findsOneWidget,
            reason: "the app shows the server's end date — it never computes one");
        expect(_detail('coachingProgramStart_${program.id}', formatProgramDate(start)), findsOneWidget);
        expect(_detail('coachingProgramPaid_${program.id}',
                formatProgramPrice(_prices['coach-1']![program.id]!)),
            findsOneWidget);
        expect(_detail('coachingProgramState_${program.id}', 'Active'), findsOneWidget);
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
