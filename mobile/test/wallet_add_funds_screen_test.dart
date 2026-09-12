import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/core/storage/local_storage_service.dart';
import 'package:zitlas_mobile/features/auth/auth_state.dart';
import 'package:zitlas_mobile/features/payments/add_funds_flow.dart';
import 'package:zitlas_mobile/features/payments/presentation/screens/wallet_screen.dart';
import 'package:zitlas_mobile/features/payments/wallet_controller.dart';
import 'package:zitlas_mobile/features/payments/wallet_freeze.dart';

import 'wallet_fakes.dart';

/// The Wallet screen's Add Funds, as the athlete sees it.
///
/// THE BUG THIS PINS. The flow existed but could not be reached: the app
/// hard-coded `kWalletFrozen = true`, so it showed "Add Funds (soon)" while
/// the backend — and the website — had the Wallet switched on. Availability
/// now comes from the server, the same way the website reads it.
void main() {
  late FakeFirebaseFirestore db;
  late FakeWalletBackend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorageService.init();
    db = await walletDb(balance: 1000);
    backend = FakeWalletBackend(db);
  });

  Future<FakeCheckout> pump(WidgetTester tester, {FakePayment payment = FakePayment.succeed}) async {
    final repo = walletRepo(db, backend);
    final controller = WalletController(
      uid: kUid,
      repository: repo,
      availability: WalletAvailability(api: backend.api()),
    );
    addTearDown(controller.dispose);
    final checkout = FakeCheckout(payment);
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthState>(
        create: (_) => FakeAuthState(),
        child: MaterialApp(
          home: WalletScreen(
            controller: controller,
            addFundsFlow: AddFundsFlow(repository: repo, checkoutFactory: () => checkout),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return checkout;
  }

  Future<void> addFunds(WidgetTester tester, {String chip = '₹500'}) async {
    await tester.tap(find.text('Add Funds'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(chip));
    await tester.pump();
    await tester.tap(find.text('Continue to Payment · $chip'));
    await tester.pumpAndSettle();
  }

  group('availability comes from the server', () {
    testWidgets('Add Funds is offered when the server says the Wallet is live', (tester) async {
      await pump(tester);
      expect(find.text('Add Funds'), findsOneWidget);
      expect(find.text('Add Funds (soon)'), findsNothing);
      expect(find.text('Wallet coming soon'), findsNothing);
    });

    testWidgets('while the server says frozen, Add Funds is visibly disabled', (tester) async {
      backend.walletFrozen = true;
      await pump(tester);
      expect(find.text('Add Funds (soon)'), findsOneWidget);
      expect(find.text('Wallet coming soon'), findsOneWidget);
    });

    testWidgets('while the server cannot be reached, Add Funds is not offered', (tester) async {
      backend.trialModeUnreachable = true;
      await pump(tester);
      expect(find.text('Add Funds (soon)'), findsOneWidget);
    });

    testWidgets('the available balance and the reserved note still render', (tester) async {
      await db.collection('users').doc(kUid).update({'wallet.reserved': 200.0});
      await pump(tester);
      expect(find.text('₹800'), findsOneWidget, reason: 'available = balance − reserved');
      expect(find.textContaining('reserved'), findsWidgets);
    });
  });

  group('adding funds', () {
    testWidgets("a completed top-up shows the SERVER's new balance and history", (tester) async {
      backend.extraCreditOnVerify = 100; // a local 1000 + 500 would say 1,500
      await pump(tester);
      await addFunds(tester);

      expect(find.text('₹500 added to your wallet. New balance ₹1,600.'), findsOneWidget);
      expect(find.text('₹1,600'), findsWidgets);
      expect(find.textContaining('Added Funds via Razorpay'), findsWidgets,
          reason: 'the transaction history refreshes too');
    });

    testWidgets('cancelling Razorpay credits nothing, and says so', (tester) async {
      await pump(tester, payment: FakePayment.cancel);
      await addFunds(tester);

      expect(find.text('Payment cancelled — nothing was charged.'), findsOneWidget);
      expect(backend.paths, isNot(contains('/api/payment/verify')));
      expect(find.text('₹1,000'), findsWidgets);
    });

    testWidgets('a refused verification is a support case, never "funds added"', (tester) async {
      await pump(tester, payment: FakePayment.badSignature);
      await addFunds(tester);

      expect(find.text('Payment not verified'), findsOneWidget);
      expect(find.textContaining('pay_order_1'), findsOneWidget);
      expect(find.textContaining('added to your wallet'), findsNothing);
    });

    testWidgets('an unconfirmed verification offers a retry that completes it', (tester) async {
      backend.verifyNetworkFailures = 1;
      await pump(tester);
      await addFunds(tester);

      expect(find.text('Payment not confirmed yet'), findsOneWidget);
      expect(find.textContaining('added to your wallet'), findsNothing);
      await tester.tap(find.byKey(const Key('topUpRetryVerify')));
      await tester.pumpAndSettle();

      expect(find.text('₹500 added to your wallet. New balance ₹1,500.'), findsOneWidget);
    });
  });
}
