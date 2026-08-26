import 'package:flutter/material.dart';

import '../theme/zitlas_tokens.dart';

/// Stand-in for a feature screen not yet implemented. Every `features/*`
/// folder scaffolded in this pass uses this so the routing foundation and
/// folder structure are real and navigable, without pretending business
/// logic exists yet — see docs/MIGRATION_INVENTORY.md §6 for what's still
/// outstanding.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: PlaceholderScreenBody(subtitle: subtitle),
    );
  }
}

/// Body-only variant of [PlaceholderScreen], for embedding inside a screen
/// that already has its own `Scaffold`/`AppBar` (e.g. one with a bottom
/// action bar, like `ProfileScreen`'s sign-out button).
class PlaceholderScreenBody extends StatelessWidget {
  const PlaceholderScreenBody({super.key, this.subtitle});

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.construction, color: ZitlasTokens.textMuted, size: 40),
            const SizedBox(height: 12),
            Text(
              subtitle ?? 'Coming soon',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
