import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../data/wallet_repository.dart';

/// "Insufficient wallet balance" — what Premium shows instead of opening
/// Razorpay when the wallet does not cover the price.
///
/// States both figures the SERVER returned (required and available) and how
/// much more is needed, and offers Add Funds as an explicit choice. Nothing
/// has been charged when this is on screen.
class InsufficientBalanceCard extends StatelessWidget {
  const InsufficientBalanceCard({
    super.key,
    required this.shortfall,
    required this.onAddFunds,
    this.busy = false,
  });

  final InsufficientWalletBalance shortfall;
  final VoidCallback? onAddFunds;
  final bool busy;

  static String _inr(double v) =>
      v == v.roundToDouble() ? '₹${v.toStringAsFixed(0)}' : '₹${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('insufficientBalanceCard'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZitlasTokens.fitnessOrange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(kZitlasRadiusMd),
        border: Border.all(color: ZitlasTokens.fitnessOrange.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Text('👛', style: TextStyle(fontSize: 18)),
              SizedBox(width: 8),
              Text(
                'Insufficient wallet balance',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: ZitlasTokens.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Premium is paid from your ZITLAS Wallet. Add funds to continue — '
            'nothing has been charged.',
            style: TextStyle(fontSize: 12, height: 1.4, color: ZitlasTokens.textSecondary),
          ),
          const SizedBox(height: 12),
          _Row(label: 'Required', value: _inr(shortfall.requiredRupees)),
          _Row(label: 'Available', value: _inr(shortfall.availableRupees)),
          _Row(label: 'Add at least', value: _inr(shortfall.shortfallRupees), strong: true),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('insufficientAddFunds'),
              style: FilledButton.styleFrom(
                backgroundColor: ZitlasTokens.primary,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: busy ? null : onAddFunds,
              child: Text(
                busy ? 'Adding funds…' : 'Add Funds',
                style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.strong = false});

  final String label, value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary)),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: strong ? FontWeight.w800 : FontWeight.w700,
              color: ZitlasTokens.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
