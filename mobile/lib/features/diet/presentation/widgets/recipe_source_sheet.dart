import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';

/// Which recipe source the athlete picked.
enum RecipeSource { zitlas, creator }

/// "How would you like your recipe?" — the choice between ZITLAS's own
/// curated recipe and a YouTube creator's video.
///
/// Neither is pre-selected: the two are genuinely different products (one
/// has ingredients/nutrition/instructions, the other is someone else's
/// video), and defaulting to either would quietly make that choice for the
/// athlete. Returns null when dismissed.
Future<RecipeSource?> showRecipeSourceSheet(BuildContext context) {
  return showModalBottomSheet<RecipeSource>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => const _RecipeSourceSheet(),
  );
}

class _RecipeSourceSheet extends StatelessWidget {
  const _RecipeSourceSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: ZitlasTokens.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const Text(
              'How would you like your recipe?',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
            ),
            const SizedBox(height: 14),
            _SourceOption(
              icon: '🍳',
              title: 'ZITLAS Recipe',
              subtitle: 'Get the personalized ZITLAS recipe with ingredients, '
                  'nutrition and instructions.',
              accent: ZitlasTokens.primary,
              onTap: () => Navigator.of(context).pop(RecipeSource.zitlas),
            ),
            const SizedBox(height: 10),
            _SourceOption(
              icon: '🎥',
              title: 'Creator Recipe',
              subtitle: 'Watch a YouTube creator prepare it.',
              accent: ZitlasTokens.primaryDark,
              onTap: () => Navigator.of(context).pop(RecipeSource.creator),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
  });

  final String icon;
  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: ZitlasTokens.bgCardLight,
            border: Border.all(color: accent.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(icon, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: accent),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary, height: 1.35),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: ZitlasTokens.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
