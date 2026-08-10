import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../models/diet_review_request.dart';

/// The accept-banner shown when an expert has completed a review the
/// athlete hasn't applied yet (`showExpertReviewBanner()` on the website) —
/// an expandable "what changed" summary built from `mealChangeHistory`,
/// plus the accept action.
class DietExpertReviewBanner extends StatefulWidget {
  const DietExpertReviewBanner({
    super.key,
    required this.review,
    required this.onAccept,
  });

  final DietReviewRequest review;
  final Future<void> Function() onAccept;

  @override
  State<DietExpertReviewBanner> createState() => _DietExpertReviewBannerState();
}

class _DietExpertReviewBannerState extends State<DietExpertReviewBanner> {
  bool _expanded = false;
  bool _accepting = false;

  Future<void> _accept() async {
    setState(() => _accepting = true);
    try {
      await widget.onAccept();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Expert changes applied to your plan.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not apply changes: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final review = widget.review;
    final history = review.mealChangeHistory;

    return ZitlasCard(
      margin: const EdgeInsets.only(bottom: 16),
      color: const Color(0xE6FFF7E8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('✅ ', style: TextStyle(fontSize: 16)),
              Expanded(
                child: Text(
                  '${review.expertName ?? 'Your expert'} reviewed your diet plan',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
                ),
              ),
            ],
          ),
          if (review.expertNotes != null) ...[
            const SizedBox(height: 6),
            Text(
              review.expertNotes!,
              style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary, height: 1.4),
            ),
          ],
          if (history.isNotEmpty) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Text(
                    _expanded ? 'Hide what changed' : 'See what changed (${history.length})',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ZitlasTokens.primaryDark),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: ZitlasTokens.primaryDark,
                  ),
                ],
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  children: history
                      .map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${entry.dayLabel ?? 'Day ${entry.dayIndex + 1}'} — ${entry.mealName}',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary),
                              ),
                              if (entry.newFoods.isNotEmpty)
                                Text(
                                  'Now: ${entry.newFoods.join(', ')}',
                                  style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textSecondary),
                                ),
                              if (entry.reason != null)
                                Text(
                                  entry.reason!,
                                  style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted, fontStyle: FontStyle.italic),
                                ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _accepting ? null : _accept,
              style: ElevatedButton.styleFrom(
                backgroundColor: ZitlasTokens.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _accepting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Apply Expert Changes', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}
