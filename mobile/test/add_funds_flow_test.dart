import 'dart:async';
import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/core/storage/local_storage_service.dart';
import 'package:zitlas_mobile/features/payments/add_funds_flow.dart';

import 'wallet_fakes.dart';

/// Razorpay → Add Funds → Wallet, end to end against the backend's rules.
///
/// THE RULE THESE PROTECT: "funds added" is said only after the BACKEND
/// confirms the credit, and the balance shown is the server's — never a
/// local sum. Every other ending (cancelled, declined, refused, no answer)
/// credits nothing, and the one ending where money may have moved without a
/// confirmation (no answer) is kept and retried, never forgotten.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFirebaseFirestore db;
  late FakeWalletBackend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorageService.init();
    db = await walletDb(balance: 1000);
    backend = FakeWalletBackend(db);
  });

  AddFundsFlow flow(FakeCheckout checkout, {String token = 'ID_TOKEN'}) =>
      AddFundsFlow(repository: walletRepo(db, backend, token: token), checkoutFactory: () => checkout);

  Future<double> storedBalance() async =>
      (((await db.collection('users').doc(kUid).get()).data()!['wallet'] as Map)['balance'] as num)
          .toDouble();

  group('creating the order', () {
    test('is authenticated and sends only the amount', () async {
      await flow(FakeCheckout()).run(uid: kUid, amountRupees: 500);
      final create = backend.requests.firstWhere((r) => r.url.path == '/api/payment/create-order');
      expect(create.headers['Authorization'], 'Bearer ID_TOKEN',
          reason: 'create-order verifies the caller; without a token it answers 401');
      expect(jsonDecode(create.body), {'amount': 500.0});
    });

    test('an invalid amount never reaches the backend', () async {
      final f = flow(FakeCheckout());
      for (final amount in [0.0, -5.0, 50001.0, double.nan]) {
        final outcome = await f.run(uid: kUid, amountRupees: amount);
        expect(outcome.status, TopUpStatus.failed, reason: 'amount $amount');
      }
      expect(backend.requests, isEmpty);
    });

    test('a failed order is reported and Razorpay never opens', () async {
      backend.createOrderStatus = 500;
      final checkout = FakeCheckout();
      final outcome = await flow(checkout).run(uid: kUid, amountRupees: 500);
      expect(outcome.status, TopUpStatus.failed);
      expect(checkout.opened, 0);
    });

    test('an expired session is explained, not shown as a raw 401', () async {
      backend.createOrderStatus = 401;
      final outcome = await flow(FakeCheckout()).run(uid: kUid, amountRupees: 500);
      expect(outcome.status, TopUpStatus.failed);
      expect(outcome.message, contains('sign in again'));
    });

    test('a frozen Wallet opens nothing', () async {
      backend.walletFrozen = true;
      final checkout = FakeCheckout();
      final outcome = await flow(checkout).run(uid: kUid, amountRupees: 500);
      expect(outcome.status, TopUpStatus.frozen);
      expect(checkout.opened, 0);
    });
  });

  group('checkout → backend verification', () {
    test('a Razorpay success is verified by the backend, which credits the wallet', () async {
      final outcome = await flow(FakeCheckout()).run(uid: kUid, amountRupees: 500);

      expect(outcome.status, TopUpStatus.credited);
      expect(outcome.balance, 1500, reason: "the SERVER's balance");
      expect(outcome.amountRupees, 500);
      expect(backend.paths, ['/api/payment/create-order', '/api/payment/verify']);
      final verify = backend.requests.last;
      expect(jsonDecode(verify.body), {
        'razorpay_order_id': 'order_1',
        'razorpay_payment_id': 'pay_order_1',
        'razorpay_signature': 'sig_ok',
      });
      expect(verify.headers['Authorization'], 'Bearer ID_TOKEN');
      expect(await storedBalance(), 1500);
    });

    test('the balance reported is the server figure, never a local sum', () async {
      backend.extraCreditOnVerify = 100; // something else landed server-side
      final outcome = await flow(FakeCheckout()).run(uid: kUid, amountRupees: 500);
      expect(outcome.balance, 1600, reason: 'a local 1000 + 500 would say 1500');
    });

    test('a cancelled checkout verifies nothing and credits nothing', () async {
      final outcome = await flow(FakeCheckout(FakePayment.cancel)).run(uid: kUid, amountRupees: 500);
      expect(outcome.status, TopUpStatus.cancelled);
      expect(outcome.message, contains('nothing was charged'));
      expect(backend.paths, isNot(contains('/api/payment/verify')));
      expect(await storedBalance(), 1000);
    });

    test('a declined payment verifies nothing', () async {
      final outcome = await flow(FakeCheckout(FakePayment.fail)).run(uid: kUid, amountRupees: 500);
      expect(outcome.status, TopUpStatus.failed);
      expect(outcome.message, 'Your card was declined.');
      expect(backend.paths, isNot(contains('/api/payment/verify')));
    });

    test('a verification the backend refuses is a support case, never a credit', () async {
      final outcome =
          await flow(FakeCheckout(FakePayment.badSignature)).run(uid: kUid, amountRupees: 500);
      expect(outcome.status, TopUpStatus.rejected);
      expect(outcome.message, contains('contact support'));
      expect(outcome.message, contains('pay_order_1'), reason: 'support needs the payment id');
      expect(await storedBalance(), 1000);
      expect(const PendingTopUpStore().load(kUid), isNull,
          reason: 'a definite refusal is not retried forever');
    });

    test('no answer from verification keeps the payment and a retry completes it', () async {
      backend.verifyNetworkFailures = 1;
      final f = flow(FakeCheckout());

      final first = await f.run(uid: kUid, amountRupees: 500);
      expect(first.status, TopUpStatus.unconfirmed);
      expect(first.pending, isNotNull);
      expect(const PendingTopUpStore().load(kUid), isNotNull,
          reason: 'the payment must survive the app being closed now');

      final second = await f.retryVerification(kUid, first.pending!);
      expect(second.status, TopUpStatus.credited);
      expect(second.balance, 1500);
      expect(const PendingTopUpStore().load(kUid), isNull);
    });

    test('a server fault during verification is retryable, not a failure', () async {
      backend.verifyServerErrors = 1;
      final outcome = await flow(FakeCheckout()).run(uid: kUid, amountRupees: 500);
      expect(outcome.status, TopUpStatus.unconfirmed);
    });

    test('a verification repeated after it succeeded never credits twice', () async {
      final f = flow(FakeCheckout());
      final first = await f.run(uid: kUid, amountRupees: 500);
      expect(first.balance, 1500);

      final again = await f.retryVerification(
        kUid,
        const PendingTopUp(
            orderId: 'order_1', paymentId: 'pay_order_1', signature: 'sig_ok', amountRupees: 500),
      );
      expect(again.status, TopUpStatus.credited);
      expect(again.alreadyCredited, isTrue);
      expect(again.balance, 1500, reason: 'unchanged');
      expect(await storedBalance(), 1500);
    });
  });

  group('idempotency around the app', () {
    test('a second tap while an attempt is running is ignored', () async {
      final checkout = FakeCheckout()..gate = Completer<void>();
      final f = flow(checkout);

      final first = f.run(uid: kUid, amountRupees: 500);
      await pumpEventQueue();
      final second = await f.run(uid: kUid, amountRupees: 500);
      expect(second.status, TopUpStatus.busy);

      checkout.gate!.complete();
      expect((await first).status, TopUpStatus.credited);
      expect(backend.paths.where((p) => p == '/api/payment/create-order'), hasLength(1));
    });

    test('a payment left unverified by a closed app is finished on the next open', () async {
      // The earlier session: order created, Razorpay paid, app killed.
      final f = flow(FakeCheckout());
      backend.verifyNetworkFailures = 1;
      await f.run(uid: kUid, amountRupees: 500);
      expect(await storedBalance(), 1000);

      // The next session.
      final resumed = await flow(FakeCheckout()).resumePending(kUid);
      expect(resumed!.status, TopUpStatus.credited);
      expect(await storedBalance(), 1500);
      expect(const PendingTopUpStore().load(kUid), isNull);
    });

    test('with nothing pending, resuming does nothing at all', () async {
      expect(await flow(FakeCheckout()).resumePending(kUid), isNull);
      expect(backend.requests, isEmpty);
    });

    test("one account's pending payment is never resumed for another", () async {
      final f = flow(FakeCheckout());
      backend.verifyNetworkFailures = 1;
      await f.run(uid: kUid, amountRupees: 500);
      expect(await flow(FakeCheckout()).resumePending('someone_else'), isNull);
    });
  });
}
