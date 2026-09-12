import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/storage/local_storage_service.dart';
import 'data/razorpay_checkout.dart';
import 'data/wallet_repository.dart';
import 'presentation/screens/wallet_screen.dart' show formatIndianAmount;
import 'presentation/widgets/add_funds_sheet.dart';
import 'wallet_freeze.dart';

/// How one Add Funds attempt ended.
enum TopUpStatus {
  /// The backend CONFIRMED the credit.
  credited,

  /// The athlete closed Razorpay. Nothing was charged.
  cancelled,

  /// The order or the payment itself failed. Nothing was credited.
  failed,

  /// The Wallet is frozen server-side; no order was created.
  frozen,

  /// Razorpay took the payment but the backend refused it — a support case.
  rejected,

  /// Razorpay took the payment and the backend has not confirmed it yet.
  /// Retrying with the same details is safe.
  unconfirmed,

  /// Another Add Funds attempt is already running.
  busy,
}

@immutable
class TopUpOutcome {
  const TopUpOutcome(
    this.status, {
    this.amountRupees,
    this.balance,
    this.alreadyCredited = false,
    this.message,
    this.pending,
  });

  final TopUpStatus status;

  /// What the backend credited (from the order, not from what was typed).
  final double? amountRupees;

  /// The SERVER's balance after the credit.
  final double? balance;

  /// A repeat of a verification already applied — nothing was added twice.
  final bool alreadyCredited;

  final String? message;

  /// Set for [TopUpStatus.unconfirmed]: what a retry needs.
  final PendingTopUp? pending;

  bool get credited => status == TopUpStatus.credited;
}

/// A payment Razorpay confirmed whose credit the backend has not yet.
@immutable
class PendingTopUp {
  const PendingTopUp({
    required this.orderId,
    required this.paymentId,
    required this.signature,
    required this.amountRupees,
  });

  final String orderId, paymentId, signature;
  final double amountRupees;

  Map<String, dynamic> toJson() => {
        'orderId': orderId,
        'paymentId': paymentId,
        'signature': signature,
        'amountRupees': amountRupees,
      };

  static PendingTopUp? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final orderId = raw['orderId'], paymentId = raw['paymentId'];
    final signature = raw['signature'], amount = raw['amountRupees'];
    if (orderId is! String || paymentId is! String || signature is! String || amount is! num) {
      return null;
    }
    return PendingTopUp(
      orderId: orderId,
      paymentId: paymentId,
      signature: signature,
      amountRupees: amount.toDouble(),
    );
  }
}

/// Remembers a [PendingTopUp] across app restarts, per account.
///
/// Razorpay has already taken the money by the time the backend is asked to
/// verify. If the app is closed, killed or offline in that gap, the
/// signature exists nowhere else — and the payment would never be credited.
/// Saved before verification, cleared only on a DEFINITE answer, and
/// retried the next time the Wallet opens.
class PendingTopUpStore {
  const PendingTopUpStore();

  static String _key(String uid) => 'zitlas_pending_topup_$uid';

  PendingTopUp? load(String uid) {
    try {
      final raw = LocalStorageService.instance.getString(_key(uid));
      return raw == null ? null : PendingTopUp.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String uid, PendingTopUp pending) async {
    try {
      await LocalStorageService.instance.setString(_key(uid), jsonEncode(pending.toJson()));
    } catch (_) {}
  }

  Future<void> clear(String uid) async {
    try {
      await LocalStorageService.instance.remove(_key(uid));
    } catch (_) {}
  }
}

/// Where an Add Funds attempt currently is.
enum AddFundsPhase { idle, creatingOrder, awaitingPayment, verifying }

/// Razorpay → Add Funds → Wallet, once, for every screen that offers it.
///
///     amount → POST /api/payment/create-order → Razorpay checkout
///            → POST /api/payment/verify → the SERVER's new balance
///
/// Reuses the existing backend and the existing [RazorpayCheckout]; no key
/// is compiled into the app and nothing is credited locally. "Funds added"
/// is reported only after the backend confirms the credit.
///
/// Idempotent where it matters: a second tap while an attempt runs is
/// ignored ([TopUpStatus.busy]); Razorpay's duplicate callbacks are settled
/// once by [RazorpayCheckout]; and a retried verification is answered by the
/// backend with `already: true` rather than a second credit.
class AddFundsFlow {
  AddFundsFlow({
    required WalletRepository repository,
    RazorpayCheckout Function()? checkoutFactory,
    PendingTopUpStore store = const PendingTopUpStore(),
    // ignore: prefer_initializing_formals
  })  : _repository = repository,
        _checkoutFactory = checkoutFactory ?? RazorpayCheckout.new,
        // ignore: prefer_initializing_formals
        _store = store;

  final WalletRepository _repository;
  final RazorpayCheckout Function() _checkoutFactory;
  final PendingTopUpStore _store;

  RazorpayCheckout? _checkout;
  bool _disposeRequested = false;

  final ValueNotifier<AddFundsPhase> phase = ValueNotifier(AddFundsPhase.idle);

  bool get inProgress => phase.value != AddFundsPhase.idle;

  Future<TopUpOutcome> run({
    required String uid,
    required double amountRupees,
    String? email,
  }) async {
    if (inProgress) return const TopUpOutcome(TopUpStatus.busy);
    if (!amountRupees.isFinite || amountRupees < kMinTopUp || amountRupees > kMaxTopUp) {
      return const TopUpOutcome(
        TopUpStatus.failed,
        message: 'Enter an amount between ₹$kMinTopUp and ₹$kMaxTopUp.',
      );
    }
    phase.value = AddFundsPhase.creatingOrder;
    try {
      final WalletOrder order;
      try {
        order = await _repository.createOrder(amountRupees);
      } on WalletFrozenException {
        return const TopUpOutcome(TopUpStatus.frozen, message: kWalletFrozenMessage);
      } catch (e) {
        return TopUpOutcome(
          TopUpStatus.failed,
          message: _message(e, 'Could not start the payment. Please try again.'),
        );
      }

      phase.value = AddFundsPhase.awaitingPayment;
      final checkout = _checkout ??= _checkoutFactory();
      final result = await checkout.open(
        order: order,
        description: 'Wallet recharge',
        email: email,
      );
      switch (result.outcome) {
        case CheckoutOutcome.cancelled:
          return const TopUpOutcome(
            TopUpStatus.cancelled,
            message: 'Payment cancelled — nothing was charged.',
          );
        case CheckoutOutcome.failed:
          return TopUpOutcome(
            TopUpStatus.failed,
            message: result.message ?? 'The payment could not be completed.',
          );
        case CheckoutOutcome.success:
          break;
      }

      final pending = PendingTopUp(
        orderId: result.orderId!,
        paymentId: result.paymentId!,
        signature: result.signature!,
        amountRupees: order.amountRupees,
      );
      // Saved BEFORE asking the backend: if the app dies from here on, the
      // next time the Wallet opens it finishes the verification.
      await _store.save(uid, pending);
      return await _verify(uid, pending);
    } finally {
      phase.value = AddFundsPhase.idle;
      if (_disposeRequested) _disposeCheckout();
    }
  }

  /// Asks the backend again about a payment it has not confirmed yet.
  Future<TopUpOutcome> retryVerification(String uid, PendingTopUp pending) async {
    if (inProgress) return const TopUpOutcome(TopUpStatus.busy);
    try {
      return await _verify(uid, pending);
    } finally {
      phase.value = AddFundsPhase.idle;
    }
  }

  /// Finishes a verification left over from an earlier session, if any.
  Future<TopUpOutcome?> resumePending(String uid) async {
    final pending = _store.load(uid);
    if (pending == null) return null;
    return retryVerification(uid, pending);
  }

  Future<TopUpOutcome> _verify(String uid, PendingTopUp pending) async {
    phase.value = AddFundsPhase.verifying;
    try {
      final verified = await _repository.verifyTopUp(
        orderId: pending.orderId,
        paymentId: pending.paymentId,
        signature: pending.signature,
      );
      await _store.clear(uid);
      return TopUpOutcome(
        TopUpStatus.credited,
        amountRupees: verified.amountRupees ?? pending.amountRupees,
        balance: verified.balance,
        alreadyCredited: verified.alreadyCredited,
      );
    } on VerificationRejected catch (e) {
      await _store.clear(uid);
      return TopUpOutcome(TopUpStatus.rejected, message: e.toString());
    } on VerificationUnconfirmed catch (e) {
      return TopUpOutcome(TopUpStatus.unconfirmed, message: e.toString(), pending: pending);
    } catch (_) {
      // Whether it was credited is unknown — never claim either way. A retry
      // is safe, so keep it retryable.
      return TopUpOutcome(
        TopUpStatus.unconfirmed,
        message: VerificationUnconfirmed(paymentId: pending.paymentId).toString(),
        pending: pending,
      );
    }
  }

  /// Safe to call while an attempt is running: an open checkout must still
  /// deliver its result (and be verified), so its disposal waits for it.
  void dispose() {
    if (inProgress) {
      _disposeRequested = true;
      return;
    }
    _disposeCheckout();
  }

  void _disposeCheckout() {
    _checkout?.dispose();
    _checkout = null;
  }

  static String _message(Object e, String fallback) {
    final raw = e.toString().replaceFirst('Exception: ', '');
    if (e is! Exception || raw.isEmpty || raw.length > 200) return fallback;
    return raw;
  }
}

/// Amount sheet → [AddFundsFlow.run] → the outcome, told to the athlete.
///
/// An unconfirmed verification offers a retry with the same payment details
/// (safe — never a second credit). Returns the final outcome, or null if
/// the amount sheet was dismissed. [reportCredited] lets a caller that has
/// more to say after a credit (Premium) phrase that message itself.
Future<TopUpOutcome?> runAddFunds(
  BuildContext context, {
  required AddFundsFlow flow,
  required String uid,
  String? email,
  int? suggestedAmount,
  bool reportCredited = true,
}) async {
  final amount = await showAddFundsSheet(context, initialAmount: suggestedAmount);
  if (amount == null || !context.mounted) return null;

  var outcome = await flow.run(uid: uid, amountRupees: amount, email: email);
  var retryOffered = false;
  while (outcome.status == TopUpStatus.unconfirmed && outcome.pending != null) {
    if (!context.mounted) return outcome;
    retryOffered = true;
    final retry = await _askToRetryVerification(context, outcome.message ?? '');
    if (!retry) break;
    outcome = await flow.retryVerification(uid, outcome.pending!);
  }
  if (!context.mounted) return outcome;
  if (outcome.credited && !reportCredited) return outcome;
  if (outcome.status == TopUpStatus.unconfirmed && retryOffered) return outcome;
  await reportTopUp(context, outcome);
  return outcome;
}

/// Tells the athlete how an Add Funds attempt ended — and never says funds
/// were added unless the backend confirmed it.
Future<void> reportTopUp(BuildContext context, TopUpOutcome outcome) async {
  switch (outcome.status) {
    case TopUpStatus.busy:
      return;
    case TopUpStatus.rejected:
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Payment not verified'),
          content: Text(outcome.message ?? 'The payment could not be verified.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
          ],
        ),
      );
      return;
    case TopUpStatus.credited:
      _snack(context, _creditedMessage(outcome));
    case TopUpStatus.unconfirmed:
      _snack(context, outcome.message ?? "We couldn't confirm your payment yet.");
    case TopUpStatus.cancelled:
    case TopUpStatus.failed:
    case TopUpStatus.frozen:
      _snack(context, outcome.message ?? 'The payment could not be completed.');
  }
}

/// "₹500 added to your wallet. New balance ₹1,500." — from the SERVER's
/// figures, never a local sum.
String _creditedMessage(TopUpOutcome o) {
  final balance = o.balance == null ? '' : ' New balance ₹${formatIndianAmount(o.balance!)}.';
  if (o.alreadyCredited) return 'This payment was already added to your wallet.$balance';
  final amount = o.amountRupees == null ? 'Funds' : '₹${formatIndianAmount(o.amountRupees!)}';
  return '$amount added to your wallet.$balance';
}

Future<bool> _askToRetryVerification(BuildContext context, String message) async {
  final retry = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Payment not confirmed yet'),
      content: Text(message),
      actions: [
        TextButton(
          key: const Key('topUpRetryLater'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Later'),
        ),
        FilledButton(
          key: const Key('topUpRetryVerify'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Retry'),
        ),
      ],
    ),
  );
  return retry ?? false;
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
