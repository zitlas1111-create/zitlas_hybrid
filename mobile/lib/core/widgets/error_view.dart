import 'package:flutter/material.dart';

import '../theme/zitlas_tokens.dart';
import '../network/api_exception.dart';

/// Standard full-space error state with a retry action, for when a screen's
/// data load fails (network error, backend 5xx, auth expiry, ...).
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  String get _message {
    final e = error;
    if (e is ApiException) {
      if (e.isNetworkError) return "Couldn't reach ZITLAS. Check your connection.";
      if (e.isUnauthorized) return 'Please sign in again.';
      return e.message;
    }
    return 'Something went wrong.';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: ZitlasTokens.textMuted, size: 40),
            const SizedBox(height: 12),
            Text(
              _message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}
