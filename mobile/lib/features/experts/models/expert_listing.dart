import '../../../core/util/json_coerce.dart';

/// Per-expert fee schedule. Defaults match `PRICING_DEFAULTS`
/// (cprofile.js:4581-4589 / coaches.js) exactly; any key present on the
/// expert's own `pricing` map overrides the matching default, mirroring
/// `_getPricing(coach)`.
class ExpertPricing {
  const ExpertPricing({
    this.dietReviewPrice = 49,
    this.workoutReviewPrice = 59,
    this.bothReviewPrice = 99,
    this.chatPrice = 149,
    this.coachingDietPrice = 499,
    this.coachingTrainingPrice = 699,
    this.coachingCompletePrice = 999,
  });

  final num dietReviewPrice;
  final num workoutReviewPrice;
  final num bothReviewPrice;
  final num chatPrice;
  final num coachingDietPrice;
  final num coachingTrainingPrice;
  final num coachingCompletePrice;

  factory ExpertPricing.fromMap(Map<String, dynamic>? m) {
    const d = ExpertPricing();
    if (m == null) return d;
    return ExpertPricing(
      dietReviewPrice: asNum(m['dietReviewPrice']) ?? d.dietReviewPrice,
      workoutReviewPrice: asNum(m['workoutReviewPrice']) ?? d.workoutReviewPrice,
      bothReviewPrice: asNum(m['bothReviewPrice']) ?? d.bothReviewPrice,
      chatPrice: asNum(m['chatPrice']) ?? d.chatPrice,
      coachingDietPrice: asNum(m['coachingDietPrice']) ?? d.coachingDietPrice,
      coachingTrainingPrice: asNum(m['coachingTrainingPrice']) ?? d.coachingTrainingPrice,
      coachingCompletePrice: asNum(m['coachingCompletePrice']) ?? d.coachingCompletePrice,
    );
  }

  /// `reviewPriceFor()` (coaches.js) — the lowest of the two single-type
  /// review fees, shown on the marketplace card.
  num get lowestReviewPrice =>
      dietReviewPrice < workoutReviewPrice ? dietReviewPrice : workoutReviewPrice;
}

/// One `experts/{id}` document as seen by an athlete — field mapping traced
/// from `_normalizeExpertToCoach()` (cprofile.js:4629-4664) and
/// `renderNutritionistCard()`/`loadExpertsFromFirebase()` (coaches.js).
/// Deliberately a separate model from `ExpertProfile`
/// (`expert_dashboard/models/expert_models.dart`), which is the expert's
/// *own* self-view shape (editable-field subset only) — this one carries
/// every athlete-visible marketplace/profile field.
class ExpertListing {
  const ExpertListing({
    required this.id,
    this.approved,
    this.name = 'Expert',
    this.role = 'Nutrition Expert',
    this.image,
    this.colorAccent,
    this.rating = '5.0',
    this.reviewCount = 0,
    this.experience,
    this.languages = const [],
    this.availableToday = false,
    this.about,
    this.quote,
    this.expertise = const [],
    this.stats = const [],
    this.reviews = const [],
    this.gallery = const [],
    this.services = const [],
    this.verified = false,
    this.verificationStatus,
    this.pricing = const ExpertPricing(),
    this.chatRate,
    this.callRate,
  });

  final String id;
  final String name;
  final String role;
  final String? image;
  final String? colorAccent;
  final String rating;
  final int reviewCount;
  final String? experience;
  final List<String> languages;
  final bool availableToday;
  final String? about;
  final String? quote;
  final List<String> expertise;
  final List<Map<String, dynamic>> stats;
  final List<Map<String, dynamic>> reviews;
  final List<String> gallery;
  final List<Map<String, dynamic>> services;

  /// Real production trust field — never inferred from certificate
  /// existence (per Phase 6 requirement #6). Backend/admin-only write.
  final bool verified;
  final String? verificationStatus;
  final ExpertPricing pricing;
  final num? chatRate;
  final num? callRate;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '--';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  String get firstName => name.trim().split(RegExp(r'\s+')).first;

  double get ratingValue => double.tryParse(rating) ?? 5.0;

  /// `experts/{uid}.approved` as stored: `true`, `false`, or ABSENT.
  ///
  /// Kept as a nullable bool rather than collapsed to a bool, because the
  /// three states mean different things and [listedInMarketplace] has to tell
  /// them apart — see that getter.
  final bool? approved;

  /// Whether this profile belongs in the public marketplace.
  ///
  /// Signup writes `approved: false` and tells the applicant "Your
  /// application is under review" (login.js:337), and the admin API flips it
  /// via `POST /api/admin/experts/approve`. So the contract has always been
  /// that an unapproved profile is NOT public — the marketplace simply never
  /// checked, listing every document in `experts` including brand-new
  /// self-signups and test accounts.
  ///
  /// Deliberately `approved != false`, NOT `approved == true`: a document
  /// that predates the field has no `approved` key at all, and excluding
  /// those would delist established real experts. Only an EXPLICIT
  /// `approved: false` — which is exactly what signup writes — is hidden.
  ///
  /// This is also why the filter is client-side rather than a Firestore
  /// `where`: an inequality query silently drops documents missing the
  /// field, which is the failure mode this getter exists to avoid.
  bool get listedInMarketplace => approved != false;

  factory ExpertListing.fromMap(String id, Map<String, dynamic> m) {
    final availability = asMap(m['availability']);
    final verification = asMap(m['verification']);
    return ExpertListing(
      id: id,
      approved: m['approved'] is bool ? m['approved'] as bool : null,
      name: asText(m['name']) ?? 'Expert',
      role: asText(m['specialization']) ?? asText(m['speciality']) ?? asText(m['role']) ?? 'Nutrition Expert',
      image: asText(m['profilePhoto']) ?? asText(m['photo']) ?? asText(m['image']),
      colorAccent: asText(m['colorAccent']),
      rating: asDisplayString(m['rating']) ?? '5.0',
      reviewCount: asInt(m['reviews']) ?? asInt(m['reviewCount']) ?? 0,
      experience: asText(m['experience']),
      languages: _languagesOf(m['languages']),
      availableToday: availability?['availableToday'] == true || m['availableToday'] == true,
      about: asText(m['about']) ?? asText(m['bio']),
      quote: asText(m['quote']),
      expertise: asStringList(m['specialties']).isNotEmpty
          ? asStringList(m['specialties'])
          : asStringList(m['expertise']),
      stats: asMapList(m['stats']),
      reviews: asMapList(m['reviews']),
      gallery: asStringList(m['gallery']),
      services: asMapList(m['services']),
      verified: m['verified'] == true,
      verificationStatus: asText(verification?['status']),
      pricing: ExpertPricing.fromMap(asMap(m['pricing'])),
      chatRate: asNum(m['chatRate']) ?? asNum(m['fee']),
      callRate: asNum(m['callRate']) ?? (asNum(m['fee']) != null ? asNum(m['fee'])! + 30 : null),
    );
  }

  static List<String> _languagesOf(dynamic raw) {
    if (raw is List) return raw.map((e) => e.toString()).toList();
    if (raw is String && raw.trim().isNotEmpty) {
      return raw.split(RegExp(r'[,/]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    return const [];
  }
}
