import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../models/wallet.dart';
import '../wallet_freeze.dart';

/// Reads the athlete's real wallet and starts real top-ups.
///
/// TWO HARD RULES, both inherited from the website and enforced by
/// `firestore.rules`:
///
///  1. **The client never writes the wallet.** `users/{uid}.wallet` is
///     backend-only (`updateKeeps(['wallet', ...])`). Money moves exclusively
///     through `POST /api/payment/verify` (credit, after an HMAC signature
///     check) and `POST /api/payment/charge` (debit, inside a Firestore
///     transaction). There is deliberately no `credit()`/`debit()` here.
///  2. **`wallet_transactions` is unreadable by any client**
///     (`allow read, write: if false`). That collection is the internal audit
///     log, not the athlete's statement. The statement is the `transactions`
///     array on the wallet itself, which is exactly what the website renders.
class WalletRepository {
  WalletRepository({FirebaseFirestore? firestore, ApiClient? api, FirebaseAuth? auth})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        // Nullable so FirebaseAuth.instance is resolved lazily — the same
        // pattern as DietRepository.
        // ignore: prefer_initializing_formals
        _auth = auth,
        _api = api ?? ApiClient() {
    // EVERY endpoint below verifies its caller (verify_firebase_token):
    // create-order, verify, membership/purchase-with-wallet. This ApiClient
    // used to carry no token at all, so each would have been refused 401 the
    // moment the Wallet was switched on.
    _api.authTokenProvider ??= () async {
      try {
        return await (_auth ?? FirebaseAuth.instance).currentUser?.getIdToken();
      } catch (_) {
        return null;
      }
    };
  }

  final FirebaseFirestore _firestore;
  final FirebaseAuth? _auth;
  final ApiClient _api;

  DocumentReference<Map<String, dynamic>> _userDoc(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Live wallet.
  ///
  /// A snapshot listener rather than a one-shot read so a top-up completed on
  /// the website — or a coaching charge accepted by an expert seconds ago —
  /// lands on screen without a pull-to-refresh.
  Stream<Wallet> watch(String uid) {
    return _userDoc(uid).snapshots().map((snap) {
      // A missing user document, or one with no `wallet` field, is a REAL and
      // ordinary state for a new account: the backend writes the wallet on the
      // first credit. It is never an error, and the app must not create it —
      // Security Rules reject a client-written wallet outright
      // (`createOmits(['wallet', ...])`), so "auto-creating" it would fail the
      // write and, worse, would be a client asserting its own balance.
      final wallet = snap.exists ? Wallet.fromUserDoc(snap.data()) : Wallet.empty;
      if (kDebugMode) {
        debugPrint('[WALLET] fetch uid=$uid exists=${wallet.exists} '
            'balance=${wallet.balance} reserved=${wallet.reserved} '
            'available=${wallet.available} transactions=${wallet.transactions.length}');
        if (wallet.ledgerDisagrees) {
          debugPrint('[WALLET] LEDGER MISMATCH — stored balance=${wallet.balance} '
              'but credits(${wallet.totalCredits}) - debits(${wallet.totalDebits}) '
              '= ${wallet.ledgerBalance}');
        }
      }
      return wallet;
    });
  }

  /// One-shot read, for callers that just need the current figure.
  Future<Wallet> fetch(String uid) async {
    final snap = await _userDoc(uid).get();
    final wallet = snap.exists ? Wallet.fromUserDoc(snap.data()) : Wallet.empty;
    if (kDebugMode) {
      debugPrint('[WALLET] one-shot fetch uid=$uid available=${wallet.available} '
          'transactions=${wallet.transactions.length}');
    }
    return wallet;
  }

  /// `POST /api/payment/create-order` — a real Razorpay order, created and
  /// recorded server-side so `/verify` has an authoritative amount to credit.
  ///
  /// Returns the order fields the checkout sheet needs (`key_id`, `order_id`,
  /// `amount` in paise, `currency`). The API key is issued by the server per
  /// order; nothing secret is compiled into the app.
  Future<WalletOrder> createOrder(double amountRupees) async {
    if (kDebugMode) debugPrint('[WALLET] create-order amount=₹$amountRupees');
    try {
      final res = await _api.post('/api/payment/create-order', body: {'amount': amountRupees});
      final map = (res as Map).cast<String, dynamic>();
      if (kDebugMode) debugPrint('[WALLET] create-order ok order_id=${map['order_id']}');
      return WalletOrder.fromMap(map);
    } on ApiException catch (e) {
      if (kDebugMode) debugPrint('[WALLET] create-order FAILED ${e.statusCode}: ${e.body}');
      if (_isFrozen(e)) throw const WalletFrozenException();
      throw Exception(_friendlyError(e, 'Could not start the payment. Please try again.'));
    }
  }

  /// `POST /api/payment/verify` — hands Razorpay's signed response to the
  /// backend, which checks the HMAC and credits the wallet in a transaction.
  ///
  /// Three honest outcomes, because they need three different answers:
  ///   * the server CONFIRMED the credit — a [TopUpVerification]. A repeat for
  ///     an order already paid comes back `alreadyCredited` with the unchanged
  ///     balance: a retried verification never credits twice.
  ///   * the server REFUSED the payment — [VerificationRejected]. Retrying
  ///     cannot help; the message points at support with the payment id.
  ///   * no answer, or a server fault — [VerificationUnconfirmed]. Retrying
  ///     with the SAME Razorpay details is safe, and is the fix.
  Future<TopUpVerification> verifyTopUp({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    if (kDebugMode) debugPrint('[WALLET] verify order=$orderId payment=$paymentId');
    try {
      final res = await _api.post('/api/payment/verify', body: {
        'razorpay_order_id': orderId,
        'razorpay_payment_id': paymentId,
        'razorpay_signature': signature,
      });
      final map = res is Map ? res.cast<String, dynamic>() : const <String, dynamic>{};
      if (map['success'] != true) {
        if (kDebugMode) debugPrint('[WALLET] verify rejected: $map');
        throw VerificationRejected(paymentId: paymentId);
      }
      final verified = TopUpVerification(
        balance: (map['balance'] as num?)?.toDouble() ?? 0,
        amountRupees: (map['amount'] as num?)?.toDouble(),
        alreadyCredited: map['already'] == true,
      );
      if (kDebugMode) {
        debugPrint('[WALLET] verified — server balance=${verified.balance} '
            'already=${verified.alreadyCredited}');
      }
      return verified;
    } on ApiException catch (e) {
      if (kDebugMode) debugPrint('[WALLET] verify FAILED ${e.statusCode}: ${e.body}');
      if (_isFrozen(e)) {
        throw VerificationUnconfirmed(paymentId: paymentId, walletFrozen: true);
      }
      final retryable = e.isNetworkError ||
          e.isServerError ||
          e.statusCode == 401 ||
          e.statusCode == 408 ||
          e.statusCode == 429;
      if (retryable) throw VerificationUnconfirmed(paymentId: paymentId);
      throw VerificationRejected(paymentId: paymentId);
    }
  }

  /// [verifyTopUp], reduced to the confirmed SERVER balance — the only
  /// balance the app will ever show.
  Future<double> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    final verified = await verifyTopUp(
      orderId: orderId,
      paymentId: paymentId,
      signature: signature,
    );
    return verified.balance;
  }

  /// `POST /api/payment/membership/purchase-with-wallet` — buys Premium with
  /// the balance the athlete already holds.
  ///
  /// RAZORPAY IS NOT INVOLVED. This is the second of the two payment flows:
  ///     Razorpay -> Add Funds -> wallet      (createOrder + verifyPayment)
  ///     wallet   -> ₹149      -> Premium     (this)
  /// A funded wallet must never open a checkout sheet.
  ///
  /// [idempotencyKey] should be generated ONCE per button press and reused on
  /// retry, so a double-tap or a resent request charges only once. The server
  /// treats a repeat as a no-op and returns the original result.
  ///
  /// Throws [InsufficientWalletBalance] when the balance does not cover the
  /// price — a distinct type so the UI can offer Add Funds rather than a
  /// generic failure. Nothing is deducted and Premium is not activated on
  /// that path.
  Future<WalletPurchaseResult> purchasePremiumWithWallet({
    String billing = 'monthly',
    String? idempotencyKey,
  }) async {
    if (kDebugMode) debugPrint('[WALLET] premium purchase billing=$billing');
    try {
      final res = await _api.post(
        '/api/payment/membership/purchase-with-wallet',
        body: {'billing': billing, 'idempotencyKey': ?idempotencyKey},
      );
      final map = (res as Map).cast<String, dynamic>();
      final balance = (map['balance'] as num?)?.toDouble() ?? 0;
      if (kDebugMode) {
        debugPrint('[WALLET] premium purchased — balance=$balance '
            'already=${map['already']}');
      }
      return WalletPurchaseResult(
        balance: balance,
        alreadyPurchased: map['already'] == true,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 402) {
        final detail = e.body is Map ? (e.body as Map)['detail'] : null;
        final required = detail is Map ? (detail['required'] as num?) : null;
        final available = detail is Map ? (detail['available'] as num?) : null;
        if (kDebugMode) {
          debugPrint('[WALLET] insufficient — need $required have $available');
        }
        throw InsufficientWalletBalance(
          requiredPaise: required?.toInt() ?? 0,
          availablePaise: available?.toInt() ?? 0,
        );
      }
      if (kDebugMode) {
        debugPrint('[WALLET] premium purchase FAILED ${e.statusCode}: ${e.body}');
      }
      // Nothing was charged. The caller falls back to paying with Razorpay
      // directly, exactly as the website does while the Wallet is frozen.
      if (_isFrozen(e)) throw const WalletFrozenException();
      throw Exception(
        _friendlyError(e, 'Could not complete the upgrade. Please try again.'),
      );
    }
  }

  static String? _detail(ApiException e) {
    final body = e.body;
    if (body is Map && body['detail'] != null) return body['detail'].toString();
    return null;
  }

  /// `503 {"detail": {"error": "wallet_frozen", ...}}` — the backend's answer
  /// to any wallet money movement while the Wallet is frozen.
  static bool _isFrozen(ApiException e) =>
      e.statusCode == 503 && (_detail(e) ?? '').contains('wallet_frozen');

  /// An error an athlete can act on. Never a raw status line or a
  /// structured detail printed as `{error: ...}`.
  static String _friendlyError(ApiException e, String fallback) {
    if (e.isNetworkError) {
      return e.message.toLowerCase().contains('timeout')
          ? 'That took too long. Please try again.'
          : "Can't reach ZITLAS right now. Check your connection and try again.";
    }
    if (e.statusCode == 401) return 'Your session has expired. Please sign in again.';
    final detail = _detail(e);
    if (detail == 'invalid_amount') return 'Enter a valid amount to add.';
    if (detail != null && !detail.startsWith('{') && detail.length < 160) return detail;
    return fallback;
  }
}

/// The Wallet is frozen server-side; nothing was charged or credited.
class WalletFrozenException implements Exception {
  const WalletFrozenException();

  @override
  String toString() => kWalletFrozenMessage;
}

/// The backend REFUSED this payment's verification (bad signature, an order
/// that is not this athlete's, not a top-up). Retrying cannot help.
class VerificationRejected implements Exception {
  const VerificationRejected({required this.paymentId});

  final String paymentId;

  @override
  String toString() =>
      'Payment could not be verified. If money was deducted, contact support '
      'with payment ID $paymentId — it has not been lost.';
}

/// The backend could not be asked, or failed while answering. The payment
/// itself may well have succeeded, and retrying with the SAME Razorpay
/// details is safe: an order already credited answers `already: true` and is
/// never credited twice.
class VerificationUnconfirmed implements Exception {
  const VerificationUnconfirmed({required this.paymentId, this.walletFrozen = false});

  final String paymentId;

  /// The Wallet was frozen between the order and the verification.
  final bool walletFrozen;

  @override
  String toString() => walletFrozen
      ? 'Your payment went through, but the Wallet is temporarily unavailable, '
          'so it has not been added yet. It is safe — contact support with '
          'payment ID $paymentId if it does not appear.'
      : "We couldn't confirm your payment yet. Your money is safe — retry to "
          "finish adding it; you won't be charged twice. If it doesn't appear, "
          'contact support with payment ID $paymentId.';
}

/// A wallet credit the backend CONFIRMED.
@immutable
class TopUpVerification {
  const TopUpVerification({
    required this.balance,
    required this.alreadyCredited,
    this.amountRupees,
  });

  /// The SERVER's balance after the credit.
  final double balance;

  /// What was credited, as recorded on the order — not what was typed.
  final double? amountRupees;

  /// A repeat of a verification already applied; nothing was added twice.
  final bool alreadyCredited;
}

/// The wallet did not cover the price. Carries both figures so the UI can say
/// exactly how much is needed instead of a bare "insufficient balance".
class InsufficientWalletBalance implements Exception {
  const InsufficientWalletBalance({
    required this.requiredPaise,
    required this.availablePaise,
  });

  final int requiredPaise;
  final int availablePaise;

  double get requiredRupees => requiredPaise / 100.0;
  double get availableRupees => availablePaise / 100.0;

  /// How much more the athlete needs to add, never negative.
  double get shortfallRupees =>
      ((requiredPaise - availablePaise).clamp(0, requiredPaise)) / 100.0;

  @override
  String toString() =>
      'Your wallet balance is too low. Please add funds to continue.';
}

/// The outcome of a successful wallet-funded Premium purchase.
@immutable
class WalletPurchaseResult {
  const WalletPurchaseResult({
    required this.balance,
    required this.alreadyPurchased,
  });

  /// The SERVER's balance after the debit — the only balance the app shows.
  final double balance;

  /// True when the request was a repeat of one already applied (same
  /// idempotency key); nothing was charged a second time.
  final bool alreadyPurchased;
}

/// A Razorpay order as returned by `POST /api/payment/create-order`.
@immutable
class WalletOrder {
  const WalletOrder({
    required this.keyId,
    required this.orderId,
    required this.amountPaise,
    required this.currency,
  });

  final String keyId;
  final String orderId;

  /// Razorpay works in paise; the rest of ZITLAS works in rupees.
  final int amountPaise;
  final String currency;

  double get amountRupees => amountPaise / 100;

  static WalletOrder fromMap(Map<String, dynamic> map) {
    final keyId = map['key_id'] as String?;
    final orderId = map['order_id'] as String?;
    final amount = map['amount'];
    if (keyId == null || orderId == null || amount is! num) {
      throw Exception('The payment service returned an incomplete order. Please try again.');
    }
    return WalletOrder(
      keyId: keyId,
      orderId: orderId,
      amountPaise: amount.toInt(),
      currency: (map['currency'] as String?) ?? 'INR',
    );
  }
}
