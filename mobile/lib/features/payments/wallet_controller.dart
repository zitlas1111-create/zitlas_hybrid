import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data/wallet_repository.dart';
import 'models/wallet.dart';

import 'wallet_freeze.dart';

/// What the Wallet screen is currently showing.
enum WalletStatus { loading, ready, error }

/// Owns the wallet's live state.
///
/// The screen never touches Firestore or the API directly, and every failure
/// path ends here as a message plus a retry — nothing throws into the widget
/// tree, which is what produced a red screen instead of a wallet.
class WalletController extends ChangeNotifier {
  WalletController({required this.uid, WalletRepository? repository})
      : _repository = repository ?? WalletRepository() {
    _subscribe();
  }

  final String uid;
  final WalletRepository _repository;

  StreamSubscription<Wallet>? _sub;

  WalletStatus status = WalletStatus.loading;
  Wallet wallet = Wallet.empty;

  /// Set only when [status] is [WalletStatus.error]. Written for an athlete to
  /// read, never a raw exception string.
  String? errorMessage;

  /// True while a top-up is in flight, so the pay button can't be double-fired.
  bool paymentInProgress = false;

  bool _disposed = false;

  void _subscribe() {
    _sub?.cancel();
    _sub = _repository.watch(uid).listen(
      (value) {
        wallet = value;
        status = WalletStatus.ready;
        errorMessage = null;
        _notify();
      },
      onError: (Object e) {
        // Reaching here means Firestore refused or the device is offline with
        // no cached copy. Both are recoverable and both get a retry.
        if (kDebugMode) debugPrint('[WALLET] stream error: $e');
        errorMessage = _friendly(e);
        status = WalletStatus.error;
        _notify();
      },
    );
  }

  /// Re-subscribes after a failure. Also used by pull-to-refresh.
  Future<void> retry() async {
    if (kDebugMode) debugPrint('[WALLET] retry requested');
    status = WalletStatus.loading;
    errorMessage = null;
    _notify();
    _subscribe();
  }

  /// Starts a real Razorpay order for [amountRupees].
  ///
  /// Returns the order for the caller to open a checkout sheet with, or null
  /// if it couldn't be created — in which case [errorMessage] explains why.
  Future<WalletOrder?> startTopUp(double amountRupees) async {
    if (paymentInProgress) return null;
    paymentInProgress = true;
    errorMessage = null;
    _notify();
    try {
      return await _repository.createOrder(amountRupees);
    } catch (e) {
      errorMessage = _friendly(e);
      return null;
    } finally {
      paymentInProgress = false;
      _notify();
    }
  }

  /// Hands a completed Razorpay payment to the backend to verify and credit.
  ///
  /// Returns the confirmed SERVER balance. The live stream delivers the new
  /// wallet a moment later on its own — nothing here adjusts the balance
  /// locally, because a client-side increment is a claim, not a fact.
  Future<double?> confirmTopUp({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    paymentInProgress = true;
    _notify();
    try {
      return await _repository.verifyPayment(
        orderId: orderId,
        paymentId: paymentId,
        signature: signature,
      );
    } catch (e) {
      errorMessage = _friendly(e);
      return null;
    } finally {
      paymentInProgress = false;
      _notify();
    }
  }

  void reportPaymentFailure(String message) {
    if (kDebugMode) debugPrint('[WALLET] payment failed: $message');
    paymentInProgress = false;
    errorMessage = message;
    _notify();
  }

  void clearError() {
    if (errorMessage == null) return;
    errorMessage = null;
    _notify();
  }

  /// Turns anything thrown into something an athlete can act on.
  static String _friendly(Object e) {
    final raw = e.toString().replaceFirst('Exception: ', '');
    final lower = raw.toLowerCase();
    // The server refuses every wallet money movement while the Wallet is
    // frozen. That is a real, specific answer — showing "can't reach ZITLAS"
    // (which `unavailable` below would otherwise match) would be a lie.
    if (lower.contains('wallet_frozen')) return kWalletFrozenMessage;
    if (lower.contains('permission-denied') || lower.contains('permission denied')) {
      return "You don't have access to this wallet. Try signing out and back in.";
    }
    if (lower.contains('unavailable') ||
        lower.contains('socket') ||
        lower.contains('failed host lookup') ||
        lower.contains('network')) {
      return "Can't reach ZITLAS right now. Check your connection and try again.";
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return 'That took too long. Please try again.';
    }
    // Messages raised by WalletRepository are already athlete-facing, and they
    // are always Exceptions. An ERROR is a programming fault — its text is a
    // stack-trace fragment ("Bad state: ...", "type 'X' is not a subtype...")
    // and must never be shown to an athlete, however short it happens to be.
    if (e is Exception && raw.isNotEmpty && raw.length < 200) return raw;
    return 'Something went wrong loading your wallet. Please try again.';
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
