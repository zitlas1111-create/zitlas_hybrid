import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../models/personal_info.dart';
import '../../payments/data/wallet_repository.dart' show WalletOrder;

/// Firestore + backend access for the Profile feature. Every field/endpoint
/// here was traced from `frontend/pages/profile/profile.js`,
/// `personal-info/personal-info.js`, `membership/membership.js`, and
/// `help-support/help-support.js` — no new collections; everything lives on
/// the same `users/{uid}` doc every other feature already reads/writes
/// (`personalInfo`, `membership`, `survey`), per `cloud-sync.js`'s
/// `FIELD_MAP`.
class ProfileRepository {
  ProfileRepository({required FirebaseFirestore firestore, required FirebaseAuth auth, ApiClient? apiClient})
    : _db = firestore,
      // ignore: prefer_initializing_formals
      _auth = auth,
      _api = apiClient ?? ApiClient() {
    _api.authTokenProvider = () async => _auth.currentUser?.getIdToken();
  }

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final ApiClient _api;

  DocumentReference<Map<String, dynamic>> _userDoc(String uid) => _db.collection('users').doc(uid);

  /// Live `users/{uid}` doc, narrowed to what Profile needs: `personalInfo`,
  /// `membership`, `goal` (for the "AI {Goal} Member" label), `survey`
  /// (`fitness_goal` fallback), and the base `name`/`photo` fields written by
  /// login (used as the pre-Personal-Info fallback, exactly like
  /// `loadAthleteProfile()`'s `zUser.name`/`fbUser.photoURL` chain).
  Stream<Map<String, dynamic>?> watchUserDoc(String uid) {
    return _userDoc(uid).snapshots().map((snap) => snap.data());
  }

  /// `initSaveBtn()` (personal-info.js:300-383) — writes BOTH `personalInfo`
  /// (the full form) and the `height_cm`/`weight_kg`/unit-preference subset
  /// into `survey`, exactly like the website's dual localStorage write. This
  /// does NOT recompute `calculations`/BMI/targets — the website doesn't
  /// either; those only change on the next Assessment run.
  Future<void> savePersonalInfo(String uid, PersonalInfo info) {
    final surveyPatch = <String, dynamic>{
      'preferred_height_unit': info.preferredHeightUnit,
      'preferred_weight_unit': info.preferredWeightUnit,
    };
    if (info.heightCm != null) surveyPatch['height_cm'] = info.heightCm;
    if (info.weightKg != null) surveyPatch['weight_kg'] = info.weightKg;

    return _userDoc(uid).set({
      'personalInfo': info.toMap(),
      'survey': surveyPatch,
    }, SetOptions(merge: true));
  }

  /// `POST /api/support/contact` — the exact payload shape from
  /// `handleSubmit()` (help-support.js:219-225). The screenshot file the UI
  /// lets you attach is never actually transmitted on the website either
  /// (collected client-side only) — faithfully not sent here.
  Future<void> submitSupportRequest({
    required String name,
    required String email,
    required String subject,
    required String category,
    required String message,
  }) async {
    await _api.post('/api/support/contact', body: {
      'name': name,
      'email': email,
      'subject': subject,
      'category': category,
      'message': message,
    });
  }

  /// `initUpgradeBtn()`'s order step (membership.js:223-246) — creates a
  /// Razorpay order priced BY THE SERVER.
  ///
  /// The app sends only the billing period; the amount comes from
  /// `MEMBERSHIP_PRICES_RUPEES` on the backend, so a patched client cannot
  /// buy Premium for ₹1. The order is recorded against the caller's uid with
  /// `purpose: 'membership'`, both of which /verify re-checks.
  ///
  /// Returns the same order shape the wallet path uses — one Razorpay order
  /// model for the whole app, not a second copy of the same four fields.
  Future<WalletOrder> createMembershipOrder(String billing) async {
    try {
      final res = await _api.post('/api/payment/membership/create-order', body: {'billing': billing});
      return WalletOrder.fromMap((res as Map).cast<String, dynamic>());
    } on ApiException catch (e) {
      final body = e.body;
      throw Exception(body is Map && body['detail'] != null ? body['detail'].toString() : 'Could not start payment.');
    }
  }

  /// `POST /api/payment/membership/verify` — the ONLY thing that can make an
  /// account Premium.
  ///
  /// The backend re-computes the HMAC signature over `order_id|payment_id`
  /// with the Razorpay secret, confirms the order exists, belongs to THIS
  /// uid and was created for a membership, and only then writes
  /// `users/{uid}.membership` inside a transaction. It is idempotent: an
  /// order already marked `paid` returns the existing membership instead of
  /// extending it, so a retried callback cannot grant a second term.
  ///
  /// Nothing here writes membership locally. A client-side "premium = true"
  /// is a claim, not a fact.
  Future<void> verifyMembershipPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    try {
      await _api.post('/api/payment/membership/verify', body: {
        'razorpay_order_id': orderId,
        'razorpay_payment_id': paymentId,
        'razorpay_signature': signature,
      });
    } on ApiException catch (e) {
      final body = e.body;
      final detail = body is Map ? body['detail'] : null;
      if (detail == 'signature_mismatch') {
        throw Exception(
            'That payment could not be verified. If money left your account, '
            'it will be refunded automatically — Premium was not activated.');
      }
      throw Exception(detail?.toString() ?? 'Payment could not be verified.');
    }
  }
}
