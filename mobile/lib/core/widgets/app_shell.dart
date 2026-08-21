import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../features/auth/auth_state.dart';
import '../notifications/notification_onboarding.dart';
import '../notifications/presentation/notification_consent_sheet.dart';
import '../../features/zino/presentation/widgets/zino_fab.dart';
import '../../features/zino/tour/zino_tour_controller.dart';
import '../../features/zino/tour/zino_tour_overlay.dart';
import '../../features/zino/tour/zino_tour_stops.dart';
import '../../features/zino/tour/zino_tour_store.dart';

/// Bottom-nav shell for the 5 primary tabs, mirroring `components/navbar.js`
/// on web (Home / Diet / Training / Experts / Profile). Wrapped around the
/// active branch by a `StatefulShellRoute.indexedStack` in `app/router.dart`
/// so each tab keeps its own navigation stack.
///
/// Also the single host for the two always-on Zino surfaces: the top-right
/// launcher and the first-run walkthrough. Both live here rather than on each
/// screen so they're guaranteed consistent across every tab.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.navigationShell,
  });

  final StatefulNavigationShell navigationShell;

  static const _tabs = [
    (icon: Icons.home_rounded, label: 'Home'),
    (icon: Icons.restaurant_menu_rounded, label: 'Diet'),
    (icon: Icons.fitness_center_rounded, label: 'Training'),
    (icon: Icons.groups_rounded, label: 'Experts'),
    (icon: Icons.person_rounded, label: 'Profile'),
  ];

  /// Branch index -> the `?from=` value Zino uses to anchor ambiguous
  /// questions. Order matches [_tabs] and the router's branch order.
  static const _zinoContextForBranch = [
    'dashboard',
    'diet',
    'training',
    'experts',
    'profile',
  ];

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  ZinoTourController? _tour;
  String? _tourUid;

  /// Tabs the athlete visited before the current one, most recent last.
  ///
  /// `StatefulShellRoute` gives each branch its own navigator, but switching
  /// BETWEEN branches records nothing — neither `goBranch()` (bottom nav) nor
  /// a cross-tab `context.go('/training')` (the Training card, the Profile
  /// avatar, the Experts promo) leaves anything to pop. So a back press on
  /// any tab other than the one you launched into had no route to return to
  /// and fell straight through to the exit confirmation, which is the
  /// reported "back jumps to the warning" bug.
  ///
  /// This is the missing history. Back now walks it one tab at a time, and
  /// the exit confirmation is reached only once it is empty — i.e. the
  /// athlete really is back where they started.
  final List<int> _tabHistory = [];

  /// Set while [_goBackToPreviousTab] drives the change, so the branch we are
  /// returning TO is not re-recorded as somewhere we came FROM (which would
  /// bounce between two tabs forever).
  bool _navigatingBack = false;

  late int _branchIndex = widget.navigationShell.currentIndex;

  /// Deep enough for any realistic session, bounded so a long browse cannot
  /// grow it without limit.
  static const _maxTabHistory = 20;

  @override
  void didUpdateWidget(AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _recordBranchChange();
  }

  /// Records a tab change however it was triggered — bottom nav, a
  /// cross-tab `context.go(...)`, or a notification deep link. Watching the
  /// shell's own `currentIndex` catches all of them; hooking only the
  /// bottom-nav `onTap` would miss the `context.go` callers entirely.
  void _recordBranchChange() {
    final current = widget.navigationShell.currentIndex;
    if (current == _branchIndex) return;

    if (!_navigatingBack) {
      _tabHistory.add(_branchIndex);
      if (_tabHistory.length > _maxTabHistory) _tabHistory.removeAt(0);
    }
    _branchIndex = current;
    _navigatingBack = false;
  }

  /// The root tab. Back may only offer to exit from here.
  static const _homeBranch = 0;

  /// True when back had somewhere to go. Never touches the exit dialog.
  bool _goBackToPreviousTab() {
    if (_tabHistory.isEmpty) return false;
    final previous = _tabHistory.removeLast();
    _navigatingBack = true;
    _branchIndex = previous;
    widget.navigationShell.goBranch(previous);
    return true;
  }

  /// Last resort before the exit dialog: from ANY non-root tab, back goes to
  /// Home.
  ///
  /// THE BUG THIS FIXES. Tab history is empty whenever the athlete did not
  /// arrive at this tab by tapping through the bottom bar — a notification
  /// deep link straight to /diet, a cross-tab `context.go`, or simply
  /// exhausting the recorded history. Back then fell straight through to
  /// "Exit ZITLAS?" while the athlete was staring at Diet or Profile, which is
  /// the exit prompt appearing where it should not.
  ///
  /// With this, the exit dialog is reachable from exactly one place: Home with
  /// nothing left to pop. Every other back press moves the athlete one step
  /// closer to Home, which is what a modern app does.
  bool _goHomeBranch() {
    if (_branchIndex == _homeBranch) return false;
    _navigatingBack = true;   // do not record Home as a forward step
    _branchIndex = _homeBranch;
    widget.navigationShell.goBranch(_homeBranch);
    return true;
  }

  /// In-session latch. Both the "no tour" and "tour finished" paths can fire,
  /// and an account switch re-runs [_initTourFor] — without this the sheet
  /// could be pushed twice.
  bool _askedAboutNotifications = false;

  /// Tour screen -> nav branch index, so advancing the walkthrough moves the
  /// athlete through the real app the way the website navigated between pages.
  static const _branchForTourScreen = {
    ZinoTourScreen.dashboard: 0,
    ZinoTourScreen.diet: 1,
    ZinoTourScreen.training: 2,
    ZinoTourScreen.experts: 3,
    ZinoTourScreen.profile: 4,
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthState>().profile?.uid;
    if (uid == null || uid == _tourUid) return;
    _tourUid = uid;
    _initTourFor(uid);
  }

  Future<void> _initTourFor(String uid) async {
    final controller = ZinoTourController(
      uid: uid,
      store: ZinoTourStore(firestore: FirebaseFirestore.instance),
    )..addListener(_onTourChanged);
    // Only ever starts for an account that has verifiably never completed or
    // skipped it — see ZinoTourStore.shouldAutoStart, which fails CLOSED.
    final started = await controller.startIfNewUser();
    if (!mounted) {
      controller.dispose();
      return;
    }
    if (started) {
      setState(() => _tour = controller);
      _syncBranchToTour();
    } else {
      controller.dispose();
      // Returning athlete: no walkthrough to wait behind, so the notification
      // ask (if it's still owed) can happen right away.
      unawaited(_maybeAskAboutNotifications());
    }
  }

  void _onTourChanged() {
    if (!mounted) return;
    final tour = _tour;
    if (tour != null && !tour.isRunning) {
      // Finished or skipped — drop the overlay and leave the athlete on the
      // tab they ended on.
      setState(() => _tour = null);
      tour.removeListener(_onTourChanged);
      tour.dispose();
      // Deliberately AFTER the walkthrough rather than at launch: a new user
      // who has just been shown what Zino does understands what the reminders
      // are for, and a permission sheet stacked on the tour spotlight would
      // block the very thing it's explaining.
      unawaited(_maybeAskAboutNotifications());
      return;
    }
    setState(() {});
    _syncBranchToTour();
  }

  /// Moves the visible tab to whatever the current stop describes.
  void _syncBranchToTour() {
    final tour = _tour;
    if (tour == null || !tour.isRunning) return;
    final target = _branchForTourScreen[tour.current.screen];
    if (target == null || target == widget.navigationShell.currentIndex) return;
    widget.navigationShell.goBranch(target);
  }

  /// One-time notification ask, guarded by [NotificationOnboarding] so a
  /// returning athlete is never re-pitched and Android's single-shot system
  /// dialog isn't spent before the user knows what it's for.
  Future<void> _maybeAskAboutNotifications() async {
    if (_askedAboutNotifications) return;
    _askedAboutNotifications = true;
    const onboarding = NotificationOnboarding();
    if (!await onboarding.shouldPrompt()) return;
    if (!mounted) return;
    await showNotificationConsentSheet(context, onboarding: onboarding);
  }

  /// Entry point for Profile -> "Take Zino Tour Again". Replaying never
  /// changes the athlete's completed status back to "new".
  void startTourManually(String uid) {
    _tour?.removeListener(_onTourChanged);
    _tour?.dispose();
    final controller = ZinoTourController(
      uid: uid,
      store: ZinoTourStore(firestore: FirebaseFirestore.instance),
    )..addListener(_onTourChanged);
    controller.startManually();
    setState(() => _tour = controller);
    _syncBranchToTour();
  }

  @override
  void dispose() {
    _tour?.removeListener(_onTourChanged);
    _tour?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final from = AppShell._zinoContextForBranch[widget.navigationShell.currentIndex
        .clamp(0, AppShell._zinoContextForBranch.length - 1)];
    final tour = _tour;

    // THE ONLY back-press confirmation in ZITLAS. This widget hosts the 5
    // primary tabs — the app ROOT — so a back press that reaches here has
    // nothing left to pop and the next one would terminate the app.
    //
    // It deliberately does NOT fire for ordinary navigation, which is why no
    // other screen needs to know it exists:
    //   * a page pushed INSIDE a tab pops on that branch's navigator;
    //   * a full-screen route declared OUTSIDE the shell (/coach-profile,
    //     /zino, /chat, /notifications, /expert-dashboard…) sits ABOVE this
    //     shell page on the ROOT navigator and pops itself.
    // In both cases the deeper route handles the pop and this callback is never
    // reached — so closing the Coach Profile WebView, or any other screen,
    // shows no warning at all.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        // Reaching here means the active tab's own navigator had nothing
        // left to pop. Before treating that as "leaving the app", walk back
        // through the tabs the athlete actually visited — that history is
        // what the branch navigators cannot represent.
        if (_goBackToPreviousTab()) return;
        // Still not Home? Go there. The exit dialog belongs to the root tab
        // alone — see _goHomeBranch.
        if (_goHomeBranch()) return;
        // Genuinely at the start: Home, no page to pop, no earlier tab.
        await _confirmExitApp();
      },
      child: ZinoTourHost(
        startTour: startTourManually,
        child: Stack(
          children: [
            Scaffold(
              // Zino rides along on every primary tab, matching the website where
              // `zino.js` self-mounts its FAB on every page — the athlete can ask
              // a question from wherever they are, and Zino knows where that was.
              //
              // TOP-RIGHT, not a bottom FAB: that placement is part of the ZITLAS
              // design (`.zn-fab { top: …; right: 16px }`), so it is preserved
              // rather than converted to the usual Android bottom-right
              // convention.
              body: ZinoFabOverlay(
                onTap: () => context.push('/zino?from=$from'),
                child: widget.navigationShell,
              ),
              bottomNavigationBar: BottomNavigationBar(
                currentIndex: widget.navigationShell.currentIndex,
                onTap: (index) => widget.navigationShell.goBranch(
                  index,
                  initialLocation: index == widget.navigationShell.currentIndex,
                ),
                items: [
                  for (final tab in AppShell._tabs)
                    BottomNavigationBarItem(icon: Icon(tab.icon), label: tab.label),
                ],
              ),
            ),
            // Above the Scaffold (including the nav bar) so the walkthrough
            // scrim genuinely blocks interaction with a half-explained screen.
            if (tour != null) ZinoTourOverlay(controller: tour),
          ],
        ),
      ),
    );
  }

  /// "Exit ZITLAS?" — shown ONLY when back would terminate the app.
  ///
  /// Latched so repeated back presses cannot stack dialogs. Exit uses
  /// SystemNavigator.pop(), which closes the app the way the OS expects rather
  /// than killing the process.
  bool _exitDialogOpen = false;

  Future<void> _confirmExitApp() async {
    if (_exitDialogOpen || !mounted) return;
    _exitDialogOpen = true;
    try {
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(
            'Exit ZITLAS?',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          content: const Text(
            'You’re at the start of the app. Going back again will close ZITLAS.',
            style: TextStyle(fontSize: 13, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Exit', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      );
      if (leave == true) await SystemNavigator.pop();
    } finally {
      _exitDialogOpen = false;
    }
  }
}

/// Exposes "replay the tour" to descendants (Profile) without a global.
class ZinoTourHost extends InheritedWidget {
  const ZinoTourHost({super.key, required this.startTour, required super.child});

  final void Function(String uid) startTour;

  static ZinoTourHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ZinoTourHost>();

  @override
  bool updateShouldNotify(ZinoTourHost oldWidget) => false;
}
