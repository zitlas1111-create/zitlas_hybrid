import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';

/// `.ed-section-label` — the small uppercase-ish heading above each block.
class EdSectionLabel extends StatelessWidget {
  const EdSectionLabel(this.text, {super.key, this.padding});

  final String text;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Text(
        text,
        style: const TextStyle(
          color: ZitlasTokens.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// `.ed-empty-state` — icon + title + subtitle, used by every list section.
class EdEmptyState extends StatelessWidget {
  const EdEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final String icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 20),
      child: Column(
        children: [
          Text(icon, style: const TextStyle(fontSize: 34)),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ZitlasTokens.textPrimary,
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ZitlasTokens.textMuted,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when a Firestore listener fails (missing index, rules, offline).
/// Scoped to one section so the rest of the dashboard keeps working.
class EdErrorState extends StatelessWidget {
  const EdErrorState({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      child: Column(
        children: [
          const Icon(Icons.cloud_off_rounded, color: ZitlasTokens.textMuted, size: 30),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ZitlasTokens.textSecondary,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    );
  }
}

/// Section-level loading state — a plain centered spinner, so a slow
/// collection never shows fabricated placeholder numbers.
class EdLoading extends StatelessWidget {
  const EdLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.6, color: ZitlasTokens.primary),
        ),
      ),
    );
  }
}

/// `.pr-inbox-tabs` — the pill tab strip used by Reviews and Coaching,
/// with optional count badges.
class EdTabStrip extends StatelessWidget {
  const EdTabStrip({
    super.key,
    required this.labels,
    required this.badges,
    required this.activeIndex,
    required this.onChanged,
  });

  final List<String> labels;

  /// Same length as [labels]; a value <= 0 hides that tab's badge.
  final List<int> badges;
  final int activeIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ZitlasTokens.border),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                  decoration: BoxDecoration(
                    color: i == activeIndex ? ZitlasTokens.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          labels[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: i == activeIndex ? Colors.white : ZitlasTokens.textSecondary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (badges[i] > 0) ...[
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: i == activeIndex ? Colors.white : ZitlasTokens.primary,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${badges[i]}',
                            style: TextStyle(
                              color: i == activeIndex ? ZitlasTokens.primary : Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Circular initials avatar used on every card (athlete/expert).
class EdAvatar extends StatelessWidget {
  const EdAvatar({super.key, required this.name, this.size = 42, this.photoUrl});

  final String name;
  final double size;
  final String? photoUrl;

  static String initialsOf(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '--';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final url = photoUrl;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ZitlasTokens.bgCardLight,
        border: Border.all(color: ZitlasTokens.border),
        image: url != null && url.startsWith('http')
            ? DecorationImage(image: NetworkImage(url), fit: BoxFit.cover)
            : null,
      ),
      child: url != null && url.startsWith('http')
          ? null
          : Text(
              initialsOf(name),
              style: TextStyle(
                color: ZitlasTokens.primary,
                fontSize: size * 0.34,
                fontWeight: FontWeight.w800,
              ),
            ),
    );
  }
}

/// Small filled/outlined action button used on inbox + coaching cards.
class EdActionButton extends StatelessWidget {
  const EdActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.filled = true,
    this.danger = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final bool danger;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final accent = danger ? ZitlasTokens.danger : ZitlasTokens.primary;
    return SizedBox(
      height: 38,
      child: filled
          ? ElevatedButton(
              onPressed: busy ? null : onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: accent.withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              child: busy ? _spinner(Colors.white) : Text(label),
            )
          : OutlinedButton(
              onPressed: busy ? null : onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: accent,
                side: BorderSide(color: accent.withValues(alpha: 0.55)),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              child: busy ? _spinner(accent) : Text(label),
            ),
    );
  }

  Widget _spinner(Color color) => SizedBox(
        width: 15,
        height: 15,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );
}

/// A read-only status "stamp" (e.g. "✅ Review Sent to User") shown in
/// place of buttons on terminal card states.
class EdStamp extends StatelessWidget {
  const EdStamp(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? ZitlasTokens.textSecondary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withValues(alpha: 0.22)),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Maps a Firestore listener failure to something the expert can act on.
/// A `permission-denied` here is almost always a security-rule/query
/// mismatch rather than anything the user did, so it must not masquerade as
/// a connectivity problem.
String edErrorMessage(Object? error, {required String what}) {
  final text = error?.toString() ?? '';
  if (text.contains('permission-denied') || text.contains('PERMISSION_DENIED')) {
    return "Your account doesn't currently have permission to read $what. "
        'This is a server configuration issue — please contact ZITLAS support.';
  }
  if (text.contains('failed-precondition') || text.contains('requires an index')) {
    return 'This list needs a database index that hasn\'t been created yet. '
        'Please contact ZITLAS support.';
  }
  return "Couldn't load $what. Check your connection and try again.";
}

/// "just now / N min ago / N hr ago / N days ago" — `_prTimeAgo` (ED:4993).
String edTimeAgo(DateTime? then) {
  if (then == null) return '';
  final diff = DateTime.now().difference(then);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  return '${diff.inDays} days ago';
}
