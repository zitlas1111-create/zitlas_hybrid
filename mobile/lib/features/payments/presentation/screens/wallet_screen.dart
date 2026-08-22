import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../features/auth/auth_state.dart';
import '../../../dashboard/presentation/dashboard_visuals.dart';
import '../../data/razorpay_checkout.dart';
import '../../models/wallet.dart';
import '../../wallet_controller.dart';
import '../../wallet_freeze.dart';
import '../widgets/add_funds_sheet.dart';
import '../widgets/wallet_transaction_row.dart';
import 'transaction_history_screen.dart';

/// Native rebuild of `frontend/components/wallet.js` — the real ZITLAS Wallet.
///
/// Replaces the Phase-1 placeholder that shipped in its place, which is why
/// tapping the balance chip on the Dashboard opened an empty page.
///
/// Same information architecture as the web panel: available balance (with any
/// reservation called out separately), quick actions, usage stats, recent
/// transactions, and a full history. Money is never written from here — see
/// [WalletRepository] for why.
class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key, this.controller});

  /// Injectable for tests.
  final WalletController? controller;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final uid = auth.profile?.uid;
    if (uid == null) {
      // The router only lands an authenticated athlete here; this guards the
      // moment between sign-out and the redirect rather than crashing.
      return const Scaffold(
        backgroundColor: DashboardColors.bgStart,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    // An injected controller belongs to its caller, so `.value` is used and
    // the provider must not dispose it. Only a controller this screen created
    // is one this screen may tear down.
    final injected = controller;
    if (injected != null) {
      return ChangeNotifierProvider<WalletController>.value(
        value: injected,
        child: const _WalletBody(),
      );
    }
    return ChangeNotifierProvider<WalletController>(
      key: ValueKey(uid),
      create: (_) => WalletController(uid: uid),
      child: const _WalletBody(),
    );
  }
}

class _WalletBody extends StatefulWidget {
  const _WalletBody();

  @override
  State<_WalletBody> createState() => _WalletBodyState();
}

class _WalletBodyState extends State<_WalletBody> {
  RazorpayCheckout? _checkout;

  @override
  void dispose() {
    _checkout?.dispose();
    super.dispose();
  }

  /// Amount sheet → real Razorpay order → native checkout → backend verify.
  ///
  /// Every step can fail independently and each one reports for itself; none of
  /// them credits anything locally. The balance on screen only ever changes
  /// because the live Firestore stream delivered a new server-written wallet.
  Future<void> _addFunds() async {
    // Unreachable while frozen — the button is disabled below — but a second
    // gate here means no future caller can open a recharge that the server
    // will only refuse.
    if (kWalletFrozen) {
      _showMessage(kWalletFrozenMessage);
      return;
    }
    final controller = context.read<WalletController>();
    final amount = await showAddFundsSheet(context);
    if (amount == null || !mounted) return;

    final order = await controller.startTopUp(amount);
    if (!mounted) return;
    if (order == null) {
      _showMessage(controller.errorMessage ?? 'Could not start the payment.');
      return;
    }

    final auth = context.read<AuthState>().profile;
    final checkout = _checkout ??= RazorpayCheckout();
    final result = await checkout.open(
      order: order,
      description: 'Wallet recharge',
      email: auth?.email,
    );
    if (!mounted) return;

    switch (result.outcome) {
      case CheckoutOutcome.cancelled:
        _showMessage('Payment cancelled — nothing was charged.');
      case CheckoutOutcome.failed:
        _showMessage(result.message ?? 'The payment could not be completed.');
      case CheckoutOutcome.success:
        final balance = await controller.confirmTopUp(
          orderId: result.orderId!,
          paymentId: result.paymentId!,
          signature: result.signature!,
        );
        if (!mounted) return;
        if (balance == null) {
          _showMessage(controller.errorMessage ?? 'Payment could not be verified.');
        } else {
          _showMessage('₹${_thousands(amount.round())} added to your wallet.');
        }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    context.read<WalletController>().clearError();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<WalletController>();

    return Scaffold(
      backgroundColor: DashboardColors.bgStart,
      appBar: AppBar(
        backgroundColor: DashboardColors.bgCard,
        elevation: 0,
        title: const Text(
          'Wallet',
          style: TextStyle(
            color: DashboardColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        iconTheme: const IconThemeData(color: DashboardColors.textPrimary),
      ),
      body: switch (controller.status) {
        WalletStatus.loading => const _LoadingState(),
        WalletStatus.error => _ErrorState(
            message: controller.errorMessage ?? 'Something went wrong.',
            onRetry: controller.retry,
          ),
        WalletStatus.ready => RefreshIndicator(
            color: DashboardColors.primary,
            onRefresh: controller.retry,
            child: _WalletContent(
              wallet: controller.wallet,
              busy: controller.paymentInProgress,
              onAddFunds: _addFunds,
            ),
          ),
      },
    );
  }
}

/// "Wallet coming soon" — shown in place of the actions, never in place of
/// the balance or the history.
class _WalletFrozenNotice extends StatelessWidget {
  const _WalletFrozenNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF28C28).withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF28C28).withValues(alpha: 0.28)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('🔒', style: TextStyle(fontSize: 17)),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Wallet coming soon',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: DashboardColors.textPrimary,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  kWalletFrozenMessage,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: DashboardColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: DashboardColors.primary),
          SizedBox(height: 14),
          Text(
            'Loading your wallet…',
            style: TextStyle(fontSize: 13, color: DashboardColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// A failure the athlete can act on, with the retry the task asks for.
///
/// Scrollable so it still works inside a RefreshIndicator and on a short
/// screen — an error state that can't be scrolled to reach its own button is
/// worse than no error state.
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('💳', style: TextStyle(fontSize: 34)),
            const SizedBox(height: 12),
            const Text(
              "Couldn't load your wallet",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: DashboardColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: DashboardColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your balance is safe — this only affects loading it here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: DashboardColors.textMuted),
            ),
            const SizedBox(height: 18),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: DashboardColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Try again', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
    );
  }
}

class _WalletContent extends StatelessWidget {
  const _WalletContent({
    required this.wallet,
    required this.busy,
    required this.onAddFunds,
  });

  final Wallet wallet;
  final bool busy;
  final Future<void> Function() onAddFunds;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _BalanceCard(wallet: wallet),
        // The state is stated before any action is offered.
        if (kWalletFrozen) ...[
          const SizedBox(height: 14),
          const _WalletFrozenNotice(),
        ],
        const SizedBox(height: 18),
        const _SectionTitle('Quick Actions'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _QuickAction(
                icon: '💳',
                // A disabled action must LOOK disabled: `_QuickAction`
                // greys itself out on a null onTap, so this is never a
                // live-looking button that fails on tap.
                label: kWalletFrozen
                    ? 'Add Funds (soon)'
                    : (busy ? 'Starting…' : 'Add Funds'),
                onTap: (kWalletFrozen || busy) ? null : onAddFunds,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _QuickAction(
                icon: '📋',
                label: 'History',
                onTap: wallet.hasTransactions
                    ? () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TransactionHistoryScreen(
                              transactions: wallet.transactions,
                            ),
                          ),
                        )
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const _SectionTitle('Wallet Usage'),
        const SizedBox(height: 8),
        _UsageStats(wallet: wallet),
        const SizedBox(height: 20),
        _RecentTransactions(wallet: wallet),
      ],
    );
  }
}

/// The headline figure is AVAILABLE, not raw balance.
///
/// `balance` can include money locked by an open coaching reservation, and
/// showing that as spendable is how an athlete ends up at a checkout that
/// declines them.
class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.wallet});

  final Wallet wallet;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [DashboardColors.primary, DashboardColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          const Text(
            'Available Balance',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white70,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '₹${_thousands(wallet.available.round())}',
            style: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            wallet.reserved > 0
                ? '🔒 ₹${_thousands(wallet.reserved.round())} reserved for a pending coaching request'
                : 'ZITLAS Wallet · Secure & Instant',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11.5, color: Colors.white70, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _UsageStats extends StatelessWidget {
  const _UsageStats({required this.wallet});

  final Wallet wallet;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: 'Added',
            value: '₹${_thousands(wallet.totalAdded.round())}',
            color: DashboardColors.success,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            label: 'Spent',
            value: '₹${_thousands(wallet.totalSpent.round())}',
            color: DashboardColors.error,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          // Reserved replaces Balance only while something IS reserved —
          // otherwise it's a permanent ₹0 tile telling the athlete nothing.
          child: wallet.reserved > 0
              ? _StatCard(
                  label: 'Reserved',
                  value: '₹${_thousands(wallet.reserved.round())}',
                  color: DashboardColors.primary,
                )
              : _StatCard(
                  label: 'Balance',
                  value: '₹${_thousands(wallet.balance.round())}',
                  color: DashboardColors.primary,
                ),
        ),
      ],
    );
  }
}

class _RecentTransactions extends StatelessWidget {
  const _RecentTransactions({required this.wallet});

  final Wallet wallet;

  @override
  Widget build(BuildContext context) {
    final recent = wallet.transactions.take(3).toList();

    return Container(
      decoration: BoxDecoration(
        color: DashboardColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DashboardColors.borderSub),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    recent.isEmpty
                        ? 'Recent Transactions'
                        : 'Last ${recent.length} transaction${recent.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: DashboardColors.textPrimary,
                    ),
                  ),
                ),
                if (wallet.transactions.length > recent.length)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TransactionHistoryScreen(
                          transactions: wallet.transactions,
                        ),
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: DashboardColors.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'See all →',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                    ),
                  ),
              ],
            ),
          ),
          if (recent.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 22),
              child: Column(
                children: [
                  Text('📋', style: TextStyle(fontSize: 26)),
                  SizedBox(height: 8),
                  Text(
                    'No transactions yet',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: DashboardColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Add funds to get started.',
                    style: TextStyle(fontSize: 12, color: DashboardColors.textSecondary),
                  ),
                ],
              ),
            )
          else
            for (final txn in recent) WalletTransactionRow(transaction: txn),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.7,
        color: DashboardColors.textMuted,
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, this.onTap});

  final String icon;
  final String label;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: DashboardColors.bgCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: enabled ? () => onTap!() : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: DashboardColors.borderSub),
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Column(
              children: [
                Text(icon, style: const TextStyle(fontSize: 20)),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: DashboardColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.color});

  final String label, value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: DashboardColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DashboardColors.borderSub),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 10.5, color: DashboardColors.textSecondary),
          ),
          const SizedBox(height: 4),
          FittedBox(
            child: Text(
              value,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

String _thousands(int n) {
  // Indian grouping (1,00,000) — the same shape the website's
  // toLocaleString('en-IN') produces, so a balance reads identically on both.
  // Last three digits, then two at a time.
  final negative = n < 0;
  final digits = n.abs().toString();
  if (digits.length <= 3) return negative ? '-$digits' : digits;

  final last3 = digits.substring(digits.length - 3);
  var head = digits.substring(0, digits.length - 3);
  final groups = <String>[];
  while (head.length > 2) {
    groups.insert(0, head.substring(head.length - 2));
    head = head.substring(0, head.length - 2);
  }
  if (head.isNotEmpty) groups.insert(0, head);
  final out = '${groups.join(',')},$last3';
  return negative ? '-$out' : out;
}

/// Exposed so the row/history widgets and tests share one formatter.
String formatIndianAmount(num value) => _thousands(value.round());

/// Copies a transaction id to the clipboard — used from the history screen's
/// long-press, so an athlete can quote it to support.
Future<void> copyToClipboard(String value) =>
    Clipboard.setData(ClipboardData(text: value));
