import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../auth/auth_state.dart';
import '../../../profile/data/profile_repository.dart';
import '../../../profile/models/personal_info.dart';
import '../../../payments/add_funds_flow.dart';
import '../../../payments/data/razorpay_checkout.dart';
import '../../../payments/data/wallet_repository.dart';
import '../../../payments/presentation/widgets/add_funds_sheet.dart' show kMinTopUp;
import '../../../payments/presentation/widgets/insufficient_balance_card.dart';
import '../../premium_wallet_controller.dart';
import '../../data/entitlements_repository.dart';

/// Native rebuild of `frontend/pages/profile/membership/membership.html` +
/// `.js` — Membership & Billing. Plan comparison, billing toggle, and
/// pricing all match the website exactly.
///
/// PREMIUM IS PAID FROM THE ZITLAS WALLET — the same rule as the website's
/// membership.js. Razorpay puts money INTO the wallet (Add Funds); Upgrade
/// charges the wallet through `POST /api/payment/membership/purchase-with-wallet`
/// at the server's price. A short wallet shows how much is missing and offers
/// Add Funds — Razorpay is never opened automatically for Premium. Only while
/// the server reports the Wallet frozen does Upgrade fall back to the
/// Razorpay-direct flow (create a server-priced order, open Razorpay, hand the
/// signed result back for verification), so Premium stays purchasable.
///
/// This screen previously created the order and then told the athlete to go
/// to the website, because the Razorpay SDK was believed to be unintegrated.
/// It is integrated — `RazorpayCheckout` has been driving wallet top-ups all
/// along — so the flow simply ended one step early and Premium could not be
/// bought on mobile at all.
class MembershipScreen extends StatelessWidget {
  const MembershipScreen({
    super.key,
    this.profileRepository,
    this.walletRepository,
    this.addFundsFlow,
  });

  /// Injectable for tests; the real ones talk to Firestore and the backend.
  final ProfileRepository? profileRepository;
  final WalletRepository? walletRepository;
  final AddFundsFlow? addFundsFlow;

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthState>().profile?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _MembershipBody(
      uid: uid,
      repository: profileRepository ??
          ProfileRepository(firestore: FirebaseFirestore.instance, auth: FirebaseAuth.instance),
      walletRepository: walletRepository,
      addFundsFlow: addFundsFlow,
    );
  }
}

class _MembershipBody extends StatefulWidget {
  const _MembershipBody({
    required this.uid,
    required this.repository,
    this.walletRepository,
    this.addFundsFlow,
  });
  final String uid;
  final ProfileRepository repository;
  final WalletRepository? walletRepository;
  final AddFundsFlow? addFundsFlow;

  @override
  State<_MembershipBody> createState() => _MembershipBodyState();
}

class _MembershipBodyState extends State<_MembershipBody> {
  /// The plan matrix, fetched from the SAME endpoint the website reads.
  /// Seeded with the mirrored defaults so the comparison renders immediately
  /// and still renders if the request fails.
  Entitlements _ent = Entitlements.fallback;

  /// Created on first use and disposed with the screen — the Razorpay plugin
  /// keeps native event handlers alive until it is told not to.
  RazorpayCheckout? _checkout;

  /// Wallet-first Premium (see the class doc).
  late final PremiumWalletController _premium;

  /// Add Funds, shared with the Wallet screen. Owned here unless injected.
  late final AddFundsFlow _flow;
  bool _ownsFlow = false;
  bool _addingFunds = false;

  @override
  void dispose() {
    _checkout?.dispose();
    _premium.removeListener(_onPremiumChanged);
    _premium.dispose();
    if (_ownsFlow) _flow.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _premium = PremiumWalletController(
      uid: widget.uid,
      repository: widget.walletRepository ?? WalletRepository(),
    )..addListener(_onPremiumChanged);
    final injected = widget.addFundsFlow;
    if (injected != null) {
      _flow = injected;
    } else {
      _flow = AddFundsFlow(repository: _premium.repository);
      _ownsFlow = true;
    }
    EntitlementsRepository().fetch().then((e) {
      if (mounted) setState(() => _ent = e);
    });
  }

  void _onPremiumChanged() {
    if (mounted) setState(() {});
  }

  String _billing = 'monthly';
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgCard,
        elevation: 0.5,
        leading: IconButton(icon: const Icon(Icons.arrow_back, color: ZitlasTokens.textPrimary), onPressed: () => context.pop()),
        title: const Text('Membership & Billing', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
      ),
      body: SafeArea(
        child: StreamBuilder<Map<String, dynamic>?>(
          stream: widget.repository.watchUserDoc(widget.uid),
          builder: (context, snap) {
            final membership = Membership.fromMap((snap.data?['membership'] as Map?)?.cast<String, dynamic>());
            _billing = membership.billing;
            return _body(membership);
          },
        ),
      ),
    );
  }

  Widget _body(Membership membership) {
    final isPremium = membership.isPremium;
    final premiumPrice = _billing == 'yearly' ? '₹999' : '₹${_ent.premiumPriceInr}';
    final premiumPeriod = _billing == 'yearly' ? '/year' : '/month';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: ZitlasTokens.bgCard, borderRadius: BorderRadius.circular(kZitlasRadiusMd), border: Border.all(color: ZitlasTokens.borderSub)),
          child: Row(
            children: [
              Text(isPremium ? '⭐' : '🆓', style: const TextStyle(fontSize: 26)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Current Plan', style: TextStyle(fontSize: 11, color: ZitlasTokens.textMuted)),
                    Text(isPremium ? 'Premium' : 'Basic', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: ZitlasTokens.success.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                child: const Text('Active', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ZitlasTokens.success)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: ZitlasTokens.bgCardLight, borderRadius: BorderRadius.circular(14)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _billingTab('monthly', 'Monthly'),
                _billingTab('yearly', 'Yearly', chip: 'Save 44%'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _PlanCard(
          icon: '🆓',
          name: 'Basic',
          price: '₹0',
          period: '/month',
          isCurrent: !isPremium,
          description: 'Perfect for getting started with your fitness journey.',
          features: [
            '${_ent.free.goalResetLabel} Goal Set/Resets per week',
            '${_ent.free.mealSwapLabel} Meal Swaps per week',
            '${_ent.free.recipeLabel} Recipes per week',
            'Standard Zino AI access',
            'AI-generated Diet Plan',
            'AI-generated Workout Plan',
            'Expert services — FREE (₹0 platform charges)',
            'SWOT Report',
            'Step Counter',
            'Progress Tracking',
            '📢 Ads included',
          ],
          buttonLabel: isPremium ? 'Downgrade' : 'Current Plan',
          buttonEnabled: false,
          premium: false,
        ),
        const SizedBox(height: 14),
        _PlanCard(
          icon: '⭐',
          name: 'Premium',
          price: premiumPrice,
          period: premiumPeriod,
          isCurrent: isPremium,
          ribbon: 'Most Popular',
          description: 'Priority handling, higher limits, and an ad-free experience.',
          features: [
            '${_ent.premium.goalResetLabel} Goal Set/Resets per week',
            '🔥 ${_ent.premium.mealSwapLabel} Meal Swaps',
            '${_ent.premium.recipeLabel} Recipes per week',
            '⭐ Much higher Zino AI access',
            '🔥 Priority Expert Reviews — pinned at the top of the queue',
            '🔥 Priority Personal Coaching requests',
            '⭐ Priority Free Coaching Trial',
            '⭐ Priority Expert access',
            '⭐ Early access to new experts',
            'Expert services — FREE (₹0 platform charges)',
            '🚫 No Ads',
          ],
          buttonLabel: isPremium ? 'Current Plan' : (_submitting ? 'Processing…' : 'Upgrade to Premium'),
          buttonEnabled: !isPremium && !_submitting,
          premium: true,
          onButtonTap: isPremium ? null : _upgrade,
        ),
        if (!isPremium) ...[
          const SizedBox(height: 8),
          _walletLine(),
        ],
        if (!isPremium && _premium.shortfall != null) ...[
          const SizedBox(height: 12),
          InsufficientBalanceCard(
            shortfall: _premium.shortfall!,
            busy: _addingFunds,
            onAddFunds: _addFunds,
          ),
        ],
        const SizedBox(height: 20),
        _ComparisonTable(billing: _billing, ent: _ent),
        const SizedBox(height: 16),
        const Text(
          'Subscriptions renew automatically. Cancel anytime from this screen. '
          'All prices are in Indian Rupees (INR). Premium is paid from your '
          'ZITLAS Wallet; add funds securely with Razorpay.',
          style: TextStyle(fontSize: 11, color: ZitlasTokens.textMuted),
        ),
      ],
    );
  }

  Widget _billingTab(String value, String label, {String? chip}) {
    final active = _billing == value;
    return GestureDetector(
      onTap: () => setState(() => _billing = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(color: active ? ZitlasTokens.primary : null, borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: active ? Colors.white : ZitlasTokens.textSecondary)),
            if (chip != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: active ? Colors.white.withValues(alpha: 0.25) : ZitlasTokens.success.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
                child: Text(chip, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: active ? Colors.white : ZitlasTokens.success)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Upgrade: pay from the ZITLAS Wallet.
  ///
  /// Paid → Premium is active. Short → the insufficient-balance card appears
  /// with Add Funds, and Razorpay is NOT opened. Frozen (the server says so)
  /// → the Razorpay-direct fallback below, exactly as the website does.
  Future<void> _upgrade() async {
    setState(() => _submitting = true);
    try {
      final status = await _premium.purchase(_billing);
      if (!mounted) return;
      switch (status) {
        case PremiumPurchaseStatus.purchased:
          _say('Premium activated — paid from your ZITLAS Wallet.');
          final refreshed = await EntitlementsRepository().fetch();
          if (mounted) setState(() => _ent = refreshed);
        case PremiumPurchaseStatus.walletFrozen:
          await _payWithRazorpay();
        case PremiumPurchaseStatus.failed:
          _say(_premium.message ?? 'Could not complete the upgrade. Please try again.');
        case PremiumPurchaseStatus.insufficient:
        case PremiumPurchaseStatus.idle:
        case PremiumPurchaseStatus.purchasing:
          break;
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Add Funds from the insufficient-balance card, pre-filled with exactly
  /// what Premium is short by. After a CONFIRMED credit the wallet is re-read
  /// from the server; Premium is not bought automatically.
  Future<void> _addFunds() async {
    final short = _premium.shortfall;
    final email = context.read<AuthState>().profile?.email;
    final suggested =
        short == null ? null : math.max(kMinTopUp, short.shortfallRupees.ceil());
    setState(() => _addingFunds = true);
    try {
      final outcome = await runAddFunds(
        context,
        flow: _flow,
        uid: widget.uid,
        email: email,
        suggestedAmount: suggested,
        reportCredited: false,
      );
      if (outcome == null || !outcome.credited) return;
      await _premium.onFundsAdded();
      if (!mounted) return;
      _say(_premium.shortfall == null
          ? 'Funds added. Tap Upgrade to Premium to pay from your wallet.'
          : 'Funds added, but your wallet is still short — add a little more to continue.');
    } finally {
      if (mounted) setState(() => _addingFunds = false);
    }
  }

  Widget _walletLine() {
    final balance = _premium.wallet.available;
    final shown = balance == balance.roundToDouble()
        ? balance.toStringAsFixed(0)
        : balance.toStringAsFixed(2);
    return Text(
      'Paid from your ZITLAS Wallet · Balance ₹$shown',
      key: const Key('premiumWalletLine'),
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted),
    );
  }

  /// Premium page -> server-priced order -> Razorpay checkout -> server-side
  /// verification -> Premium.
  ///
  /// EVERY failure path leaves the athlete on their previous entitlement.
  /// Cancelled, failed, and a signature that does not verify all return
  /// without granting anything, because the only thing that grants Premium
  /// is the backend's own transaction after it checks the signature, the
  /// order owner and the purpose.
  Future<void> _payWithRazorpay() async {
    setState(() => _submitting = true);
    try {
      final order = await widget.repository.createMembershipOrder(_billing);
      if (!mounted) return;

      final checkout = _checkout ??= RazorpayCheckout();
      final result = await checkout.open(
        order: order,
        description: 'ZITLAS Premium ($_billing)',
      );
      if (!mounted) return;

      switch (result.outcome) {
        case CheckoutOutcome.cancelled:
          _say('Payment cancelled — nothing was charged.');
        case CheckoutOutcome.failed:
          _say(result.message ?? 'The payment could not be completed.');
        case CheckoutOutcome.success:
          await widget.repository.verifyMembershipPayment(
            orderId: result.orderId!,
            paymentId: result.paymentId!,
            signature: result.signature!,
          );
          if (!mounted) return;
          _say('Premium is active. Enjoy ZITLAS Premium!');
          // Re-read the limits from the server rather than assuming the new
          // tier — same rule as everywhere else: the server decides.
          final refreshed = await EntitlementsRepository().fetch();
          if (mounted) setState(() => _ent = refreshed);
      }
    } catch (e) {
      if (mounted) _say(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _say(String message) {
    // A newer message REPLACES an older one instead of queueing behind it —
    // "Premium activated" must not wait out the previous notice.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.icon,
    required this.name,
    required this.price,
    required this.period,
    required this.isCurrent,
    required this.description,
    required this.features,
    required this.buttonLabel,
    required this.buttonEnabled,
    required this.premium,
    this.ribbon,
    this.onButtonTap,
  });

  final String icon;
  final String name;
  final String price;
  final String period;
  final bool isCurrent;
  final String description;
  final List<String> features;
  final String buttonLabel;
  final bool buttonEnabled;
  final bool premium;
  final String? ribbon;
  final VoidCallback? onButtonTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: premium ? ZitlasTokens.primary.withValues(alpha: 0.04) : ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(kZitlasRadiusMd),
        border: Border.all(color: premium ? ZitlasTokens.primary.withValues(alpha: 0.4) : ZitlasTokens.borderSub, width: premium ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ribbon != null)
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: ZitlasTokens.primary, borderRadius: BorderRadius.circular(20)),
                child: Text(ribbon!, style: const TextStyle(fontSize: 9.5, color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: premium ? ZitlasTokens.primaryDark : ZitlasTokens.textPrimary)),
                    Row(
                      children: [
                        Text(price, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
                        Text(period, style: const TextStyle(fontSize: 12, color: ZitlasTokens.textMuted)),
                      ],
                    ),
                  ],
                ),
              ),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: ZitlasTokens.bgCardLight, borderRadius: BorderRadius.circular(20)),
                  child: const Text('Current Plan', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: ZitlasTokens.textSecondary)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(description, style: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary)),
          const SizedBox(height: 12),
          ...features.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('✅ ', style: TextStyle(fontSize: 12)),
                    Expanded(child: Text(f, style: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary))),
                  ],
                ),
              )),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: premium
                ? FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: ZitlasTokens.primary, padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    onPressed: buttonEnabled ? onButtonTap : null,
                    child: Text(buttonLabel, style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.white)),
                  )
                : OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13), side: const BorderSide(color: ZitlasTokens.borderSub)),
                    onPressed: null,
                    child: Text(buttonLabel, style: const TextStyle(fontWeight: FontWeight.w700, color: ZitlasTokens.textSecondary)),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ComparisonTable extends StatelessWidget {
  const _ComparisonTable({required this.billing, required this.ent});
  final String billing;
  final Entitlements ent;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String, String)>[
      ('Goal Set/Reset / week', ent.free.goalResetLabel, ent.premium.goalResetLabel),
      ('Meal Swaps / week', ent.free.mealSwapLabel, '🔥 ${ent.premium.mealSwapLabel}'),
      ('Get Recipe / week', ent.free.recipeLabel, ent.premium.recipeLabel),
      ('Zino AI access', 'Standard', '⭐ Much higher'),
      ('Expert Services Charges', 'FREE', 'FREE'),
      ('Expert access priority', 'Standard', '⭐ Priority'),
      ('Priority Queue Placement', '❌', '✅'),
      ('Priority Expert Reviews', 'Standard', '🔥 Priority'),
      ('Priority Personal Coaching', 'Standard', '🔥 Priority'),
      ('Free Coaching Trial priority', 'Standard', '⭐ Priority'),
      ('New expert availability', 'Standard', '⭐ Early access'),
      ('AI Diet Plan', '✅', '✅'),
      ('AI Workout Plan', '✅', '✅'),
      ('SWOT Report', '✅', '✅'),
      ('Step Counter', '✅', '✅'),
      ('Progress Tracking', '✅', '✅'),
      ('Ad-Free', '❌', '✅'),
      ('Monthly Price', 'Free', '₹${ent.premiumPriceInr}/mo'),
      ('Yearly Price', 'Free', '₹999/yr'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Full Comparison', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 36,
            dataRowMinHeight: 34,
            dataRowMaxHeight: 40,
            columns: const [
              DataColumn(label: Text('Feature', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
              DataColumn(label: Text('Basic', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
              DataColumn(label: Text('⭐ Premium', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ZitlasTokens.primaryDark))),
            ],
            rows: rows
                .map((r) => DataRow(cells: [
                      DataCell(Text(r.$1, style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textSecondary))),
                      DataCell(Text(r.$2, style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textSecondary))),
                      DataCell(Text(r.$3, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: ZitlasTokens.primaryDark))),
                    ]))
                .toList(),
          ),
        ),
      ],
    );
  }
}
