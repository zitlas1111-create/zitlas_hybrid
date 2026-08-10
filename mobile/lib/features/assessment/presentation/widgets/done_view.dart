import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';

/// `#s-done` — exact copy.
class DoneView extends StatelessWidget {
  const DoneView({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100,
              height: 100,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: ZitlasTokens.achievementYellow, width: 3),
              ),
              child: ClipOval(child: Image.asset('assets/images/zino.png', fit: BoxFit.cover)),
            ),
            const SizedBox(height: 14),
            const Text('✓', style: TextStyle(fontSize: 36, color: ZitlasTokens.achievementYellow, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Your plan is '),
                  TextSpan(text: 'saved!', style: TextStyle(color: ZitlasTokens.achievementYellow)),
                ],
              ),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: ZitlasTokens.textPrimary),
            ),
            const SizedBox(height: 8),
            const Text(
              'Zino has everything ready. Head to your dashboard to start today.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: ZitlasTokens.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onDone,
                style: ElevatedButton.styleFrom(
                  backgroundColor: ZitlasTokens.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text('Go to Dashboard →', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
