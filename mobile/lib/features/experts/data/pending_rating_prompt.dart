import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/expert_rating.dart';
import 'expert_rating_repository.dart';

/// Decides WHEN to ask the athlete to rate a finished engagement.
///
/// Two rules the spec is emphatic about, and they pull in opposite
/// directions:
///   * the prompt must appear once the engagement ends, whichever side
///     ended it, and must survive a dismissal so it can be asked again;
///   * it must NOT appear on every app launch or every screen.
///
/// So there are two independent gates:
///   1. SERVER — `/api/expert-ratings/pending` is the authority on whether a
///      rating is owed. A submitted rating stops the prompt permanently, on
///      every device, including after a reinstall. Nothing local can
///      contradict that.
///   2. LOCAL SNOOZE — a dismissal ("Maybe later", swipe away) records a
///      timestamp and suppresses the prompt for [snoozeDuration]. This is
///      the only local state, and it can only ever DELAY a prompt, never
///      cancel one — so a lost/cleared preference degrades to "ask again",
///      never to "silently never ask".
class PendingRatingPrompt {
  PendingRatingPrompt({ExpertRatingRepository? repository})
      : _repo = repository ?? ExpertRatingRepository();

  final ExpertRatingRepository _repo;

  /// Long enough not to nag, short enough that an athlete who meant to come
  /// back to it actually gets the chance.
  static const snoozeDuration = Duration(hours: 24);

  static const _snoozeKeyPrefix = 'zitlas_rating_snoozed_';

  /// The engagement to prompt about, or null if there is nothing to ask —
  /// either because nothing is pending, it was already rated, or the
  /// athlete snoozed it recently.
  ///
  /// Never throws: a failed check must not break whatever screen called it.
  Future<PendingExpertRating?> check() async {
    PendingExpertRating? pending;
    try {
      pending = await _repo.fetchPending();
    } catch (e) {
      if (kDebugMode) debugPrint('[RATING] pending check failed: $e');
      return null;
    }
    if (pending == null) return null;
    if (await _isSnoozed(pending.engagementId)) return null;
    return pending;
  }

  /// Called when the athlete dismisses without submitting. Does NOT mark the
  /// engagement reviewed — no rating is created, and the server still
  /// reports it as pending after the snooze lapses.
  Future<void> snooze(String engagementId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        '$_snoozeKeyPrefix$engagementId',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      // Worst case the athlete sees the prompt again sooner than intended,
      // which is the harmless direction to fail in.
      if (kDebugMode) debugPrint('[RATING] snooze write failed: $e');
    }
  }

  Future<bool> _isSnoozed(String engagementId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final at = prefs.getInt('$_snoozeKeyPrefix$engagementId');
      if (at == null) return false;
      final since = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at));
      return since < snoozeDuration;
    } catch (_) {
      return false;
    }
  }
}
