import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart' show SetOptions;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/auth/auth_state.dart';
import 'package:zitlas_mobile/features/payments/data/razorpay_checkout.dart';
import 'package:zitlas_mobile/features/payments/data/wallet_repository.dart';
import 'package:zitlas_mobile/models/user_model.dart';

/// Shared fakes for the Add Funds / Premium-from-wallet tests. Not a test
/// file itself (no `_test` suffix).

const kUid = 'athlete_1';

/// The ZITLAS payment backend as far as the app can tell: every wallet
/// endpoint the app calls, with the real backend's rules — server-priced,
/// signature-checked, idempotent — writing `users/{uid}.wallet` into the fake
/// Firestore the way the real backend does. The app itself never writes it.
class FakeWalletBackend {
  FakeWalletBackend(this.db, {this.uid = kUid});

  final FakeFirebaseFirestore db;
  final String uid;

  final List<http.Request> requests = [];
  List<String> get paths => requests.map((r) => r.url.path).toList();

  bool walletFrozen = false;
  bool trialModeUnreachable = false;

  /// Forces an error status on create-order.
  int? createOrderStatus;

  /// Verify calls that get no response at all / a 500.
  int verifyNetworkFailures = 0;
  int verifyServerErrors = 0;

  /// A concurrent server-side credit landing with the verification — proves
  /// the app shows the SERVER's balance rather than adding locally.
  double extraCreditOnVerify = 0;

  int premiumPricePaise = 14900;

  final Map<String, double> _orders = {};
  final Set<String> _paid = {};
  int _orderSeq = 0;

  ApiClient api() => ApiClient(httpClient: MockClient(_handle), baseUrl: 'https://api.test');

  Future<Map<String, dynamic>> _wallet() async {
    final data = (await db.collection('users').doc(uid).get()).data() ?? {};
    return Map<String, dynamic>.from(
        (data['wallet'] as Map?) ?? {'balance': 0.0, 'reserved': 0.0, 'transactions': <dynamic>[]});
  }

  Future<http.Response> _handle(http.Request r) async {
    requests.add(r);
    Map<String, dynamic> body() =>
        r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;

    switch (r.url.path) {
      case '/api/system/trial-mode':
        if (trialModeUnreachable) throw http.ClientException('Failed host lookup');
        return _json({'walletFrozen': walletFrozen});

      case '/api/payment/create-order':
        if (walletFrozen) {
          return _json({'detail': {'error': 'wallet_frozen', 'message': 'frozen'}}, 503);
        }
        if (createOrderStatus != null) return _json({'detail': 'razorpay_unavailable'}, createOrderStatus!);
        final amount = (body()['amount'] as num).toDouble();
        if (amount <= 0) return _json({'detail': 'invalid_amount'}, 400);
        final id = 'order_${++_orderSeq}';
        _orders[id] = amount;
        return _json({
          'order_id': id,
          'amount': (amount * 100).round(),
          'currency': 'INR',
          'key_id': 'rzp_test_key',
        });

      case '/api/payment/verify':
        if (verifyNetworkFailures > 0) {
          verifyNetworkFailures--;
          throw http.ClientException('Connection reset by peer');
        }
        if (verifyServerErrors > 0) {
          verifyServerErrors--;
          return _json({'detail': 'payment_credit_failed'}, 500);
        }
        final b = body();
        final orderId = b['razorpay_order_id'] as String;
        if (b['razorpay_signature'] == 'bad') return _json({'detail': 'signature_mismatch'}, 400);
        final amount = _orders[orderId];
        if (amount == null) return _json({'detail': 'order_not_found'}, 404);
        final wallet = await _wallet();
        if (_paid.contains(orderId)) {
          // Idempotent: an order already credited is never credited again.
          return _json({'success': true, 'already': true, 'amount': amount, 'balance': wallet['balance']});
        }
        _paid.add(orderId);
        final balance =
            ((wallet['balance'] as num?) ?? 0).toDouble() + amount + extraCreditOnVerify;
        final txns = List<dynamic>.from((wallet['transactions'] as List?) ?? const []);
        txns.add({
          'id': 'txn_${b['razorpay_payment_id']}',
          'type': 'credit',
          'amount': amount,
          'description': 'Added Funds via Razorpay',
          'date': DateTime.now().toUtc().toIso8601String(),
        });
        await db.collection('users').doc(uid).set({
          'wallet': {
            ...wallet,
            'balance': balance,
            'total_added': ((wallet['total_added'] as num?) ?? 0) + amount,
            'transactions': txns,
          },
        }, SetOptions(merge: true));
        return _json({'success': true, 'already': false, 'amount': amount, 'balance': balance});

      case '/api/payment/membership/purchase-with-wallet':
        if (walletFrozen) {
          return _json({'detail': {'error': 'wallet_frozen', 'message': 'frozen'}}, 503);
        }
        final wallet = await _wallet();
        final balancePaise = (((wallet['balance'] as num?) ?? 0) * 100).round();
        final reservedPaise = (((wallet['reserved'] as num?) ?? 0) * 100).round();
        final available = balancePaise - reservedPaise;
        if (available < premiumPricePaise) {
          return _json({
            'detail': {
              'error': 'insufficient_wallet_balance',
              'required': premiumPricePaise,
              'available': available,
            },
          }, 402);
        }
        final newBalance = (balancePaise - premiumPricePaise) / 100.0;
        await db.collection('users').doc(uid).set({
          'wallet': {...wallet, 'balance': newBalance},
          'membership': {'plan': 'premium', 'billing': 'monthly'},
        }, SetOptions(merge: true));
        return _json({
          'success': true,
          'already': false,
          'balance': newBalance,
          'charged': premiumPricePaise / 100,
        });
    }
    return _json({'detail': 'not_found'}, 404);
  }

  static http.Response _json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}

enum FakePayment { succeed, cancel, fail, badSignature }

/// Razorpay's native sheet, replaced. Records whether it was ever opened —
/// the Premium tests assert it is NOT, for a short wallet.
class FakeCheckout implements RazorpayCheckout {
  FakeCheckout([this.mode = FakePayment.succeed]);

  FakePayment mode;
  int opened = 0;
  WalletOrder? lastOrder;

  /// When set, the sheet stays "open" until this completes.
  Completer<void>? gate;

  @override
  Future<CheckoutResult> open({
    required WalletOrder order,
    required String description,
    String? email,
    String? contact,
  }) async {
    opened++;
    lastOrder = order;
    if (gate != null) await gate!.future;
    switch (mode) {
      case FakePayment.succeed:
        return CheckoutResult.success(
            orderId: order.orderId, paymentId: 'pay_${order.orderId}', signature: 'sig_ok');
      case FakePayment.badSignature:
        return CheckoutResult.success(
            orderId: order.orderId, paymentId: 'pay_${order.orderId}', signature: 'bad');
      case FakePayment.cancel:
        return const CheckoutResult.cancelled();
      case FakePayment.fail:
        return const CheckoutResult.failed('Your card was declined.');
    }
  }

  @override
  void dispose() {}
}

class FakeUser implements User {
  FakeUser(this.token);
  final String token;

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => token;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAuth implements FirebaseAuth {
  FakeAuth([this.user]);
  final User? user;

  @override
  User? get currentUser => user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAuthState extends ChangeNotifier implements AuthState {
  @override
  UserModel? get profile =>
      const UserModel(uid: kUid, email: 'athlete@example.com', name: 'Test Athlete');

  @override
  AuthStatus get status => AuthStatus.authenticated;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A user document with a server-written wallet.
Future<FakeFirebaseFirestore> walletDb({double balance = 1000}) async {
  final db = FakeFirebaseFirestore();
  await db.collection('users').doc(kUid).set({
    'name': 'Test Athlete',
    'membership': {'plan': 'free'},
    'wallet': {
      'balance': balance,
      'reserved': 0.0,
      'total_added': balance,
      'total_spent': 0.0,
      'transactions': <dynamic>[],
    },
  });
  return db;
}

WalletRepository walletRepo(FakeFirebaseFirestore db, FakeWalletBackend backend,
        {String token = 'ID_TOKEN'}) =>
    WalletRepository(firestore: db, api: backend.api(), auth: FakeAuth(FakeUser(token)));
