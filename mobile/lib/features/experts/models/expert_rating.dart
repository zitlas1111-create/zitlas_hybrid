import '../../../core/util/json_coerce.dart';

/// A finished coaching engagement the athlete has not rated yet —
/// `GET /api/expert-ratings/pending`.
///
/// The BACKEND decides whether a rating is owed, not the client. That is
/// what stops a reinstall or a second device re-prompting for a rating the
/// athlete already submitted: "already rated" is answered by the same
/// authority that stores the rating.
class PendingExpertRating {
  const PendingExpertRating({
    required this.engagementId,
    required this.expertId,
    required this.expertName,
    this.planLabel,
    this.endedAt,
  });

  /// The `personal_coach_requests` doc id — one engagement, one rating.
  final String engagementId;
  final String expertId;
  final String expertName;
  final String? planLabel;
  final String? endedAt;

  static PendingExpertRating? fromMap(Map<String, dynamic> m) {
    if (m['pending'] != true) return null;
    final engagementId = asText(m['engagementId']);
    final expertId = asText(m['expertId']);
    if (engagementId == null || expertId == null) return null;
    return PendingExpertRating(
      engagementId: engagementId,
      expertId: expertId,
      expertName: asText(m['expertName']) ?? 'your coach',
      planLabel: asText(m['planLabel']),
      endedAt: asText(m['endedAt']),
    );
  }
}

/// One published rating as shown on an expert's public profile —
/// `GET /api/expert-ratings/expert/{id}`.
///
/// Photo URLs arrive already stripped by the backend when the athlete did
/// not consent to public display, so a non-null URL here always means
/// consent was explicitly given.
class ExpertRating {
  const ExpertRating({
    required this.reviewId,
    required this.rating,
    this.reviewText,
    this.verifiedCoaching = false,
    this.athleteName = 'Verified ZITLAS Client',
    this.beforePhotoUrl,
    this.afterPhotoUrl,
    this.createdAt,
  });

  final String reviewId;
  final int rating;
  final String? reviewText;
  final bool verifiedCoaching;
  final String athleteName;
  final String? beforePhotoUrl;
  final String? afterPhotoUrl;
  final String? createdAt;

  bool get hasPublicPhotos => beforePhotoUrl != null || afterPhotoUrl != null;

  static ExpertRating? fromMap(Map<String, dynamic> m) {
    final id = asText(m['reviewId']);
    final rating = asInt(m['rating']);
    if (id == null || rating == null) return null;
    return ExpertRating(
      reviewId: id,
      rating: rating,
      reviewText: asText(m['reviewText']),
      verifiedCoaching: m['verifiedCoaching'] == true,
      athleteName: asText(m['athleteName']) ?? 'Verified ZITLAS Client',
      beforePhotoUrl: asText(m['beforePhotoUrl']),
      afterPhotoUrl: asText(m['afterPhotoUrl']),
      createdAt: asText(m['createdAt']),
    );
  }
}

/// What the sheet collects and submits.
class ExpertRatingDraft {
  ExpertRatingDraft({required this.engagementId, required this.expertId});

  final String engagementId;
  final String expertId;

  /// 0 = nothing chosen yet. Submission is blocked until this is 1-5.
  int rating = 0;
  String reviewText = '';
  String? beforePhotoUrl;
  String? afterPhotoUrl;

  /// Explicit public-display consent. MUST default to false and must never
  /// be flipped as a side effect of merely attaching a photo.
  bool photoPublic = false;

  bool get canSubmit => rating >= 1 && rating <= 5;
  bool get hasAnyPhoto => beforePhotoUrl != null || afterPhotoUrl != null;

  Map<String, dynamic> toBody() => {
    'engagementId': engagementId,
    'expertId': expertId,
    'rating': rating,
    if (reviewText.trim().isNotEmpty) 'reviewText': reviewText.trim(),
    if (beforePhotoUrl != null) 'beforePhotoUrl': beforePhotoUrl,
    if (afterPhotoUrl != null) 'afterPhotoUrl': afterPhotoUrl,
    // Consent is meaningless without a photo, and sending true with no
    // photo would leave a misleading flag on the stored record.
    'photoPublic': photoPublic && hasAnyPhoto,
  };
}
