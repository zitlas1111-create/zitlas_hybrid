import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../core/network/api_client.dart';

/// WALLET FREEZE — whether the Wallet can move money, as the SERVER says.
///
/// Read from `GET /api/system/trial-mode` (`walletFrozen`) — the same answer
/// the website's wallet panel reads through payment-service.js. This used to
/// be a compile-time `const bool kWalletFrozen = true`: the backend unfroze
/// the Wallet (`WALLET_ENABLED` in backend/launch_config.py), the website
/// followed on its next page load, and the app went on showing
/// "Add Funds (soon)" because nothing can change a const in a shipped build.
///
/// DISPLAY ONLY. The backend refuses every wallet money movement with
/// `503 wallet_frozen` while frozen, whatever any client believes, so this
/// decides what is offered and never what is allowed.
///
/// Frozen means no deposit, withdrawal, transfer or spending. It never means
/// hidden: the balance and the transaction history always render.

/// What the app shows before the server has answered, and whenever it cannot
/// be reached. The safe direction: briefly hiding Add Funds is harmless,
/// offering a recharge the server will then refuse is not.
const bool kWalletFrozenByDefault = true;

/// The copy shown wherever a wallet action would otherwise be offered.
/// Kept identical to `wallet_config.WALLET_FROZEN_MESSAGE`.
const String kWalletFrozenMessage =
    "Wallet is temporarily unavailable. It's coming in a future update — "
    'your balance and transaction history are safe.';

/// Asks the server whether the Wallet is frozen.
class WalletAvailability {
  WalletAvailability({ApiClient? api, FirebaseAuth? auth})
      : _api = api ?? ApiClient(),
        // Nullable so FirebaseAuth.instance is resolved lazily, the same
        // pattern as DietRepository.
        // ignore: prefer_initializing_formals
        _auth = auth {
    _api.authTokenProvider ??= () async {
      try {
        return await (_auth ?? FirebaseAuth.instance).currentUser?.getIdToken();
      } catch (_) {
        return null;
      }
    };
  }

  final ApiClient _api;
  final FirebaseAuth? _auth;

  /// True when the Wallet is frozen — or when that could not be found out.
  Future<bool> isFrozen() async {
    try {
      final res = await _api.get('/api/system/trial-mode');
      if (res is Map && res['walletFrozen'] is bool) {
        return res['walletFrozen'] as bool;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[WALLET] availability check failed: $e');
    }
    return kWalletFrozenByDefault;
  }
}
