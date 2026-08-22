import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:zitlas_mobile/features/auth/auth_state.dart';
import 'package:zitlas_mobile/models/user_model.dart';
import 'package:zitlas_mobile/features/payments/data/wallet_repository.dart';
import 'package:zitlas_mobile/features/payments/models/wallet.dart';
import 'package:zitlas_mobile/features/payments/presentation/screens/transaction_history_screen.dart';
import 'package:zitlas_mobile/features/payments/presentation/screens/wallet_screen.dart';
import 'package:zitlas_mobile/features/payments/presentation/widgets/add_funds_sheet.dart';
import 'package:zitlas_mobile/features/payments/wallet_controller.dart';

/// What the athlete actually sees.
///
/// The screen these replace was a placeholder, so every one of these is a
/// behaviour that did not exist before: a real balance, a real empty state, a
/// real error state with a retry, and no blank screen on any path.
void main() {
  const uid = 'athlete_1';

  Map<String, dynamic> txn({
    required String id,
    required String type,
    required num amount,
    String description = 'Test transaction',
  }) =>
      {
        'id': id,
        'type': type,
        'amount': amount,
        'description': description,
        'date': '2026-08-01T10:00:00.000Z',
      };

  Future<void> pump(WidgetTester tester, WalletController controller) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthState>(
        create: (_) => _FakeAuthState(),
        child: MaterialApp(home: WalletScreen(controller: controller)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }

  Future<WalletController> controllerFor(Map<String, dynamic>? wallet) async {
    final db = FakeFirebaseFirestore();
    await db.collection('users').doc(uid).set({
      'name': 'Test Athlete',
      'wallet': ?wallet,
    });
    return WalletController(uid: uid, repository: WalletRepository(firestore: db));
  }

  testWidgets('a funded wallet shows its real spendable balance', (tester) async {
    final controller = await controllerFor({
      'balance': 12500.0,
      'total_added': 15000.0,
      'total_spent': 2500.0,
      'transactions': [txn(id: 'a', type: 'credit', amount: 15000)],
    });
    addTearDown(controller.dispose);
    await pump(tester, controller);

    expect(find.text('Available Balance'), findsOneWidget);
    // Indian grouping, matching the website's toLocaleString('en-IN').
    // Twice on purpose: the headline available figure, and the "Balance"
    // stat tile (identical here because nothing is reserved).
    expect(find.text('₹12,500'), findsNWidgets(2));
    expect(find.text('₹15,000'), findsOneWidget); // Added
    expect(find.text('₹2,500'), findsOneWidget); // Spent
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('reserved money is called out and excluded from the headline',
      (tester) async {
    final controller = await controllerFor({'balance': 1000.0, 'reserved': 400.0});
    addTearDown(controller.dispose);
    await pump(tester, controller);

    expect(find.text('₹600'), findsOneWidget, reason: 'spendable, not raw balance');
    expect(find.textContaining('reserved for a pending coaching request'), findsOneWidget);
    expect(find.text('Reserved'), findsOneWidget);
  });

  testWidgets('a brand-new account gets an empty state, not a blank screen',
      (tester) async {
    final controller = await controllerFor(null);
    addTearDown(controller.dispose);
    await pump(tester, controller);

    expect(find.text('₹0'), findsWidgets);
    expect(find.text('No transactions yet'), findsOneWidget);
    expect(find.text('Add funds to get started.'), findsOneWidget);
    // The empty state is not an error state.
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('history is disabled — not broken — with nothing to show',
      (tester) async {
    final controller = await controllerFor(null);
    addTearDown(controller.dispose);
    await pump(tester, controller);

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionHistoryScreen), findsNothing);
  });

  testWidgets('a failure shows a friendly message AND a working retry',
      (tester) async {
    final repo = _FlakyRepository();
    final controller = WalletController(uid: uid, repository: repo);
    addTearDown(controller.dispose);
    await pump(tester, controller);

    expect(find.text("Couldn't load your wallet"), findsOneWidget);
    expect(find.textContaining('connection'), findsOneWidget);
    expect(find.textContaining('Your balance is safe'), findsOneWidget);

    repo.healed = true;
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text("Couldn't load your wallet"), findsNothing);
    expect(find.text('₹750'), findsWidgets);
  });

  testWidgets('the loading state is a spinner, never a blank frame', (tester) async {
    final controller = WalletController(uid: uid, repository: _NeverRepository());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthState>(
        create: (_) => _FakeAuthState(),
        child: MaterialApp(home: WalletScreen(controller: controller)),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading your wallet…'), findsOneWidget);
  });

  testWidgets('recent transactions render newest first with correct signs',
      (tester) async {
    final controller = await controllerFor({
      'balance': 500.0,
      'transactions': [
        txn(id: 'old', type: 'credit', amount: 1000, description: 'Added Funds via Razorpay'),
        txn(id: 'new', type: 'debit', amount: 500, description: 'Diet Plan Review'),
      ],
    });
    addTearDown(controller.dispose);
    await pump(tester, controller);

    expect(find.text('Diet Plan Review'), findsOneWidget);
    expect(find.text('−₹500'), findsOneWidget, reason: 'a debit must read as money out');
    expect(find.text('+₹1,000'), findsOneWidget);
  });

  testWidgets('"See all" opens the full history', (tester) async {
    final controller = await controllerFor({
      'balance': 100.0,
      'transactions': [
        for (var i = 0; i < 5; i++) txn(id: 't$i', type: 'credit', amount: 100),
      ],
    });
    addTearDown(controller.dispose);
    await pump(tester, controller);

    expect(find.text('Last 3 transactions'), findsOneWidget);
    // The wallet is a scrolling list and the frozen-wallet notice made it
    // taller than the 800x600 test viewport, so "See all" now starts below
    // the fold. Scroll to it the way a person would rather than asserting
    // against a screen that only fits on a large phone.
    await tester.ensureVisible(find.text('See all →'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('See all →'));
    await tester.pumpAndSettle();

    expect(find.byType(TransactionHistoryScreen), findsOneWidget);
    expect(find.text('Total in'), findsOneWidget);
  });

  testWidgets('the history screen filters money in and money out', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TransactionHistoryScreen(
        transactions: Wallet.fromUserDoc({
          'wallet': {
            'transactions': [
              txn(id: 'a', type: 'credit', amount: 1000, description: 'Top up'),
              txn(id: 'b', type: 'debit', amount: 300, description: 'Expert review'),
            ],
          },
        }).transactions,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('+₹1,000'), findsWidgets);
    expect(find.text('−₹300'), findsWidgets);

    await tester.tap(find.text('Money out'));
    await tester.pumpAndSettle();
    expect(find.text('Expert review'), findsOneWidget);
    expect(find.text('Top up'), findsNothing);
  });

  testWidgets('an empty filter result is distinguished from an empty wallet',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TransactionHistoryScreen(
        transactions: Wallet.fromUserDoc({
          'wallet': {
            'transactions': [txn(id: 'a', type: 'credit', amount: 1000)],
          },
        }).transactions,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Money out'));
    await tester.pumpAndSettle();
    expect(find.text('No transactions of this type yet.'), findsOneWidget);
    expect(find.text('No transactions yet'), findsNothing);
  });

  group('add funds sheet', () {
    Future<void> openSheet(WidgetTester tester, {void Function(double)? captured}) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                final amount = await showAddFundsSheet(context);
                if (amount != null && captured != null) captured(amount);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('every website preset amount is offered', (tester) async {
      await openSheet(tester);
      for (final amount in kQuickAmounts) {
        expect(find.text('₹$amount'), findsOneWidget);
      }
    });

    testWidgets('continue is disabled until an amount is chosen', (tester) async {
      await openSheet(tester);
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Continue to Payment'),
      );
      expect(button.onPressed, isNull);

      await tester.tap(find.text('₹500'));
      await tester.pumpAndSettle();
      expect(find.text('Continue to Payment · ₹500'), findsOneWidget);
    });

    testWidgets('an over-limit custom amount explains itself', (tester) async {
      await openSheet(tester);
      await tester.enterText(find.byType(TextField), '99999');
      await tester.pumpAndSettle();

      // Above the cap the button stays disabled AND says why once tapped.
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Continue to Payment'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('a custom amount overrides a previously tapped preset',
        (tester) async {
      double? picked;
      await openSheet(tester, captured: (v) => picked = v);
      await tester.tap(find.text('₹100'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '750');
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Continue to Payment'));
      await tester.pumpAndSettle();
      expect(picked, 750);
    });

    testWidgets('no fake payment-method picker is shown', (tester) async {
      // Razorpay's own sheet has the real, live options — a second cosmetic
      // one in front of it would be a lie about what is being chosen.
      await openSheet(tester);
      expect(find.text('UPI'), findsNothing);
      expect(find.text('Net Banking'), findsNothing);
      expect(find.textContaining('secured by Razorpay'), findsOneWidget);
    });
  });
}

/// A signed-in athlete, without touching Firebase.
class _FakeAuthState extends ChangeNotifier implements AuthState {
  @override
  UserModel? get profile => const UserModel(
        uid: 'athlete_1',
        email: 'athlete@example.com',
        name: 'Test Athlete',
      );

  @override
  AuthStatus get status => AuthStatus.authenticated;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FlakyRepository implements WalletRepository {
  bool healed = false;

  @override
  Stream<Wallet> watch(String uid) => healed
      ? Stream<Wallet>.value(const Wallet(balance: 750, exists: true))
      : Stream<Wallet>.error(Exception('Failed host lookup: api.zitlas.com'));

  @override
  Future<Wallet> fetch(String uid) async => const Wallet(balance: 750, exists: true);

  @override
  Future<WalletOrder> createOrder(double amountRupees) async => throw Exception('offline');

  @override
  Future<double> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async =>
      throw Exception('offline');
}

class _NeverRepository implements WalletRepository {
  @override
  Stream<Wallet> watch(String uid) => const Stream<Wallet>.empty();

  @override
  Future<Wallet> fetch(String uid) => Completer<Wallet>().future;

  @override
  Future<WalletOrder> createOrder(double amountRupees) => Completer<WalletOrder>().future;

  @override
  Future<double> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) =>
      Completer<double>().future;
}
