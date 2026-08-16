import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/presence/presence_dot.dart';
import '../../../../core/theme/zitlas_tokens.dart';
import '../../../auth/auth_state.dart';
import '../../data/expert_repository.dart';
import '../../expert_dashboard_controller.dart';
import '../../models/expert_models.dart';
import '../sections/chats_section.dart';
import '../sections/coaching_section.dart';
import '../sections/dashboard_section.dart';
import '../sections/profile_section.dart';
import '../sections/reviews_section.dart';
import '../widgets/expert_account_sheet.dart';
import '../widgets/expert_common.dart';
import 'athlete_profile_screen.dart';
import 'expert_chat_screen.dart';
import 'review_diet_editor_screen.dart';
import 'review_workout_editor_screen.dart';

/// Native rebuild of `frontend/pages/experts/expert-dashboard.html` +
/// `expert-dashboard.js` — the real ZITLAS Expert Portal, replacing the
/// former placeholder screen.
///
/// Structure mirrors the website 1:1: a fixed header (avatar, name/role,
/// online dot, notification bell, logout) over five bottom-nav sections
/// (Dashboard / Reviews / Coaching / Chats / Profile) with live count
/// badges on Reviews and Coaching.
class ExpertDashboardScreen extends StatelessWidget {
  const ExpertDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<AuthState>().profile;
    final uid = profile?.uid;

    if (uid == null) {
      return const Scaffold(
        backgroundColor: ZitlasTokens.bgStart,
        body: Center(child: CircularProgressIndicator(color: ZitlasTokens.primary)),
      );
    }

    return ChangeNotifierProvider<ExpertDashboardController>(
      key: ValueKey(uid),
      create: (_) => ExpertDashboardController(
        uid: uid,
        repository: ExpertRepository(
          firestore: FirebaseFirestore.instance,
          auth: FirebaseAuth.instance,
        ),
        authName: profile?.name,
        authEmail: profile?.email,
        authPhoto: profile?.photoUrl,
      ),
      child: const _ExpertDashboardBody(),
    );
  }
}

class _ExpertDashboardBody extends StatefulWidget {
  const _ExpertDashboardBody();

  @override
  State<_ExpertDashboardBody> createState() => _ExpertDashboardBodyState();
}

class _ExpertDashboardBodyState extends State<_ExpertDashboardBody> {
  int _section = 0;

  void _go(int index) => setState(() => _section = index);

  /// Opens a chat thread. Chat room ids on the website are inconsistent
  /// (`chat_<athleteId>_<expertId>`, a review's own `chatId`, or the bare
  /// expert uid) — we resolve in that documented order so existing threads
  /// created by the web app are found rather than duplicated.
  void _openChat({
    required String chatId,
    required String athleteId,
    required String athleteName,
  }) {
    final c = context.read<ExpertDashboardController>();
    final expert = c.profile;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExpertChatScreen(
          repository: c.repository,
          chatId: chatId,
          expertId: c.uid,
          expertName: expert?.name ?? 'Expert',
          athleteId: athleteId,
          athleteName: athleteName,
          readOnly: c.isChatReadOnly(athleteId),
        ),
      ),
    );
  }

  void _openReviewChat(ReviewRequest r) {
    final c = context.read<ExpertDashboardController>();
    _openChat(
      chatId: r.chatId ?? c.uid,
      athleteId: r.userId ?? '',
      athleteName: r.displayName,
    );
  }

  void _openCoachingChat(CoachingRequest req) {
    final athleteId = req.athleteId ?? '';
    _openChat(
      chatId: 'chat_${athleteId}_${req.expertId ?? context.read<ExpertDashboardController>().uid}',
      athleteId: athleteId,
      athleteName: req.athleteName ?? 'Athlete',
    );
  }

  void _openAthlete(CoachingRelationship rel) {
    final c = context.read<ExpertDashboardController>();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AthleteProfileScreen(
          repository: c.repository,
          athleteId: rel.athleteId ?? '',
          athleteName: rel.athleteName ?? 'Athlete',
          // Passing the coach's identity turns the profile from a read-only
          // summary into the coaching workspace: it can now open the plan
          // editors and own the private notes.
          coachId: c.uid,
          coachName: c.profile?.name ?? 'Your coach',
          planType: rel.planType ?? 'complete',
        ),
      ),
    );
  }

  /// Opens the plan editor and RETURNS the push future, so the caller can keep
  /// the review's buttons disabled until the editor actually closes.
  ///
  /// Returning early (rather than awaiting nothing) is what lets
  /// `ExpertReviewsSection` guarantee only one editor exists per review.
  /// Completion happens inside the editor; this deliberately performs no
  /// navigation of its own afterwards — popping the editor returns to this
  /// dashboard, which is the only correct destination.
  Future<void> _openReviewEditor(ReviewRequest r) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => r.reviewType == 'workout'
            ? ReviewWorkoutEditorScreen(reviewId: r.id)
            : ReviewDietEditorScreen(reviewId: r.id),
      ),
    );
  }

  void _openRoom(ChatRoom room) {
    _openChat(
      chatId: room.id,
      athleteId: room.athleteId ?? '',
      athleteName: room.displayName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ExpertDashboardController>();

    final sections = [
      ExpertDashboardSection(
        onOpenReviews: () => _go(1),
        onOpenChats: () => _go(3),
        onOpenAthlete: _openAthlete,
      ),
      ExpertReviewsSection(onOpenChat: _openReviewChat, onEditPlan: _openReviewEditor),
      ExpertCoachingSection(onOpenChat: _openCoachingChat),
      ExpertChatsSection(onOpenRoom: _openRoom),
      const ExpertProfileSection(),
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: ZitlasTokens.bgStart,
        body: Stack(
          children: [
            const ZitlasPremiumBackground(),
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  const _ExpertHeader(),
                  Expanded(child: sections[_section]),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: _ExpertNavBar(
          index: _section,
          onChanged: _go,
          reviewsBadge: c.navBadgeReviews,
          coachingBadge: c.navBadgeCoaching,
        ),
      ),
    );
  }
}

/// `.ed-header` — avatar + name/role on the left, online state,
/// notification bell with live unread badge, and the account menu.
class _ExpertHeader extends StatelessWidget {
  const _ExpertHeader();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ExpertDashboardController>();
    final p = c.profile;

    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: Color(0xD9F4F7ED),
        border: Border(bottom: BorderSide(color: ZitlasTokens.borderSub)),
      ),
      child: Row(
        children: [
          EdAvatar(name: p?.name ?? 'Expert', size: 38, photoUrl: p?.photo),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p?.firstName ?? 'Expert',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: ZitlasTokens.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  p?.specialization ?? 'Expert',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: ZitlasTokens.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          // Derived from a live heartbeat, not from the stored flag. The
          // previous `p?.isOnline ?? true` painted this green even with no
          // profile loaded at all — it could not report anything else.
          if (p != null)
            PresenceBuilder(
              uid: p.uid,
              builder: (context, presence) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 5),
                    decoration: BoxDecoration(
                      color: presence.isOnline
                          ? ZitlasTokens.success
                          : ZitlasTokens.textMuted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Text(
                    presence.isOnline ? 'Online' : 'Offline',
                    style: const TextStyle(
                      color: ZitlasTokens.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(width: 4),
          _HeaderIconButton(
            icon: Icons.notifications_none_rounded,
            badge: c.unreadNotifications,
            tooltip: 'Notifications',
            onTap: () => context.push('/notifications'),
          ),
          _HeaderIconButton(
            icon: Icons.account_circle_outlined,
            tooltip: 'Account',
            onTap: () => showExpertAccountSheet(context),
          ),
        ],
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, size: 21, color: ZitlasTokens.textPrimary),
              if (badge > 0)
                Positioned(
                  top: 7,
                  right: 7,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 15),
                    decoration: BoxDecoration(
                      color: ZitlasTokens.danger,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: ZitlasTokens.bgStart, width: 1.5),
                    ),
                    child: Text(
                      badge > 9 ? '9+' : '$badge',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.ed-navbar` — the expert portal's own 5-item bottom nav (distinct from
/// the athlete `AppShell` nav), with live badges on Reviews and Coaching.
class _ExpertNavBar extends StatelessWidget {
  const _ExpertNavBar({
    required this.index,
    required this.onChanged,
    required this.reviewsBadge,
    required this.coachingBadge,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final int reviewsBadge;
  final int coachingBadge;

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.dashboard_outlined, Icons.dashboard_rounded, 'Dashboard'),
      (Icons.description_outlined, Icons.description_rounded, 'Reviews'),
      (Icons.groups_outlined, Icons.groups_rounded, 'Coaching'),
      (Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, 'Chats'),
      (Icons.person_outline_rounded, Icons.person_rounded, 'Profile'),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: ZitlasTokens.bgCard,
        border: Border(top: BorderSide(color: ZitlasTokens.borderSub)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onChanged(i),
                    child: _NavItem(
                      icon: i == index ? items[i].$2 : items[i].$1,
                      label: items[i].$3,
                      active: i == index,
                      badge: i == 1 ? reviewsBadge : (i == 2 ? coachingBadge : 0),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.badge,
  });

  final IconData icon;
  final String label;
  final bool active;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final color = active ? ZitlasTokens.primary : ZitlasTokens.textMuted;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(icon, size: 21, color: color),
            if (badge > 0)
              Positioned(
                top: -4,
                right: -8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  constraints: const BoxConstraints(minWidth: 15),
                  decoration: BoxDecoration(
                    color: ZitlasTokens.danger,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    badge > 9 ? '9+' : '$badge',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 9.5,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
