import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../models/trial_report.dart';

/// Backend access for the Trial Completion Report.
///
/// READ-ONLY, AND DELIBERATELY THIN. The report is an immutable snapshot the
/// backend froze when the coaching engagement ended
/// (`services/trial_report_store.py`), so there is nothing to write and
/// nothing to compute here. `GET /api/trial-report/{requestId}` returns the
/// stored document; this class parses it and hands it to the screen.
///
/// Deliberately NOT a direct Firestore read, even though `firestore.rules`
/// would permit one for the athlete named on the report: routing through the
/// API keeps a single authorization path (the route checks the caller
/// against the STORED athleteId/coachId) and leaves room for the response to
/// evolve without a second client-side schema to keep in sync.
class TrialReportRepository {
  TrialReportRepository({ApiClient? apiClient, FirebaseAuth? auth})
      : _api = apiClient ?? ApiClient(),
        _auth = auth {
    _api.authTokenProvider = () async {
      // A token we cannot obtain degrades to "send none", so the backend
      // answers 401 and the screen shows a real authentication failure
      // rather than an unexplained error thrown before the request is made.
      try {
        final user = (_auth ?? FirebaseAuth.instance).currentUser;
        return await user?.getIdToken();
      } catch (e) {
        if (kDebugMode) debugPrint('[TRIAL REPORT] token unavailable: $e');
        return null;
      }
    };
  }

  final ApiClient _api;
  final FirebaseAuth? _auth;

  /// This athlete's completed reports, newest first.
  ///
  /// The backend derives the athlete from the verified token, so there is no
  /// id to pass and no way to ask for somebody else's history.
  ///
  /// SUMMARIES ONLY — no metrics. That is why history exists at all: once a
  /// new coaching engagement starts, `personal_coaching/{uid}` is overwritten
  /// and the previous engagement's id is no longer discoverable from
  /// client-readable data, even though its report is still stored.
  Future<List<TrialReportSummary>> fetchHistory() async {
    final res = await _api.get('/api/trial-reports');
    if (res is! Map) return const [];
    final rows = res['reports'];
    if (rows is! List) return const [];
    return [
      for (final row in rows) ?TrialReportSummary.fromMap(row),
    ];
  }

  /// The stored report for one engagement, or null when none exists yet.
  ///
  /// Null covers both "never generated" and "not generated yet" — the
  /// backend answers 404 for both on purpose, so that an id the caller has
  /// no right to cannot be distinguished from one that simply has no report.
  /// Callers render "not available" for null, never an error.
  Future<TrialReport?> fetch(String requestId) async {
    if (requestId.trim().isEmpty) return null;
    try {
      final res = await _api.get('/api/trial-report/$requestId');
      if (res is! Map) return null;
      return TrialReport.fromMap(res.cast<String, dynamic>());
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }
}
