import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart' show SetOptions;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/auth/auth_state.dart';
import 'package:zitlas_mobile/features/coaching_programs/coaching_programs.dart';
import 'package:zitlas_mobile/features/coaching_programs/data/coaching_programs_repository.dart';
import 'package:zitlas_mobile/features/coaching_programs/models/program_offer.dart';
import 'package:zitlas_mobile/features/coaching_programs/presentation/coaching_programs_screen.dart';
import 'package:zitlas_mobile/features/payments/add_funds_flow.dart';
import 'package:zitlas_mobile/features/payments/data/wallet_repository.dart';
import 'package:zitlas_mobile/features/payments/wallet_freeze.dart';

import 'wallet_fakes.dart';

/// Personal Coaching Programs — PHASE 3: Pay & Start Program.
///
///     expert accepted -> Pay & Start -> wallet covers it?  yes: paid + active
///                                                          no:  Required / Available / Need
///                                                               + the EXISTING Add Funds
///
/// What these protect:
///   * the amount shown and charged is the request's SERVER snapshot — the
///     app sends no amount at all;
///   * a short wallet never opens Razorpay by itself; Add Funds is the
///     existing flow, and a top-up never pays the program automatically;
///   * a double tap or a lost response can never charge twice.

const _json = {'content-type': 'application/json; charset=utf-8'};
const _price = 499900; // ₹4,999 — the expert's price, snapshotted on the request

http.Response _res(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _json);

/// /api/coaching-programs as the app sees it. Paying reads and debits the
/// SAME fake-Firestore wallet that FakeWalletBackend's Add Funds credits —
/// exactly how the real backend shares users/{uid}.wallet.
class _ProgramsBackend {
  _ProgramsBackend(this.db);

  final FakeFirebaseFirestore db;

  /// Starts as an accepted request whose payment is due.
  String status = 'accepted';
  String paymentStatus = 'payment_required';
  DateTime? startedAt;
  DateTime? endsAt;
  int? amountPaidPaise;

  final gets = <Uri>[];
  final pays = <http.Request>[];

  /// Holds the pay response open (a slow network).
  Completer<void>? payGate;

  /// Applies the payment, then the connection drops before the answer.
  bool loseNextPayResponse = false;

  /// Answers the next pay call with exactly this.
  (int, Object)? payOverride;

  void markPaid({DateTime? start, int days = 10}) {
    final s = (start ?? DateTime.now()).toUtc();
    status = 'active';
    paymentStatus = 'paid';
    startedAt = s;
    endsAt = s.add(Duration(days: days));
    amountPaidPaise = _price;
  }

  Map<String, dynamic> request() => {
        'requestId': 'CPR_1',
        'athleteId': kUid,
        'expertId': 'coach-1',
        'expertName': 'Asha Rao',
        'programId': '10_day',
        'programTitle': '10-Day Program',
        'programType': 'diet',
        'durationDays': 10,
        'pricePaise': _price,
        'currency': 'INR',
        'status': status,
        'paymentStatus': paymentStatus,
        'expertAccepted': true,
        'requestedAt': '2026-09-01T06:00:00+00:00',
        if (startedAt != null) 'paidAt': startedAt!.toIso8601String(),
        if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
        if (endsAt != null) 'endsAt': endsAt!.toIso8601String(),
        'amountPaidPaise': ?amountPaidPaise,
      };

  Map<String, dynamic> _offer() => {
        'expertId': 'coach-1',
        'expertName': 'Asha Rao',
        'currency': 'INR',
        'programs': [
          for (final p in kCoachingPrograms) {'programId': p.id, 'pricePaise': _price, 'available': true},
        ],
        'request': request(),
      };

  Future<Map<String, dynamic>> _wallet() async => Map<String, dynamic>.from(
      ((await db.collection('users').doc(kUid).get()).data()?['wallet'] as Map?) ?? const {});

  Map<String, dynamic> _paid(bool already, double? balance) => {
        'success': true,
        'already': already,
        'requestId': 'CPR_1',
        'programId': '10_day',
        'paymentStatus': paymentStatus,
        'programStatus': status,
        'amountPaidPaise': _price,
        'startedAt': startedAt?.toIso8601String(),
        'endsAt': endsAt?.toIso8601String(),
        'balance': balance,
        'request': request(),
      };

  Future<http.Response> _pay() async {
    if (payGate != null) await payGate!.future;
    final override = payOverride;
    if (override != null) {
      payOverride = null;
      return _res(override.$2, override.$1);
    }
    final wallet = await _wallet();
    final balance = (((wallet['balance'] as num?) ?? 0) * 100).round();
    if (paymentStatus == 'paid') return _res(_paid(true, balance / 100.0));
    final reserved = (((wallet['reserved'] as num?) ?? 0) * 100).round();
    final available = balance - reserved;
    if (available < _price) {
      return _res({
        'detail': {
          'error': 'insufficient_wallet_balance',
          'required': _price,
          'available': available < 0 ? 0 : available,
          'currency': 'INR',
        },
      }, 402);
    }
    final newBalance = (balance - _price) / 100.0;
    await db.collection('users').doc(kUid).set({
      'wallet': {...wallet, 'balance': newBalance},
    }, SetOptions(merge: true));
    markPaid();
    if (loseNextPayResponse) {
      loseNextPayResponse = false;
      throw http.ClientException('Connection reset by peer');
    }
    return _res(_paid(false, newBalance));
  }

  late final CoachingProgramsRepository repo = CoachingProgramsRepository(
    apiClient: ApiClient(
      baseUrl: 'https://api.test',
      httpClient: MockClient((r) async {
        if (r.method == 'GET') {
          gets.add(r.url);
          return _res(_offer());
        }
        if (r.url.path == '/api/coaching-programs/requests/CPR_1/pay') {
          pays.add(r);
          return _pay();
        }
        return _res({'detail': 'not_found'}, 404);
      }),
    ),
  );
}

class _Rig {
  _Rig(this.db, this.programs, this.wallet, this.checkout);

  final FakeFirebaseFirestore db;
  final _ProgramsBackend programs;
  final FakeWalletBackend wallet;
  final FakeCheckout checkout;

  Future<double> balance() async =>
      (((await db.collection('users').doc(kUid).get()).data()!['wallet'] as Map)['balance'] as num)
          .toDouble();
}

Future<_Rig> _pump(
  WidgetTester tester, {
  double balance = 10000,
  void Function(_ProgramsBackend)? setUp,
}) async {
  final db = await walletDb(balance: balance);
  final programs = _ProgramsBackend(db);
  setUp?.call(programs);
  final walletBackend = FakeWalletBackend(db);
  final checkout = FakeCheckout();
  final wallet = walletRepo(db, walletBackend);
  tester.view.physicalSize = const Size(800, 7000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ChangeNotifierProvider<AuthState>(
    create: (_) => FakeAuthState(),
    child: MaterialApp(
      home: CoachingProgramsScreen(
        expertId: 'coach-1',
        repository: programs.repo,
        walletRepository: wallet,
        addFundsFlow: AddFundsFlow(repository: wallet, checkoutFactory: () => checkout),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return _Rig(db, programs, walletBackend, checkout);
}

final _pay = find.byKey(const Key('coachingProgramPay_10_day'));
final _card = find.byKey(const Key('insufficientBalanceCard'));
final _status = find.byKey(const Key('coachingProgramStatus_10_day'));

Finder _inCard(String id, Finder f) =>
    find.descendant(of: find.byKey(Key('coachingProgram_$id')), matching: f);

Finder _inShortfall(String text) => find.descendant(of: _card, matching: find.text(text));

Future<void> _tapPay(WidgetTester tester) async {
  await tester.tap(_pay);
  await tester.pumpAndSettle();
}

void main() {
  group('Pay & Start Program', () {
    testWidgets('an accepted program shows the recorded amount and Pay & Start — nothing charged',
        (tester) async {
      final rig = await _pump(tester);
      expect(_inCard('10_day', find.text(kProgramAcceptedTitle)), findsOneWidget);
      expect(_inCard('10_day', find.text('10-Day Program')), findsWidgets);
      expect(
        find.descendant(
          of: find.byKey(const Key('coachingProgramAmount_10_day')),
          matching: find.text('₹4,999'),
        ),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(_pay).onPressed, isNotNull);
      expect(find.text(kProgramPayLabel), findsOneWidget);
      expect(_card, findsNothing);
      expect(rig.programs.pays, isEmpty);
      expect(await rig.balance(), 10000);
    });

    testWidgets("paying sends no amount, and the program starts from the server's answer",
        (tester) async {
      final rig = await _pump(tester);
      await _tapPay(tester);

      final call = rig.programs.pays.single;
      expect(call.url.path, '/api/coaching-programs/requests/CPR_1/pay');
      expect(call.body, isEmpty, reason: 'no price, duration or expert ever leaves the app');
      expect(find.text(kProgramStarted), findsOneWidget);
      expect(await rig.balance(), 10000 - 4999);

      expect(_pay, findsNothing, reason: 'nothing left to pay');
      expect(find.descendant(of: _status, matching: find.text(kProgramActiveTitle)), findsOneWidget);
      // The program's details, every value from the server's answer.
      Finder detail(String key, String text) =>
          find.descendant(of: find.byKey(Key(key)), matching: find.text(text));
      expect(detail('coachingProgramStart_10_day', formatProgramDate(rig.programs.startedAt!)),
          findsOneWidget);
      expect(detail('coachingProgramEnd_10_day', formatProgramDate(rig.programs.endsAt!)),
          findsOneWidget);
      expect(detail('coachingProgramPaid_10_day', '₹4,999'), findsOneWidget);
      expect(detail('coachingProgramState_10_day', 'Active'), findsOneWidget);
      expect(find.descendant(of: _status, matching: find.text('Asha Rao')), findsOneWidget);
      expect(find.text(kProgramOtherRunning), findsNWidgets(2), reason: 'one program at a time');
      expect(rig.checkout.opened, 0);
    });

    testWidgets('a double tap charges once', (tester) async {
      final rig = await _pump(tester);
      rig.programs.payGate = Completer<void>();
      await tester.tap(_pay);
      await tester.pump();
      expect(tester.widget<FilledButton>(_pay).onPressed, isNull, reason: 'disabled while paying');
      await tester.tap(_pay, warnIfMissed: false);
      await tester.pump();
      rig.programs.payGate!.complete();
      await tester.pumpAndSettle();
      expect(rig.programs.pays, hasLength(1));
      expect(await rig.balance(), 10000 - 4999);
    });

    testWidgets('a lost response is safe: the screen shows what the server did, charged once',
        (tester) async {
      final rig = await _pump(tester);
      rig.programs.loseNextPayResponse = true;
      await _tapPay(tester);
      expect(find.text(kProgramPaymentUnconfirmed), findsOneWidget);
      expect(rig.programs.gets, hasLength(2), reason: 'the truth is reloaded from the server');
      expect(find.descendant(of: _status, matching: find.text(kProgramActiveTitle)), findsOneWidget);
      expect(rig.programs.pays, hasLength(1));
      expect(await rig.balance(), 10000 - 4999);
    });

    testWidgets('paid on another device: the repeat returns that payment and charges nothing',
        (tester) async {
      final rig = await _pump(tester);
      rig.programs.markPaid(); // the other device already paid
      await _tapPay(tester);
      expect(find.text(kProgramAlreadyPaid), findsOneWidget);
      expect(find.descendant(of: _status, matching: find.text(kProgramActiveTitle)), findsOneWidget);
      expect(await rig.balance(), 10000);
    });

    testWidgets('a request that can no longer be paid says so and shows the new state',
        (tester) async {
      final rig = await _pump(tester);
      rig.programs.payOverride = (409, {
        'detail': {'error': 'not_payable', 'status': 'declined'},
      });
      rig.programs.status = 'declined';
      rig.programs.paymentStatus = 'unpaid';
      await _tapPay(tester);
      expect(find.text('This program can no longer be paid for.'), findsOneWidget);
      expect(find.descendant(of: _status, matching: find.text(kProgramDeclinedTitle)), findsOneWidget);
      expect(await rig.balance(), 10000);
    });

    testWidgets('a frozen wallet charges nothing and opens nothing', (tester) async {
      final rig = await _pump(tester);
      rig.programs.payOverride = (503, {
        'detail': {'error': 'wallet_frozen', 'message': 'frozen'},
      });
      await _tapPay(tester);
      expect(find.text(kWalletFrozenMessage), findsOneWidget);
      expect(rig.checkout.opened, 0);
      expect(_pay, findsOneWidget);
    });
  });

  group('a short wallet', () {
    testWidgets('shows Required / Available / Need and Add Funds — and never opens Razorpay',
        (tester) async {
      final rig = await _pump(tester, balance: 100);
      await _tapPay(tester);

      expect(_card, findsOneWidget);
      expect(find.descendant(of: _card, matching: find.text('Insufficient wallet balance')),
          findsOneWidget);
      expect(find.descendant(of: _card, matching: find.text(kProgramShortfallMessage)),
          findsOneWidget);
      for (final (label, value) in [('Required', '₹4999'), ('Available', '₹100'), ('Need', '₹4899')]) {
        expect(_inShortfall(label), findsOneWidget, reason: label);
        expect(_inShortfall(value), findsOneWidget, reason: value);
      }
      expect(rig.checkout.opened, 0, reason: 'Add Funds is the athlete\'s choice, never automatic');
      expect(rig.wallet.paths, isEmpty);
      expect(await rig.balance(), 100);
      expect(_pay, findsOneWidget, reason: 'still payable once the wallet covers it');
    });

    testWidgets('Add Funds is the existing flow — and a top-up never pays the program by itself',
        (tester) async {
      final rig = await _pump(tester, balance: 100);
      await _tapPay(tester);
      await tester.tap(find.byKey(const Key('insufficientAddFunds')));
      await tester.pumpAndSettle();

      // The existing amount sheet, pre-filled with exactly what is short.
      expect(find.text('Continue to Payment · ₹4899'), findsOneWidget);
      await tester.tap(find.text('Continue to Payment · ₹4899'));
      await tester.pumpAndSettle();

      expect(rig.checkout.opened, 1);
      expect(rig.wallet.paths, ['/api/payment/create-order', '/api/payment/verify']);
      expect(await rig.balance(), 4999);
      expect(find.text(kProgramFundsAddedReady), findsOneWidget);
      expect(_card, findsNothing);
      expect(rig.programs.pays, hasLength(1), reason: 'only the first, short attempt — no auto-pay');

      await _tapPay(tester);
      expect(rig.programs.pays, hasLength(2));
      expect(await rig.balance(), 0);
      expect(find.descendant(of: _status, matching: find.text(kProgramActiveTitle)), findsOneWidget);
    });

    testWidgets('a top-up that is still short keeps the card, with the new figures',
        (tester) async {
      await _pump(tester, balance: 100);
      await _tapPay(tester);
      await tester.tap(find.byKey(const Key('insufficientAddFunds')));
      await tester.pumpAndSettle();
      // A preset, smaller than the shortfall — the chip in the sheet, not the
      // card's own "Available ₹100".
      await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('₹100')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue to Payment · ₹100'));
      await tester.pumpAndSettle();

      expect(find.text(kProgramFundsAddedShort), findsOneWidget);
      expect(_inShortfall('₹200'), findsOneWidget, reason: 'available, re-read from the server');
      expect(_inShortfall('₹4799'), findsOneWidget, reason: 'what is still needed');
    });
  });

  group('a paid program', () {
    testWidgets('while it runs: no Pay, its dates, and nothing else can start', (tester) async {
      await _pump(tester, setUp: (p) => p.markPaid());
      expect(_pay, findsNothing);
      expect(find.byKey(const Key('coachingProgramGetStarted_10_day')), findsNothing);
      expect(find.descendant(of: _status, matching: find.text(kProgramActiveTitle)), findsOneWidget);
      expect(find.text(kProgramOtherRunning), findsNWidgets(2));
    });

    testWidgets('once it has ended, a new program can be started', (tester) async {
      await _pump(tester,
          setUp: (p) => p.markPaid(start: DateTime.now().subtract(const Duration(days: 11))));
      expect(find.descendant(of: _status, matching: find.text('Program ended')), findsOneWidget);
      for (final p in kCoachingPrograms) {
        final start = find.byKey(Key('coachingProgramGetStarted_${p.id}'));
        expect(tester.widget<FilledButton>(start).onPressed, isNotNull, reason: p.id);
      }
    });
  });

  group('the repository', () {
    CoachingProgramsRepository repoWith(int status, Object body, {List<http.Request>? seen}) =>
        CoachingProgramsRepository(
          apiClient: ApiClient(
            baseUrl: 'https://api.test',
            httpClient: MockClient((r) async {
              seen?.add(r);
              return _res(body, status);
            }),
          ),
        );

    test('pays by request id alone, with no body', () async {
      final seen = <http.Request>[];
      final db = FakeFirebaseFirestore();
      final backend = _ProgramsBackend(db)..markPaid();
      final repo = repoWith(200, backend._paid(false, 5001), seen: seen);
      final result = await repo.payForProgram('CPR 1/x');
      expect(seen.single.url.path, '/api/coaching-programs/requests/CPR%201%2Fx/pay');
      expect(seen.single.body, isEmpty);
      expect(result.request.isPaid, isTrue);
      expect(result.request.status, ProgramRequestStatus.active);
      expect(result.alreadyPaid, isFalse);
      expect(result.balance, 5001);
    });

    test("a 402 is the wallet's own InsufficientWalletBalance, with the server's figures", () async {
      final repo = repoWith(402, {
        'detail': {'error': 'insufficient_wallet_balance', 'required': 499900, 'available': 10000},
      });
      await expectLater(
        repo.payForProgram('CPR_1'),
        throwsA(isA<InsufficientWalletBalance>()
            .having((e) => e.requiredPaise, 'required', 499900)
            .having((e) => e.availablePaise, 'available', 10000)
            .having((e) => e.shortfallRupees, 'need', 4899)),
      );
    });

    test('a frozen wallet is the wallet\'s own WalletFrozenException', () async {
      final repo = repoWith(503, {
        'detail': {'error': 'wallet_frozen', 'message': 'frozen'},
      });
      await expectLater(repo.payForProgram('CPR_1'), throwsA(isA<WalletFrozenException>()));
    });

    test('refusals become messages an athlete can act on', () async {
      Future<String> refusal(Object detail) async {
        try {
          await repoWith(409, {'detail': detail}).payForProgram('CPR_1');
        } on ProgramRequestException catch (e) {
          return e.message;
        }
        return 'not refused';
      }

      expect(await refusal({'error': 'not_accepted', 'status': 'pending_expert_acceptance'}),
          contains("hasn't accepted"));
      expect(await refusal({'error': 'not_payable', 'status': 'declined'}),
          'This program can no longer be paid for.');
      expect(await refusal('active_coaching_exists'), contains('active personal coach'));
      expect(await refusal('request_invalid'), contains('nothing was charged'));
    });

    test('an answer that is not a paid program is never reported as paid', () async {
      final repo = repoWith(200, {'success': true, 'request': {'requestId': 'CPR_1'}});
      await expectLater(repo.payForProgram('CPR_1'), throwsA(isA<ProgramRequestException>()));
    });
  });
}
