import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/util/json_coerce.dart';
import '../models/coach_diet_plan.dart';
import '../models/coach_plan_version.dart';

/// `coaching_plans/{athleteUid}` — the coach-authored plans.
///
/// THE SAME DOCUMENT THE WEBSITE USES (`components/coaching-workspace.js`),
/// field for field, so a plan written on the phone opens on the web and vice
/// versa. Nothing here writes `users/{uid}.dietPlan` or `.workoutPlan`: the
/// AI plan and the coach plan are separate documents with separate owners,
/// which is precisely why regenerating one can never overwrite the other.
///
/// Every save also appends to `versions/` — the coach plan is never
/// overwritten in place without a snapshot of what it replaced. A DIET
/// publish is written by the backend ([saveDiet]); training is still written
/// from here.
class CoachingPlanRepository {
  CoachingPlanRepository({FirebaseFirestore? firestore, ApiClient? apiClient})
      : _db = firestore ?? FirebaseFirestore.instance,
        _apiOverride = apiClient;

  final FirebaseFirestore _db;
  final ApiClient? _apiOverride;
  ApiClient? _liveApi;

  /// The signed-in user's ID token, read per request — never at construction.
  ApiClient get _api =>
      _apiOverride ??
      (_liveApi ??= ApiClient()
        ..authTokenProvider = () async => FirebaseAuth.instance.currentUser?.getIdToken());

  DocumentReference<Map<String, dynamic>> _planDoc(String athleteId) =>
      _db.collection('coaching_plans').doc(athleteId);

  /// Live coach plan document.
  Stream<CoachingPlanDoc> watch(String athleteId) {
    return _planDoc(athleteId).snapshots().map((snap) {
      final doc = CoachingPlanDoc.fromMap(snap.data());
      if (kDebugMode) {
        debugPrint('[COACH PLAN] $athleteId diet=${doc.diet.days.length}d '
            'v${doc.dietVersion} training=${doc.hasTraining} v${doc.trainingVersion}');
      }
      return doc;
    });
  }

  Future<CoachingPlanDoc> fetch(String athleteId) async {
    final snap = await _planDoc(athleteId).get();
    return CoachingPlanDoc.fromMap(snap.data());
  }

  /// Publishes the coach's diet — through the backend, never a client write.
  ///
  /// `POST /api/coaching-plans/{athleteId}/diet` (backend/routes/coaching_plans.py)
  /// is the one authority, for the app and the website's coaching workspace
  /// alike. It checks the caller is this athlete's active, assigned coach on
  /// an engagement that covers diet (and, for a Personal Coaching Program,
  /// that the program is paid and active); compares [baseVersion] — the
  /// `dietVersion` this edit started from — with the stored one; writes the
  /// plan and its version snapshot in ONE transaction, stamped with the
  /// athlete's current planId; and only after that commit notifies the
  /// athlete. Coach identity, version and planId are decided server-side.
  ///
  /// Returns the saved `dietVersion`. Throws [CoachPlanConflictException]
  /// when another device published first (nothing was written) and
  /// [CoachPlanSaveException] for every other refusal or failure — a publish
  /// that did not happen is never reported as one that did.
  Future<int> saveDiet({
    required String athleteId,
    required CoachDietPlan diet,
    required int baseVersion,
  }) async {
    if (kDebugMode) {
      debugPrint('[COACH PLAN] publishing diet for $athleteId on v$baseVersion '
          '(${diet.days.length} days)');
    }
    final dynamic res;
    try {
      res = await _api.post(
        '/api/coaching-plans/${Uri.encodeComponent(athleteId)}/diet',
        body: {'diet': diet.toMap(), 'baseVersion': baseVersion},
      );
    } on ApiException catch (e) {
      final body = e.body;
      final detail = body is Map ? body['detail'] : null;
      if (e.statusCode == 409) {
        throw CoachPlanConflictException(
          currentVersion: detail is Map ? asNum(detail['currentVersion'])?.toInt() : null,
        );
      }
      throw CoachPlanSaveException.fromApi(e);
    }
    final version = res is Map && res['success'] == true ? asNum(res['dietVersion'])?.toInt() : null;
    if (version == null) {
      // A 2xx that does not confirm the save is not a save.
      throw const CoachPlanSaveException(
        "The server didn't confirm the publish — reload to check before trying again.",
        code: 'unconfirmed',
      );
    }
    return version;
  }

  /// Training mirror of [saveDiet]. `training` is passed as the raw website
  /// shape (`{days: [...]}`) because `CoachTrainingPlan` already converts that
  /// into the athlete's rendering model on the read side — round-tripping it
  /// through a second representation here would risk the two drifting.
  Future<void> saveTraining({
    required String athleteId,
    required String athleteName,
    required String coachId,
    required String coachName,
    required String planType,
    required Map<String, dynamic> training,
    String? athletePlanId,
  }) async {
    final now = DateTime.now();
    final current = await fetch(athleteId);
    final version = current.trainingVersion + 1;
    final stamped = {...training, 'planId': athletePlanId};

    if (kDebugMode) {
      debugPrint('[COACH PLAN] saving training v$version for $athleteId');
    }

    await _planDoc(athleteId).set({
      'athleteId': athleteId,
      'athleteName': athleteName,
      'coachId': coachId,
      'coachName': coachName,
      'planType': planType,
      'training': stamped,
      'trainingUpdatedAt': now.toIso8601String(),
      'trainingVersion': version,
    }, SetOptions(merge: true));

    await _snapshotVersion(
      athleteId: athleteId,
      type: 'training',
      data: stamped,
      version: version,
      savedBy: coachName,
      now: now,
    );

    await _notifyAthlete(
      athleteId: athleteId,
      title: '🏋 $coachName updated your workout plan',
      message: 'Tap to see what changed.',
      type: 'training_update',
      action: 'training',
    );
  }

  /// Every saved revision, newest first — the history and rollback source.
  Stream<List<CoachPlanVersion>> watchVersions(String athleteId, {String? type}) {
    Query<Map<String, dynamic>> query = _planDoc(athleteId).collection('versions');
    if (type != null) query = query.where('type', isEqualTo: type);
    return query.snapshots().map((snap) {
      final list = snap.docs
          .map((d) => CoachPlanVersion.fromMap(d.id, d.data()))
          .nonNulls
          .toList();
      // Sorted client-side rather than with orderBy so this needs no composite
      // index alongside the `type` filter — a version list is at most a few
      // dozen documents.
      list.sort((a, b) {
        final at = a.savedAt, bt = b.savedAt;
        if (at == null && bt == null) return b.version.compareTo(a.version);
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
      return list;
    });
  }

  /// Restores a previous revision by SAVING IT FORWARD as a new version.
  ///
  /// Deliberately not a destructive rewind: rolling back is itself an edit the
  /// athlete is entitled to see, and the revision being replaced stays in the
  /// history. Nothing is ever deleted.
  ///
  /// A diet restore goes through [saveDiet]. The coach picked this revision
  /// from the live history, so the base is the version stored right now
  /// unless the caller passes the one it was showing — the website's restore
  /// does the same.
  Future<void> restoreVersion({
    required String athleteId,
    required String athleteName,
    required String coachId,
    required String coachName,
    required String planType,
    required CoachPlanVersion version,
    String? athletePlanId,
    int? baseVersion,
  }) async {
    if (version.type == 'training') {
      return saveTraining(
        athleteId: athleteId,
        athleteName: athleteName,
        coachId: coachId,
        coachName: coachName,
        planType: planType,
        training: version.data,
        athletePlanId: athletePlanId,
      );
    }
    final base = baseVersion ?? (await fetch(athleteId)).dietVersion;
    await saveDiet(
      athleteId: athleteId,
      diet: CoachDietPlan.fromMap(version.data),
      baseVersion: base,
    );
  }

  /// The athlete's current selection per meal, keyed `'<day>:<mealId>'`.
  Future<void> saveSelections(String athleteId, Map<String, int> selections) {
    return _planDoc(athleteId).set({'dietSelections': selections}, SetOptions(merge: true));
  }

  Future<void> _snapshotVersion({
    required String athleteId,
    required String type,
    required Map<String, dynamic> data,
    required int version,
    required String savedBy,
    required DateTime now,
  }) async {
    try {
      await _planDoc(athleteId)
          .collection('versions')
          .doc('${type}_${now.millisecondsSinceEpoch}')
          .set({
        'type': type,
        'data': data,
        'version': version,
        'savedAt': now.toIso8601String(),
        'savedBy': savedBy,
      });
    } catch (e) {
      // The plan itself is already published. Losing a history entry is worth
      // a log, not a failed save the coach would retry (and thereby publish
      // twice).
      if (kDebugMode) debugPrint('[COACH PLAN] version snapshot failed: $e');
    }
  }

  /// Same `notifications` doc shape `ZitlasNotify.send()` writes on the
  /// website, so these render identically in the athlete's Notification
  /// Center on both platforms.
  Future<void> _notifyAthlete({
    required String athleteId,
    required String title,
    required String message,
    required String type,
    required String action,
  }) async {
    final now = DateTime.now();
    final id = 'NTF_${now.millisecondsSinceEpoch}_$type';
    try {
      await _db.collection('notifications').doc(id).set({
        'notificationId': id,
        'userId': athleteId,
        'title': title,
        'message': message,
        'category': 'expert',
        'icon': null,
        'type': type,
        'action': action,
        'actionId': null,
        'expertId': null,
        'isRead': false,
        'priority': 'high',
        'createdAt': now.toIso8601String(),
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[COACH PLAN] notification failed: $e');
    }
  }
}

/// The whole `coaching_plans/{athleteUid}` document.
@immutable
class CoachingPlanDoc {
  const CoachingPlanDoc({
    this.diet = const CoachDietPlan(),
    this.training,
    this.selections = const {},
    this.coachId,
    this.coachName,
    this.planType,
    this.dietVersion = 0,
    this.trainingVersion = 0,
    this.dietUpdatedAt,
    this.trainingUpdatedAt,
    this.exists = false,
  });

  final CoachDietPlan diet;

  /// Raw website shape — see [CoachingPlanRepository.saveTraining].
  final Map<String, dynamic>? training;

  final Map<String, int> selections;
  final String? coachId;
  final String? coachName;
  final String? planType;
  final int dietVersion;
  final int trainingVersion;
  final DateTime? dietUpdatedAt;
  final DateTime? trainingUpdatedAt;
  final bool exists;

  bool get hasTraining {
    final t = training;
    if (t == null) return false;
    final days = t['days'];
    return days is List && days.isNotEmpty;
  }

  /// Whether the coach may edit diet / training, from the plan they sold.
  ///
  /// `diet` → diet only, `training` → training only, `complete` → both. A
  /// coach paid for training must not quietly rewrite the athlete's food.
  bool get canEditDiet => planType == 'diet' || planType == 'complete' || planType == null;
  bool get canEditTraining =>
      planType == 'training' || planType == 'complete' || planType == null;

  /// True when this plan was authored against a DIFFERENT athlete plan
  /// generation than the one currently in force — the fail-closed guard.
  bool isStaleFor(String? athletePlanId) {
    final authored = diet.planId;
    if (authored == null || athletePlanId == null) return false;
    return authored != athletePlanId;
  }

  static CoachingPlanDoc fromMap(Map<String, dynamic>? data) {
    if (data == null) return const CoachingPlanDoc();
    final rawSelections = data['dietSelections'];
    return CoachingPlanDoc(
      diet: CoachDietPlan.fromMap(data['diet']),
      training: (data['training'] as Map?)?.cast<String, dynamic>(),
      // Coerced rather than cast: these documents are written by the website
      // too, and JS happily stores a version or a selection index as a string.
      // A hard cast threw on the real production document and took the whole
      // coach plan down with it.
      selections: {
        if (rawSelections is Map)
          for (final e in rawSelections.entries)
            if (asNum(e.value) != null) e.key.toString(): asNum(e.value)!.toInt(),
      },
      coachId: data['coachId'] as String?,
      coachName: data['coachName'] as String?,
      planType: data['planType'] as String?,
      dietVersion: asNum(data['dietVersion'])?.toInt() ?? 0,
      trainingVersion: asNum(data['trainingVersion'])?.toInt() ?? 0,
      dietUpdatedAt: _date(data['dietUpdatedAt']),
      trainingUpdatedAt: _date(data['trainingUpdatedAt']),
      exists: true,
    );
  }

  static DateTime? _date(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
}

/// Another device published a newer diet first. NOTHING was written and the
/// newer plan is untouched — load it before editing again.
class CoachPlanConflictException implements Exception {
  const CoachPlanConflictException({this.currentVersion});

  final int? currentVersion;

  String get message => 'A newer version of this diet'
      '${currentVersion != null ? ' (v$currentVersion)' : ''} was published from '
      'another device. Your changes were NOT published — load the latest version '
      'to continue.';

  @override
  String toString() => message;
}

/// The backend refused, or could not complete, a diet publish. NOTHING was
/// published; [message] is written for the coach.
class CoachPlanSaveException implements Exception {
  const CoachPlanSaveException(this.message, {this.code, this.statusCode});

  factory CoachPlanSaveException.fromApi(ApiException e) {
    final body = e.body;
    final detail = body is Map ? body['detail'] : null;
    final String? code = detail is String
        ? detail
        : (detail is Map && detail['error'] is String ? detail['error'] as String : null);
    final status = e.statusCode;
    final String message;
    if (status == null) {
      message = 'No connection — the plan was NOT published. Check your connection and try again.';
    } else if (status == 401) {
      message = 'Your session has expired — sign in again. The plan was NOT published.';
    } else if (status == 403) {
      message = switch (code) {
        'coaching_not_active' || 'program_not_active' =>
          'This coaching has ended — the plan was NOT published.',
        'plan_does_not_cover_diet' =>
          "This coaching plan doesn't include diet — the plan was NOT published.",
        _ => "You are not this athlete's active coach — the plan was NOT published.",
      };
    } else if (status >= 500) {
      message = "The server couldn't publish the plan — it was NOT published. Please try again.";
    } else {
      message = 'This plan could not be published (${code ?? status}).';
    }
    return CoachPlanSaveException(message, code: code, statusCode: status);
  }

  final String message;
  final String? code;
  final int? statusCode;

  /// Worth a "Retry": the connection or the server failed; nobody refused.
  bool get isRetryable => statusCode == null || statusCode! >= 500 || code == 'unconfirmed';

  @override
  String toString() => message;
}
