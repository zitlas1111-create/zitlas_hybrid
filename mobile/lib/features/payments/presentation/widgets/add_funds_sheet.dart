import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../dashboard/presentation/dashboard_visuals.dart';

/// Preset amounts, identical to `renderAddFundsStep1()` on the website.
const kQuickAmounts = <int>[100, 250, 500, 1000, 2000];

/// Razorpay's own limits for a single wallet top-up, mirrored from the web
/// panel's `min="1" max="50000"`.
const kMinTopUp = 1;
const kMaxTopUp = 50000;

/// Asks how much to add. Returns the amount in rupees, or null if dismissed.
///
/// Method selection (UPI / card / net banking) is deliberately NOT here —
/// Razorpay's own sheet shows the real, live options, and a second cosmetic
/// picker in front of it would just be a lie about what's being chosen. The
/// website removed exactly this for the same reason.
///
/// [initialAmount] pre-fills the amount — for example exactly what Premium
/// is short by — and the athlete can still change it.
Future<double?> showAddFundsSheet(BuildContext context, {int? initialAmount}) {
  return showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AddFundsSheet(initialAmount: initialAmount),
  );
}

class _AddFundsSheet extends StatefulWidget {
  const _AddFundsSheet({this.initialAmount});

  final int? initialAmount;

  @override
  State<_AddFundsSheet> createState() => _AddFundsSheetState();
}

class _AddFundsSheetState extends State<_AddFundsSheet> {
  final _custom = TextEditingController();
  int? _selectedPreset;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialAmount;
    if (initial != null) {
      _custom.text = initial.clamp(kMinTopUp, kMaxTopUp).toString();
    }
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  /// The amount currently chosen, from whichever input was used last.
  int? get _amount {
    final typed = int.tryParse(_custom.text.trim());
    if (typed != null) return typed;
    return _selectedPreset;
  }

  bool get _isValid {
    final a = _amount;
    return a != null && a >= kMinTopUp && a <= kMaxTopUp;
  }

  void _pick(int amount) {
    setState(() {
      _selectedPreset = amount;
      _custom.clear();
      _error = null;
    });
  }

  void _submit() {
    final a = _amount;
    // Validated here rather than only by disabling the button, so a typed
    // out-of-range amount gets an explanation instead of a dead control.
    if (a == null || a < kMinTopUp) {
      setState(() => _error = 'Enter an amount of at least ₹$kMinTopUp.');
      return;
    }
    if (a > kMaxTopUp) {
      setState(() => _error = 'The most you can add at once is ₹$kMaxTopUp.');
      return;
    }
    Navigator.of(context).pop(a.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Lifts the sheet above the keyboard so the custom-amount field and the
      // Continue button stay visible while typing.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: DashboardColors.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: DashboardColors.borderSub,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Add Funds',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: DashboardColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Choose an amount, or enter your own.',
              style: TextStyle(fontSize: 12.5, color: DashboardColors.textSecondary),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final amount in kQuickAmounts)
                  _AmountChip(
                    amount: amount,
                    selected: _selectedPreset == amount && _custom.text.isEmpty,
                    onTap: () => _pick(amount),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _custom,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {
                _selectedPreset = null;
                _error = null;
              }),
              decoration: InputDecoration(
                prefixText: '₹ ',
                hintText: 'Custom amount',
                filled: true,
                fillColor: DashboardColors.bgCardLight,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: DashboardColors.borderSub),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: DashboardColors.borderSub),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: DashboardColors.primary),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: DashboardColors.error),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isValid ? _submit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: DashboardColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: DashboardColors.borderSub,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  _isValid ? 'Continue to Payment · ₹${_amount!}' : 'Continue to Payment',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'UPI, card or net banking — secured by Razorpay.',
                style: TextStyle(fontSize: 11, color: DashboardColors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AmountChip extends StatelessWidget {
  const _AmountChip({required this.amount, required this.selected, required this.onTap});

  final int amount;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? DashboardColors.primary : DashboardColors.bgCardLight,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? DashboardColors.primary : DashboardColors.borderSub,
            ),
          ),
          child: Text(
            '₹$amount',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: selected ? Colors.white : DashboardColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
