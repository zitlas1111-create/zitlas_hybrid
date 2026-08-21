import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../../core/utils/safe_image.dart';
import '../../data/meal_checkin_repository.dart';
import '../../models/meal_checkin.dart';
import '../../models/meal_compliance.dart';

/// The coach's meal review queue (Steps 4, 7, 11).
///
/// Pending first, because that is the work. Everything below the fold is
/// history and compliance — useful, but not what the coach opened this for.
class MealReviewScreen extends StatelessWidget {
  const MealReviewScreen({
    super.key,
    required this.coachId,
    required this.coachName,
    this.repository,
    this.athleteId,
  });

  final String coachId;
  final String coachName;
  final MealCheckinRepository? repository;

  /// Narrows to one athlete when opened from their profile; null shows every
  /// athlete this coach works with.
  final String? athleteId;

  @override
  Widget build(BuildContext context) {
    final repo = repository ?? MealCheckinRepository();

    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgCard,
        elevation: 0,
        iconTheme: const IconThemeData(color: ZitlasTokens.textPrimary),
        title: const Text(
          'Meal Reviews',
          style: TextStyle(
            color: ZitlasTokens.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: StreamBuilder<List<MealCheckin>>(
        stream: repo.watchForCoach(coachId),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: ZitlasTokens.primary),
            );
          }
          if (snap.hasError) {
            return const _Message(
              "These meals are no longer available to you — that usually means "
              'the coaching relationship has ended.',
            );
          }

          final all = [
            for (final c in snap.data ?? const <MealCheckin>[])
              if (athleteId == null || c.athleteId == athleteId) c,
          ];
          if (all.isEmpty) {
            return const _Message(
              'No meals yet. When your users photograph a meal it appears '
              'here for review.',
            );
          }

          final pending = all.where((c) => c.isPending).toList();
          final reviewed = all.where((c) => c.isReviewed).toList();
          final insights = buildInsights(checkins: all, today: DateTime.now());

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
            children: [
              _Counters(
                pending: pending.length,
                reviewedToday: reviewed.where((c) => _isToday(c.reviewedAt)).length,
                athletesPending: pending.map((c) => c.athleteId).toSet().length,
              ),
              if (insights.isNotEmpty) ...[
                const SizedBox(height: 12),
                _Insights(insights: insights),
              ],
              const SizedBox(height: 16),
              if (pending.isNotEmpty) ...[
                const _SectionLabel('AWAITING YOUR REVIEW'),
                for (final c in pending)
                  _CheckinCard(
                    checkin: c,
                    repository: repo,
                    coachName: coachName,
                  ),
                const SizedBox(height: 12),
              ],
              if (reviewed.isNotEmpty) ...[
                const _SectionLabel('REVIEWED'),
                for (final c in reviewed.take(20))
                  _CheckinCard(
                    checkin: c,
                    repository: repo,
                    coachName: coachName,
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  static bool _isToday(DateTime? t) {
    if (t == null) return false;
    final now = DateTime.now();
    return t.year == now.year && t.month == now.month && t.day == now.day;
  }
}

class _Counters extends StatelessWidget {
  const _Counters({
    required this.pending,
    required this.reviewedToday,
    required this.athletesPending,
  });

  final int pending, reviewedToday, athletesPending;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZitlasTokens.borderSub),
      ),
      child: Row(
        children: [
          _Counter(value: pending, label: 'Pending', highlight: pending > 0),
          _Counter(value: reviewedToday, label: 'Reviewed today'),
          _Counter(value: athletesPending, label: 'Users waiting'),
        ],
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.value, required this.label, this.highlight = false});

  final int value;
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w900,
              color: highlight ? ZitlasTokens.primary : ZitlasTokens.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted),
          ),
        ],
      ),
    );
  }
}

class _Insights extends StatelessWidget {
  const _Insights({required this.insights});

  final List<CoachInsight> insights;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZitlasTokens.borderSub),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'WHAT THE RECORD SHOWS',
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.7,
              color: ZitlasTokens.textMuted,
            ),
          ),
          const SizedBox(height: 7),
          for (final i in insights)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${i.icon} ${i.text}',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: i.isPositive ? ZitlasTokens.success : ZitlasTokens.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CheckinCard extends StatefulWidget {
  const _CheckinCard({
    required this.checkin,
    required this.repository,
    required this.coachName,
  });

  final MealCheckin checkin;
  final MealCheckinRepository repository;
  final String coachName;

  @override
  State<_CheckinCard> createState() => _CheckinCardState();
}

class _CheckinCardState extends State<_CheckinCard> {
  MealReaction? _picked;
  late final _comment = TextEditingController(text: widget.checkin.comment ?? '');
  bool _saving = false;
  bool _expanded = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reaction = _picked;
    if (reaction == null || _saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.repository.review(
        checkin: widget.checkin,
        reaction: reaction,
        coachName: widget.coachName,
        comment: _comment.text,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _expanded = false;
      });
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('${reaction.icon} ${widget.checkin.mealName} reviewed — '
              '${widget.checkin.athleteName ?? "the athlete"} has been notified.'),
        ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Could not save that review. Please try again.'),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.checkin;
    final reviewed = c.reaction != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ZitlasTokens.borderSub),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isNetworkImageUrl(c.imageUrl))
            GestureDetector(
              onTap: () => _openFullImage(context, c.imageUrl!),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                child: CachedNetworkImage(
                  imageUrl: c.imageUrl!,
                  height: 190,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => Container(
                    height: 190,
                    color: ZitlasTokens.bgCardLight,
                    child: const Center(
                      child: CircularProgressIndicator(color: ZitlasTokens.primary),
                    ),
                  ),
                  errorWidget: (_, _, _) => Container(
                    height: 190,
                    color: ZitlasTokens.bgCardLight,
                    alignment: Alignment.center,
                    child: const Text(
                      'Photo unavailable',
                      style: TextStyle(fontSize: 12, color: ZitlasTokens.textMuted),
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${c.athleteName ?? "Athlete"} · ${c.mealName}',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: ZitlasTokens.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      _when(c.timestamp),
                      style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted),
                    ),
                  ],
                ),
                if (c.foodRecognition.isNotEmpty || c.hasEstimate) ...[
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (c.foodRecognition.isNotEmpty) c.foodRecognition.join(', '),
                      // Always labelled an estimate — a vision model looking at
                      // a plate, not a weighed measurement.
                      if (c.hasEstimate)
                        'est. ${[
                          if (c.estimatedCalories != null) '${c.estimatedCalories!.round()} kcal',
                          if (c.estimatedProtein != null) '${c.estimatedProtein!.round()}g P',
                        ].join(' · ')}',
                    ].join(' — '),
                    style: const TextStyle(fontSize: 11, color: ZitlasTokens.textSecondary),
                  ),
                ],
                if (reviewed && !_expanded) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        '${c.reaction!.icon} ${c.reaction!.label}',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: c.reaction!.isCompliant
                              ? ZitlasTokens.success
                              : ZitlasTokens.danger,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() {
                          _expanded = true;
                          _picked = c.reaction;
                        }),
                        style: TextButton.styleFrom(
                          foregroundColor: ZitlasTokens.textSecondary,
                          textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        child: const Text('Change'),
                      ),
                    ],
                  ),
                  if (c.comment != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '"${c.comment!}"',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontStyle: FontStyle.italic,
                          color: ZitlasTokens.textSecondary,
                        ),
                      ),
                    ),
                ] else ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final r in MealReaction.values)
                        _ReactionChip(
                          reaction: r,
                          selected: _picked == r,
                          onTap: () => setState(() => _picked = r),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _comment,
                    maxLines: 2,
                    style: const TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: 'Optional note — e.g. "Great protein. Add a fruit tomorrow."',
                      hintStyle: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted),
                      filled: true,
                      fillColor: ZitlasTokens.bgCardLight,
                      contentPadding: const EdgeInsets.all(11),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                        borderSide: const BorderSide(color: ZitlasTokens.borderSub),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                        borderSide: const BorderSide(color: ZitlasTokens.borderSub),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _picked == null || _saving ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: ZitlasTokens.primary,
                            disabledBackgroundColor: ZitlasTokens.borderSub,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            _saving ? 'Saving…' : 'Send review',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Step 12 — straight into the existing chat thread, so a
                      // meal that needs a conversation gets one.
                      IconButton(
                        tooltip: 'Discuss in chat',
                        onPressed: () => context.push(
                          '/chat/chat_${c.athleteId}_${c.coachId}'
                          '?expertId=${c.coachId}'
                          '&expertName=${Uri.encodeComponent(c.athleteName ?? "Athlete")}',
                        ),
                        icon: const Icon(Icons.chat_bubble_rounded, size: 19),
                        color: ZitlasTokens.textSecondary,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openFullImage(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: InteractiveViewer(
            child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  static String _when(DateTime? t) {
    if (t == null) return '';
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays}d ago';
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.reaction,
    required this.selected,
    required this.onTap,
  });

  final MealReaction reaction;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? ZitlasTokens.primary : ZitlasTokens.bgCardLight,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? ZitlasTokens.primary : ZitlasTokens.borderSub,
          ),
        ),
        child: Text(
          '${reaction.icon} ${reaction.label}',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: selected ? Colors.white : ZitlasTokens.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 3, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.7,
          color: ZitlasTokens.textMuted,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            height: 1.5,
            color: ZitlasTokens.textSecondary,
          ),
        ),
      ),
    );
  }
}
