import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/core/storage/local_storage_service.dart';
import 'package:zitlas_mobile/features/auth/auth_state.dart';
import 'package:zitlas_mobile/features/membership/premium_wallet_controller.dart';
import 'package:zitlas_mobile/features/membership/presentation/screens/membership_screen.dart';
import 'package:zitlas_mobile/features/payments/add_funds_flow.dart';
import 'package:zitlas_mobile/features/payments/data/wallet_repository.dart';
import 'package:zitlas_mobile/features/payments/presentation/widgets/insufficient_balance_card.dart';
import 'package:zitlas_mobile/features/profile/data/profile_repository.dart';

import 'wallet_fakes.dart';

/// Premium, paid from the ZITLAS Wallet.
///
///     wallet → ₹149 → Premium        (never Razorpay for a short wallet)
///     short  → "Insufficient wallet balance" → Add Funds → back → Upgrade
///
/// THE RULE THESE PROTECT: a short wallet is answered with the two figures
/// and an Add Funds button — Razorpay is not opened for Premium, and Premium
/// is not bought behind the athlete's back once the money arrives.
void main() {
  late FakeFirebaseFirestore db;
  late FakeWalletBackend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorageService.init();
    db = await walletDb(balance: 100);
    backend = FakeWalletBackend(db);
  });

  PremiumWalletController controller() {
    final c = PremiumWalletController(uid: kUid, repository: walletRepo(db, backend));
    addTearDown(c.dispose);
    return c;
  }

  group('the purchase', () {
    test('a short wallet is an insufficient state with both figures — and no Razorpay', () async {
      final c = controller();
      expect(await c.purchase('monthly'), PremiumPurchaseStatus.insufficient);
      expect(c.shortfall!.requiredRupees, 149);
      expect(c.shortfall!.availableRupees, 100);
      expect(c.shortfall!.shortfallRupees, 49);
      expect(backend.paths, ['/api/payment/membership/purchase-with-wallet'],
          reason: 'no wallet or membership Razorpay order may be created');
    });

    test('a funded wallet buys Premium with a fresh idempotency key per press', () async {
      db = await walletDb(balance: 500);
      backend = FakeWalletBackend(db);
      final c = controller();
      expect(await c.purchase('monthly'), PremiumPurchaseStatus.purchased);
      final first = jsonDecode(backend.requests.last.body) as Map<String, dynamic>;
      expect(first['billing'], 'monthly');
      expect(first['idempotencyKey'], startsWith('app_${kUid}_'));
      expect(first.containsKey('amount'), isFalse, reason: 'the price is the server\'s');

      await c.purchase('monthly');
      final second = jsonDecode(backend.requests.last.body) as Map<String, dynamic>;
      expect(second['idempotencyKey'], isNot(first['idempotencyKey']),
          reason: 'two presses are two purchases; one press is one');
    });

    test('a frozen Wallet sends the screen to the Razorpay fallback', () async {
      backend.walletFrozen = true;
      expect(await controller().purchase('monthly'), PremiumPurchaseStatus.walletFrozen);
    });

    test('after Add Funds the wallet is re-read — covered clears the card, nothing is bought',
        () async {
      final c = controller();
      await c.purchase('monthly');
      await db.collection('users').doc(kUid).update({'wallet.balance': 200.0});

      await c.onFundsAdded();
      expect(c.shortfall, isNull);
      expect(c.status, PremiumPurchaseStatus.idle);
      expect(backend.paths.where((p) => p.endsWith('purchase-with-wallet')), hasLength(1),
          reason: 'Premium is bought only when the athlete taps Upgrade again');
    });

    test('still short after Add Funds — the card is recomputed from the new balance', () async {
      final c = controller();
      await c.purchase('monthly');
      await db.collection('users').doc(kUid).update({'wallet.balance': 120.0});

      await c.onFundsAdded();
      expect(c.shortfall!.availableRupees, 120);
      expect(c.shortfall!.shortfallRupees, 29);
    });
  });

  group('InsufficientBalanceCard', () {
    testWidgets('states required, available and the shortfall, and offers Add Funds',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InsufficientBalanceCard(
            shortfall: const InsufficientWalletBalance(requiredPaise: 14900, availablePaise: 10000),
            onAddFunds: () => taps++,
          ),
        ),
      ));
      expect(find.text('Insufficient wallet balance'), findsOneWidget);
      expect(find.text('₹149'), findsOneWidget);
      expect(find.text('₹100'), findsOneWidget);
      expect(find.text('₹49'), findsOneWidget);
      await tester.tap(find.byKey(const Key('insufficientAddFunds')));
      expect(taps, 1);
    });

    testWidgets('is disabled while funds are being added', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InsufficientBalanceCard(
            shortfall: const InsufficientWalletBalance(requiredPaise: 14900, availablePaise: 0),
            onAddFunds: () {},
            busy: true,
          ),
        ),
      ));
      expect(find.text('Adding funds…'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byKey(const Key('insufficientAddFunds')));
      expect(button.onPressed, isNull);
    });
  });

  group('the Membership screen', () {
    testWidgets('short wallet → Add Funds → back to Premium → Upgrade pays from the wallet',
        (tester) async {
      // Tall enough that the whole plan list is built — ListView is lazy.
      tester.view.physicalSize = const Size(1200, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = walletRepo(db, backend);
      final checkout = FakeCheckout();
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthState>(
          create: (_) => FakeAuthState(),
          child: MaterialApp(
            home: MembershipScreen(
              profileRepository: ProfileRepository(firestore: db, auth: FakeAuth()),
              walletRepository: repo,
              addFundsFlow: AddFundsFlow(repository: repo, checkoutFactory: () => checkout),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final upgrade = find.text('Upgrade to Premium');
      await tester.ensureVisible(upgrade);
      await tester.tap(upgrade);
      await tester.pumpAndSettle();

      // Short: the card, both figures, and NO Razorpay.
      expect(find.byKey(const Key('insufficientBalanceCard')), findsOneWidget);
      expect(find.text('₹49'), findsOneWidget);
      expect(checkout.opened, 0, reason: 'Razorpay must not open for a short wallet');
      expect(backend.paths, isNot(contains('/api/payment/membership/create-order')));

      // Add Funds, pre-filled with exactly the shortfall.
      final addFunds = find.byKey(const Key('insufficientAddFunds'));
      await tester.ensureVisible(addFunds);
      await tester.tap(addFunds);
      await tester.pumpAndSettle();
      expect(find.text('Continue to Payment · ₹49'), findsOneWidget);
      await tester.tap(find.text('Continue to Payment · ₹49'));
      await tester.pumpAndSettle();

      // Credited by the backend, card gone — and Premium NOT bought yet.
      expect(checkout.opened, 1);
      expect(find.byKey(const Key('insufficientBalanceCard')), findsNothing);
      expect(find.text('Funds added. Tap Upgrade to Premium to pay from your wallet.'),
          findsOneWidget);
      expect(backend.paths.where((p) => p.endsWith('purchase-with-wallet')), hasLength(1));

      // Upgrade again: paid from the wallet.
      await tester.ensureVisible(upgrade);
      await tester.tap(upgrade);
      await tester.pumpAndSettle();
      expect(find.text('Premium activated — paid from your ZITLAS Wallet.'), findsOneWidget);
      expect(checkout.opened, 1, reason: 'the Premium payment itself never used Razorpay');
    });
  });
}
