import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../../core/utils/safe_image.dart';
import '../../../auth/auth_state.dart';
import '../../../expert_dashboard/models/expert_models.dart';
import '../../data/experts_repository.dart';
import '../../expert_profile_controller.dart';
import '../../models/expert_listing.dart';
import '../widgets/request_review_sheet.dart';
import '../widgets/personal_coaching_sheet.dart';
// NOTE: this whole screen is DORMANT — the entire coach journey (profile,
// Request Review, Personal Coach, payment, active coaching workspace) is now
// ONE continuous Website session in CoachingWebViewScreen.coachProfile
// ('/coach-profile/:id'), reached from the Experts list and coaching
// notifications. Nothing in the app routes here any more; kept in the tree,
// unreferenced, for the eventual return to native parity (see
// ActiveCoachingBanner, similarly dormant).

/// Native rebuild of `frontend/pages/coaches/cprofile.html` + `cprofile.js`
/// — the athlete-facing Expert Profile page. DORMANT (see note above).
/// Section order matches the website exactly: hero → quick info → CTAs →
/// status banner → About → Certificates → Expertise → Track record →
/// Services → Pricing → Reviews. Gallery/availability calendar/WebRTC voice
/// calling are deferred (same precedent as the Expert Dashboard phase — no
/// phone-dialer alternative exists in production, only unbuilt WebRTC);
/// certificates, verified status, pricing and the review-request lifecycle
/// are full parity.
class ExpertProfileScreen extends StatelessWidget {
  const ExpertProfileScreen({super.key, required this.expertId, this.action});

  final String expertId;
  final String? action;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>().profile;
    if (auth == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ChangeNotifierProvider<ExpertProfileController>(
      key: ValueKey(expertId),
      create: (_) => ExpertProfileController(
        expertId: expertId,
        userId: auth.uid,
        userName: auth.name ?? 'User',
        repository: ExpertsRepository(firestore: FirebaseFirestore.instance, auth: FirebaseAuth.instance),
        firestore: FirebaseFirestore.instance,
      ),
      child: _ExpertProfileBody(action: action),
    );
  }
}

class _ExpertProfileBody extends StatefulWidget {
  const _ExpertProfileBody({this.action});
  final String? action;

  @override
  State<_ExpertProfileBody> createState() => _ExpertProfileBodyState();
}

class _ExpertProfileBodyState extends State<_ExpertProfileBody> {
  bool _deepLinkHandled = false;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ExpertProfileController>();

    if (controller.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: ZitlasTokens.primary)));
    }
    if (controller.notFound || controller.expert == null) {
      return Scaffold(
        backgroundColor: ZitlasTokens.bgStart,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
        body: const Center(
          child: Text('Expert profile not found.', style: TextStyle(color: ZitlasTokens.textSecondary)),
        ),
      );
    }

    if (!_deepLinkHandled) {
      _deepLinkHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _handleDeepLink(context, controller));
    }

    final e = controller.expert!;
    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              pinned: false,
              leading: IconButton(icon: const Icon(Icons.arrow_back, color: ZitlasTokens.textPrimary), onPressed: () => context.pop()),
            ),
            SliverToBoxAdapter(child: _Hero(expert: e)),
            SliverToBoxAdapter(child: _QuickInfo(expert: e)),
            SliverToBoxAdapter(child: _Ctas(controller: controller)),
            if (_isActiveCoachOfThisExpert(controller))
              SliverToBoxAdapter(
                child: _OpenCoachingCta(
                  coachName: e.name,
                  coachId: controller.expertId,
                ),
              ),
            SliverToBoxAdapter(child: _StatusBanner(controller: controller)),
            if (e.about != null) SliverToBoxAdapter(child: _Section(title: 'About', child: Text(e.about!, style: const TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary, height: 1.5)))),
            SliverToBoxAdapter(child: _CertificatesSection(controller: controller)),
            if (e.expertise.isNotEmpty) SliverToBoxAdapter(child: _ExpertiseSection(expert: e)),
            if (e.stats.isNotEmpty) SliverToBoxAdapter(child: _StatsSection(expert: e)),
            SliverToBoxAdapter(child: _PricingSection(expert: e)),
            if (controller.expertRatings.isNotEmpty)
              SliverToBoxAdapter(child: _CoachingRatingsSection(controller: controller)),
            if (e.reviews.isNotEmpty) SliverToBoxAdapter(child: _ReviewsSection(expert: e)),
            SliverToBoxAdapter(child: _PreviousReviewsSection(controller: controller)),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  void _handleDeepLink(BuildContext context, ExpertProfileController controller) {
    switch (widget.action) {
      case 'verify':
        showRequestReviewSheet(context, controller: controller);
        break;
      case 'coach':
        showPersonalCoachingSheet(context, controller: controller);
        break;
      case 'ask':
        _openChat(context, controller);
        break;
    }
  }
}

/// True only when [controller.myCoachingRelationship] is ACTIVE and is a
/// relationship with THIS expert — an athlete coaching with someone else
/// entirely must never see End Coaching on a different expert's profile.
bool _isActiveCoachOfThisExpert(ExpertProfileController controller) {
  final rel = controller.myCoachingRelationship;
  return rel != null && rel.isActive && rel.coachId == controller.expertId;
}

void _openChat(BuildContext context, ExpertProfileController controller) {
  context.push('/chat/${controller.chatId()}?expertId=${controller.expertId}&expertName=${Uri.encodeComponent(controller.expert!.name)}');
}

/// DORMANT (see file note above) — unreached now that `/coach-profile/:id`
/// is the sole entry point, which the website's own JS already routes to the
/// active-coaching workspace when the relationship is active. Kept in the
/// tree, pointed at the current route name, for the eventual return to
/// native parity.
class _OpenCoachingCta extends StatelessWidget {
  const _OpenCoachingCta({required this.coachName, required this.coachId});

  final String coachName;
  final String coachId;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ZitlasTokens.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🏋️', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Personal Coaching active',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: ZitlasTokens.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Chat with $coachName, send meals for review, follow your coach plan '
            'and manage your coaching.',
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: ZitlasTokens.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => context.push('/coach-profile/$coachId'),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('Open Coaching'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.expert});
  final ExpertListing expert;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        children: [
          if (expert.availableToday)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: ZitlasTokens.success.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: const Text('🟢 Available Today', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ZitlasTokens.success)),
            ),
          CircleAvatar(
            radius: 44,
            backgroundColor: ZitlasTokens.primary.withValues(alpha: 0.15),
            backgroundImage: safeImageProvider(expert.image),
            child: expert.image == null || expert.image!.isEmpty
                ? Text(expert.initials, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: ZitlasTokens.primaryDark))
                : null,
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(expert.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
              if (expert.verified) ...[
                const SizedBox(width: 5),
                const Icon(Icons.verified_rounded, size: 18, color: ZitlasTokens.aiAccent),
              ],
            ],
          ),
          Text(expert.role, style: const TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary)),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.star_rounded, size: 16, color: ZitlasTokens.primary),
              const SizedBox(width: 3),
              Text('${expert.rating} · ${expert.reviewCount} reviews', style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary)),
            ],
          ),
          if (expert.verified)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Identity & credentials verified by ZITLAS', style: TextStyle(fontSize: 10.5, color: ZitlasTokens.aiAccent)),
            ),
          if (expert.quote != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('"${expert.quote}"', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: ZitlasTokens.textMuted)),
            ),
        ],
      ),
    );
  }
}

class _QuickInfo extends StatelessWidget {
  const _QuickInfo({required this.expert});
  final ExpertListing expert;

  @override
  Widget build(BuildContext context) {
    Widget item(String label, String value) => Expanded(
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
          Text(label, style: const TextStyle(fontSize: 10, color: ZitlasTokens.textMuted)),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ZitlasCard(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        radius: kZitlasRadiusMd,
        child: Row(
          children: [
            item('Languages', expert.languages.isNotEmpty ? expert.languages.join(', ') : '—'),
            item('Experience', expert.experience ?? '—'),
            item('Chat', '₹${expert.pricing.chatPrice}'),
            item('Call', expert.callRate != null ? '₹${expert.callRate}' : '—'),
          ],
        ),
      ),
    );
  }
}

class _Ctas extends StatelessWidget {
  const _Ctas({required this.controller});
  final ExpertProfileController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
              label: const Text('Chat Now'),
              onPressed: () => _openChat(context, controller),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12), side: const BorderSide(color: ZitlasTokens.borderSub)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.school_rounded, size: 16),
              label: const Text('Personal Coach'),
              onPressed: () => showPersonalCoachingSheet(context, controller: controller),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12), side: const BorderSide(color: ZitlasTokens.borderSub)),
            ),
          ),
        ],
      ),
    );
  }
}

/// `updateVerifyBtnState(coach)` (cprofile.js:2510-2614) — exact button text
/// per status, plus the withdraw / "Request Another Review" affordances.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.controller});
  final ExpertProfileController controller;

  @override
  Widget build(BuildContext context) {
    final info = controller.verifyButtonState();
    final isTerminal = info.state == VerifyButtonState.completed || info.state == VerifyButtonState.rejected;

    Color bg;
    Color fg;
    switch (info.state) {
      case VerifyButtonState.requestReview:
        bg = ZitlasTokens.primary;
        fg = Colors.white;
        break;
      case VerifyButtonState.pendingWithdraw:
      case VerifyButtonState.awaitingPayment:
      case VerifyButtonState.inProgress:
        bg = ZitlasTokens.bgCardLight;
        fg = ZitlasTokens.textPrimary;
        break;
      case VerifyButtonState.chatWithExpert:
        bg = ZitlasTokens.aiAccent;
        fg = Colors.white;
        break;
      case VerifyButtonState.completed:
        bg = ZitlasTokens.success.withValues(alpha: 0.15);
        fg = ZitlasTokens.successDark;
        break;
      case VerifyButtonState.rejected:
        bg = ZitlasTokens.danger.withValues(alpha: 0.12);
        fg = ZitlasTokens.danger;
        break;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: bg, padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              onPressed: () => _onTap(context, info),
              child: Text(info.label, style: TextStyle(color: fg, fontWeight: FontWeight.w800)),
            ),
          ),
          if (info.state == VerifyButtonState.pendingWithdraw)
            TextButton(
              onPressed: () => _confirmWithdraw(context, info.review!),
              child: const Text('Withdraw Request', style: TextStyle(color: ZitlasTokens.danger, fontSize: 12)),
            ),
          if (isTerminal)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                onPressed: () => showRequestReviewSheet(context, controller: controller),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: ZitlasTokens.borderSub)),
                child: const Text('Request Another Review', style: TextStyle(fontSize: 12.5)),
              ),
            ),
        ],
      ),
    );
  }

  void _onTap(BuildContext context, VerifyButtonInfo info) {
    switch (info.state) {
      case VerifyButtonState.requestReview:
        showRequestReviewSheet(context, controller: controller);
        break;
      case VerifyButtonState.chatWithExpert:
        _openChat(context, controller);
        break;
      default:
        break;
    }
  }

  Future<void> _confirmWithdraw(BuildContext context, ReviewRequest review) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Withdraw request?'),
        content: const Text('This review request will be withdrawn. You can request again anytime.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Withdraw', style: TextStyle(color: ZitlasTokens.danger))),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await controller.withdraw(review);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? 'Review request withdrawn.' : 'This request can no longer be withdrawn.')),
      );
    }
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _CertificatesSection extends StatelessWidget {
  const _CertificatesSection({required this.controller});
  final ExpertProfileController controller;

  @override
  Widget build(BuildContext context) {
    final certs = controller.certificates;
    return _Section(
      title: 'Verified Certificates',
      child: certs.isEmpty
          ? const Text('No certificates uploaded yet.', style: TextStyle(fontSize: 12, color: ZitlasTokens.textMuted))
          : Column(
              children: certs.map((c) {
                Color color;
                switch (c.verificationStatus) {
                  case 'verified':
                    color = ZitlasTokens.success;
                    break;
                  case 'rejected':
                    color = ZitlasTokens.danger;
                    break;
                  default:
                    color = ZitlasTokens.primaryDark;
                }
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: ZitlasTokens.bgCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: ZitlasTokens.borderSub)),
                  child: Row(
                    children: [
                      const Icon(Icons.workspace_premium_rounded, size: 20, color: ZitlasTokens.textMuted),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.certificateName ?? 'Certificate', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
                            if (c.issuingOrganization != null) Text(c.issuingOrganization!, style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted)),
                          ],
                        ),
                      ),
                      Text(c.statusLabel, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
                    ],
                  ),
                );
              }).toList(),
            ),
    );
  }
}

class _ExpertiseSection extends StatelessWidget {
  const _ExpertiseSection({required this.expert});
  final ExpertListing expert;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Expertise',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: expert.expertise
            .map((tag) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: ZitlasTokens.bgCardLight, borderRadius: BorderRadius.circular(20)),
                  child: Text(tag, style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textSecondary)),
                ))
            .toList(),
      ),
    );
  }
}

class _StatsSection extends StatelessWidget {
  const _StatsSection({required this.expert});
  final ExpertListing expert;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Track Record',
      child: Row(
        children: expert.stats.take(4).map((s) {
          return Expanded(
            child: Column(
              children: [
                Text('${s['value'] ?? ''}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.primaryDark)),
                Text('${s['label'] ?? ''}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: ZitlasTokens.textMuted)),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _PricingSection extends StatelessWidget {
  const _PricingSection({required this.expert});
  final ExpertListing expert;

  @override
  Widget build(BuildContext context) {
    final p = expert.pricing;
    final rows = <(String, num)>[
      ('Diet Plan Review', p.dietReviewPrice),
      ('Workout Plan Review', p.workoutReviewPrice),
      ('Diet + Workout Review', p.bothReviewPrice),
      ('Chat Consultation', p.chatPrice),
      ('Coaching — Diet', p.coachingDietPrice),
      ('Coaching — Training', p.coachingTrainingPrice),
      ('Coaching — Complete', p.coachingCompletePrice),
    ];
    return _Section(
      title: 'Pricing',
      child: Column(
        children: rows
            .map((r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(r.$1, style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary)),
                      Text('₹${r.$2}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }
}

/// Verified coaching ratings — 1-5 stars left by athletes who genuinely
/// completed a Personal Coaching engagement with this expert.
///
/// Distinct from `_ReviewsSection` below, which renders the legacy inline
/// `experts/{id}.reviews` array (free-form entries with no engagement
/// behind them). Only these carry the "Verified Coaching" badge, because
/// only these were validated against a real, finished engagement by the
/// backend.
class _CoachingRatingsSection extends StatelessWidget {
  const _CoachingRatingsSection({required this.controller});
  final ExpertProfileController controller;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Verified Coaching Reviews',
      child: Column(
        children: controller.expertRatings.take(8).map((r) {
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ZitlasTokens.bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: ZitlasTokens.borderSub),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Semantics(
                      label: '${r.rating} out of 5 stars',
                      child: Row(
                        children: [
                          for (var i = 1; i <= 5; i++)
                            Icon(
                              i <= r.rating ? Icons.star_rounded : Icons.star_outline_rounded,
                              size: 14,
                              color: i <= r.rating ? const Color(0xFFF5A623) : ZitlasTokens.border,
                            ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    if (r.verifiedCoaching)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0x1F3A8F8B),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          '✓ Verified Coaching',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: ZitlasTokens.hydrationTeal),
                        ),
                      ),
                  ],
                ),
                // An empty review is normal — the text was always optional,
                // and a rating with no words must still render cleanly.
                if ((r.reviewText ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(r.reviewText!, style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary, height: 1.4)),
                ],
                // Shown ONLY when the athlete explicitly consented — the
                // backend omits these URLs entirely otherwise, so a
                // non-consented photo never even reaches this device.
                if (r.hasPublicPhotos) ...[
                  const SizedBox(height: 8),
                  _TransformationPhotos(before: r.beforePhotoUrl, after: r.afterPhotoUrl),
                ],
                const SizedBox(height: 6),
                Text('— ${r.athleteName}', style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted)),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _TransformationPhotos extends StatelessWidget {
  const _TransformationPhotos({this.before, this.after});
  final String? before;
  final String? after;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (before != null) Expanded(child: _photo(before!, 'Before')),
        if (before != null && after != null) const SizedBox(width: 8),
        if (after != null) Expanded(child: _photo(after!, 'After')),
      ],
    );
  }

  Widget _photo(String url, String label) => Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 120,
              width: double.infinity,
              color: ZitlasTokens.bgCardLight,
              child: Image(
                image: safeImageProvider(url) ?? const AssetImage('assets/images/logo.png'),
                fit: BoxFit.cover,
                errorBuilder: (_, e, s) => const Icon(
                  Icons.image_not_supported_outlined,
                  color: ZitlasTokens.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textMuted)),
        ],
      );
}

class _ReviewsSection extends StatelessWidget {
  const _ReviewsSection({required this.expert});
  final ExpertListing expert;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'User Reviews',
      child: Column(
        children: expert.reviews.take(5).map((r) {
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: ZitlasTokens.bgCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: ZitlasTokens.borderSub)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('${r['name'] ?? 'Athlete'}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
                    const Spacer(),
                    const Icon(Icons.star_rounded, size: 13, color: ZitlasTokens.primary),
                    Text('${r['rating'] ?? '5'}', style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textSecondary)),
                  ],
                ),
                if (r['text'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${r['text']}', style: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary))),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// `renderPrevReviews()` (cprofile.js:2615-2676).
class _PreviousReviewsSection extends StatefulWidget {
  const _PreviousReviewsSection({required this.controller});
  final ExpertProfileController controller;

  @override
  State<_PreviousReviewsSection> createState() => _PreviousReviewsSectionState();
}

class _PreviousReviewsSectionState extends State<_PreviousReviewsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final reviews = widget.controller.myReviews;
    if (reviews.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
            child: Text('View Previous Reviews (${reviews.length})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ZitlasTokens.primaryDark)),
          ),
          if (_expanded)
            ...reviews.map((r) {
              final label = r.reviewType == 'workout' ? '💪 Workout' : '🥗 Diet';
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: ZitlasTokens.bgCardLight, borderRadius: BorderRadius.circular(10)),
                child: Row(
                  children: [
                    Text(label, style: const TextStyle(fontSize: 12)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r.status, style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted))),
                    if (r.createdAt != null) Text('${r.createdAt!.day}/${r.createdAt!.month}/${r.createdAt!.year}', style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted)),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
