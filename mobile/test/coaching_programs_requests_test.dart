import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/core/network/api_exception.dart';
import 'package:zitlas_mobile/features/coaching_programs/coaching_programs.dart';
import 'package:zitlas_mobile/features/coaching_programs/data/coaching_programs_repository.dart';
import 'package:zitlas_mobile/features/coaching_programs/models/program_offer.dart';
import 'package:zitlas_mobile/features/coaching_programs/presentation/coaching_programs_screen.dart';

/// Personal Coaching Programs — prices and requests (Phase 2).
///
///     expert's server-side price -> Get Started -> request -> expert answers
///
/// What these protect:
///   * every price on screen is the selected expert's, from the server — an
///     unpriced program says the expert hasn't priced it, never ₹0, and a
///     failed load is an error, never "not offered";
///   * Get Started sends ONLY the expert and the program (never a price);
///   * the athlete sees pending / accepted (with Pay & Start) / declined.
///     Paying itself is covered by coaching_programs_payment_test.dart.

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _req(String programId, String status, {int? price = 499900}) => {
      'requestId': 'CPR_1',
      'athleteId': 'me',
      'expertId': 'coach-1',
      'expertName': 'Asha Rao',
      'programId': programId,
      'programTitle': 'Program',
      'programType': 'diet',
      'durationDays': 10,
      'pricePaise': price,
      'currency': 'INR',
      'status': status,
      'paymentStatus': 'unpaid',
      'requestedAt': '2026-09-13T06:00:00+00:00',
    };

/// A stand-in for /api/coaching-programs.
class _Backend {
  _Backend({
    Map<String, int?>? prices,
    this.request,
    this.failOffer = false,
    this.postStatus = 200,
    this.postBody,
  }) : prices = prices ?? {'10_day': 499900, '1_month': 1299900, '3_month': 3499950};

  Map<String, int?> prices;
  Map<String, dynamic>? request;
  bool failOffer;
  int postStatus;
  Map<String, dynamic>? postBody;

  /// False: the expert takes no program requests (`expertAvailable: false`).
  bool expertAvailable = true;

  final gets = <Uri>[];
  final posts = <Map<String, dynamic>>[];

  Map<String, dynamic> _offer() => {
        'expertId': 'coach-1',
        'expertName': 'Asha Rao',
        'expertAvailable': expertAvailable,
        'currency': 'INR',
        'programs': [
          for (final p in kCoachingPrograms)
            {
              'programId': p.id,
              'pricePaise': expertAvailable ? prices[p.id] : null,
              'available': expertAvailable && prices[p.id] != null,
              'unavailableReason': expertAvailable && prices[p.id] != null
                  ? null
                  : (expertAvailable ? 'not_priced' : 'expert_unavailable'),
            },
        ],
        'request': request,
      };

  late final CoachingProgramsRepository repo = CoachingProgramsRepository(
    apiClient: ApiClient(
      baseUrl: 'https://api.test',
      httpClient: MockClient((r) async {
        if (r.method == 'GET') {
          gets.add(r.url);
          return failOffer
              ? http.Response('{"detail":"firestore_unavailable"}', 503, headers: _json)
              : http.Response(jsonEncode(_offer()), 200, headers: _json);
        }
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        posts.add(body);
        if (postBody != null || postStatus != 200) {
          return http.Response(jsonEncode(postBody ?? {}), postStatus, headers: _json);
        }
        final programId = body['programId'] as String;
        request = _req(programId, 'pending_expert_acceptance', price: prices[programId]);
        return http.Response(
          jsonEncode({'success': true, 'alreadyRequested': false, 'request': request}),
          200,
          headers: _json,
        );
      }),
    ),
  );
}

Future<void> _pump(WidgetTester tester, _Backend backend) async {
  tester.view.physicalSize = const Size(800, 7000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: CoachingProgramsScreen(expertId: 'coach-1', repository: backend.repo),
  ));
  await tester.pumpAndSettle();
}

Finder _inCard(String id, Finder f) =>
    find.descendant(of: find.byKey(Key('coachingProgram_$id')), matching: f);

Finder _startKey(String id) => find.byKey(Key('coachingProgramGetStarted_$id'));

bool _enabled(WidgetTester tester, String id) =>
    tester.widget<FilledButton>(_startKey(id)).onPressed != null;

Future<void> _getStarted(WidgetTester tester, String id, {bool send = true}) async {
  await tester.tap(_startKey(id));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(send ? 'coachingProgramConfirmSend' : 'coachingProgramConfirmCancel')));
  await tester.pumpAndSettle();
}

void main() {
  group('REGRESSION: an assigned expert with a valid offer', () {
    testWidgets('shows "Get Started" — enabled — for all three programs, never "Currently unavailable"',
        (tester) async {
      await _pump(tester, _Backend());

      expect(find.text('Currently unavailable'), findsNothing);
      expect(find.text(kProgramChooseAnotherExpert), findsNothing,
          reason: 'the assigned expert stays selected');
      for (final p in kCoachingPrograms) {
        expect(_inCard(p.id, find.text('Get Started')), findsOneWidget, reason: p.id);
        expect(_enabled(tester, p.id), isTrue, reason: p.id);
      }
    });

    for (final program in kCoachingPrograms) {
      testWidgets(
          '${program.title}: Get Started sends the existing request to the assigned expert — nothing charged',
          (tester) async {
        final backend = _Backend();
        await _pump(tester, backend);

        await _getStarted(tester, program.id);

        expect(backend.posts, [
          {'expertId': 'coach-1', 'programId': program.id},
        ], reason: 'the assigned expert and the program — never a price');
        expect(find.text(kProgramRequestSent), findsOneWidget);
        expect(_inCard(program.id, find.text(kProgramPendingTitle)), findsOneWidget);
        expect(backend.gets.every((u) => u.path == '/api/coaching-programs/experts/coach-1'), isTrue,
            reason: 'no payment call at Get Started');
      });
    }
  });

  group('prices come from the server', () {
    testWidgets("each program shows the selected expert's own price", (tester) async {
      final backend = _Backend();
      await _pump(tester, backend);

      expect(backend.gets.single.path, '/api/coaching-programs/experts/coach-1');
      expect(_inCard('10_day', find.text('₹4,999')), findsOneWidget);
      expect(_inCard('1_month', find.text('₹12,999')), findsOneWidget);
      expect(_inCard('3_month', find.text('₹34,999.50')), findsOneWidget);
      for (final p in kCoachingPrograms) {
        expect(_enabled(tester, p.id), isTrue, reason: p.id);
      }
    });

    testWidgets(
        "an unpriced program says the expert hasn't priced it — never ₹0 — and switching experts is a separate choice",
        (tester) async {
      await _pump(tester, _Backend(prices: {'10_day': 499900, '1_month': null, '3_month': null}));

      expect(_inCard('1_month', find.text(kProgramNotOffered)), findsOneWidget);
      expect(_inCard('3_month', find.text(kProgramNotOffered)), findsOneWidget);
      expect(find.textContaining('₹0'), findsNothing);
      expect(find.text('Currently unavailable'), findsNothing);
      for (final p in kCoachingPrograms) {
        expect(_inCard(p.id, find.text('Get Started')), findsOneWidget,
            reason: '${p.id}: the main button is always Get Started');
      }
      expect(_enabled(tester, '10_day'), isTrue);
      expect(_enabled(tester, '1_month'), isFalse, reason: 'the server could not create this request');
      expect(_enabled(tester, '3_month'), isFalse);
      expect(find.byKey(const Key('coachingProgramChooseAnother_10_day')), findsNothing);
      expect(find.byKey(const Key('coachingProgramChooseAnother_1_month')), findsOneWidget);
      expect(find.byKey(const Key('coachingProgramChooseAnother_3_month')), findsOneWidget);
      expect(find.text('Your expert: Asha Rao'), findsOneWidget, reason: 'never switched automatically');
    });

    testWidgets("an expert taking no program requests is shown as such — not as \"not priced\"",
        (tester) async {
      await _pump(tester, _Backend()..expertAvailable = false);

      expect(find.text(kProgramExpertUnavailable), findsNWidgets(3));
      expect(find.text(kProgramNotOffered), findsNothing);
      for (final p in kCoachingPrograms) {
        expect(_enabled(tester, p.id), isFalse, reason: p.id);
        expect(find.byKey(Key('coachingProgramChooseAnother_${p.id}')), findsOneWidget, reason: p.id);
      }
    });

    test('a zero, negative, fractional or string price is not a price', () {
      final offer = ProgramOffer.fromJson({
        'expertId': 'coach-1',
        'expertName': 'Asha Rao',
        'programs': [
          {'programId': '10_day', 'pricePaise': 0, 'available': true},
          {'programId': '1_month', 'pricePaise': -100, 'available': true},
          {'programId': '3_month', 'pricePaise': 499.5, 'available': true},
          {'programId': 'x', 'pricePaise': '49900', 'available': true},
          {'programId': 'y', 'pricePaise': 49900, 'available': false},
        ],
      });
      expect(offer.prices, isEmpty);
    });

    testWidgets('if prices cannot load, nothing can start — and Retry reloads', (tester) async {
      final backend = _Backend(failOffer: true);
      await _pump(tester, backend);

      expect(find.byKey(const Key('coachingProgramsLoadError')), findsOneWidget);
      expect(find.text(kProgramPriceLoadFailed), findsNWidgets(3),
          reason: 'a failed load is an error — never "not offered"');
      expect(find.text(kProgramNotOffered), findsNothing);
      for (final p in kCoachingPrograms) {
        expect(_enabled(tester, p.id), isFalse, reason: p.id);
        expect(find.byKey(Key('coachingProgramChooseAnother_${p.id}')), findsNothing, reason: p.id);
      }

      backend.failOffer = false;
      await tester.tap(find.byKey(const Key('coachingProgramsRetry')));
      await tester.pumpAndSettle();
      expect(backend.gets, hasLength(2));
      expect(find.byKey(const Key('coachingProgramsLoadError')), findsNothing);
      expect(_inCard('10_day', find.text('₹4,999')), findsOneWidget);
    });
  });

  group('Get Started sends a request', () {
    testWidgets('it asks first, then sends ONLY the expert and the program', (tester) async {
      final backend = _Backend();
      await _pump(tester, backend);

      await tester.tap(_startKey('10_day'));
      await tester.pumpAndSettle();
      expect(find.textContaining('₹4,999 · 10 days'), findsOneWidget);
      expect(find.textContaining("You won't be charged now"), findsOneWidget);
      await tester.tap(find.byKey(const Key('coachingProgramConfirmSend')));
      await tester.pumpAndSettle();

      expect(backend.posts, [
        {'expertId': 'coach-1', 'programId': '10_day'},
      ], reason: 'no price, status or duration ever leaves the app');
      expect(find.text(kProgramRequestSent), findsOneWidget);
      expect(_inCard('10_day', find.text(kProgramPendingTitle)), findsOneWidget);
      expect(_startKey('10_day'), findsNothing, reason: 'nothing to do while it waits');
      expect(find.text(kProgramOtherRequestOpen), findsNWidgets(2));
      expect(_enabled(tester, '1_month'), isFalse);
      expect(_enabled(tester, '3_month'), isFalse);
    });

    testWidgets('Cancel sends nothing', (tester) async {
      final backend = _Backend();
      await _pump(tester, backend);
      await _getStarted(tester, '1_month', send: false);
      expect(backend.posts, isEmpty);
      expect(find.byKey(const Key('coachingProgramStatus_1_month')), findsNothing);
      expect(_enabled(tester, '1_month'), isTrue);
    });

    testWidgets("the status shows the server's snapshotted price", (tester) async {
      final backend = _Backend(postBody: {
        'success': true,
        'alreadyRequested': false,
        'request': _req('10_day', 'pending_expert_acceptance', price: 599900),
      });
      await _pump(tester, backend);
      await _getStarted(tester, '10_day');
      expect(_inCard('10_day', find.text('Program price: ₹5,999')), findsOneWidget);
    });

    testWidgets('asking again shows the request already waiting', (tester) async {
      await _pump(tester, _Backend(postBody: {
        'success': true,
        'alreadyRequested': true,
        'request': _req('10_day', 'pending_expert_acceptance'),
      }));
      await _getStarted(tester, '10_day');
      expect(find.text(kProgramAlreadyRequested), findsOneWidget);
      expect(_inCard('10_day', find.text(kProgramPendingTitle)), findsOneWidget);
    });

    testWidgets('a refused request says why, and reloads what the server knows', (tester) async {
      final backend = _Backend(postStatus: 409, postBody: {
        'detail': {'error': 'program_request_exists', 'programId': '1_month', 'requestId': 'CPR_9'},
      });
      await _pump(tester, backend);
      await _getStarted(tester, '10_day');
      expect(find.text('You already have a program request with this expert.'), findsOneWidget);
      expect(backend.gets, hasLength(2));
    });
  });

  group('where the request stands', () {
    testWidgets('pending, as loaded from the server', (tester) async {
      await _pump(tester, _Backend(request: _req('3_month', 'pending_expert_acceptance')));
      expect(_inCard('3_month', find.text(kProgramPendingTitle)), findsOneWidget);
      expect(_inCard('3_month', find.text(kProgramPendingBody)), findsOneWidget);
      expect(_startKey('3_month'), findsNothing);
    });

    testWidgets('accepted: the recorded price and Pay & Start — nothing charged yet', (tester) async {
      await _pump(tester, _Backend(request: _req('1_month', 'accepted', price: 1299900)));
      expect(_inCard('1_month', find.text(kProgramAcceptedTitle)), findsOneWidget);
      expect(_inCard('1_month', find.text(kProgramAcceptedBody)), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('coachingProgramAmount_1_month')),
          matching: find.text('₹12,999'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('coachingProgramPay_1_month')), findsOneWidget);
      expect(_startKey('1_month'), findsNothing);
      expect(_enabled(tester, '10_day'), isFalse, reason: 'one open request per expert');
      expect(find.byKey(const Key('insufficientBalanceCard')), findsNothing,
          reason: 'no Add Funds until a payment comes back short');
    });

    testWidgets('declined: the athlete sees it and can send a new request', (tester) async {
      await _pump(tester, _Backend(request: _req('10_day', 'declined')));
      expect(_inCard('10_day', find.text(kProgramDeclinedTitle)), findsOneWidget);
      for (final p in kCoachingPrograms) {
        expect(_enabled(tester, p.id), isTrue, reason: p.id);
      }
    });
  });

  group('repository and formatting', () {
    test('prices use Indian grouping, with paise only when there are any', () {
      expect(formatProgramPrice(100), '₹1');
      expect(formatProgramPrice(49950), '₹499.50');
      expect(formatProgramPrice(49905), '₹499.05');
      expect(formatProgramPrice(499900), '₹4,999');
      expect(formatProgramPrice(10000000), '₹1,00,000');
      expect(formatProgramPrice(12345678), '₹1,23,456.78');
    });

    test('request statuses', () {
      ProgramRequest r(String s) => ProgramRequest.fromJson(_req('10_day', s))!;
      expect(r('pending_expert_acceptance').status, ProgramRequestStatus.pendingExpertAcceptance);
      expect(r('pending_expert_acceptance').isOpen, isTrue);
      expect(r('accepted').isOpen, isTrue, reason: 'waiting for payment');
      expect(r('declined').isOpen, isFalse);
      expect(r('something_new').status, ProgramRequestStatus.unknown);
      expect(ProgramRequest.fromJson({'status': 'accepted'}), isNull);
    });

    test('the expert id is URL-encoded', () async {
      Uri? seen;
      final repo = CoachingProgramsRepository(
        apiClient: ApiClient(
          baseUrl: 'https://api.test',
          httpClient: MockClient((r) async {
            seen = r.url;
            return http.Response('{"programs":[]}', 200, headers: _json);
          }),
        ),
      );
      await repo.fetchOffer('a b/c');
      expect(seen!.path, '/api/coaching-programs/experts/a%20b%2Fc');
    });

    test('refusals become messages an athlete can act on', () {
      String m(int status, Object? body) =>
          CoachingProgramsRepository.messageFor(ApiException(message: 'x', statusCode: status, body: body));
      expect(m(409, {'detail': 'program_unavailable'}), contains("isn't available"));
      expect(m(409, {'detail': 'active_coaching_exists'}), contains('active personal coach'));
      expect(m(409, {'detail': 'open_request_exists'}), contains('waiting for a response'));
      expect(m(401, {'detail': 'invalid_token'}), contains('sign in again'));
      expect(m(503, null), contains("Couldn't reach ZITLAS"));
      expect(
        CoachingProgramsRepository.messageFor(const ApiException(message: 'offline')),
        contains("Couldn't reach ZITLAS"),
      );
      expect(m(418, null), 'Could not send your request. Please try again.');
    });
  });
}
