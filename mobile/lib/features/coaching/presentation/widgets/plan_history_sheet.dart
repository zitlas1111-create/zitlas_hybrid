import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../data/coaching_plan_repository.dart';
import '../../models/coach_plan_version.dart';

/// Version history with rollback (Step 10 / Phase 2A's `versions/`).
///
/// A restore is saved FORWARD as a new revision rather than rewinding, so the
/// revision being replaced stays in the list and the athlete's history stays
/// truthful about what they were prescribed and when.
Future<void> showPlanHistorySheet(
  BuildContext context, {
  required String athleteId,
  required String athleteName,
  required String coachId,
  required String coachName,
  required String planType,
  required CoachingPlanRepository repository,
  String? athletePlanId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PlanHistorySheet(
      athleteId: athleteId,
      athleteName: athleteName,
      coachId: coachId,
      coachName: coachName,
      planType: planType,
      repository: repository,
      athletePlanId: athletePlanId,
    ),
  );
}

class _PlanHistorySheet extends StatefulWidget {
  const _PlanHistorySheet({
    required this.athleteId,
    required this.athleteName,
    required this.coachId,
    required this.coachName,
    required this.planType,
    required this.repository,
    this.athletePlanId,
  });

  final String athleteId, athleteName, coachId, coachName, planType;
  final CoachingPlanRepository repository;
  final String? athletePlanId;

  @override
  State<_PlanHistorySheet> createState() => _PlanHistorySheetState();
}

class _PlanHistorySheetState extends State<_PlanHistorySheet> {
  String? _restoring;

  Future<void> _restore(CoachPlanVersion version) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ZitlasTokens.bgCard,
        title: Text('Restore ${version.type} v${version.version}?'),
        content: Text(
          'This republishes that revision to ${widget.athleteName} and notifies '
          'them. It is saved as a NEW version — nothing in this history is '
          'deleted or overwritten.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _restoring = version.id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.repository.restoreVersion(
        athleteId: widget.athleteId,
        athleteName: widget.athleteName,
        coachId: widget.coachId,
        coachName: widget.coachName,
        planType: widget.planType,
        version: version,
        athletePlanId: widget.athletePlanId,
      );
      if (!mounted) return;
      setState(() => _restoring = null);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('✅ v${version.version} republished to ${widget.athleteName}'),
        ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _restoring = null);
      // The backend's reason (coaching ended, a newer publish, no connection)
      // is worth more than a generic failure.
      final reason = e is CoachPlanConflictException || e is CoachPlanSaveException
          ? e.toString()
          : 'Could not restore. Please try again.';
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(reason)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
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
              decoration: BoxDecoration(
                color: ZitlasTokens.borderSub,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Plan history',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: ZitlasTokens.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          const Text(
            'Every version you have published. Restoring one republishes it as a '
            'new version — nothing here is ever deleted.',
            style: TextStyle(fontSize: 11.5, height: 1.45, color: ZitlasTokens.textSecondary),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: StreamBuilder<List<CoachPlanVersion>>(
              stream: widget.repository.watchVersions(widget.athleteId),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 36),
                    child: Center(child: CircularProgressIndicator(color: ZitlasTokens.primary)),
                  );
                }
                final versions = snap.data ?? const [];
                if (versions.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Text(
                      'No versions yet — publish a plan and it will appear here.',
                      style: TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary),
                    ),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  itemCount: versions.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: ZitlasTokens.borderSub),
                  itemBuilder: (context, i) {
                    final v = versions[i];
                    final isLatest = i == 0 ||
                        !versions.take(i).any((other) => other.type == v.type);
                    return _VersionRow(
                      version: v,
                      isLatest: isLatest,
                      busy: _restoring == v.id,
                      onRestore: _restoring == null ? () => _restore(v) : null,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({
    required this.version,
    required this.isLatest,
    required this.busy,
    required this.onRestore,
  });

  final CoachPlanVersion version;
  final bool isLatest;
  final bool busy;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(version.isDiet ? '🥗' : '🏋', style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${version.isDiet ? "Diet" : "Training"} v${version.version}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: ZitlasTokens.textPrimary,
                      ),
                    ),
                    if (isLatest) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: ZitlasTokens.success.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'CURRENT',
                          style: TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w900,
                            color: ZitlasTokens.success,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (version.savedBy != null) version.savedBy!,
                    if (version.savedAt != null) _when(version.savedAt!),
                    if (version.dayCount > 0) '${version.dayCount} days',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted),
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: ZitlasTokens.primary),
            )
          else if (!isLatest)
            TextButton(
              onPressed: onRestore,
              style: TextButton.styleFrom(
                foregroundColor: ZitlasTokens.primary,
                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              child: const Text('Restore'),
            ),
        ],
      ),
    );
  }

  static String _when(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) {
      final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
      return 'today $h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? "AM" : "PM"}';
    }
    if (diff.inDays == 1) return 'yesterday';
    return '${t.day}/${t.month}/${t.year}';
  }
}
