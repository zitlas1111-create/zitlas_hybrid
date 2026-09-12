import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/payments/data/wallet_repository.dart';

/// The wallet as ZITLAS's internal payment balance, from the app's side.
///
///     Razorpay -> Add Funds -> wallet      createOrder + verifyPayment
///     wallet   -> ₹149      -> Premium     purchasePremiumWithWallet
///
/// THE PROPERTY THESE TESTS PROTECT: the app never decides the balance and
/// never decides the price. It sends `billing`, and renders whatever the
/// server says the balance became. A funded wallet must not open Razorpay.
void main() {
  ApiClient api(MockClient mock) =>
      ApiClient(httpClient: mock, baseUrl: 'https://api.test');

  http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body), status, headers: {'content-type': 'application/json'});

  /// Records every path the app calls, so a test can assert Razorpay was not
  /// reached at all.
  late List<String> paths;

  setUp(() => paths = <String>[]);

  MockClient client(
    Object Function(String path) respond, {
    int status = 200,
  }) =>
      MockClient((request) async {
        paths.add(request.url.path);
        final body = respond(request.url.path);
        return json(body, status);
      });

  group('Premium purchased from the wallet', () {
    test('a funded wallet buys Premium and returns the server balance',
        () async {
      final repo = WalletRepository(
        firestore: FakeFirebaseFirestore(),
        api: api(client((_) => {
              'success': true,
              'already': false,
              'balance': 351.0,
              'charged': 149,
            })),
      );
      final result = await repo.purchasePremiumWithWallet();
      expect(result.balance, 351.0);
      expect(result.alreadyPurchased, isFalse);
    });

    test('it never calls Razorpay', () async {
      final repo = WalletRepository(
        firestore: FakeFirebaseFirestore(),
        api: api(client((_) => {'success': true, 'balance': 351.0})),
      );
      await repo.purchasePremiumWithWallet();
      expect(paths, ['/api/payment/membership/purchase-with-wallet']);
      expect(paths.any((p) => p.contains('create-order')), isFalse,
          reason: 'a funded wallet must not open a Razorpay checkout');
      expect(paths.any((p) => p.contains('verify')), isFalse);
    });

    test('it sends only the billing period — never an amount', () async {
      Map<String, dynamic>? sent;
      final mock = MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return json({'success': true, 'balance': 351.0});
      });
      await WalletRepository(firestore: FakeFirebaseFirestore(), api: api(mock)).purchasePremiumWithWallet();
      expect(sent!.keys, ['billing']);
      expect(sent!['billing'], 'monthly');
      expect(sent!.containsKey('amount'), isFalse);
      expect(sent!.containsKey('price'), isFalse);
      expect(sent!.containsKey('uid'), isFalse);
    });

    test('an idempotency key is forwarded when supplied', () async {
      Map<String, dynamic>? sent;
      final mock = MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return json({'success': true, 'balance': 351.0});
      });
      await WalletRepository(firestore: FakeFirebaseFirestore(), api: api(mock))
          .purchasePremiumWithWallet(idempotencyKey: 'tap-1');
      expect(sent!['idempotencyKey'], 'tap-1');
    });

    test('a repeated purchase is reported as already applied', () async {
      final repo = WalletRepository(
        firestore: FakeFirebaseFirestore(),
        api: api(client((_) =>
            {'success': true, 'already': true, 'balance': 351.0})),
      );
      final result =
          await repo.purchasePremiumWithWallet(idempotencyKey: 'tap-1');
      expect(result.alreadyPurchased, isTrue);
      expect(result.balance, 351.0, reason: 'nothing was charged again');
    });

    test('a yearly purchase passes its own billing period', () async {
      Map<String, dynamic>? sent;
      final mock = MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return json({'success': true, 'balance': 1001.0});
      });
      await WalletRepository(firestore: FakeFirebaseFirestore(), api: api(mock))
          .purchasePremiumWithWallet(billing: 'yearly');
      expect(sent!['billing'], 'yearly');
    });
  });

  group('Insufficient balance', () {
    MockClient insufficient({int required = 14900, int available = 10000}) =>
        MockClient((request) async {
          paths.add(request.url.path);
          return json({
            'detail': {
              'error': 'insufficient_wallet_balance',
              'required': required,
              'available': available,
            }
          }, 402);
        });

    test('it raises a typed error carrying both figures', () async {
      final repo = WalletRepository(firestore: FakeFirebaseFirestore(), api: api(insufficient()));
      await expectLater(
        repo.purchasePremiumWithWallet(),
        throwsA(isA<InsufficientWalletBalance>()
            .having((e) => e.requiredRupees, 'requiredRupees', 149.0)
            .having((e) => e.availableRupees, 'availableRupees', 100.0)
            .having((e) => e.shortfallRupees, 'shortfallRupees', 49.0)),
      );
    });

    test('its message is the Add Funds copy', () async {
      final repo = WalletRepository(firestore: FakeFirebaseFirestore(), api: api(insufficient()));
      try {
        await repo.purchasePremiumWithWallet();
        fail('expected InsufficientWalletBalance');
      } on InsufficientWalletBalance catch (e) {
        expect(e.toString(),
            'Your wallet balance is too low. Please add funds to continue.');
      }
    });

    test('it does NOT fall back to Razorpay on its own', () async {
      final repo = WalletRepository(firestore: FakeFirebaseFirestore(), api: api(insufficient()));
      try {
        await repo.purchasePremiumWithWallet();
      } on InsufficientWalletBalance {
        // expected
      }
      expect(paths, ['/api/payment/membership/purchase-with-wallet'],
          reason: 'Add Funds must be an explicit user choice, not automatic');
    });

    test('an empty wallet reports a zero balance, never negative', () async {
      final repo =
          WalletRepository(firestore: FakeFirebaseFirestore(), api: api(insufficient(available: 0)));
      try {
        await repo.purchasePremiumWithWallet();
        fail('expected InsufficientWalletBalance');
      } on InsufficientWalletBalance catch (e) {
        expect(e.availableRupees, 0.0);
        expect(e.shortfallRupees, 149.0);
      }
    });

    test('a shortfall is never negative even on odd server data', () async {
      final repo = WalletRepository(
          firestore: FakeFirebaseFirestore(),
          api: api(insufficient(required: 14900, available: 20000)));
      try {
        await repo.purchasePremiumWithWallet();
        fail('expected InsufficientWalletBalance');
      } on InsufficientWalletBalance catch (e) {
        expect(e.shortfallRupees, 0.0);
      }
    });
  });

  group('Add Funds (Razorpay tops the wallet up)', () {
    test('createOrder asks the server for the order', () async {
      final repo = WalletRepository(
        firestore: FakeFirebaseFirestore(),
        api: api(client((_) => {
              'order_id': 'order_1',
              'amount': 50000,
              'currency': 'INR',
              'key_id': 'rzp_test',
            })),
      );
      final order = await repo.createOrder(500);
      expect(order.orderId, 'order_1');
      expect(order.amountPaise, 50000);
      expect(paths, ['/api/payment/create-order']);
    });

    test('verifyPayment returns the SERVER balance, not a local sum', () async {
      final repo = WalletRepository(
        firestore: FakeFirebaseFirestore(),
        api: api(client((_) => {
              'success': true,
              'already': false,
              'amount': 500.0,
              'balance': 500.0,
            })),
      );
      expect(await repo.verifyPayment(
        orderId: 'order_1', paymentId: 'pay_1', signature: 'sig',
      ), 500.0);
    });

    test('a repeated verification still returns the unchanged balance',
        () async {
      final repo = WalletRepository(
        firestore: FakeFirebaseFirestore(),
        api: api(client((_) => {
              'success': true,
              'already': true,
              'amount': 500.0,
              'balance': 500.0,
            })),
      );
      expect(await repo.verifyPayment(
        orderId: 'order_1', paymentId: 'pay_1', signature: 'sig',
      ), 500.0, reason: 'a replay must not appear to add money twice');
    });

    test('a rejected verification points the athlete at support', () async {
      final repo = WalletRepository(
        firestore: FakeFirebaseFirestore(),
        api: api(client((_) => {'success': false})),
      );
      await expectLater(
        repo.verifyPayment(
            orderId: 'o', paymentId: 'p', signature: 'bad'),
        throwsA(predicate((e) => e.toString().contains('contact support'))),
      );
    });
  });
}
