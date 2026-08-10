import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/assigned_coach.dart';
import '../dashboard_visuals.dart';
import 'section_header.dart';

/// "My Personal Coach" — shown once an expert has accepted the athlete's
/// request.
///
/// Rendered from `personal_coaching/{uid}`, which the backend writes inside
/// the accept transaction. That means it appears the moment the expert taps
/// Accept (the dashboard holds a live listener), and it is still there after a
/// logout, an app restart or a reinstall — nothing about the assignment lives
/// on the handset.
///
/// End Coaching does NOT live here — it lives on the Coach Profile screen
/// (`ActiveCoachingBanner`, opened via the Profile action below) so there is
/// exactly one End Coaching button in the app, not one per surface that
/// happens to know about the relationship.
class MyCoachCard extends StatelessWidget {
  const MyCoachCard({
    super.key,
    required this.coach,
    required this.athleteId,
  });

  final AssignedCoach coach;

  /// Needed to build the chat room id — see [_roomId].
  final String athleteId;

  @override
  Widget build(BuildContext context) {
    final days = coach.daysRemaining;

    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            emoji: '🤝',
            title: 'My Personal Coach',
            subtitle: 'Your assigned expert',
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CoachAvatar(name: coach.coachName, photo: coach.photo),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            coach.coachName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: DashboardColors.textPrimary,
                            ),
                          ),
                        ),
                        if (coach.verified) ...[
                          const SizedBox(width: 5),
                          const Icon(
                            Icons.verified_rounded,
                            size: 17,
                            color: DashboardColors.aiAccent,
                          ),
                        ],
                      ],
                    ),
                    if (coach.specialization != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        coach.specialization!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: DashboardColors.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        const _Pill(
                          label: 'ACTIVE',
                          color: DashboardColors.hydrationTeal,
                          filled: true,
                        ),
                        if (coach.planLabel != null)
                          _Pill(
                            label: coach.planLabel!,
                            color: DashboardColors.sageGreen,
                            textColor: DashboardColors.primaryDark,
                          ),
                        if (days != null)
                          _Pill(
                            label: days > 0 ? '$days days left' : 'Ends today',
                            color: DashboardColors.textSecondary,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _CoachAction(
                  icon: Icons.chat_bubble_rounded,
                  label: 'Message',
                  primary: true,
                  onTap: () => context.push(
                    '/chat/${_roomId()}'
                    '?expertId=${coach.coachId}'
                    '&expertName=${Uri.encodeComponent(coach.coachName)}',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CoachAction(
                  icon: Icons.call_rounded,
                  label: 'Call',
                  // Voice calling with a coach is Phase 7. Shown but disabled
                  // with a real explanation, rather than a button that looks
                  // live and silently does nothing.
                  onTap: () => ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      const SnackBar(
                        content: Text('Calling your coach is coming soon — message them for now.'),
                      ),
                    ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CoachAction(
                  icon: Icons.person_rounded,
                  label: 'Profile',
                  onTap: () => context.push('/experts/${coach.coachId}'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// `chat_<athleteId>_<expertId>` — the SAME deterministic id
  /// `ExpertsRepository.chatIdFor` builds, so Message opens the existing
  /// conversation with this coach rather than starting a second, empty one
  /// alongside it.
  String _roomId() => 'chat_${athleteId}_${coach.coachId}';
}

class _CoachAvatar extends StatelessWidget {
  const _CoachAvatar({required this.name, this.photo});

  final String name;
  final String? photo;

  @override
  Widget build(BuildContext context) {
    final url = photo?.trim();
    final fallback = Container(
      width: 54,
      height: 54,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: DashboardColors.primary,
        shape: BoxShape.circle,
      ),
      child: Text(
        name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
        style: const TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w900,
          color: Colors.white,
        ),
      ),
    );

    if (url == null || url.isEmpty || !url.startsWith('http')) return fallback;
    return ClipOval(
      child: Image.network(
        url,
        width: 54,
        height: 54,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) => progress == null ? child : fallback,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color, this.filled = false, this.textColor});

  final String label;
  final Color color;
  final bool filled;

  /// Overrides the text color when [color] itself is too light to read at
  /// 10px (e.g. sage) — the tint/border still use [color] so the accent
  /// stays visible, only the text swaps to something with real contrast.
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: filled ? color : color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.3,
          color: filled ? Colors.white : (textColor ?? color),
        ),
      ),
    );
  }
}

class _CoachAction extends StatelessWidget {
  const _CoachAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Colors.white : DashboardColors.textPrimary;
    return Material(
      color: primary ? DashboardColors.primary : DashboardColors.bgCardLight,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: primary ? DashboardColors.primary : DashboardColors.borderSub,
            ),
          ),
          child: Column(
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
