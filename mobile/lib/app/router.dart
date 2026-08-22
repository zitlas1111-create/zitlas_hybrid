import 'package:flutter/foundation.dart' show Listenable, debugPrint, kDebugMode;
// widgets.dart (not material.dart): this file only needs Widget and the fade
// primitives for the transparent WebView page below, no Material components.
import 'package:flutter/widgets.dart' show Curves, CurvedAnimation, FadeTransition, Widget;
import 'package:go_router/go_router.dart';

import '../core/notifications/notification_router.dart' show rootNavigatorKey;
import '../core/widgets/app_shell.dart';
import '../features/admin/presentation/screens/admin_screen.dart';
import '../features/ai_coach/presentation/screens/ai_coach_screen.dart';
import '../features/assessment/presentation/screens/assessment_screen.dart';
import '../features/auth/auth_state.dart';
import '../features/auth/presentation/screens/expert_application_review_screen.dart';
import '../features/auth/presentation/screens/login_screen.dart';
import '../features/auth/presentation/screens/splash_screen.dart';
import '../features/chat/presentation/screens/chat_screen.dart';
import '../features/coaching_webview/coaching_webview_screen.dart';
import '../features/dashboard/presentation/screens/dashboard_screen.dart';
import '../features/diet/presentation/screens/diet_screen.dart';
import '../features/diet/presentation/screens/creator_profile_screen.dart';
import '../features/diet/presentation/screens/creator_recipe_screen.dart';
import '../features/diet/presentation/screens/recipe_screen.dart';
// NOTE: ExpertDashboardScreen (native coach dashboard) is intentionally NOT
// imported — /expert-dashboard now renders CoachingWebViewScreen. The native
// screen stays in the tree, dormant, for the eventual return to native parity.
import '../features/experts/presentation/screens/expert_profile_screen.dart';
import '../features/experts/presentation/screens/experts_screen.dart';
import '../features/health/presentation/screens/step_history_route.dart';
import '../features/membership/presentation/screens/membership_screen.dart';
import '../features/notifications/presentation/screens/notifications_screen.dart';
import '../features/payments/presentation/screens/wallet_screen.dart';
import '../features/profile/presentation/screens/help_support_screen.dart';
import '../features/profile/presentation/screens/notification_settings_screen.dart';
import '../features/profile/presentation/screens/personal_info_screen.dart';
import '../features/profile/presentation/screens/profile_screen.dart';
import '../features/reviews/presentation/screens/reviews_screen.dart';
import '../features/workout/presentation/screens/workout_screen.dart';
import '../features/zino/data/zino_context_builder.dart';
import '../features/zino/presentation/screens/zino_screen.dart';
import 'splash_gate.dart';

/// Routing foundation. The 5 bottom-nav tabs (matching `components/navbar.js`
/// on web) live under a [StatefulShellRoute] so each tab keeps its own back
/// stack; everything else is a flat top-level route for now — see
/// docs/MIGRATION_INVENTORY.md §2 for which web page maps to which route,
/// and §6 for what's deliberately not wired up yet (real screens, nested
/// feature navigation, role-gating).
/// Routes that belong to the ATHLETE experience only. An expert reaching one of
/// these has been mis-routed (a stale deep link, a notification, or a fallback
/// that assumed the athlete dashboard), so the redirect sends them to their own
/// dashboard instead of silently downgrading their role.
///
/// Deliberately narrow: it lists the athlete tabs and their sub-pages, NOT
/// shared surfaces an expert legitimately uses (/notifications, /profile,
/// /chat, /zino, /wallet, /coach-profile, /experts…), and NOT /under-review,
/// which an authenticated pending expert lands on on purpose.
const _athleteOnlyRoutes = <String>[
  '/dashboard',
  '/diet',
  '/training',
  '/assessment',
  '/ai-coach',
  '/activity',
];

GoRouter buildRouter(AuthState authState) {
  return GoRouter(
    // Shared with NotificationRouter, which needs a BuildContext to navigate
    // from an FCM callback (which arrives from outside the widget tree).
    navigatorKey: rootNavigatorKey,
    initialLocation: '/splash',
    // Merged so BOTH inputs to "may we leave the splash yet?" re-trigger the
    // redirect: the auth status resolving, and the splash's minimum duration
    // elapsing. A bare timer would otherwise never re-evaluate the redirect.
    refreshListenable: Listenable.merge([authState, SplashGate.instance]),
    redirect: (context, state) {
      final status = authState.status;
      final loc = state.matchedLocation;
      final onSplash = loc == '/splash';
      final onLogin = loc == '/login';

      // Stay on the branded splash until BOTH are true:
      //   * Firebase's persisted-session check has resolved (so an
      //     already-signed-in user never flashes /login first), and
      //   * the splash's short minimum has elapsed (so a fast startup doesn't
      //     flicker the logo for two frames).
      // Whichever finishes last releases the app — see SplashGate.
      if (status == AuthStatus.unknown || !SplashGate.instance.isReady) {
        return onSplash ? null : '/splash';
      }

      final signedIn = status == AuthStatus.authenticated;
      if (!signedIn) {
        // Covers both unauthenticated and firebaseUnavailable — both route
        // to the login screen (which shows why sign-in is disabled for the
        // latter, see docs/MIGRATION_INVENTORY.md §4).
        return onLogin ? null : '/login';
      }

      // Role comes from the authoritative profile (users/{uid} -> roles /
      // expert_status / role, the SAME algorithm login.js uses — see
      // UserModel.isExpert). Never from an email, a cached role, or a default.
      final role = authState.profile?.resolvedRole;
      final isExpert = role == 'expert';

      // Signed in: leave the splash/login screens for the correct
      // dashboard by role. Every other route (including /under-review,
      // which an authenticated pending-expert lands on deliberately) is
      // left alone — this is what prevents redirect loops.
      if (onSplash || onLogin) {
        final dest = isExpert ? '/expert-dashboard' : '/dashboard';
        if (kDebugMode) {
          debugPrint('[AUTH ROUTING] uid=${authState.profile?.uid} '
              'roleSource=users/{uid}(roles|expert_status|role) role=$role -> $dest');
        }
        return dest;
      }

      // An EXPERT must never sit inside the athlete shell. Without this, any
      // path that lands on an athlete tab — a stale deep link, a
      // notification, or a fallback that assumed '/dashboard' — silently
      // downgrades an expert into the athlete area with no way back, which is
      // exactly the reported bug. Symmetric to the guard dashboard.js already
      // performs on the website.
      if (isExpert && _athleteOnlyRoutes.any((r) => loc == r || loc.startsWith('$r/'))) {
        if (kDebugMode) {
          debugPrint('[AUTH ROUTING] expert on athlete route $loc -> /expert-dashboard');
        }
        return '/expert-dashboard';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (context, state) => const SplashScreen()),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/under-review',
        builder: (context, state) => const ExpertApplicationReviewScreen(),
      ),

      // Full-screen flows outside the bottom-nav shell.
      GoRoute(path: '/assessment', builder: (context, state) => const AssessmentScreen()),
      GoRoute(path: '/ai-coach', builder: (context, state) => const AiCoachScreen()),
      // Personal Coaching (coach side) is served by the Website inside a
      // secure WebView until native Flutter reaches parity. The native
      // ExpertDashboardScreen is kept in the tree (dormant) so this can be
      // flipped back with a one-line change.
      GoRoute(
        path: '/expert-dashboard',
        // pageBuilder (not builder) so the screen this was opened from stays
        // painted underneath the loading overlay — see _webViewPage.
        pageBuilder: (context, state) =>
            _webViewPage(CoachingWebViewScreen.expertDashboard()),
      ),
      // The COMPLETE coach journey — profile, Request Review, Personal Coach,
      // payment, and (once active) the full coaching workspace: diet,
      // training, meal snap/review, chat, calls, progress, End Coaching.
      // INTENTIONALLY the Website's own cprofile.html in a WebView, kept as
      // ONE continuous Website session for all of it — never the native
      // ExpertProfileScreen (that screen stays in the tree, dormant, and is
      // no longer reached by anything in the normal flow).
      // `action` (optional) deep-links straight into the website's own
      // Request-Review / Personal-Coach / Chat flow on load, reusing
      // cprofile.js's existing `?action=` handling.
      GoRoute(
        path: '/coach-profile/:id',
        pageBuilder: (context, state) => _webViewPage(
          CoachingWebViewScreen.coachProfile(
            expertId: state.pathParameters['id']!,
            action: state.uri.queryParameters['action'],
          ),
        ),
      ),
      GoRoute(path: '/reviews/:id', builder: (context, state) => const ReviewsScreen()),
      // "Get Easy ZITLAS Recipe" — top-level (not nested in the Diet tab's
      // shell) so it pushes as a real full-screen page with its own back
      // button, the same way /chat/:roomId and /experts/:id do.
      GoRoute(
        path: '/recipe',
        // The only real caller (DietMealCard's onGetRecipe in diet_screen.dart)
        // always supplies `meal_type` from `mealSlotFromName(...).apiValue`, so
        // this only matters for a malformed/manual deep link. Falls back to
        // 'snack' — the SAME "unrecognized meal" fallback mealSlotFromName()
        // itself uses — never 'breakfast'. An unrecognized workout slot must
        // never silently become a normal meal recommendation.
        builder: (context, state) => RecipeScreen(
          mealType: state.uri.queryParameters['meal_type'] ?? 'snack',
          // The DISH the athlete tapped. Absent only on a manual deep link,
          // in which case the screen falls back to the slot recommender —
          // never as a silent substitute for a dish lookup that failed.
          mealName: state.uri.queryParameters['meal_name'],
          foods: (state.uri.queryParameters['foods'] ?? '')
              .split('|')
              .where((f) => f.trim().isNotEmpty)
              .toList(),
        ),
      ),
      // 🎥 Creator Recipe — a YouTube creator's video. A SEPARATE source
      // from /recipe (ZITLAS's own curated recipes); the two are never
      // conflated in the UI or the routing.
      GoRoute(
        path: '/creator-recipe',
        builder: (context, state) => CreatorRecipeScreen(
          food: state.uri.queryParameters['food'] ?? '',
          mealType: state.uri.queryParameters['meal_type'] ?? 'snack',
        ),
      ),
      GoRoute(
        path: '/creator/:channelId',
        builder: (context, state) =>
            CreatorProfileScreen(channelId: state.pathParameters['channelId']!),
      ),
      GoRoute(
        path: '/chat/:roomId',
        builder: (context, state) => ChatScreen(
          roomId: state.pathParameters['roomId']!,
          expertId: state.uri.queryParameters['expertId'],
          expertName: state.uri.queryParameters['expertName'],
        ),
      ),
      GoRoute(
        path: '/experts/:id',
        builder: (context, state) => ExpertProfileScreen(
          expertId: state.pathParameters['id']!,
          action: state.uri.queryParameters['action'],
        ),
      ),
      GoRoute(path: '/notifications', builder: (context, state) => const NotificationsScreen()),
      // Admin certificate console — parity with the website's cert-audit /
      // admin-review pages. The screen itself claim-gates (backend `admin`
      // custom claim); a non-admin who reaches it sees an access-denied view.
      GoRoute(path: '/admin', builder: (context, state) => const AdminScreen()),
      GoRoute(path: '/membership', builder: (context, state) => const MembershipScreen()),
      GoRoute(path: '/profile/personal-info', builder: (context, state) => const PersonalInfoScreen()),
      GoRoute(path: '/profile/help-support', builder: (context, state) => const HelpSupportScreen()),
      GoRoute(path: '/profile/notifications', builder: (context, state) => const NotificationSettingsScreen()),
      GoRoute(path: '/wallet', builder: (context, state) => const WalletScreen()),
      GoRoute(path: '/activity', builder: (context, state) => const StepHistoryRoute()),
      // Full-screen voice call. A top-level route (not nested in the shell)
      // so the bottom nav and the Zino FAB don't sit on top of a call.
      // Declared BEFORE '/zino' so the more specific path matches first.
      // `?from=diet` tells Zino which screen the athlete opened it from, so
      // an ambiguous question ("replace this") anchors to what they were just
      // looking at — the mobile equivalent of zino.js's `current_page`.
      GoRoute(
        path: '/zino',
        builder: (context, state) => ZinoScreen(
          screenContext: zinoScreenContextFromName(state.uri.queryParameters['from']),
          viewingExpertId: state.uri.queryParameters['expertId'],
        ),
      ),

      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/dashboard', builder: (context, state) => const DashboardScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/diet', builder: (context, state) => const DietScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/training', builder: (context, state) => const WorkoutScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/experts', builder: (context, state) => const ExpertsScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen()),
            ],
          ),
        ],
      ),
    ],
  );
}

/// A WebView route that keeps the Flutter screen it was opened FROM painted
/// underneath it.
///
/// `opaque: false` is the whole trick. A normal (opaque) route lets Flutter
/// stop painting everything below it, so the WebView screen had nothing behind
/// it and fell through to its own black Scaffold — that black is what the
/// hand-off to the website looked like. Keeping the route non-opaque leaves the
/// previous screen mounted and painted, so the loading cover can blur and dim
/// the REAL screen the athlete was just looking at instead of covering it.
///
/// Deliberately NOT a screenshot/RepaintBoundary capture: no image buffer to
/// size against a particular device, nothing to leak, and it cannot go stale.
/// The trade-off of `opaque: false` is that the screen below keeps its widgets
/// alive for the lifetime of the WebView route; these two routes are pushed one
/// at a time from a dashboard/list screen, which is cheap to keep around.
///
/// The fade is short and applies to the WHOLE overlay (blur, scrim and logo
/// together), so there is no frame where a bare colour is on screen — that is
/// what removes the black flash rather than merely recolouring it.
CustomTransitionPage<void> _webViewPage(Widget child) {
  return CustomTransitionPage<void>(
    child: child,
    opaque: false,
    barrierColor: null,
    barrierDismissible: false,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}
