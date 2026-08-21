import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../../core/presence/presence_dot.dart';
import '../../../../core/theme/zitlas_tokens.dart';
import '../../expert_dashboard_controller.dart';
import '../../models/expert_models.dart';
import '../widgets/expert_common.dart';

/// `#sectionDashboard` — expert profile card, 4-stat grid, quick actions,
/// and the live "My Users" list.
class ExpertDashboardSection extends StatelessWidget {
  const ExpertDashboardSection({
    super.key,
    required this.onOpenReviews,
    required this.onOpenChats,
    required this.onOpenAthlete,
  });

  final VoidCallback onOpenReviews;
  final VoidCallback onOpenChats;
  final void Function(CoachingRelationship) onOpenAthlete;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ExpertDashboardController>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        _ProfileCard(profile: c.profile, loading: c.profileLoading),
        const SizedBox(height: 16),
        _StatsGrid(controller: c),
        const SizedBox(height: 20),
        const EdSectionLabel('Quick Actions'),
        Row(
          children: [
            Expanded(
              child: _QuickButton(icon: '📋', label: 'Review Requests', onTap: onOpenReviews),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickButton(icon: '💬', label: 'Client Chats', onTap: onOpenChats),
            ),
          ],
        ),
        const SizedBox(height: 22),
        const EdSectionLabel('My Users'),
        ZitlasCard(
          padding: EdgeInsets.zero,
          child: c.myAthletes.isEmpty
              ? const EdEmptyState(
                  icon: '👨‍🏫',
                  title: 'No coaching clients yet',
                  subtitle:
                      'Users who purchase Personal Coaching with you will appear here.',
                )
              : Column(
                  children: [
                    for (var i = 0; i < c.myAthletes.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, color: ZitlasTokens.borderSub, indent: 16),
                      _AthleteTile(
                        rel: c.myAthletes[i],
                        onOpen: () => onOpenAthlete(c.myAthletes[i]),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// `.ed-profile-card` (#epcName / #epcRole / #epcRating / #epcReviews /
/// #epcFee / #epcExp).
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile, required this.loading});

  final ExpertProfile? profile;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (profile == null) {
      return ZitlasCard(child: loading ? const EdLoading() : const SizedBox(height: 60));
    }
    final p = profile!;

    return ZitlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  EdAvatar(name: p.name, size: 56, photoUrl: p.photo),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: PresenceDot(
                      uid: p.uid,
                      size: 14,
                      borderColor: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ZitlasTokens.textPrimary,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                      decoration: BoxDecoration(
                        color: ZitlasTokens.border,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        p.specialization,
                        style: const TextStyle(
                          color: ZitlasTokens.primaryDark,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded, color: ZitlasTokens.primary, size: 14),
                        const SizedBox(width: 3),
                        Text(
                          p.rating,
                          style: const TextStyle(
                            color: ZitlasTokens.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Text(
                          '  ·  ',
                          style: TextStyle(color: ZitlasTokens.textMuted, fontSize: 12),
                        ),
                        Flexible(
                          child: Text(
                            '${p.reviewCount} reviews',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: ZitlasTokens.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _FeeChip(label: 'Review', value: '₹${p.fee}')),
              const SizedBox(width: 10),
              Expanded(child: _FeeChip(label: 'Experience', value: p.experience)),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeeChip extends StatelessWidget {
  const _FeeChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCardLight,
        borderRadius: BorderRadius.circular(kZitlasRadiusSm),
        border: Border.all(color: ZitlasTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: ZitlasTokens.textMuted, fontSize: 10),
          ),
          const SizedBox(height: 1),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: ZitlasTokens.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// `.ed-stats-grid` — 4 tiles. When a count is zero the website swaps the
/// number for an encouraging empty message (`setStatText`, ED:339); we keep
/// that behaviour rather than showing a bare "0".
class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.controller});
  final ExpertDashboardController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final tiles = <Widget>[
      _StatTile(
        icon: '📋',
        value: '${c.statPending}',
        label: 'Pending Reviews',
        emptyLabel: "🎉 You're all caught up.",
        isEmpty: c.statPending == 0,
        loading: c.reviewsLoading,
      ),
      _StatTile(
        icon: '💬',
        value: '${c.statChats}',
        label: 'Active Chats',
        emptyLabel: 'No conversations yet.',
        isEmpty: c.statChats == 0,
        loading: c.chatsLoading,
      ),
      _StatTile(
        icon: '👥',
        value: '${c.statClients}',
        label: 'Active Clients',
        emptyLabel: 'No clients yet.',
        isEmpty: c.statClients == 0,
        loading: c.reviewsLoading,
      ),
      _StatTile(
        icon: '₹',
        value: '₹${c.statEarnings}',
        label: 'Est. Earnings',
        emptyLabel: 'No earnings yet.',
        isEmpty: c.statEarnings == 0,
        loading: c.reviewsLoading,
        accent: true,
      ),
    ];

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: tiles[0]),
            const SizedBox(width: 12),
            Expanded(child: tiles[1]),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: tiles[2]),
            const SizedBox(width: 12),
            Expanded(child: tiles[3]),
          ],
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.value,
    required this.label,
    required this.emptyLabel,
    required this.isEmpty,
    required this.loading,
    this.accent = false,
  });

  final String icon;
  final String value;
  final String label;
  final String emptyLabel;
  final bool isEmpty;
  final bool loading;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return ZitlasCard(
      radius: kZitlasRadiusMd,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      color: accent ? const Color(0xFFFFF3E0).withValues(alpha: 0.86) : ZitlasTokens.cardGlass,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(icon, style: const TextStyle(fontSize: 17)),
          const SizedBox(height: 6),
          if (loading)
            const SizedBox(
              height: 24,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: ZitlasTokens.primary),
                ),
              ),
            )
          else if (!isEmpty)
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: ZitlasTokens.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                height: 1.1,
              ),
            )
          else
            const SizedBox(height: 6),
          const SizedBox(height: 2),
          Text(
            isEmpty && !loading ? emptyLabel : label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: ZitlasTokens.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickButton extends StatelessWidget {
  const _QuickButton({required this.icon, required this.label, required this.onTap});
  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ZitlasCard(
        radius: kZitlasRadiusMd,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Column(
          children: [
            Text(icon, style: const TextStyle(fontSize: 21)),
            const SizedBox(height: 7),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: const TextStyle(
                color: ZitlasTokens.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `.ed-user-card` — name, `Coaching since <date>`, days-left warning
/// under 7 days (ED:1337-1376).
class _AthleteTile extends StatelessWidget {
  const _AthleteTile({required this.rel, required this.onOpen});

  final CoachingRelationship rel;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final name = rel.athleteName ?? 'Athlete';
    final since = rel.startDate != null
        ? 'Coaching since ${DateFormat('d MMM').format(rel.startDate!)}'
        : 'Coaching client';
    final days = rel.daysRemaining;
    final warn = days != null && days <= 7;
    final suffix = days == null
        ? ''
        : ' · $days ${days == 1 ? 'day' : 'days'} left';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          EdAvatar(name: name, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: ZitlasTokens.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${warn ? '⚠ ' : ''}$since$suffix',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: warn ? ZitlasTokens.danger : ZitlasTokens.textMuted,
                    fontSize: 11.5,
                    fontWeight: warn ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          EdActionButton(label: 'View User Profile', onPressed: onOpen, filled: false),
        ],
      ),
    );
  }
}
