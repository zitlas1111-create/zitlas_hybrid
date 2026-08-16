/// Who a notification is FOR.
///
/// ZITLAS has two fundamentally different notification experiences on one
/// codebase and one device. An expert must never be told to eat breakfast;
/// an athlete must never be told a client is waiting for a review.
///
/// Before this existed the two were not separated at all: every one of the
/// eight local reminder slots (breakfast, lunch, snack, dinner, steps,
/// workout, morning motivation, wind-down) was scheduled from `main()`
/// BEFORE authentication resolved, so an expert who had never opened the
/// athlete side still received meal reminders every single day.
library;

enum NotificationAudience {
  /// Athlete-only. Meal, workout, steps, motivation, plan updates.
  athlete,

  /// Expert-only. Client requests, pending reviews, ratings, verification.
  expert,

  /// Genuinely relevant to whoever is signed in — account and security
  /// notices, and chat, which both roles participate in from opposite ends.
  both,
}

/// The role→notification contract, in one place.
///
/// Keys are the `type` field carried in every FCM data payload and every
/// `notifications/{id}` document. An unknown type resolves to
/// [NotificationAudience.both] so a new backend event is never silently
/// swallowed — but it is also never reclassified, which is why every type
/// the product actually sends is listed explicitly.
const Map<String, NotificationAudience> kNotificationAudience = {
  // ── Athlete: nutrition ──────────────────────────────────────────────
  'meal_reminder': NotificationAudience.athlete,
  'breakfast_reminder': NotificationAudience.athlete,
  'lunch_reminder': NotificationAudience.athlete,
  'dinner_reminder': NotificationAudience.athlete,
  'snack_reminder': NotificationAudience.athlete,
  'pre_workout_meal': NotificationAudience.athlete,
  'post_workout_meal': NotificationAudience.athlete,
  'water_reminder': NotificationAudience.athlete,

  // ── Athlete: training and activity ──────────────────────────────────
  'workout_reminder': NotificationAudience.athlete,
  'workout_completed': NotificationAudience.athlete,
  'step_goal': NotificationAudience.athlete,
  'step_goal_achieved': NotificationAudience.athlete,
  'streak': NotificationAudience.athlete,
  'milestone': NotificationAudience.athlete,
  'motivation': NotificationAudience.athlete,

  // ── Athlete: what an expert did TO their plan ───────────────────────
  'diet_modified': NotificationAudience.athlete,
  'diet_updated': NotificationAudience.athlete,
  'workout_modified': NotificationAudience.athlete,
  'workout_updated': NotificationAudience.athlete,
  'review_completed': NotificationAudience.athlete,
  'meal_review_completed': NotificationAudience.athlete,
  'meal_reviewed': NotificationAudience.athlete,
  'expert_accepted': NotificationAudience.athlete,
  'expert_message': NotificationAudience.athlete,
  'zino_message': NotificationAudience.athlete,
  'health_status_sick': NotificationAudience.athlete,
  'health_status_injured': NotificationAudience.athlete,
  'health_status_unwell': NotificationAudience.athlete,
  'health_status_poor_sleep': NotificationAudience.athlete,
  'health_status_stress': NotificationAudience.athlete,
  'health_status_other': NotificationAudience.athlete,

  // ── Expert: inbound work ────────────────────────────────────────────
  'expert_request': NotificationAudience.expert,
  'coaching_request': NotificationAudience.expert,
  'review_pending': NotificationAudience.expert,
  'diet_review_pending': NotificationAudience.expert,
  'workout_review_pending': NotificationAudience.expert,
  'meal_review_pending': NotificationAudience.expert,
  'meal_checkin': NotificationAudience.expert,
  'client_unwell': NotificationAudience.expert,
  // The coach-facing wellness alert. The ATHLETE's own confirmation that
  // their plan changed is a different notification entirely
  // (`health_status_<status>`, written by sendSelfNotification), so the two
  // sides of one wellness check-in never cross roles.
  'wellness_plan_adjusted': NotificationAudience.expert,
  'client_needs_attention': NotificationAudience.expert,
  'consultation_reminder': NotificationAudience.expert,
  'consultation_requested': NotificationAudience.expert,

  // ── Expert: their own account ───────────────────────────────────────
  'rating_received': NotificationAudience.expert,
  'rating_updated': NotificationAudience.expert,
  'expert_verification': NotificationAudience.expert,
  'expert_approved': NotificationAudience.expert,
  'expert_rejected': NotificationAudience.expert,

  // ── Both ────────────────────────────────────────────────────────────
  // Chat is one event type with two destinations, already resolved by
  // `NotificationRouter` via recipientRole.
  'chat_message': NotificationAudience.both,
  'account_security': NotificationAudience.both,
  'system': NotificationAudience.both,
};

NotificationAudience audienceFor(String? type) {
  if (type == null || type.isEmpty) return NotificationAudience.both;
  return kNotificationAudience[type] ?? NotificationAudience.both;
}

/// Whether a signed-in [role] (`'athlete'` | `'expert'`, as produced by
/// `UserModel.resolvedRole`) should be shown a notification of [type].
///
/// Applied at BOTH ends: the list screen filters with it, and the foreground
/// FCM handler drops with it — so a mis-targeted server push is contained on
/// the client too rather than merely being unlikely.
bool isForRole(String? type, String? role) {
  final audience = audienceFor(type);
  if (audience == NotificationAudience.both) return true;
  final isExpert = role == 'expert';
  return isExpert
      ? audience == NotificationAudience.expert
      : audience == NotificationAudience.athlete;
}
