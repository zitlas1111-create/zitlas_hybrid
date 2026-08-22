import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/auth/auth_state.dart';
import 'package:zitlas_mobile/features/payments/data/wallet_repository.dart';
import 'package:zitlas_mobile/features/payments/presentation/screens/wallet_screen.dart';
import 'package:zitlas_mobile/features/payments/wallet_controller.dart';
import 'package:zitlas_mobile/features/payments/wallet_freeze.dart';
import 'package:zitlas_mobile/features/profile/data/profile_repository.dart';
import 'package:zitlas_mobile/models/user_model.dart';

/// THE WALLET MOVES NO MONEY THIS RELEASE — AND PREMIUM IS RAZORPAY-ONLY.
///
/// Frozen is not deleted and not hidden. A balance and a transaction history
/// are the athlete's own records and keep rendering; only the actions that
/// move money are withdrawn, and they are withdrawn VISIBLY — a greyed-out
/// "Add Funds (soon)" rather than a live-looking button that fails on tap.
///
/// The backend refuses every wallet money movement with 503 wallet_frozen
/// regardless of what this app believes, so the constant here decides only
/// what is shown. These tests cover the shown half; the enforced half lives
/// in backend/tests/test_wallet_freeze.py.
void main() {
  group('the freeze flag', () {
    test('the wallet is frozen for launch', () {
      expect(kWalletFrozen, isTrue);
    });

    test('the message tells the athlete their money is safe', () {
      expect(kWalletFrozenMessage, contains('temporarily unavailable'));
      expect(kWalletFrozenMessage.toLowerCase(), contains('safe'));
    });
  });

  group('the wallet screen while frozen', () {
    const uid = 'athlete_1';

    Future<void> pump(WidgetTester tester, WalletController controller) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthState>(
          create: (_) => _FakeAuthState(),
          child: MaterialApp(home: WalletScreen(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }

    Future<WalletController> fundedWallet() async {
      final db = FakeFirebaseFirestore();
      await db.collection('users').doc(uid).set({
        'name': 'Test Athlete',
        'wallet': {
          'balance': 5000.0,
          'reserved': 0.0,
          'total_added': 5000.0,
          'total_spent': 0.0,
          'transactions': [
            {
              'id': 't1',
              'type': 'credit',
              'amount': 5000,
              'description': 'Wallet recharge',
              'date': '2026-01-01T00:00:00.000Z',
            },
          ],
        },
      });
      return WalletController(
        uid: uid, repository: WalletRepository(firestore: db));
    }

    testWidgets('says the wallet is coming soon', (tester) async {
      final c = await fundedWallet();
      addTearDown(c.dispose);
      await pump(tester, c);
      expect(find.text('Wallet coming soon'), findsOneWidget);
    });

    testWidgets('Add Funds is visibly disabled, not silently broken',
        (tester) async {
      final c = await fundedWallet();
      addTearDown(c.dispose);
      await pump(tester, c);

      expect(find.text('Add Funds (soon)'), findsOneWidget,
          reason: 'the label must say the action is unavailable');
      expect(find.text('Add Funds'), findsNothing,
          reason: 'a plain "Add Funds" reads as a working button');
    });

    testWidgets('the balance is still shown — freezing is not hiding',
        (tester) async {
      final c = await fundedWallet();
      addTearDown(c.dispose);
      await pump(tester, c);
      expect(find.textContaining('5,000'), findsWidgets);
    });

    testWidgets('the transaction history is still reachable', (tester) async {
      final c = await fundedWallet();
      addTearDown(c.dispose);
      await pump(tester, c);
      expect(find.text('History'), findsOneWidget);
      expect(find.textContaining('Wallet recharge'), findsWidgets);
    });
  });

  group('the repository honours a frozen backend', () {
    test('a frozen recharge surfaces as an error, never as a credit',
        () async {
      final mock = MockClient((request) async => http.Response(
            jsonEncode({
              'detail': {'error': 'wallet_frozen', 'message': 'frozen'}
            }),
            503,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final repo = WalletRepository(
        firestore: FakeFirebaseFirestore(),
        api: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
      );

      await expectLater(repo.createOrder(500), throwsA(isA<Exception>()),
          reason: 'the app must not proceed to a checkout the server refused');
    });
  });

  group('premium is bought from Razorpay, and only from Razorpay', () {
    test('the order request carries a billing period and NO amount', () async {
      // A client that could name its own price could buy Premium for ₹1.
      Map<String, dynamic>? sent;
      final mock = MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'order_id': 'order_1',
            'amount': 14900,
            'currency': 'INR',
            'key_id': 'rzp_test_x',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final repo = ProfileRepository(
        firestore: FakeFirebaseFirestore(),
        auth: _FakeAuth(),
        apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
      );

      final order = await repo.createMembershipOrder('monthly');

      expect(sent, {'billing': 'monthly'});
      expect(sent!.containsKey('amount'), isFalse);
      expect(order.amountPaise, 14900,
          reason: 'the price is whatever the SERVER decided');
      expect(order.orderId, 'order_1');
    });

    test('verification is handed to the backend, never done locally',
        () async {
      String? path;
      Map<String, dynamic>? sent;
      final mock = MockClient((request) async {
        path = request.url.path;
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'success': true}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final repo = ProfileRepository(
        firestore: FakeFirebaseFirestore(),
        auth: _FakeAuth(),
        apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
      );

      await repo.verifyMembershipPayment(
        orderId: 'order_1', paymentId: 'pay_1', signature: 'sig_1',
      );

      expect(path, '/api/payment/membership/verify');
      expect(sent!['razorpay_order_id'], 'order_1');
      expect(sent!['razorpay_payment_id'], 'pay_1');
      expect(sent!['razorpay_signature'], 'sig_1');
    });

    test('a rejected signature is reported, and nothing is granted', () async {
      final mock = MockClient((request) async => http.Response(
            jsonEncode({'detail': 'signature_mismatch'}), 400,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final repo = ProfileRepository(
        firestore: FakeFirebaseFirestore(),
        auth: _FakeAuth(),
        apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
      );

      await expectLater(
        repo.verifyMembershipPayment(
            orderId: 'o', paymentId: 'p', signature: 'forged'),
        throwsA(predicate((e) =>
            e.toString().toLowerCase().contains('could not be verified'))),
      );
    });
  });
}


/// Minimal signed-in AuthState — the wallet screen reads the profile for the
/// Razorpay prefill only.
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

/// Not exercised by these tests — the membership order/verify calls go
/// through ApiClient, not FirebaseAuth. A bare Fake avoids adding a mocking
/// dependency the project does not otherwise use (same approach as
/// role_token_refresh_test.dart).
class _FakeAuth extends Fake implements FirebaseAuth {
  /// Signed out: ProfileRepository asks for a token, gets none, and sends
  /// the request without one. These tests assert the request BODY and the
  /// response handling, neither of which depends on the header.
  @override
  User? get currentUser => null;
}
