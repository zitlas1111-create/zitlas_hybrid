import 'package:flutter/foundation.dart';

import '../../../core/util/json_coerce.dart';

/// The coach's verdict on a meal.
///
/// Values are the website's exactly (`PC_REACTION_LABEL` in `diet.js`,
/// `reactions` in `coaching-workspace.js`) so a meal rated on the phone reads
/// correctly on the web and vice versa.
enum MealReaction {
  perfect('perfect', '🟢', 'Perfect', 5),
  great('great', '🟢', 'Great', 4),
  good('good', '🟡', 'Good', 3),
  needsImprovement('needs_improvement', '🟠', 'Needs improvement', 2),
  notRecommended('not_recommended', '🔴', 'Not recommended', 1);

  const MealReaction(this.id, this.icon, this.label, this.score);

  final String id;
  final String icon;
  final String label;

  /// 1–5, stored alongside the reaction so compliance maths never has to
  /// re-derive a number from a label.
  final int score;

  /// Whether this reaction counts the meal as followed for compliance.
  ///
  /// Good and above. "Needs improvement" means the athlete ate something the
  /// coach would not have chosen — counting it as adherence would flatter the
  /// number and hide the thing the coach is trying to fix.
  bool get isCompliant => score >= 3;

  static MealReaction? fromId(String? id) {
    if (id == null) return null;
    for (final r in values) {
      if (r.id == id) return r;
    }
    return null;
  }
}

/// `meal_checkins/{checkinId}` — one photographed meal, awaiting or carrying a
/// coach's review.
///
/// Field-for-field the document `diet.js` writes, so the two clients share one
/// record. Nothing here is invented: every field below exists in the website's
/// own submit path.
@immutable
class MealCheckin {
  const MealCheckin({
    required this.checkinId,
    required this.athleteId,
    required this.coachId,
    required this.mealType,
    required this.mealName,
    required this.status,
    this.athleteName,
    this.day,
    this.imageUrl,
    this.timestamp,
    this.reaction,
    this.score,
    this.overallRating,
    this.tasteRating,
    this.presentationRating,
    this.nutritionRating,
    this.comment,
    this.reviewedAt,
    this.reviewedBy,
    this.estimatedCalories,
    this.estimatedProtein,
    this.estimatedCarbs,
    this.estimatedFat,
    this.foodRecognition = const [],
    this.confidenceScore,
  });

  final String checkinId;
  final String athleteId;
  final String coachId;

  /// Lower-cased meal name — `breakfast`, `lunch`, `snacks`, `dinner`.
  final String mealType;

  final String mealName;

  /// `pending` | `reviewed`.
  final String status;

  final String? athleteName;

  /// Weekday name the meal belongs to, as the website stores it.
  final String? day;

  final String? imageUrl;
  final DateTime? timestamp;

  final MealReaction? reaction;
  final int? score;

  /// The expert's star rating, 1-5. `reaction` and `score` are still the
  /// compliance/stat inputs; these are what the rating UI shows and edits.
  /// Null on meals reviewed before the star UI existed — [displayRating]
  /// falls back to `score` for those.
  final int? overallRating;
  final int? tasteRating;
  final int? presentationRating;
  final int? nutritionRating;

  /// What "Rated X.X★" should show, or null when genuinely unrated.
  double? get displayRating {
    if (overallRating != null) return overallRating!.toDouble();
    if (score != null) return (score! / 2).clamp(1, 5).toDouble();
    return null;
  }

  bool get isRated => isReviewed && displayRating != null;
  final String? comment;
  final DateTime? reviewedAt;
  final String? reviewedBy;

  /// Populated by `POST /api/meal/estimate-nutrition` when it succeeds. Null
  /// when the estimate failed or timed out — it never blocks a check-in, and a
  /// null here means "not estimated", not "zero calories".
  final num? estimatedCalories;
  final num? estimatedProtein;
  final num? estimatedCarbs;
  final num? estimatedFat;
  final List<String> foodRecognition;
  final num? confidenceScore;

  bool get isPending => status == 'pending';
  bool get isReviewed => status == 'reviewed';
  bool get hasEstimate => estimatedCalories != null || estimatedProtein != null;

  Map<String, dynamic> toMap() => {
        'checkinId': checkinId,
        'athleteId': athleteId,
        'athleteName': athleteName,
        'coachId': coachId,
        'day': day,
        'mealType': mealType,
        'mealName': mealName,
        'imageUrl': imageUrl,
        'timestamp': timestamp?.toIso8601String(),
        'status': status,
        'reaction': reaction?.id,
        'score': score,
        'overallRating': overallRating,
        'tasteRating': tasteRating,
        'presentationRating': presentationRating,
        'nutritionRating': nutritionRating,
        'comment': comment,
        'reviewedAt': reviewedAt?.toIso8601String(),
        'reviewedBy': reviewedBy,
        'estimatedCalories': estimatedCalories,
        'estimatedProtein': estimatedProtein,
        'estimatedCarbs': estimatedCarbs,
        'estimatedFat': estimatedFat,
        'foodRecognition': foodRecognition.isEmpty ? null : foodRecognition,
        'confidenceScore': confidenceScore,
      };

  static MealCheckin? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final athleteId = m['athleteId'] as String?;
    final coachId = m['coachId'] as String?;
    if (athleteId == null || coachId == null) return null;
    final raw = m['foodRecognition'];
    return MealCheckin(
      checkinId: (m['checkinId'] as String?) ?? '',
      athleteId: athleteId,
      coachId: coachId,
      mealType: ((m['mealType'] as String?) ?? 'meal').toLowerCase(),
      mealName: (m['mealName'] as String?) ?? 'Meal',
      status: (m['status'] as String?) ?? 'pending',
      athleteName: m['athleteName'] as String?,
      day: m['day'] as String?,
      imageUrl: m['imageUrl'] as String?,
      timestamp: _date(m['timestamp']),
      reaction: MealReaction.fromId(m['reaction'] as String?),
      score: asNum(m['score'])?.toInt(),
      overallRating: asNum(m['overallRating'])?.toInt(),
      tasteRating: asNum(m['tasteRating'])?.toInt(),
      presentationRating: asNum(m['presentationRating'])?.toInt(),
      nutritionRating: asNum(m['nutritionRating'])?.toInt(),
      comment: m['comment'] as String?,
      reviewedAt: _date(m['reviewedAt']),
      reviewedBy: m['reviewedBy'] as String?,
      // Coerced, not cast — these are written by the website too, and JS
      // stores numbers as strings often enough to matter.
      estimatedCalories: asNum(m['estimatedCalories']),
      estimatedProtein: asNum(m['estimatedProtein']),
      estimatedCarbs: asNum(m['estimatedCarbs']),
      estimatedFat: asNum(m['estimatedFat']),
      foodRecognition: [
        if (raw is List)
          for (final f in raw)
            if (f is String && f.trim().isNotEmpty) f.trim(),
      ],
      confidenceScore: asNum(m['confidenceScore']),
    );
  }

  static DateTime? _date(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
}
