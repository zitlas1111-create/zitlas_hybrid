import 'dart:io';


import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../coaching/data/meal_photo_uploader.dart';
import '../models/expert_rating.dart';

/// Raised when a transformation photo could not be uploaded.
///
/// Deliberately distinct from a failed SUBMIT: a photo that won't upload
/// must never cost the athlete their written rating. The sheet catches this,
/// drops the photo, and lets them submit the rest.
class TransformationPhotoException implements Exception {
  const TransformationPhotoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Backend access for the expert rating flow.
///
/// Every write goes through `/api/expert-ratings/*` rather than Firestore
/// directly: the validation this feature needs (engagement ended, athlete
/// belongs to it, not already rated, aggregate updated atomically) is
/// cross-document and transactional, so `firestore.rules` denies client
/// writes to `expert_ratings` outright.
class ExpertRatingRepository {
  ExpertRatingRepository({
    ApiClient? apiClient,
    MealPhotoUploader? photoUploader,
    FirebaseAuth? auth,
  })  : _api = apiClient ?? ApiClient(),
        _uploader = photoUploader,
        _auth = auth {
    _api.authTokenProvider = () async {
      // A token we cannot obtain must degrade to "send none" — the backend
      // then answers 401 and the sheet shows a real failure. Letting this
      // throw instead would abort the submit before the request is even
      // made, which surfaces to the athlete as an unexplained error rather
      // than an authentication problem.
      try {
        return await (_auth ?? FirebaseAuth.instance).currentUser?.getIdToken();
      } catch (e) {
        if (kDebugMode) debugPrint('[RATING] no auth token available: $e');
        return null;
      }
    };
  }

  final ApiClient _api;
  final MealPhotoUploader? _uploader;
  final FirebaseAuth? _auth;

  /// Reuses the SAME uploader Meal Snap already uses — same compression,
  /// same HEIC normalization, same Firebase Storage bucket, same
  /// backend fallback when Storage is unavailable. Only the path prefix
  /// differs, so transformation photos are separable in the bucket.
  MealPhotoUploader get _photos => _uploader ?? MealPhotoUploader();

  static const photoPathPrefix = 'transformation_photos';

  /// Whether this athlete owes a rating for a finished engagement.
  /// Returns null when nothing is pending (including "already rated").
  Future<PendingExpertRating?> fetchPending() async {
    final res = await _api.get('/api/expert-ratings/pending');
    if (res is! Map) return null;
    return PendingExpertRating.fromMap(res.cast<String, dynamic>());
  }

  /// Published ratings for a public profile. Photo URLs are already
  /// stripped server-side unless the athlete consented to public display.
  Future<List<ExpertRating>> fetchForExpert(String expertId, {int limit = 20}) async {
    final res = await _api.get('/api/expert-ratings/expert/$expertId', query: {'limit': limit});
    if (res is! Map) return const [];
    final raw = (res['reviews'] as List?) ?? const [];
    return [
      for (final r in raw)
        if (r is Map) ?ExpertRating.fromMap(r.cast<String, dynamic>()),
    ];
  }

  /// Uploads one transformation photo and returns its URL.
  ///
  /// [bytes] is passed when the athlete used the face-hiding editor — those
  /// are the EDITED pixels, and the original is never uploaded in that case.
  Future<String> uploadPhoto(File file, {Uint8List? bytes}) async {
    try {
      if (bytes != null) {
        return await _photos.uploadPrepared(
          (bytes: bytes, contentType: 'image/jpeg', fileName: 'transformation.jpg'),
          pathPrefix: photoPathPrefix,
        );
      }
      return await _photos.upload(file, pathPrefix: photoPathPrefix);
    } catch (e) {
      if (kDebugMode) debugPrint('[RATING] photo upload failed: $e');
      throw const TransformationPhotoException(
        "That photo couldn't be uploaded. You can still submit your review without it.",
      );
    }
  }

  /// Submits the rating. Throws [ApiException] on a backend refusal — the
  /// caller surfaces the reason rather than pretending it succeeded.
  Future<void> submit(ExpertRatingDraft draft) async {
    await _api.post('/api/expert-ratings/submit', body: draft.toBody());
  }

  /// True when the failure means "this engagement is already rated" — the
  /// one refusal the UI treats as success rather than an error, since the
  /// athlete's goal (a rating exists) is already met.
  static bool isAlreadyRated(Object e) =>
      e is ApiException && (e.statusCode == 409 || '$e'.contains('already_rated'));
}
