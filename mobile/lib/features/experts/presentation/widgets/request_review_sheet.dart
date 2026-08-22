import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../expert_profile_controller.dart';
import '../../../payments/launch_config.dart';

/// `#vpSheet` / `initVerifyPlanBtn()` (cprofile.js:2677-3195) — service type
/// (verification / chat / verification+chat) → review type (diet / workout
/// / both) → live total price → submit. The lifecycle guard (one active
/// review per athlete↔expert) is enforced in the controller before this
/// sheet is even reachable via the "Request Review" button; "Request
/// Another Review" re-opens the same sheet once terminal.
Future<void> showRequestReviewSheet(BuildContext context, {required ExpertProfileController controller}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RequestReviewSheet(controller: controller),
  );
}

class _RequestReviewSheet extends StatefulWidget {
  const _RequestReviewSheet({required this.controller});
  final ExpertProfileController controller;

  @override
  State<_RequestReviewSheet> createState() => _RequestReviewSheetState();
}

class _RequestReviewSheetState extends State<_RequestReviewSheet> {
  String? _service; // 'verification' | 'chat' | 'verification_chat'
  String? _reviewType; // 'diet' | 'workout' | 'both'
  bool _submitting = false;

  bool get _needsReviewType => _service == 'verification' || _service == 'verification_chat';

  num get _total {
    final e = widget.controller.expert!;
    num total = 0;
    if (_needsReviewType) {
      total += switch (_reviewType) {
        'diet' => e.pricing.dietReviewPrice,
        'workout' => e.pricing.workoutReviewPrice,
        'both' => e.pricing.bothReviewPrice,
        _ => 0,
      };
    }
    if (_service == 'chat' || _service == 'verification_chat') total += e.pricing.chatPrice;
    // Expert services are FREE at launch (backend/launch_config.py); the
    // server prices them at ₹0 and refuses any non-zero charge. The expert's
    // own pricing is kept and still drives this sum, so the day services are
    // paid again nothing here has to be rewritten.
    if (!kExpertServicesPaymentRequired) return 0;
    return total;
  }

  bool get _ready => _service != null && (!_needsReviewType || _reviewType != null);

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final hasDiet = c.hasDietPlan;
    final hasWorkout = c.hasWorkoutPlan;

    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      decoration: const BoxDecoration(color: ZitlasTokens.bgCard, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: ZitlasTokens.borderSub, borderRadius: BorderRadius.circular(4)))),
            const SizedBox(height: 16),
            const Text('Request Expert Review', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
            const SizedBox(height: 4),
            const Text('Choose what you need from this expert.', style: TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary)),
            const SizedBox(height: 16),
            _optionTile(
              'verification',
              'Verification Only',
              kExpertServicesPaymentRequired
                  ? 'Expert reviews your plan · from ₹${c.expert!.pricing.dietReviewPrice < c.expert!.pricing.workoutReviewPrice ? c.expert!.pricing.dietReviewPrice : c.expert!.pricing.workoutReviewPrice}'
                  : 'Expert reviews your plan · $kFreeLabel',
            ),
            _optionTile(
              'chat',
              'Chat Only',
              kExpertServicesPaymentRequired
                  ? 'Unlimited chat until the expert closes it · ₹${c.expert!.pricing.chatPrice}'
                  : 'Unlimited chat until the expert closes it · $kFreeLabel',
            ),
            _optionTile('verification_chat', 'Verification + Chat', 'Review, then unlimited chat'),
            if (_needsReviewType) ...[
              const SizedBox(height: 14),
              const Text('Review type', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
              const SizedBox(height: 8),
              _typeTile('diet', 'Diet Plan', hasDiet, 'No diet plan found. Generate your AI diet plan first.'),
              _typeTile('workout', 'Workout Plan', hasWorkout, 'No workout plan found. Generate your AI training plan first.'),
              _typeTile('both', 'Diet + Workout', hasDiet && hasWorkout, 'Both plans are required for a bundled review.'),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Total', style: TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary)),
                Text(
                  launchPriceLabel(_ready ? _total : 0,
                      paymentRequired: kExpertServicesPaymentRequired),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: ZitlasTokens.primaryDark),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: ZitlasTokens.primary, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: (_ready && !_submitting) ? _submit : null,
                child: _submitting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Send Request →', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _optionTile(String value, String title, String subtitle) {
    final selected = _service == value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? ZitlasTokens.primary.withValues(alpha: 0.1) : ZitlasTokens.bgCardLight,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() {
            _service = value;
            if (!_needsReviewType) _reviewType = null;
          }),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: selected ? ZitlasTokens.primary : ZitlasTokens.borderSub)),
            child: Row(
              children: [
                Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18, color: selected ? ZitlasTokens.primary : ZitlasTokens.textMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
                      Text(subtitle, style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _typeTile(String value, String title, bool available, String unavailableMsg) {
    final selected = _reviewType == value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: available ? 1 : 0.5,
        child: Material(
          color: ZitlasTokens.bgCardLight,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              if (!available) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(unavailableMsg)));
                return;
              }
              setState(() => _reviewType = value);
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: selected ? ZitlasTokens.primary : ZitlasTokens.borderSub)),
              child: Row(
                children: [
                  Icon(selected ? Icons.check_circle : Icons.circle_outlined, size: 16, color: selected ? ZitlasTokens.primary : ZitlasTokens.textMuted),
                  const SizedBox(width: 10),
                  Text(title, style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textPrimary)),
                  if (!available) const Spacer(),
                  if (!available) const Text('Unavailable', style: TextStyle(fontSize: 10, color: ZitlasTokens.textMuted)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final ok = await widget.controller.submitReviewRequest(
      reviewType: _reviewType ?? 'diet',
      serviceType: _service!,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Your request has been sent.')));
    } else {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not send request — please try again.')));
    }
  }
}
