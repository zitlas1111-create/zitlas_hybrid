import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/steps/presentation/step_consent_sheet.dart';
import '../../../../core/widgets/app_shell.dart';
import '../../../zino/tour/zino_tour_stops.dart';
import '../../../../core/steps/step_tracking_service.dart';
import '../../../../core/theme/zitlas_tokens.dart';
import '../../../auth/auth_state.dart';
import '../../../auth/sign_out_action.dart';
import '../../data/profile_repository.dart';
import '../../profile_controller.dart';
import '../widgets/language_modal.dart';

/// Native rebuild of `frontend/pages/profile/profile.html` + `profile.js` —
/// the Athlete Profile hub, replacing the Phase-1 placeholder. This page is
/// a navigation hub, not a data-heavy dashboard: avatar/name/badges, then
/// Account (Personal Information, Language, Membership & Billing), Quick
/// Actions (Edit Profile, Share Profile, Contact Support), and Log Out.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthState>().profile?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ChangeNotifierProvider<ProfileController>(
      key: ValueKey(uid),
      create: (_) => ProfileController(
        uid: uid,
        repository: ProfileRepository(firestore: FirebaseFirestore.instance, auth: FirebaseAuth.instance),
      ),
      child: const _ProfileBody(),
    );
  }
}

class _ProfileBody extends StatelessWidget {
  const _ProfileBody();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ProfileController>();
    final auth = context.watch<AuthState>().profile;
    final name = c.displayName(auth?.name ?? '');
    final photo = c.displayPhoto(auth?.photoUrl);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: ZitlasTokens.bgStart,
        body: Stack(
          children: [
            const ZitlasPremiumBackground(),
            SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                children: [
                  if (c.expertApplicationPending) const _ExpertAppliedBanner(),
                  KeyedSubtree(
                    key: ZinoTourKeys.profileHeader,
                    child: _Header(name: name, photo: photo, aiLabel: c.aiLabel(), isPremium: c.membership.isPremium),
                  ),
                  const SizedBox(height: 20),
                  _SectionCard(
                    title: 'Account',
                    children: [
                      _SettingsRow(
                        icon: Icons.person_outline_rounded,
                        label: 'Personal Information',
                        onTap: () => context.push('/profile/personal-info'),
                      ),
                      _SettingsRow(
                        icon: Icons.language_rounded,
                        label: 'Language',
                        onTap: () => showLanguageModal(context),
                      ),
                      _SettingsRow(
                        icon: Icons.credit_card_rounded,
                        label: 'Membership & Billing',
                        subtitle: 'Current Plan: ${c.membership.isPremium ? 'Premium' : 'Basic'}',
                        onTap: () => context.push('/membership'),
                      ),
                      // Second, always-available entry point to the step
                      // permission flow — the Dashboard prompt is easy to
                      // dismiss, and someone who tapped "Not Now" needs a way
                      // back that isn't a nag.
                      const _StepTrackingRow(),
                      _SettingsRow(
                        icon: Icons.notifications_none_rounded,
                        label: 'Notifications',
                        subtitle: "Zino's daily reminders",
                        onTap: () => context.push('/profile/notifications'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _SectionCard(
                    title: 'Quick Actions',
                    children: [
                      _SettingsRow(
                        icon: Icons.edit_outlined,
                        label: 'Edit Profile',
                        onTap: () => context.push('/profile/personal-info'),
                      ),
                      _SettingsRow(
                        icon: Icons.share_outlined,
                        label: 'Share Profile',
                        onTap: () => _shareProfile(name),
                      ),
                      _SettingsRow(
                        icon: Icons.help_outline_rounded,
                        label: 'Contact Support',
                        onTap: () => context.push('/profile/help-support'),
                      ),
                      // Manual replay. Deliberately does NOT reset
                      // `zinoTourCompleted` — replaying the walkthrough must
                      // never turn an existing athlete back into a "new user"
                      // who'd be auto-toured again on the next login.
                      _SettingsRow(
                        icon: Icons.auto_awesome_outlined,
                        label: 'Take Zino Tour Again',
                        subtitle: 'Replay the quick walkthrough',
                        onTap: () {
                          final host = ZinoTourHost.maybeOf(context);
                          final tourUid = auth?.uid;
                          if (host == null || tourUid == null) return;
                          host.startTour(tourUid);
                        },
                      ),
                      // Admin-only: certificate review console. Renders ONLY
                      // for users carrying the backend `admin` custom claim
                      // (invisible to everyone else), mirroring the website
                      // where the admin pages are reachable by admins only.
                      const _AdminConsoleRow(),
                    ],
                  ),
                  const SizedBox(height: 28),
                  _LogoutButton(onConfirm: () => performSignOut(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _shareProfile(String name) {
    SharePlus.instance.share(
      ShareParams(
        subject: 'My ZITLAS Weight-Loss Profile',
        text: 'Check out my ZITLAS Weight-Loss Profile! | Pune, India',
      ),
    );
  }
}

class _ExpertAppliedBanner extends StatelessWidget {
  const _ExpertAppliedBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZitlasTokens.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(kZitlasRadiusMd),
        border: Border.all(color: ZitlasTokens.primary.withValues(alpha: 0.3)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('⏳', style: TextStyle(fontSize: 20)),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Application Under Review', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
                SizedBox(height: 2),
                Text(
                  'Your application has already been submitted and is under review. We will notify you via email.',
                  style: TextStyle(fontSize: 11.5, color: ZitlasTokens.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.name, required this.photo, required this.aiLabel, required this.isPremium});
  final String name;
  final String? photo;
  final String aiLabel;
  final bool isPremium;

  @override
  Widget build(BuildContext context) {
    final initials = name.trim().isEmpty
        ? 'ZT'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w.isEmpty ? '' : w[0]).join().toUpperCase();

    return Column(
      children: [
        const SizedBox(height: 16),
        SizedBox(
          width: 110,
          height: 110,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: ZitlasTokens.primary.withValues(alpha: 0.35), width: 2),
                  ),
                ),
              ),
              Positioned(
                left: 3,
                top: 3,
                right: 3,
                bottom: 3,
                child: Builder(builder: (context) {
                  final img = (photo != null && photo!.isNotEmpty) ? _avatarImage(photo!) : null;
                  return CircleAvatar(
                    backgroundColor: ZitlasTokens.primary.withValues(alpha: 0.15),
                    backgroundImage: img,
                    child: img == null
                        ? Text(initials, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: ZitlasTokens.primaryDark))
                        : null,
                  );
                }),
              ),
              // `.avatar-edit-btn` on the website has no click handler at all
              // (verified against profile.js) — decorative-only, faithfully
              // reproduced as non-interactive rather than inventing a native
              // photo picker on THIS screen (the real one lives on Personal
              // Information / Edit Profile).
              Positioned(
                bottom: 3,
                right: 3,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: const BoxDecoration(color: ZitlasTokens.primary, shape: BoxShape.circle),
                  child: const Icon(Icons.edit, size: 13, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: ZitlasTokens.primary.withValues(alpha: 0.1),
            border: Border.all(color: ZitlasTokens.primary.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            aiLabel.toUpperCase(),
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.5, color: ZitlasTokens.primaryDark),
          ),
        ),
        const SizedBox(height: 10),
        Text(name.isEmpty ? ' ' : name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          alignment: WrapAlignment.center,
          children: [
            _Pill(
              icon: isPremium ? Icons.star_rounded : Icons.circle_outlined,
              label: isPremium ? 'Premium Member' : 'Basic Member',
              accent: true,
            ),
            // `.location-badge` is a static "Pune, India" in the website's
            // HTML — never overwritten by profile.js for any user. Kept
            // exactly as-is rather than "fixed" to be dynamic.
            const _Pill(icon: Icons.location_on_outlined, label: 'Pune, India', accent: false),
          ],
        ),
      ],
    );
  }

  ImageProvider? _avatarImage(String photo) {
    if (photo.startsWith('data:')) {
      try {
        return MemoryImage(base64Decode(photo.split(',').last));
      } catch (_) {
        return null;
      }
    }
    if (photo.startsWith('http')) return NetworkImage(photo);
    return null;
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, required this.accent});
  final IconData icon;
  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: accent ? ZitlasTokens.primary.withValues(alpha: 0.1) : ZitlasTokens.bgCard,
        border: Border.all(color: accent ? ZitlasTokens.primary.withValues(alpha: 0.3) : ZitlasTokens.borderSub),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: accent ? ZitlasTokens.primaryDark : ZitlasTokens.textSecondary),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 12.5, color: accent ? ZitlasTokens.primaryDark : ZitlasTokens.textSecondary)),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 2),
          child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary)),
        ),
        Container(
          decoration: BoxDecoration(
            color: ZitlasTokens.bgCard,
            border: Border.all(color: ZitlasTokens.borderSub),
            borderRadius: BorderRadius.circular(kZitlasRadiusMd),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    );
  }
}

/// Profile → Activity / Step Tracking → Enable.
///
/// Reflects the CURRENT state rather than always saying "Enable", so someone
/// who already granted it sees that and isn't invited to re-grant.
class _StepTrackingRow extends StatefulWidget {
  const _StepTrackingRow();

  @override
  State<_StepTrackingRow> createState() => _StepTrackingRowState();
}

class _StepTrackingRowState extends State<_StepTrackingRow> {
  late StepTrackingService _service = StepTrackingService();

  @override
  Widget build(BuildContext context) {
    final enabled = _service.isEnabled;
    return _SettingsRow(
      icon: Icons.directions_walk_rounded,
      label: 'Step Tracking',
      subtitle: enabled ? 'Enabled' : 'Track your daily activity',
      onTap: enabled
          ? null
          : () async {
              await showStepConsentSheet(context, service: _service);
              if (mounted) setState(() => _service = StepTrackingService());
            },
    );
  }
}

/// Certificate-review entry, shown ONLY to users with the backend `admin`
/// custom claim — invisible to every normal user (renders nothing), matching
/// the website where the admin console is admin-reachable only. The claim is
/// authoritative and not client-forgeable (backend-set); the destination
/// screen re-checks it too, so this row is convenience, not the gate.
class _AdminConsoleRow extends StatefulWidget {
  const _AdminConsoleRow();

  @override
  State<_AdminConsoleRow> createState() => _AdminConsoleRowState();
}

class _AdminConsoleRowState extends State<_AdminConsoleRow> {
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final res = await user.getIdTokenResult();
      if (mounted && res.claims?['admin'] == true) setState(() => _isAdmin = true);
    } catch (_) {
      // No claim / offline — stay hidden. Never surface admin UI on doubt.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAdmin) return const SizedBox.shrink();
    return _SettingsRow(
      icon: Icons.verified_user_outlined,
      label: 'Certificate Review',
      subtitle: 'Admin — approve or reject expert certificates',
      onTap: () => context.push('/admin'),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.icon, required this.label, required this.onTap, this.subtitle});
  final IconData icon;
  final String label;
  final String? subtitle;

  /// Nullable so a row can render in a settled state (e.g. Step Tracking once
  /// it's already enabled) without inviting a pointless re-tap.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: ZitlasTokens.borderSub))),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: ZitlasTokens.bgCardLight,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: ZitlasTokens.borderSub),
              ),
              child: Icon(icon, size: 17, color: ZitlasTokens.textSecondary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZitlasTokens.textPrimary)),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(subtitle!, style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted)),
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: ZitlasTokens.textMuted),
          ],
        ),
      ),
    );
  }
}

class _LogoutButton extends StatelessWidget {
  const _LogoutButton({required this.onConfirm});
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kZitlasRadiusMd)),
          side: const BorderSide(color: ZitlasTokens.primary, width: 1.5),
        ),
        icon: const Icon(Icons.logout_rounded, size: 18, color: ZitlasTokens.primaryDark),
        label: const Text('Log Out', style: TextStyle(color: ZitlasTokens.primaryDark, fontWeight: FontWeight.w700, fontSize: 15)),
        onPressed: () => _confirmLogout(context),
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ZitlasTokens.bgCard,
        icon: const Icon(Icons.logout_rounded, size: 36, color: ZitlasTokens.primary),
        title: const Text('Log Out?', textAlign: TextAlign.center),
        content: const Text('You will be logged out of your ZITLAS account.', textAlign: TextAlign.center),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Log Out', style: TextStyle(color: ZitlasTokens.danger))),
        ],
      ),
    );
    if (confirmed == true) onConfirm();
  }
}
