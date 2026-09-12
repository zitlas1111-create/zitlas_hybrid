import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show SetOptions;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/payments/data/wallet_repository.dart';
import 'package:zitlas_mobile/features/payments/models/wallet.dart';
import 'package:zitlas_mobile/features/payments/wallet_controller.dart';

/// The ZITLAS Wallet.
///
/// The cases that matter are the ones that used to reach the UI as an
/// exception or a blank screen: an account with no wallet document at all, a
/// Firestore refusal, and a ledger that disagrees with the stored balance.
void main() {
  const uid = 'athlete_1';

  Map<String, dynamic> txn({
    required String id,
    required String type,
    required num amount,
    String description = 'Test transaction',
    String? date,
  }) =>
      {
        'id': id,
        'type': type,
        'amount': amount,
        'description': description,
        'date': date ?? '2026-08-01T10:00:00.000Z',
      };

  Future<FakeFirebaseFirestore> withWallet(Map<String, dynamic>? wallet) async {
    final db = FakeFirebaseFirestore();
    await db.collection('users').doc(uid).set({
      'name': 'Test Athlete',
      'wallet': ?wallet,
    });
    return db;
  }

  group('parsing a real wallet document', () {
    test('every field the backend writes is read back', () {
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'balance': 1500.0,
          'reserved': 500.0,
          'total_added': 3000.0,
          'total_spent': 1500.0,
          'transactions': [
            txn(id: 't1', type: 'credit', amount: 3000),
            txn(id: 't2', type: 'debit', amount: 1500),
          ],
        },
      });

      expect(wallet.exists, isTrue);
      expect(wallet.balance, 1500);
      expect(wallet.reserved, 500);
      expect(wallet.totalAdded, 3000);
      expect(wallet.totalSpent, 1500);
      expect(wallet.transactions.length, 2);
    });

    test('available excludes anything reserved for a pending coaching request', () {
      final wallet = Wallet.fromUserDoc({
        'wallet': {'balance': 1000.0, 'reserved': 400.0},
      });
      expect(wallet.available, 600);
      expect(wallet.balance, 1000, reason: 'the raw balance is still reported separately');
    });

    test('a reservation larger than the balance never shows a negative', () {
      final wallet = Wallet.fromUserDoc({
        'wallet': {'balance': 100.0, 'reserved': 400.0},
      });
      expect(wallet.available, 0);
    });

    test('transactions come out newest first', () {
      // The backend APPENDS, so the stored array is oldest-first.
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'transactions': [
            txn(id: 'oldest', type: 'credit', amount: 100),
            txn(id: 'middle', type: 'debit', amount: 50),
            txn(id: 'newest', type: 'credit', amount: 200),
          ],
        },
      });
      expect(wallet.transactions.map((t) => t.id).toList(), ['newest', 'middle', 'oldest']);
    });

    test('every transaction type the ledger can contain is recognised', () {
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'transactions': [
            txn(id: 'a', type: 'credit', amount: 10),
            txn(id: 'b', type: 'debit', amount: 10),
            txn(id: 'c', type: 'reward', amount: 10),
            txn(id: 'd', type: 'refund', amount: 10),
            txn(id: 'e', type: 'referral', amount: 10),
            txn(id: 'f', type: 'cashback', amount: 10),
          ],
        },
      });
      expect(
        wallet.transactions.map((t) => t.type).toSet(),
        {
          WalletTransactionType.credit,
          WalletTransactionType.debit,
          WalletTransactionType.reward,
          WalletTransactionType.refund,
          WalletTransactionType.referral,
          WalletTransactionType.cashback,
        },
      );
    });

    test('direction comes from the type, not the sign of the amount', () {
      // The backend stores POSITIVE amounts for debits too.
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'transactions': [txn(id: 'd', type: 'debit', amount: 500)],
        },
      });
      final debit = wallet.transactions.single;
      expect(debit.amount, 500, reason: 'displayed magnitude stays positive');
      expect(debit.type.isCredit, isFalse);
      expect(debit.signedAmount, -500);
    });

    test('a type this build does not know still renders, unsigned', () {
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'transactions': [txn(id: 'x', type: 'some_future_type', amount: 100)],
        },
      });
      final entry = wallet.transactions.single;
      expect(entry.type, WalletTransactionType.unknown);
      expect(entry.type.isCredit, isFalse, reason: 'never assume money in');
      expect(entry.amount, 100);
    });

    test('a malformed entry is skipped, not fatal to the whole ledger', () {
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'transactions': [
            txn(id: 'good', type: 'credit', amount: 100),
            {'id': 'no_amount', 'type': 'credit'},
            'not even a map',
            txn(id: 'good2', type: 'debit', amount: 50),
          ],
        },
      });
      expect(wallet.transactions.length, 2);
      expect(wallet.transactions.map((t) => t.id), containsAll(['good', 'good2']));
    });

    test('an unparseable date is left null rather than defaulted to now', () {
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'transactions': [txn(id: 'a', type: 'credit', amount: 10, date: 'garbage')],
        },
      });
      expect(wallet.transactions.single.date, isNull);
    });

    test('a legacy entry with no id still gets a stable unique key', () {
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'transactions': [
            {'type': 'credit', 'amount': 10, 'description': 'old'},
            {'type': 'debit', 'amount': 20, 'description': 'older'},
          ],
        },
      });
      final ids = wallet.transactions.map((t) => t.id).toList();
      expect(ids.toSet().length, 2, reason: 'duplicate keys would break the list');
    });
  });

  group('balance equals credits minus debits', () {
    test('a consistent ledger reconciles exactly', () {
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'balance': 1500.0,
          'transactions': [
            txn(id: 'a', type: 'credit', amount: 2000),
            txn(id: 'b', type: 'debit', amount: 500),
          ],
        },
      });
      expect(wallet.totalCredits, 2000);
      expect(wallet.totalDebits, 500);
      expect(wallet.ledgerBalance, 1500);
      expect(wallet.ledgerBalance, wallet.balance);
      expect(wallet.ledgerDisagrees, isFalse);
    });

    test('rewards and refunds count towards credits', () {
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'balance': 250.0,
          'transactions': [
            txn(id: 'a', type: 'reward', amount: 100),
            txn(id: 'b', type: 'refund', amount: 150),
          ],
        },
      });
      expect(wallet.ledgerBalance, 250);
      expect(wallet.ledgerDisagrees, isFalse);
    });

    test('a divergence is REPORTED, never silently corrected', () {
      // The stored balance is what the server will actually spend against.
      // Showing a locally recomputed figure would offer money that isn't there.
      final wallet = Wallet.fromUserDoc({
        'wallet': {
          'balance': 900.0,
          'transactions': [txn(id: 'a', type: 'credit', amount: 1000)],
        },
      });
      expect(wallet.ledgerDisagrees, isTrue);
      expect(wallet.balance, 900, reason: 'the SERVER balance is still what is shown');
      expect(wallet.available, 900);
    });

    test('an empty ledger is not treated as a mismatch', () {
      // A wallet funded before the transactions array existed.
      final wallet = Wallet.fromUserDoc({'wallet': {'balance': 500.0}});
      expect(wallet.ledgerDisagrees, isFalse);
    });
  });

  group('a missing wallet is a state, not a crash', () {
    test('a user document with no wallet field reads as an empty wallet', () async {
      final db = await withWallet(null);
      final wallet = await WalletRepository(firestore: db).fetch(uid);

      expect(wallet.exists, isFalse);
      expect(wallet.balance, 0);
      expect(wallet.available, 0);
      expect(wallet.transactions, isEmpty);
      expect(wallet.hasTransactions, isFalse);
    });

    test('a user document that does not exist at all reads as an empty wallet', () async {
      final db = FakeFirebaseFirestore();
      final wallet = await WalletRepository(firestore: db).fetch('never_signed_up');
      expect(wallet.exists, isFalse);
      expect(wallet.balance, 0);
    });

    test('the app never writes a wallet document itself', () async {
      // Security Rules reject a client-written wallet outright
      // (createOmits/updateKeeps), and a client asserting its own balance is
      // the bug class this whole design avoids. Reading must stay a read.
      final db = await withWallet(null);
      await WalletRepository(firestore: db).fetch(uid);

      final doc = await db.collection('users').doc(uid).get();
      expect(doc.data()!.containsKey('wallet'), isFalse);
    });

    test('a zero wallet that DOES exist is distinguishable from no wallet', () async {
      final db = await withWallet({'balance': 0.0, 'total_added': 0.0});
      final wallet = await WalletRepository(firestore: db).fetch(uid);
      expect(wallet.exists, isTrue);
      expect(wallet.balance, 0);
    });
  });

  group('the controller drives the screen through real states', () {
    test('a wallet with transactions ends in ready', () async {
      final db = await withWallet({
        'balance': 700.0,
        'transactions': [txn(id: 'a', type: 'credit', amount: 700)],
      });
      final controller = WalletController(uid: uid, repository: WalletRepository(firestore: db));
      addTearDown(controller.dispose);

      expect(controller.status, WalletStatus.loading, reason: 'shows a spinner first');
      await _settle(controller);

      expect(controller.status, WalletStatus.ready);
      expect(controller.wallet.available, 700);
      expect(controller.wallet.transactions.length, 1);
      expect(controller.errorMessage, isNull);
    });

    test('a brand-new account reaches ready with an empty wallet, not an error', () async {
      final db = await withWallet(null);
      final controller = WalletController(uid: uid, repository: WalletRepository(firestore: db));
      addTearDown(controller.dispose);
      await _settle(controller);

      expect(controller.status, WalletStatus.ready);
      expect(controller.wallet.exists, isFalse);
      expect(controller.errorMessage, isNull);
    });

    test('a live server credit arrives without a refresh', () async {
      final db = await withWallet({'balance': 100.0});
      final controller = WalletController(uid: uid, repository: WalletRepository(firestore: db));
      addTearDown(controller.dispose);
      await _settle(controller);
      expect(controller.wallet.balance, 100);

      // The backend credits the wallet (e.g. a top-up completed on the website).
      await db.collection('users').doc(uid).set({
        'wallet': {
          'balance': 600.0,
          'total_added': 500.0,
          'transactions': [txn(id: 'new', type: 'credit', amount: 500)],
        },
      }, SetOptions(merge: true));
      await _settle(controller);

      expect(controller.wallet.balance, 600);
      expect(controller.wallet.transactions.first.id, 'new');
    });

    test('a stream failure becomes a retryable error, never an exception', () async {
      final controller = WalletController(
        uid: uid,
        repository: _FailingRepository(Exception('permission-denied')),
      );
      addTearDown(controller.dispose);
      await _settle(controller);

      expect(controller.status, WalletStatus.error);
      expect(controller.errorMessage, contains('access'));
    });

    test('an offline device gets a connection message and a retry', () async {
      final controller = WalletController(
        uid: uid,
        repository: _FailingRepository(Exception('Failed host lookup: api.zitlas.com')),
      );
      addTearDown(controller.dispose);
      await _settle(controller);

      expect(controller.status, WalletStatus.error);
      expect(controller.errorMessage, contains('connection'));
    });

    test('a timeout says so plainly', () async {
      final controller = WalletController(
        uid: uid,
        repository: _FailingRepository(TimeoutException('timed out')),
      );
      addTearDown(controller.dispose);
      await _settle(controller);
      expect(controller.errorMessage, contains('too long'));
    });

    test('retry re-subscribes and recovers', () async {
      final repo = _FlakyRepository(
        failure: Exception('unavailable'),
        recovered: const Wallet(balance: 250, exists: true),
      );
      final controller = WalletController(uid: uid, repository: repo);
      addTearDown(controller.dispose);
      await _settle(controller);
      expect(controller.status, WalletStatus.error);

      repo.healed = true;
      await controller.retry();
      await _settle(controller);

      expect(controller.status, WalletStatus.ready);
      expect(controller.wallet.balance, 250);
      expect(controller.errorMessage, isNull);
    });

    test('a raw exception never reaches the UI as a raw exception', () async {
      final controller = WalletController(
        uid: uid,
        repository: _FailingRepository(StateError('Bad state: something internal exploded')),
      );
      addTearDown(controller.dispose);
      await _settle(controller);

      expect(controller.errorMessage, isNotNull);
      expect(controller.errorMessage, isNot(contains('Bad state')));
    });

    test('disposing mid-flight does not notify a dead controller', () async {
      final db = await withWallet({'balance': 10.0});
      final controller = WalletController(uid: uid, repository: WalletRepository(firestore: db));
      controller.dispose();
      // No notifyListeners-after-dispose crash.
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
  });

  group('top-up', () {
    test('a failed order creation surfaces a message and clears the busy flag', () async {
      final controller = WalletController(
        uid: uid,
        repository: _FailingRepository(Exception('Could not start the payment. Please try again.')),
      );
      addTearDown(controller.dispose);

      final order = await controller.startTopUp(500);
      expect(order, isNull);
      expect(controller.paymentInProgress, isFalse, reason: 'the button must re-enable');
      expect(controller.errorMessage, contains('Could not start'));
    });

    test('a second tap while a payment is in flight is ignored', () async {
      final repo = _SlowOrderRepository();
      final controller = WalletController(uid: uid, repository: repo);
      addTearDown(controller.dispose);

      final first = controller.startTopUp(500);
      final second = await controller.startTopUp(500);
      expect(second, isNull, reason: 'no second order may be created');
      await first;
      expect(repo.orderCalls, 1);
    });

    test('a verification failure points at support, not at "try again"', () async {
      final controller = WalletController(
        uid: uid,
        repository: _FailingRepository(Exception(
          'Payment could not be verified. If money was deducted, contact support '
          'with your payment ID — it has not been lost.',
        )),
      );
      addTearDown(controller.dispose);

      final balance = await controller.confirmTopUp(
        orderId: 'order_1',
        paymentId: 'pay_1',
        signature: 'sig',
      );
      expect(balance, isNull);
      expect(controller.errorMessage, contains('contact support'));
    });

    test('an order is parsed into the fields the checkout sheet needs', () {
      final order = WalletOrder.fromMap({
        'key_id': 'rzp_test_abc',
        'order_id': 'order_XYZ',
        'amount': 50000,
        'currency': 'INR',
      });
      expect(order.keyId, 'rzp_test_abc');
      expect(order.orderId, 'order_XYZ');
      expect(order.amountPaise, 50000);
      expect(order.amountRupees, 500, reason: 'Razorpay works in paise, ZITLAS in rupees');
    });

    test('an incomplete order is rejected rather than opening a broken sheet', () {
      expect(
        () => WalletOrder.fromMap({'order_id': 'order_X', 'amount': 100}),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('spending checks', () {
    test('canAfford uses the SPENDABLE figure, not the raw balance', () {
      const wallet = Wallet(balance: 1000, reserved: 800, exists: true);
      expect(wallet.canAfford(150), isTrue);
      expect(wallet.canAfford(500), isFalse,
          reason: 'reserved money is locked by a pending coaching request');
    });
  });
}

/// Pumps the microtask/stream queue until the controller has settled.
Future<void> _settle(WalletController controller) =>
    Future<void>.delayed(const Duration(milliseconds: 40));

class _FailingRepository implements WalletRepository {
  @override
  Future<TopUpVerification> verifyTopUp({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async =>
      throw UnimplementedError();

  _FailingRepository(this.error);
  final Object error;

  @override
  Stream<Wallet> watch(String uid) => Stream<Wallet>.error(error);

  @override
  Future<Wallet> fetch(String uid) async => throw error;

  @override
  Future<WalletOrder> createOrder(double amountRupees) async => throw error;

  @override
  Future<double> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async =>
      throw error;

  @override
  Future<WalletPurchaseResult> purchasePremiumWithWallet({
    String billing = 'monthly',
    String? idempotencyKey,
  }) async =>
      throw UnimplementedError(
          'not exercised by this double — see wallet_premium_test.dart');
}

class _FlakyRepository implements WalletRepository {
  @override
  Future<TopUpVerification> verifyTopUp({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async =>
      throw UnimplementedError();

  _FlakyRepository({required this.failure, required this.recovered});
  final Object failure;
  final Wallet recovered;
  bool healed = false;

  @override
  Stream<Wallet> watch(String uid) =>
      healed ? Stream<Wallet>.value(recovered) : Stream<Wallet>.error(failure);

  @override
  Future<Wallet> fetch(String uid) async => recovered;

  @override
  Future<WalletOrder> createOrder(double amountRupees) async => throw failure;

  @override
  Future<double> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async =>
      throw failure;

  @override
  Future<WalletPurchaseResult> purchasePremiumWithWallet({
    String billing = 'monthly',
    String? idempotencyKey,
  }) async =>
      throw UnimplementedError(
          'not exercised by this double — see wallet_premium_test.dart');
}

class _SlowOrderRepository implements WalletRepository {
  @override
  Future<TopUpVerification> verifyTopUp({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async =>
      throw UnimplementedError();

  int orderCalls = 0;

  @override
  Stream<Wallet> watch(String uid) => const Stream<Wallet>.empty();

  @override
  Future<Wallet> fetch(String uid) async => Wallet.empty;

  @override
  Future<WalletOrder> createOrder(double amountRupees) async {
    orderCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    return const WalletOrder(
      keyId: 'rzp_test',
      orderId: 'order_1',
      amountPaise: 50000,
      currency: 'INR',
    );
  }

  @override
  Future<double> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async =>
      500;

  @override
  Future<WalletPurchaseResult> purchasePremiumWithWallet({
    String billing = 'monthly',
    String? idempotencyKey,
  }) async =>
      throw UnimplementedError(
          'not exercised by this double — see wallet_premium_test.dart');
}
