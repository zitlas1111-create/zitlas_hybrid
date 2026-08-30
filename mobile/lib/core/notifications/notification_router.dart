import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'notification_payload.dart';

/// Global navigator key, handed to GoRouter in `buildRouter`.
///
/// A notification tap arrives from outside the widget tree (an FCM callback or
/// a local-notification response), so there is no `BuildContext` to navigate
/// with. This key provides one. It is also what lets a COLD START navigate
/// after the first frame, once the router actually exists.
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'zitlasRootNavigator');

/// THE one place that turns a notification into a destination.
///
/// Every entry point routes through [route]: a tap while backgrounded
/// (`onMessageOpenedApp`), a cold start (`getInitialMessage`), a foreground
/// local-notification tap, and the in-app Notification Centre. Keeping the
/// mapping here — rather than scattered across screens — is what stops the
/// four paths from drifting apart.
///
/// COACHING LIVES ON THE WEBSITE. Personal Coaching (chat, meal reviews, plan
/// editing, End Coaching) is intentionally served by the Website inside
/// `CoachingWebViewScreen`, so coaching notifications deep-link to
/// `/coach-profile/:id` (athlete) or `/expert-dashboard` (coach) — NOT to the
/// dormant native coaching screens. Diet/Training/Dashboard remain native.
abstract final class NotificationRouter {
  /// A notification that arrived before the app was ready to navigate (cold
  /// start, or before authentication resolved). Consumed by
  /// [consumePending] once the router and session exist.
  static NotificationPayload? _pending;

  static void remember(NotificationPayload payload) {
    _pending = payload;
    if (kDebugMode) debugPrint('[NOTIF ROUTER] pending: ${payload.type}');
  }

  static bool get hasPending => _pending != null;

  /// Navigates to the remembered notification's destination, if any. Called
  /// after the first frame AND after auth resolves — whichever is later — so a
  /// cold start from a notification lands on the right screen instead of the
  /// dashboard.
  static void consumePending() {
    final payload = _pending;
    if (payload == null) return;
    _pending = null;
    route(payload);
  }

  /// Resolves [payload] to a route and navigates. No-op (with a log) when the
  /// navigator is not mounted yet — the caller should [remember] instead in
  /// that case.
  static void route(NotificationPayload payload) {
    final context = rootNavigatorKey.currentContext;
    if (context == null) {
      if (kDebugMode) {
        debugPrint('[NOTIF ROUTER] navigator not ready — remembering ${payload.type}');
      }
      remember(payload);
      return;
    }
    // Logged on release builds: a tap that lands on the wrong screen is
    // reported from a real phone running a release APK, and a debug-only line
    // is invisible exactly when it is needed. Ids only — never the body, which
    // can carry an expert's private feedback.
    debugPrint('[NOTIFY] notification tap type=${payload.type}');
    if (payload.deepLink != null) {
      debugPrint('[NOTIFY] deepLink=${payload.deepLink}');
    }
    final destination = destinationFor(payload);
    if (destination == null) {
      debugPrint('[NOTIFY] no destination for type=${payload.type}');
      return;
    }
    if (payload.mealId != null) {
      debugPrint('[NOTIFY] opening meal review mealId=${payload.mealId}');
    }
    debugPrint('[NOTIFY] navigating type=${payload.type} -> $destination');
    try {
      GoRouter.of(context).push(destination);
    } catch (e) {
      if (kDebugMode) debugPrint('[NOTIF ROUTER] navigation failed: $e');
    }
  }

  /// Translates a `zitlas://…` deep link into an in-app route, or null when
  /// there is nothing usable to translate.
  ///
  /// Deliberately a TRANSLATION and not a redirect. The same meal review opens
  /// in two different places depending on who tapped it — the athlete in their
  /// coach's workspace, the expert in their own dashboard — and the server
  /// cannot know which device it landed on. Resolving that here also means a
  /// malformed or hostile link can never navigate anywhere the type switch
  /// would not have gone anyway.
  static String? _fromDeepLink(NotificationPayload p, {required bool isCoach}) {
    final raw = p.deepLink;
    if (raw == null || raw.isEmpty) return null;

    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'zitlas') return null;

    switch (uri.host) {
      case 'meal-review':
        // zitlas://meal-review/<checkinId>
        //
        // The id comes from the PAYLOAD, not from the link path: the path is
        // only ever as trustworthy as the string the server built, while
        // mealId/mealCheckinId are the fields every other consumer already
        // reads. `cwCheckin` is what makes the exact meal open instead of
        // just the list — the workspace holds it until meal_checkins loads.
        final meal = p.mealId;
        final mealParam = meal == null ? '' : '&cwCheckin=$meal';
        if (isCoach) {
          final athlete = p.athleteId ?? p.counterpartId ?? p.senderId;
          return athlete != null
              ? '/expert-dashboard?cwAthlete=$athlete&cwTab=checkins$mealParam'
              : '/expert-dashboard';
        }
        final coach = p.coachId ?? p.counterpartId ?? p.senderId;
        return coach != null
            ? '/coach-profile/$coach?cwTab=checkins$mealParam'
            : '/diet';

      default:
        // A link shape this build does not know. Falling through to the type
        // switch is what lets the backend ship a new one first.
        return null;
    }
  }

  /// The route for a payload, or null when it should not navigate anywhere.
  ///
  /// Pure and side-effect free, so it is directly unit-testable without a
  /// widget tree — see test/notification_router_test.dart.
  static String? destinationFor(NotificationPayload p) {
    final isCoach = p.recipientRole == 'coach';

    // `deepLink` (zitlas://…) is what the backend templates now send, and it
    // names the destination directly instead of making the client re-derive
    // it from loose ids. It is translated rather than trusted verbatim: the
    // in-app route depends on WHO is looking (an expert and an athlete open a
    // meal review from different sides), which a single server-side string
    // cannot know. Unknown or malformed links fall through to the type switch
    // below, so a new link shape can ship on the backend before the app that
    // understands it exists.
    final viaLink = _fromDeepLink(p, isCoach: isCoach);
    if (viaLink != null) return viaLink;

    switch (p.type) {
      // ── Chat ────────────────────────────────────────────────────────────
      // Same message, two destinations: the coach works out of their
      // dashboard, the athlete out of their coach's profile workspace.
      // `recipientRole` is derived server-side precisely so this is not a guess.
      case 'chat_message':
        if (isCoach) return '/expert-dashboard';
        final coach = p.counterpartId ?? p.senderId ?? p.coachId;
        return coach != null ? '/coach-profile/$coach?action=ask' : '/experts';

      // ── Meal reviews ────────────────────────────────────────────────────
      //
      // Both sides land on the Meal Reviews tab of the coaching workspace —
      // the screen the notification is actually ABOUT. These used to stop at
      // the dashboard and at /diet, leaving the user to find the meal
      // themselves; /diet in particular shows the plan, not the coach's
      // feedback, so the one thing the notification promised was the one
      // thing the destination did not contain.
      //
      // `cwAthlete`/`cwTab` are the query params the website's own
      // refresh-restore already understands (expert-dashboard.js
      // _restorePendingWorkspace, cprofile.js's onSnapshot restore hook), so
      // this needs nothing new deployed. Both re-read `personal_coaching`
      // and fail closed on an ended or foreign relationship, which is why it
      // is safe to build these from payload values.
      case 'meal_review_pending': // coach: an athlete sent a meal
      case 'meal_checkin':
        final athlete = p.athleteId ?? p.counterpartId ?? p.senderId;
        final pendingMeal = p.mealId == null ? '' : '&cwCheckin=${p.mealId}';
        return athlete != null
            ? '/expert-dashboard?cwAthlete=$athlete&cwTab=checkins$pendingMeal'
            : '/expert-dashboard';
      case 'meal_review_completed': // athlete: the coach rated it
      case 'meal_reviewed':
        // Without a coach there is no workspace to open, and /diet remains
        // the closest useful screen rather than a dead end.
        final coach = p.coachId ?? p.counterpartId ?? p.senderId;
        final ratedMeal = p.mealId == null ? '' : '&cwCheckin=${p.mealId}';
        return coach != null
            ? '/coach-profile/$coach?cwTab=checkins$ratedMeal'
            : '/diet';

      // ── Plans ───────────────────────────────────────────────────────────
      // `_modified` and `_updated` are the same event under two names: the
      // backend has written `_updated` since before push existed, and
      // `_modified` is the name the expert-modification system uses. Both
      // land on the screen the athlete needs to look at.
      case 'diet_updated':
      case 'diet_modified':
        return '/diet';
      case 'workout_updated':
      case 'workout_modified':
        return '/training';

      // ── Athlete: their OWN wellness check-in confirmation ───────────────
      // The Dashboard is where the Recovery Mode card summarises BOTH the
      // adjusted diet and the adjusted training, so it is the one screen
      // that shows the whole effect of the check-in. Matches the `action:
      // 'dashboard'` the self-notification already carries.
      case 'health_status_sick':
      case 'health_status_injured':
      case 'health_status_unwell':
      case 'health_status_poor_sleep':
      case 'health_status_stress':
      case 'health_status_other':
        return '/dashboard';

      // ── Athlete: expert activity ────────────────────────────────────────
      case 'review_completed':
        return '/diet';
      case 'expert_accepted':
        final coach = p.counterpartId ?? p.senderId ?? p.coachId;
        return coach != null ? '/coach-profile/$coach' : '/experts';

      // ── Athlete: reminders land where the athlete can ACT on them ───────
      case 'meal_reminder':
      case 'breakfast_reminder':
      case 'lunch_reminder':
      case 'dinner_reminder':
      case 'snack_reminder':
      case 'pre_workout_meal':
      case 'post_workout_meal':
      case 'water_reminder':
        return '/diet';
      case 'workout_reminder':
      case 'workout_completed':
        return '/training';
      case 'step_goal':
      case 'step_goal_achieved':
      case 'streak':
      case 'milestone':
      case 'motivation':
        return '/dashboard';

      // ── Expert: inbound work, straight to the queue ─────────────────────
      case 'expert_request':
      case 'coaching_request':
      case 'review_pending':
      case 'diet_review_pending':
      case 'workout_review_pending':
      case 'wellness_plan_adjusted': // coach: a client reported sick/injured
      case 'client_unwell':
      case 'client_needs_attention':
      case 'consultation_reminder':
      case 'consultation_requested':
      case 'rating_received':
      case 'rating_updated':
      case 'expert_verification':
      case 'expert_approved':
      case 'expert_rejected':
        return '/expert-dashboard';

      // ── Zino / AI ───────────────────────────────────────────────────────
      case 'zino_message':
        return '/zino';

      default:
        return _coachingOrActionFallback(p, isCoach);
    }
  }

  /// Coaching lifecycle types (`coaching_requested`, `coaching_accepted`,
  /// `coaching_started`, `coaching_ended`, `payment_*` …) plus the
  /// notification-centre `action` keys the backend has always written.
  ///
  /// Honouring `action` here is deliberate: those values predate push, and
  /// mapping them the same way `navigateForAction()` does on the website keeps
  /// a pushed notification and an in-app tap landing on the SAME screen.
  static String? _coachingOrActionFallback(NotificationPayload p, bool isCoach) {
    final type = p.type;
    if (type.startsWith('coaching') || type.startsWith('payment')) {
      if (isCoach) return '/expert-dashboard';
      final coach = p.coachId ?? p.counterpartId ?? p.actionId ?? p.coachingId;
      return coach != null ? '/coach-profile/$coach' : '/experts';
    }

    switch (p.action) {
      case 'diet':
        return '/diet';
      case 'training':
        return '/training';
      case 'dashboard':
        return '/dashboard';
      case 'coaches':
        return '/experts';
      case 'expert_dashboard':
        return '/expert-dashboard';
      case 'profile':
        return '/profile';
      case 'expert_profile':
      case 'coaching_workspace':
      case 'chat':
        final id = p.actionId ?? p.coachId ?? p.counterpartId;
        if (id == null) return '/experts';
        return p.action == 'chat'
            ? '/coach-profile/$id?action=ask'
            : '/coach-profile/$id';
      default:
        // Unknown/general — the Notification Centre is the honest destination:
        // the notification is definitely there, whatever it was about.
        return '/notifications';
    }
  }
}
