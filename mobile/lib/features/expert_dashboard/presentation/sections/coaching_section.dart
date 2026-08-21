import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../data/expert_repository.dart';
import '../../expert_dashboard_controller.dart';
import '../../models/expert_models.dart';
import '../widgets/expert_common.dart';

/// `#sectionCoaching` — Personal Coaching requests with Pending / Active /
/// Past Clients tabs. Accept and decline are server-authoritative: they call
/// `/api/coaching/accept|reject` with a Firebase ID token, exactly as
/// `_pcUpdateRequestStatus` does (ED:1529-1559). The client never writes
/// these Firestore docs itself.
class ExpertCoachingSection extends StatefulWidget {
  const ExpertCoachingSection({super.key, required this.onOpenChat});

  final void Function(CoachingRequest) onOpenChat;

  @override
  State<ExpertCoachingSection> createState() => _ExpertCoachingSectionState();
}

class _ExpertCoachingSectionState extends State<ExpertCoachingSection> {
  int _tab = 0;
  final _busy = <String>{};

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _respond(
    ExpertDashboardController c,
    CoachingRequest req, {
    required bool accept,
  }) async {
    if (!accept) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: ZitlasTokens.bgCard,
          title: const Text('Decline this request?'),
          content: Text(
            "${req.athleteName ?? 'The athlete'}'s reserved payment will be released.",
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Decline', style: TextStyle(color: ZitlasTokens.danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busy.add(req.id));
    final result = await c.respondToCoaching(req, accept: accept);
    if (!mounted) return;
    setState(() => _busy.remove(req.id));

    // Result messages verbatim from ED:1544-1553.
    switch (result) {
      case CoachingActionResult.success:
        _toast(accept
            ? '✅ Accepted — payment auto-debited, coaching is now active.'
            : 'Request declined — reservation released.');
      case CoachingActionResult.alreadyHandled:
        _toast('This request was already handled.');
      case CoachingActionResult.failed:
        _toast('Could not update the request. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ExpertDashboardController>();
    final buckets = [c.pendingCoaching, c.activeCoaching, c.pastCoaching];
    final list = buckets[_tab];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        const EdSectionLabel('Personal Coaching'),
        if (!c.coachingLoading && c.coachingError == null) ...[
          _CoachingSummary(controller: c),
          const SizedBox(height: 12),
        ],
        EdTabStrip(
          labels: const ['Pending', 'Active', 'Past Clients'],
          badges: [c.pendingCoaching.length, 0, 0],
          activeIndex: _tab,
          onChanged: (i) => setState(() => _tab = i),
        ),
        const SizedBox(height: 14),
        if (c.coachingLoading)
          const EdLoading()
        else if (c.coachingError != null)
          ZitlasCard(
            child: EdErrorState(
              message: edErrorMessage(c.coachingError, what: 'coaching requests'),
            ),
          )
        else if (list.isEmpty)
          const ZitlasCard(
            padding: EdgeInsets.zero,
            child: EdEmptyState(
              icon: '👨‍🏫',
              title: 'No coaching requests',
              subtitle:
                  'Users who request Personal Coaching with you will appear here.',
            ),
          )
        else
          for (final req in list)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _CoachingCard(
                req: req,
                busy: _busy.contains(req.id),
                onAccept: () => _respond(c, req, accept: true),
                onDecline: () => _respond(c, req, accept: false),
                onChat: () => widget.onOpenChat(req),
              ),
            ),
      ],
    );
  }
}

/// The coaching request card (ED:1459-1520).
class _CoachingCard extends StatelessWidget {
  const _CoachingCard({
    required this.req,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
    required this.onChat,
  });

  final CoachingRequest req;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onChat;

  @override
  Widget build(BuildContext context) {
    final planLine = [
      req.planLabel ?? req.planType ?? 'Personal Coaching',
      if (req.price != null) '₹${req.price}/mo',
    ].join(' · ');

    return ZitlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AthleteAvatar(
                name: req.athleteName ?? 'Athlete',
                photo: req.athleteProfile?.photo,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            req.athleteName ?? 'Athlete',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: ZitlasTokens.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (req.isPremium) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: ZitlasTokens.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              '⭐ PRIORITY',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${req.planIcon} $planLine',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ZitlasTokens.textSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      req.statusLine,
                      maxLines: 2,
                      style: TextStyle(
                        color: req.status == 'pending'
                            ? ZitlasTokens.success
                            : ZitlasTokens.textMuted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // The profile an expert needs to judge the request. Only shown while
          // the decision is still theirs to make — once accepted, the full
          // athlete profile is available to them properly.
          if (req.status == 'pending' && (req.athleteProfile?.hasAny ?? false)) ...[
            const SizedBox(height: 12),
            _AthleteFacts(profile: req.athleteProfile!, requestedAt: req.createdAt),
          ],
          if (req.status == 'pending') ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: EdActionButton(
                    label: 'Decline',
                    onPressed: onDecline,
                    filled: false,
                    danger: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: EdActionButton(label: 'Accept', onPressed: onAccept, busy: busy),
                ),
              ],
            ),
          ] else if (req.status == 'active' || req.status == 'ended') ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: EdActionButton(
                label: req.status == 'active' ? 'Chat' : 'View Chat',
                onPressed: onChat,
                filled: false,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The athlete's photo, falling back to the initials avatar the rest of the
/// dashboard uses when there is no photo (or it fails to load).
class _AthleteAvatar extends StatelessWidget {
  const _AthleteAvatar({required this.name, this.photo});

  final String name;
  final String? photo;

  @override
  Widget build(BuildContext context) {
    final url = photo?.trim();
    if (url == null || url.isEmpty || !url.startsWith('http')) {
      return EdAvatar(name: name, size: 42);
    }
    return ClipOval(
      child: Image.network(
        url,
        width: 42,
        height: 42,
        fit: BoxFit.cover,
        // A broken photo URL must never blank the card — the initials avatar
        // is a complete answer on its own.
        errorBuilder: (_, _, _) => EdAvatar(name: name, size: 42),
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : EdAvatar(name: name, size: 42),
      ),
    );
  }
}

/// Age / gender / height / weight / BMI / goal, plus when the request came in.
///
/// Only facts that exist are rendered. A missing height is omitted rather than
/// shown as "—": an expert scanning a queue should see what they know, not a
/// grid of blanks.
class _AthleteFacts extends StatelessWidget {
  const _AthleteFacts({required this.profile, this.requestedAt});

  final CoachingAthleteProfile profile;
  final DateTime? requestedAt;

  @override
  Widget build(BuildContext context) {
    final facts = <(String, String)>[
      if (profile.age != null) ('Age', '${profile.age}'),
      if (profile.gender != null) ('Gender', _capitalise(profile.gender!)),
      if (profile.heightCm != null) ('Height', '${_trim(profile.heightCm!)} cm'),
      if (profile.weightKg != null) ('Weight', '${_trim(profile.weightKg!)} kg'),
      if (profile.bmi != null) ('BMI', _trim(profile.bmi!)),
      if (profile.goalType != null) ('Goal', _capitalise(profile.goalType!)),
    ];
    if (facts.isEmpty && requestedAt == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCardLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZitlasTokens.borderSub),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (facts.isNotEmpty)
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                for (final (label, value) in facts)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label.toUpperCase(),
                        style: const TextStyle(
                          color: ZitlasTokens.textMuted,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        value,
                        style: const TextStyle(
                          color: ZitlasTokens.textPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          if (requestedAt != null) ...[
            if (facts.isNotEmpty) const SizedBox(height: 8),
            Text(
              'Requested ${_relative(requestedAt!)}',
              style: const TextStyle(
                color: ZitlasTokens.textMuted,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _trim(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  static String _capitalise(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll('_', ' ');

  static String _relative(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 30) return '${diff.inDays} days ago';
    return '${when.day}/${when.month}/${when.year}';
  }
}

/// Coaching at a glance: assigned athletes, and how the request queue stands.
///
/// Every number is derived from the two live streams the section already
/// holds — no extra reads, and nothing can disagree with the list below it.
class _CoachingSummary extends StatelessWidget {
  const _CoachingSummary({required this.controller});

  final ExpertDashboardController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    // `myUsers` counts ACTIVE relationships (personal_coaching), which is
    // the real client list; `activeCoaching` counts accepted REQUESTS. They
    // usually match, and when they don't the relationship is the truth — a
    // request whose 30 days lapsed is no longer a client.
    final stats = <(String, String, int)>[
      ('👥', 'Users', c.myAthletes.length),
      ('🕒', 'Pending', c.pendingCoaching.length),
      ('✅', 'Accepted', c.activeCoaching.length),
      ('✕', 'Declined', c.declinedCoaching.length),
    ];

    return ZitlasCard(
      child: Row(
        children: [
          for (final (icon, label, value) in stats)
            Expanded(
              child: Column(
                children: [
                  Text(icon, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 3),
                  Text(
                    '$value',
                    style: TextStyle(
                      color: value > 0 && label == 'Pending'
                          ? ZitlasTokens.primary
                          : ZitlasTokens.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    label,
                    style: const TextStyle(
                      color: ZitlasTokens.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
