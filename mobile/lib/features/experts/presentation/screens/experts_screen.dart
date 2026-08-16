import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../../core/utils/safe_image.dart';
import '../../data/experts_repository.dart';
import '../../data/pending_rating_prompt.dart';
import '../../experts_controller.dart';
import '../../models/expert_listing.dart';
import '../widgets/rate_expert_sheet.dart';

const _specialties = ['All', 'Weight Loss', 'Muscle Gain', 'PCOS', 'Diabetes', 'General Fitness'];

/// Native rebuild of `frontend/pages/coaches/coaches.html` + `coaches.js` —
/// the athlete-facing Expert marketplace, replacing the Phase-1 placeholder.
/// Reads the live `experts` Firestore collection directly (one-time fetch,
/// same as the website — no localStorage fallback since this app never had
/// that cache to begin with).
class ExpertsScreen extends StatelessWidget {
  const ExpertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ExpertsController>(
      create: (_) => ExpertsController(
        repository: ExpertsRepository(firestore: FirebaseFirestore.instance, auth: FirebaseAuth.instance),
      ),
      child: const _ExpertsBody(),
    );
  }
}

class _ExpertsBody extends StatefulWidget {
  const _ExpertsBody();

  @override
  State<_ExpertsBody> createState() => _ExpertsBodyState();
}

class _ExpertsBodyState extends State<_ExpertsBody> {
  /// The rating prompt lives HERE rather than on the dashboard or at app
  /// launch, deliberately. This is the screen an athlete lands on after a
  /// coaching engagement ends (to find a new coach), so the ask is
  /// contextual — and it is the one surface where being asked about a coach
  /// you just finished with does not feel like an interruption of something
  /// else. `PendingRatingPrompt` still owns whether to ask at all.
  final _prompt = PendingRatingPrompt();

  /// Once per mount. Without this, popping back to this tab would re-run
  /// the check and could re-open a sheet the athlete just dismissed.
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptForRating());
  }

  Future<void> _maybePromptForRating() async {
    if (_checked || !mounted) return;
    _checked = true;

    final pending = await _prompt.check();
    if (pending == null || !mounted) return;

    final submitted = await showRateExpertSheet(context, pending: pending);
    if (submitted != true) {
      // Dismissed without rating — no review is created, and the engagement
      // stays pending server-side. Snooze only delays the next ask.
      await _prompt.snooze(pending.engagementId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ExpertsController>();

    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: controller.load,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _Header(controller: controller)),
              if (controller.loading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator(color: ZitlasTokens.primary)),
                )
              else if (controller.error != null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _MessageState(
                    icon: Icons.wifi_off_rounded,
                    title: 'Could not load experts',
                    subtitle: 'Check your connection and pull to retry.',
                  ),
                )
              else if (!controller.hasAnyExperts)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _MessageState(
                    icon: Icons.person_search_rounded,
                    title: 'No experts yet',
                    subtitle: 'Verified nutrition & training experts will appear here soon.',
                  ),
                )
              else
                _ExpertList(controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final ExpertsController controller;

  @override
  Widget build(BuildContext context) {
    final results = controller.hasAnyExperts ? controller.filtered.length : 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Experts',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
          ),
          const SizedBox(height: 2),
          const Text(
            'Verified experts · 1:1 consultations · Real results',
            style: TextStyle(fontSize: 12.5, color: ZitlasTokens.hydrationTeal, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          TextField(
            onChanged: controller.setSearch,
            decoration: InputDecoration(
              hintText: 'Search by name or specialty...',
              hintStyle: TextStyle(color: ZitlasTokens.textPrimary.withValues(alpha: 0.45), fontSize: 13.5),
              prefixIcon: const Icon(Icons.search, color: ZitlasTokens.hydrationTeal, size: 20),
              filled: true,
              fillColor: ZitlasTokens.bgCard,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: ZitlasTokens.bgCardLight),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: ZitlasTokens.bgCardLight),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _specialties.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final s = _specialties[i];
                final selected = controller.specialty == s;
                return ChoiceChip(
                  label: Text(s, style: const TextStyle(fontSize: 12)),
                  selected: selected,
                  onSelected: (_) => controller.setSpecialty(s),
                  selectedColor: ZitlasTokens.primary,
                  backgroundColor: ZitlasTokens.bgCard,
                  labelStyle: TextStyle(
                    color: selected ? Colors.white : ZitlasTokens.textPrimary,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                  side: BorderSide(color: selected ? ZitlasTokens.primary : ZitlasTokens.bgCardLight),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$results expert${results == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: ZitlasTokens.textMuted, fontWeight: FontWeight.w600),
              ),
              PopupMenuButton<ExpertSort>(
                initialValue: controller.sort,
                onSelected: controller.setSort,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: ExpertSort.rated, child: Text('Highest Rated')),
                  PopupMenuItem(value: ExpertSort.price, child: Text('Lowest Price')),
                  PopupMenuItem(value: ExpertSort.available, child: Text('Available Now')),
                ],
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.tune_rounded, size: 16, color: ZitlasTokens.hydrationTeal),
                    SizedBox(width: 4),
                    Text('Sort & Filter', style: TextStyle(fontSize: 12, color: ZitlasTokens.primary, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExpertList extends StatelessWidget {
  const _ExpertList({required this.controller});

  final ExpertsController controller;

  @override
  Widget build(BuildContext context) {
    final experts = controller.filtered;
    if (experts.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: _MessageState(
          icon: Icons.filter_alt_off_rounded,
          title: 'No matches',
          subtitle: 'Try a different search term or specialty filter.',
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      sliver: SliverList.separated(
        itemCount: experts.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, i) => _ExpertCard(expert: experts[i]),
      ),
    );
  }
}

class _ExpertCard extends StatelessWidget {
  const _ExpertCard({required this.expert});

  final ExpertListing expert;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ZitlasTokens.bgCard,
      borderRadius: BorderRadius.circular(kZitlasRadiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(kZitlasRadiusMd),
        // Coach Profile — and the entire coach journey that follows it — is
        // INTENTIONALLY the Website's cprofile.html in ONE continuous WebView
        // session, not the native ExpertProfileScreen. The quick-action
        // buttons below open the SAME WebView with `action=` so the website's
        // own existing deep-link handling (cprofile.js) auto-opens that flow.
        onTap: () => context.push('/coach-profile/${expert.id}'),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kZitlasRadiusMd),
            border: Border.all(color: ZitlasTokens.borderSub),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Avatar(expert: expert, radius: 26),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                expert.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
                              ),
                            ),
                            if (expert.verified) ...[
                              const SizedBox(width: 4),
                              const Icon(Icons.verified_rounded, size: 15, color: ZitlasTokens.primary),
                            ],
                          ],
                        ),
                        Text(
                          expert.role,
                          style: const TextStyle(fontSize: 12, color: ZitlasTokens.hydrationTeal, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 10,
                          runSpacing: 2,
                          children: [
                            _MetaChip(
                              icon: Icons.star_rounded,
                              text: '${expert.rating} (${expert.reviewCount})',
                              iconColor: ZitlasTokens.achievementYellow,
                            ),
                            if (expert.experience != null) _MetaChip(icon: Icons.workspace_premium_rounded, text: expert.experience!),
                            if (expert.languages.isNotEmpty) _MetaChip(icon: Icons.translate_rounded, text: expert.languages.join(', ')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.circle, size: 8, color: expert.availableToday ? ZitlasTokens.hydrationTeal : ZitlasTokens.sageGreen),
                  const SizedBox(width: 6),
                  Text(
                    expert.availableToday ? 'Available Today' : 'Available Tomorrow',
                    style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textPrimary, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  _PriceChip(
                    label: 'Review',
                    price: expert.pricing.lowestReviewPrice,
                    bg: ZitlasTokens.achievementYellow.withValues(alpha: 0.16),
                    fg: ZitlasTokens.textPrimary,
                    border: ZitlasTokens.achievementYellow.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 6),
                  _PriceChip(
                    label: 'Coaching',
                    price: expert.pricing.coachingCompletePrice,
                    bg: ZitlasTokens.aiAccent.withValues(alpha: 0.12),
                    fg: ZitlasTokens.aiAccent,
                    border: ZitlasTokens.aiAccent.withValues(alpha: 0.3),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: ZitlasTokens.bgStart,
                    foregroundColor: ZitlasTokens.primary,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    side: const BorderSide(color: ZitlasTokens.primary, width: 1.4),
                  ),
                  onPressed: () => context.push('/coach-profile/${expert.id}?action=verify'),
                  child: const Text('Request Review', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: ZitlasTokens.bgCardLight,
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        side: BorderSide(color: ZitlasTokens.sageGreen.withValues(alpha: 0.4)),
                      ),
                      onPressed: () => context.push('/coach-profile/${expert.id}?action=coach'),
                      child: const Text('Personal Coach', style: TextStyle(fontSize: 12.5, color: ZitlasTokens.primary, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: ZitlasTokens.hydrationTeal.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => context.push('/coach-profile/${expert.id}?action=ask'),
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.chat_bubble_outline_rounded, size: 18, color: ZitlasTokens.hydrationTeal),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.expert, required this.radius});

  final ExpertListing expert;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: ZitlasTokens.sageGreen,
      backgroundImage: safeImageProvider(expert.image),
      onBackgroundImageError: expert.image != null ? (_, _) {} : null,
      child: expert.image == null || expert.image!.isEmpty
          ? Text(expert.initials, style: TextStyle(color: ZitlasTokens.primaryDark, fontWeight: FontWeight.w800, fontSize: radius * 0.6))
          : null,
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.text, this.iconColor});

  final IconData icon;
  final String text;

  /// Overrides the icon color — used for the star rating (Warm Yellow),
  /// left as the neutral default for experience/language chips.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: iconColor ?? ZitlasTokens.textMuted),
        const SizedBox(width: 3),
        Text(text, style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted)),
      ],
    );
  }
}

class _PriceChip extends StatelessWidget {
  const _PriceChip({required this.label, required this.price, required this.bg, required this.fg, this.border});

  final String label;
  final num price;
  final Color bg;
  final Color fg;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: border != null ? Border.all(color: border!) : null,
      ),
      child: Text('$label ₹$price', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: ZitlasTokens.textMuted),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
            const SizedBox(height: 4),
            Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary)),
          ],
        ),
      ),
    );
  }
}
