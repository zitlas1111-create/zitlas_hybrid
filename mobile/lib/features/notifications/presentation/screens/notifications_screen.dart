import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/notifications/notification_audience.dart';
import '../../../../core/theme/zitlas_tokens.dart';
import '../../../auth/auth_state.dart';
import '../../data/notifications_repository.dart';
import '../../models/app_notification.dart';

/// Native rebuild of `frontend/pages/notifications/` +
/// `assets/js/notification-center.js` — the real central activity feed,
/// replacing the placeholder. Renders whatever's in the `notifications`
/// collection (no fixed type enum, matching the website's own design:
/// "any feature — present or future — creates a notification by calling
/// ONE function"), with the exact `action`/`actionId` tap-routing table.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<AuthState>().profile;
    final uid = profile?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final repo = NotificationsRepository(firestore: FirebaseFirestore.instance);
    return _NotificationsBody(uid: uid, role: profile!.resolvedRole, repository: repo);
  }
}

class _NotificationsBody extends StatelessWidget {
  const _NotificationsBody({
    required this.uid,
    required this.role,
    required this.repository,
  });
  final String uid;

  /// `'athlete' | 'expert'` — the second half of role isolation. Documents
  /// are already scoped per-uid in Firestore, but a mis-targeted server push
  /// (or an event written for the wrong role) is contained here too rather
  /// than merely being unlikely.
  final String role;
  final NotificationsRepository repository;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgCard,
        elevation: 0.5,
        leading: IconButton(icon: const Icon(Icons.arrow_back, color: ZitlasTokens.textPrimary), onPressed: () => context.pop()),
        title: const Text('Notifications', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
        actions: [
          TextButton(
            onPressed: () => repository.markAllRead(uid),
            child: const Text('Mark all read', style: TextStyle(fontSize: 12.5, color: ZitlasTokens.primaryDark)),
          ),
        ],
      ),
      body: SafeArea(
        child: StreamBuilder<List<AppNotification>>(
          stream: repository.watchAll(uid),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator(color: ZitlasTokens.primary));
            }
            // An expert must never be shown a breakfast reminder, and an
            // athlete must never be shown "a client is waiting for a review".
            final items = snap.data!
                .where((n) => isForRole(n.type, role))
                .toList(growable: false);
            if (items.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.notifications_none_rounded, size: 44, color: ZitlasTokens.textMuted),
                      SizedBox(height: 12),
                      Text('No notifications yet', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
                      SizedBox(height: 4),
                      Text('Expert updates, chat replies, and reminders will show up here.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary)),
                    ],
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(14),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _NotificationTile(
                n: items[i],
                onTap: () => _handleTap(context, items[i]),
              ),
            );
          },
        ),
      ),
    );
  }

  void _handleTap(BuildContext context, AppNotification n) {
    if (!n.isRead) repository.markRead(n.id);
    // `navigateForAction()` (notification-center.js:145-157), ported 1:1.
    switch (n.action) {
      case 'diet':
        context.go('/diet');
        break;
      case 'training':
        context.go('/training');
        break;
      case 'dashboard':
        context.go('/dashboard');
        break;
      case 'coaches':
        context.go('/experts');
        break;
      case 'expert_profile':
        // Coach Profile browsing is the Website's cprofile.html in a WebView
        // (see CoachingWebViewScreen.coachProfile) — same screen a coach-card
        // tap on the Experts list opens, so a notification lands the same way.
        if (n.actionId != null) {
          context.push('/coach-profile/${n.actionId}');
        } else {
          context.go('/experts');
        }
        break;
      case 'chat':
        // Chat is part of the ONE continuous Website coaching session — opens
        // the same Coach Profile WebView with action=ask, which auto-opens the
        // website's own chat via its existing ?action= handling.
        if (n.actionId != null) {
          context.push('/coach-profile/${n.actionId}?action=ask');
        } else {
          context.go('/experts');
        }
        break;
      case 'expert_dashboard':
        // Coach side of Personal Coaching — now the Website module in a WebView.
        context.go('/expert-dashboard');
        break;
      case 'coaching_workspace':
        // Athlete side of Personal Coaching — the SAME Coach Profile WebView;
        // the website's own JS detects the active relationship and shows the
        // coaching workspace itself. actionId carries the coach id; without it
        // fall back to browse.
        if (n.actionId != null && n.actionId!.isNotEmpty) {
          context.push('/coach-profile/${n.actionId}');
        } else {
          context.go('/experts');
        }
        break;
      case 'profile':
        context.go('/profile');
        break;
      default:
        break; // no-op — stay on the Notification Center, matches web.
    }
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.n, required this.onTap});
  final AppNotification n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: n.isRead ? ZitlasTokens.bgCard : ZitlasTokens.primary.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(kZitlasRadiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(kZitlasRadiusMd),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kZitlasRadiusMd),
            border: Border.all(color: n.isRead ? ZitlasTokens.borderSub : ZitlasTokens.primary.withValues(alpha: 0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(n.displayIcon, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(n.title, style: TextStyle(fontSize: 13.5, fontWeight: n.isRead ? FontWeight.w600 : FontWeight.w800, color: ZitlasTokens.textPrimary)),
                    if (n.message.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(n.message, style: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary)),
                      ),
                    if (n.createdAt != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_timeAgo(n.createdAt!), style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted)),
                      ),
                  ],
                ),
              ),
              if (!n.isRead)
                Container(width: 8, height: 8, margin: const EdgeInsets.only(top: 4), decoration: const BoxDecoration(color: ZitlasTokens.primary, shape: BoxShape.circle)),
            ],
          ),
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
