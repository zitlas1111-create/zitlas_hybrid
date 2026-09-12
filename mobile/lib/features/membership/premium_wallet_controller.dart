import 'dart:async';

import 'package:flutter/foundation.dart';

import '../payments/data/wallet_repository.dart';
import '../payments/models/wallet.dart';

enum PremiumPurchaseStatus { idle, purchasing, purchased, insufficient, walletFrozen, failed }

/// Buys Premium from the ZITLAS Wallet — the wallet-first half of the
/// Membership screen, mirroring `membership.js` on the website.
///
///     wallet → ₹149 → Premium        (POST /api/payment/membership/purchase-with-wallet)
///
/// The price is the SERVER's: a short wallet comes back as 402 with the
/// required and available amounts, which is what [shortfall] carries.
/// Razorpay is never opened from here. A short wallet is answered with Add
/// Funds, and only a FROZEN wallet ([PremiumPurchaseStatus.walletFrozen])
/// sends the screen to the Razorpay-direct fallback — the same rule the
/// website follows.
class PremiumWalletController extends ChangeNotifier {
  PremiumWalletController({required this.uid, required WalletRepository repository})
      // ignore: prefer_initializing_formals
      : _repository = repository {
    _sub = _repository.watch(uid).listen(
      (value) {
        wallet = value;
        _notify();
      },
      onError: (Object e) {
        if (kDebugMode) debugPrint('[PREMIUM] wallet stream error: $e');
      },
    );
  }

  final String uid;
  final WalletRepository _repository;
  StreamSubscription<Wallet>? _sub;
  bool _disposed = false;

  /// The same repository — and so the same authenticated client — that the
  /// screen's Add Funds flow uses.
  WalletRepository get repository => _repository;

  /// The live, server-written wallet.
  Wallet wallet = Wallet.empty;

  PremiumPurchaseStatus status = PremiumPurchaseStatus.idle;

  /// Set while the wallet does not cover Premium.
  InsufficientWalletBalance? shortfall;

  /// For [PremiumPurchaseStatus.failed]: written for an athlete.
  String? message;

  Future<PremiumPurchaseStatus> purchase(String billing) async {
    if (status == PremiumPurchaseStatus.purchasing) return status;
    status = PremiumPurchaseStatus.purchasing;
    message = null;
    _notify();
    // ONE key per press, so a resent request cannot charge twice.
    final key = 'app_${uid}_${DateTime.now().microsecondsSinceEpoch}';
    try {
      await _repository.purchasePremiumWithWallet(billing: billing, idempotencyKey: key);
      shortfall = null;
      status = PremiumPurchaseStatus.purchased;
    } on InsufficientWalletBalance catch (e) {
      shortfall = e;
      status = PremiumPurchaseStatus.insufficient;
    } on WalletFrozenException {
      shortfall = null;
      status = PremiumPurchaseStatus.walletFrozen;
    } catch (e) {
      message = e.toString().replaceFirst('Exception: ', '');
      status = PremiumPurchaseStatus.failed;
    }
    _notify();
    return status;
  }

  /// After a confirmed top-up: re-read the SERVER-written wallet.
  ///
  /// Premium is deliberately NOT bought here — the athlete chose to add
  /// money, and taps Upgrade again to spend it. If the wallet now covers the
  /// price the shortfall clears; if not, it is recomputed from the new
  /// balance so the card stays accurate.
  Future<void> onFundsAdded() async {
    try {
      wallet = await _repository.fetch(uid);
    } catch (e) {
      if (kDebugMode) debugPrint('[PREMIUM] wallet refresh failed: $e');
    }
    final short = shortfall;
    if (short != null) {
      final availablePaise = (wallet.available * 100).round();
      if (availablePaise >= short.requiredPaise) {
        shortfall = null;
        status = PremiumPurchaseStatus.idle;
      } else {
        shortfall = InsufficientWalletBalance(
          requiredPaise: short.requiredPaise,
          availablePaise: availablePaise,
        );
      }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
